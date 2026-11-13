import Foundation
import Testing
@testable import GameAI
@testable import GameCore
import MapGen

// Robustness (ai-3): situations a game reaches rarely — not the AI's phase, the game over
// during its phase, a rival eliminated mid-phase, no city yet, a lost capital, an empty
// treasury, wars on two fronts with proposals pending, islands, crowds of units. In each the AI
// has no command refused, ends its phase (unless the game ended) and leaves the invariants
// intact.

private let p0 = PlayerID(0)
private let p1 = PlayerID(1)
private let p2 = PlayerID(2)

/// Plays AI phases for `turns` turns, expecting what every run must: no refusal, no command
/// cap, every phase ended, the invariants intact after every phase.
@discardableResult
private func expectSoundRun(_ state: inout GameState, turns: Int, _ label: String) -> AIRun {
    let run = playAI(&state, until: state.turn + turns, checkInvariants: true)
    #expect(run.rejections.isEmpty, "\(label): \(run.rejections.prefix(3))")
    #expect(run.capHits == 0, "\(label): command cap hit")
    #expect(run.unfinishedPhases == 0, "\(label): a phase did not end")
    #expect(run.brokenInvariants.isEmpty, "\(label): \(run.brokenInvariants.prefix(3))")
    return run
}

@Suite struct AIRobustnessTests {
    /// Not the player's phase, or the game over: no command, nothing changed.
    @Test func nothingOutsideItsPhase() {
        var state = makeState()
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p1, at: hex(16, 6))
        let before = state
        #expect(AIPlayer.playTurn(&state, player: p1).steps.isEmpty)
        #expect(state == before)
        state.outcome = .victory(player: p1, kind: .score)
        let over = state
        #expect(AIPlayer.playTurn(&state, player: p0).steps.isEmpty)
        #expect(state == over)
    }

    /// The game ends during the phase (the rival's last city taken): the capture is the last
    /// step and no `endTurn` follows (it would be refused).
    @Test func gameEndsDuringItsPhase() throws {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(2, 6))
        let last = addCity(&state, p1, at: hex(8, 6))
        updateCity(&state, last) { $0.hp = 0 }
        let warrior = state.addUnit(.warrior, owner: p0, at: hex(7, 6))
        state.addUnit(.archer, owner: p0, at: hex(6, 8))
        state.addUnit(.warrior, owner: p1, at: hex(10, 9))
        setRelation(&state, p0, p1, war: true, since: 1)
        refreshKnowledge(&state)
        let (commands, report) = playPhase(&state)
        #expect(state.outcome == .victory(player: p0, kind: .domination) || state.outcome == .victory(player: p0, kind: .lastStanding))
        #expect(commands.last == .attack(unit: warrior, target: hex(8, 6)))
        #expect(!commands.contains(.endTurn))
        #expect(report.rejections.isEmpty)
    }

    /// A rival eliminated during the phase (its only city taken, its units removed) while a
    /// third player lives on: the AI plays on without touching the removed units and ends its
    /// phase; the game goes on.
    @Test func aRivalEliminatedMidPhase() throws {
        var state = makeState(map: openMap(width: 24, height: 12), players: 3)
        addCity(&state, p0, at: hex(2, 6))
        let last = addCity(&state, p1, at: hex(8, 6))
        addCity(&state, p2, at: hex(21, 6))
        updateCity(&state, last) { $0.hp = 0 }
        let warrior = state.addUnit(.warrior, owner: p0, at: hex(7, 6))
        state.addUnit(.archer, owner: p0, at: hex(9, 8))
        state.addUnit(.warrior, owner: p1, at: hex(10, 9))
        setRelation(&state, p0, p1, war: true, since: 1)
        refreshKnowledge(&state)
        let (commands, report) = playPhase(&state)
        #expect(commands.contains(.attack(unit: warrior, target: hex(8, 6))))
        #expect(!state.players[1].isAlive)
        #expect(state.outcome == nil)
        #expect(commands.last == .endTurn)
        #expect(report.rejections.isEmpty, "\(report.rejections)")
        #expect(state.checkInvariants().isEmpty)
        expectSoundRun(&state, turns: 3, "after the elimination")
    }

    /// No city yet, mid-game: a Settler that may not found where it stands (a foreign city it
    /// has not seen is 3 tiles away; cities need 4) finds a site and founds, without a refused
    /// `foundCity` (the borders it sees betray the city, ai-3); its Warrior and Scout keep busy
    /// meanwhile.
    @Test func noCityYet() {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p1, at: hex(12, 6))
        state.addUnit(.warrior, owner: p1, at: hex(12, 6))
        state.addUnit(.settler, owner: p0, at: hex(9, 6))
        state.addUnit(.warrior, owner: p0, at: hex(9, 7))
        state.addUnit(.scout, owner: p0, at: hex(8, 6))
        state.turn = 12
        refreshKnowledge(&state)
        let distance = state.map.distance(hex(9, 6), hex(12, 6))
        #expect(distance < state.rules.constants.city.minDistance)
        #expect(state.view(for: p0).canFoundCity(at: hex(9, 6)) == true) // by its knowledge
        let run = expectSoundRun(&state, turns: 8, "no city yet")
        #expect(run.founded[0] >= 1)
        #expect(state.players[0].isAlive)
    }

    /// The capital lost to a rival: the Palace moves to the other city and the AI plays on
    /// from there, at war.
    @Test func capitalLost() throws {
        var state = makeState(map: openMap(width: 24, height: 12), players: 3)
        let capital = addCity(&state, p0, at: hex(6, 6))
        let other = addCity(&state, p0, at: hex(3, 2))
        addCity(&state, p1, at: hex(14, 6))
        addCity(&state, p2, at: hex(20, 10))
        updateCity(&state, capital) { $0.hp = 0 }
        let raider = state.addUnit(.warrior, owner: p1, at: hex(7, 6))
        state.addUnit(.warrior, owner: p0, at: hex(3, 2))
        state.addUnit(.warrior, owner: p1, at: hex(14, 6))
        setRelation(&state, p0, p1, war: true, since: 1)
        refreshKnowledge(&state)
        _ = try GameEngine.apply(.endTurn, by: p0, to: &state)
        _ = try GameEngine.apply(.attack(unit: raider, target: hex(6, 6)), by: p1, to: &state)
        try #require(state.city(capital)?.owner == p1)
        _ = try GameEngine.apply(.endTurn, by: p1, to: &state)
        _ = try GameEngine.apply(.endTurn, by: p2, to: &state)
        try #require(state.currentPlayer == p0 && state.players[0].capital == other)
        let (commands, report) = playPhase(&state)
        #expect(report.rejections.isEmpty, "\(report.rejections)")
        #expect(commands.last == .endTurn)
        #expect(report.posture == .war)
        expectSoundRun(&state, turns: 4, "capital lost")
    }

    /// No gold and an upkeep deficit: units the treasury cannot keep are disbanded at phase
    /// start (M1 §7.1); the AI starts no military unit it could not keep and has nothing
    /// refused.
    @Test func bankruptWithAnUpkeepDeficit() throws {
        var state = makeState(map: openMap(width: 24, height: 12), gold: 0)
        addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 6))
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        for col in 3...9 { state.addUnit(.warrior, owner: p0, at: hex(col, 9)) }
        state.addUnit(.warrior, owner: p1, at: hex(18, 6))
        refreshKnowledge(&state)
        try #require(state.view(for: p0).income().net < 0)
        let run = expectSoundRun(&state, turns: 6, "bankrupt")
        let bought = run.commands.joined().filter { command in
            if case let .purchase(city, .unit(type)) = command { !type.isCivilian && state.city(city)?.owner == p0 } else { false }
        }
        #expect(bought.isEmpty, "\(bought)")
        #expect(state.view(for: p0).income().net >= 0)
        #expect(state.players[0].gold >= 0)
    }

    /// At war with two players, each with a peace proposal pending at the phase start: both
    /// are answered, and the AI plays on for ten turns without a refusal.
    @Test func warsOnTwoFrontsWithProposalsPending() throws {
        var state = makeState(map: openMap(width: 30, height: 14), players: 3)
        addCity(&state, p0, at: hex(14, 7))
        addCity(&state, p1, at: hex(4, 7))
        addCity(&state, p2, at: hex(25, 7))
        for (owner, spot) in [(p0, hex(14, 7)), (p1, hex(4, 7)), (p2, hex(25, 7)), (p0, hex(15, 7)), (p1, hex(8, 7)), (p2, hex(21, 7))] {
            state.addUnit(.warrior, owner: owner, at: spot)
        }
        setRelation(&state, p0, p1, war: true, since: 5)
        setRelation(&state, p0, p2, war: true, since: 5)
        state.updateRelation(p0, p1) { $0.proposalFrom = p1 }
        state.updateRelation(p0, p2) { $0.proposalFrom = p2 }
        state.turn = 20
        refreshKnowledge(&state)
        let (commands, report) = playPhase(&state)
        #expect(commands.contains { if case .respondToPeace(from: p1, _) = $0 { true } else { false } })
        #expect(commands.contains { if case .respondToPeace(from: p2, _) = $0 { true } else { false } })
        #expect(report.rejections.isEmpty, "\(report.rejections)")
        #expect(commands.last == .endTurn)
        expectSoundRun(&state, turns: 10, "two fronts")
    }

    /// Two islands a strait apart (M1 has no boats), each player knowing the other's city:
    /// once the war test could hold (turn 30) neither prepares a war it could never wage
    /// (ai-3); 60 turns without a refusal.
    @Test func islands() throws {
        var map = openMap(width: 20, height: 12, fill: Tile(terrain: .ocean))
        for centre in [hex(4, 6), hex(10, 6)] {
            for h in map.coords(within: 2, of: centre) { map[h] = Tile(terrain: .grassland) }
        }
        map[hex(3, 5)] = Tile(terrain: .plains, elevation: .hills)
        map[hex(11, 7)] = Tile(terrain: .plains, elevation: .hills)
        var state = makeState(map: map)
        addCity(&state, p0, at: hex(5, 6))
        addCity(&state, p1, at: hex(9, 6))
        for (owner, warrior, scout) in [(p0, hex(5, 6), hex(4, 6)), (p1, hex(9, 6), hex(10, 6))] {
            state.addUnit(.warrior, owner: owner, at: warrior)
            state.addUnit(.scout, owner: owner, at: scout)
        }
        reveal(&state, to: p0, from: hex(8, 6))
        reveal(&state, to: p1, from: hex(6, 6))
        let met = state.hasMet(p0, p1)
        try #require(met)
        try #require(state.view(for: p0).knownCities.contains { $0.owner == p1 })
        try #require(state.view(for: p1).knownCities.contains { $0.owner == p0 })
        var rejections: [AIRejection] = []
        var broken: [String] = []
        var prepared: [String] = []
        while state.outcome == nil, state.turn <= 60 {
            let player = state.currentPlayer
            let report = AIPlayer.playPhase(&state, player: player)
            rejections += report.rejections
            broken += state.checkInvariants()
            if report.posture == .prepare { prepared.append("turn \(state.turn) \(player) against \(String(describing: report.rival))") }
            guard state.outcome != nil || state.currentPlayer != player else {
                Issue.record("turn \(state.turn) \(player): the phase did not end")
                break
            }
        }
        #expect(state.turn > 60)
        #expect(rejections.isEmpty, "\(rejections.prefix(3))")
        #expect(broken.isEmpty, "\(broken.prefix(3))")
        #expect(prepared.isEmpty, "\(prepared.prefix(3))")
    }

    /// Crowds: 150 extra units dropped on a Duel game in its middle, with gold to spend: six
    /// turns without a refusal, the command cap or a broken invariant.
    @Test func crowdsOfUnits() {
        var state = aiGame(.duel, seed: 3)
        playAI(&state, until: 40)
        DebugTools.spawnUnits(count: 150, seed: 99, in: &state)
        for i in state.players.indices { state.players[i].gold += 400 }
        expectSoundRun(&state, turns: 6, "crowds")
    }
}
