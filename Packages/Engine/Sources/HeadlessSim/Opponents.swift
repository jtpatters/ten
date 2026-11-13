import GameCore

// Stand-ins for a human in player 0's seat (`--p0`), to see how the AI fares against players
// who do not play like it (ai-2 brief: "the AI must defend sensibly and still attack a player who
// turtles"). Both decide from `state.view(for:)` and act through `GameEngine.apply`, like a human.
//
//   scripted  `DebugTools.scriptedCommands`: founds cities, keeps queues full, improves tiles and
//             walks units to random tiles nearby (a careless builder)
//   turtle    `TurtlePlayer`: up to four cities close together, Walls and an Archer garrison in
//             every city, extra defenders fortified next to them, never declares war, answers
//             any peace proposal with yes and proposes peace whenever it may; it shoots and
//             bombards whatever comes in range and attacks out only with good odds; its Scout
//             explores like the newbie's for the first 30 turns (p3b), then defends
//   newbie    `NewPlayer` (p3 early-game): a sensible new player — capital in place, 3–4 cities
//             by turn 50, a couple of Warriors and Archers, Builders, Pottery/Archery/Bronze
//             Working early, explores with its Scout, never declares war
//   shadow    `NewPlayer` whose Scout harasses the AI's Settlers instead (p3b ai-settler-escort):
//             it follows any it sees, and waits by the AI's first city otherwise

enum Opponent: String { case ai, scripted, turtle, newbie, shadow }

/// The commands of one turtle phase for the current player (the phase is not ended). Planned
/// command by command against the live state, so each sees the effects of the ones before it.
struct TurtlePlayer {
    static let maxCities = 4
    static let research: [TechID] = ["pottery", "mining", "masonry", "animalHusbandry", "archery", "bronzeWorking",
                                     "writing", "irrigation", "currency", "sailing"]
    /// p3b ai-turtle-scouts: its Scout explores until this turn (a turtle still looks around,
    /// so the AI meets it as early as it would meet a newbie), then defends like any unit.
    static let exploreTurns = 30

    let me: PlayerID
    var state: GameState
    /// The commands applied, each with its events.
    var steps: [(command: Command, events: [EventRecord])] = []

    init(state: GameState) {
        self.state = state
        me = state.currentPlayer
    }

    var view: PlayerView { state.view(for: me) }
    var live: Bool { state.outcome == nil && state.currentPlayer == me }

    @discardableResult
    mutating func issue(_ command: Command) -> Bool {
        guard live else { return false }
        do {
            steps.append((command, try GameEngine.apply(command, by: me, to: &state)))
            return true
        } catch {
            return false
        }
    }

    mutating func play() {
        guard live else { return }
        diplomacy()
        if view.me.researching == nil, let tech = Self.research.first(where: { !view.me.knows($0) }) {
            issue(.setResearch(tech: tech))
        }
        shoot()
        for id in view.units.map(\.id) {
            guard live, let unit = view.unit(id) else { continue }
            switch unit.type {
            case .settler: settle(unit)
            case .builder: improve(unit)
            case .scout where state.turn <= Self.exploreTurns: explore(unit)
            default: defend(unit)
            }
        }
        produce()
    }

    /// The newbie's exploring step (`frontierStep`); with nothing left to explore, the Scout
    /// defends.
    mutating func explore(_ unit: Unit) {
        guard unit.movesLeft > 0 || unit.destination != nil else { return }
        switch frontierStep(unit, view) {
        case .going: return
        case let .move(goal): issue(.moveUnit(unit: unit.id, to: goal))
        case .none: defend(unit)
        }
    }

    mutating func diplomacy() {
        for proposer in view.peaceProposals { issue(.respondToPeace(from: proposer, accept: true)) }
        for other in view.players where other.id != me && other.isAlive && view.isAtWar(with: other.id) {
            if view.peaceProblem(to: other.id) == nil { issue(.proposePeace(to: other.id)) }
        }
    }

    /// Cities bombard, then Archers fire: kills first, else the lowest HP left.
    mutating func shoot() {
        for id in view.cities.map(\.id) {
            if let target = pick(view.cityAttackOptions(for: id), attacker: .city(id)) { issue(.cityAttack(city: id, target: target.target)) }
        }
        for id in view.units.filter({ state.rules.unit($0.type).isRanged }).map(\.id) {
            guard let unit = view.unit(id), unit.movesLeft > 0 else { continue }
            let inPlace = view.attackOptions(for: id).filter { $0.from == unit.position }
            if let target = pick(inPlace, attacker: .unit(id)) { issue(.attack(unit: id, target: target.target)) }
        }
    }

    func pick(_ options: [AttackOption], attacker: Combatant) -> AttackOption? {
        var best: (kill: Bool, left: Int, option: AttackOption)?
        for option in options {
            guard let p = view.combatPreview(attacker: attacker, target: option.target, from: option.from) else { continue }
            let hp: Int
            switch option.defender {
            case let .unit(u): hp = view.unit(u)?.hp ?? 100
            case .city: hp = view.knownCity(at: option.target).map { $0.hp + $0.wallHP } ?? 300
            }
            let kill = p.killChance(atLeast: 50)
            let left = max(0, hp - p.meanDealt)
            if let b = best, (b.kill ? 0 : 1, b.left) <= (kill ? 0 : 1, left) { continue }
            best = (kill, left, option)
        }
        return best?.option
    }

