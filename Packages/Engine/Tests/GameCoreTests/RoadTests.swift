@testable import GameCore
import Testing

/// Roads, pillage and repair (M2 §3.3).
@Suite struct RoadTests {
    @Test func movesCountThreePointsAndRoadsCostOne() {
        var state = makeTestState(map: openMap())
        let a = tile(state, hex(1, 1)), b = tile(state, hex(2, 1))
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        #expect(state.rules.movePoints == 3 && state.unit(w)!.movesLeft == 6)
        #expect(state.moveCost(from: a, to: b, .east) == 3)
        state.map[index: a].road = true
        #expect(state.moveCost(from: a, to: b, .east) == 3) // only road to road
        state.map[index: b].road = true
        state.map[index: b].elevation = .hills
        #expect(state.moveCost(from: a, to: b, .east) == 1)
        #expect(state.rules.movesText(7) == "2⅓" && state.rules.movesText(2) == "⅔" && state.rules.movesText(6) == "2")
    }

    @Test func engineeringBridgesRiversOnRoads() {
        var state = makeTestState(map: openMap())
        let a = tile(state, hex(1, 1)), b = tile(state, hex(2, 1))
        state.map[index: a].riverEdges = 1 << UInt8(HexDirection.east.rawValue)
        state.map[index: a].road = true
        state.map[index: b].road = true
        let crossing = state.rules.points(state.rules.river.crossingMoveCost)
        #expect(state.moveCost(from: a, to: b, .east, owner: PlayerID(0)) == 1 + crossing)
        state.learn("engineering", player: PlayerID(0))
        #expect(state.moveCost(from: a, to: b, .east, owner: PlayerID(0)) == 1)
        #expect(state.moveCost(from: a, to: b, .east, owner: PlayerID(1)) == 1 + crossing)
    }

    @Test func buildersLayRoadsAfterTheWheel() throws {
        var state = makeTestState(map: openMap())
        addCity(&state, PlayerID(0), at: hex(3, 3))
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(4, 3))
        let charges = state.unit(builder)!.charges
        #expect(throws: CommandError.rejected(reason: "needs The Wheel")) { try apply(.buildRoad(unit: builder), &state) }
        state.learn("theWheel", player: PlayerID(0))
        let records = try apply(.buildRoad(unit: builder), &state)
        #expect(events(records).contains(.roadBuilt(at: hex(4, 3), owner: PlayerID(0))))
        let after = try #require(state.unit(builder))
        #expect(state.map[hex(4, 3)].hasRoad && after.movesLeft == 0 && after.charges == charges)
        #expect(state.players[0].memory.remembersRoad(tile(state, hex(4, 3))))
        #expect(state.view(for: PlayerID(0)).tile(at: hex(4, 3))?.hasRoad == true)
        #expect(state.players[1].memory.remembersRoad(tile(state, hex(4, 3))) == state.players[1].visible[tile(state, hex(4, 3))])
        try nextTurn(&state)
        #expect(throws: CommandError.rejected(reason: "tile already has a road")) { try apply(.buildRoad(unit: builder), &state) }
        expectSound(state)
    }

    @Test func pillageThenRepair() throws {
        var state = makeWarState()
        let city = addCity(&state, PlayerID(1), at: hex(7, 3))
        let farm = hex(6, 3)
        claimTile(&state, farm, for: city)
        state.map[farm].improvement = .farm
        state.map[farm].road = true
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: farm)
        refreshKnowledge(&state)
        let before = state.tileYields(tile(state, farm), for: PlayerID(1))
        let gold = state.players[0].gold
        let records = try apply(.pillage(unit: w), &state)
        #expect(events(records).contains(.tilePillaged(at: farm, unit: w, by: PlayerID(0), owner: PlayerID(1), improvement: .farm,
                                                        gold: 25, healed: 0)))
        #expect(state.map[farm].isPillaged && state.map[farm].hasRoad && state.players[0].gold == gold + 25)
        #expect(state.unit(w)!.movesLeft == 0)
        #expect(state.tileYields(tile(state, farm), for: PlayerID(1)).food < before.food)
        expectSound(state)

        // Wounded, the next pillage (the road) heals nothing: only improvements heal.
        try nextTurn(&state)
        state.updateUnit(w) { $0.hp = 40 }
        try apply(.pillage(unit: w), &state)
        #expect(!state.map[farm].hasRoad && state.unit(w)!.hp == 40)
        try nextTurn(&state)
        #expect(throws: CommandError.rejected(reason: "nothing to pillage")) { try apply(.pillage(unit: w), &state) }

        // The owner's Builder repairs it for a charge.
        state.removeUnit(w)
        try endPhases(until: PlayerID(1), &state)
        let builder = state.addUnit(.builder, owner: PlayerID(1), at: farm)
        refreshKnowledge(&state)
        let charges = state.unit(builder)!.charges
        #expect(throws: CommandError.rejected(reason: "tile already improved")) { try apply(.buildImprovement(unit: builder, improvement: .mine), &state) }
        try apply(.buildImprovement(unit: builder, improvement: .farm), &state)
        #expect(!state.map[farm].isPillaged && state.map[farm].improvement == .farm)
        #expect(state.unit(builder).map(\.charges) ?? 0 == charges - 1)
        expectSound(state)
    }

    @Test func pillagingHealsTheWounded() throws {
        var state = makeWarState()
        let city = addCity(&state, PlayerID(1), at: hex(7, 3))
        claimTile(&state, hex(6, 3), for: city)
        state.map[hex(6, 3)].improvement = .farm
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: hex(6, 3))
        state.updateUnit(w) { $0.hp = 70 }
        let gold = state.players[0].gold
        try apply(.pillage(unit: w), &state)
        #expect(state.unit(w)!.hp == 100 && state.players[0].gold == gold)
    }

    @Test func onlyAtWarAndOnlyForeignTiles() throws {
        var state = makeTestState(map: openMap())
        let city = addCity(&state, PlayerID(1), at: hex(7, 3))
        claimTile(&state, hex(6, 3), for: city)
        state.map[hex(6, 3)].improvement = .farm
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: hex(6, 3))
        #expect(throws: CommandError.rejected(reason: "only tiles of a player you are at war with")) { try apply(.pillage(unit: w), &state) }
        let mine = addCity(&state, PlayerID(0), at: hex(2, 3))
        claimTile(&state, hex(3, 3), for: mine)
        state.map[hex(3, 3)].improvement = .farm
        let own = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 3))
        #expect(throws: CommandError.rejected(reason: "only tiles of a player you are at war with")) { try apply(.pillage(unit: own), &state) }
        let actions = state.view(for: PlayerID(0)).unitActions(for: own)
        #expect(actions.first { $0.kind == .pillage }?.isAvailable == false)
    }
}
