// PlayerView (M1 §11, §12.6): the only way the UI and the AI read the world. It shows a
// player's own units and cities in full, foreign units only on visible tiles, terrain only on
// explored tiles, the player's memory (territory, improvements, cities and unit sightings),
// relations, the public rules and everyone's score. Every query is pure and deterministic.
// Phase 2 may add read-only query files under GameCore/Queries/.

extension GameState {
    /// What `player` knows (M1 §11).
    public func view(for player: PlayerID) -> PlayerView {
        PlayerView(state: self, player: player)
    }
}

/// Public facts about a player.
public struct PlayerSummary: Hashable, Sendable {
    public var id: PlayerID
    public var name: String
    public var civ: CivID
    public var isHuman: Bool
    public var isAlive: Bool
    public var score: Int
    /// A civ, not the Free Cities (M2 §12.5).
    public var isMajor = true
}

/// A player's income per turn (M1 §12.6), from the cities' current yields.
public struct Income: Hashable, Sendable {
    /// Gold from cities.
    public var gold: Int
    /// Gold paid for military units beyond the free allowance.
    public var upkeep: Int
    public var science: Int
    public var culture: Int
    public var militaryUnits: Int
    public var freeUnits: Int
    /// Gold paid for buildings and quarters (M2 §5.4).
    public var buildings: Int = 0
    public var net: Int { gold - upkeep - buildings }
}

/// Something a city could produce (M1 §12.6).
public struct ProductionOption: Hashable, Sendable {
    public var item: ProductionItem
    public var name: String
    public var cost: Int
    /// Phases a new entry of it needs at the city's production, from no progress, plus stored
    /// progress when no entry already queued would take the production first (M1 §5); for a
    /// building already queued, its queue row's phases (`queueStatus`). Nil with no production.
    public var turns: Int?
    public var buyPrice: Int
    /// Why it may not be queued now (nil: it may).
    public var queueProblem: String?
    /// Why it may not be bought now (nil: it may).
    public var buyProblem: String?
}

/// A tech as the research screen shows it (M1 §12.6).
public struct ResearchOption: Hashable, Sendable {
    public var tech: TechID
    public var name: String
    public var cost: Int
    public var requires: [TechID]
    public var known: Bool
    public var researching: Bool
    public var isTarget: Bool
    /// Its prerequisites are known (and it is not).
    public var available: Bool
    /// Phases to learn it, missing prerequisites first, at the current science (nil when known
    /// or with no science).
    public var turns: Int?
    /// What it unlocks, by name.
    public var unlocks: [String]
    /// Its era's index (M2 §2; 0 without eras).
    public var era: Int = 0
    /// Credit toward it from Insights and the world era (M2 §6.2).
    public var credit: Int = 0
    /// Its Insight's text, if it has one.
    public var insight: String?
    /// Its Insight has fired for the viewer.
    public var insightGained: Bool = false
}

public enum UnitActionKind: String, Hashable, Sendable, CaseIterable {
    case foundCity, buildFarm, buildMine, buildPasture, fortify, sleep, wake, skip, cancelOrders, disband
    // M2 §4.1.
    case buildQuarry, buildPlantation, buildCamp, buildFishingBoats, buildLumberMill
    // M2 §3.3.
    case buildRoad, pillage
}

/// An action of the unit card (M1 §12.6, §16).
public struct UnitAction: Hashable, Sendable {
    public var kind: UnitActionKind
    public var command: Command
    /// Why it is not available now (nil: it is).
    public var problem: String?
    public var isAvailable: Bool { problem == nil }
}

public struct PlayerView: Sendable {
    let state: GameState
    public let player: PlayerID

    init(state: GameState, player: PlayerID) {
        self.state = state
        self.player = player
    }

    // MARK: Public facts

    public var rules: Ruleset { state.rules }
    public var seed: UInt64 { state.seed }
    public var turn: Int { state.turn }
    public var currentPlayer: PlayerID { state.currentPlayer }
    public var phaseCount: Int { state.phaseCount }
    public var outcome: GameOutcome? { state.outcome }
    public var mapSizeName: String { state.mapSizeName }
    public var isMyPhase: Bool { state.currentPlayer == player && state.outcome == nil }

