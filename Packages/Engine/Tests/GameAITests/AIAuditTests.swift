import Foundation
import Testing
@testable import GameAI
@testable import GameCore

// ai-3's audit of M1 §13: a test for each rule the other suites left unchecked. Rules about a
// derived quantity (power, the plan, the priority list, a Builder's choice) are checked
// white-box on `AITurn`; the others on a whole phase.

private let p0 = PlayerID(0)
private let p1 = PlayerID(1)
private let p2 = PlayerID(2)

/// Every tile explored by `player`.
private func exploreMap(_ state: inout GameState, _ player: PlayerID) {
    for t in 0..<state.map.tileCount { state.players[player.rawValue].explored[t] = true }
    refreshKnowledge(&state)
}

/// The tiles within `radius` of `center` explored by `player`.
private func explore(_ state: inout GameState, _ player: PlayerID, within radius: Int, of center: HexCoord) {
    for h in state.map.coords(within: radius, of: center) { state.players[player.rawValue].explored[state.map.index(of: h)!] = true }
    refreshKnowledge(&state)
}

/// The AI of `player` (default: the current player) with this phase's plan made.
private func planned(_ state: GameState, _ player: PlayerID? = nil) -> AITurn {
    var turn = AITurn(state: state, player: player ?? state.currentPlayer)
    turn.plan = turn.makePlan()
    return turn
}

/// The head of the queue the AI wants for `city` now.
private func wantedQueue(_ state: GameState, _ city: CityID) -> [ProductionItem] {
    let turn = planned(state)
    return turn.decideQueue(for: city, turn.baseCounts())
}

/// Whether `command` is an attack by unit `id`.
private func attacks(_ command: Command, by id: UnitID) -> Bool {
    if case .attack(id, _) = command { true } else { false }
}

@Suite struct AIPowerAuditTests {
    /// Power (M1 §13): (Ranged Strength if any, else Strength) × HP / 100. A city's garrison is
    /// its military unit on the tile; the army is every other military unit but recon.
    @Test func powerGarrisonAndArmy() throws {
        var state = makeState()
        addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(16, 6))
        let garrison = state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        let archer = state.addUnit(.archer, owner: p0, at: hex(7, 6))
        let spearman = state.addUnit(.spearman, owner: p0, at: hex(5, 6))
        state.addUnit(.scout, owner: p0, at: hex(6, 7))
        state.addUnit(.builder, owner: p0, at: hex(6, 6))
        state.updateUnit(archer) { $0.hp = 50 }
        let turn = planned(state)
        let v = turn.view
        let hurt = try #require(v.unit(archer)), fresh = try #require(v.unit(spearman))
        #expect(v.power(of: hurt) == 25 * 50 / 100)
        #expect(v.power(of: fresh) == 25)
        let forces = turn.forces(v)
        #expect(forces.garrisons.map(\.unit) == [garrison])
        #expect(forces.army.map(\.id) == [archer, spearman])
        #expect(forces.power == 12 + 25)
        #expect(turn.plan.army == 37)
    }

    /// estimate(R) (M1 §13) = Σ power of R's sightings at most 20 turns old + 15 per city of R
    /// the player remembers.
    @Test func estimateCountsRecentSightingsAndKnownCities() throws {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p1, at: hex(14, 6))
        addCity(&state, p1, at: hex(21, 2))
        reveal(&state, to: p0, from: hex(13, 6))
        state.turn = 40
        state.players[0].memory.units = [
            UnitSighting(id: UnitID(900), owner: p1, type: .archer, position: hex(12, 9), hp: 100, turnSeen: 20),
            UnitSighting(id: UnitID(901), owner: p1, type: .spearman, position: hex(12, 2), hp: 60, turnSeen: 30),
            UnitSighting(id: UnitID(902), owner: p1, type: .warrior, position: hex(11, 9), hp: 100, turnSeen: 19),
        ]
        let turn = planned(state)
        let known = turn.view.knownCities.filter { $0.owner == p1 }.count
        try #require(known == 1)
        // The Archer (seen 20 turns ago) and the Spearman count; the Warrior (21 turns) does not.
        #expect(turn.estimate(of: p1, turn.view) == 25 + 25 * 60 / 100 + 15 * known)
    }
}

@Suite struct AIPostureAuditTests {
    /// Expand while a good site exists and cities < the map's maximum; develop otherwise.
    @Test func expandWhileGoodSitesRemainElseDevelop() {
        var open = makeState()
        addCity(&open, p0, at: hex(4, 6))
        addCity(&open, p1, at: hex(18, 2))
        exploreMap(&open, p0)
        let expanding = planned(open)
        #expect(expanding.plan.goodSiteExists)
        #expect(expanding.plan.posture == .expand)

        // A small island: no site far enough from the city.
        var map = openMap(fill: Tile(terrain: .ocean))
        for h in map.coords(within: 2, of: hex(5, 6)) { map[h] = Tile(terrain: .grassland) }
        for h in map.coords(within: 2, of: hex(16, 6)) { map[h] = Tile(terrain: .grassland) }
        var island = makeState(map: map)
        addCity(&island, p0, at: hex(5, 6))
        addCity(&island, p1, at: hex(16, 6))
        exploreMap(&island, p0)
        let developing = planned(island)
        #expect(!developing.plan.goodSiteExists)
        #expect(developing.plan.posture == .develop)
    }

    /// Prepare (the war test but the army) only against a rival the army can march on (ai-3):
    /// across explored sea there is no target and no rally city, so the AI expands or develops
    /// instead of building an army it can never use. With a land bridge it prepares.
    @Test func preparesOnlyAgainstAReachableRival() throws {
        func world(bridge: Bool) -> GameState {
            var map = openMap(width: 24, height: 12, fill: Tile(terrain: .ocean))
            for h in map.coords(within: 3, of: hex(5, 6)) { map[h] = Tile(terrain: .grassland) }
            for h in map.coords(within: 3, of: hex(18, 6)) { map[h] = Tile(terrain: .grassland) }
            if bridge { for col in 8...15 { map[hex(col, 6)] = Tile(terrain: .grassland) } }
            var state = makeState(map: map)
            addCity(&state, p0, at: hex(5, 6))
            addCity(&state, p1, at: hex(18, 6))
            state.addUnit(.warrior, owner: p0, at: hex(5, 6))
            exploreMap(&state, p0)
            reveal(&state, to: p0, from: hex(17, 6))
            setRelation(&state, p0, p1, war: false, since: nil)
            state.turn = 40
            return state
        }
        let apart = planned(world(bridge: false))
        try #require(apart.view.knownCities.contains { $0.owner == p1 })
        try #require(apart.warEligible(p1, apart.view))
        #expect(apart.plan.rival == nil)
        #expect(apart.plan.posture != .prepare)
        let joined = planned(world(bridge: true))
        #expect(joined.plan.rival == p1)
        #expect(joined.plan.posture == .prepare)
        #expect(joined.plan.target?.owner == p1 && joined.plan.rally != nil)
    }
}

