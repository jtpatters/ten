import Testing
@testable import GameCore

// M2 §7.2–7.3 governments and policy slots.

@Suite struct GovernanceTests {
    let p0 = PlayerID(0)

    @Test func theRulesHaveSevenGovernmentsAndThirtyPolicies() throws {
        let g = try #require(Ruleset.standard.governance)
        #expect(g.governments.count == 7 && g.policies.count == 30)
        #expect(makeTestState(map: openMap(), gold: 0).government(of: p0)?.id == "despotism")
    }

    @Test func aGovernmentNeedsItsCivicAndIsFreeTheFirstTime() throws {
        var state = makeTestState(map: openMap(), gold: 100)
        #expect(throws: CommandError.rejected(reason: "government not available")) {
            try apply(.setGovernment(government: "chiefdom"), &state)
        }
        state.learnCivic("codeOfLaws", player: p0)
        state.players[0].freeChangeTurn = nil
        try apply(.setGovernment(government: "chiefdom"), &state)
        #expect(state.government(of: p0)?.id == "chiefdom" && state.players[0].gold == 100)
        #expect(state.players[0].governmentsAdopted == ["chiefdom"])
        let turnGold = max(0, state.view(for: p0).income().gold)
        #expect(state.governmentChangeCost(to: "despotism", for: p0) == (turnGold * 5 + 5) / 10 * 10)
        #expect(throws: CommandError.rejected(reason: "already the government")) {
            try apply(.setGovernment(government: "chiefdom"), &state)
        }
    }

    @Test func policiesMustFitTheirSlotsAndWildcardTakesAny() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        state.learnCivic("codeOfLaws", player: p0)
        state.learnCivic("craftsmanship", player: p0)
        // Despotism: one Wildcard slot.
        try apply(.setPolicies(policies: ["urbanPlanning"]), &state)
        #expect(throws: CommandError.rejected(reason: "not enough slots")) {
            try apply(.setPolicies(policies: ["urbanPlanning", "discipline"]), &state)
        }
        try apply(.setGovernment(government: "chiefdom"), &state)
        try apply(.setPolicies(policies: ["urbanPlanning", "discipline"]), &state)
        #expect(throws: CommandError.rejected(reason: "not enough slots")) {
            try apply(.setPolicies(policies: ["urbanPlanning", "ilkum"]), &state)
        }
        #expect(throws: CommandError.rejected(reason: "policy not available")) {
            try apply(.setPolicies(policies: ["colonization"]), &state)
        }
        #expect(throws: CommandError.rejected(reason: "no such policy")) {
            try apply(.setPolicies(policies: ["nope"]), &state)
        }
    }

    @Test func policyChangesAreFreeOnACivicTurnAndCostGoldOtherwise() throws {
        var state = makeTestState(map: openMap(), gold: 120)
        state.learnCivic("codeOfLaws", player: p0)
        #expect(state.isFreeChangeTurn(for: p0))
        try apply(.setPolicies(policies: ["urbanPlanning"]), &state)
        #expect(state.players[0].gold == 120)
        state.players[0].freeChangeTurn = nil
        #expect(state.policyChangeCost(to: ["discipline"], for: p0) == 50)
        #expect(state.policyChangeCost(to: [], for: p0) == 0)
        try apply(.setPolicies(policies: ["discipline"]), &state)
        #expect(state.players[0].gold == 70)
        state.players[0].gold = 10
        #expect(throws: CommandError.rejected(reason: "not enough gold")) {
            try apply(.setPolicies(policies: ["urbanPlanning"]), &state)
        }
    }

    @Test func changingGovernmentUnslotsPoliciesThatNoLongerFit() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        state.learnCivic("codeOfLaws", player: p0)
        try apply(.setGovernment(government: "chiefdom"), &state)
        try apply(.setPolicies(policies: ["discipline", "urbanPlanning"]), &state)
        try apply(.setGovernment(government: "despotism"), &state)
        #expect(state.players[0].policies == ["discipline"])
        #expect(state.bonuses(of: p0).count == 1)
    }

    @Test func bonusesSumTheGovernmentAndPolicies() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        state.learnCivic("codeOfLaws", player: p0)
        try apply(.setGovernment(government: "chiefdom"), &state)
        try apply(.setPolicies(policies: ["urbanPlanning"]), &state)
        #expect(state.bonus(\.influence, for: p0) == 1)
        #expect(state.bonus(\.cityProduction, for: p0) == 1)
    }
}
