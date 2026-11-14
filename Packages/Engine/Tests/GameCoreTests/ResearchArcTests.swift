import Foundation
@testable import GameCore
import Testing

/// The research arc (M2 §2, §6): eras, Insights and the world era.
@Suite struct ResearchArcTests {
    private func techIndex(_ id: TechID, _ state: GameState) -> Int { state.rules.techIndex(id)! }

    /// Meeting a civ is Writing's Insight: 40% of its cost as credit, once per player.
    @Test func anInsightFiresOnceAndCredits() throws {
        var state = makeTestState()
        var fx = Effects()
        state.meet(PlayerID(0), PlayerID(1), &fx)
        state.checkInsights(&fx)
        let gained = fx.pending.compactMap { entry -> PlayerID? in
            if case let .insightGained(player, tech, credit) = entry.event, tech == "writing", credit == 18 { return player }
            return nil
        }
        #expect(gained == [PlayerID(0), PlayerID(1)])
        let writing = techIndex("writing", state)
        #expect(state.players[0].credit(techIndex: writing) == 18 && state.players[0].hasInsight("writing"))

        var again = Effects()
        again.emit(.playersMet(PlayerID(0), PlayerID(1)), .pair(PlayerID(0), PlayerID(1)))
        state.checkInsights(&again)
        #expect(!again.pending.contains { if case .insightGained = $0.event { true } else { false } })
        #expect(state.players[0].credit(techIndex: writing) == 18)
    }

    /// A known tech's Insight never fires.
    @Test func knownTechsGetNoInsight() throws {
        var state = makeTestState()
        state.learn("pottery", player: PlayerID(0))
        state.learn("writing", player: PlayerID(0))
        var fx = Effects()
        state.meet(PlayerID(0), PlayerID(1), &fx)
        state.checkInsights(&fx)
        #expect(!state.players[0].hasInsight("writing") && state.players[1].hasInsight("writing"))
    }

    /// Credit lowers what a tech needs; learning it clears the credit.
    @Test func creditShortensResearch() throws {
        var state = makeTestState()
        state.learn("pottery", player: PlayerID(0))
        let writing = techIndex("writing", state)
        state.addTechCredit(18, techIndex: writing, player: PlayerID(0))
        state.setResearch("writing", for: PlayerID(0))
        var fx = Effects()
        state.runResearch(for: PlayerID(0), science: 26, &fx)
        #expect(!state.players[0].knows("writing"))
        state.runResearch(for: PlayerID(0), science: 3, &fx)
        #expect(state.players[0].knows("writing") && state.players[0].researchProgress == 2)
        #expect(state.players[0].credit(techIndex: writing) == 0)
    }

    /// Credit is capped at the cost − 1: research still learns the tech.
    @Test func creditIsCapped() throws {
        var state = makeTestState()
        let pottery = techIndex("pottery", state)
        state.addTechCredit(1000, techIndex: pottery, player: PlayerID(0))
        #expect(state.players[0].credit(techIndex: pottery) == 24)
    }

    /// The world advances when the mean progress through its era's techs (by cost) reaches the
    /// threshold, and everyone gets catch-up credit toward that era's unknown techs.
    @Test func theWorldEraAdvancesWithCatchUp() throws {
        var state = makeTestState()
        #expect(state.worldEra == 0)
        let ancient = state.rules.techs.indices.filter { state.rules.techEras[$0] == 0 }
        // Player 0 knows a third of the Ancient era by cost, player 1 nothing: no advance.
        var known = 0
        let total = ancient.reduce(0) { $0 + state.rules.techs[$1].cost }
        for i in ancient where 3 * (known + state.rules.techs[i].cost) <= total {
            state.learn(state.rules.techs[i].id, player: PlayerID(0))
            known += state.rules.techs[i].cost
        }
        var fx = Effects()
        state.advanceWorldEraIfDue(&fx)
        #expect(state.worldEra == 0)

        for i in ancient { state.learn(state.rules.techs[i].id, player: PlayerID(0)) }
        state.advanceWorldEraIfDue(&fx)
        #expect(state.worldEra == 1)
        #expect(fx.pending.map(\.event).contains(.worldEraAdvanced(era: 1)))
        let pottery = techIndex("pottery", state), currency = techIndex("currency", state)
        #expect(state.players[1].credit(techIndex: pottery) == 5 && state.players[1].credit(techIndex: currency) == 14)
        #expect(state.players[0].techCredit == nil)

        // One era per turn start at most, and never past the last.
        for i in state.rules.techs.indices { state.learn(state.rules.techs[i].id, player: PlayerID(1)) }
        for i in state.rules.techs.indices { state.learn(state.rules.techs[i].id, player: PlayerID(0)) }
        state.advanceWorldEraIfDue(&fx)
        #expect(state.worldEra == 2)
        state.advanceWorldEraIfDue(&fx)
        #expect(state.worldEra == 2)
    }

    /// The research options show eras, credit and Insights.
    @Test func researchOptionsShowInsights() throws {
        var state = makeTestState()
        var fx = Effects()
        state.meet(PlayerID(0), PlayerID(1), &fx)
        state.checkInsights(&fx)
        let options = state.view(for: PlayerID(0)).researchOptions()
        let writing = try #require(options.first { $0.tech == "writing" })
        #expect(writing.credit == 18 && writing.insightGained && writing.insight == "Meet another civilization" && writing.era == 0)
        #expect(options.first { $0.tech == "astronomy" }?.era == 2)
    }

    /// Validation rejects an unknown era and an Insight naming an unknown building.
    @Test func validationChecksErasAndInsights() throws {
        var json = try standardRulesJSON()
        var techs = try #require(json["techs"] as? [[String: Any]])
        techs[0]["era"] = "bronzeAge"
        techs[1]["insight"] = ["kind": "ownBuildings", "count": 1, "target": "colosseum", "text": "Build it"]
        json["techs"] = techs
        #expect(throws: RulesValidationError.self) { try loadRules(json) }
    }
}
