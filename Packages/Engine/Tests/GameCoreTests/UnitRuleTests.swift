import Foundation
import Testing
@testable import GameCore

@Suite struct ActivityTests {
    @Test func fortifyTakesEffectAtTheNextPhaseStart() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        try apply(.fortify(unit: id), &state)
        #expect(state.unit(id)!.activity == .fortifying)
        #expect(throws: CommandError.rejected(reason: "already fortified")) { try apply(.fortify(unit: id), &state) }
        try endPhases(until: PlayerID(1), &state)
        #expect(state.unit(id)!.activity == .fortifying) // only at its owner's phase start
        try nextTurn(&state)
        #expect(state.unit(id)!.activity == .fortified)
        try nextTurn(&state)
        #expect(state.unit(id)!.activity == .fortified)
        try apply(.wake(unit: id), &state)
        #expect(state.unit(id)!.activity == .none)
        #expect(throws: CommandError.rejected(reason: "not asleep or fortified")) { try apply(.wake(unit: id), &state) }
        #expect(throws: CommandError.rejected(reason: "civilians cannot fortify")) {
            try apply(.fortify(unit: parkedSettler(of: PlayerID(0))), &state)
        }
    }

    @Test func movingClearsTheActivity() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        try apply(.fortify(unit: id), &state)
        try apply(.moveUnit(unit: id, to: hex(2, 1)), &state)
        #expect(state.unit(id)!.activity == .none)
    }

    @Test func fortifyAndSleepClearStandingOrders() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        try apply(.moveUnit(unit: id, to: hex(6, 0)), &state)
        try apply(.sleep(unit: id), &state)
        #expect(state.unit(id)!.destination == nil && state.unit(id)!.activity == .sleeping)
        try nextTurn(&state)
        #expect(state.unit(id)!.position == hex(2, 0))
    }

    /// Sleepers sleep until woken, moved, or an enemy comes within 2 (M1 §7.4).
    @Test func sleepersWakeWhenAnEnemyComesNear() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        try apply(.sleep(unit: id), &state)
        #expect(throws: CommandError.rejected(reason: "already asleep")) { try apply(.sleep(unit: id), &state) }
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(3, 1)) // at peace: not an enemy
        try nextTurn(&state)
        #expect(state.unit(id)!.activity == .sleeping)
        setWar(&state, PlayerID(0), PlayerID(1))
        try nextTurn(&state)
        #expect(state.unit(id)!.activity == .none)
    }

    @Test func skipLastsUntilTheNextPhase() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        try apply(.skip(unit: id), &state)
        #expect(state.unit(id)!.activity == .skipped)
        #expect(throws: CommandError.rejected(reason: "already has an activity")) { try apply(.skip(unit: id), &state) }
        try nextTurn(&state)
        #expect(state.unit(id)!.activity == .none)
    }

    @Test func disbandRemovesTheUnit() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        let records = try apply(.disband(unit: id), &state)
        #expect(state.unit(id) == nil)
        #expect(events(records) == [.unitDisbanded(unit: id, type: .warrior, owner: PlayerID(0), at: hex(1, 1), upkeep: false)])
        #expect(records[0].audience == 0b01)
    }
}

@Suite struct HealingTests {
    /// +20 in an own city, +15 in own territory, +10 in neutral land, +5 in foreign territory
    /// (max 100), for units that neither moved nor attacked during their owner's previous phase.
    @Test func healingDependsOnWhereTheUnitStands() throws {
        var state = makeTestState(width: 20, height: 10)
        addCity(&state, PlayerID(0), at: hex(3, 3))
        addCity(&state, PlayerID(1), at: hex(12, 3))
        let inCity = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 3))
        let inTerritory = state.addUnit(.warrior, owner: PlayerID(0), at: hex(4, 3))
        let neutral = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 7))
        let abroad = state.addUnit(.builder, owner: PlayerID(0), at: hex(13, 3)) // civilians may stay
        let nearlyFull = state.addUnit(.scout, owner: PlayerID(0), at: hex(2, 3))
        let mover = state.addUnit(.scout, owner: PlayerID(0), at: hex(8, 8))
        for id in [inCity, inTerritory, neutral, abroad, mover] { state.updateUnit(id) { $0.hp = 50 } }
        state.updateUnit(nearlyFull) { $0.hp = 95 }
        try apply(.moveUnit(unit: mover, to: hex(9, 8)), &state)
        try nextTurn(&state)
        #expect(state.unit(inCity)!.hp == 70)
        #expect(state.unit(inTerritory)!.hp == 65)
        #expect(state.unit(neutral)!.hp == 60)
        #expect(state.unit(abroad)!.hp == 55)
        #expect(state.unit(nearlyFull)!.hp == 100)
        #expect(state.unit(mover)!.hp == 50) // it moved in its owner's previous phase
        try nextTurn(&state)
        #expect(state.unit(mover)!.hp == 60)
    }
}

