@testable import GameAI
@testable import GameCore
import Testing

/// Naval AI (M2 §8.4).
@Suite struct AINavalTests {
    @Test func aCoastalCityWithNothingElseToBuildBuildsAShip() {
        var state = makeState()
        for col in 11..<20 { for row in 0..<12 { state.map[hex(col, row)].terrain = .coast } }
        let port = addCity(&state, PlayerID(0), at: hex(10, 5))
        let inland = addCity(&state, PlayerID(0), at: hex(4, 5))
        for id in [port, inland] {
            updateCity(&state, id) { $0.buildings += ["monument", "granary", "library", "market", "walls"] }
        }
        state.addUnit(.warrior, owner: PlayerID(0), at: hex(10, 5))
        state.addUnit(.warrior, owner: PlayerID(0), at: hex(4, 5))
        state.addUnit(.builder, owner: PlayerID(0), at: hex(5, 5))
        state.turn = 40
        state.learn("sailing", player: PlayerID(0))
        refreshKnowledge(&state)
        var turn = AITurn(state: state, player: PlayerID(0))
        turn.plan = turn.makePlan()
        #expect(turn.view.isCoastal(state.city(port)!) && !turn.view.isCoastal(state.city(inland)!))
        #expect(turn.decideQueue(for: port, turn.baseCounts()).first == .unit(.galley))
        #expect(turn.decideQueue(for: inland, turn.baseCounts()).first != .unit(.galley))
    }
}
