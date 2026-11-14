import Testing
@testable import GameCore

// M2 §12 minor factions, on an open 30×20 Duel-size game: two civs starting at (3, 10) and
// (26, 10), then two minors, the raiders and the Free Cities.

@Suite struct MinorTests {
    let p0 = PlayerID(0), p1 = PlayerID(1)

    func world(seed: UInt64 = 11) -> GameState {
        GameState.newGame(seed: seed, map: openMap(width: 30, height: 20), startPositions: [hex(3, 10), hex(26, 10)],
                          humanPlayers: [], mapSizeName: "duel", placeMinors: true)
    }

    func minors(_ state: GameState) -> [PlayerID] { state.players.filter { $0.kind == .minor }.map(\.id) }

    func meet(_ state: inout GameState, _ a: PlayerID, _ b: PlayerID) {
        var fx = Effects()
        state.meet(a, b, &fx)
        state.updateKnowledge(&fx)
    }

    @Test func minorsArePlacedWithTheirCityAndArmy() throws {
        let state = world()
        let m = minors(state)
        let r = try #require(state.rules.minors)
        #expect(m == [PlayerID(2), PlayerID(3)])
        #expect(state.players.map(\.kind) == [nil, nil, .minor, .minor, .raiders, .free])
        let starts = [hex(3, 10), hex(26, 10)]
        var sites: [HexCoord] = []
        for p in m {
            let cities = state.cities.filter { $0.owner == p }
            let city = try #require(cities.first)
            #expect(cities.count == 1 && city.population == r.startPopulation && city.wallHP > 0 && city.name == state.players[p.rawValue].name)
            #expect(state.units.filter { $0.owner == p }.map(\.type).sorted { $0.rawValue < $1.rawValue } == [.archer, .warrior])
            #expect(starts.allSatisfy { state.map.distance($0, city.position) >= r.minStartDistance })
            #expect(!state.isAtWar(p, p0) && !state.isAtWar(p, p1) && state.isAtWar(p, state.raiderPlayer!) && state.isAtWar(p, state.freeCities!))
            #expect(state.players[p.rawValue].takesPhases && !state.players[p.rawValue].isMajor)
            sites.append(city.position)
        }
        #expect(state.map.distance(sites[0], sites[1]) >= r.minMinorDistance)
        #expect(state.livingPlayers == [p0, p1])
        #expect(world().minors == state.minors && world().cities == state.cities, "placement is deterministic")
        expectSound(state)
    }

    @Test func theFirstToMeetGetsAnEnvoyAndThePatronHasTheMostFromThree() throws {
        var state = world()
        let m = minors(state)[0]
        meet(&state, p0, m)
        #expect(state.minor(m)?.envoys(of: p0) == 1 && state.minor(m)?.firstMet == p0)
        meet(&state, p1, m)
        #expect(state.minor(m)?.envoys(of: p1) == 0)
        state.players[0].envoyTokens = 5
        state.players[1].envoyTokens = 5
        #expect(state.envoyProblem(p0, to: minors(state)[1]) != nil, "not met")
        _ = try GameEngine.perform(.sendEnvoy(to: m), by: p0, on: &state)
        #expect(state.minor(m)?.patron == nil)
        _ = try GameEngine.perform(.sendEnvoy(to: m), by: p0, on: &state)
        #expect(state.minor(m)?.patron == p0 && state.players[0].envoyTokens == 3)
        for _ in 0..<3 { _ = try GameEngine.perform(.sendEnvoy(to: m), by: p1, on: &state) }
        #expect(state.minor(m)?.patron == p0, "a tie keeps the first")
        _ = try GameEngine.perform(.sendEnvoy(to: m), by: p1, on: &state)
        #expect(state.minor(m)?.patron == p1)
        expectSound(state)
    }

    @Test func envoysGiveTheTypesBonuses() throws {
        var state = world()
        let m = minors(state)[0]
        let city = addCity(&state, p0, at: hex(3, 10))
        var envoys = [Int](repeating: 0, count: state.players.count)
        envoys[0] = 1
        state.minors![0] = MinorFaction(player: m, type: .scientific, envoys: envoys)
        func bonus() -> Yields { state.envoyYields(state.city(city)!) }
        #expect(bonus() == Yields(science: 2))
        state.minors![0].envoys[0] = 3
        #expect(bonus() == Yields(science: 2), "no Library yet")
        let i = state.cityIndex(city)!
        state.cities[i].buildings.append("library")
        #expect(bonus() == Yields(science: 4))
        #expect(state.cityYields(state.cities[i]).breakdown.contains { $0.source == .envoys })
        state.minors![0] = MinorFaction(player: m, type: .militaristic, envoys: envoys)
        #expect(bonus() == .zero, "production for units only while building one")
        state.cities[i].queue = [QueueEntry(.unit(.warrior))]
        #expect(bonus() == Yields(production: 2))
    }