@Suite struct AIResearchAuditTests {
    /// Research orders (M1 §13): in peace the first unknown tech of Pottery, Animal Husbandry,
    /// …; when threatened (as when preparing or at war) of Mining, Bronze Working, ….
    @Test func researchFollowsThePosturesOrder() throws {
        var state = makeState()
        addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 2))
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        var peaceful = state
        #expect(playPhase(&peaceful).commands.contains(.setResearch(tech: "pottery")))
        var later = state
        later.players[0].knownTechs += ["pottery"]
        #expect(playPhase(&later).commands.contains(.setResearch(tech: "animalHusbandry")))
        // A foreign Warrior 2 tiles from the city: threatened.
        var threatened = state
        threatened.addUnit(.warrior, owner: p1, at: hex(8, 6))
        setRelation(&threatened, p0, p1, war: false, since: nil)
        refreshKnowledge(&threatened)
        try #require(!planned(threatened).plan.threatened.isEmpty)
        #expect(playPhase(&threatened).commands.contains(.setResearch(tech: "mining")))
    }
}

@Suite struct AICityAuditTests {
    /// The priority list (M1 §13 Cities), item by item: the defence quota; a Warrior early to
    /// explore without a Scout; a Settler for a good site; a Builder for unimproved worked
    /// tiles; the Monument early; then Granary, the Campus, Library, the Market quarter, Market.
    @Test func priorityListInOrder() throws {
        var state = makeState()
        let city = addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 2))
        explore(&state, p0, within: 7, of: hex(6, 6))
        state.turn = 5
        #expect(wantedQueue(state, city).first == .unit(.warrior)) // no garrison
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        #expect(wantedQueue(state, city).first == .unit(.warrior)) // to explore: no Scout, no army
        state.addUnit(.scout, owner: p0, at: hex(8, 8))
        #expect(wantedQueue(state, city).first == .unit(.settler))
        state.addUnit(.settler, owner: p0, at: hex(5, 5))
        #expect(wantedQueue(state, city).first == .unit(.builder))
        state.addUnit(.builder, owner: p0, at: hex(7, 6))
        #expect(wantedQueue(state, city).first == .building("monument"))
        updateCity(&state, city) { $0.buildings.append("monument") }
        state.players[0].knownTechs += ["pottery", "writing", "currency"]
        #expect(wantedQueue(state, city).first == .building("granary"))
        updateCity(&state, city) { $0.buildings.append("granary"); $0.population = 3 }
        // M2 §5.3: the Library and Market wait for their quarters, each on its best site.
        let campus = try #require(state.view(for: p0).quarterSites("campus", in: city).first?.tile)
        #expect(wantedQueue(state, city).first == .quarter("campus", at: campus))
        updateCity(&state, city) { $0.quarters = [CityQuarter(kind: "campus", tile: campus)] }
        #expect(wantedQueue(state, city).first == .building("library"))
        updateCity(&state, city) { $0.buildings.append("library") }
        let market = try #require(state.view(for: p0).quarterSites("market", in: city).first?.tile)
        #expect(market != campus && wantedQueue(state, city).first == .quarter("market", at: market))
        updateCity(&state, city) { $0.quarters! += [CityQuarter(kind: "market", tile: market)] }
        #expect(wantedQueue(state, city).first == .building("market"))
    }

    /// Upkeep (M1 §13): no military unit is started when net gold after its upkeep would be
    /// negative, unless at war with gold ≥ warGoldDeficitMultiplier × the deficit; not even
    /// a garrison.
    @Test func militaryOnlyWhenTheTreasuryCanKeepIt() throws {
        var state = makeState(gold: 0)
        let city = addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 2))
        let income = state.view(for: p0).income()
        let kept = income.freeUnits + income.gold // military units the income keeps
        let peace = planned(state)
        #expect(peace.militaryAffordable(kept - 1, atWar: false, peace.view))
        #expect(!peace.militaryAffordable(kept, atWar: false, peace.view))
        #expect(!peace.militaryAffordable(kept, atWar: true, peace.view))
        let multiplier = state.rules.ai.warGoldDeficitMultiplier
        state.players[0].gold = multiplier - 1
        let short = planned(state)
        #expect(!short.militaryAffordable(kept, atWar: true, short.view))
        state.players[0].gold = multiplier
        let rich = planned(state)
        #expect(rich.militaryAffordable(kept, atWar: true, rich.view))
        #expect(!rich.militaryAffordable(kept, atWar: false, rich.view))

        // End to end: an ungarrisoned city of a player who cannot keep another unit makes none.
        var broke = state
        broke.players[0].gold = 0
        for i in 0..<kept { broke.addUnit(.warrior, owner: p0, at: hex(9 + i % 8, 1 + 2 * (i / 8))) }
        try #require(broke.view(for: p0).income().net <= 0)
        let queue = wantedQueue(broke, city)
        #expect(!queue.isEmpty)
        #expect(!queue.contains { if case let .unit(type) = $0 { !type.isCivilian } else { false } }, "\(queue)")
    }

    /// Settlers (M1 §13) only with no visible enemy within 4 tiles of the city, and while
    /// Settlers alive + queued < ⌈cities / 2⌉.
    @Test func noSettlersWithAnEnemyNearOrEnoughUnderWay() throws {
        var state = makeState()
        let city = addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 2))
        updateCity(&state, city) { $0.population = 3 }
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        state.addUnit(.scout, owner: p0, at: hex(9, 9))
        state.addUnit(.builder, owner: p0, at: hex(7, 6))
        exploreMap(&state, p0)
        state.turn = 35
        try #require(wantedQueue(state, city).first == .unit(.settler))
        var enemy = state
        enemy.addUnit(.warrior, owner: p1, at: hex(8, 6))
        setRelation(&enemy, p0, p1, war: true, since: 30)
        refreshKnowledge(&enemy)
        #expect(!wantedQueue(enemy, city).contains(.unit(.settler)))
        var busy = state
        busy.addUnit(.settler, owner: p0, at: hex(5, 5))
        #expect(!wantedQueue(busy, city).contains(.unit(.settler)))
    }

    /// Army first (rules `armyFirstCities`, p3 early-game): preparing for war with at least
    /// that many cities, a city builds a missing Builder and then the army before more
    /// Settlers; with fewer cities, or before the prepare posture, Settlers still come first.
    @Test func armyBeforeSettlersFromArmyFirstCities() throws {
        func world(_ spots: [HexCoord], turn: Int, builders: Int = 2) -> (GameState, CityID) {
            var state = makeState(map: openMap(width: 30, height: 14))
            var cities: [CityID] = []
            for spot in spots {
                let city = addCity(&state, p0, at: spot)
                updateCity(&state, city) { $0.population = 3 }
                state.addUnit(.warrior, owner: p0, at: spot)
                cities.append(city)
            }
            for i in 0..<builders { state.addUnit(.builder, owner: p0, at: hex(1, 1 + 2 * i)) }
            addCity(&state, p1, at: hex(26, 6))
            state.addUnit(.scout, owner: p0, at: hex(14, 6))
            exploreMap(&state, p0)
            reveal(&state, to: p0, from: hex(25, 6))
            setRelation(&state, p0, p1, war: false, since: nil)
            state.turn = turn
            return (state, cities[0])
        }
        func headIsMilitary(_ queue: [ProductionItem]) -> Bool {
            if case let .unit(type)? = queue.first { !type.isCivilian } else { false }
        }
        try #require(Ruleset.standard.ai.armyFirstCities == 3)
        let three = [hex(4, 3), hex(4, 10), hex(9, 6)]

        let (preparing, capital) = world(three, turn: 40)
        let plan = planned(preparing).plan
        try #require(plan.posture == .prepare && plan.goodSiteExists)
        #expect(headIsMilitary(wantedQueue(preparing, capital)), "\(wantedQueue(preparing, capital))")

        let (unimproved, capital1) = world(three, turn: 40, builders: 0)
        try #require(planned(unimproved).plan.posture == .prepare)
        #expect(wantedQueue(unimproved, capital1).first == .unit(.builder))

        let (fewer, capital2) = world(Array(three.prefix(2)), turn: 40)
        try #require(planned(fewer).plan.posture == .prepare)
        #expect(wantedQueue(fewer, capital2).first == .unit(.settler))

        let (early, capital3) = world(three, turn: 20)
        try #require(planned(early).plan.posture == .expand)
        #expect(wantedQueue(early, capital3).first == .unit(.settler))
    }

    /// Focus: Balanced.
    @Test func citiesWorkBalanced() {
        var state = makeState()
        let city = addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 2))
        updateCity(&state, city) { $0.focus = .production }
        #expect(playPhase(&state).commands.contains(.setFocus(city: city, focus: .balanced)))
        #expect(state.city(city)?.focus == .balanced)
    }

    /// A met rival none of whose cities is known: a Scout is built to find it (M1 §13
    /// Exploring), right after the defence quota.
    @Test func aScoutIsBuiltToFindAnUnlocatedRival() throws {
        var state = makeState(map: openMap(width: 24, height: 12))
        let city = addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(20, 6))
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        setRelation(&state, p0, p1, war: false, since: nil)
        state.turn = 35
        let turn = planned(state)
        try #require(turn.unlocatedRival(turn.view) == p1)
        #expect(wantedQueue(state, city).first == .unit(.scout))
    }

    /// …but not when no unit leaving a city could reach the frontier (ai-3): from an explored
    /// island, a Scout would be disbanded at once for want of anything to explore, then built
    /// again, phase after phase (seen on Large maps, behind closed borders too).
    @Test func noScoutWithoutAReachableFrontier() throws {
        var map = openMap(width: 24, height: 12, fill: Tile(terrain: .ocean))
        for h in map.coords(within: 3, of: hex(5, 6)) { map[h] = Tile(terrain: .grassland) }
        for h in map.coords(within: 3, of: hex(18, 6)) { map[h] = Tile(terrain: .grassland) }
        var state = makeState(map: map)
        let city = addCity(&state, p0, at: hex(5, 6))
        addCity(&state, p1, at: hex(18, 6))
        state.addUnit(.warrior, owner: p0, at: hex(5, 6))
        // The home island and the sea around it, and a strip of the other island's coast.
        for h in map.coords(within: 6, of: hex(5, 6)) + map.coords(within: 1, of: hex(15, 6)) {
            state.players[0].explored[tile(state, h)] = true
        }
        refreshKnowledge(&state)
        setRelation(&state, p0, p1, war: false, since: nil)
        state.turn = 35
        let turn = planned(state)
        try #require(turn.unlocatedRival(turn.view) == p1)
        try #require(!turn.view.aiFrontier().isEmpty)
        #expect(turn.plan.explorerCity == nil)
        #expect(!wantedQueue(state, city).contains(.unit(.scout)))
    }
}

