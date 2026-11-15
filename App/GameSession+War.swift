import GameCore
import Persistence
import SwiftUI

// War orders (docs/M2.md §10.4), App-side conveniences and no rules, as the Explore order: the
// engine only hears the ordinary commands they issue.
//
// - Groups: own military units sent together to a goal. Each gets its own place there
//   (`PlayerView.formation`: the goal, then the tiles around it nearest first, on the side the
//   group comes from; an enemy city is surrounded) and an ordinary march (`moveUnit`). The group
//   is gathered on the map (the unit card's Group tile: the unit and the own military units
//   within `groupRadius`; tapping own units adds or drops them) or picked in the War Room.
//   The first tap on the goal previews the places, the second gives the order.
// - Marches: a unit on its way keeps its place in mind. At the start of each of the viewer's
//   phases (before the autosave) a unit whose march was stopped (an unseen unit in the way,
//   a zone of control) is given a new place and route around the same goal, and a unit that
//   arrived fortifies there, unless an enemy is near (it waits for orders, to attack). Marching
//   units are not in the attention queue. Any order the player gives a unit ends its march.
// - Rally points: a city's new military units (built or bought) march to its rally point, as a
//   group of their own.
// - Production at scale: one item put first, last or in place of the queues of many cities
//   (`PlayerView.bulkQueues`).
// Marches and rally points live in the save header (`SaveSummary.war`), so they survive save,
// quit and Continue.

/// The War Room's tabs.
enum WarRoomTab: String, CaseIterable, Identifiable {
    case production, army
    var id: String { rawValue }
    var title: String { self == .production ? "Production" : "Army" }
}

/// The War Room's tab, the cities and units picked in it, and how an item goes into queues.
struct WarRoomState: Equatable {
    var tab = WarRoomTab.production
    var cities: Set<CityID> = []
    var units: Set<UnitID> = []
    var placement = BulkPlacement.first
    var filter = ArmyFilter.all
}

/// Which of the viewer's military units the War Room lists.
enum ArmyFilter: String, CaseIterable, Identifiable {
    case all, idle, fortified, marching, hurt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .idle: "Idle"
        case .fortified: "Fortified"
        case .marching: "Marching"
        case .hurt: "Hurt"
        }
    }
}

/// The session's war orders.
struct WarOrders: Equatable {
    struct March: Equatable {
        /// The goal the unit's group was sent to.
        var target: HexCoord
        /// Its own place there.
        var slot: HexCoord
    }

    private(set) var rallies: [CityID: HexCoord] = [:]
    private(set) var marches: [UnitID: March] = [:]
    /// New military units of cities with a rally point, sent there at the next chance.
    private(set) var recruits: [UnitID: CityID] = [:]

    var isEmpty: Bool { rallies.isEmpty && marches.isEmpty }
    func isMarching(_ id: UnitID) -> Bool { marches[id] != nil }

    mutating func setRally(_ tile: HexCoord?, for city: CityID) { rallies[city] = tile }
    mutating func setMarch(_ march: March?, for id: UnitID) { marches[id] = march }
    mutating func addRecruit(_ id: UnitID, from city: CityID) { recruits[id] = city }

    mutating func takeRecruits() -> [UnitID: CityID] {
        defer { recruits = [:] }
        return recruits
    }

    /// The places of the marches of units other than `ids`: no one else is sent there.
    func places(excluding ids: [UnitID]) -> Set<HexCoord> {
        Set(marches.filter { !ids.contains($0.key) }.map(\.value.slot))
    }

    /// Whether a save would keep the same orders as `other` (recruits are not saved).
    func savesSame(as other: WarOrders) -> Bool { rallies == other.rallies && marches == other.marches }
}

/// Choosing a war order's goal on the map.
struct WarTargeting: Equatable {
    enum Kind: Equatable {
        /// A group to send.
        case march([UnitID])
        /// Cities whose rally point is chosen.
        case rally([CityID])
    }

    var kind: Kind
    /// The goal tapped once, with the group's places (a march).
    var plan: FormationPlan?
    /// The tile tapped once (a rally point).
    var rallyTile: HexCoord?
    /// The War Room opens again when the choice is made or dropped.
    var fromWarRoom: Bool