    @Test func thePatronSeesTheTerritoryAndMayLevyTheArmy() throws {
        var state = world()
        let m = minors(state)[0]
        let centre = state.cities.first { $0.owner == m }!.position
        #expect(!state.players[0].visible[tile(state, centre)])
        meet(&state, p0, m)
        state.players[0].envoyTokens = 2
        state.players[0].gold = 500
        #expect(state.levyProblem(p0, on: m) != nil, "not the Patron")
        _ = try GameEngine.perform(.sendEnvoy(to: m), by: p0, on: &state)
        _ = try GameEngine.perform(.sendEnvoy(to: m), by: p0, on: &state)
        #expect(state.minor(m)?.patron == p0 && state.players[0].visible[tile(state, centre)])
        let army = state.units.filter { $0.owner == m && $0.position != centre }.map(\.id)
        #expect(!army.isEmpty, "the garrison stays home")
        _ = try GameEngine.perform(.levy(minor: m), by: p0, on: &state)
        #expect(state.players[0].gold == 500 - army.count * state.rules.minors!.levyGoldPerUnit)
        #expect(army.allSatisfy { state.unit($0)?.owner == p0 } && state.minor(m)?.levy?.units == army)
        expectSound(state)
        state.turn += state.rules.minors!.levyTurns
        var fx = Effects()
        state.runMinor(m, &fx)
        state.updateKnowledge(&fx)
        #expect(army.allSatisfy { state.unit($0)?.owner == m } && state.minor(m)?.levy == nil)
        expectSound(state)
    }

    @Test func warOnAMinorCostsTheEnvoysThereAndMinorsNeverDeclare() throws {
        var state = world()
        let m = minors(state)[0]
        meet(&state, p0, m)
        state.players[0].envoyTokens = 2
        _ = try GameEngine.perform(.sendEnvoy(to: m), by: p0, on: &state)
        _ = try GameEngine.perform(.sendEnvoy(to: m), by: p0, on: &state)
        #expect(state.warProblem(m, on: p0) != nil)
        _ = try GameEngine.perform(.declareWar(on: m), by: p0, on: &state)
        #expect(state.isAtWar(p0, m) && state.minor(m)?.envoys(of: p0) == 0 && state.minor(m)?.patron == nil)
        expectSound(state)
    }

    @Test func takingTheCityEliminatesTheMinor() throws {
        var state = world()
        let m = minors(state)[0]
        meet(&state, p0, m)
        var fx = Effects()
        state.declareWar(p0, on: m, &fx)
        let index = state.cities.firstIndex { $0.owner == m }!
        let centre = state.cities[index].position
        let spot = state.map.neighbors(of: centre).first { state.canEnd(.warrior, owner: p0, at: $0) }!
        let id = state.addUnit(.warrior, owner: p0, at: spot)
        state.captureCity(index, by: id, &fx)
        state.finishCommand(&fx)
        #expect(state.cities[index].owner == p0 && !state.players[m.rawValue].isAlive)
        #expect(state.units.allSatisfy { $0.owner != m })
        expectSound(state)
    }

    @Test func eraDefendersQuestsAndProduction() throws {
        var state = world()
        let m = minors(state)[0]
        let city = state.cities.first { $0.owner == m }!
        #expect(state.itemProblem(.unit(.warrior), in: city) == nil && state.itemProblem(.unit(.swordsman), in: city) != nil)
        state.worldEra = 1
        var fx = Effects()
        state.giveMinorsEraDefenders(&fx)
        let types = state.units.filter { $0.owner == m }.map(\.type)
        #expect(types.contains(.swordsman) && types.count <= state.rules.minors!.maxMilitary)
        meet(&state, p0, m)
        let i = state.minorIndex(of: m)!
        state.minors![i].quest = MinorQuest(kind: .building, building: "monument", issued: state.turn)
        state.buildingCompletedForQuests("monument", by: p0, &fx)
        #expect(state.minor(m)?.envoys(of: p0) == 2 && state.minor(m)?.questsCompleted == 1 && state.minor(m)?.quest != nil)
        state.updateKnowledge(&fx)
        expectSound(state)
    }
}