@Suite struct AIBuilderAuditTests {
    /// A Builder's choice (M1 §13): a Farm by fresh water first, then a Mine on hills, then a
    /// Pasture, then a plain Farm; each only where its tech is known.
    @Test func improvementRanks() throws {
        var map = openMap()
        map[hex(8, 6)] = Tile(terrain: .lake)
        map[hex(5, 6)] = Tile(terrain: .grassland, elevation: .hills)
        var state = makeState(map: map)
        addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 2))
        let water = tile(state, hex(7, 6)), hill = tile(state, hex(5, 6)), plain = tile(state, hex(6, 5))
        let before = planned(state)
        try #require(before.view.aiHasFreshWater(at: hex(7, 6)) && !before.view.aiHasFreshWater(at: hex(6, 5)))
        let farm = try #require(before.bestImprovement(at: water, before.view))
        #expect(farm.0 == .farm && farm.1 == 0)
        #expect(before.bestImprovement(at: hill, before.view) == nil) // Mining unknown
        let plainFarm = try #require(before.bestImprovement(at: plain, before.view))
        #expect(plainFarm.0 == .farm && plainFarm.1 == 3)
        state.players[0].knownTechs += ["mining", "animalHusbandry"]
        let after = planned(state)
        let mine = try #require(after.bestImprovement(at: hill, after.view))
        #expect(mine.0 == .mine && mine.1 == 1)
        let pasture = try #require(after.bestImprovement(at: plain, after.view))
        #expect(pasture.0 == .pasture && pasture.1 == 2)
    }

    /// A Builder heads for the best-ranked worked tile: the Farm by the lake.
    @Test func builderGoesToTheBestWorkedTile() throws {
        var map = openMap()
        map[hex(8, 6)] = Tile(terrain: .lake)
        var state = makeState(map: map)
        let city = addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 2))
        updateCity(&state, city) { $0.population = 6 }
        state.assignCitizens(try #require(state.cityIndex(city)))
        try #require(state.city(city)?.workedTiles.contains(hex(7, 6)) == true)
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        let builder = state.addUnit(.builder, owner: p0, at: hex(5, 7))
        playPhase(&state)
        #expect(state.unit(builder)?.position == hex(7, 6))
    }

    /// Safety (M1 §13) holds for a Builder at work too: building takes its moves, so it would
    /// end the phase on that tile. Not within 2 tiles of a visible foreign military unit
    /// (ai-3): it works a safe tile instead, or keeps clear.
    @Test func builderDoesNotWorkWithinReachOfForeignTroops() throws {
        var state = makeState(map: openMap(width: 24, height: 12))
        let city = addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(20, 6))
        updateCity(&state, city) { $0.population = 6 }
        state.assignCitizens(try #require(state.cityIndex(city)))
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        let here = hex(7, 6)
        try #require(state.city(city)?.workedTiles.contains(here) == true)
        let builder = state.addUnit(.builder, owner: p0, at: here)
        let foreign = hex(9, 6)
        state.addUnit(.warrior, owner: p1, at: foreign)
        setRelation(&state, p0, p1, war: false, since: nil)
        refreshKnowledge(&state)
        try #require(state.map.distance(here, foreign) == 2)
        try #require(state.view(for: p0).visibleForeignUnits.contains { $0.position == foreign })
        playPhase(&state)
        let end = try #require(state.unit(builder))
        let escorted = state.units.contains { $0.owner == p0 && !$0.type.isCivilian && $0.position == end.position }
        #expect(escorted || state.map.distance(end.position, foreign) > 2, "Builder ends at \(end.position) (\(end.activity))")
    }
}

