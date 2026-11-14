import Testing
@testable import GameCore

// M2 §5.5 Loyalty and §12.5 Free Cities, on an open 24×8 map with two civs and the Free Cities
// (player 2). Player 0's capital is at (1, 4), well out of reach of its city at (14, 4);
// player 1's capital is at (18, 4), 4 from it.

@Suite struct LoyaltyTests {
    let p0 = PlayerID(0), p1 = PlayerID(1), free = PlayerID(2)

    func world() -> (GameState, CityID, CityID) {
        let map = openMap(width: 24, height: 8)
        let players = [
            Player(id: p0, name: "P0", isHuman: true, tileCount: map.tileCount, gold: 1000),
            Player(id: p1, name: "P1", isHuman: false, tileCount: map.tileCount, gold: 1000),
            Player(id: free, name: "Free Cities", isHuman: false, tileCount: map.tileCount, kind: .free),
        ]
        var state = GameState(seed: 1, map: map, players: players, rules: .standard)
        _ = addCity(&state, p0, at: hex(1, 4))
        let city = addCity(&state, p0, at: hex(14, 4))
        let rival = addCity(&state, p1, at: hex(18, 4))
        updateCity(&state, rival) { $0.population = 10 }
        return (state, city, rival)
    }

    @Test func theFreeCitiesAreAFixedFactionAtWarWithEveryone() {
        let (state, _, _) = world()
        #expect(state.freeCities == free && state.livingPlayers == [p0, p1])
        #expect(state.isAtWar(p0, free) && state.isAtWar(p1, free) && !state.isAtWar(p0, p1))
        expectSound(state)
    }

    @Test func aFoundedCityStartsLoyalAndHoldsNearItsCapital() throws {
        let (state, _, _) = world()
        let capital = try #require(state.cities.first { $0.position == hex(1, 4) })
        #expect(capital.loyalty == 100)
        let b = try #require(state.loyaltyBreakdown(capital))
        #expect(b.ownPressure == 10 && b.foreignPressure == 0 && b.capital == 8 && b.total > 0)
        #expect(state.turnsUntilRevolt(capital) == nil)
    }

    @Test func foreignPressureWearsAForwardCityDown() throws {
        let (state, id, _) = world()
        let city = try #require(state.city(id))
        let b = try #require(state.loyaltyBreakdown(city))
        // P1: 10 × (10 − 4) = 60 against P0's own 1 × 10 = 10: (10 − 60) / 20 = −2.
        #expect(b.ownPressure == 10 && b.foreignPressure == 60 && b.topForeign == p1 && b.pressure == -2)
        #expect(b.capital == 0 && b.garrison == 0)
        #expect(b.total == b.pressure + b.stability + b.captured + b.enemies)
    }

    @Test func aGarrisonAndEnemyUnitsCount() throws {
        var (state, id, _) = world()
        let before = try #require(state.loyaltyBreakdown(state.city(id)!))
        _ = state.insertUnit(.warrior, owner: p0, at: hex(14, 4))
        setWar(&state, p0, p1)
        for h in [hex(13, 4), hex(15, 4), hex(14, 3), hex(14, 5)] { _ = state.insertUnit(.warrior, owner: p1, at: h) }
        let after = try #require(state.loyaltyBreakdown(state.city(id)!))
        #expect(after.garrison == 2 && after.enemies == -3, "enemy units count at most −3")
        #expect(after.total == max(-10, before.total + 2 - 3))
    }

    @Test func atZeroTheCityRevoltsKeepingItsBuildings() throws {
        var (state, id, _) = world()
        let warrior = state.insertUnit(.warrior, owner: p0, at: hex(14, 4))
        setWar(&state, p0, p1)
        for h in [hex(13, 4), hex(15, 4), hex(14, 3)] { _ = state.insertUnit(.warrior, owner: p1, at: h) }
        updateCity(&state, id) { city in
            city.loyalty = 1
            city.buildings.append("granary")
            city.queue = [QueueEntry(.unit(.warrior))]
        }
        var setup = Effects()
        setup.touchAllPlayers(state.players.count)
        state.updateKnowledge(&setup)
        let delta = try #require(state.loyaltyBreakdown(state.city(id)!)).total
        try #require(delta < 0)
        #expect(state.turnsUntilRevolt(state.city(id)!) == 1)
        var fx = Effects()
        state.updateLoyalty(for: p0, &fx)
        state.updateKnowledge(&fx)
        let city = try #require(state.city(id))
        #expect(city.owner == free && city.loyalty == 50 && city.queue.isEmpty)
        #expect(city.buildings.contains("granary"))
        let unit = try #require(state.unit(warrior))
        #expect(unit.position != hex(14, 4) && state.map.distance(unit.position, hex(14, 4)) == 1)
        #expect(fx.pending.contains { if case .cityRevolted(id, _, p0, free, _) = $0.event { true } else { false } })
        expectSound(state)
    }

    @Test func aFreeCityJoinsTheCivWithTheMostPressureForFiveTurns() throws {
        var (state, id, _) = world()
        updateCity(&state, id) { $0.loyalty = 0 }
        var fx = Effects()
        state.revolt(state.cityIndex(id)!, &fx)
        for turn in 1...4 {
            state.runFreeCities(&fx)
            let city = try #require(state.city(id))
            #expect(city.owner == free && city.freeCityLeader == p1 && city.freeCityTurns == turn)
        }
        state.runFreeCities(&fx)
        state.updateKnowledge(&fx)
        let city = try #require(state.city(id))
        #expect(city.owner == p1 && city.loyalty == 50 && city.freeCityLeader == nil)
        #expect(fx.pending.contains { if case .cityJoined(id, _, free, p1, _) = $0.event { true } else { false } })
        expectSound(state)
    }

    @Test func freeCitiesRaiseDefenders() throws {
        var (state, id, _) = world()
        var fx = Effects()
        state.revolt(state.cityIndex(id)!, &fx)
        state.turn = 10
        state.runFreeCities(&fx)
        state.runFreeCities(&fx)
        state.runFreeCities(&fx)
        state.updateKnowledge(&fx)
        #expect(state.units(of: free).map(\.type) == [.warrior, .warrior], "at most two")
        state.turn = 11
        expectSound(state)
    }

    @Test func aCapturedCityStartsAtHalf() throws {
        var (state, id, _) = world()
        setWar(&state, p0, p1)
        var fx = Effects()
        let rival = try #require(state.cities.first { $0.owner == p1 })
        let captor = state.insertUnit(.warrior, owner: p0, at: hex(17, 4))
        state.captureCity(state.cityIndex(rival.id)!, by: captor, &fx)
        #expect(state.city(rival.id)?.loyalty == 50)
        #expect(state.city(id)?.loyalty == 100)
    }
}
