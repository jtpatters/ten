import Testing
import GameAI
import GameCore
import MapGen

@Suite struct AIPlayerTests {
    /// An AI's phase ends with its `.endTurn`, and the steps carry what each command produced.
    @Test func playTurnEndsThePhase() throws {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: 7))
        var state = GameState.newGame(seed: 7, map: generated.map, startPositions: generated.startPositions)
        let phase = state.phaseCount
        let result = AIPlayer.playTurn(&state, player: PlayerID(0))
        let last = try #require(result.steps.last)
        #expect(last.command == .endTurn)
        #expect(state.phaseCount == phase + 1 && state.currentPlayer == PlayerID(1)) // one phase per player (M1 §3)
    }
}