@Suite struct AISafetyAuditTests {
    /// Civilian danger (M1 §13 Safety, ai-3): within 2 tiles of every visible foreign military
    /// unit and of the non-recon ones remembered on tiles out of sight.
    @Test func rememberedTroopsCountRememberedScoutsDoNot() throws {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p1, at: hex(21, 6))
        setRelation(&state, p0, p1, war: false, since: nil)
        state.turn = 10
        let warriorAt = hex(12, 6), scoutAt = hex(12, 1)
        try #require(!state.players[0].visible[tile(state, warriorAt)] && !state.players[0].visible[tile(state, scoutAt)])
        state.players[0].memory.units = [
            UnitSighting(id: UnitID(500), owner: p1, type: .warrior, position: warriorAt, hp: 100, turnSeen: 8),
            UnitSighting(id: UnitID(501), owner: p1, type: .scout, position: scoutAt, hp: 100, turnSeen: 9),
        ]
        let turn = planned(state)
        let danger = turn.civilianDanger(turn.view)
        for t in 0..<state.map.tileCount {
            let near = state.map.distance(state.map.coord(at: t), warriorAt) <= 2
            #expect(danger[t] == near, "tile \(state.map.coord(at: t))")
        }
    }

    /// Borders betray an unseen city (ai-3): a remembered foreign tile no known city of its
    /// owner can have claimed marks sites within minDistance − 1 − initialRadius of it, so a
    /// Settler does not try to found a city the engine would refuse; once the city is known,
    /// the tile is explained.
    @Test func bordersBetrayAnUnseenCity() throws {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p1, at: hex(14, 6))
        let seen = tile(state, hex(13, 6)) // in player 1's first ring
        try #require(!state.players[0].visible[seen])
        state.players[0].memory.tileOwner[seen] = UInt8(p1.rawValue + 1)
        let reach = state.rules.constants.city.minDistance - 1 - state.rules.constants.city.initialRadius
        let turn = planned(state)
        let risk = turn.hiddenCityRisk(turn.view)
        for t in 0..<state.map.tileCount {
            #expect(risk[t] == (state.map.distance(index: t, seen) <= reach), "tile \(state.map.coord(at: t))")
        }
        reveal(&state, to: p0, from: hex(12, 6))
        let informed = planned(state)
        try #require(informed.view.knownCities.contains { $0.owner == p1 })
        #expect(!informed.hiddenCityRisk(informed.view).contains(true))
    }

    /// If every route is unsafe, a civilian travels with its escort: the escort moves first to
    /// the farthest tile of the civilian's path this phase, then the civilian joins it. Alone,
    /// it ends the phase on a safe tile.
    @Test func settlerTravelsWithItsEscort() throws {
        func world(escort: Bool) -> (AITurn, UnitID, UnitID?) {
            var state = makeState(map: openMap(width: 24, height: 12))
            addCity(&state, p0, at: hex(4, 6))
            addCity(&state, p1, at: hex(21, 6))
            state.addUnit(.warrior, owner: p0, at: hex(4, 6))
            let settler = state.addUnit(.settler, owner: p0, at: hex(6, 6))
            let guardian = escort ? state.addUnit(.warrior, owner: p0, at: hex(6, 6)) : nil
            state.addUnit(.warrior, owner: p1, at: hex(7, 4))
            setRelation(&state, p0, p1, war: false, since: nil)
            exploreMap(&state, p0)
            return (planned(state), settler, guardian)
        }
        let goal = hex(12, 6)
        let escorted = world(escort: true)
        var together = escorted.0
        let settler = escorted.1, escort = try #require(escorted.2)
        let path = try #require(together.view.path(for: settler, to: goal))
        let end = try #require(path.steps.last { $0.turn <= 1 }?.hex)
        try #require(!together.safe(tile(together.state, end), together.view, danger: together.civilianDanger(together.view)))
        together.travel(settler, to: goal)
        #expect(together.state.unit(settler)?.position == end)
        #expect(together.state.unit(escort)?.position == end)

        let lone = world(escort: false)
        var alone = lone.0
        let single = lone.1
        alone.travel(single, to: goal)
        let position = try #require(alone.state.unit(single)?.position)
        #expect(alone.state.map.distance(position, hex(7, 4)) > 2, "the lone Settler ends at \(position)")
    }

    /// A world for the Settler rules of ai-3: player 1's territory (closed to player 0's
    /// military at peace) is a band of columns `band`, with player 1's warriors on `warriors`;
    /// player 0 has explored the map and looked around `seen`.
    static func borderWorld(band: ClosedRange<Int>, warriors: [HexCoord], settler: HexCoord, seen: [HexCoord],
                            war: Bool) -> (GameState, UnitID) {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(3, 6))
        let home = addCity(&state, p1, at: hex(21, 6))
        for t in 0..<state.map.tileCount where band.contains(state.map.coord(at: t).offset.col) {
            state.tileCity[t] = Int32(home.rawValue + 1)
        }
        for spot in warriors { state.addUnit(.warrior, owner: p1, at: spot) }
        let id = state.addUnit(.settler, owner: p0, at: settler)
        setRelation(&state, p0, p1, war: war, since: nil)
        exploreMap(&state, p0)
        for spot in seen { reveal(&state, to: p0, from: spot) }
        return (state, id)
    }

    /// A Settler ends a phase anywhere but on an unsafe tile in territory closed to its
    /// player's military, where no escort could join it (ai-3): its movement field never stops
    /// there, so a site beyond a band of such tiles too wide to cross in a phase is out of its
    /// reach. At war the borders are open and the plain field serves.
    @Test func settlerStopsOnlyWhereAnEscortCouldJoinIt() throws {
        let warriors = [10, 12].flatMap { c in [1, 4, 7, 10].map { hex(c, $0) } }
        let seen = [1, 5, 9].map { hex(11, $0) }
        let (state, settler) = Self.borderWorld(band: 9...13, warriors: warriors, settler: hex(6, 6), seen: seen, war: false)
        var turn = planned(state)
        let v = turn.view
        let maybeStops = turn.settlerStops(settler, v)
        let stops = try #require(maybeStops)
        let closed = v.aiClosedToMilitary()
        let danger = turn.civilianDanger(v)
        for t in 0..<state.map.tileCount {
            let hex = state.map.coord(at: t)
            let inBand = (9...13).contains(hex.offset.col), isSafe = turn.safe(t, v, danger: danger)
            try #require(closed[t] == inBand, "tile \(hex)")
            if inBand { try #require(!isSafe, "band tile \(hex) is safe") }
            #expect(stops[t] == (!inBand || isSafe), "tile \(hex)")
        }
        let field = turn.field(settler)
        let plain = v.movementField(for: settler)
        let stoppedWhereItMayNot = (0..<state.map.tileCount).filter { !stops[$0] && field[$0] >= 0 }
        #expect(stoppedWhereItMayNot.isEmpty)
        let beyond = tile(state, hex(16, 6))
        #expect(plain[beyond] > 0, "the plain field crosses the band")
        #expect(field[beyond] < 0, "the Settler's field crosses the band")
        let path = turn.path(settler, to: hex(16, 6), v)
        #expect(path == nil)

        let (atWar, warSettler) = Self.borderWorld(band: 9...13, warriors: warriors, settler: hex(6, 6), seen: seen, war: true)
        var open = planned(atWar)
        let none = open.settlerStops(warSettler, open.view)
        #expect(none == nil)
        let warField = open.field(warSettler), warPlain = open.view.movementField(for: warSettler)
        #expect(warField == warPlain)
    }

    /// A Settler caught on an unsafe tile in a peace partner's territory, where no escort can
    /// reach it and no safe tile is in reach this phase, does not wait there for ever (ai-3):
    /// it goes on to where its path stops this phase, and asks for an escort there (p3b: where
    /// one could come; here the city with the garrison could build one).
    @Test func aSettlerCaughtWhereNoEscortCanComeMovesOn() throws {
        let at = hex(10, 6)
        let ring = HexDirection.allCases.map { at.neighbor($0).neighbor($0) }
        var (state, settler) = Self.borderWorld(band: 9...14, warriors: ring, settler: at, seen: [], war: false)
        state.addUnit(.warrior, owner: p0, at: hex(3, 6))
        var turn = planned(state)
        let v = turn.view
        let here = tile(state, at)
        let danger = turn.civilianDanger(v)
        let unit = try #require(v.unit(settler))
        let closed = v.aiClosedToMilitary()
        let hereSafe = turn.safe(here, v, danger: danger)
        try #require(closed[here] && !hereSafe)
        let safeInReach = turn.reachableThisPhase(unit).filter { turn.safe($0, v, danger: danger) }
        try #require(safeInReach.isEmpty, "a safe tile is in reach")
        let goal = hex(3, 6)
        let stop = try #require(turn.path(settler, to: goal, v)?.steps.last { $0.turn <= 1 }?.hex)
        turn.travel(settler, to: goal)
        let after = try #require(turn.state.unit(settler)?.position)
        #expect(after == stop)
        #expect(after != at)
        let end = tile(state, after)
        let escortCanJoin = !closed[end] || turn.safe(end, v, danger: danger)
        #expect(escortCanJoin)
        let waits = turn.escortWanted.contains(settler)
        #expect(waits)
    }
}