    var units: [UnitID] { if case let .march(ids) = kind { ids } else { [] } }
    var cities: [CityID] { if case let .rally(ids) = kind { ids } else { [] } }
}

extension GameSession {
    /// How far from the unit the Group tile gathers own military units.
    static let groupRadius = 2

    // MARK: Queries

    /// The viewer's military units.
    var armyUnits: [GameCore.Unit] { view.units.filter { !$0.type.isCivilian } }

    /// A tile's name for the war tools: an own or known city on it ("Rome"), one within 3 tiles
    /// ("near Rome"), else "the open field".
    func placeName(_ hex: HexCoord) -> String {
        let view = self.view
        let cities = view.knownCities.map { ($0.name, $0.position) } + view.cities.map { ($0.name, $0.position) }
        guard let nearest = cities.min(by: { (view.distance($0.1, hex), $0.0) < (view.distance($1.1, hex), $1.0) }) else {
            return "the open field"
        }
        let d = view.distance(nearest.1, hex)
        if d == 0 { return nearest.0 }
        return d <= 3 ? "near \(nearest.0)" : "the open field"
    }

    /// What an own military unit is doing, for the War Room and its card.
    func armyStatus(of unit: GameCore.Unit) -> String {
        if let march = war.marches[unit.id] {
            let turns = view.path(for: unit.id, to: march.slot)?.turns
            return "Marching to \(placeName(march.target))" + (turns.map { $0 <= 1 ? " · arrives this turn" : " · \($0) turns" } ?? "")
        }
        if explore.contains(unit.id) { return "Exploring" }
        if unit.destination != nil { return "On the move" }
        switch unit.activity {
        case .fortified: return "Fortified"
        case .fortifying: return "Fortifying"
        case .sleeping: return "Asleep"
        case .skipped: return "Skipping this turn"
        case .none: return unit.movesLeft > 0 ? "Awaiting orders" : "Moved this turn"
        }
    }

    /// Whether the unit waits for orders (the War Room's Idle filter).
    func isIdle(_ unit: GameCore.Unit) -> Bool {
        unit.activity == .none && unit.destination == nil && !war.isMarching(unit.id) && !explore.contains(unit.id)
    }

    // MARK: Groups and goals on the map

    /// The unit card's Group tile: the unit and the own military units within `groupRadius`
    /// (not exploring) become a group, whose goal is tapped next.
    func beginGroup(around id: UnitID) {
        guard isInputEnabled else {
            show(waitingFor.map { "Waiting for \($0.civName)" } ?? "Not your turn")
            return
        }
        guard let lead = view.unit(id), lead.owner == viewer, !lead.type.isCivilian else { return }
        let near = armyUnits.filter { $0.id != id && view.distance($0.position, lead.position) <= Self.groupRadius && !explore.contains($0.id) }
        clearPreviews()
        warTargeting = WarTargeting(kind: .march([id] + near.map(\.id)), fromWarRoom: false)
        let count = near.count + 1
        show(count == 1 ? "Tap own units to add them, then tap where the group goes"
            : "\(count) units in the group: tap where they go (tap own units to add or drop them)", for: 4)
        refreshSelection()
    }

    /// The War Room's Send To on the map: the goal of units `ids` is tapped next.
    func beginMarch(_ ids: [UnitID]) {
        guard isInputEnabled, !ids.isEmpty else { return }
        openPanel = nil
        clearPreviews()
        warTargeting = WarTargeting(kind: .march(ids), fromWarRoom: true)
        show(ids.count == 1 ? "Tap where the unit goes" : "Tap where the \(ids.count) units go", for: 4)
        refreshSelection()
    }

    /// The War Room's Set Rally Point: the rally point of cities `ids` is tapped next.
    func beginRally(_ ids: [CityID]) {
        guard !ids.isEmpty else { return }
        openPanel = nil
        clearPreviews()
        warTargeting = WarTargeting(kind: .rally(ids), fromWarRoom: true)
        show("Tap where new units from \(ids.count == 1 ? "the city" : "these \(ids.count) cities") gather", for: 4)
        refreshSelection()
    }