    /// The viewing player, in full.
    public var me: Player { state.players[player.rawValue] }

    public var players: [PlayerSummary] {
        state.players.map { p in
            PlayerSummary(id: p.id, name: p.name, civ: p.civ, isHuman: p.isHuman, isAlive: p.isAlive, score: state.score(of: p.id),
                          isMajor: p.isMajor)
        }
    }

    public func score(of other: PlayerID) -> Int { state.score(of: other) }

    /// The relation with another player (nil for oneself).
    public func relation(with other: PlayerID) -> Relation? {
        other == player || !state.players.indices.contains(other.rawValue) ? nil : state.relation(player, other)
    }

    public func hasMet(_ other: PlayerID) -> Bool { state.hasMet(player, other) }
    public func isAtWar(with other: PlayerID) -> Bool { state.isAtWar(player, other) }

    // MARK: Knowledge

    public var visible: TileBitSet { me.visible }
    public var explored: TileBitSet { me.explored }
    public var memory: PlayerMemory { me.memory }
    /// Per tile: owner as last seen (0 none, else player + 1). Current on visible tiles.
    public var knownTerritory: [UInt8] { me.memory.tileOwner }
    /// Per tile: improvement raw value as last seen (0 none). Current on visible tiles.
    public var knownImprovements: [UInt8] { me.memory.tileImprovement }
    /// Every city the player knows of (own cities current), sorted by id.
    public var knownCities: [CitySighting] { me.memory.cities }
    /// Foreign military units seen recently, sorted by id.
    public var sightings: [UnitSighting] { me.memory.units }
    /// The tribal villages the player knows of (M1 §7.7), as tile indices in order: current on
    /// visible tiles, as last seen elsewhere. From memory only.
    public var knownTribalVillages: [Int32] { me.memory.tribalVillages ?? [] }

    /// Whether the player knows of a tribal village on the tile (memory only).
    public func isKnownTribalVillage(_ hex: HexCoord) -> Bool {
        guard let t = index(of: hex), let known = me.memory.tribalVillages else { return false }
        return SortedTiles.contains(known, t)
    }

    /// How many gifts the player has had from tribal villages (its own count only).
    public var tribalVillageGiftsReceived: Int {
        guard let gifts = state.tribalVillages?.gifts, gifts.indices.contains(player.rawValue) else { return 0 }
        return gifts[player.rawValue]
    }

    // MARK: Units and cities

    /// Own units, sorted by id.
    public var units: [Unit] { state.units.filter { $0.owner == player } }
    /// Own cities, sorted by id.
    public var cities: [City] { state.cities.filter { $0.owner == player } }
    /// Foreign units on visible tiles, sorted by id.
    public var visibleForeignUnits: [Unit] {
        state.units.filter { $0.owner != player && isVisible(index: state.map.index(of: $0.position)!) }
    }
    /// Own units and foreign units on visible tiles, sorted by id.
    public var visibleUnits: [Unit] {
        state.units.filter { $0.owner == player || isVisible(index: state.map.index(of: $0.position)!) }
    }

    /// An own unit, or a foreign unit on a visible tile.
    /// The promotions an own unit may take now (M2 §8.3).
    public func promotionsOffered(_ id: UnitID) -> [PromotionDef] {
        guard let u = state.unit(id), u.owner == player else { return [] }
        return state.promotionsOffered(to: u)
    }

    /// Gold to upgrade an own unit now, nil when it may not (M2 §8.2).
    /// `unit`'s range, promotions included (0 for non-ranged units).
    public func range(of unit: Unit) -> Int { state.range(of: unit) }

    /// Whether it may fire after moving in the phase (siege may not, M2 §8.1, unless promoted).
    public func firesAfterMoving(_ unit: Unit) -> Bool { state.firesAfterMoving(unit) }