@Suite struct AIExploreAuditTests {
    /// Scouts (id order) go to the frontier tile with the lowest movement cost (ties: lower
    /// index), reserving targets within 3 of each other.
    @Test func scoutsHeadForTheCheapestFrontier() throws {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(20, 6))
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        let first = state.addUnit(.scout, owner: p0, at: hex(6, 7))
        let second = state.addUnit(.scout, owner: p0, at: hex(7, 7))
        let v = state.view(for: p0)
        let frontier = v.aiFrontier()
        func cheapest(_ id: UnitID, avoiding taken: Int?) throws -> (target: Int, end: HexCoord) {
            let f = v.movementField(for: id)
            let target = try #require(frontier.filter { g in
                f[g] > 0 && taken.map { v.aiDistance($0, g) > state.rules.ai.scoutTargetSpacing } ?? true
            }.min { (f[$0], $0) < (f[$1], $1) })
            let end = try #require(v.path(for: id, to: v.coord(at: target))?.steps.last { $0.turn <= 1 }?.hex)
            return (target, end)
        }
        let a = try cheapest(first, avoiding: nil)
        let b = try cheapest(second, avoiding: a.target)
        playPhase(&state)
        #expect(state.unit(first)?.position == a.end)
        #expect(state.unit(second)?.position == b.end)
    }

    /// No frontier left: Scouts are disbanded while upkeep is paid, otherwise they sleep next
    /// to the own city nearest the rival.
    @Test func scoutsRetireWhenAllIsExplored() throws {
        func world(warriors: Int) -> (GameState, UnitID) {
            var state = makeState(map: openMap(width: 24, height: 12))
            addCity(&state, p0, at: hex(6, 6))
            addCity(&state, p1, at: hex(18, 6))
            state.addUnit(.warrior, owner: p0, at: hex(6, 6))
            for i in 0..<warriors { state.addUnit(.warrior, owner: p0, at: hex(5 + i, 7)) }
            let scout = state.addUnit(.scout, owner: p0, at: hex(9, 6))
            exploreMap(&state, p0)
            reveal(&state, to: p0, from: hex(17, 6))
            return (state, scout)
        }
        var cheap = world(warriors: 0)
        try #require(cheap.0.view(for: p0).income().upkeep == 0 && cheap.0.view(for: p0).aiFrontier().isEmpty)
        playPhase(&cheap.0)
        let parked = try #require(cheap.0.unit(cheap.1))
        #expect(cheap.0.map.distance(parked.position, hex(6, 6)) == 1)
        #expect(parked.activity == .sleeping)
        var costly = world(warriors: 3)
        try #require(costly.0.view(for: p0).income().upkeep > 0)
        #expect(playPhase(&costly.0).commands.contains(.disband(unit: costly.1)))
    }

    /// While a met rival has no remembered city, a Scout explores toward its remembered
    /// territory: the frontier tile nearest it (ties: cheaper, lower index).
    @Test func scoutHuntsTowardTheRivalsTerritory() throws {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(20, 6))
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        let scout = state.addUnit(.scout, owner: p0, at: hex(6, 7))
        explore(&state, p0, within: 4, of: hex(6, 6))
        setRelation(&state, p0, p1, war: false, since: nil)
        let anchor = tile(state, hex(19, 6))
        try #require(!state.players[0].visible[anchor])
        state.players[0].memory.tileOwner[anchor] = UInt8(p1.rawValue + 1)
        let v = state.view(for: p0)
        let f = v.movementField(for: scout)
        let target = try #require(v.aiFrontier().filter { f[$0] > 0 }.min { a, b in
            (v.aiDistance(a, anchor), f[a], a) < (v.aiDistance(b, anchor), f[b], b)
        })
        let end = try #require(v.path(for: scout, to: v.coord(at: target))?.steps.last { $0.turn <= 1 }?.hex)
        playPhase(&state)
        #expect(state.unit(scout)?.position == end)
        #expect(state.map.distance(end, hex(19, 6)) < state.map.distance(hex(6, 7), hex(19, 6)))
    }
}