@Suite struct UpkeepTests {
    @Test func militaryUnitsBeyondTheAllowanceCostGold() throws {
        var state = makeTestState(gold: 20)
        for col in 0..<4 { state.addUnit(.warrior, owner: PlayerID(0), at: hex(col, 1)) }
        state.addUnit(.builder, owner: PlayerID(0), at: hex(0, 1)) // civilians are free
        #expect(state.freeUnitAllowance(of: PlayerID(0)) == 2)
        #expect(state.upkeep(of: PlayerID(0)) == 2)
        try nextTurn(&state)
        #expect(state.players[0].gold == 18)
        #expect(state.players[1].gold == 20) // only at each player's own phase start

        addCity(&state, PlayerID(0), at: hex(8, 4)) // +1 free unit
        #expect(state.view(for: PlayerID(0)).income().upkeep == 1)
    }

    /// While the treasury would be negative and there are more military units than the free
    /// allowance, the cheapest (then highest id) is disbanded (M1 §7.1).
    @Test func unpaidUpkeepDisbandsTheCheapestUnits() throws {
        var state = makeTestState(gold: 1)
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 1))
        let scoutA = state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 1))
        let scoutB = state.addUnit(.scout, owner: PlayerID(0), at: hex(2, 1))
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(3, 1))
        try endPhases(until: PlayerID(1), &state)
        let records = try apply(.endTurn, &state)
        // Upkeep 2 > 1 Gold: scout B goes; upkeep 1 is then paid.
        #expect(state.unit(scoutB) == nil)
        #expect([warrior, scoutA, archer].allSatisfy { state.unit($0) != nil })
        #expect(state.players[0].gold == 0)
        let disbanded = try #require(records.first {
            $0.event == .unitDisbanded(unit: scoutB, type: .scout, owner: PlayerID(0), at: hex(2, 1), upkeep: true)
        })
        #expect(disbanded.isVisible(to: PlayerID(0)) && !disbanded.isVisible(to: PlayerID(1)))

        // With no gold at all, units go until the rest are free.
        try nextTurn(&state)
        #expect(state.units(of: PlayerID(0)).filter { !$0.type.isCivilian }.map(\.id) == [warrior, archer])
        #expect(state.players[0].gold == 0)
    }
}

@Suite struct BuilderTests {
    /// Around a city at (2,2): plains hills at (1,2), forest at (2,3), the rest grassland.
    func makeState() -> (GameState, CityID) {
        var map = makeTestMap()
        map[hex(1, 2)] = Tile(terrain: .plains, elevation: .hills)
        map[hex(2, 3)] = Tile(terrain: .grassland, feature: .forest)
        var state = makeTestState(map: map)
        let city = addCity(&state, PlayerID(0), at: hex(2, 2))
        return (state, city)
    }

