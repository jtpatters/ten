@testable import GameAI
@testable import GameCore
import Testing

/// The AI's roads and pillage (M2 §3.3).
@Suite struct AIRoadTests {
    let p0 = PlayerID(0), p1 = PlayerID(1)

    /// A Builder with nothing to improve lays the road between its cities, starting where it stands.
    @Test func idleBuilderLaysTheRoadBetweenCities() throws {
        var map = openMap()
        for t in map.tiles.indices { map[index: t].improvement = .farm }
        var state = makeState(map: map)
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p0, at: hex(10, 6))
        addCity(&state, p1, at: hex(18, 2))
        let builder = state.addUnit(.builder, owner: p0, at: hex(5, 6))
        refreshKnowledge(&state)
        #expect(AITurn(state: state, player: p0).roadWork(state.view(for: p0)).isEmpty)
        state.learn("theWheel", player: p0)
        let work = AITurn(state: state, player: p0).roadWork(state.view(for: p0))
        #expect(Set(work) == Set((5...9).map { tile(state, hex($0, 6)) }))
        let (commands, report) = playPhase(&state)
        #expect(report.rejections.isEmpty)
        #expect(commands.contains(.buildRoad(unit: builder)))
        #expect(state.map[hex(5, 6)].hasRoad)
    }

    /// At war, a unit standing on an enemy improvement pillages it; at peace it does not.
    @Test func pillagesEnemyImprovementsOnlyAtWar() throws {
        var state = makeState(map: openMap())
        addCity(&state, p0, at: hex(3, 6))
        let city = addCity(&state, p1, at: hex(12, 6))
        let farm = hex(11, 6)
        state.tileCity[tile(state, farm)] = Int32(city.rawValue + 1)
        state.map[farm].improvement = .farm
        let w = state.addUnit(.warrior, owner: p0, at: farm)
        refreshKnowledge(&state)
        var peace = AITurn(state: state, player: p0)
        peace.pillage()
        #expect(peace.steps.isEmpty)
        setRelation(&state, p0, p1, war: true, since: 1)
        refreshKnowledge(&state)
        var war = AITurn(state: state, player: p0)
        war.pillage()
        #expect(war.rejections.isEmpty && war.steps.map(\.command) == [.pillage(unit: w)])
        #expect(war.state.map[farm].isPillaged && war.state.players[0].gold == state.players[0].gold + 25)
    }
}