@Suite struct AIWarAuditTests {
    /// The war test needs 100·army ≥ 130·estimate(R): against a rival seen with a big army,
    /// no war (the AI keeps preparing).
    @Test func noWarWithoutTheArmyRatio() throws {
        var state = AIWarTests.world(turn: 40, archers: 2, warriors: 2)
        state.players[0].memory.units = (0..<6).map { i in
            UnitSighting(id: UnitID(900 + i), owner: p1, type: .spearman, position: hex(17, 2 + i), hp: 100, turnSeen: 38)
        }
        let turn = planned(state)
        try #require(100 * turn.plan.army < 130 * turn.plan.estimate)
        let (commands, report) = playPhase(&state)
        #expect(!commands.contains(.declareWar(on: p1)))
        #expect(report.posture == .prepare)
    }

    /// At most one offensive war at a time: at war with one player, none is declared on
    /// another for which the war test holds.
    @Test func oneWarAtATime() {
        var state = makeState(map: openMap(width: 24, height: 12), players: 3)
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p1, at: hex(14, 6))
        addCity(&state, p2, at: hex(21, 1))
        state.players[0].knownTechs.append("archery")
        state.addUnit(.warrior, owner: p0, at: hex(4, 6))
        for spot in [hex(5, 6), hex(3, 6)] { state.addUnit(.archer, owner: p0, at: spot) }
        for spot in [hex(4, 5), hex(4, 7)] { state.addUnit(.warrior, owner: p0, at: spot) }
        reveal(&state, to: p0, from: hex(13, 6))
        setRelation(&state, p0, p1, war: false, since: nil)
        setRelation(&state, p0, p2, war: true, since: 35)
        state.turn = 40
        let (commands, report) = playPhase(&state)
        #expect(!commands.contains(.declareWar(on: p1)))
        #expect(report.posture == .war)
    }

    /// R = the met rival with the highest army / max(estimate, 1), i.e. the lowest estimate;
    /// ties: the nearest remembered city.
    @Test func rivalIsTheWeakestKnownThenTheNearest() {
        var state = makeState(map: openMap(width: 30, height: 14), players: 3)
        addCity(&state, p0, at: hex(4, 7))
        addCity(&state, p1, at: hex(14, 7))
        addCity(&state, p2, at: hex(24, 7))
        state.addUnit(.warrior, owner: p0, at: hex(4, 7))
        reveal(&state, to: p0, from: hex(13, 7))
        reveal(&state, to: p0, from: hex(23, 7))
        setRelation(&state, p0, p1, war: false, since: nil)
        setRelation(&state, p0, p2, war: false, since: nil)
        state.turn = 40
        #expect(planned(state).plan.rival == p1) // equal estimates: the nearer
        state.players[0].memory.units = [UnitSighting(id: UnitID(900), owner: p1, type: .warrior, position: hex(16, 3), hp: 100, turnSeen: 39)]
        #expect(planned(state).plan.rival == p2) // player 1 seen with a unit: player 2 is weaker
    }

    /// Target: R's remembered city with the lowest path cost from the capital, but within
    /// targetCostTolerance a non-capital first, then the lower id. Rally: the own city with the
    /// lowest path cost to the target.
    @Test func targetAndRallyCity() throws {
        var state = makeState(map: openMap(width: 30, height: 14))
        addCity(&state, p0, at: hex(4, 7))
        let forward = addCity(&state, p0, at: hex(9, 3))
        addCity(&state, p1, at: hex(16, 7)) // player 1's capital: cost 12 from player 0's
        let town = addCity(&state, p1, at: hex(16, 3)) // cost 14
        addCity(&state, p1, at: hex(16, 11)) // cost 14, higher id
        addCity(&state, p1, at: hex(26, 7)) // cost 22
        state.addUnit(.warrior, owner: p0, at: hex(4, 7))
        for spot in [hex(15, 7), hex(15, 3), hex(15, 11), hex(25, 7)] { reveal(&state, to: p0, from: spot) }
        try #require(state.view(for: p0).knownCities.filter { $0.owner == p1 }.count == 4)
        setRelation(&state, p0, p1, war: false, since: nil)
        state.turn = 40
        let plan = planned(state).plan
        #expect(plan.rival == p1)
        #expect(plan.target?.id == town)
        #expect(plan.rally?.id == forward)
    }

    /// The army advances on the target once advanceArmyUnits army units stand within
    /// rallyRadius of the rally city, or advanceAfterTurns turns after the declaration.
    @Test func advanceWhenGatheredOrAfterEightTurns() {
        func world(units: Int, since: Int) -> GameState {
            var state = makeState(map: openMap(width: 24, height: 12))
            addCity(&state, p0, at: hex(4, 6))
            addCity(&state, p1, at: hex(18, 6))
            state.addUnit(.warrior, owner: p0, at: hex(4, 6))
            for spot in [hex(3, 6), hex(4, 5), hex(4, 7), hex(3, 5), hex(3, 7)].prefix(units) {
                state.addUnit(.warrior, owner: p0, at: spot)
            }
            reveal(&state, to: p0, from: hex(17, 6))
            state.turn = 50
            setRelation(&state, p0, p1, war: true, since: since)
            return state
        }
        #expect(!planned(world(units: 3, since: 45)).plan.advancing)
        #expect(planned(world(units: 4, since: 45)).plan.advancing)
        #expect(planned(world(units: 3, since: 42)).plan.advancing)
    }
}