    /// Leaves goal choosing (Cancel, Esc, or after the order), back to the War Room when it
    /// came from there.
    func endWarTargeting() {
        guard let targeting = warTargeting else { return }
        warTargeting = nil
        if targeting.fromWarRoom { openPanel = .war }
        refreshSelection()
    }

    /// Tap rule 0d: while a goal is chosen. A march: own military units off the goal (and not in
    /// a city) join or leave the group; another tile previews the places there, and a second
    /// tap on it gives the order. A rally point: the first tap marks it, the second sets it.
    func warTap(at hex: HexCoord) {
        guard var targeting = warTargeting else { return }
        let view = self.view
        switch targeting.kind {
        case let .march(ids):
            if targeting.plan?.target == hex {
                confirmWarTarget()
                return
            }
            let own = view.units(at: hex).filter { $0.owner == viewer && !$0.type.isCivilian }
            if let unit = own.first, view.cities.first(where: { $0.position == hex }) == nil {
                var group = ids
                if let i = group.firstIndex(of: unit.id) {
                    guard group.count > 1 else {
                        show("A group needs one unit at least")
                        return
                    }
                    group.remove(at: i)
                } else {
                    group.append(unit.id)
                }
                targeting.kind = .march(group)
                targeting.plan = targeting.plan.map { view.formation(of: group, around: $0.target, reserved: war.places(excluding: group)) }
                warTargeting = targeting
                show("\(group.count) unit\(group.count == 1 ? "" : "s") in the group")
                refreshSelection()
                return
            }
            let plan = view.formation(of: ids, around: hex, reserved: war.places(excluding: ids))
            guard plan.placed > 0 else {
                show("No route there for \(ids.count == 1 ? "the unit" : "the group")")
                return
            }
            targeting.plan = plan
            warTargeting = targeting
            show("Tap again to march: " + Self.planSummary(plan), for: 4)
            refreshSelection()
        case .rally:
            guard view.isExplored(hex), let tile = view.tile(at: hex), view.rules.isPassable(tile) else {
                show("Pick explored land for the rally point")
                return
            }
            if targeting.rallyTile == hex {
                confirmWarTarget()
                return
            }
            targeting.rallyTile = hex
            warTargeting = targeting
            show("Tap again to set the rally point \(placeName(hex) == "the open field" ? "here" : placeName(hex))")
            refreshSelection()
        }
    }

    /// The goal card's Go (or the second tap): gives the previewed order.
    func confirmWarTarget() {
        guard let targeting = warTargeting else { return }
        switch targeting.kind {
        case .march:
            guard let plan = targeting.plan else { return }
            let outcome = sendArmy(plan)
            warTargeting = nil
            refreshSelection()
            show(outcome, for: 4)
            if targeting.fromWarRoom { openPanel = .war }
        case let .rally(cities):
            guard let tile = targeting.rallyTile else { return }
            let before = war
            for city in cities { war.setRally(tile, for: city) }
            if !war.savesSame(as: before) { noteHeaderChange() }
            warTargeting = nil
            refreshSelection()
            show("Rally point set: new military units from \(cities.count == 1 ? (view.city(cities[0])?.name ?? "the city") : "\(cities.count) cities") march \(placeName(tile) == "the open field" ? "there" : "to " + placeName(tile))")
            if targeting.fromWarRoom { openPanel = .war }
        }
    }

    /// "5 units, arriving in 2–4 turns; 1 has no route".
    static func planSummary(_ plan: FormationPlan) -> String {
        var text = "\(plan.placed) unit\(plan.placed == 1 ? "" : "s")"
        if let arrivals = plan.arrivals {
            text += arrivals.lowerBound == arrivals.upperBound
                ? (arrivals.lowerBound <= 1 ? ", arriving this turn" : ", arriving in \(arrivals.lowerBound) turns")
                : ", arriving in \(arrivals.lowerBound)–\(arrivals.upperBound) turns"
        } else {
            text += ", already in place"
        }
        if !plan.unreachable.isEmpty { text += "; \(plan.unreachable.count) ha\(plan.unreachable.count == 1 ? "s" : "ve") no route" }
        return text
    }

    // MARK: Orders

