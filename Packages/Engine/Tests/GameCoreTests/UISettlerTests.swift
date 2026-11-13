import Testing
@testable import GameCore

// A Settler ready to found (GameCore/Queries/UISettler.swift, M1 §16): founding takes no moves,
// so a Settler whose march ends on a site at its owner's phase start, with no moves left, still
// waits for orders, and the engine lets it found the city in that phase.

@Suite struct UISettlerTests {
    private let me = PlayerID(0)

    @Test func aSpentSettlerOnASiteIsReadyToFound() throws {
        var state = makeTestState(map: openMap())
        let settler = state.addUnit(.settler, owner: me, at: hex(1, 3))
        // 4 tiles at 2 moves a turn: 2 now, the last 2 at the start of the next phase.
        try apply(.moveUnit(unit: settler, to: hex(5, 3)), &state)
        var unit = try #require(state.unit(settler))
        #expect(unit.destination == hex(5, 3))
        #expect(!state.view(for: me).standsReadyToFound(unit), "still marching")

        try nextTurn(&state)
        unit = try #require(state.unit(settler))
        #expect(unit.position == hex(5, 3) && unit.destination == nil && unit.movesLeft == 0)
        #expect(state.view(for: me).standsReadyToFound(unit))

        // Asleep, it waits for nothing; awake again, it is ready.
        try apply(.sleep(unit: settler), &state)
        #expect(!state.view(for: me).standsReadyToFound(try #require(state.unit(settler))))
        try apply(.wake(unit: settler), &state)
        #expect(state.view(for: me).standsReadyToFound(try #require(state.unit(settler))))

        // Founding takes no moves.
        let records = try apply(.foundCity(unit: settler), &state)
        #expect(events(records).contains { if case .cityFounded = $0 { true } else { false } })
        #expect(state.unit(settler) == nil)
    }

    @Test func notReadyWhereNoCityMayBeFounded() throws {
        var state = makeTestState(map: openMap())
        addCity(&state, me, at: hex(2, 3))
        // Within the minimum distance of a known city.
        let near = state.addUnit(.settler, owner: me, at: hex(4, 3))
        #expect(!state.view(for: me).standsReadyToFound(try #require(state.unit(near))))
        // Far enough: ready, whatever its moves.
        let far = state.addUnit(.settler, owner: me, at: hex(7, 3))
        state.updateUnit(far) { $0.movesLeft = 0 }
        #expect(state.view(for: me).standsReadyToFound(try #require(state.unit(far))))
        // Only units that found cities, and only the viewer's own.
        let warrior = state.addUnit(.warrior, owner: me, at: hex(8, 5))
        #expect(!state.view(for: me).standsReadyToFound(try #require(state.unit(warrior))))
        #expect(!state.view(for: PlayerID(1)).standsReadyToFound(try #require(state.unit(far))))
    }
}
