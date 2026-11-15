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
        /// Its HP when last seen on the march: less at the next phase means it was attacked,
        /// and it stops for orders. Not saved: a loaded march starts from the unit's HP.
        var hp: Int
    }

    /// A siege: own units around an enemy city, which shoot it every phase from where they
    /// stand and hold the line around it (`GameSession.runSieges`).
    struct Siege: Equatable {
        var city: CityID
        var members: Set<UnitID>
        /// What the last volley did (for the Siege card).
        var report: SiegeReport?
    }

    /// One phase's volley at a besieged city.
    struct SiegeReport: Equatable {
        var phase: Int
        var shots: Int
        var walls: (before: Int, after: Int)
        var hp: (before: Int, after: Int)

        static func == (a: SiegeReport, b: SiegeReport) -> Bool {
            (a.phase, a.shots, a.walls.before, a.walls.after, a.hp.before, a.hp.after)
                == (b.phase, b.shots, b.walls.before, b.walls.after, b.hp.before, b.hp.after)
        }
    }

    private(set) var rallies: [CityID: HexCoord] = [:]
    private(set) var marches: [UnitID: March] = [:]
    /// New military units of cities with a rally point, sent there at the next chance.
    private(set) var recruits: [UnitID: CityID] = [:]
    /// Sieges under way, by the city's tile.
    private(set) var sieges: [HexCoord: Siege] = [:]

    var isEmpty: Bool { rallies.isEmpty && marches.isEmpty && sieges.isEmpty }
    func isMarching(_ id: UnitID) -> Bool { marches[id] != nil }
    /// The tile of the city the unit besieges.
    func siegeTile(of id: UnitID) -> HexCoord? { sieges.first { $0.value.members.contains(id) }?.key }
    func isBesieging(_ id: UnitID) -> Bool { siegeTile(of: id) != nil }
    /// The tile of the siege of city `id`.
    func siegeTile(ofCity id: CityID) -> HexCoord? { sieges.first { $0.value.city == id }?.key }

    mutating func setRally(_ tile: HexCoord?, for city: CityID) { rallies[city] = tile }
    mutating func setMarch(_ march: March?, for id: UnitID) { marches[id] = march }
    mutating func addRecruit(_ id: UnitID, from city: CityID) { recruits[id] = city }

    /// Puts the unit in the siege of `city` at `tile` (out of any other).
    mutating func join(_ id: UnitID, siegeOf city: CityID, at tile: HexCoord) {
        leaveSiege(id)
        if sieges[tile]?.city != city { sieges[tile] = Siege(city: city, members: []) }
        sieges[tile]?.members.insert(id)
    }

    /// Takes the unit out of its siege; a siege left with no one ends.
    mutating func leaveSiege(_ id: UnitID) {
        guard let tile = siegeTile(of: id) else { return }
        sieges[tile]?.members.remove(id)
        if sieges[tile]?.members.isEmpty == true { sieges[tile] = nil }
    }

    mutating func endSiege(at tile: HexCoord) { sieges[tile] = nil }
    mutating func setReport(_ report: SiegeReport, at tile: HexCoord) { sieges[tile]?.report = report }

    mutating func takeRecruits() -> [UnitID: CityID] {
        defer { recruits = [:] }
        return recruits
    }

    /// The places of the marches of units other than `ids`: no one else is sent there.
    func places(excluding ids: [UnitID]) -> Set<HexCoord> {
        Set(marches.filter { !ids.contains($0.key) }.map(\.value.slot))
    }
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
        if let tile = war.siegeTile(of: unit.id) { return "Besieging \(placeName(tile))" }
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
        unit.activity == .none && unit.destination == nil && !war.isMarching(unit.id) && !war.isBesieging(unit.id)
            && !explore.contains(unit.id)
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
        // Garrisons stay home: units in own cities join only when the War Room picks them.
        let cityTiles = Set(view.cities.map(\.position))
        let around = armyUnits.filter { $0.id != id && view.distance($0.position, lead.position) <= Self.groupRadius && !explore.contains($0.id) }
        let near = around.filter { !cityTiles.contains($0.position) }
        let garrisons = around.count - near.count
        clearPreviews()
        warTargeting = WarTargeting(kind: .march([id] + near.map(\.id)), fromWarRoom: false)
        let count = near.count + 1
        let home = garrisons == 0 ? "" : " · \(garrisons) garrison\(garrisons == 1 ? " stays" : "s stay") home"
        show((count == 1 ? "Tap own units to add them, then tap where the group goes"
            : "\(count) units in the group: tap where they go (tap own units to add or drop them)") + home, for: 4)
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
            for city in cities { war.setRally(tile, for: city) }
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

    /// Gives each unit of a formation its march (a unit already in its place holds it), keeps
    /// the marches in mind, and sets out at once: the group keeps together, so units more than a
    /// phase ahead of the slowest wait for it. Returns what happened, for a message.
    @discardableResult
    func sendArmy(_ plan: FormationPlan) -> String {
        guard isInputEnabled else { return waitingFor.map { "Waiting for \($0.civName)" } ?? "Not your turn" }
        for (id, slot) in plan.slots.sorted(by: { $0.key < $1.key }) {
            guard let unit = view.unit(id) else { continue }
            // An older standing order would carry the unit on by itself at the next phase.
            if unit.destination != nil { perform(.cancelOrders(unit: id), quiet: true) }
            war.setMarch(WarOrders.March(target: plan.target, slot: slot, hp: unit.hp), for: id)
        }
        // An order just given may start next to the enemy on purpose: contact where a unit
        // stands does not hold it back, only contact where its move ends.
        let report = advanceMarches(to: plan.target, stopOnContact: false)
        for id in report.stuck { war.setMarch(nil, for: id) }
        var parts: [String] = []
        let place = placeName(plan.target)
        if report.marching > 0 {
            var text = "\(report.marching) unit\(report.marching == 1 ? "" : "s") marching to \(place)"
            if let arrivals = plan.arrivals, arrivals.upperBound > 1 {
                text += arrivals.lowerBound == arrivals.upperBound ? " (\(arrivals.upperBound) turns)"
                    : " (\(max(arrivals.lowerBound, 1))–\(arrivals.upperBound) turns)"
            }
            parts.append(text)
        }
        if report.waiting > 0 { parts.append("\(report.waiting) wait\(report.waiting == 1 ? "s" : "") for the slower ones") }
        if report.arrived > 0 { parts.append("\(report.arrived) in place") }
        if !report.contact.isEmpty { parts.append("\(report.contact.count) met the enemy") }
        let stuck = report.stuck.count + plan.unreachable.count
        if stuck > 0 { parts.append("\(stuck) can't get there") }
        // Units already around the city open the siege at once.
        if war.sieges[plan.target] != nil, let volley = fireSiege(at: plan.target) { parts.append(volley) }
        return parts.isEmpty ? "No one could march" : parts.joined(separator: " · ")
    }

    /// What one round of marching did (`advanceMarches`).
    struct MarchReport {
        var marching = 0
        var arrived = 0
        var waiting = 0
        /// Units that stopped near the enemy; they wait for orders (the attention queue).
        var contact: [UnitID] = []
        /// Units whose place is out of reach (their march is still kept; the caller decides).
        var stuck: [UnitID] = []
    }

    /// Moves the units marching to `target` one phase on, together (`PlayerView.marchSteps`):
    /// arrived units hold their places, units near the enemy (where they stand, with
    /// `stopOnContact`, or where their move ends) stop for orders, units ahead of the slowest
    /// wait, and the rest march. A march is driven by the
    /// App each phase, not left as a standing order, so it can keep pace and stop on contact.
    func advanceMarches(to target: HexCoord, stopOnContact: Bool) -> MarchReport {
        var report = MarchReport()
        let legs = war.marches.filter { $0.value.target == target }.sorted { $0.key < $1.key }
            .map { MarchLeg(unit: $0.key, target: $0.value.target, slot: $0.value.slot) }
        let steps = view.marchSteps(legs, stopOnContact: stopOnContact)
        for leg in legs {
            let id = leg.unit
            switch steps[id] ?? .gone {
            case .gone:
                war.setMarch(nil, for: id)
            case .arrived:
                war.setMarch(nil, for: id)
                holdPlace(id)
                joinSiege(id, at: target)
                report.arrived += 1
            case .contact:
                war.setMarch(nil, for: id)
                report.contact.append(id)
            case .noRoute:
                report.stuck.append(id)
            case .wait:
                // A standing order (a march from an older save) would carry it on regardless.
                if let unit = view.unit(id), unit.destination != nil, let march = war.marches[id] {
                    perform(.cancelOrders(unit: id), quiet: true)
                    war.setMarch(march, for: id)
                }
                report.waiting += 1
            case .move:
                guard let unit = view.unit(id), let march = war.marches[id] else { continue }
                // Held by a zone of control this phase: it sets out next phase.
                if unit.zocStopped {
                    report.marching += 1
                    continue
                }
                guard perform(.moveUnit(unit: id, to: leg.slot), quiet: true) else {
                    report.stuck.append(id)
                    continue
                }
                // Any order ends a march (`warHeard`): it is given back below unless it is over.
                guard let moved = view.unit(id) else { continue }
                if moved.position == march.slot {
                    holdPlace(id)
                    joinSiege(id, at: target)
                    report.arrived += 1
                    continue
                }
                if moved.destination != nil { perform(.cancelOrders(unit: id), quiet: true) }
                if view.marchContact(at: moved.position, target: target) {
                    report.contact.append(id)
                    continue
                }
                war.setMarch(WarOrders.March(target: march.target, slot: march.slot, hp: moved.hp), for: id)
                report.marching += 1
            }
        }
        return report
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
        for id in ids { war.setRally(nil, for: id) }
        refreshSelection()
    }

    func rally(of city: CityID) -> HexCoord? { war.rallies[city] }

    // MARK: Hooks

    /// `perform`'s hook: an order the player gives a marching unit ends its march.
    func warHeard(_ command: Command) {
        guard let id = Self.orderedUnit(of: command) else { return }
        if war.isMarching(id) { war.setMarch(nil, for: id) }
        // Shooting and fortifying are what a besieger does; any other order takes it out.
        switch command {
        case .attack, .fortify: break
        default: war.leaveSiege(id)
        }
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

    /// The viewer's phase began: marches go one phase on (`advanceMarches`). Units attacked
    /// since the last phase or near the enemy stop for orders (they join the attention queue),
    /// units whose place is out of reach get a new one around the same goal, arrived units hold
    /// their places, and new units go to their rally points.
    func continueWar() {
        guard isInputEnabled else { return }
        for (city, _) in war.rallies where view.city(city) == nil { war.setRally(nil, for: city) }
        // Hit on the way: the enemy found it, so the player decides.
        var attacked: [UnitID] = []
        for (id, march) in war.marches.sorted(by: { $0.key < $1.key }) {
            guard let unit = view.unit(id) else {
                war.setMarch(nil, for: id)
                continue
            }
            if unit.hp < march.hp {
                war.setMarch(nil, for: id)
                attacked.append(id)
            }
        }
        // A new place for units whose own is out of reach (another unit on it, a way closed).
        let targets = Set(war.marches.values.map(\.target)).sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        var lost = 0
        for target in targets {
            let legs = war.marches.filter { $0.value.target == target }.sorted { $0.key < $1.key }
                .map { MarchLeg(unit: $0.key, target: $0.value.target, slot: $0.value.slot) }
            let steps = view.marchSteps(legs)
            let blocked = legs.map(\.unit).filter { steps[$0] == .noRoute }
            guard !blocked.isEmpty else { continue }
            let plan = view.formation(of: blocked, around: target, reserved: war.places(excluding: blocked))
            for id in plan.unreachable { war.setMarch(nil, for: id) }
            lost += plan.unreachable.count
            for (id, slot) in plan.slots.sorted(by: { $0.key < $1.key }) {
                war.setMarch(WarOrders.March(target: target, slot: slot, hp: view.unit(id)?.hp ?? 0), for: id)
            }
        }
        var report = MarchReport()
        for target in targets {
            let one = advanceMarches(to: target, stopOnContact: true)
            report.marching += one.marching
            report.arrived += one.arrived
            report.waiting += one.waiting
            report.contact += one.contact
            report.stuck += one.stuck
        }
        for id in report.stuck { war.setMarch(nil, for: id) }
        lost += report.stuck.count
        // Units resting this phase may heal: their HP now is the mark for the next.
        for (id, march) in war.marches {
            if let unit = view.unit(id), unit.hp != march.hp {
                war.setMarch(WarOrders.March(target: march.target, slot: march.slot, hp: unit.hp), for: id)
            }
        }
        let siegeNews = runSieges()
        dispatchRecruits()
        let marchNews = Self.marchNews(contact: report.contact.count, attacked: attacked.count, lost: lost,
                                       arrived: report.arrived, near: (report.contact + attacked).first.flatMap { view.unit($0) }.map { placeName($0.position) })
        let lines = [marchNews].compactMap { $0 } + siegeNews
        if !lines.isEmpty {
            let urgent = !report.contact.isEmpty || !attacked.isEmpty || lost > 0 || !siegeNews.isEmpty
            show(lines.joined(separator: " · "), for: urgent ? 5 : 2)
        }
        refreshSelection()
    }

    /// The phase's march news, the most urgent first: "Enemy near Kumasi: 2 marching units
    /// stopped and wait for orders · 1 attacked on the march".
    static func marchNews(contact: Int, attacked: Int, lost: Int, arrived: Int, near place: String?) -> String? {
        func units(_ n: Int) -> String { "\(n) marching unit\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if contact > 0 {
            let at = place.map { $0 == "the open field" ? "Enemy in sight" : "Enemy \($0.hasPrefix("near ") ? $0 : "at " + $0)" } ?? "Enemy in sight"
            parts.append("\(at): \(units(contact)) stopped and wait\(contact == 1 ? "s" : "") for orders")
        }
        if attacked > 0 { parts.append("\(units(attacked)) attacked on the way, waiting for orders") }
        if lost > 0 { parts.append("\(units(lost)) found no way on and wait\(lost == 1 ? "s" : "") for orders") }
        if parts.isEmpty, arrived > 0 { parts.append("\(arrived) unit\(arrived == 1 ? "" : "s") reached \(arrived == 1 ? "its place" : "their places")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Sieges

    /// An own military unit in its place around `target`: when that is a known enemy city, it
    /// joins the city's siege.
    func joinSiege(_ id: UnitID, at target: HexCoord) {
        let view = self.view
        guard let city = view.knownCity(at: target), view.isAtWar(with: city.owner),
              let unit = view.unit(id), !unit.type.isCivilian else { return }
        war.join(id, siegeOf: city.id, at: city.position)
    }

    /// The siege of city `id`, as it stands (nil: no siege of it, or the city is no longer an
    /// enemy's).
    func siegeOutlook(ofCity id: CityID) -> SiegeOutlook? {
        guard let tile = war.siegeTile(ofCity: id), let siege = war.sieges[tile] else { return nil }
        return view.siegeOutlook(of: siege.members.sorted(), at: tile)
    }

    /// The viewer's phase began (after the marches): every siege shoots its city. A siege whose
    /// city fell, changed hands or is no longer at war ends; badly hurt besiegers leave it for
    /// orders. Returns the news, a line per siege.
    func runSieges() -> [String] {
        var lines: [String] = []
        let maxHP = view.rules.constants.healing.maxHP
        for (tile, siege) in war.sieges.sorted(by: { ($0.key.q, $0.key.r) < ($1.key.q, $1.key.r) }) {
            let view = self.view
            guard let sighting = view.knownCity(at: tile), sighting.id == siege.city, view.isAtWar(with: sighting.owner) else {
                war.endSiege(at: tile)
                if let own = view.city(siege.city) {
                    lines.append("\(own.name) is yours: the siege is over")
                } else {
                    lines.append("The siege of \(placeName(tile)) is over")
                }
                continue
            }
            var wounded = 0
            for id in siege.members.sorted() {
                guard let unit = view.unit(id) else {
                    war.leaveSiege(id)
                    continue
                }
                if unit.hp * 2 < maxHP {
                    war.leaveSiege(id)
                    // Awake, so it comes up in the attention queue.
                    if [.fortified, .fortifying, .sleeping].contains(unit.activity) { perform(.wake(unit: id), quiet: true) }
                    wounded += 1
                }
            }
            if let volley = fireSiege(at: tile) { lines.append(volley) }
            if wounded > 0 {
                lines.append("\(wounded) wounded besieger\(wounded == 1 ? "" : "s") of \(sighting.name) wait\(wounded == 1 ? "s" : "") for orders")
            }
        }
        return lines
    }

    /// The siege at `tile` shoots: each ranged member that can hit the city from where it
    /// stands does (strongest first, until the city has no HP left), and members with nothing
    /// to do fortify where they stand. Returns the volley's news (nil when no one shot).
    @discardableResult
    func fireSiege(at tile: HexCoord) -> String? {
        guard isInputEnabled, let siege = war.sieges[tile], let outlook = view.siegeOutlook(of: siege.members.sorted(), at: tile) else { return nil }
        let before = outlook.city
        var shots = 0
        for id in outlook.shots {
            guard let now = view.knownCity(at: tile), now.hp > 0 else { break }
            if perform(.attack(unit: id, target: tile), quiet: true) { shots += 1 }
        }
        for id in siege.members.sorted() {
            if let unit = view.unit(id), unit.activity == .none { perform(.fortify(unit: id), quiet: true) }
        }
        guard shots > 0, let after = view.knownCity(at: tile) else { return nil }
        war.setReport(WarOrders.SiegeReport(phase: view.phaseCount, shots: shots, walls: (before.wallHP, after.wallHP),
                                            hp: (before.hp, after.hp)), at: tile)
        var text = "Siege of \(after.name): \(shots) shot\(shots == 1 ? "" : "s")"
        if before.wallHP > 0 || after.wallHP > 0 { text += " · walls \(before.wallHP)→\(after.wallHP)" }
        if before.hp != after.hp { text += " · city \(before.hp)→\(after.hp)" }
        if after.hp == 0 { text += " · it can be taken" }
        return text
    }

    /// The Siege card's Assault: the best melee member storms the city (a capture opens Keep or
    /// Raze); a city taken ends its siege.
    func assault(city id: CityID) {
        guard let tile = war.siegeTile(ofCity: id), let attack = siegeOutlook(ofCity: id)?.assault else {
            show("No one can storm the city now")
            return
        }
        closeAttentionCard()
        guard perform(.attack(unit: attack.unit, target: tile)) else { return }
        if view.city(id) != nil { war.endSiege(at: tile) }
        refreshSelection()
    }

    /// The Siege card's Lift Siege: the besiegers wake and wait for orders where they stand.
    func liftSiege(city id: CityID) {
        guard let tile = war.siegeTile(ofCity: id), let siege = war.sieges[tile] else { return }
        war.endSiege(at: tile)
        closeAttentionCard()
        var awake = 0
        for id in siege.members.sorted() {
            guard let unit = view.unit(id) else { continue }
            if [.fortified, .fortifying, .sleeping].contains(unit.activity) {
                if perform(.wake(unit: id), quiet: true) { awake += 1 }
            } else {
                awake += 1
            }
        }
        show("Siege lifted: \(awake) unit\(awake == 1 ? "" : "s") wait\(awake == 1 ? "s" : "") for orders")
        refreshSelection()
    }

    // MARK: Saves

    /// The orders to put in a save's header (`SaveSummary.war`).
    var warToSave: SavedWarOrders? {
        guard !war.isEmpty else { return nil }
        return SavedWarOrders(rallies: war.rallies.sorted { $0.key < $1.key }.map { SavedRally(city: $0.key, tile: $0.value) },
                              marches: war.marches.sorted { $0.key < $1.key }.map {
                                  SavedMarch(unit: $0.key, target: $0.value.target, slot: $0.value.slot)
                              },
                              sieges: war.sieges.sorted { ($0.key.q, $0.key.r) < ($1.key.q, $1.key.r) }.map {
                                  SavedSiege(city: $0.value.city, tile: $0.key, units: $0.value.members.sorted())
                              })
    }

    /// After a load, before play begins: the orders the save's header kept, for own cities and
    /// units still there.
    func resumeWar(_ saved: SavedWarOrders?) {
        guard let saved else { return }
        let view = self.view
        for rally in saved.rallies where view.city(rally.city) != nil { war.setRally(rally.tile, for: rally.city) }
        for march in saved.marches {
            guard let unit = view.unit(march.unit), !unit.type.isCivilian else { continue }
            war.setMarch(WarOrders.March(target: march.target, slot: march.slot, hp: unit.hp), for: march.unit)
        }
        for siege in saved.sieges {
            for id in siege.units where view.unit(id).map({ !$0.type.isCivilian }) == true {
                war.join(id, siegeOf: siege.city, at: siege.tile)
            }
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