    /// Why an own unit cannot upgrade now (nil: it can, or it is not this player's): moves,
    /// territory, tech, Gold or the target's strategic resource (M2 §8.2, §3.1).
    public func upgradeProblem(_ id: UnitID) -> String? {
        guard let u = state.unit(id), u.owner == player else { return nil }
        guard isMyPhase else { return "not your turn" }
        return state.upgradeProblem(u)
    }

    public func upgradeCost(_ id: UnitID) -> Int? {
        guard isMyPhase, let u = state.unit(id), u.owner == player, state.upgradeProblem(u) == nil else { return nil }
        return state.upgradeCost(of: u.type, for: player)
    }

    public func unit(_ id: UnitID) -> Unit? {
        guard let unit = state.unit(id) else { return nil }
        return unit.owner == player || isVisible(unit.position) ? unit : nil
    }

    /// Own units and visible foreign units on a tile.
    public func units(at hex: HexCoord) -> [Unit] {
        guard isVisible(hex) || state.units.contains(where: { $0.owner == player && $0.position == hex }) else { return [] }
        return state.units(at: hex).filter { $0.owner == player || isVisible(hex) }
    }

    /// An own city.
    /// Where one of my cities may place a quarter of `kind`, best first (M2 §18.2).
    public func quarterSites(_ kind: QuarterKind, in id: CityID) -> [(tile: HexCoord, adjacency: Int)] {
        guard let i = state.cityIndex(id), state.cities[i].owner == player else { return [] }
        return state.quarterSites(kind, in: state.cities[i])
    }

    public func city(_ id: CityID) -> City? {
        state.city(id).flatMap { $0.owner == player ? $0 : nil }
    }

    // MARK: Map

    public var mapWidth: Int { state.map.width }
    public var mapHeight: Int { state.map.height }
    public var wrapsX: Bool { state.map.wrapsX }
    public var tileCount: Int { state.map.tileCount }
    public func index(of hex: HexCoord) -> Int? { state.map.index(of: hex) }
    public func coord(at index: Int) -> HexCoord { state.map.coord(at: index) }
    public func normalize(_ hex: HexCoord) -> HexCoord? { state.map.normalize(hex) }
    public func neighbors(of hex: HexCoord) -> [HexCoord] { state.map.neighbors(of: hex) }
    public func distance(_ a: HexCoord, _ b: HexCoord) -> Int { state.map.distance(a, b) }
    public func coords(within radius: Int, of center: HexCoord) -> [HexCoord] { state.map.coords(within: radius, of: center) }

    public func isExplored(_ hex: HexCoord) -> Bool { index(of: hex).map { me.explored[$0] } ?? false }
    public func isVisible(_ hex: HexCoord) -> Bool { index(of: hex).map { me.visible[$0] } ?? false }
    func isVisible(index: Int) -> Bool { me.visible[index] }

    /// An explored tile as the player knows it (improvement as last seen); nil if unexplored.
    public func tile(at hex: HexCoord) -> Tile? {
        guard let t = index(of: hex), me.explored[t] else { return nil }
        var tile = state.map.tiles[t]
        tile.improvement = Improvement(rawValue: me.memory.tileImprovement[t])
        tile.road = me.memory.remembersRoad(t) ? true : nil
        if !me.visible[t] { tile.pillaged = nil }
        tile.resource = state.knownResource(at: t, for: player)
        return tile
    }

    /// The known city centred on a tile (own or remembered).
    public func knownCity(at hex: HexCoord) -> CitySighting? {
        guard let hex = normalize(hex) else { return nil }
        return me.memory.city(at: hex)
    }

    // MARK: Yields

    /// The yields of an explored tile for this player (its techs, the improvement as last
    /// seen, city centre if a known city stands there); nil if unexplored.
    /// The resource on an explored tile once this player knows its reveal tech (M2 §3.4:
    /// resources never change, so a reveal fills in every explored tile at once).
    public func resource(at hex: HexCoord) -> Resource? {
        guard let t = index(of: hex), me.explored[t] else { return nil }
        return state.knownResource(at: t, for: player)
    }