@Suite struct AITacticsAuditTests {
    /// Tactic 3 against units: attack when the expected damage dealt beats the damage taken or
    /// the kill chance is ≥ 50%; otherwise not.
    @Test func meleeAttacksOnlyGoodTrades() throws {
        func world(foe type: UnitType, hp: Int, terrain: Tile) -> (GameState, UnitID) {
            var map = openMap(width: 24, height: 12)
            map[hex(11, 6)] = terrain
            var state = makeState(map: map)
            addCity(&state, p0, at: hex(4, 6))
            addCity(&state, p1, at: hex(20, 6))
            state.addUnit(.warrior, owner: p0, at: hex(4, 6))
            let warrior = state.addUnit(.warrior, owner: p0, at: hex(10, 6))
            let foe = state.addUnit(type, owner: p1, at: hex(11, 6))
            state.updateUnit(foe) { $0.hp = hp }
            setRelation(&state, p0, p1, war: true, since: 1)
            refreshKnowledge(&state)
            return (state, warrior)
        }
        var weak = world(foe: .warrior, hp: 20, terrain: Tile(terrain: .grassland))
        let kill = try #require(weak.0.view(for: p0).combatPreview(attacker: .unit(weak.1), target: hex(11, 6), from: hex(10, 6)))
        try #require(kill.killChance(atLeast: 50))
        #expect(playPhase(&weak.0).commands.contains(.attack(unit: weak.1, target: hex(11, 6))))

        var strong = world(foe: .spearman, hp: 100, terrain: Tile(terrain: .grassland, elevation: .hills))
        let bad = try #require(strong.0.view(for: p0).combatPreview(attacker: .unit(strong.1), target: hex(11, 6), from: hex(10, 6)))
        try #require(!bad.killChance(atLeast: 50) && bad.meanDealt <= bad.meanTaken)
        #expect(!playPhase(&strong.0).commands.contains { attacks($0, by: strong.1) })
    }