    /// Sends own units `ids` to `target` at once (the War Room's quick goals). Returns what
    /// happened, for a message.
    @discardableResult
    func sendArmy(_ ids: [UnitID], to target: HexCoord) -> String {
        let plan = view.formation(of: ids, around: target, reserved: war.places(excluding: ids))
        guard plan.placed > 0 else { return "No route to \(placeName(target))" }
        return sendArmy(plan)
    }

    /// Gives each unit of a formation its march (a unit already in its place holds it), and
    /// keeps the marches in mind. Returns what happened, for a message.
    @discardableResult
    func sendArmy(_ plan: FormationPlan) -> String {
        guard isInputEnabled else { return waitingFor.map { "Waiting for \($0.civName)" } ?? "Not your turn" }
        let before = war
        defer { if !war.savesSame(as: before) { noteHeaderChange() } }
        var marching = 0, arrived = 0, refused = 0
        for (id, slot) in plan.slots.sorted(by: { $0.key < $1.key }) {
            guard let unit = view.unit(id) else { continue }
            war.setMarch(nil, for: id)
            // A unit not setting out now drops its earlier destination or Explore order, which
            // would take it from its place (a `moveUnit` replaces them for the others).
            if unit.position == slot || unit.zocStopped, unit.destination != nil || isExploring(id) {
                perform(.cancelOrders(unit: id), quiet: true)
            }
            if unit.position == slot {
                holdPlace(id)
                arrived += 1
                continue
            }
            let march = WarOrders.March(target: plan.target, slot: slot)
            // Held by a zone of control this phase: it sets out next phase.
            if unit.zocStopped {
                war.setMarch(march, for: id)
                marching += 1
                continue
            }
            guard perform(.moveUnit(unit: id, to: slot), quiet: true) else {
                refused += 1
                continue
            }
            guard let moved = view.unit(id) else { continue }
            if moved.position == slot {
                holdPlace(id)
                arrived += 1
            } else {
                war.setMarch(march, for: id)
                marching += 1
            }
        }
        var parts: [String] = []
        let place = placeName(plan.target)
        if marching > 0 {
            var text = "\(marching) unit\(marching == 1 ? "" : "s") marching to \(place)"
            if let arrivals = plan.arrivals, arrivals.upperBound > 1 {
                text += arrivals.lowerBound == arrivals.upperBound ? " (\(arrivals.upperBound) turns)"
                    : " (\(max(arrivals.lowerBound, 1))–\(arrivals.upperBound) turns)"
            }
            parts.append(text)
        }
        if arrived > 0 { parts.append("\(arrived) in place") }
        let stuck = refused + plan.unreachable.count
        if stuck > 0 { parts.append("\(stuck) can't get there") }
        return parts.isEmpty ? "No one could march" : parts.joined(separator: " · ")
    }

    /// A unit arrived in its place: it fortifies, unless an enemy is near (it waits for orders).
    private func holdPlace(_ id: UnitID) {
        guard let unit = view.unit(id), unit.activity != .fortified, unit.activity != .fortifying else { return }
        guard !enemyNear(unit.position) else { return }
        perform(.fortify(unit: id), quiet: true)
    }

    /// Whether a city or military unit of a player the viewer is at war with is within 2 tiles
    /// of `hex`, as far as the viewer knows.
    func enemyNear(_ hex: HexCoord) -> Bool {
        let view = self.view
        let near = view.knownCities.contains { view.isAtWar(with: $0.owner) && view.distance($0.position, hex) <= 2 }
        return near || view.visibleForeignUnits.contains { !$0.type.isCivilian && view.isAtWar(with: $0.owner) && view.distance($0.position, hex) <= 2 }
    }

    /// Fortifies own units `ids` (those that can), waking none.
    func fortifyAll(_ ids: [UnitID]) {
        var done = 0
        for id in ids {
            guard let unit = view.unit(id), unit.activity != .fortified, unit.activity != .fortifying else { continue }
            if perform(.fortify(unit: id), quiet: true) { done += 1 }
        }
        show(done == 0 ? "No one to fortify" : "\(done) unit\(done == 1 ? "" : "s") fortified")
    }

