import Foundation
import Testing
@testable import GameCore

@Suite struct SetupTests {
    /// Each player starts with a Settler, a Warrior and a Scout and 10 Gold, at peace and unmet;
    /// civs come in rules order (M1 §2).
    @Test func newGameGivesEveryPlayerTheStartingUnitsAndGold() {
        let map = makeTestMap(width: 30, height: 12)
        let state = GameState.newGame(seed: 4, map: map, startPositions: [hex(3, 9), hex(22, 4)], mapSizeName: "test")
        #expect(state.mapSizeName == "test" && state.seed == 4)
        #expect(state.turn == 1 && state.currentPlayer == PlayerID(0) && state.phaseCount == 1)
        #expect(state.players.map(\.civ) == ["rome", "mongols"])
        #expect(state.players.map(\.name) == ["Rome", "Mongols"])
        #expect(state.players.map(\.isHuman) == [true, false])
        #expect(state.players.allSatisfy { $0.gold == 10 && $0.isAlive && $0.knownTechs.isEmpty })
        #expect(state.players[0].lastPhaseStart == 1)
        for (player, start) in zip(state.players, [hex(3, 9), hex(22, 4)]) {
            let units = state.units(of: player.id)
            #expect(units.map(\.type) == [.settler, .warrior, .scout])
            #expect(units[0].position == start && units[1].position == start)
            #expect(state.map.distance(units[2].position, start) == 1)
            #expect(units.allSatisfy { $0.movesLeft == state.rules.unit($0.type).moves && $0.hp == 100 })
            #expect(units.first { $0.type == .builder } == nil)
            #expect(player.explored.setCount > 0)
        }
        #expect(state.relations.count == 1)
        #expect(!state.relations[0].met && state.relations[0].stance == .peace)
        expectSound(state)
    }

    @Test func theHumanPicksACivAndTheAIsTakeTheRestInOrder() {
        #expect(GameState.civOrder(human: "mali", players: 4) == ["mali", "rome", "mongols", "china"])
        let map = makeTestMap(width: 30, height: 12)
        let state = GameState.newGame(seed: 4, map: map, startPositions: [hex(3, 9), hex(22, 4)],
                                      civs: GameState.civOrder(human: "china", players: 2))
        #expect(state.players.map(\.civ) == ["china", "rome"])
        #expect(state.players[0].name == "China")
        #expect(state.mapSizeName == "30x12")
    }
}

@Suite struct PhaseTests {
    /// One phase per living player, in player order; the turn number rises after the last
    /// (M1 §3).
    @Test func everyLivingPlayerHasAPhaseInOrder() throws {
        var state = makeTestState(players: 3)
        #expect(state.turn == 1 && state.currentPlayer == PlayerID(0) && state.phaseCount == 1)
        var records = try apply(.endTurn, &state)
        #expect(state.turn == 1 && state.currentPlayer == PlayerID(1) && state.phaseCount == 2)
        #expect(state.players[1].lastPhaseStart == 2)
        #expect(records.first == EventRecord(.phaseStarted(turn: 1, player: PlayerID(1)), audience: EventRecord.everyone))
        try apply(.endTurn, &state)
        records = try apply(.endTurn, &state)
        #expect(state.turn == 2 && state.currentPlayer == PlayerID(0) && state.phaseCount == 4)
        #expect(state.players.map(\.lastPhaseStart) == [4, 2, 3])
        #expect(Array(events(records).prefix(2)) == [.turnStarted(turn: 2), .phaseStarted(turn: 2, player: PlayerID(0))])
    }

    @Test func movesAreRestoredAtTheOwnersPhaseStart() throws {
        var state = makeTestState()
        let mine = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        let theirs = state.addUnit(.warrior, owner: PlayerID(1), at: hex(1, 6))
        try apply(.moveUnit(unit: mine, to: hex(2, 0)), &state)
        state.updateUnit(theirs) { $0.movesLeft = 0 }
        try apply(.endTurn, &state)
        #expect(state.unit(theirs)!.movesLeft == 2)
        #expect(state.unit(mine)!.movesLeft == 0)
        try apply(.endTurn, &state)
        #expect(state.unit(mine)!.movesLeft == 2)
    }

