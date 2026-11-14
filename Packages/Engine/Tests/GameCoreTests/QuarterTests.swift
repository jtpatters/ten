import Testing
@testable import GameCore

// M2 §5.3 quarters. A capital at (5, 4) on open grassland that knows the quarter techs.

@Suite struct QuarterTests {
    let me = PlayerID(0)

    func capital(_ map: HexMap = openMap(), population: Int = 3) -> (GameState, CityID) {
        var state = makeTestState(map: map)
        let id = addCity(&state, me, at: hex(5, 4))
        updateCity(&state, id) { $0.population = population }
        state.players[0].knownTechs += ["writing", "currency", "engineering", "apprenticeship", "bronzeWorking", "celestialNavigation"]
        state.players[0].knownTechs.sort()
        return (state, id)
    }

    func build(_ state: inout GameState, _ kind: QuarterKind, at h: HexCoord, in id: CityID) {
        var fx = Effects()
        state.complete(.quarter(kind, at: h), inCity: state.cityIndex(id)!, &fx)
        state.updateKnowledge(&fx)
    }

    @Test func placement() {
        var map = openMap()
        map[hex(6, 3)] = Tile(terrain: .grassland, elevation: .mountains)
        var luxury = Tile(terrain: .grassland)
        luxury.resource = .ivory
        map[hex(4, 5)] = luxury
        var (state, id) = capital(map)
        for h in [hex(7, 4), hex(8, 4), hex(9, 4)] { claimTile(&state, h, for: id) }
        let city = state.city(id)!
        #expect(state.quarterSiteProblem("campus", at: hex(5, 4), in: city) != nil, "centre")
        #expect(state.quarterSiteProblem("campus", at: hex(6, 3), in: city) != nil, "mountain")
        #expect(state.quarterSiteProblem("campus", at: hex(4, 5), in: city) != nil, "luxury")
        #expect(state.quarterSiteProblem("campus", at: hex(5, 7), in: city) != nil, "outside the territory")
        #expect(state.quarterSiteProblem("campus", at: hex(9, 4), in: city) != nil, "4 from the centre")
        #expect(state.quarterSiteProblem("campus", at: hex(8, 4), in: city) == nil)
        #expect(state.quarterSiteProblem("barracks", at: hex(6, 4), in: city) != nil, "Barracks next to the centre")
        #expect(state.quarterSiteProblem("barracks", at: hex(7, 4), in: city) == nil)
        #expect(state.quarterSiteProblem("harbor", at: hex(6, 4), in: city) != nil, "Harbor on land")
        #expect(state.quarterSiteProblem("aqueduct", at: hex(5, 3), in: city) == nil, "next to the mountain")
        #expect(state.quarterSiteProblem("aqueduct", at: hex(4, 4), in: city) != nil, "no fresh water")
    }

    @Test func techCivicOnePerKindAndCap() {
        var (state, id) = capital(population: 2)
        #expect(state.itemProblem(.quarter("campus", at: hex(6, 4)), in: state.city(id)!) == nil)
        state.players[0].knownTechs.removeAll { $0 == "writing" }
        #expect(state.itemProblem(.quarter("campus", at: hex(6, 4)), in: state.city(id)!) == "needs Writing")
        #expect(state.itemProblem(.quarter("theater", at: hex(6, 4)), in: state.city(id)!) == "needs a civic")
        build(&state, "market", at: hex(6, 4), in: id)
        #expect(state.itemProblem(.quarter("market", at: hex(4, 4)), in: state.city(id)!) == "already built")
        #expect(state.itemProblem(.quarter("workshop", at: hex(4, 4)), in: state.city(id)!) == "needs population 3",
                "1 + 2 / 3 = 1 quarter")
        #expect(state.itemProblem(.quarter("aqueduct", at: hex(4, 4)), in: state.city(id)!) == "needs a river, lake or mountain",
                "the Aqueduct is exempt from the cap")
    }

    @Test func costIsFixedWhenQueued() {
        var (state, id) = capital()
        #expect(state.quarterCost("campus") == 55 && state.quarterCost("aqueduct") == 50)
        state.worldEra = 1
        #expect(state.quarterCost("campus") == 85)
        state.setQueue(ofCity: state.cityIndex(id)!, to: [.quarter("campus", at: hex(6, 4))])
        state.worldEra = 2
        #expect(state.city(id)!.queue[0].cost == 85 && state.cost(of: state.city(id)!.queue[0]) == 85)
    }

    @Test func aQuarterTileLosesItsImprovementAndWorker() {
        var map = openMap()
        map[hex(6, 4)] = Tile(terrain: .grassland, improvement: .farm)
        var (state, id) = capital(map, population: 1)
        updateCity(&state, id) { $0.workedTiles = [hex(6, 4)] }
        #expect(state.itemProblem(.building("library"), in: state.city(id)!) == "needs a Campus")
        build(&state, "campus", at: hex(6, 4), in: id)
        let t = state.map.index(of: hex(6, 4))!
        #expect(state.map.tiles[t].improvement == nil && state.isQuarterTile(t))
        #expect(!state.city(id)!.workedTiles.contains(hex(6, 4)))
        #expect(state.itemProblem(.building("library"), in: state.city(id)!) == nil)
        #expect(state.checkInvariants() == [])
    }

    @Test func adjacencyHalvesRoundDown() {
        var map = openMap()
        let around = map.neighbors(of: hex(6, 4)).filter { $0 != hex(5, 4) && map.distance($0, hex(4, 4)) > 1 }
        map[around[0]] = Tile(terrain: .grassland, elevation: .mountains)
        map[around[1]] = Tile(terrain: .grassland, feature: .jungle)
        map[hex(4, 4)] = Tile(terrain: .grassland, riverEdges: 1)
        var (state, id) = capital(map)
        let centre = state.map.index(of: hex(5, 4))!
        let campus = state.map.index(of: hex(6, 4))!
        #expect(state.quarterAdjacency("campus", at: campus, owner: me, centre: centre) == 1, "mountain 1, jungle ½")
        build(&state, "market", at: hex(4, 4), in: id)
        #expect(state.quarterAdjacency("market", at: state.map.index(of: hex(4, 4))!, owner: me, centre: centre) == 2)
        build(&state, "campus", at: hex(6, 4), in: id)
        let y = state.cityYields(state.city(id)!)
        #expect(y.breakdown.contains { $0.source == .quarter("campus") && $0.yields == Yields(science: 1) })
        #expect(y.breakdown.contains { $0.source == .quarter("market") && $0.yields == Yields(gold: 2) })
    }

    @Test func aqueductHousingAndArenaReach() {
        var map = openMap()
        map[hex(6, 3)] = Tile(terrain: .grassland, elevation: .mountains)
        var (state, id) = capital(map)
        let before = state.housing(of: state.city(id)!)
        build(&state, "aqueduct", at: hex(5, 3), in: id)
        #expect(state.housing(of: state.city(id)!).quarters == 6 && before.quarters == 0, "+6: the city has no fresh water")
        let other = addCity(&state, me, at: hex(10, 4))
        build(&state, "arena", at: hex(6, 4), in: id)
        updateCity(&state, id) { $0.buildings.append("arena") }
        let b = state.stabilityBreakdowns(for: me)
        #expect(b[state.cityIndex(id)!]!.quarters == 3 && b[state.cityIndex(other)!]!.quarters == 3)
        #expect(b[state.cityIndex(id)!]!.buildings == 1, "the Palace; the Arena's +1 goes to its reach")
    }
}
