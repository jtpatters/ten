import Testing
@testable import GameCore

// M2 §4.3 Influence and §7.2–7.3 government and policy effects.

@Suite struct GovernanceEffectsTests {
    let p0 = PlayerID(0)

    @Test func costCutsApplyToTheirUnitsOnly() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        state.players[0].policies = ["agoge", "ilkum"]
        let warrior = state.rules.cost(of: .unit(.warrior))
        #expect(state.productionCost(of: .unit(.warrior), for: p0) == warrior - warrior * 25 / 100)
        #expect(state.costCutPct(.unit(.builder), for: p0) == 15)
        #expect(state.costCutPct(.unit(.settler), for: p0) == 0)
        #expect(state.productionCost(of: .unit(.warrior), for: PlayerID(1)) == warrior)
        #expect(state.purchasePrice(of: .unit(.warrior), for: p0) < state.purchasePrice(of: .unit(.warrior)))
    }

    @Test func urbanPlanningAddsProductionToEveryCity() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        let id = addCity(&state, p0, at: hex(4, 4))
        let before = state.cityYields(state.city(id)!).total.production
        state.players[0].policies = ["urbanPlanning"]
        let yields = state.cityYields(state.city(id)!)
        #expect(yields.total.production == before + 1)
        #expect(yields.breakdown.contains { $0.source == .government })
    }

    @Test func landSurveyorsCutsTilePrices() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        let id = addCity(&state, p0, at: hex(4, 4))
        let before = try #require(state.tilePrice(for: state.city(id)!))
        state.players[0].policies = ["landSurveyors"]
        #expect(state.tilePrice(for: state.city(id)!) == before - before * 25 / 100)
    }

    @Test func surveyGivesReconUnitsSightAndMoves() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        let scout = Unit(id: UnitID(999), owner: p0, type: .scout, position: hex(2, 2), movesLeft: 0)
        let sight = state.sight(of: scout), moves = state.maxMoves(of: scout)
        state.players[0].policies = ["survey"]
        #expect(state.sight(of: scout) == sight + 1)
        #expect(state.maxMoves(of: scout) == moves + state.rules.movePoints)
    }

    @Test func influenceBuysEnvoyTokensAtARisingThreshold() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        _ = addCity(&state, p0, at: hex(4, 4))
        #expect(state.influenceIncome(of: p0) == 1)
        #expect(state.envoyThreshold(for: p0) == 25)
        state.players[0].influence = 24
        var fx = Effects()
        state.runInfluence(for: p0, &fx)
        #expect(state.players[0].envoyTokens == 1 && state.players[0].influence == 0)
        #expect(state.envoyThreshold(for: p0) == 30)
        state.players[0].envoysEarned = 20
        #expect(state.envoyThreshold(for: p0) == 60)
    }
}