    /// Tactic 4: a unit below 40 HP goes to the nearest own city it reaches and fortifies.
    @Test func woundedUnitRetreatsToTheCity() throws {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(20, 6))
        let wounded = state.addUnit(.warrior, owner: p0, at: hex(8, 6))
        state.updateUnit(wounded) { $0.hp = 30 }
        state.addUnit(.warrior, owner: p1, at: hex(11, 6))
        setRelation(&state, p0, p1, war: true, since: 1)
        refreshKnowledge(&state)
        playPhase(&state)
        let after = try #require(state.unit(wounded))
        #expect(after.position == hex(6, 6))
        #expect(after.activity == .fortifying || after.activity == .fortified)
    }

    /// Tactic 5: a city at ≤ 100 HP with an enemy next to it buys its best defender and calls
    /// back the army units within 5 tiles.
    @Test func besiegedCityBuysADefenderAndRecallsTheArmy() throws {
        var state = makeState(map: openMap(width: 24, height: 12), gold: 500)
        let city = addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(20, 6))
        updateCity(&state, city) { $0.hp = 90 }
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        let soldier = state.addUnit(.warrior, owner: p0, at: hex(10, 6)) // 4 tiles out, 3 from the enemy
        state.addUnit(.warrior, owner: p1, at: hex(7, 6))
        setRelation(&state, p0, p1, war: true, since: 1)
        refreshKnowledge(&state)
        let (commands, _) = playPhase(&state)
        #expect(commands.contains(.purchase(city: city, item: .unit(.warrior))))
        let back = try #require(state.unit(soldier))
        #expect(state.map.distance(back.position, hex(6, 6)) < 4)
    }

    /// Tactic 6: at war, a unit that reaches an unescorted enemy civilian this phase captures
    /// it, unless 2+ visible enemies stand next to the civilian.
    @Test func unescortedCiviliansAreCaptured() throws {
        func world(guards: Int) -> (GameState, UnitID) {
            var state = makeState(map: openMap(width: 24, height: 12))
            addCity(&state, p0, at: hex(20, 6))
            addCity(&state, p1, at: hex(2, 6))
            state.addUnit(.warrior, owner: p0, at: hex(20, 6))
            let hunter = state.addUnit(.warrior, owner: p0, at: hex(13, 6))
            state.addUnit(.scout, owner: p0, at: hex(8, 6)) // sees the guards
            state.addUnit(.builder, owner: p1, at: hex(11, 6))
            for spot in [hex(10, 5), hex(10, 7)].prefix(guards) { state.addUnit(.spearman, owner: p1, at: spot) }
            setRelation(&state, p0, p1, war: true, since: 1)
            refreshKnowledge(&state)
            return (state, hunter)
        }
        var open = world(guards: 0)
        #expect(playPhase(&open.0).commands.contains(.moveUnit(unit: open.1, to: hex(11, 6))))
        #expect(open.0.units.contains { $0.owner == p0 && $0.type == .builder })
        var guarded = world(guards: 2)
        try #require(guarded.0.view(for: p0).visibleForeignUnits.filter { $0.type == .spearman }.count == 2)
        #expect(!playPhase(&guarded.0).commands.contains(.moveUnit(unit: guarded.1, to: hex(11, 6))))
    }

    /// p3d ai-idle-tactics (HeadlessSim seed 23, turn 145: Archers standing idle by an enemy
    /// city): a unit whose move to its attack tile fails — another unit took that tile meanwhile —
    /// keeps its moves and stays free for the later orders. Before, an attack made it done for the
    /// phase at once, and it stood idle with all its moves.
    @Test func aUnitWhoseMoveToAttackFailsStaysFree() throws {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p1, at: hex(20, 6))
        state.addUnit(.warrior, owner: p0, at: hex(4, 6))
        let archer = state.addUnit(.archer, owner: p0, at: hex(8, 6))
        let target = hex(11, 6)
        let foe = state.addUnit(.warrior, owner: p1, at: target)
        let taken = hex(9, 6)
        state.addUnit(.spearman, owner: p0, at: taken)
        setRelation(&state, p0, p1, war: true, since: 1)
        refreshKnowledge(&state)
        try #require(state.map.distance(taken, target) <= state.rules.unit(.archer).range)
        var turn = planned(state)
        let moves = state.maxMoves(of: state.unit(archer)!)
        let hit = turn.attack(archer, AttackOption(target: target, defender: .unit(foe), from: taken, moveCost: 1))
        #expect(!hit)
        #expect(!turn.acted.contains(archer))
        #expect(turn.state.unit(archer)?.movesLeft == moves)
        turn.moveMilitary()
        let after = try #require(turn.state.unit(archer))
        let idle = after.activity == .none && after.destination == nil && after.movesLeft == moves
        #expect(!idle, "the Archer stands idle at \(after.position)")
    }

    /// p3d ai-idle-tactics (HeadlessSim seed 33, turn 121): a besieged city calls back its army
    /// (tactic 5), but every tile next to it is taken. A unit within 2 tiles of the city fortifies
    /// where it stands; one farther away heads for the cheapest free own tile within 2 of the city
    /// (here 3 moves off: it gets closer this phase). Before, both stood idle with all their moves.
    @Test func recalledUnitsFindNoFreeTileByTheCity() throws {
        var state = makeState(map: openMap(width: 24, height: 12), gold: 0)
        let centre = hex(6, 6)
        let city = addCity(&state, p0, at: centre)
        addCity(&state, p1, at: hex(20, 6))
        updateCity(&state, city) { $0.hp = 90 }
        var claimed = Effects() // the city's borders out to 2 tiles
        for h in state.map.coords(within: 2, of: centre) {
            state.tileCity[tile(state, h)] = Int32(city.rawValue + 1)
            claimed.touchTile(tile(state, h))
        }
        claimed.touchAllPlayers(state.players.count)
        state.updateKnowledge(&claimed)
        state.addUnit(.warrior, owner: p0, at: centre)
        let ring = state.map.coords(within: 1, of: centre).filter { $0 != centre }
        try #require(ring.count == 6)
        for (i, h) in ring.enumerated() { state.addUnit(.spearman, owner: i % 2 == 0 ? p1 : p0, at: h) }
        let near = state.addUnit(.warrior, owner: p0, at: hex(8, 6))
        let far = state.addUnit(.warrior, owner: p0, at: hex(10, 6))
        setRelation(&state, p0, p1, war: true, since: 1)
        refreshKnowledge(&state)
        try #require(state.map.distance(hex(8, 6), centre) == 2 && state.map.distance(hex(10, 6), centre) == 4)
        var turn = planned(state)
        turn.defendCities()
        let a = try #require(turn.state.unit(near))
        #expect(a.position == hex(8, 6) && (a.activity == .fortifying || a.activity == .fortified), "\(a.position) \(a.activity)")
        let b = try #require(turn.state.unit(far))
        #expect(state.map.distance(b.position, centre) < 4 && b.movesLeft == 0, "\(b.position.offset) \(b.activity)")
    }

    /// "Garrisons fortify."
    @Test func garrisonsFortify() {
        var state = makeState()
        addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 2))
        let garrison = state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        #expect(playPhase(&state).commands.contains(.fortify(unit: garrison)))
    }
}
