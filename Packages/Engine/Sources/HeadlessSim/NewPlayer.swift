import GameCore

// p3 early-game: a third stand-in for a human in player 0's seat (`--p0 newbie`), one that
// plays like a sensible new player rather than a careless builder (`scripted`) or a turtle:
//
//  - founds the capital where the Settler starts, on turn 1;
//  - grows to 3–4 cities by turn 50: Settlers from cities of population 2+, to the best site
//    within 6 tiles of an own city (settle score ≥ 55, a little less for a farther walk);
//  - researches Pottery, Animal Husbandry, Archery, Mining, Bronze Working early, then
//    Writing, Irrigation, Masonry, Currency, Sailing;
//  - keeps a garrison in every city and a couple of Warriors (Spearmen once known) and Archers;
//  - sends Builders to good worked tiles (Farm by fresh water, Mine, Pasture, Farm);
//  - explores with its Scout (tapping the nearest unexplored edge, like a player would) and
//    parks it at home when nothing is left; p3g: a known tribal village within the rules'
//    `seekTurns` turns' moves comes first, and before it parks, any known one it can reach
//    (`frontierStep`, which the turtle shares);
//  - with `rush` (`--newbie-rush`, p3g G13): its capital builds a second Scout first;
//  - never declares war; accepts every peace offer and asks for peace whenever it may;
//  - with `shadow` (`--p0 shadow`, p3b ai-settler-escort): its Scout harasses the AI's Settlers
//    instead of exploring once it knows an AI city — it keeps within 2 tiles of any AI Settler it
//    sees, next to it and ahead of it (away from its owner's cities) when it can, and otherwise
//    waits as near the AI's first known city as it may stand (a human who follows or blocks the
//    AI's Settlers again and again);
//  - at war: cities bombard, Archers shoot, melee units attack next to them with good odds,
//    wounded units go home, threatened cities get a second defender (Walls once known), and a
//    city under attack buys a defender when the treasury allows.
//
// Like a human it decides from `state.view(for:)` and acts through `GameEngine.apply`.

/// What a Scout exploring like a player does now (the newbie's, and the turtle's early on).
enum FrontierStep {
    /// It walks to a frontier tile or a known tribal village already: it goes on.
    case going
    /// It taps this tile: a frontier tile, or a known tribal village.
    case move(HexCoord)
    /// Nothing left it can explore, and no known tribal village it can reach.
    case none
}

/// A Scout exploring like a player tapping the nearest unexplored edge: one walking to a
/// frontier tile goes on; else it taps the frontier tile it reaches cheapest (ties: lower index).
///
/// p3g (M1 §7.7, §17; DESIGN §5.3): a known tribal village comes first, as a player who sees
/// one nearby walks to it. In order:
///  1. one walking to a known tribal village goes on;
///  2. with moves left, it taps the known tribal village it reaches cheapest within the rules'
///     `seekTurns` turns' moves (movement field cost above 0 and at most `seekTurns` × its full
///     moves; ties: lower index), even while it walks to a frontier tile;
///  3. the frontier, as before;
///  4. with no frontier tap left, with moves left, any known tribal village it can reach
///     (cheapest; ties: lower index), before nothing.
/// It knows them only from memory (`knownTribalVillages`), and leaves out those another own unit
/// heads for (its destination), so that a second Scout (`--newbie-rush`) seeks another one.
/// None known (always so without the rules section) or `seekTurns` 0: the step is as before.
func frontierStep(_ unit: Unit, _ v: PlayerView) -> FrontierStep {
    let seek = v.rules.tribalVillages?.seekTurns ?? 0
    var villages: [Int] = []
    if seek > 0, !v.knownTribalVillages.isEmpty {
        if let destination = unit.destination, v.isKnownTribalVillage(destination) { return .going }
        let heading = v.units.compactMap { $0.id == unit.id ? nil : $0.destination.flatMap { v.index(of: $0) } }
        villages = v.knownTribalVillages.map(Int.init).filter { !heading.contains($0) }
    }
    var computed: [Int32]?
    func field() -> [Int32] {
        if let computed { return computed }
        let f = v.movementField(for: unit.id)
        computed = f
        return f
    }
    /// The tribal village it reaches cheapest within `limit` movement points (nil: any).
    func village(within limit: Int?) -> HexCoord? {
        guard !villages.isEmpty, unit.movesLeft > 0 else { return nil }
        let f = field()
        var best: (cost: Int32, tile: Int)?
        for t in villages where f.indices.contains(t) && f[t] > 0 && limit.map({ Int(f[t]) <= $0 }) ?? true {
            // In tile order: a tie keeps the lower index.
            if let best, best.cost <= f[t] { continue }
            best = (f[t], t)
        }
        return best.map { v.coord(at: $0.tile) }
    }
    if let goal = village(within: seek * max(1, v.rules.unit(unit.type).moves) * v.rules.movePoints) { return .move(goal) }
    let frontier = v.aiFrontier()
    if let destination = unit.destination, let d = v.index(of: destination), frontier.contains(d) { return .going }
    if !frontier.isEmpty, unit.movesLeft > 0 {
        let costs = field()
        if let goal = frontier.filter({ costs[$0] > 0 }).min(by: { (costs[$0], $0) < (costs[$1], $1) }) {
            return .move(v.coord(at: goal))
        }
    }
    if let goal = village(within: nil) { return .move(goal) }
    return .none
}

