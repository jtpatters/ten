import Foundation
import Testing
@testable import GameCore

// A city at (2,2) on the test map works one grassland tile; per phase it makes Food 4 (eats 2),
// Production 4 (centre 1 + 1, Palace 2), Gold 3, Science 4 and Culture 2. Its neighbours are
// (3,2), (2,1), (1,1), (1,2), (1,3) and (2,3).

@Suite struct FoundingTests {
    @Test func aSettlerFoundsTheCapital() throws {
        var state = makeTestState()
        let settler = state.addUnit(.settler, owner: PlayerID(0), at: hex(2, 2))
        let records = try apply(.foundCity(unit: settler), &state)
        #expect(state.unit(settler) == nil)
        let city = try #require(state.city(at: hex(2, 2)))
        let names = state.rules.civ(state.players[0].civ)!.cityNames
        #expect(city.population == 1 && city.owner == PlayerID(0) && city.hp == 200 && city.foundedTurn == 1)
        #expect(city.name == names[0])
        #expect(city.buildings == ["palace"])
        #expect(city.storedProgress == state.rules.constants.city.foundingProduction && city.storedProgress == 40)
        #expect(state.players[0].capital == city.id && state.players[0].originalCapital == city.id)
        // It owns its centre and every unowned tile at distance 1.
        let owned = (0..<state.map.tileCount).filter { state.tileOwner($0) == PlayerID(0) }
        #expect(owned.map { state.map.coord(at: $0) }.sorted { $0.offset.row * 100 + $0.offset.col < $1.offset.row * 100 + $1.offset.col }
            == [hex(1, 1), hex(2, 1), hex(1, 2), hex(2, 2), hex(3, 2), hex(1, 3), hex(2, 3)])
        #expect(events(records).contains(.cityFounded(city: city.id, name: city.name, owner: PlayerID(0), at: hex(2, 2))))
        expectSound(state)

        // The second city has no Palace and takes the next name.
        let second = state.addUnit(.settler, owner: PlayerID(0), at: hex(8, 2))
        try apply(.foundCity(unit: second), &state)
        let city2 = try #require(state.city(at: hex(8, 2)))
        #expect(city2.buildings.isEmpty && city2.name == names[1] && city2.storedProgress == 40)
        #expect(state.players[0].capital == city.id)
    }

    @Test func cityNamesContinueWithNew() {
        var state = makeTestState()
        let names = state.rules.civ(state.players[0].civ)!.cityNames
        state.players[0].citiesNamed = names.count
        #expect(state.nextCityName(for: PlayerID(0)) == "New " + names[0])
        state.players[0].citiesNamed = names.count + 1
        #expect(state.nextCityName(for: PlayerID(0)) == "New " + names[1])
    }

    /// Passable land, not an oasis, not another player's, at distance ≥ 4 from every city; a
    /// rejection says only "site not valid" and reveals the city in the way (M1 §5).
    @Test func foundingRules() throws {
        var map = makeTestMap(width: 24, height: 12)
        map[hex(2, 9)] = Tile(terrain: .desert, feature: .oasis)
        var state = makeTestState(map: map)
        let theirs = addCity(&state, PlayerID(1), at: hex(14, 5))
        let siteRejected = CommandError.rejected(reason: "site not valid")

        // Too close to a city player 0 has never seen.
        let s1 = state.addUnit(.settler, owner: PlayerID(0), at: hex(11, 5))
        #expect(!state.players[0].visible[state.map.index(of: hex(14, 5))!])
        #expect(state.players[0].memory.city(theirs) == nil)
        #expect(state.view(for: PlayerID(0)).canFoundCity(at: hex(11, 5))) // as far as player 0 knows
        #expect(throws: siteRejected) { try apply(.foundCity(unit: s1), &state) }
        #expect(state.players[0].memory.city(theirs)?.position == hex(14, 5))
        #expect(!state.view(for: PlayerID(0)).canFoundCity(at: hex(11, 5)))
        #expect(state.unit(s1) != nil)

        // Another player's territory, though far enough from the city.
        let far = state.map.index(of: hex(18, 5))!
        state.tileCity[far] = Int32(theirs.rawValue + 1)
        refreshKnowledge(&state)
        let s2 = state.addUnit(.settler, owner: PlayerID(0), at: hex(18, 5))
        #expect(throws: siteRejected) { try apply(.foundCity(unit: s2), &state) }

        // An oasis.
        let s3 = state.addUnit(.settler, owner: PlayerID(0), at: hex(2, 9))
        #expect(throws: siteRejected) { try apply(.foundCity(unit: s3), &state) }

        // Only Settlers found cities.
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 3))
        #expect(throws: CommandError.rejected(reason: "only Settlers found cities")) { try apply(.foundCity(unit: warrior), &state) }

        // A valid site: the improvement on it goes (none on city centres).
        let site = state.map.index(of: hex(6, 9))!
        state.map[index: site].improvement = .farm
        let s4 = state.addUnit(.settler, owner: PlayerID(0), at: hex(6, 9))
        try apply(.foundCity(unit: s4), &state)
        #expect(state.city(at: hex(6, 9)) != nil && state.map.tiles[site].improvement == nil)
        expectSound(state)
    }
}

