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

    /// A Warrior on the Builder's tile is the player's: the Builder is planned as going alone,
    /// so where foreign troops are near it stops only on a tile safe without the Warrior, which
    /// stays where it is.
    @Test func anEscortOnTheTileDoesNotCountAsComing() throws {
        var map = openMap()
        for t in map.tiles.indices { map[index: t].improvement = .farm }
        var state = makeState(map: map)
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p0, at: hex(12, 6))
        addCity(&state, p1, at: hex(18, 2))
        let builder = state.addUnit(.builder, owner: p0, at: hex(4, 8))
        let escort = state.addUnit(.warrior, owner: p0, at: hex(4, 8))
        state.addUnit(.warrior, owner: p1, at: hex(6, 6))
        setRelation(&state, p0, p1, war: false, since: nil)
        state.learn("theWheel", player: p0)
        for t in 0..<state.map.tileCount { state.players[0].explored[t] = true }
        refreshKnowledge(&state)
        let before = AITurn(state: state, player: p0)
        #expect(before.civilianDanger(state.view(for: p0)).contains(true))
        let commands = AIPlayer.builderCommands(state, player: p0, builders: [builder])
        #expect(commands.contains { if case .moveUnit(builder, _) = $0 { true } else { false } })
        for command in commands { _ = try GameEngine.apply(command, by: p0, to: &state) }
        #expect(state.unit(escort)?.position == hex(4, 8))
        let moved = try #require(state.unit(builder))
        #expect(moved.position != hex(4, 8))
        let turn = AITurn(state: state, player: p0)
        let view = state.view(for: p0)
        let t = try #require(view.index(of: moved.position))
        #expect(turn.safe(t, view, danger: turn.civilianDanger(view)))
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