    @Test func buildersImproveOwnedTiles() throws {
        var (state, _) = makeState()
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(3, 2))
        #expect(state.unit(builder)!.charges == 3)
        let records = try apply(.buildImprovement(unit: builder, improvement: .farm), &state)
        let t = state.map.index(of: hex(3, 2))!
        #expect(state.map.tiles[t].improvement == .farm)
        #expect(state.unit(builder)!.charges == 2 && state.unit(builder)!.movesLeft == 0)
        #expect(events(records) == [.improvementBuilt(improvement: .farm, at: hex(3, 2), owner: PlayerID(0))])
        #expect(state.players[0].memory.tileImprovement[t] == Improvement.farm.rawValue)
        #expect(throws: CommandError.rejected(reason: "no moves left")) {
            try apply(.buildImprovement(unit: builder, improvement: .pasture), &state)
        }
        expectSound(state)
    }

    @Test func improvementRules() throws {
        var (state, _) = makeState()
        func problem(_ improvement: Improvement, at h: HexCoord) -> String? {
            let id = state.addUnit(.builder, owner: PlayerID(0), at: h)
            defer { state.removeUnit(id) }
            return state.improvementProblem(improvement, by: state.unit(id)!)
        }
        #expect(problem(.farm, at: hex(3, 2)) == nil)
        #expect(problem(.farm, at: hex(6, 6)) == "tile not in your territory")
        #expect(problem(.farm, at: hex(2, 2)) == "not on a city centre")
        #expect(problem(.farm, at: hex(2, 3)) == "Farm not allowed here") // forest
        #expect(problem(.mine, at: hex(3, 2)) == "Mine not allowed here") // flat
        #expect(problem(.mine, at: hex(1, 2)) == "needs Mining")
        #expect(problem(.pasture, at: hex(3, 2)) == "needs Animal Husbandry")
        state.learn("mining", player: PlayerID(0))
        #expect(problem(.mine, at: hex(1, 2)) == nil)
        state.map[hex(3, 2)].improvement = .farm
        #expect(problem(.pasture, at: hex(3, 2)) == "tile already improved")

        // Only Builders improve tiles.
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(2, 1))
        #expect(throws: CommandError.rejected(reason: "only Builders improve tiles")) {
            try apply(.buildImprovement(unit: warrior, improvement: .farm), &state)
        }
    }

    @Test func theLastChargeUsesUpTheBuilder() throws {
        var (state, _) = makeState()
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(2, 1))
        state.updateUnit(builder) { $0.charges = 1 }
        try apply(.buildImprovement(unit: builder, improvement: .farm), &state)
        #expect(state.unit(builder) == nil)
        #expect(state.map[hex(2, 1)].improvement == .farm)
    }

    /// An improvement changes what the city's citizens work at once.
    @Test func improvementsFeedTheCity() throws {
        var (state, _) = makeState()
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(3, 2))
        try apply(.buildImprovement(unit: builder, improvement: .farm), &state)
        #expect(state.city(at: hex(2, 2))!.workedTiles == [hex(3, 2)])
        #expect(state.cityYields(state.city(at: hex(2, 2))!).total.food == 5)
    }
}

@Suite struct ClosedBorderTests {
    /// Military units may not enter the territory of a player they are at peace with;
    /// civilians may (M1 §9).
    @Test func militaryUnitsStayOutOfTerritoryAtPeace() throws {
        var state = makeTestState()
        addCity(&state, PlayerID(1), at: hex(8, 3))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(8, 1))
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(8, 1))
        // (8,2) belongs to player 1 and player 0 sees it.
        #expect(state.players[0].memory.tileOwner[state.map.index(of: hex(8, 2))!] == 2)
        #expect(Pathfinder.findPath(for: state.unit(warrior)!, to: hex(8, 2), in: state) == nil)
        #expect(Pathfinder.findPath(for: state.unit(builder)!, to: hex(8, 2), in: state) != nil)
        // At war the borders open.
        setWar(&state, PlayerID(0), PlayerID(1))
        #expect(Pathfinder.findPath(for: state.unit(warrior)!, to: hex(8, 2), in: state) != nil)
        // Never into a foreign city.
        #expect(Pathfinder.findPath(for: state.unit(builder)!, to: hex(8, 3), in: state) == nil)
    }

    /// A military unit inside territory closed to it moves out at its owner's next phase start,
    /// to the nearest tile it may stand on (ties: lower index).
    @Test func unitsInClosedTerritoryAreMovedOut() throws {
        var state = makeTestState()
        addCity(&state, PlayerID(1), at: hex(8, 3))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 3))
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(9, 3))
        try endPhases(until: PlayerID(1), &state)
        let records = try apply(.endTurn, &state)
        let expected = state.map.coords(within: 1, of: hex(9, 3))
            .map { state.map.index(of: $0)! }
            .filter { state.tileOwner($0) == nil && state.rules.isPassable(state.map.tiles[$0]) }
            .min()!
        #expect(state.unit(warrior)!.position == state.map.coord(at: expected))
        #expect(state.unit(builder)!.position == hex(9, 3))
        #expect(events(records).contains(.unitMoved(unit: warrior, from: hex(9, 3), path: [state.map.coord(at: expected)])))
    }
}