@Suite struct YieldTests {
    let rules = Ruleset.standard
    let none: (TechID) -> Bool = { _ in false }
    let all: (TechID) -> Bool = { _ in true }

    @Test func tileYieldsFollowTheTables() {
        func y(_ tile: Tile, techs: Bool = false, lake: Bool = false) -> Yields {
            rules.tileYields(tile, knows: techs ? all : none, touchesLake: lake)
        }
        #expect(y(Tile(terrain: .grassland)) == Yields(food: 2))
        #expect(y(Tile(terrain: .plains)) == Yields(food: 1, production: 1))
        #expect(y(Tile(terrain: .desert)) == .zero && y(Tile(terrain: .snow)) == .zero)
        #expect(y(Tile(terrain: .tundra)) == Yields(food: 1))
        #expect(y(Tile(terrain: .ocean)) == Yields(food: 1))
        #expect(y(Tile(terrain: .coast)) == Yields(food: 1, gold: 1))
        #expect(y(Tile(terrain: .coast), techs: true) == Yields(food: 2, gold: 1)) // Sailing
        #expect(y(Tile(terrain: .lake)) == Yields(food: 2, gold: 1))
        #expect(y(Tile(terrain: .lake), techs: true) == Yields(food: 3, gold: 1))
        #expect(y(Tile(terrain: .plains, elevation: .hills)) == Yields(food: 1, production: 2))
        #expect(y(Tile(terrain: .grassland, feature: .forest)) == Yields(food: 2, production: 1))
        #expect(y(Tile(terrain: .grassland, feature: .jungle)) == Yields(food: 3))
        #expect(y(Tile(terrain: .grassland, feature: .marsh)) == Yields(food: 3))
        #expect(y(Tile(terrain: .desert, feature: .floodplain)) == Yields(food: 2))
        #expect(y(Tile(terrain: .desert, feature: .oasis)) == Yields(food: 3, gold: 1))
        #expect(y(Tile(terrain: .coast, feature: .reef)) == Yields(food: 2, production: 1, gold: 1))
        #expect(y(Tile(terrain: .grassland, riverEdges: 0b100)) == Yields(food: 2, gold: 1))

        #expect(y(Tile(terrain: .grassland, improvement: .farm)) == Yields(food: 3))
        #expect(y(Tile(terrain: .grassland, improvement: .farm), lake: true) == Yields(food: 3))
        #expect(y(Tile(terrain: .grassland, improvement: .farm), techs: true, lake: true) == Yields(food: 4)) // Irrigation
        #expect(y(Tile(terrain: .grassland, riverEdges: 1, improvement: .farm), techs: true) == Yields(food: 4, gold: 1))
        #expect(y(Tile(terrain: .plains, elevation: .hills, improvement: .mine)) == Yields(food: 1, production: 4))
        #expect(y(Tile(terrain: .plains, improvement: .pasture)) == Yields(food: 1, production: 2, gold: 1))
    }

