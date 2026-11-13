import GameCore
import Persistence
import SwiftUI

// The Explore order (M1 §16), an App-side convenience and no rule: the engine never hears of it.
// It is a Scout's first action and any other military unit's last. A unit on the order walks, at
// the start of each of the viewer's phases (before the autosave) and right after the order is
// given, toward a tribal village its player knows of within a few turns' moves (the rules'
// `seekTurns`, M1 §7.7), else toward the frontier tile its player knows of that pays best
// (`PlayerView.exploreStep`), keeping the one it heads for unless another frontier tile is
// better by more than a turn, by ordinary `moveUnit` commands to where it gets this phase (so
// no standing order ever crosses a phase). Taking a tribal village does not end the order: the
// gift's notice is important, so it joins the attention queue. Badly hurt with no enemy in
// sight, it rests where it stands until it has healed. The order ends when nothing it can reach
// is left unexplored and no tribal village it knows of is in reach, when the way on lies only
// within enemy reach, when the player gives the unit another order, or when an enemy military
// unit comes into its sight (the unit then waits in the attention queue), each with a notice of
// its own saying why; a good city site its walk brings into view gets a notice too. Exploring
// units are not in the attention queue. The order lives in the save header
// (`SaveSummary.explorers`), so it survives save, quit and Continue.

/// The session's explorers, and what the unit card shows about them.
struct ExploreOrders: Equatable {
    struct Order: Equatable {
        var unit: UnitID
        /// Enemy military units in its sight when the order was given: they do not end it while
        /// they stay in sight.
        var knownEnemies: [UnitID] = []
        /// The frontier tile or tribal village it heads for (after its first step).
        var goal: HexCoord?
        /// It rested this phase to heal (nil after a load: the unit tells, `exploreStep`).
        var resting: Bool? = false
        /// Whose reach its last step kept out of, leading it no nearer its goal (the card says so).
        var avoiding: ExploreThreat?
    }

    /// Why a unit's order ended, shown on its card for the rest of that phase.
    struct Stop: Equatable {
        var unit: UnitID
        var text: String
        var phase: Int
    }

    /// A good city site an explorer's walk brought into view, announced in a notice.
    struct Find: Equatable {
        var unit: UnitID
        var site: HexCoord
        var turn: Int
    }

    /// By unit id.
    private(set) var orders: [Order] = []
    private(set) var stops: [Stop] = []
    /// This session's finds, oldest first: a site near one of them is not announced again.
    private(set) var finds: [Find] = []
    /// The unit whose Explore tile is being described (a long-press).
    var described: UnitID?

    func contains(_ id: UnitID) -> Bool { orders.contains { $0.unit == id } }

    func order(of id: UnitID) -> Order? { orders.first { $0.unit == id } }

    mutating func set(_ order: Order) {
        stops.removeAll { $0.unit == order.unit }
        if let i = orders.firstIndex(where: { $0.unit == order.unit }) {
            orders[i] = order
        } else {
            orders.append(order)
            orders.sort { $0.unit < $1.unit }
        }
    }

    mutating func remove(_ id: UnitID) {
        orders.removeAll { $0.unit == id }
    }

    mutating func noteStop(_ id: UnitID, _ text: String, phase: Int) {
        stops.removeAll { $0.unit == id || $0.phase != phase }
        stops.append(Stop(unit: id, text: text, phase: phase))
    }

    mutating func clearStop(_ id: UnitID) {
        stops.removeAll { $0.unit == id }
    }

    func stop(of id: UnitID, phase: Int) -> Stop? { stops.first { $0.unit == id && $0.phase == phase } }

    mutating func noteFind(_ find: Find) {
        finds.append(find)
    }

    /// At most one find per explorer per turn.
    func found(by id: UnitID, turn: Int) -> Bool { finds.contains { $0.unit == id && $0.turn == turn } }
}

extension GameSession {
    /// Legs one explorer may walk in a phase (each a `moveUnit`; a Scout takes at most 3).
    static let exploreLegsPerPhase = 8

    // MARK: Giving and ending the order

    /// Whether own unit `id` is on the Explore order.
    func isExploring(_ id: UnitID) -> Bool { explore.contains(id) }

