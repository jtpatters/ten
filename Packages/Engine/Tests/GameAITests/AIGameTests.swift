import Foundation
import Testing
@testable import GameAI
@testable import GameCore
import MapGen

// Whole AI-versus-AI games (M1 §13, §18): no errors, no refused commands, deterministic,
// expansion and war; save and load mid-game; statelessness. (Debug builds play these games
// some 80 times slower than release ones, so the games run concurrently where they can.)

/// Plays a whole AI game from the start (all players AI) to turn `turn`.
private func playGame(_ size: MapSize = .duel, seed: UInt64, until turn: Int,
                      checkInvariants: Bool = false) async -> (GameState, AIRun) {
    var state = aiGame(size, seed: seed)
    let run = playAI(&state, until: turn, checkInvariants: checkInvariants)
    return (state, run)
}

/// Plays AI phases on a copy of `state` until turn `turn` starts.
private func continueGame(_ state: GameState, until turn: Int) async -> GameState {
    var copy = state
    playAI(&copy, until: turn)
    return copy
}

@Suite struct AIGameTests {
    /// 150 turns of AI against AI on a Duel map, twice: every phase ends with `endTurn`, no
    /// command is refused, the command cap is never hit, the invariants hold after every
    /// phase, every AI founds at least 3 cities, a war starts; both runs play the same commands
    /// and end with the same hash.
    @Test func aiVersusAIDuel() async throws {
        async let first = playGame(seed: 7, until: 151, checkInvariants: true)
        async let second = playGame(seed: 7, until: 151)
        let (state, run) = await first
        let (again, rerun) = await second
        #expect(run.unfinishedPhases == 0)
        #expect(run.rejections.isEmpty, "\(run.rejections.prefix(5))")
        #expect(run.capHits == 0)
        #expect(run.brokenInvariants.isEmpty, "\(run.brokenInvariants.prefix(5))")
        #expect(state.outcome != nil || state.turn == 151)
        #expect(run.founded.indices.allSatisfy { !state.players[$0].isMajor || run.founded[$0] >= 3 }, "cities founded: \(run.founded)")
        #expect(!run.warTurns.isEmpty, "no war in 150 turns")
        #expect(run.maxCommandsInAPhase < state.rules.ai.maxCommandsPerPhase)
        // Deterministic (M1 §12.7).
        #expect(run.commands == rerun.commands)
        #expect(state.stateHash() == again.stateHash())
    }

    /// A game saved at turn 30 as JSON, loaded (decoded with the rules) and continued to turn
    /// 60 ends exactly as the uninterrupted game.
    @Test func saveAndLoadMidGame() async throws {
        async let uninterrupted = playGame(seed: 11, until: 60)
        var saved = aiGame(seed: 11)
        playAI(&saved, until: 30)
        var loaded = try roundTrip(saved)
        #expect(loaded == saved)
        playAI(&loaded, until: 60)
        let (straight, _) = await uninterrupted
        #expect(loaded.turn == 60 && straight.turn == 60)
        #expect(loaded.stateHash() == straight.stateHash())
    }

    /// ai-3: the same at war, mid-turn, on a Small map (four players: sightings, memories,
    /// relations and proposals all go through the save): saved in the third phase of turn 85,
    /// loaded and continued to turn 100, the game ends exactly as the uninterrupted one.
    @Test func saveAndLoadAtWarMidTurn() async throws {
        var state = aiGame(.small, seed: 4)
        playAI(&state, until: 85)
        for _ in 0..<2 { playPhase(&state) }
        let wars = state.relations.filter { $0.stance == .war }.count
        #expect(wars > 0, "no war at the save: the test proves less")
        var loaded = try roundTrip(state)
        let faithful = loaded == state
        #expect(faithful, "the decoded state differs from the saved one")
        async let straight = continueGame(state, until: 100)
        playAI(&loaded, until: 100)
        let uninterrupted = await straight
        #expect(loaded.turn == 100 && uninterrupted.turn == 100)
        #expect(loaded.stateHash() == uninterrupted.stateHash())
    }

    /// Stateless between phases (M1 §13): at any point, a decoded copy of the state plays the
    /// same commands as the original, and playing a phase twice from the same state gives the
    /// same commands.
    @Test func aiIsStateless() throws {
        var state = aiGame(seed: 5)
        for stop in [2, 20, 45, 80] {
            playAI(&state, until: stop)
            guard state.outcome == nil else { break }
            for _ in 0..<state.players.count {
                var original = state
                var copy = try roundTrip(state)
                var again = state
                let a = playPhase(&original).commands
                let b = playPhase(&copy).commands
                let c = playPhase(&again).commands
                #expect(a == b, "turn \(state.turn) \(state.currentPlayer): decoded copy played differently")
                #expect(a == c, "turn \(state.turn) \(state.currentPlayer): replay played differently")
                #expect(original == copy)
                state = original
                if state.outcome != nil { break }
            }
        }
    }

    /// Standard map, six AIs, 20 turns: no refusals and every phase ends (several rivals and
    /// sightings).
    @Test func sixAIsOnAStandardMap() async {
        let (state, run) = await playGame(.standard, seed: 2, until: 21)
        #expect(run.unfinishedPhases == 0)
        #expect(run.rejections.isEmpty, "\(run.rejections.prefix(5))")
        #expect(state.checkInvariants().isEmpty)
        #expect(run.founded.indices.allSatisfy { !state.players[$0].isMajor || run.founded[$0] >= 1 }, "cities founded: \(run.founded)")
    }
}
