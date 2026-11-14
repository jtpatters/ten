import Testing
@testable import GameCore

// M2 §7.1 the civic tree.

@Suite struct CivicsTests {
    let p0 = PlayerID(0)

    @Test func theTreeHasEighteenCivicsCosting2115() {
        let rules = Ruleset.standard
        #expect(rules.civics.count == 18)
        #expect(rules.civics.reduce(0) { $0 + $1.cost } == 2115)
    }

    @Test func setCivicWalksPrerequisitesInTreeOrder() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        try apply(.setCivic(civic: "earlyEmpire"), &state)
        #expect(state.players[0].studying == "codeOfLaws" && state.players[0].civicTarget == "earlyEmpire")
        #expect(throws: (any Error).self) { try apply(.setCivic(civic: "nope"), &state) }
    }

    @Test func cultureCompletesOneCivicAPhaseAndCarriesOverflow() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        try apply(.setCivic(civic: "foreignTrade"), &state)
        var fx = Effects()
        state.runCivics(for: p0, culture: 75, &fx)
        #expect(state.players[0].knownCivics == ["codeOfLaws"])
        #expect(state.players[0].studying == "foreignTrade" && state.players[0].civicProgress == 55)
        #expect(fx.pending.contains { if case .civicCompleted(_, "codeOfLaws") = $0.event { true } else { false } })
        state.runCivics(for: p0, culture: 0, &fx)
        #expect(state.players[0].knownCivics == ["codeOfLaws", "foreignTrade"])
        #expect(state.players[0].studying == nil && state.players[0].civicTarget == nil)
        #expect(state.players[0].civicProgress == 15)
        expectSound(state)
    }

    @Test func civicOptionsShowThePathAndWhatEachUnlocks() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        try apply(.setCivic(civic: "earlyEmpire"), &state)
        let options = state.view(for: p0).civicOptions()
        #expect(options.count == state.rules.civics.count)
        let laws = try #require(options.first { $0.civic == "codeOfLaws" })
        #expect(laws.available && laws.studying && !laws.isTarget && !laws.known)
        #expect(laws.unlocks.contains("Chiefdom") && laws.unlocks.contains("Discipline"))
        let empire = try #require(options.first { $0.civic == "earlyEmpire" })
        #expect(empire.isTarget && !empire.available && !empire.studying)
    }

    @Test func debugLearnCivicClearsTheStudyAndFreesAChange() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        try apply(.setCivic(civic: "codeOfLaws"), &state)
        #expect(DebugTools.learnCivic("codeOfLaws", player: p0, in: &state))
        #expect(!DebugTools.learnCivic("codeOfLaws", player: p0, in: &state))
        #expect(state.players[0].knowsCivic("codeOfLaws"))
        #expect(state.players[0].studying == nil && state.players[0].civicTarget == nil)
        #expect(state.isFreeChangeTurn(for: p0))
        #expect(state.view(for: p0).civicOptions().first { $0.civic == "codeOfLaws" }?.known == true)
    }

    @Test func theArenaQuarterNeedsGamesAndRecreation() {
        var state = makeTestState(map: openMap(), gold: 0)
        let id = addCity(&state, p0, at: hex(3, 4))
        updateCity(&state, id) { $0.population = 6 }
        let city = state.city(id)!
        #expect(state.quarterKindProblem("arena", in: city) == "needs Games and Recreation")
        state.learnCivic("gamesAndRecreation", player: p0)
        #expect(state.quarterKindProblem("arena", in: state.city(id)!) == nil)
    }

    @Test func anInsightCutsACivicsCost() {
        var state = makeTestState(map: openMap(), gold: 0)
        let index = state.rules.civicIndex("earlyEmpire")!
        #expect(state.civicCredit(index, for: p0) == 0)
        state.players[0].civicInsights = ["earlyEmpire"]
        #expect(state.civicCredit(index, for: p0) == 60 * state.rules.progression!.insightPct / 100)
    }

    @Test func owningThreeCitiesFiresTheEarlyEmpireInsight() {
        var state = makeTestState(map: openMap(), gold: 0)
        var fx = Effects()
        for x in [2, 6, 10] {
            let id = addCity(&state, p0, at: hex(x, 4))
            fx.emit(.cityFounded(city: id, name: "c", owner: p0, at: hex(x, 4)), .everyone)
        }
        state.checkInsights(&fx)
        #expect(state.players[0].civicInsights?.contains("earlyEmpire") == true)
    }
}
