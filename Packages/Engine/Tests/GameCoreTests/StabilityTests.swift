import Testing
@testable import GameCore

// M2 §5.1 Housing and §5.2 Stability. A capital on open grassland: base Housing 2 + Palace 1.

@Suite struct HousingTests {
    func capital(_ map: HexMap = openMap(), population: Int = 1) -> (GameState, CityID) {
        var state = makeTestState(map: map)
        let id = addCity(&state, PlayerID(0), at: hex(3, 3))
        updateCity(&state, id) { $0.population = population }
        return (state, id)
    }

    @Test func baseHousingComesFromWater() {
        let (dry, a) = capital()
        #expect(dry.housing(of: dry.city(a)!) == HousingBreakdown(base: 2, buildings: 1, improvements: 0))

        var map = openMap()
        map[hex(4, 3)] = Tile(terrain: .coast)
        let (coast, b) = capital(map)
        #expect(coast.housing(of: coast.city(b)!).base == 3)

        map[hex(2, 3)] = Tile(terrain: .lake)
        let (lake, c) = capital(map)
        #expect(lake.housing(of: lake.city(c)!).base == 5, "a lake is fresh water")

        var river = openMap()
        var tile = Tile(terrain: .grassland)
        tile.riverEdges = 1
        river[hex(3, 3)] = tile
        let (onRiver, d) = capital(river)
        #expect(onRiver.housing(of: onRiver.city(d)!).base == 5)
    }

    @Test func everyTwoWorkedFarmsAddOne() {
        var map = openMap()
        for h in [hex(4, 3), hex(2, 3), hex(3, 2)] { map[h] = Tile(terrain: .grassland, improvement: .farm) }
        var (state, id) = capital(map, population: 3)
        updateCity(&state, id) { $0.workedTiles = [hex(4, 3), hex(2, 3), hex(3, 2)] }
        #expect(state.housing(of: state.city(id)!).improvements == 1)
        updateCity(&state, id) { $0.buildings.append("granary") }
        #expect(state.housing(of: state.city(id)!).total == 6)
    }

    /// Housing 3: 100% up to population 1, 50% at 2, 25% from 3, nothing from 7.
    @Test func growthSlowsAtTheHousing() {
        for (pop, pct) in [(1, 100), (2, 50), (3, 25), (6, 25), (7, 0)] {
            let (state, id) = capital(population: pop)
            #expect(state.growthPct(of: state.city(id)!) == pct, "population \(pop)")
        }
        var (state, id) = capital(population: 2)
        state.assignCitizens(state.cityIndex(id)!)
        let y = state.cityYields(state.city(id)!)
        #expect(y.growthPct == 50 && y.foodSurplus == y.rawFoodSurplus * 50 / 100)
    }

    @Test func aShrinkingCityIsNotScaled() {
        var (state, id) = capital(population: 7)
        updateCity(&state, id) { $0.workedTiles = [] }
        let y = state.cityYields(state.city(id)!)
        #expect(y.rawFoodSurplus < 0 && y.foodSurplus == y.rawFoodSurplus)
    }
}

@Suite struct StabilityTests {
    @Test func supplyMinusNeedAndPenalties() {
        var state = makeTestState(map: openMap())
        let id = addCity(&state, PlayerID(0), at: hex(3, 3))
        let i = state.cityIndex(id)!
        #expect(state.stabilityBreakdowns(for: PlayerID(0))[i]!.total == 1, "the Palace")
        updateCity(&state, id) { $0.population = 5 }
        let b = state.stabilityBreakdowns(for: PlayerID(0))[i]!
        #expect(b.buildings == 1 && b.need == 2 && b.overcrowding == -2 && b.total == -3)
        #expect(state.rules.stabilityState(b.total) == .unrest)
        let now = state.turn
        updateCity(&state, id) { $0.capturedTurn = now }
        #expect(state.stabilityBreakdowns(for: PlayerID(0))[i]!.occupied == -2)
    }

    @Test func eachCityBeyondFourCosts() {
        var state = makeTestState(map: openMap(width: 24, height: 12))
        for k in 0..<8 { addCity(&state, PlayerID(0), at: hex(1 + (k % 4) * 6, 2 + (k / 4) * 6)) }
        let all = state.stabilityBreakdowns(for: PlayerID(0))
        #expect(all.count == 8 && all.values.allSatisfy { $0.empireSize == -1 })
    }

    @Test func statesBoundaries() {
        let r = Ruleset.standard
        #expect([3, 2, 0, -1, -2, -3, -4, -5].map(r.stabilityState)
            == [.thriving, .content, .content, .restless, .restless, .unrest, .unrest, .revolt])
    }

    @Test func stabilityScalesEveryYieldButFood() {
        var state = makeTestState(map: openMap())
        let id = addCity(&state, PlayerID(0), at: hex(3, 3))
        state.assignCitizens(state.cityIndex(id)!)
        let base = state.cityYields(state.city(id)!)
        updateCity(&state, id) { $0.stability = -3 }
        let unrest = state.cityYields(state.city(id)!)
        #expect(unrest.total.food == base.total.food)
        #expect(unrest.total.production == base.total.production * 75 / 100)
        #expect(unrest.total.science == base.total.science * 75 / 100)
        #expect(unrest.breakdown.contains { $0.source == .stability })
        #expect(unrest.growthPct == 0)
        updateCity(&state, id) { $0.stability = 0 }
        #expect(state.cityYields(state.city(id)!) == base)
    }

    @Test func thePhaseStartRecomputesIt() throws {
        var state = makeTestState(map: openMap())
        let id = addCity(&state, PlayerID(0), at: hex(3, 3))
        #expect(state.city(id)!.stability == nil)
        try nextTurn(&state)
        #expect(state.city(id)!.stability == 1)
        #expect(state.view(for: PlayerID(0)).wellbeing(of: id)?.state == .content)
        expectSound(state)
    }

    @Test func theWaterMillNeedsARiver() {
        var state = makeTestState(map: openMap())
        let id = addCity(&state, PlayerID(0), at: hex(3, 3))
        state.players[0].knownTechs.append("theWheel")
        #expect(state.itemProblem(.building("waterMill"), in: state.city(id)!) == "needs a river")
    }
}