    /// The tile's yields without its feature (forest, jungle, marsh and Floodplain alike), Food
    /// raised to 2 and Production to 1, then +1 Production, +1 Science, +1 Culture (M1 §4).
    @Test func cityCentreYields() {
        func centre(_ tile: Tile) -> Yields { rules.tileYields(tile, knows: none, isCityCentre: true) }
        #expect(centre(Tile(terrain: .desert)) == Yields(food: 2, production: 2, science: 1, culture: 1))
        #expect(centre(Tile(terrain: .grassland, feature: .forest)) == Yields(food: 2, production: 2, science: 1, culture: 1))
        #expect(centre(Tile(terrain: .plains, elevation: .hills)) == Yields(food: 2, production: 3, science: 1, culture: 1))
        #expect(centre(Tile(terrain: .grassland, feature: .jungle)) == Yields(food: 2, production: 2, science: 1, culture: 1))
        #expect(centre(Tile(terrain: .desert, feature: .floodplain)) == Yields(food: 2, production: 2, science: 1, culture: 1))
        // "Without feature": the Floodplain's +2 Food does not count on the centre (core-3 audit).
        #expect(centre(Tile(terrain: .grassland, feature: .floodplain)) == Yields(food: 2, production: 2, science: 1, culture: 1))
        #expect(centre(Tile(terrain: .plains, feature: .floodplain)) == Yields(food: 2, production: 2, science: 1, culture: 1))
        #expect(centre(Tile(terrain: .plains, elevation: .hills, feature: .forest)) == Yields(food: 2, production: 3, science: 1, culture: 1))
        // Improvements never count on the centre.
        #expect(centre(Tile(terrain: .grassland, improvement: .farm)) == Yields(food: 2, production: 2, science: 1, culture: 1))
        #expect(centre(Tile(terrain: .grassland, riverEdges: 1)) == Yields(food: 2, production: 2, gold: 1, science: 1, culture: 1))
    }

