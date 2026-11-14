@testable import GameCore
import Testing

/// Embarking and naval units (M2 §8.4).
@Suite struct NavalTests {
    /// Coast on columns 5…8, Ocean on column 9, rows 1…6.
    func sea(_ state: inout GameState) {
        for col in 5...9 {
            for row in 1...6 { state.map[hex(col, row)].terrain = col == 9 ? .ocean : .coast }
        }
        refreshKnowledge(&state)
    }

    @Test func embarkingNeedsSailingCostsAllMovesThenThreeSteps() throws {
        var state = makeTestState(map: openMap())
        sea(&state)
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: hex(4, 3))
        refreshKnowledge(&state)
        #expect(throws: (any Error).self) { try apply(.moveUnit(unit: w, to: hex(5, 3)), &state) }
        state.learn("sailing", player: PlayerID(0))
        _ = try apply(.moveUnit(unit: w, to: hex(5, 3)), &state)
        var unit = try #require(state.unit(w))
        #expect(unit.position == hex(5, 3) && unit.movesLeft == 0 && state.isEmbarked(unit))
        #expect(state.sight(of: unit) == 2)
        try nextTurn(&state)
        _ = try apply(.moveUnit(unit: w, to: hex(8, 3)), &state)
        unit = try #require(state.unit(w))
        #expect(unit.position == hex(8, 3) && unit.movesLeft == 0)
        try nextTurn(&state)
        #expect(throws: (any Error).self) { try apply(.moveUnit(unit: w, to: hex(9, 3)), &state) }
        state.learn("cartography", player: PlayerID(0))
        _ = try apply(.moveUnit(unit: w, to: hex(9, 3)), &state)
        #expect(state.unit(w)?.position == hex(9, 3))
        expectSound(state)
    }

    @Test func landingCostsOneMove() throws {
        var state = makeTestState(map: openMap())
        sea(&state)
        state.learn("sailing", player: PlayerID(0))
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: hex(5, 3))
        refreshKnowledge(&state)
        _ = try apply(.moveUnit(unit: w, to: hex(4, 3)), &state)
        #expect(state.unit(w)?.position == hex(4, 3) && state.unit(w)?.movesLeft == state.rules.points(1))
    }

    @Test func shipsSailWaterAndOwnCitiesOnly() throws {
        var state = makeTestState(map: openMap())
        sea(&state)
        state.learn("sailing", player: PlayerID(0))
        let port = addCity(&state, PlayerID(0), at: hex(4, 3))
        let inland = addCity(&state, PlayerID(0), at: hex(1, 3))
        #expect(state.itemProblem(.unit(.galley), in: state.city(port)!) == nil)
        #expect(state.itemProblem(.unit(.galley), in: state.city(inland)!) == "needs a coastal city")
        let g = state.addUnit(.galley, owner: PlayerID(0), at: hex(6, 3))
        refreshKnowledge(&state)
        #expect(!state.terrainAllows(tile(state, hex(3, 3)), .galley, owner: PlayerID(0)))
        #expect(!state.terrainAllows(tile(state, hex(9, 3)), .galley, owner: PlayerID(0)))
        #expect(state.terrainAllows(tile(state, hex(4, 3)), .galley, owner: PlayerID(0)))
        #expect(throws: (any Error).self) { try apply(.moveUnit(unit: g, to: hex(3, 3)), &state) }
        _ = try apply(.moveUnit(unit: g, to: hex(4, 3)), &state)
        #expect(state.unit(g)?.position == hex(4, 3) && state.unit(g)?.movesLeft == state.rules.points(1))
        #expect(!state.isEmbarked(state.unit(g)!))
        expectSound(state)
    }

    @Test func embarkedUnitsCannotAttackAndDefendWithTen() throws {
        var state = makeWarState()
        sea(&state)
        state.learn("sailing", player: PlayerID(0))
        state.learn("sailing", player: PlayerID(1))
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: hex(6, 3))
        let g = state.addUnit(.galley, owner: PlayerID(1), at: hex(7, 3))
        _ = g
        let shore = state.addUnit(.warrior, owner: PlayerID(1), at: hex(3, 3))
        refreshKnowledge(&state)
        #expect(throws: CommandError.rejected(reason: "embarked units cannot attack")) {
            try apply(.attack(unit: w, target: hex(7, 3)), &state)
        }
        let clash = state.clash(attacker: .unit(state.unit(g)!), defender: .unit(state.unit(w)!),
                                from: tile(state, hex(7, 3)), target: tile(state, hex(6, 3)), ranged: false, sees: { _ in true })
        #expect(clash.defence.total == state.rules.embark!.strength)
        _ = shore
    }

    @Test func landMeleeCannotAttackShipsAndShipsDoNotTakeCities() throws {
        var state = makeWarState()
        sea(&state)
        state.learn("sailing", player: PlayerID(1))
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: hex(4, 3))
        let g = state.addUnit(.galley, owner: PlayerID(1), at: hex(5, 3))
        refreshKnowledge(&state)
        #expect(throws: CommandError.rejected(reason: "cannot attack units at sea")) {
            try apply(.attack(unit: w, target: hex(5, 3)), &state)
        }
        #expect(!state.capturesCities(.galley))
        try endPhases(until: PlayerID(1), &state)
        #expect(throws: CommandError.rejected(reason: "ships cannot attack units on land")) {
            try apply(.attack(unit: g, target: hex(4, 3)), &state)
        }
    }

    @Test func shipsHealOnlyInOwnCities() {
        var state = makeTestState(map: openMap())
        sea(&state)
        state.learn("sailing", player: PlayerID(0))
        addCity(&state, PlayerID(0), at: hex(4, 3))
        let atSea = state.addUnit(.galley, owner: PlayerID(0), at: hex(6, 3))
        let inPort = state.addUnit(.galley, owner: PlayerID(0), at: hex(4, 3))
        state.turn = 5
        #expect(state.healing(for: state.unit(atSea)!) == 0)
        #expect(state.healing(for: state.unit(inPort)!) == state.rules.embark!.navalHealInCity)
    }
}
