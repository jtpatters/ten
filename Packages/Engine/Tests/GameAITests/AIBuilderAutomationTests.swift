@testable import GameAI
@testable import GameCore
import Testing

/// `AIPlayer.builderCommands`: the App's Automate order for a human's Builders.
@Suite struct AIBuilderAutomationTests {
    let p0 = PlayerID(0), p1 = PlayerID(1)

    /// Only the automated Builder gets commands, and they apply in order to the real state.
    @Test func onlyTheAutomatedBuilderIsCommanded() throws {
        var map = openMap()
        for t in map.tiles.indices { map[index: t].improvement = .farm }
        var state = makeState(map: map)
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p0, at: hex(10, 6))
        addCity(&state, p1, at: hex(18, 2))
        let automated = state.addUnit(.builder, owner: p0, at: hex(5, 6))
        let manual = state.addUnit(.builder, owner: p0, at: hex(9, 6))
        let escort = state.addUnit(.warrior, owner: p0, at: hex(5, 6))
        state.learn("theWheel", player: p0)
        refreshKnowledge(&state)
        let commands = AIPlayer.builderCommands(state, player: p0, builders: [automated])
        #expect(commands == [.buildRoad(unit: automated)])
        for command in commands { _ = try GameEngine.apply(command, by: p0, to: &state) }
        #expect(state.map[hex(5, 6)].hasRoad)
        #expect(state.unit(manual)?.position == hex(9, 6) && state.unit(escort)?.position == hex(5, 6))
    }

    /// Nothing to do: the Builder goes home but is not put to sleep; out of its phase, nothing.
    @Test func idleBuildersAreNotSlept() {
        var map = openMap()
        for t in map.tiles.indices { map[index: t].improvement = .farm }
        var state = makeState(map: map)
        addCity(&state, p0, at: hex(4, 6))
        let builder = state.addUnit(.builder, owner: p0, at: hex(4, 6))
        refreshKnowledge(&state)
        #expect(AIPlayer.builderCommands(state, player: p0, builders: [builder]).isEmpty)
        #expect(AIPlayer.builderCommands(state, player: p1, builders: [builder]).isEmpty)
    }
}