    @Test func cityYieldsWithTheirSources() throws {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        let yields = state.cityYields(try #require(state.city(id)))
        #expect(yields.total == Yields(food: 4, production: 4, gold: 3, science: 4, culture: 2))
        #expect(yields.foodEaten == 2 && yields.foodSurplus == 2)
        #expect(yields.breakdown.map(\.source) == [.centre, .workedTiles, .building("palace")])
        // +1 Science per 2 population; citizens with no tile make +1 Production each.
        updateCity(&state, id) { $0.population = 8 }
        state.assignCitizens(state.cityIndex(id)!)
        let big = state.cityYields(try #require(state.city(id)))
        #expect(state.city(id)!.workedTiles.count == 6)
        #expect(big.breakdown.contains { $0.source == .unemployed && $0.yields == Yields(production: 2) })
        #expect(big.breakdown.contains { $0.source == .population && $0.yields == Yields(science: 4) })
        #expect(big.foodEaten == 16)
    }
}

@Suite struct CitizenTests {
    /// Around (2,2): grassland at (3,2), desert at (2,1), plains hills on the other four.
    func makeState() -> (GameState, CityID) {
        var map = makeTestMap()
        map[hex(2, 1)] = Tile(terrain: .desert)
        for h in [hex(1, 1), hex(1, 2), hex(1, 3), hex(2, 3)] { map[h] = Tile(terrain: .plains, elevation: .hills) }
        var state = makeTestState(map: map)
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        updateCity(&state, id) { $0.population = 2 }
        state.assignCitizens(state.cityIndex(id)!)
        return (state, id)
    }

    /// Balanced: the hills (value 7) would drop the food surplus below +2, so the first citizen
    /// takes the grassland (value 6); no tile keeps the floor for the second, which takes the
    /// tile with the most Food (hills over desert; ties by value, distance, then index).
    @Test func theFoodFloorComesFirst() {
        let (state, id) = makeState()
        #expect(state.city(id)!.workedTiles == [hex(1, 1), hex(3, 2)])
        #expect(state.cityYields(state.city(id)!).foodSurplus == 1)
    }

    @Test func focusChangesWhatCitizensWork() throws {
        let made = makeState()
        var state = made.0
        let id = made.1
        try apply(.setFocus(city: id, focus: .production), &state) // floor 0: the hills
        #expect(state.city(id)!.workedTiles == [hex(1, 1), hex(1, 2)])
        try apply(.setFocus(city: id, focus: .food), &state)
        #expect(state.city(id)!.workedTiles == [hex(1, 1), hex(3, 2)])
        try apply(.setFocus(city: id, focus: .gold), &state) // hills and grassland tie at 4: lower index
        #expect(state.city(id)!.workedTiles == [hex(1, 1), hex(1, 2)])
        #expect(state.city(id)!.focus == .gold)
    }

    @Test func citizensAvoidTilesWithEnemyUnits() throws {
        let made = makeState()
        var state = made.0
        let id = made.1
        setWar(&state, PlayerID(0), PlayerID(1))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(1, 1))
        try apply(.setFocus(city: id, focus: .production), &state)
        #expect(state.city(id)!.workedTiles == [hex(1, 2), hex(1, 3)])
    }
}

@Suite struct GrowthTests {
    @Test func citiesGrowAtTheThresholdAndKeepTheOverflow() throws {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        // The surplus is +2; p3f: the threshold at population 1 is 11 (growth.base).
        #expect(state.rules.growthThreshold(population: 1) == 11)
        updateCity(&state, id) { $0.foodStore = 10 }
        try endPhases(until: PlayerID(1), &state)
        #expect(state.city(id)!.population == 1) // only at the owner's phase start
        let records = try apply(.endTurn, &state)
        #expect(state.city(id)!.population == 2 && state.city(id)!.foodStore == 1)
        #expect(events(records).contains(.cityGrew(city: id, population: 2, at: hex(2, 2))))
    }