    /// A player with no cities and no Settlers is eliminated after the command (M1 §10);
    /// their units are removed and their phases skipped.
    @Test func eliminatedPlayersAreSkipped() throws {
        var state = makeTestState(players: 3)
        let warrior = state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 6))
        state.removeUnit(parkedSettler(of: PlayerID(1)))
        let records = try apply(.endTurn, &state)
        #expect(!state.players[1].isAlive)
        #expect(state.unit(warrior) == nil && state.units(of: PlayerID(1)).isEmpty)
        #expect(state.currentPlayer == PlayerID(2))
        #expect(state.livingPlayers == [PlayerID(0), PlayerID(2)])
        let eliminated = try #require(records.first { $0.event == .playerEliminated(PlayerID(1)) })
        #expect(eliminated.audience == EventRecord.everyone)
        #expect(state.outcome == nil)
        try apply(.endTurn, &state)
        #expect(state.turn == 2 && state.currentPlayer == PlayerID(0))
        try apply(.endTurn, &state)
        #expect(state.currentPlayer == PlayerID(2))
        expectSound(state)
    }

    /// If the current player is eliminated during their phase, the phase ends at once.
    @Test func eliminationEndsTheCurrentPhase() throws {
        var state = makeTestState(players: 3)
        try apply(.endTurn, &state)
        let records = try apply(.disband(unit: parkedSettler(of: PlayerID(1))), &state)
        #expect(!state.players[1].isAlive)
        #expect(state.currentPlayer == PlayerID(2))
        #expect(events(records).contains(.phaseStarted(turn: 1, player: PlayerID(2))))
    }

    @Test func theLastPlayerStandingWins() throws {
        var state = makeTestState()
        try apply(.endTurn, &state)
        let records = try apply(.disband(unit: parkedSettler(of: PlayerID(1))), &state)
        let outcome = GameOutcome.victory(player: PlayerID(0), kind: .lastStanding)
        #expect(state.outcome == outcome)
        #expect(events(records).contains(.gameOver(outcome)))
        #expect(throws: CommandError.gameOver) { try apply(.endTurn, &state) }
    }

    @Test func defeatWhenEveryHumanIsEliminated() throws {
        var state = makeTestState(players: 3)
        let records = try apply(.disband(unit: parkedSettler(of: PlayerID(0))), &state)
        #expect(state.outcome == .defeat)
        #expect(events(records).contains(.gameOver(.defeat)))
        #expect(throws: CommandError.gameOver) { try apply(.endTurn, &state) }
    }

    /// A player owning every other player's original capital wins (M1 §10), here by
    /// capturing them.
    @Test func dominationVictory() throws {
        var state = makeTestState(width: 30, height: 12, players: 3)
        setWar(&state, PlayerID(0), PlayerID(1))
        setWar(&state, PlayerID(0), PlayerID(2))
        addCity(&state, PlayerID(0), at: hex(3, 3))
        let b = addCity(&state, PlayerID(1), at: hex(10, 3))
        addCity(&state, PlayerID(1), at: hex(10, 9))
        let c = addCity(&state, PlayerID(2), at: hex(20, 3))
        addCity(&state, PlayerID(2), at: hex(20, 9))
        updateCity(&state, b) { $0.hp = 0 }
        updateCity(&state, c) { $0.hp = 0 }
        let first = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 3))
        let second = state.addUnit(.spearman, owner: PlayerID(0), at: hex(19, 3))
        try apply(.attack(unit: first, target: hex(10, 3)), &state)
        #expect(state.city(b)!.owner == PlayerID(0) && state.outcome == nil)
        let records = try apply(.attack(unit: second, target: hex(20, 3)), &state)
        let outcome = GameOutcome.victory(player: PlayerID(0), kind: .domination)
        #expect(state.outcome == outcome)
        #expect(events(records).last == .gameOver(outcome) && records.last?.audience == EventRecord.everyone)
        #expect(throws: CommandError.gameOver) { try apply(.endTurn, &state) }
    }

    /// Losing the last city with no Settler left eliminates a player (M1 §10): their units go,
    /// everyone hears of it; the last one standing wins.
    @Test func capturingTheLastCityEliminates() throws {
        var state = makeTestState(width: 24, height: 12, players: 3)
        setWar(&state, PlayerID(0), PlayerID(1))
        let city = addCity(&state, PlayerID(1), at: hex(10, 3))
        state.removeUnit(parkedSettler(of: PlayerID(1)))
        let straggler = state.addUnit(.warrior, owner: PlayerID(1), at: hex(16, 8))
        updateCity(&state, city) { $0.hp = 0 }
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 3))
        let records = try apply(.attack(unit: a, target: hex(10, 3)), &state)
        #expect(!state.players[1].isAlive && state.unit(straggler) == nil)
        let eliminated = try #require(records.first { $0.event == .playerEliminated(PlayerID(1)) })
        #expect(eliminated.audience == EventRecord.everyone)
        #expect(state.outcome == nil) // player 2 lives on with a Settler
        expectSound(state)

        var duel = makeTestState(width: 24, height: 12)
        setWar(&duel, PlayerID(0), PlayerID(1))
        let theirs = addCity(&duel, PlayerID(1), at: hex(10, 3))
        duel.removeUnit(parkedSettler(of: PlayerID(1)))
        updateCity(&duel, theirs) { $0.hp = 0 }
        let b = duel.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 3))
        try apply(.attack(unit: b, target: hex(10, 3)), &duel)
        #expect(duel.outcome == .victory(player: PlayerID(0), kind: .lastStanding))
    }

    /// A human who loses their last city with no Settler left is defeated (M1 §10).
    @Test func losingTheLastCityIsDefeat() throws {
        var state = makeTestState(width: 24, height: 12)
        setWar(&state, PlayerID(0), PlayerID(1))
        let mine = addCity(&state, PlayerID(0), at: hex(10, 3))
        state.removeUnit(parkedSettler(of: PlayerID(0)))
        try apply(.endTurn, &state)
        updateCity(&state, mine) { $0.hp = 0 }
        let a = state.addUnit(.warrior, owner: PlayerID(1), at: hex(11, 3))
        let records = try apply(.attack(unit: a, target: hex(10, 3)), &state)
        #expect(state.outcome == .defeat && events(records).last == .gameOver(.defeat))
    }

    /// At the end of the turn limit's last turn the highest score wins (ties: lower index).
    @Test func scoreVictoryAtTheTurnLimit() throws {
        var state = makeTestState()
        addCity(&state, PlayerID(1), at: hex(2, 2))
        state.turn = 250
        try apply(.endTurn, &state)
        #expect(state.outcome == nil)
        let records = try apply(.endTurn, &state)
        #expect(state.outcome == .victory(player: PlayerID(1), kind: .score))
        #expect(events(records) == [.gameOver(.victory(player: PlayerID(1), kind: .score))])
        #expect(state.turn == 250)

        var tied = makeTestState()
        tied.turn = 250
        try apply(.endTurn, &tied)
        try apply(.endTurn, &tied)
        #expect(tied.outcome == .victory(player: PlayerID(0), kind: .score))
    }

    /// Score = 5·cities + population + 3·techs + 2·buildings (Palace excluded).
    @Test func scoreCountsCitiesPopulationTechsAndBuildings() {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        updateCity(&state, id) { city in
            city.population = 3
            city.buildings = ["monument", "palace"]
        }
        state.learn("pottery", player: PlayerID(0))
        #expect(state.score(of: PlayerID(0)) == 5 + 3 + 3 + 2)
        #expect(state.view(for: PlayerID(1)).players.map(\.score) == [13, 0])
    }
}