    /// Whether the unit may take the order: any own military unit (civilians do not explore).
    func canExplore(_ unit: GameCore.Unit) -> Bool {
        unit.owner == viewer && !unit.type.isCivilian
    }

    /// Whether the Explore tile leads the unit's actions (a recon unit's, or one exploring, whose
    /// likeliest action is Stop) rather than ending them.
    func exploreLeads(_ unit: GameCore.Unit) -> Bool {
        view.rules.unit(unit.type).unitClass == .recon || isExploring(unit.id)
    }

    /// The unit card's Explore tile: gives the order, or ends it.
    func toggleExplore(_ id: UnitID) {
        explore.described = nil
        if isExploring(id) {
            explore.remove(id)
        } else {
            startExploring(id)
        }
    }

    /// Gives own unit `id` the order and takes its first steps now. A march or a rest under way
    /// gives way to it; enemies already in its sight do not end it while they stay there. A
    /// route previewed for it goes (its Move would be another order, ending this one), and so
    /// does the reason its last order ended.
    func startExploring(_ id: UnitID) {
        guard isInputEnabled else {
            show(waitingFor.map { "Waiting for \($0.civName)" } ?? "Not your turn")
            return
        }
        guard let unit = view.unit(id), canExplore(unit) else { return }
        clearPreviews()
        explore.clearStop(id)
        if unit.destination != nil { perform(.cancelOrders(unit: id)) }
        if unit.activity == .sleeping || unit.activity == .fortified || unit.activity == .fortifying {
            perform(.wake(unit: id))
        }
        explore.set(ExploreOrders.Order(unit: id, knownEnemies: view.enemiesInSight(of: id)))
        stepExplorers(only: id)
        // Also when it has not moved: it waits (for foreign units in the way to move on, say).
        if isExploring(id), view.unit(id)?.movesLeft == 0 || explore.order(of: id)?.goal == nil
            || view.unit(id)?.position == unit.position {
            show("\(unit.type.displayName) is exploring")
        }
    }

    /// `perform`'s hook: an order the player gives a unit ends its Explore order, and the line
    /// saying why an earlier one ended goes.
    func exploreHeard(_ command: Command) {
        guard let id = Self.orderedUnit(of: command) else { return }
        explore.clearStop(id)
        if isExploring(id) { explore.remove(id) }
    }

    /// The orders to put in a save's header (`SaveSummary.explorers`).
    var explorersToSave: [SavedExplorer] {
        explore.orders.map { SavedExplorer(unit: $0.unit, knownEnemies: $0.knownEnemies) }
    }

    /// After a load, before play begins: the orders the save's header kept, for own units still
    /// on the map that may take them. The next phase start walks them (a save made in the
    /// viewer's phase was made after this phase's steps); whether one was resting the unit
    /// tells then (the header does not keep it).
    func resumeExploring(_ saved: [SavedExplorer]) {
        let view = self.view
        for record in saved {
            guard let unit = view.unit(record.unit), canExplore(unit) else { continue }
            explore.set(ExploreOrders.Order(unit: record.unit, knownEnemies: record.knownEnemies, resting: nil))
        }
        #if DEBUG
        if !saved.isEmpty { DebugLog.write("Explore resumed for \(explore.orders.map(\.unit.rawValue)) of \(saved.map(\.unit.rawValue))") }
        #endif
    }

    // MARK: Walking

    /// The viewer's phase began: every explorer takes its steps, in unit order.
    func continueExploring() {
        stepExplorers(only: nil)
    }