struct NewPlayer {
    static let maxCities = 4
    static let minSiteScore = 55
    static let siteRadius = 6
    static let research: [TechID] = ["pottery", "animalHusbandry", "archery", "mining", "bronzeWorking",
                                     "writing", "irrigation", "masonry", "currency", "sailing"]

    let me: PlayerID
    var state: GameState
    var steps: [(command: Command, events: [EventRecord])] = []
    /// Cities a unit was sent to garrison this phase.
    var garrisonSent: [CityID] = []
    /// Sites chosen by Settlers this phase (tile indices).
    var chosenSites: [Int] = []
    /// p3b: the Scout shadows the AI's Settlers (`--p0 shadow`).
    let shadow: Bool
    /// p3g: the capital builds a second Scout first (`--newbie-rush`, DESIGN §5.3, G13).
    let rush: Bool

    init(state: GameState, shadow: Bool = false, rush: Bool = false) {
        self.state = state
        me = state.currentPlayer
        self.shadow = shadow
        self.rush = rush
    }

    var view: PlayerView { state.view(for: me) }
    var live: Bool { state.outcome == nil && state.currentPlayer == me }
    var rules: Ruleset { state.rules }

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

    var atWar: Bool { view.players.contains { $0.id != me && $0.isAlive && view.isAtWar(with: $0.id) } }

    func isFighter(_ type: UnitType) -> Bool { !type.isCivilian && rules.unit(type).unitClass != .recon }
    func isRanged(_ type: UnitType) -> Bool { rules.unit(type).isRanged }

    /// Visible enemy military units (at war).
    func enemies(_ v: PlayerView) -> [Unit] {
        v.visibleForeignUnits.filter { !$0.type.isCivilian && v.isAtWar(with: $0.owner) }
    }

    mutating func play() {
        guard live else { return }
        diplomacy()
        if view.me.researching == nil, let tech = Self.research.first(where: { !view.me.knows($0) }) {
            issue(.setResearch(tech: tech))
        }
        if atWar { shoot() }
        for id in view.units.map(\.id) {
            guard live, let unit = view.unit(id) else { continue }
            switch unit.type {
            case .settler: settle(unit)
            case .builder: improve(unit)
            case .scout: explore(unit)
            default: soldier(unit)
            }
        }
        produce()
    }

    // MARK: Diplomacy

    mutating func diplomacy() {
        for proposer in view.peaceProposals { issue(.respondToPeace(from: proposer, accept: true)) }
        for other in view.players where other.id != me && other.isAlive && view.isAtWar(with: other.id) {
            if view.peaceProblem(to: other.id) == nil { issue(.proposePeace(to: other.id)) }
        }
    }

    // MARK: Fighting

    /// Cities bombard, then Archers fire from where they stand: kills first, else the target
    /// left with the lowest HP.
    mutating func shoot() {
        for id in view.cities.map(\.id) {
            if let target = pick(view.cityAttackOptions(for: id), attacker: .city(id)) { issue(.cityAttack(city: id, target: target.target)) }
        }
        for id in view.units.filter({ isRanged($0.type) }).map(\.id) {
            guard live, let unit = view.unit(id), unit.movesLeft > 0 else { continue }
            let inPlace = view.attackOptions(for: id).filter { $0.from == unit.position }
            if let target = pick(inPlace, attacker: .unit(id)) { issue(.attack(unit: id, target: target.target)) }
        }
    }