    /// Wakes own units `ids` that are asleep or fortified.
    func wakeAll(_ ids: [UnitID]) {
        var done = 0
        for id in ids {
            guard let unit = view.unit(id), [.sleeping, .fortified, .fortifying].contains(unit.activity) else { continue }
            if perform(.wake(unit: id), quiet: true) { done += 1 }
        }
        show(done == 0 ? "No one to wake" : "\(done) unit\(done == 1 ? "" : "s") awake")
    }

    /// Stops the marches of own units `ids`: they wait for orders where they are.
    func haltAll(_ ids: [UnitID]) {
        let before = war
        defer { if !war.savesSame(as: before) { noteHeaderChange() } }
        var done = 0
        for id in ids {
            guard let unit = view.unit(id) else { continue }
            if unit.destination != nil {
                if perform(.cancelOrders(unit: id), quiet: true) { done += 1 }
            } else if war.isMarching(id) {
                done += 1
            }
            war.setMarch(nil, for: id)
        }
        show(done == 0 ? "No one is marching" : "\(done) unit\(done == 1 ? "" : "s") halted")
    }

    // MARK: Rally points

    /// Removes the rally points of cities `ids`.
    func clearRally(_ ids: [CityID]) {
        let before = war
        for id in ids { war.setRally(nil, for: id) }
        if !war.savesSame(as: before) { noteHeaderChange() }
        refreshSelection()
    }

    func rally(of city: CityID) -> HexCoord? { war.rallies[city] }

    // MARK: Hooks

    /// `perform`'s hook: an order the player gives a marching unit ends its march.
    func warHeard(_ command: Command) {
        guard let id = Self.orderedUnit(of: command), war.isMarching(id) else { return }
        war.setMarch(nil, for: id)
    }

    /// `stateChanged`'s hook: the military units a city with a rally point just made.
    func noteRecruits(_ records: [EventRecord]) {
        guard !war.rallies.isEmpty else { return }
        var from: CityID?
        for record in records {
            switch record.event {
            case let .productionCompleted(city, .unit(type), _):
                from = !type.isCivilian && war.rallies[city] != nil && state.city(city)?.owner == viewer ? city : nil
            case let .unitCreated(unit, _, owner, _):
                if let city = from, owner == viewer { war.addRecruit(unit, from: city) }
                from = nil
            default:
                break
            }
        }
    }

    /// Sends the new units of rally cities to their rally points, a group per point.
    func dispatchRecruits() {
        guard isInputEnabled else { return }
        let recruits = war.takeRecruits()
        guard !recruits.isEmpty else { return }
        var byPoint: [HexCoord: [UnitID]] = [:]
        for (id, city) in recruits {
            guard let point = war.rallies[city], view.city(city) != nil, view.unit(id) != nil else { continue }
            byPoint[point, default: []].append(id)
        }
        var lines: [String] = []
        for (point, ids) in byPoint.sorted(by: { ($0.key.q, $0.key.r) < ($1.key.q, $1.key.r) }) {
            let plan = view.formation(of: ids.sorted(), around: point, reserved: war.places(excluding: ids))
            guard plan.placed > 0 else {
                lines.append("No route to the rally point \(placeName(point))")
                continue
            }
            let names = ids.compactMap { view.unit($0)?.type.displayName }
            lines.append("\(names.count == 1 ? "New \(names[0])" : "\(names.count) new units") → rally point: " + sendArmy(plan))
        }
        if !lines.isEmpty { show(lines.joined(separator: " · "), for: 4) }
    }

    /// The viewer's phase began: arrived units hold their places, stopped marches go on by a
    /// new route, and new units go to their rally points.
    func continueWar() {
        guard isInputEnabled else { return }
        for (city, _) in war.rallies where view.city(city) == nil { war.setRally(nil, for: city) }
        var stalled: [HexCoord: [UnitID]] = [:]
        var arrived = 0
        for (id, march) in war.marches.sorted(by: { $0.key < $1.key }) {
            guard let unit = view.unit(id) else {
                war.setMarch(nil, for: id)
                continue
            }
            if unit.position == march.slot {
                war.setMarch(nil, for: id)
                holdPlace(id)
                arrived += 1
            } else if unit.destination != march.slot {
                stalled[march.target, default: []].append(id)
            }
        }
        var lost = 0
        for (target, ids) in stalled.sorted(by: { ($0.key.q, $0.key.r) < ($1.key.q, $1.key.r) }) {
            let plan = view.formation(of: ids, around: target, reserved: war.places(excluding: ids))
            for id in plan.unreachable { war.setMarch(nil, for: id) }
            lost += plan.unreachable.count
            if plan.placed > 0 { sendArmy(plan) }
        }
        dispatchRecruits()
        if lost > 0 {
            show("\(lost) marching unit\(lost == 1 ? "" : "s") found no way on and wait\(lost == 1 ? "s" : "") for orders", for: 4)
        } else if arrived > 0 {
            show("\(arrived) unit\(arrived == 1 ? "" : "s") reached \(arrived == 1 ? "its place" : "their places")")
        }
        refreshSelection()
    }