    /// The first city where the Settler stands; later ones on the best site within 6 tiles of
    /// the capital.
    mutating func settle(_ unit: Unit) {
        let v = view
        if v.cities.isEmpty {
            if v.canFoundCity(at: unit.position) { issue(.foundCity(unit: unit.id)) }
            return
        }
        guard let capital = v.me.capital.flatMap({ v.city($0) }) else { return }
        var best: (score: Int, hex: HexCoord)?
        for hex in v.coords(within: 6, of: capital.position) where v.canFoundCity(at: hex) {
            let s = v.settleScore(at: hex)
            if s < 50 { continue }
            if let b = best, b.score >= s { continue }
            best = (s, hex)
        }
        guard let best else {
            if unit.activity != .sleeping { issue(.sleep(unit: unit.id)) }
            return
        }
        if best.hex == unit.position {
            issue(.foundCity(unit: unit.id))
        } else if unit.movesLeft > 0 {
            issue(.moveUnit(unit: unit.id, to: best.hex))
        }
    }

    /// The nearest worked, unimproved tile that takes an improvement.
    mutating func improve(_ unit: Unit) {
        let v = view
        let worked = v.cities.flatMap(\.workedTiles)
        func kind(_ hex: HexCoord) -> Improvement? {
            Improvement.allCases.first { v.aiImprovementProblem($0, at: hex) == nil }
        }
        if worked.contains(unit.position), let k = kind(unit.position), unit.movesLeft > 0 {
            issue(.buildImprovement(unit: unit.id, improvement: k))
            return
        }
        let goal = worked.filter { kind($0) != nil }.min { (v.distance($0, unit.position), v.index(of: $0)!) < (v.distance($1, unit.position), v.index(of: $1)!) }
        if let goal, unit.movesLeft > 0 { issue(.moveUnit(unit: unit.id, to: goal)) }
    }

    /// Military units: garrison a city without one, else stand fortified next to the city with
    /// the fewest defenders around it; melee units next to an enemy attack it with good odds.
    mutating func defend(_ unit: Unit) {
        let v = view
        guard unit.movesLeft > 0 else { return }
        if !state.rules.unit(unit.type).isRanged, let attack = v.attackOptions(for: unit.id).first(where: { o in
            guard o.from == unit.position, case .unit = o.defender,
                  let p = v.combatPreview(attacker: .unit(unit.id), target: o.target, from: o.from) else { return false }
            return p.killChance(atLeast: 50) || p.meanDealt > 2 * p.meanTaken
        }) {
            issue(.attack(unit: unit.id, target: attack.target))
            return
        }
        let cities = v.cities
        if cities.contains(where: { $0.position == unit.position }) {
            if unit.activity != .fortified && unit.activity != .fortifying { issue(.fortify(unit: unit.id)) }
            return
        }
        let military = v.units.filter { !$0.type.isCivilian }
        if let empty = cities.filter({ c in !military.contains { $0.position == c.position } })
            .min(by: { v.distance($0.position, unit.position) < v.distance($1.position, unit.position) }) {
            issue(.moveUnit(unit: unit.id, to: empty.position))
            return
        }
        // Next to the city with the fewest defenders around it (ties: nearer, lower id).
        guard let city = cities.min(by: { a, b in
            let na = military.filter { v.distance($0.position, a.position) <= 1 }.count
            let nb = military.filter { v.distance($0.position, b.position) <= 1 }.count
            return (na, v.distance(a.position, unit.position), a.id.rawValue) < (nb, v.distance(b.position, unit.position), b.id.rawValue)
        }) else { return }
        if v.distance(unit.position, city.position) == 1 {
            if unit.activity != .fortified && unit.activity != .fortifying { issue(.fortify(unit: unit.id)) }
            return
        }
        for spot in v.neighbors(of: city.position) where state.canEnd(unit.type, owner: me, at: spot, ignoring: unit.id) {
            if issue(.moveUnit(unit: unit.id, to: spot)) { return }
        }
        if unit.activity != .fortified && unit.activity != .fortifying { issue(.fortify(unit: unit.id)) }
    }

    /// Queues: a garrison (Archer once known), Walls, Monument, Settlers up to four cities, a
    /// Builder, Granary, Library, a second defender, Market, then Archers.
    mutating func produce() {
        let v = view
        let rules = state.rules
        let settlers = v.units.filter { $0.type == .settler }.count
        let builders = v.units.filter { $0.type == .builder }.count
        var queuedSettlers = 0, queuedBuilders = 0
        for city in v.cities {
            guard live else { return }
            let military = v.units.filter { !$0.type.isCivilian }
            let defender: UnitType = v.me.knows("archery") ? .archer : .warrior
            var wanted: [ProductionItem] = []
            if !military.contains(where: { $0.position == city.position }) { wanted.append(.unit(defender)) }
            wanted += [.building("walls"), .building("monument")]
            if v.cities.count + settlers + queuedSettlers < Self.maxCities, city.population >= 2 {
                wanted.append(.unit(.settler))
            }
            if builders + queuedBuilders < (v.cities.count + 1) / 2 { wanted.append(.unit(.builder)) }
            wanted += [.building("granary"), .building("library")]
            if military.filter({ v.distance($0.position, city.position) <= 1 }).count < 2 { wanted.append(.unit(defender)) }
            wanted += [.building("market"), .unit(defender)]
            let item = wanted.first { item in
                if case let .building(b) = item {
                    guard let def = rules.building(b), !city.has(b) else { return false }
                    return def.tech.map(v.me.knows) ?? true
                }
                if case let .unit(t) = item { return rules.unit(t).tech.map(v.me.knows) ?? true }
                return false
            }
            guard let item else { continue }
            if item == .unit(.settler) { queuedSettlers += 1 }
            if item == .unit(.builder) { queuedBuilders += 1 }
            if city.queue.first?.item != item { issue(.setQueue(city: city.id, items: [item])) }
        }
    }
}