    func pick(_ options: [AttackOption], attacker: Combatant) -> AttackOption? {
        let v = view
        var best: (kill: Bool, left: Int, option: AttackOption)?
        for option in options {
            guard let p = v.combatPreview(attacker: attacker, target: option.target, from: option.from) else { continue }
            let hp: Int
            switch option.defender {
            case let .unit(u): hp = v.unit(u)?.hp ?? 100
            case .city: hp = v.knownCity(at: option.target).map { $0.hp + $0.wallHP } ?? 300
            }
            let kill = p.killChance(atLeast: 50)
            let left = max(0, hp - p.meanDealt)
            if let b = best, (b.kill ? 0 : 1, b.left) <= (kill ? 0 : 1, left) { continue }
            best = (kill, left, option)
        }
        return best?.option
    }

    /// Military units: wounded ones go home; at war, melee units attack an adjacent enemy unit
    /// with good odds; garrisons stay; others garrison an empty city, else stand fortified next
    /// to the city nearest the rival (the border city).
    mutating func soldier(_ unit: Unit) {
        var v = view
        guard unit.movesLeft > 0 else { return }
        let cities = v.cities
        let onCity = cities.first { $0.position == unit.position }
        if atWar, !isRanged(unit.type), let attack = v.attackOptions(for: unit.id).first(where: { o in
            guard o.from == unit.position, case .unit = o.defender,
                  let p = v.combatPreview(attacker: .unit(unit.id), target: o.target, from: o.from) else { return false }
            return p.killChance(atLeast: 50) || 2 * p.meanDealt > 3 * p.meanTaken
        }) {
            issue(.attack(unit: unit.id, target: attack.target))
            return
        }
        v = view
        // The garrison: the first military unit on a city's tile stays there.
        if let city = onCity, v.units.first(where: { !$0.type.isCivilian && $0.position == city.position })?.id == unit.id {
            if unit.activity != .fortified && unit.activity != .fortifying { issue(.fortify(unit: unit.id)) }
            return
        }
        // Wounded: home to heal.
        if unit.hp < 50 {
            if onCity != nil || v.knownTerritory[v.index(of: unit.position)!] == UInt8(me.rawValue + 1) {
                if unit.activity != .fortified && unit.activity != .fortifying { issue(.fortify(unit: unit.id)) }
            } else if let home = cities.min(by: { v.distance($0.position, unit.position) < v.distance($1.position, unit.position) }) {
                issue(.moveUnit(unit: unit.id, to: home.position))
            }
            return
        }
        // An empty city gets the nearest free fighter.
        let military = v.units.filter { !$0.type.isCivilian && rules.unit($0.type).unitClass != .recon }
        if let empty = cities.filter({ c in !military.contains { $0.position == c.position } && !garrisonSent.contains(c.id) })
            .min(by: { v.distance($0.position, unit.position) < v.distance($1.position, unit.position) }), isFighter(unit.type) {
            garrisonSent.append(empty.id)
            if unit.destination != empty.position { issue(.moveUnit(unit: unit.id, to: empty.position)) }
            return
        }
        // Next to the border city: the own city nearest a known foreign city (else the capital);
        // at war, the city nearest a visible enemy.
        guard let city = borderCity(v) else { return }
        if v.distance(unit.position, city.position) == 1 {
            if unit.activity != .fortified && unit.activity != .fortifying { issue(.fortify(unit: unit.id)) }
            return
        }
        if let destination = unit.destination, v.distance(destination, city.position) == 1 { return }
        let spots = v.neighbors(of: city.position).filter { state.canEnd(unit.type, owner: me, at: $0, ignoring: unit.id) }
            .sorted { v.distance($0, unit.position) < v.distance($1, unit.position) }
        for spot in spots.prefix(3) where issue(.moveUnit(unit: unit.id, to: spot)) { return }
        if unit.activity != .fortified && unit.activity != .fortifying { issue(.fortify(unit: unit.id)) }
    }

    func borderCity(_ v: PlayerView) -> City? {
        let cities = v.cities
        guard !cities.isEmpty else { return nil }
        let threats = enemies(v).map(\.position)
        let anchors = threats.isEmpty ? v.knownCities.filter { $0.owner != me }.map(\.position) : threats
        guard !anchors.isEmpty else { return v.me.capital.flatMap { v.city($0) } ?? cities[0] }
        return cities.min { a, b in
            let da = anchors.map { v.distance($0, a.position) }.min()!, db = anchors.map { v.distance($0, b.position) }.min()!
            return (da, a.id.rawValue) < (db, b.id.rawValue)
        }
    }