@Suite struct ResearchTests {
    /// With prerequisites missing, research the first missing one in tree order and remember
    /// the target (M1 §6).
    @Test func researchWalksMissingPrerequisites() throws {
        var state = makeTestState()
        try apply(.setResearch(tech: "currency"), &state)
        #expect(state.players[0].researching == "pottery" && state.players[0].researchTarget == "currency")
        addCity(&state, PlayerID(0), at: hex(2, 2)) // Science 4 per phase
        state.players[0].researchProgress = 24
        try endPhases(until: PlayerID(1), &state)
        let records = try apply(.endTurn, &state)
        #expect(state.players[0].knownTechs == ["pottery"])
        #expect(state.players[0].researching == "writing" && state.players[0].researchProgress == 3)
        let learned = try #require(records.first { $0.event == .techResearched(player: PlayerID(0), tech: "pottery") })
        #expect(learned.audience == 0b01)
    }

    /// Overflow carries on, but at most one tech completes per phase.
    @Test func oneTechPerPhase() throws {
        var state = makeTestState()
        addCity(&state, PlayerID(0), at: hex(2, 2))
        try apply(.setResearch(tech: "currency"), &state)
        state.players[0].researchProgress = 196 // + 4 = 200: pottery (25), writing (45), currency (70)
        try nextTurn(&state)
        #expect(state.players[0].knownTechs == ["pottery"] && state.players[0].researchProgress == 175)
        try nextTurn(&state)
        #expect(state.players[0].knownTechs == ["pottery", "writing"] && state.players[0].researchProgress == 134)
        try nextTurn(&state)
        #expect(state.players[0].knownTechs == ["currency", "pottery", "writing"])
        #expect(state.players[0].researching == nil && state.players[0].researchTarget == nil)
        #expect(state.players[0].researchProgress == 68)
        // With nothing to research, science accumulates.
        try nextTurn(&state)
        #expect(state.players[0].researchProgress == 72)
    }