    /// Strategic stock of a resource and this player's improved sources of it.
    public func stock(_ resource: Resource) -> (amount: Int, sources: Int, cap: Int) {
        (me.stock(resource), state.improvedSources(of: player)[Int(resource.rawValue) - 1], state.stockpileCap)
    }

    /// Why this player cannot field a unit of `type` now for want of its strategic resource
    /// ("needs 10 Iron (have 4)"); nil when it needs none or has enough.
    public func resourceProblem(_ type: UnitType) -> String? { state.resourceProblem(type, owner: player) }

    public func tileYields(at hex: HexCoord) -> Yields? {
        guard let tile = tile(at: hex), let t = index(of: hex) else { return nil }
        let known = me.knownTechs
        var lake = false
        state.map.forEachNeighbor(of: t) { n, _ in if me.explored[n], state.map.tiles[n].terrain == .lake { lake = true } }
        return rules.tileYields(tile, knows: { known.contains($0) }, isCityCentre: knownCity(at: hex) != nil, touchesLake: lake)
    }

    /// An own city's yields with their sources.
    public func cityYields(_ id: CityID) -> CityYields? {
        city(id).map { state.cityYields($0) }
    }

    /// Phases until an own city grows (nil when its food store is not growing).
    public func turnsToGrow(_ id: CityID) -> Int? {
        guard let city = city(id) else { return nil }
        let surplus = state.cityYields(city).foodSurplus
        guard surplus > 0 else { return nil }
        let needed = rules.growthThreshold(population: city.population) - city.foodStore
        return max(1, (needed + surplus - 1) / surplus)
    }

    /// Income per turn from the cities' current yields, and upkeep.
    public func income() -> Income {
        var y = Yields.zero
        for city in state.cities where city.owner == player { y += state.cityYields(city).total }
        return Income(gold: y.gold, upkeep: state.upkeep(of: player), science: y.science, culture: y.culture,
                      militaryUnits: state.militaryUnitCount(of: player), freeUnits: state.freeUnitAllowance(of: player),
                      buildings: state.buildingUpkeep(of: player))
    }

    // MARK: Production

    /// Everything an own city could produce, with cost, phases, buy price and whether it may be
    /// queued or bought now.
    public func productionOptions(for id: CityID) -> [ProductionOption] {
        guard let city = city(id) else { return [] }
        let production = state.cityYields(city).total.production
        let maxQueue = rules.constants.production.maxQueue
        let gold = me.gold
        // A new entry starts from nothing; stored progress goes to it only when nothing queued
        // can take the production before it (p3f: a Settler that fills while it waits takes it).
        let queue = queueStatus(of: id)
        let filling = state.waitingHeadFillLimit(city) != nil
        let stored = queue.contains(where: \.receivesProduction) || filling ? 0 : city.storedProgress
        let items = UnitType.allCases.map { ProductionItem.unit($0) }
            + rules.buildings.filter(\.buildable).map { ProductionItem.building($0.id) }
        return items.map { item in
            let cost = rules.cost(of: item)
            var turns = production > 0 ? max(1, (max(0, cost - stored) + production - 1) / production) : nil
            if case .building = item, let row = queue.first(where: { $0.item == item }) { turns = row.turns }
            let price = state.purchasePrice(of: item, for: player)
            var queueProblem = state.itemProblem(item, in: city)
            if queueProblem == nil {
                if city.queue.count >= maxQueue { queueProblem = "queue full" }
                else if case .building = item, city.queue.contains(where: { $0.item == item }) { queueProblem = "already queued" }
            }
            var buyProblem = state.itemProblem(item, in: city) ?? state.completionProblem(item, in: city)
            if buyProblem == nil, gold < price { buyProblem = "needs \(price) gold" }
            if !isMyPhase, buyProblem == nil { buyProblem = "not your turn" }
            return ProductionOption(item: item, name: state.itemName(item), cost: cost, turns: turns, buyPrice: price,
                                    queueProblem: queueProblem, buyProblem: buyProblem)
        }
    }

    // MARK: Research