    @Test func starvingCitiesShrink() throws {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        // 8 citizens, 6 tiles: Food 2 + 6·2 = 14, eaten 16.
        updateCity(&state, id) { $0.population = 8; $0.foodStore = 1 }
        try nextTurn(&state)
        #expect(state.city(id)!.population == 7 && state.city(id)!.foodStore == 0)

        // Never below 1.
        updateCity(&state, id) { $0.population = 1; $0.foodStore = 0 }
        var fx = Effects()
        state.runGrowth(inCity: state.cityIndex(id)!, surplus: -5, &fx)
        #expect(state.city(id)!.population == 1 && state.city(id)!.foodStore == 0)
    }
}

/// A city with nothing stored: its founding production (M1 §5) is cleared, so a test times the
/// phase's production alone.
@discardableResult
private func addBareCity(_ state: inout GameState, _ player: PlayerID, at hex: HexCoord) -> CityID {
    let id = addCity(&state, player, at: hex)
    updateCity(&state, id) { $0.storedProgress = 0 }
    return id
}

@Suite struct ProductionTests {
    /// p3d core-new-city-production: every city starts with 40 stored progress (a Warrior's
    /// cost), which the first item that can complete takes at the next phase start; the
    /// empty-queue cap never takes it away.
    @Test func aNewCityStartsWithItsFoundingProduction() throws {
        var state = makeTestState()
        let settler = state.addUnit(.settler, owner: PlayerID(0), at: hex(2, 2))
        try apply(.foundCity(unit: settler), &state)
        let id = try #require(state.city(at: hex(2, 2))).id
        #expect(state.city(id)!.storedProgress == 40)
        let warrior = try #require(state.view(for: PlayerID(0)).productionOptions(for: id).first { $0.item == .unit(.warrior) })
        #expect(warrior.turns == 1)
        // p3f: a Settler alone at population 1 takes the 40 and the phase's 4 while it waits.
        // Removed, its progress goes back to stored progress, which an empty queue's cap (2 × 4)
        // never takes away.
        try apply(.setQueue(city: id, items: [.unit(.settler)]), &state)
        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.settler), progress: 44)] && state.city(id)!.storedProgress == 0)
        try apply(.setQueue(city: id, items: []), &state)
        #expect(state.city(id)!.storedProgress == 44)
        try nextTurn(&state)
        #expect(state.city(id)!.storedProgress == 44)
        // The first item that can complete takes it: 44 + 4 ≥ 40; the overflow is capped at 4.
        try apply(.setQueue(city: id, items: [.unit(.warrior)]), &state)
        try endPhases(until: PlayerID(1), &state)
        let records = try apply(.endTurn, &state) // player 0's phase starts
        #expect(events(records).contains(.productionCompleted(city: id, item: .unit(.warrior), at: hex(2, 2))))
        #expect(state.city(id)!.queue.isEmpty && state.city(id)!.storedProgress == 4)
        // Below the cap, an empty queue stores production up to the cap as before.
        try nextTurn(&state)
        #expect(state.city(id)!.storedProgress == 8)
        try nextTurn(&state)
        #expect(state.city(id)!.storedProgress == 8)
    }

    @Test func oneItemCompletesPerPhaseWithItsOverflowCapped() throws {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        try apply(.setQueue(city: id, items: [.unit(.warrior), .unit(.scout)]), &state)
        updateCity(&state, id) { city in
            city.queue[0].progress = 39
            city.storedProgress = 10
        }
        try endPhases(until: PlayerID(1), &state)
        let records = try apply(.endTurn, &state)
        let city = try #require(state.city(id))
        // 39 + 4 + 10 = 53: the Warrior completes; the overflow 13 is capped at the phase's 4.
        #expect(city.queue == [QueueEntry(.unit(.scout))])
        #expect(city.storedProgress == 4)
        let warrior = try #require(state.units(at: hex(2, 2)).first { $0.type == .warrior })
        #expect(warrior.owner == PlayerID(0))
        let completed = try #require(records.first { $0.event == .productionCompleted(city: id, item: .unit(.warrior), at: hex(2, 2)) })
        #expect(completed.audience == 0b01) // the owner only
        #expect(events(records).contains(.unitCreated(unit: warrior.id, type: .warrior, owner: PlayerID(0), at: hex(2, 2))))

        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.scout), progress: 8)])
        #expect(state.city(id)!.storedProgress == 0)
    }

    /// A Settler waits in a city of population 1 while the next item gets the production (once
    /// it holds its cost, p3f: see OpeningTempoTests); it costs 1 population when it completes.
    @Test func settlersWaitForPopulationTwo() throws {
        var state = makeTestState()
        let id = addBareCity(&state, PlayerID(0), at: hex(2, 2))
        try apply(.setQueue(city: id, items: [.unit(.settler), .unit(.warrior)]), &state)
        updateCity(&state, id) { $0.queue[0].progress = 60 }
        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.settler), progress: 60), QueueEntry(.unit(.warrior), progress: 4)])

        updateCity(&state, id) { city in
            city.population = 2
            city.queue[0].progress = 78
        }
        try endPhases(until: PlayerID(1), &state)
        let records = try apply(.endTurn, &state)
        #expect(state.city(id)!.population == 1)
        #expect(state.city(id)!.queuedItems == [.unit(.warrior)])
        #expect(state.units(at: hex(2, 2)).contains { $0.type == .settler && $0.owner == PlayerID(0) })
        #expect(events(records).contains(.cityShrank(city: id, population: 1, at: hex(2, 2))))
    }

    @Test func anEmptyQueueStoresUpToTwiceThePhasesProduction() throws {
        var state = makeTestState()
        let id = addBareCity(&state, PlayerID(0), at: hex(2, 2))
        try nextTurn(&state)
        #expect(state.city(id)!.storedProgress == 4)
        try nextTurn(&state)
        try nextTurn(&state)
        #expect(state.city(id)!.storedProgress == 8)
        try apply(.setQueue(city: id, items: [.building("monument")]), &state)
        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.building("monument"), progress: 12)])
        #expect(state.city(id)!.storedProgress == 0)
    }

    @Test func unitsAppearOnTheNearestFreeOwnedTile() throws {
        var state = makeTestState()
        let id = addBareCity(&state, PlayerID(0), at: hex(2, 2))
        state.addUnit(.warrior, owner: PlayerID(0), at: hex(2, 2))
        try apply(.purchase(city: id, item: .unit(.warrior)), &state)
        // Nearest own tiles: the six neighbours; the lowest index is (1,1).
        #expect(state.units(at: hex(1, 1)).contains { $0.type == .warrior })

        for h in [hex(2, 1), hex(1, 2), hex(3, 2), hex(1, 3), hex(2, 3)] { state.addUnit(.warrior, owner: PlayerID(0), at: h) }
        #expect(throws: CommandError.rejected(reason: "no room to place the unit")) {
            try apply(.purchase(city: id, item: .unit(.warrior)), &state)
        }
        try apply(.purchase(city: id, item: .unit(.builder)), &state) // the civilian slot is free
        #expect(state.units(at: hex(2, 2)).contains { $0.type == .builder })

        // A unit with no room waits; the production goes to stored progress.
        try apply(.setQueue(city: id, items: [.unit(.scout)]), &state)
        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.scout))])
        #expect(state.city(id)!.storedProgress == 4)
    }

    @Test func buyingCompletesAnItemAtOnce() throws {
        var state = makeTestState(gold: 300)
        let id = addBareCity(&state, PlayerID(0), at: hex(2, 2))
        try apply(.setQueue(city: id, items: [.building("monument"), .unit(.warrior)]), &state)
        updateCity(&state, id) { $0.queue[0].progress = 10 }

        let records = try apply(.purchase(city: id, item: .building("monument")), &state)
        let monument = state.rules.building("monument")!.cost, warrior = state.rules.unit(.warrior).cost
        #expect(state.players[0].gold == 300 - 3 * monument)
        #expect(state.city(id)!.has("monument"))
        #expect(state.city(id)!.queuedItems == [.unit(.warrior)])
        #expect(state.city(id)!.storedProgress == 10)
        #expect(events(records) == [.productionCompleted(city: id, item: .building("monument"), at: hex(2, 2))])

        // It is not the phase's completion: the queue still completes an item.
        try apply(.purchase(city: id, item: .unit(.warrior)), &state)
        #expect(state.players[0].gold == 300 - 3 * (monument + warrior))
        updateCity(&state, id) { $0.queue[0].progress = 30 }
        try nextTurn(&state)
        #expect(state.city(id)!.queue.isEmpty)
        #expect(state.units(of: PlayerID(0)).filter { $0.type == .warrior }.count == 2)

        let gold = state.players[0].gold
        #expect(throws: CommandError.rejected(reason: "needs 120 gold")) { try apply(.purchase(city: id, item: .unit(.warrior)), &state) }
        #expect(throws: CommandError.rejected(reason: "needs population 2")) { try apply(.purchase(city: id, item: .unit(.settler)), &state) }
        #expect(throws: CommandError.rejected(reason: "already built")) { try apply(.purchase(city: id, item: .building("monument")), &state) }
        #expect(throws: CommandError.rejected(reason: "needs Pottery")) { try apply(.purchase(city: id, item: .building("granary")), &state) }
        #expect(state.players[0].gold == gold)
    }

    @Test func queueRules() throws {
        var state = makeTestState()
        let id = addBareCity(&state, PlayerID(0), at: hex(2, 2))
        func setQueue(_ items: [ProductionItem]) throws { try apply(.setQueue(city: id, items: items), &state) }
        #expect(throws: CommandError.rejected(reason: "at most 6 items")) {
            try setQueue(Array(repeating: .unit(.warrior), count: 7))
        }
        #expect(throws: CommandError.rejected(reason: "Monument is queued twice")) {
            try setQueue([.building("monument"), .building("monument")])
        }
        #expect(throws: CommandError.rejected(reason: "Granary: needs Pottery")) { try setQueue([.building("granary")]) }
        #expect(throws: CommandError.rejected(reason: "Archer: needs Archery")) { try setQueue([.unit(.archer)]) }
        #expect(throws: CommandError.rejected(reason: "Palace: cannot be built")) { try setQueue([.building("palace")]) }
        try setQueue(Array(repeating: .unit(.warrior), count: 6))

        // Entries kept keep their progress (matched in order); removed ones' progress is stored.
        try setQueue([.unit(.warrior), .building("monument")])
        updateCity(&state, id) { city in
            city.queue[0].progress = 10
            city.queue[1].progress = 20
        }
        try setQueue([.building("monument"), .unit(.scout)])
        #expect(state.city(id)!.queue == [QueueEntry(.building("monument"), progress: 20), QueueEntry(.unit(.scout))])
        #expect(state.city(id)!.storedProgress == 10)

        try endPhases(until: PlayerID(1), &state)
        // Player 1 has never seen the city: refused as if it did not exist (core-3: no id probing).
        #expect(throws: CommandError.unknownCity(id)) { try apply(.setQueue(city: id, items: []), &state) }
        #expect(throws: CommandError.unknownCity(CityID(99))) { try apply(.setQueue(city: CityID(99), items: []), &state) }
        state.addUnit(.scout, owner: PlayerID(1), at: hex(3, 4))
        #expect(state.players[1].memory.city(id) != nil)
        #expect(throws: CommandError.notYourCity(id)) { try apply(.setQueue(city: id, items: []), &state) }
    }
}