    @Test func researchRules() throws {
        var state = makeTestState()
        #expect(throws: CommandError.rejected(reason: "no such tech")) { try apply(.setResearch(tech: "fire"), &state) }
        state.learn("pottery", player: PlayerID(0))
        #expect(throws: CommandError.rejected(reason: "already known")) { try apply(.setResearch(tech: "pottery"), &state) }
        try apply(.setResearch(tech: "sailing"), &state) // its prerequisite is known
        #expect(state.players[0].researching == "sailing")
        // Techs unlock units, buildings and improvements.
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        try apply(.setQueue(city: id, items: [.building("granary")]), &state)
        #expect(throws: CommandError.rejected(reason: "Archer: needs Archery")) {
            try apply(.setQueue(city: id, items: [.unit(.archer)]), &state)
        }
        state.learn("archery", player: PlayerID(0))
        try apply(.setQueue(city: id, items: [.unit(.archer)]), &state)
    }
}

@Suite struct DiplomacyModelTests {
    /// One relation per player pair i < j, in pair order; everyone starts unmet and at peace.
    @Test func relationsArePairsInOrder() {
        let state = makeTestState(players: 4)
        #expect(state.relations.map { [$0.a.rawValue, $0.b.rawValue] } == [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]])
        for a in 0..<4 {
            for b in 0..<4 where a != b {
                let relation = state.relation(PlayerID(a), PlayerID(b))
                #expect(relation.involves(PlayerID(a)) && relation.involves(PlayerID(b)))
            }
        }
        #expect(state.relations.allSatisfy { !$0.met && $0.stance == .peace && $0.since == nil && $0.proposalFrom == nil })
        #expect(state.bordersClosed(to: PlayerID(0), by: PlayerID(1)) && !state.bordersClosed(to: PlayerID(0), by: PlayerID(0)))
    }

    /// A peace proposal unanswered by the proposer's next phase start expires and starts the
    /// proposer's cool-down (M1 §3 step 1, §9).
    @Test func unansweredProposalsExpire() throws {
        var state = makeTestState()
        setWar(&state, PlayerID(0), PlayerID(1))
        state.updateRelation(PlayerID(0), PlayerID(1)) { $0.proposalFrom = PlayerID(0) }
        try endPhases(until: PlayerID(1), &state)
        #expect(state.relation(PlayerID(0), PlayerID(1)).proposalFrom == PlayerID(0))
        let records = try apply(.endTurn, &state)
        let relation = state.relation(PlayerID(0), PlayerID(1))
        #expect(relation.proposalFrom == nil && relation.aCooldownEnds == 12 && relation.bCooldownEnds == 0)
        let declined = try #require(records.first { $0.event == .peaceDeclined(proposer: PlayerID(0), by: PlayerID(1)) })
        #expect(declined.audience == 0b11)
    }
}