    // MARK: Settlers

    mutating func settle(_ unit: Unit) {
        let v = view
        if v.cities.isEmpty {
            if v.canFoundCity(at: unit.position) {
                issue(.foundCity(unit: unit.id))
            } else if let next = v.neighbors(of: unit.position).first(where: { v.canFoundCity(at: $0) }) {
                issue(.moveUnit(unit: unit.id, to: next))
            }
            return
        }
        guard let here = v.index(of: unit.position) else { return }
        // Keep walking to a chosen site while it is still good.
        if let destination = unit.destination, let d = v.index(of: destination), siteValue(d, v) != nil {
            chosenSites.append(d)
            return
        }
        if let value = siteValue(here, v), value >= Self.minSiteScore, !chosenSites.contains(here) {
            issue(.foundCity(unit: unit.id))
            return
        }
        let field = v.movementField(for: unit.id, limit: v.rules.points(16))
        var best: (value: Int, tile: Int)?
        for t in candidateSites(v) where !chosenSites.contains(where: { v.aiDistance($0, t) <= 3 }) {
            guard field.indices.contains(t), field[t] >= 0, let score = siteValue(t, v) else { continue }
            let value = score - Int(field[t])
            if let b = best, (b.value, -b.tile) >= (value, -t) { continue }
            best = (value, t)
        }
        guard let best else {
            if unit.activity != .sleeping { issue(.sleep(unit: unit.id)) }
            return
        }
        chosenSites.append(best.tile)
        if best.tile == here {
            issue(.foundCity(unit: unit.id))
        } else {
            issue(.moveUnit(unit: unit.id, to: v.coord(at: best.tile)))
        }
    }

    /// Foundable tiles within siteRadius of an own city.
    func candidateSites(_ v: PlayerView) -> [Int] {
        var seen = [Bool](repeating: false, count: v.tileCount)
        var result: [Int] = []
        for city in v.cities {
            guard let c = v.index(of: city.position) else { continue }
            for t in v.aiTiles(within: Self.siteRadius, of: c) where !seen[t] {
                seen[t] = true
                if siteValue(t, v) != nil { result.append(t) }
            }
        }
        return result.sorted()
    }

    /// A site's score when it is a good one: foundable, score ≥ minSiteScore, and (at war) no
    /// visible enemy within 2.
    func siteValue(_ t: Int, _ v: PlayerView) -> Int? {
        let hex = v.coord(at: t)
        guard v.canFoundCity(at: hex) else { return nil }
        let score = v.settleScore(at: hex)
        guard score >= Self.minSiteScore else { return nil }
        if enemies(v).contains(where: { v.distance($0.position, hex) <= 2 }) { return nil }
        return score
    }

    // MARK: Builders

    /// The best tile to improve (Farm by fresh water, Mine, Pasture, then Farm), worked tiles
    /// first, nearest first: own tiles within 2 of an own city, as a player looks at the land
    /// around their cities.
    mutating func improve(_ unit: Unit) {
        let v = view
        guard unit.movesLeft > 0 else { return }
        func best(_ hex: HexCoord) -> (Improvement, Int)? {
            let farm = v.aiImprovementProblem(.farm, at: hex) == nil
            if farm, v.aiHasFreshWater(at: hex) { return (.farm, 0) }
            if v.aiImprovementProblem(.mine, at: hex) == nil { return (.mine, 1) }
            if v.aiImprovementProblem(.pasture, at: hex) == nil { return (.pasture, 2) }
            if farm { return (.farm, 3) }
            return nil
        }
        let tiles = improvableTiles(v)
        let worked = v.cities.flatMap(\.workedTiles)
        if tiles.contains(unit.position), let (kind, _) = best(unit.position) {
            issue(.buildImprovement(unit: unit.id, improvement: kind))
            return
        }
        let goal = tiles.compactMap { hex in best(hex).map { (hex, (worked.contains(hex) ? 0 : 4) + $0.1) } }
            .min { (a, b) in (a.1, v.distance(a.0, unit.position), v.index(of: a.0)!) < (b.1, v.distance(b.0, unit.position), v.index(of: b.0)!) }
        if let goal {
            if unit.destination != goal.0 { issue(.moveUnit(unit: unit.id, to: goal.0)) }
        } else if unit.activity != .sleeping {
            issue(.sleep(unit: unit.id))
        }
    }