@Suite struct BorderTests {
    @Test func cultureClaimsTheBestTileTouchingTheTerritory() throws {
        var map = makeTestMap()
        map[hex(4, 2)] = Tile(terrain: .plains, elevation: .hills) // 3·1 + 2·2 = 7 beats grassland's 6
        var state = makeTestState(map: map)
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        updateCity(&state, id) { $0.cultureStore = 9 }
        try endPhases(until: PlayerID(1), &state)
        let records = try apply(.endTurn, &state)
        #expect(state.tileOwner(state.map.index(of: hex(4, 2))!) == PlayerID(0))
        #expect(state.city(id)!.tilesGained == 1 && state.city(id)!.cultureStore == 1)
        #expect(events(records).contains(.borderGrew(city: id, tile: hex(4, 2))))
        expectSound(state)

        // Without a better tile, ties go to the nearer tile, then the lower index.
        var plain = makeTestState()
        let other = addCity(&plain, PlayerID(0), at: hex(2, 2))
        #expect(plain.borderCandidate(for: plain.city(other)!) == plain.map.index(of: hex(1, 0)))
    }

    @Test func mountainsAreClaimedLast() {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        let mountain = state.map.index(of: hex(5, 2))!
        let area = state.map.coords(within: 3, of: hex(2, 2)).map { state.map.index(of: $0)! }
        for t in area where t != mountain { state.tileCity[t] = Int32(id.rawValue + 1) }
        #expect(state.borderCandidate(for: state.city(id)!) == mountain)
    }
}

@Suite struct CityHealingTests {
    @Test func citiesHealAndRepairWallsWhenNotAttacked() throws {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        updateCity(&state, id) { city in
            city.hp = 150
            city.buildings = ["palace", "walls"]
        }
        try nextTurn(&state)
        #expect(state.city(id)!.hp == 170 && state.city(id)!.wallHP == 10)

        // Attacked since the owner's previous phase start: no healing.
        let phase = state.phaseCount
        updateCity(&state, id) { $0.lastAttackedPhase = phase }
        try nextTurn(&state)
        #expect(state.city(id)!.hp == 170 && state.city(id)!.wallHP == 10)
    }
}