    /// Steps for each explorer (or only `only`): until it waits (its moves spent, or the way on
    /// opens only next turn), rests or the order ends. After its last leg it is asked once more,
    /// so an enemy that leg brought into sight ends the order now. Another explorer's goal is
    /// claimed: one goes elsewhere while it can. Then what the walk found.
    private func stepExplorers(only: UnitID?) {
        guard isInputEnabled else { return }
        for id in explore.orders.map(\.unit) where only == nil || only == id {
            guard var order = explore.order(of: id) else { continue }
            let before = self.view
            // Only a living explorer's goal is claimed: one killed or captured since (its order
            // goes when this loop comes to it) leaves its goal to the others at once.
            let claimed = explore.orders.filter { $0.unit != id && before.unit($0.unit) != nil }.compactMap(\.goal)
            var ended: ExploreEnd?
            for _ in 0..<Self.exploreLegsPerPhase {
                let view = self.view
                guard isInputEnabled, let unit = view.unit(id) else {
                    if state.outcome == nil, view.unit(id) == nil { ended = .unavailable }
                    break
                }
                let step = view.exploreStep(for: id, knownEnemies: order.knownEnemies, claimed: claimed, goal: order.goal,
                                            resting: order.resting)
                let inSight = view.enemiesInSight(of: id)
                order.knownEnemies.removeAll { !inSight.contains($0) }
                guard case let .move(to, goal, avoiding) = step else {
                    switch step {
                    case let .end(why): ended = why
                    case let .wait(goal):
                        order.goal = goal
                        order.resting = false
                    case let .rest(goal, _):
                        order.goal = goal
                        order.resting = true
                        order.avoiding = nil
                    case .move: break
                    }
                    break
                }
                order.goal = goal
                order.resting = false
                order.avoiding = avoiding
                guard exploreLeg(id, to: to) else {
                    ended = .unavailable
                    break
                }
                guard let after = state.unit(id), after.position != unit.position else { break }
            }
            if let ended {
                explore.remove(id)
                noteExploreEnded(id, ended)
            } else if explore.contains(id) {
                explore.set(order)
            }
            noteExploreFinds(id, since: before)
        }
    }

    /// One leg: the viewer's `moveUnit`, applied and shown as `perform` does, but without the
    /// march's stop notice (a leg cut short by what the walk revealed is planned again at once).
    private func exploreLeg(_ id: UnitID, to hex: HexCoord) -> Bool {
        guard isInputEnabled else { return false }
        do {
            let events = try applyOthers(.moveUnit(unit: id, to: hex), by: viewer)
            stateChanged(events: events.filter {
                if case .moveInterrupted(id, _) = $0.event { false } else { true }
            }, byViewer: true)
            if !isViewerPhase { playOtherPhases() }
            return true
        } catch {
            #if DEBUG
            DebugLog.write("Explore leg of unit \(id.rawValue) to \(hex) refused: \(error)")
            #endif
            return false
        }
    }

    /// The notice for an order that ended (its own kind, so that two never merge into one
    /// line), and the reason on the unit's card for this phase. Enemies in sight (or in the
    /// way) are important when the unit has no moves left to act on them; with moves left it
    /// waits in the attention queue anyway.
    private func noteExploreEnded(_ id: UnitID, _ why: ExploreEnd) {
        let view = self.view
        guard let unit = view.unit(id) else { return }
        let name = unit.type.displayName
        let text: String, image: String, tone: Notice.Tone, place: HexCoord?
        switch why {
        case .unavailable:
            return
        case let .explored(closedLand):
            let closed = closedLand.map { CivText.adjective(of: $0, in: view, civName: civName(of:)) }
            text = closed.isEmpty ? "\(name) has explored all the land it can reach"
                : "\(name) has explored all it can reach: \(Self.list(closed)) land, closed at peace, bars the way"
            (image, tone, place) = ("binoculars.fill", .neutral, unit.position)
        case let .enemyInSight(enemies):
            let seen = enemies.compactMap { view.unit($0) }
            let what = seen.count == 1 ? "an enemy \(seen[0].type.displayName) is in sight" : "\(seen.count) enemy units are in sight"
            text = "\(name) stopped exploring: \(what)"
            (image, tone, place) = ("exclamationmark.triangle.fill", .bad, seen.first?.position ?? unit.position)
        case .enemyReach:
            text = "\(name) stopped exploring: the way on is within enemy reach"
            (image, tone, place) = ("exclamationmark.triangle.fill", .bad, unit.position)
        }
        let danger = if case .explored = why { false } else { true }
        let importance: Notice.Importance = danger && unit.movesLeft == 0 ? .important : .info
        explore.noteStop(id, text, phase: state.phaseCount)
        notices.post([Notice(kind: .explore, text: text, systemImage: image, tone: tone, importance: importance, place: place,
                             subject: .unit(id), turn: view.turn)])
        #if DEBUG
        DebugLog.write("Explore ended for unit \(id.rawValue): \(text)")
        #endif
    }

