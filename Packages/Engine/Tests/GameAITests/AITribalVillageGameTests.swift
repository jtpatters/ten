import Foundation
import Testing
@testable import GameAI
@testable import GameCore
import MapGen

// Whole AI games with the tribal villages the standard rules place (p3g; M1 §7.7, §13, §18;
// DESIGN §9 GameAI): `GameState.newGame(…, placeTribalVillages: true)` places them and the
// engine takes them and gives the gifts, where AITribalVillageTests' games scatter their own
// (`scatterTribalVillages`) and play to turn 60. AI against AI over 150 turns: no errors, and
// deterministic; saved at turn 30 and loaded, the game goes on as the uninterrupted one.

/// A Duel game, all players AI, with the standard rules' tribal villages.
private func gameWithTribalVillages(seed: UInt64) -> GameState {
    let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: seed))
    return GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions, humanPlayers: [],
                             mapSizeName: MapSize.duel.rawValue, placeTribalVillages: true)
}

/// What a run of AI phases did, with the takes and gifts its events report.
private struct VillageGameRun {
    var commands: [[Command]] = []
    var rejections: [AIRejection] = []
    var capHits = 0
    /// Phases that ended without an `endTurn` while the game went on.
    var unfinishedPhases = 0
    var brokenInvariants: [String] = []
    /// `tribalVillageTaken` events, those by a unit (the rest: a city's land), and
    /// `tribalVillageGift` events.
    var takes = 0
    var unitTakes = 0
    var gifts = 0
}

/// Plays AI phases until turn `turn` starts or the game ends (as `playAI`, counting the takes).
private func playCountingTakes(_ state: inout GameState, until turn: Int, checkInvariants: Bool) -> VillageGameRun {
    var run = VillageGameRun()
    while state.outcome == nil, state.turn < turn {
        let player = state.currentPlayer
        let phaseTurn = state.turn
        let report = AIPlayer.playPhase(&state, player: player)
        run.commands.append(report.result.steps.map(\.command))
        run.rejections += report.rejections
        if report.hitCommandCap { run.capHits += 1 }
        for record in report.result.steps.flatMap(\.events) {
            switch record.event {
            case let .tribalVillageTaken(_, _, unit, _):
                run.takes += 1
                if unit != nil { run.unitTakes += 1 }
            case .tribalVillageGift:
                run.gifts += 1
            default:
                break
            }
        }
        if checkInvariants { run.brokenInvariants += state.checkInvariants().map { "turn \(phaseTurn) \(player): \($0)" } }
        if state.outcome == nil, state.currentPlayer == player {
            run.unfinishedPhases += 1
            break
        }
    }
    return run
}

/// A whole game with tribal villages played to turn `turn`, and the number placed.
private func playedGame(seed: UInt64, until turn: Int, checkInvariants: Bool = false) async -> (GameState, VillageGameRun, placed: Int) {
    var state = gameWithTribalVillages(seed: seed)
    let placed = DebugTools.tribalVillages(in: state).count
    let run = playCountingTakes(&state, until: turn, checkInvariants: checkInvariants)
    return (state, run, placed)
}

/// Gifts received over all players (each player's own count).
private func giftsReceived(_ state: GameState) -> Int {
    state.players.map { state.view(for: $0.id).tribalVillageGiftsReceived }.reduce(0, +)
}

@Suite struct AITribalVillageGameTests {
    /// 150 turns of AI against AI on a Duel map with the standard rules' tribal villages, twice:
    /// every phase ends with `endTurn`, no command is refused, the command cap is never hit, the
    /// invariants hold after every phase; both runs play the same commands and end with the same
    /// hash (M1 §12.7). The AIs take tribal villages, each take gives one gift, and every one
    /// placed was taken or still stands.
    @Test func aiVersusAIDuelWithTribalVillages() async throws {
        async let first = playedGame(seed: 7, until: 151, checkInvariants: true)
        async let second = playedGame(seed: 7, until: 151)
        let (state, run, placed) = await first
        let (again, rerun, _) = await second
        #expect(run.unfinishedPhases == 0)
        #expect(run.rejections.isEmpty, "\(run.rejections.prefix(5))")
        #expect(run.capHits == 0)
        #expect(run.brokenInvariants.isEmpty, "\(run.brokenInvariants.prefix(5))")
        #expect(state.outcome != nil || state.turn == 151)
        // Deterministic (M1 §12.7).
        #expect(run.commands == rerun.commands)
        #expect(state.stateHash() == again.stateHash())
        try #require(placed >= 4, "only \(placed) placed")
        let standing = DebugTools.tribalVillages(in: state).count
        #expect(run.unitTakes > 0 && run.gifts == run.takes, "\(run.takes) taken (\(run.unitTakes) by units), \(run.gifts) gifts")
        #expect(run.takes + standing == placed, "\(placed) placed, \(run.takes) taken, \(standing) standing")
        #expect(giftsReceived(state) == run.gifts)
    }

    /// A game with the standard rules' tribal villages saved at turn 30 as JSON, loaded (decoded
    /// with the rules) and continued to turn 60 ends exactly as the uninterrupted game. Some
    /// still stand at the save (seed 14: three, where most Duel games have none or one left),
    /// the load keeps them and the gifts given, and some of them are taken after it.
    @Test func saveAndLoadAtTurn30WithTribalVillages() async throws {
        async let uninterrupted = playedGame(seed: 14, until: 60)
        var (saved, _, _) = await playedGame(seed: 14, until: 30)
        let standing = DebugTools.tribalVillages(in: saved)
        try #require(!standing.isEmpty, "none stands at turn 30")
        var loaded = try roundTrip(saved)
        #expect(loaded == saved)
        #expect(DebugTools.tribalVillages(in: loaded) == standing && giftsReceived(loaded) == giftsReceived(saved))
        let after = playCountingTakes(&loaded, until: 60, checkInvariants: false)
        _ = playCountingTakes(&saved, until: 60, checkInvariants: false)
        let (straight, _, _) = await uninterrupted
        #expect(loaded.turn == 60 && straight.turn == 60)
        #expect(loaded.stateHash() == straight.stateHash() && saved.stateHash() == straight.stateHash())
        #expect(after.takes > 0, "none of the \(standing.count) standing at turn 30 taken by turn 60")
    }
}