    /// Own tiles within 2 of an own city that take an improvement now.
    func improvableTiles(_ v: PlayerView) -> [HexCoord] {
        var result: [HexCoord] = []
        for city in v.cities {
            for hex in v.coords(within: 2, of: city.position) where !result.contains(hex) {
                if [Improvement.farm, .mine, .pasture].contains(where: { v.aiImprovementProblem($0, at: hex) == nil }) { result.append(hex) }
            }
        }
        return result
    }

    // MARK: Scouts

    /// Taps the cheapest frontier tile and lets the Scout walk there (`frontierStep`); with
    /// nothing left to explore, it goes home and sleeps next to the capital.
    mutating func explore(_ unit: Unit) {
        let v = view
        if shadow, unit.movesLeft > 0, harass(unit) { return }
        guard unit.movesLeft > 0 || unit.destination != nil else { return }
        switch frontierStep(unit, v) {
        case .going: return
        case let .move(goal):
            issue(.moveUnit(unit: unit.id, to: goal))
            return
        case .none: break
        }
        guard unit.movesLeft > 0, let capital = v.me.capital.flatMap({ v.city($0) }) else { return }
        if v.distance(unit.position, capital.position) <= 1, unit.position != capital.position {
            if unit.activity != .sleeping { issue(.sleep(unit: unit.id)) }
            return
        }
        for spot in v.neighbors(of: capital.position) where state.canEnd(unit.type, owner: me, at: spot, ignoring: unit.id) {
            if issue(.moveUnit(unit: unit.id, to: spot)) { return }
        }
        if unit.activity != .sleeping { issue(.sleep(unit: unit.id)) }
    }

    /// `shadow`: the Scout goes within 2 tiles of the nearest AI Settler it sees (ties: lower
    /// id) — the reachable tile nearest it, then farthest from its owner's known cities, then
    /// the lower index — or, with none in sight, as near the AI's first known city as it can
    /// get. Returns whether it had a target (an AI city or Settler known).
    mutating func harass(_ unit: Unit) -> Bool {
        let v = view
        let settlers = v.visibleForeignUnits.filter { $0.type == .settler }
        let field = v.movementField(for: unit.id)
        func goTo(_ tiles: [Int], key: (Int) -> [Int]) -> Bool {
            let keys = tiles.map(key)
            guard let i = keys.indices.min(by: { keys[$0].lexicographicallyPrecedes(keys[$1]) }) else { return false }
            let goal = v.coord(at: tiles[i])
            if goal != unit.position, unit.destination != goal { issue(.moveUnit(unit: unit.id, to: goal)) }
            return true
        }
        if let settler = settlers.min(by: { (v.distance($0.position, unit.position), $0.id) < (v.distance($1.position, unit.position), $1.id) }) {
            let home = v.knownCities.filter { $0.owner == settler.owner }.map(\.position)
            let reach = (0..<field.count).filter { t in
                field[t] >= 0 && (field[t] == 0 || Int(field[t]) <= unit.movesLeft) && (1...2).contains(v.distance(v.coord(at: t), settler.position))
            }
            if goTo(reach, key: { t in
                let hex = v.coord(at: t)
                return [v.distance(hex, settler.position), -(home.map { v.distance($0, hex) }.min() ?? 0), t]
            }) { return true }
            // Out of reach this phase: toward it.
            let near = (0..<field.count).filter { field[$0] > 0 && v.distance(v.coord(at: $0), settler.position) <= 2 }
            if goTo(near, key: { [Int(field[$0]), $0] }) { return true }
        }
        guard let city = v.knownCities.filter({ $0.owner != me }).min(by: { $0.id < $1.id }) else { return false }
        let options = (0..<field.count).filter { field[$0] >= 0 }
        return goTo(options, key: { t in [v.distance(v.coord(at: t), city.position), Int(field[t]), t] })
    }

    // MARK: Production