    /// The best good city site the explorer's walk brought into view (`exploreFinds`), if any:
    /// a notice that says where, with its place (the toast and the log look there). At most one
    /// per explorer per turn, never one near a site announced before.
    private func noteExploreFinds(_ id: UnitID, since before: PlayerView) {
        let view = self.view
        guard let unit = view.unit(id), !explore.found(by: id, turn: view.turn),
              let find = view.exploreFinds(since: before, announced: explore.finds.map(\.site)).first else { return }
        explore.noteFind(ExploreOrders.Find(unit: id, site: find.hex, turn: view.turn))
        let text = Self.findText(find, by: unit, view: view, map: state.map)
        notices.post([Notice(kind: .explore, text: text, systemImage: "star.circle.fill", tone: .good, importance: .info,
                             place: find.hex, subject: .unit(id), turn: view.turn)])
        #if DEBUG
        DebugLog.write("Explore found a site for unit \(id.rawValue) at \(find.hex): \(text)")
        #endif
    }

    /// "Scout found a good city site 6 tiles west of Rome (river, hills)".
    static func findText(_ find: ExploreFind, by unit: GameCore.Unit, view: PlayerView, map: HexMap) -> String {
        let city = view.city(find.city)?.position
        let way = city.flatMap { map.compassPoint(from: $0, to: find.hex) }.map { "\($0.name) of" } ?? "from"
        var site = "\(unit.type.displayName) found a good city site \(find.distance) tile\(find.distance == 1 ? "" : "s") \(way) \(find.cityName)"
        if let facts = view.siteFacts(at: find.hex) {
            let river = view.tile(at: find.hex).map { $0.riverEdges != 0 } ?? false
            let water: String? = facts.freshWater ? (river ? "river" : "lake") : nil
            let traits = [water, facts.coast ? "coast" : nil, facts.hills ? "hills" : nil].compactMap { $0 }
            if !traits.isEmpty { site += " (\(traits.joined(separator: ", ")))" }
        }
        return site
    }

    /// The card's Explore tile was long-pressed.
    func describeExplore(_ id: UnitID) {
        describedAction = nil
        explore.described = id
    }

    /// The badge on an exploring unit's card.
    func exploreBadge(of unit: GameCore.Unit) -> String? {
        isExploring(unit.id) ? "Exploring" : nil
    }

    /// The card's line about the order: where it heads (and whose reach a step away from there
    /// keeps out of), that it rests to heal, or why it ended this phase.
    func exploreHint(of unit: GameCore.Unit) -> (text: String, symbol: String)? {
        if let order = explore.order(of: unit.id) {
            if order.resting == true {
                return ("Exploring · resting to heal, \(unit.hp) HP (on at \(PlayerView.exploreRestHP.until))", "cross.case")
            }
            if let goal = order.goal, goal != unit.position, let point = state.map.compassPoint(from: unit.position, to: goal) {
                let detour = order.avoiding.flatMap(threatName).map { ", keeping out of \($0)" } ?? ""
                return ("Exploring · heading \(point.name)\(detour)", "binoculars")
            }
            return (unit.movesLeft == 0 ? "Exploring · on again next turn" : "Exploring", "binoculars")
        }
        if let stop = explore.stop(of: unit.id, phase: state.phaseCount) {
            return (stop.text, "exclamationmark.triangle")
        }
        return nil
    }

    /// "the Roman Scout's reach", "Karakorum's bombard range", as the viewer knows them.
    private func threatName(_ threat: ExploreThreat) -> String? {
        let view = self.view
        switch threat {
        case let .unit(id):
            guard let enemy = view.unit(id) else { return "an enemy's reach" }
            return "the \(CivText.adjective(of: enemy.owner, in: view, civName: civName(of:))) \(enemy.type.displayName)'s reach"
        case let .city(id):
            guard let city = view.knownCities.first(where: { $0.id == id }) else { return "an enemy city's bombard range" }
            return "\(city.name)'s bombard range"
        }
    }

    // MARK: Helpers

    /// The unit a command gives an order to.
    nonisolated static func orderedUnit(of command: Command) -> UnitID? {
        switch command {
        case let .moveUnit(unit, _), let .cancelOrders(unit), let .foundCity(unit), let .buildImprovement(unit, _),
             let .fortify(unit), let .sleep(unit), let .wake(unit), let .skip(unit), let .disband(unit), let .attack(unit, _):
            unit
        default:
            nil
        }
    }

