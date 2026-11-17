import Testing
@testable import GameCore

/// M3a increment 3a.1: the Renaissance's rules beyond its data (docs/M3a.md).
@Suite struct RenaissanceTests {
    let p0 = PlayerID(0), p1 = PlayerID(1)

    /// M3a §3.1: the cap gains its bonus in the Medieval era and again in every later era.
    @Test func theStockpileCapRisesEachEraFromTheMedieval() {
        var state = makeTestState()
        var caps: [Int] = []
        for era in 0...3 {
            state.worldEra = era
            caps.append(state.stockpileCap)
        }
        #expect(caps == [20, 20, 30, 40])
    }

    /// Techs carry lasting bonuses (M3a §6): Printing's Library Science counts once known.
    @Test func knownTechsAddTheirBonuses() {
        var state = makeTestState()
        func librarySciences() -> [Int] {
            state.bonuses(of: p0).compactMap(\.buildingYields).flatMap { $0 }.filter { $0.building == "library" }.map(\.yields.science)
        }
        #expect(librarySciences().isEmpty)
        state.learn("printing", player: p0)
        #expect(librarySciences() == [1])
        #expect(state.bonuses(of: p1).compactMap(\.buildingYields).isEmpty, "only the player who knows it")
    }

    /// M3a §4: a Fort defends its owner's land units (and counts as fortified), not another
    /// player's; Forts may not stand side by side.
    @Test func aFortDefendsItsOwnersUnitsAndStandsAlone() throws {
        var state = makeWarState()
        let centre = hex(3, 3)
        addCity(&state, p0, at: centre)
        let fortHex = hex(4, 3)
        let t = tile(state, fortHex)
        #expect(state.tileOwner(t) == p0)
        state.map[index: t].improvement = .fort
        let mine = state.addUnit(.musketman, owner: p0, at: fortHex)
        #expect(state.fortDefense(try #require(state.unit(mine)), at: t) == 6)
        let theirs = state.addUnit(.musketman, owner: p1, at: hex(8, 3))
        var visitor = try #require(state.unit(theirs))
        visitor.position = fortHex
        #expect(state.fortDefense(visitor, at: t) == nil, "only the owner's units")
        state.map[index: t].pillaged = true
        #expect(state.fortDefense(try #require(state.unit(mine)), at: t) == nil, "not while pillaged")
        state.map[index: t].pillaged = false

        state.learn("siegeTactics", player: p0)
        let next = try #require(state.map.neighbors(of: fortHex).first {
            $0 != centre && state.tileOwner(tile(state, $0)) == p0 && state.map[$0].improvement == nil
        })
        let builder = state.addUnit(.builder, owner: p0, at: next)
        #expect(state.improvementProblem(.fort, by: try #require(state.unit(builder))) == "not next to another Fort")
        #expect(!Improvement.tileWork.contains(.fort), "no Builder job list offers a Fort")
    }

    /// A map with land in columns 0–5 and 11 (where the Settlers park), coast between.
    private func coastState() -> GameState {
        var map = openMap()
        for c in 6..<(map.width - 1) {
            for r in 0..<map.height { map[hex(c, r)] = Tile(terrain: .coast) }
        }
        var state = makeTestState(map: map)
        setWar(&state, p0, p1)
        return state
    }

    /// M3a §9.4: a Privateer on a tile its enemy sees stays hidden unless one of the enemy's
    /// units or cities is next to it, or it attacked this turn or the last.
    @Test func hiddenShipsAreSeenOnlyUpClose() throws {
        var state = coastState()
        let lookout = state.addUnit(.musketman, owner: p0, at: hex(5, 3))
        let ship = state.addUnit(.privateer, owner: p1, at: hex(7, 3))
        refreshKnowledge(&state)
        var view = state.view(for: p0)
        #expect(view.isVisible(hex(7, 3)), "the tile is in sight")
        #expect(view.unit(ship) == nil && view.units(at: hex(7, 3)).isEmpty && !view.visibleUnits.contains { $0.id == ship })
        #expect(state.view(for: p1).unit(ship) != nil, "its owner sees it")
        guard case .problem = state.attackTarget(at: tile(state, hex(7, 3)), by: p0) else {
            Issue.record("a hidden ship is no target")
            return
        }
        #expect(state.players[0].memory.unit(ship) == nil, "nor sighted")
        #expect(!state.zocReaches(try #require(state.unit(ship)), from: tile(state, hex(7, 3)), to: tile(state, hex(6, 3))))

        // Next to it: seen.
        state.updateUnit(lookout) { $0.position = hex(6, 3) }
        state.map[hex(6, 3)] = Tile(terrain: .grassland)
        refreshKnowledge(&state)
        view = state.view(for: p0)
        #expect(view.unit(ship) != nil)
        if case .problem = state.attackTarget(at: tile(state, hex(7, 3)), by: p0) { Issue.record("a found ship is a target") }

        // Away again, but it attacked last turn: still seen; the turn after, hidden.
        state.updateUnit(lookout) { $0.position = hex(5, 3) }
        let now = state.turn
        state.updateUnit(ship) { $0.revealedUntil = now }
        refreshKnowledge(&state)
        #expect(state.view(for: p0).unit(ship) != nil)
        state.updateUnit(ship) { $0.revealedUntil = now - 1 }
        #expect(state.view(for: p0).unit(ship) == nil)
    }

    /// The enemy gets no event of a hidden ship's move, even across tiles it sees.
    @Test func aHiddenShipMovesUnreported() throws {
        var state = coastState()
        state.addUnit(.musketman, owner: p0, at: hex(5, 3))
        let ship = state.addUnit(.privateer, owner: p1, at: hex(8, 2))
        refreshKnowledge(&state)
        try endPhases(until: p1, &state)
        let records = try apply(.moveUnit(unit: ship, to: hex(7, 3)), &state)
        let moves = records.filter { if case .unitMoved = $0.event { true } else { false } }
        #expect(!moves.isEmpty)
        #expect(moves.allSatisfy { $0.audience & 1 == 0 }, "player 0 sees none of it")
        #expect(moves.contains { $0.audience & 2 != 0 }, "its owner does")
        expectSound(state)
    }
}