    // MARK: Saves

    /// The orders to put in a save's header (`SaveSummary.war`).
    var warToSave: SavedWarOrders? {
        guard !war.isEmpty else { return nil }
        return SavedWarOrders(rallies: war.rallies.sorted { $0.key < $1.key }.map { SavedRally(city: $0.key, tile: $0.value) },
                              marches: war.marches.sorted { $0.key < $1.key }.map {
                                  SavedMarch(unit: $0.key, target: $0.value.target, slot: $0.value.slot)
                              })
    }

    /// After a load, before play begins: the orders the save's header kept, for own cities and
    /// units still there.
    func resumeWar(_ saved: SavedWarOrders?) {
        guard let saved else { return }
        let view = self.view
        for rally in saved.rallies where view.city(rally.city) != nil { war.setRally(rally.tile, for: rally.city) }
        for march in saved.marches where view.unit(march.unit).map({ !$0.type.isCivilian }) == true {
            war.setMarch(WarOrders.March(target: march.target, slot: march.slot), for: march.unit)
        }
    }

    // MARK: Production at scale

    /// Puts `item` in the queues of own cities `ids` (`placement`: first, last or alone).
    /// Returns what happened, for a message.
    @discardableResult
    func bulkQueue(_ item: ProductionItem, in ids: [CityID], placement: BulkPlacement) -> String {
        guard isInputEnabled else { return waitingFor.map { "Waiting for \($0.civName)" } ?? "Not your turn" }
        let changes = view.bulkQueues(item, in: ids, placement: placement)
        var done = 0
        var problems: [String: Int] = [:]
        for change in changes {
            if let items = change.items, perform(.setQueue(city: change.city, items: items), quiet: true) {
                done += 1
            } else {
                problems[change.problem ?? "refused", default: 0] += 1
            }
        }
        let name = state.itemName(item)
        var text = done == 0 ? "\(name): no city could take it" : "\(name) \(placement == .last ? "queued" : "set") in \(done) cit\(done == 1 ? "y" : "ies")"
        if !problems.isEmpty {
            text += " · " + problems.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        }
        show(text, for: 4)
        return text
    }

    // MARK: Map marks

    /// The war tools' tokens on the map: rally points (always), and while a goal is chosen the
    /// group's units, the previewed places and the goal; with a marching unit selected, its place.
    func armyMarks() -> [MapOverlay.ArmyMark] {
        var marks: [MapOverlay.ArmyMark] = []
        var points: [HexCoord: Int] = [:]
        for (_, tile) in war.rallies { points[tile, default: 0] += 1 }
        if let targeting = warTargeting {
            for id in targeting.units {
                if let unit = view.unit(id) { marks.append(.init(hex: unit.position, kind: .member)) }
            }
            if let plan = targeting.plan {
                for slot in Set(plan.slots.values) where slot != plan.target { marks.append(.init(hex: slot, kind: .slot)) }
                marks.append(.init(hex: plan.target, kind: .target))
            }
            if let tile = targeting.rallyTile { marks.append(.init(hex: tile, kind: .newRally)) }
        } else if case let .unit(id)? = selection, let march = war.marches[id] {
            marks.append(.init(hex: march.slot, kind: .slot))
        }
        let taken = Set(marks.map(\.hex))
        for (tile, count) in points.sorted(by: { ($0.key.q, $0.key.r) < ($1.key.q, $1.key.r) }) where !taken.contains(tile) {
            marks.append(.init(hex: tile, kind: .rally(count)))
        }
        return marks
    }
}