    /// "Mongol", "Mongol and Malian", "Mongol, Malian and Inca".
    nonisolated static func list(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
    }
}

// MARK: - The unit card's Explore tile, line and description

/// The Explore tile of a military unit's action bar (M1 §16): Explore, or Stop while it
/// explores; a long-press describes it.
struct ExploreTile: View {
    let session: GameSession
    let unit: GameCore.Unit
    var compact = false
    @State private var pressed = false

    var body: some View {
        let info = ExploreText.tile(exploring: session.isExploring(unit.id),
                                    tribalVillageTurns: session.state.rules.tribalVillages?.seekTurns)
        Label(info.title, systemImage: info.symbol)
            .actionTile(pressed: pressed, lit: session.isInputEnabled, compact: compact, fill: true)
            .onTapGesture { session.toggleExplore(unit.id) }
            .onLongPressGesture(minimumDuration: 0.4, perform: { session.describeExplore(unit.id) },
                                onPressingChanged: { pressed = $0 })
            .onChange(of: session.describedAction) { _, described in
                if described != nil { session.explore.described = nil }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(info.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(info.help)
            .accessibilityAction { session.toggleExplore(unit.id) }
            .accessibilityAction(named: "Describe") { session.describeExplore(unit.id) }
    }
}

/// The card's line about the order (where it heads, or why it ended this phase).
struct ExploreRow: View {
    let session: GameSession
    let unit: GameCore.Unit

    var body: some View {
        if let hint = session.exploreHint(of: unit) {
            Hint(systemImage: hint.symbol, text: hint.text)
        }
    }
}

/// The Explore tile's description (a long-press), as the action bar's description line.
struct ExploreDescription: View {
    let session: GameSession
    let unit: GameCore.Unit

    var body: some View {
        let info = ExploreText.tile(exploring: session.isExploring(unit.id),
                                    tribalVillageTurns: session.state.rules.tribalVillages?.seekTurns)
        HStack(alignment: .top, spacing: HUD.Space.s) {
            Image(systemName: info.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(HUD.inkSoft)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(info.title).font(HUD.title(.caption)))  \(info.help)").font(HUD.body(.caption))
                if !session.isInputEnabled {
                    Text("Not now: it is not your turn.").font(HUD.body(.caption).weight(.semibold)).foregroundStyle(HUD.danger)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HUD.Space.s)
        .padding(.vertical, HUD.Space.xs + 2)
        .parchmentWell()
        .onTapGesture { session.explore.described = nil }
    }
}

enum ExploreText {
    /// The Explore tile's title, symbol and help. `tribalVillageTurns`: how many turns' moves
    /// away a tribal village the player knows of may lie for the explorer to make for it first
    /// (the rules' `seekTurns`); nil in rules without tribal villages.
    static func tile(exploring: Bool, tribalVillageTurns: Int? = nil) -> (title: String, symbol: String, help: String) {
        guard !exploring else { return ("Stop", "binoculars", "Stop exploring: the unit waits for orders.") }
        guard let turns = tribalVillageTurns, turns > 0 else {
            return ("Explore", "binoculars.fill",
                    "Walks on its own every turn toward land you have not seen, never ending a turn where an enemy in sight or a known "
                    + "enemy city's bombard could strike it; rests to heal when badly hurt, and tells you of good city sites it finds. "
                    + "It stops when nothing it can reach is left unexplored, when the way on lies only within enemy reach, when you "
                    + "give it another order, or when an enemy comes into sight.")
        }
        return ("Explore", "binoculars.fill",
                "Walks on its own every turn toward land you have not seen, first to any tribal village you know of within "
                + "\(turnsText(turns)) of it, never ending a turn where an enemy in sight or a known enemy city's bombard could strike "
                + "it; rests to heal when badly hurt, and tells you of good city sites it finds. It stops when nothing it can reach is "
                + "left unexplored and no tribal village you know of is in reach, when the way on lies only within enemy reach, when "
                + "you give it another order, or when an enemy comes into sight.")
    }
}