    /// The techs in tree order with their state, phases to learn and unlocks.
    public func researchOptions() -> [ResearchOption] {
        let science = income().science
        return rules.techs.map { tech in
            let known = me.knows(tech.id)
            var turns: Int?
            if !known, science > 0 {
                // The tech and its missing prerequisites, minus the progress banked.
                var cost = 0
                var needed = [Bool](repeating: false, count: rules.techs.count)
                let goal = rules.techIndex(tech.id)!
                needed[goal] = true
                for i in stride(from: goal, through: 0, by: -1) where needed[i] {
                    for r in rules.techRequires[i] { needed[r] = true }
                }
                for i in rules.techs.indices where needed[i] && !me.knows(rules.techs[i].id) {
                    cost += max(0, rules.techs[i].cost - me.credit(techIndex: i))
                }
                let remaining = max(0, cost - me.researchProgress)
                turns = max(1, (remaining + science - 1) / science)
            }
            let index = rules.techIndex(tech.id)!
            return ResearchOption(tech: tech.id, name: tech.name, cost: tech.cost, requires: tech.requires, known: known,
                                  researching: me.researching == tech.id, isTarget: me.researchTarget == tech.id,
                                  available: !known && tech.requires.allSatisfy(me.knows),
                                  turns: turns, unlocks: unlocks(of: tech.id), era: rules.techEras[index],
                                  credit: me.credit(techIndex: index), insight: tech.insight?.text,
                                  insightGained: me.hasInsight(tech.id))
        }
    }

    /// Names of what a tech unlocks.
    public func unlocks(of tech: TechID) -> [String] {
        var names: [String] = []
        for def in rules.units where def.tech == tech { names.append(def.type.displayName) }
        for def in rules.buildings where def.tech == tech { names.append(def.name) }
        for def in rules.improvements where def.tech == tech { names.append(def.displayName) }
        for def in rules.improvements where def.freshWaterTech == tech {
            names.append("\(def.displayName) +\(def.freshWaterFood) Food by fresh water")
        }
        for def in rules.terrains {
            for bonus in def.techBonuses where bonus.tech == tech {
                names.append("+\(bonus.food) Food on \(def.name.capitalized)")
            }
        }
        if let e = rules.embark {
            if e.coastTech == tech { names.append("Embark on Coast and Lake") }
            if e.oceanTech == tech { names.append("Ocean for all units") }
        }
        return names
    }

    // MARK: Units

    /// The actions of an own unit's card, each available or with the reason it is not.
    public func unitActions(for id: UnitID) -> [UnitAction] {
        guard let unit = state.unit(id), unit.owner == player else { return [] }
        let def = rules.unit(unit.type)
        var actions: [UnitAction] = []
        let turnProblem: String? = isMyPhase ? nil : "not your turn"
        func add(_ kind: UnitActionKind, _ command: Command, _ problem: String?) {
            actions.append(UnitAction(kind: kind, command: command, problem: turnProblem ?? problem))
        }
        if def.foundsCity {
            add(.foundCity, .foundCity(unit: id), canFoundCity(at: unit.position) ? nil : "site not valid")
        }
        if def.charges > 0 {
            for (kind, improvement) in [(UnitActionKind.buildFarm, Improvement.farm), (.buildMine, .mine), (.buildPasture, .pasture)] {
                add(kind, .buildImprovement(unit: id, improvement: improvement), state.improvementProblem(improvement, by: unit))
            }
            // M2 improvements are offered only where they could stand.
            let t = state.map.index(of: unit.position)!
            let known = state.knownResource(at: t, for: player)
            for (kind, improvement) in [(UnitActionKind.buildQuarry, Improvement.quarry), (.buildPlantation, .plantation),
                                        (.buildCamp, .camp), (.buildFishingBoats, .fishingBoats), (.buildLumberMill, .lumberMill)]
                where rules.allowsImprovement(improvement, on: state.map.tiles[t], resource: known) {
                add(kind, .buildImprovement(unit: id, improvement: improvement), state.improvementProblem(improvement, by: unit))
            }
        }
        if def.charges > 0, rules.roads != nil { add(.buildRoad, .buildRoad(unit: id), state.roadProblem(unit)) }
        if def.isMilitary, rules.roads != nil { add(.pillage, .pillage(unit: id), state.pillageProblem(unit)) }
        if def.isMilitary { add(.fortify, .fortify(unit: id), GameEngine.activityProblem(.fortify, unit)) }
        add(.sleep, .sleep(unit: id), GameEngine.activityProblem(.sleep, unit))
        add(.wake, .wake(unit: id), GameEngine.activityProblem(.wake, unit))
        add(.skip, .skip(unit: id), GameEngine.activityProblem(.skip, unit))
        add(.cancelOrders, .cancelOrders(unit: id), unit.destination == nil ? "no orders" : nil)
        add(.disband, .disband(unit: id), nil)
        return actions
    }