    /// Each city keeps one item queued (plus one that can complete when the first would wait),
    /// changed only when it is no longer wanted or a defender is urgent: a garrison; a second
    /// defender (and Walls) when an enemy is near at war; Settlers up to maxCities; Builders
    /// (one per two cities) while worked tiles lack improvements; two Warriors/Spearmen and
    /// two Archers; Monument, Granary, Library, Market; then Archers.
    mutating func produce() {
        let v0 = view
        var settlers = v0.units.filter { $0.type == .settler }.count
        var builders = v0.units.filter { $0.type == .builder }.count
        var line = v0.units.filter { rules.unit($0.type).unitClass == .melee || rules.unit($0.type).unitClass == .antiCavalry }.count
        var archers = v0.units.filter { isRanged($0.type) }.count
        let goodSite = !candidateSites(v0).isEmpty
        for id in v0.cities.map(\.id) {
            let v = view
            guard live, let city = v.city(id) else { continue }
            let military = v.units.filter { isFighter($0.type) }
            let archer: UnitType? = v.me.knows("archery") ? .archer : nil
            let melee: UnitType = v.me.knows("bronzeWorking") ? .spearman : .warrior
            let near = enemies(v).contains { v.distance($0.position, city.position) <= 3 }
            var urgent: [ProductionItem] = []
            var wanted: [ProductionItem] = []
            let garrisoned = military.contains { $0.position == city.position } || garrisonSent.contains(city.id)
            if !garrisoned { urgent.append(.unit(archer ?? melee)) }
            if near, military.filter({ v.distance($0.position, city.position) <= 1 }).count < 2 { urgent.append(.unit(archer ?? melee)) }
            if near { urgent.append(.building("walls")) }
            // p3g `--newbie-rush` (DESIGN §5.3, G13): the capital's first item is a Scout, once per
            // game: queued in its founding phase and kept while it heads the queue (the newbie
            // queues no Scout otherwise).
            if rush, city.id == v.me.capital, city.foundedTurn == v.turn || city.queue.first?.item == .unit(.scout) {
                wanted.append(.unit(.scout))
            }
            if goodSite, v.cities.count + settlers < Self.maxCities, v.turn <= 80, city.population >= 2 || city.id == v.me.capital {
                wanted.append(.unit(.settler))
            }
            if !improvableTiles(v).isEmpty, builders < max(1, v.cities.count / 2) { wanted.append(.unit(.builder)) }
            if line < 2 { wanted.append(.unit(melee)) }
            if let archer, archers < 2 { wanted.append(.unit(archer)) }
            wanted += [.building("monument"), .building("granary"), .building("library"), .building("market")]
            if let archer { wanted.append(.unit(archer)) } else { wanted.append(.unit(melee)) }
            func ok(_ item: ProductionItem) -> Bool {
                switch item {
                case let .building(b):
                    guard let def = rules.building(b), !city.has(b) else { return false }
                    return def.tech.map(v.me.knows) ?? true
                case let .unit(t): return rules.unit(t).tech.map(v.me.knows) ?? true
                }
            }
            urgent = urgent.filter(ok)
            wanted = wanted.filter(ok)
            let head = city.queue.first?.item
            var queue: [ProductionItem]
            if let first = urgent.first, head != first, !(head.map { urgent.contains($0) } ?? false) {
                queue = [first]
            } else if let head, urgent.contains(head) || wanted.contains(head) {
                queue = city.queuedItems
            } else if let first = urgent.first ?? wanted.first {
                queue = [first]
            } else {
                continue
            }
            // A first item that would wait (a Settler at population 1) gets a filler after it.
            if queue.count == 1, v.aiCompletionProblem(queue[0], in: id) != nil,
               let filler = (urgent + wanted).first(where: { $0 != queue[0] && v.aiCompletionProblem($0, in: id) == nil }) {
                queue.append(filler)
            }
            if queue != city.queuedItems { issue(.setQueue(city: id, items: queue)) }
            for item in queue {
                guard case let .unit(t) = item else { continue }
                if t == .settler { settlers += 1 }
                if t == .builder { builders += 1 }
                if rules.unit(t).unitClass == .melee || rules.unit(t).unitClass == .antiCavalry { line += 1 }
                if isRanged(t) { archers += 1 }
            }
            buy(city.id, urgent: !urgent.isEmpty && near)
        }
    }

    /// Buys the first item when the treasury holds its price plus 25 Gold and it would take
    /// more than 3 more turns (a defender in a city with an enemy near at war: at its price).
    mutating func buy(_ id: CityID, urgent: Bool) {
        let v = view
        guard let city = v.city(id), let head = city.queue.first?.item,
              let option = v.productionOptions(for: id).first(where: { $0.item == head }), option.buyProblem == nil else { return }
        // The head's own phases left (its queue row; the option's turns are a new entry's).
        let turns = v.queueStatus(of: id).first?.turns
        if urgent ? v.me.gold >= option.buyPrice : v.me.gold >= option.buyPrice + 25 && (turns ?? 99) > 3 {
            issue(.purchase(city: id, item: head))
        }
    }
}