    /// Tiles an own unit can reach and stop on this phase, by this player's knowledge.
    public func reachableTiles(for id: UnitID) -> [HexCoord] {
        guard let unit = state.unit(id), unit.owner == player else { return [] }
        return Pathfinder.reachableTiles(for: unit, in: state)
    }

    /// A path for an own unit, by this player's knowledge.
    public func path(for id: UnitID, to hex: HexCoord) -> Path? {
        guard let unit = state.unit(id), unit.owner == player else { return nil }
        return Pathfinder.findPath(for: unit, to: hex, in: state)
    }

    // MARK: Settling

    /// Whether this player could found a city on a tile, by its knowledge (explored tiles only):
    /// passable land that allows a city, not owned by another player as last seen, and at
    /// least the minimum distance from every known city.
    public func canFoundCity(at hex: HexCoord) -> Bool {
        guard let t = index(of: hex), me.explored[t] else { return false }
        let tile = state.map.tiles[t]
        guard rules.isPassable(tile), rules.feature(tile.feature).allowsCity else { return false }
        let owner = me.memory.tileOwner[t]
        guard owner == 0 || Int(owner) - 1 == player.rawValue else { return false }
        let minimum = rules.constants.city.minDistance
        let site = coord(at: t)
        return !me.memory.cities.contains { distance($0.position, site) < minimum }
    }

    /// How good a city site looks to this player (0 where it may not found one): the weighted
    /// yields (3·Food + 2·Prod + 2·Gold by default) of the explored tiles within the settle
    /// radius that are unowned or own as last seen and workable, plus bonuses for fresh water,
    /// coast and hills. Unexplored tiles count 0.
    public func settleScore(at hex: HexCoord) -> Int {
        guard canFoundCity(at: hex), let centre = index(of: hex) else { return 0 }
        let s = rules.constants.settle
        let known = me.knownTechs
        let knows: (TechID) -> Bool = { known.contains($0) }
        let mine = UInt8(player.rawValue + 1)
        var score = 0
        state.map.forEachIndex(within: s.radius, of: coord(at: centre)) { t in
            guard me.explored[t] else { return }
            let owner = me.memory.tileOwner[t]
            guard owner == 0 || owner == mine else { return }
            var tile = state.map.tiles[t]
            guard rules.isWorkable(tile) else { return }
            tile.improvement = Improvement(rawValue: me.memory.tileImprovement[t])
            tile.road = me.memory.remembersRoad(t) ? true : nil
            if !me.visible[t] { tile.pillaged = nil }
            let y = rules.tileYields(tile, knows: knows, isCityCentre: t == centre)
            score += s.foodWeight * y.food + s.productionWeight * y.production + s.goldWeight * y.gold
        }
        let tile = state.map.tiles[centre]
        var lake = false, coast = false
        state.map.forEachNeighbor(of: centre) { n, _ in
            guard me.explored[n] else { return }
            if state.map.tiles[n].terrain == .lake { lake = true }
            if state.map.tiles[n].terrain == .coast { coast = true }
        }
        if tile.riverEdges != 0 || lake { score += s.freshWaterBonus }
        if coast { score += s.coastBonus }
        if tile.elevation == .hills { score += s.hillsBonus }
        return score
    }
}
