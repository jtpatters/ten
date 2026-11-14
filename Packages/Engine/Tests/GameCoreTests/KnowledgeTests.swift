import Foundation
import Testing
@testable import GameCore

@Suite struct KnowledgeTests {
    /// Visible: within each own unit's sight, within 2 of each own city centre, and every owned
    /// tile; explored: every tile ever visible (M1 §11).
    @Test func visibilityComesFromUnitsCitiesAndTerritory() throws {
        var state = makeTestState(width: 24, height: 12)
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(4, 5))
        func visible(_ h: HexCoord) -> Bool { state.players[0].visible[state.map.index(of: h)!] }
        func explored(_ h: HexCoord) -> Bool { state.players[0].explored[state.map.index(of: h)!] }
        #expect(visible(hex(7, 5)) && !visible(hex(8, 5))) // sight 3

        let city = addCity(&state, PlayerID(0), at: hex(14, 6))
        #expect(visible(hex(16, 6)) && !visible(hex(17, 6))) // city sight 2
        state.tileCity[state.map.index(of: hex(17, 6))!] = Int32(city.rawValue + 1)
        refreshKnowledge(&state)
        #expect(visible(hex(17, 6))) // owned

        try apply(.moveUnit(unit: scout, to: hex(7, 5)), &state)
        #expect(!visible(hex(1, 5)) && explored(hex(1, 5)))
        #expect(visible(hex(10, 5)))
        #expect(state.visibleTiles(for: PlayerID(0)) == state.players[0].visible)
        expectSound(state)
    }

    /// Memory keeps a tile's owner and improvement as last seen, and refreshes them when the
    /// tile is seen again; city sightings likewise.
    @Test func memoryKeepsWhatWasLastSeen() throws {
        var state = makeTestState(width: 24, height: 12)
        let theirs = addCity(&state, PlayerID(1), at: hex(14, 5))
        let farm = state.map.index(of: hex(15, 5))!
        state.map[index: farm].improvement = .farm
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(12, 5))
        var memory = state.players[0].memory
        #expect(memory.tileOwner[farm] == 2 && memory.tileImprovement[farm] == Improvement.farm.rawValue)
        let sighting = try #require(memory.city(theirs))
        #expect(sighting.owner == PlayerID(1) && sighting.position == hex(14, 5) && sighting.population == 1)
        #expect(sighting.capital && !sighting.walls && sighting.hp == 200 && sighting.turnSeen == 1)
        #expect(sighting.name == state.city(theirs)!.name)
        #expect(state.view(for: PlayerID(0)).knownCity(at: hex(14, 5))?.id == theirs)

        // Out of sight, the world changes; memory does not.
        try apply(.moveUnit(unit: scout, to: hex(9, 5)), &state)
        #expect(!state.players[0].visible[farm])
        state.map[index: farm].improvement = nil
        updateCity(&state, theirs) { $0.population = 3 }
        refreshKnowledge(&state)
        memory = state.players[0].memory
        #expect(memory.tileImprovement[farm] == Improvement.farm.rawValue && memory.city(theirs)?.population == 1)
        #expect(state.view(for: PlayerID(0)).tile(at: hex(15, 5))?.improvement == .farm)

        // Seen again: refreshed.
        try nextTurn(&state)
        try apply(.moveUnit(unit: scout, to: hex(12, 5)), &state)
        memory = state.players[0].memory
        #expect(memory.tileImprovement[farm] == 0)
        #expect(memory.city(theirs)?.population == 3 && memory.city(theirs)?.turnSeen == 2)
        // Own cities are remembered too.
        let mine = addCity(&state, PlayerID(0), at: hex(4, 9))
        #expect(state.players[0].memory.city(mine)?.owner == PlayerID(0))
        expectSound(state)
    }

    /// A remembered city is forgotten once its tile is seen without it.
    @Test func citiesSeenGoneAreForgotten() throws {
        var state = makeTestState(width: 24, height: 12)
        let theirs = addCity(&state, PlayerID(1), at: hex(14, 5))
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(12, 5))
        #expect(state.players[0].memory.city(theirs) != nil)
        try apply(.moveUnit(unit: scout, to: hex(9, 5)), &state)

        // The city goes (razing is M1 Core-2's: remove it directly).
        state.cities.removeAll { $0.id == theirs }
        for t in state.tileCity.indices where state.tileCity[t] == Int32(theirs.rawValue + 1) { state.tileCity[t] = 0 }
        refreshKnowledge(&state)
        #expect(state.players[0].memory.city(theirs) != nil) // not seen gone yet

        try nextTurn(&state)
        try apply(.moveUnit(unit: scout, to: hex(12, 5)), &state)
        #expect(state.players[0].memory.city(theirs) == nil)
        #expect(state.players[0].memory.tileOwner[state.map.index(of: hex(14, 5))!] == 0)
    }

    /// Foreign military units are sighted while visible, kept at their last tile for 20 turns,
    /// and forgotten when seen killed; civilians are not sighted (M1 §11).
    @Test func unitSightings() throws {
        var state = makeTestState()
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 1))
        let warrior = state.addUnit(.warrior, owner: PlayerID(1), at: hex(3, 1))
        state.addUnit(.builder, owner: PlayerID(1), at: hex(3, 2))
        var sightings = state.players[0].memory.units
        #expect(sightings == [UnitSighting(id: warrior, owner: PlayerID(1), type: .warrior, position: hex(3, 1), hp: 100, turnSeen: 1)])
        #expect(state.view(for: PlayerID(0)).sightings == sightings)

        state.removeUnit(scout)
        refreshKnowledge(&state)
        state.turn = 21
        refreshKnowledge(&state)
        sightings = state.players[0].memory.units
        #expect(sightings.map(\.position) == [hex(3, 1)])
        state.turn = 22
        refreshKnowledge(&state)
        #expect(state.players[0].memory.units.isEmpty)

        // Seen killed (here: disbanded in sight).
        var other = makeTestState()
        other.addUnit(.scout, owner: PlayerID(0), at: hex(1, 1))
        let doomed = other.addUnit(.warrior, owner: PlayerID(1), at: hex(3, 1))
        #expect(!other.players[0].memory.units.isEmpty)
        try apply(.endTurn, &other)
        let records = try apply(.disband(unit: doomed), &other)
        #expect(other.players[0].memory.units.isEmpty)
        #expect(records.first?.isVisible(to: PlayerID(0)) == true) // the disbanding happened in sight
    }

    @Test func playersMeetWhenTheySeeEachOther() throws {
        var state = makeTestState(width: 24, height: 12)
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(4, 5))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(10, 5))
        #expect(!state.hasMet(PlayerID(0), PlayerID(1)))
        #expect(!state.view(for: PlayerID(0)).hasMet(PlayerID(1)))
        let records = try apply(.moveUnit(unit: scout, to: hex(7, 5)), &state)
        #expect(state.hasMet(PlayerID(0), PlayerID(1)) && state.relation(PlayerID(1), PlayerID(0)).met)
        let met = try #require(records.first { $0.event == .playersMet(PlayerID(0), PlayerID(1)) })
        #expect(met.audience == 0b11)
        #expect(state.view(for: PlayerID(1)).relation(with: PlayerID(0))?.stance == .peace)
    }

    /// Tile events reach the players for whom a tile they name is visible before or after the
    /// command (M1 §12.5).
    @Test func eventsReachOnlyPlayersWhoSeeThem() throws {
        var state = makeTestState(width: 24, height: 12)
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(9, 5))
        let mover = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 5))
        func moved(_ records: [EventRecord]) -> EventRecord? {
            records.first { if case .unitMoved = $0.event { true } else { false } }
        }
        let far = try #require(moved(try apply(.moveUnit(unit: mover, to: hex(5, 5)), &state)))
        #expect(far.audience == 0b01)
        try nextTurn(&state)
        // Player 1 (warrior at (9,5), sight 2) sees (7,5) but neither (5,5) nor (6,5): it gets
        // only the step it sees, never the hidden start (per-step audience, M1 §12.5).
        let near = try apply(.moveUnit(unit: mover, to: hex(7, 5)), &state).filter {
            if case .unitMoved = $0.event { true } else { false }
        }
        #expect(near == [EventRecord(.unitMoved(unit: mover, from: hex(5, 5), path: [hex(6, 5), hex(7, 5)]), audience: 0b01),
                         EventRecord(.unitMoved(unit: mover, from: hex(6, 5), path: [hex(7, 5)]), audience: 0b10)])
        // Once it sees the whole path, it shares the owner's record.
        try nextTurn(&state)
        let close = try #require(moved(try apply(.moveUnit(unit: mover, to: hex(8, 4)), &state)))
        #expect(close == EventRecord(.unitMoved(unit: mover, from: hex(7, 5), path: [hex(8, 4)]), audience: 0b11))
    }
}

@Suite struct PlayerViewTests {
    @Test func foreignUnitsShowOnlyOnVisibleTiles() {
        var state = makeTestState()
        let mine = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        let near = state.addUnit(.warrior, owner: PlayerID(1), at: hex(2, 2))
        let far = state.addUnit(.warrior, owner: PlayerID(1), at: hex(8, 1))
        let view = state.view(for: PlayerID(0))
        let parked = parkedSettler(of: PlayerID(0))
        #expect(view.units.map(\.id) == [parked, mine])
        #expect(view.visibleForeignUnits.map(\.id) == [near])
        #expect(view.visibleUnits.map(\.id) == [parked, mine, near])
        #expect(view.unit(near) != nil && view.unit(far) == nil)
        #expect(view.units(at: hex(8, 1)).isEmpty && view.units(at: hex(2, 2)).map(\.id) == [near])
        #expect(view.isMyPhase && !state.view(for: PlayerID(1)).isMyPhase)
        #expect(view.reachableTiles(for: mine).contains(hex(2, 1)))
        #expect(view.path(for: mine, to: hex(3, 1)) != nil)
        #expect(view.path(for: far, to: hex(3, 1)) == nil && view.reachableTiles(for: far).isEmpty)
    }

    @Test func tilesShowOnlyWhenExplored() {
        let state = makeTestState()
        let view = state.view(for: PlayerID(0))
        #expect(view.tile(at: hex(0, 0)) == nil && view.tileYields(at: hex(0, 0)) == nil && !view.isExplored(hex(0, 0)))
        #expect(view.tile(at: hex(10, 7)) == Tile(terrain: .grassland))
        #expect(view.tileYields(at: hex(10, 7)) == Yields(food: 2))
        #expect(view.isVisible(hex(10, 7)))
    }

    @Test func cityQueries() throws {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2))
        let theirs = addCity(&state, PlayerID(1), at: hex(8, 2))
        let view = state.view(for: PlayerID(0))
        #expect(view.cities.map(\.id) == [id])
        #expect(view.city(theirs) == nil && view.cityYields(theirs) == nil)
        #expect(view.cityYields(id)?.total == Yields(food: 4, production: 4, gold: 3, science: 4, culture: 2))
        #expect(view.turnsToGrow(id) == 6) // 11 Food at +2 (p3f: growth.base 11)
        #expect(view.tileYields(at: hex(2, 2)) == Yields(food: 2, production: 2, science: 1, culture: 1)) // a known city centre
        let income = view.income()
        #expect(income.gold == 3 && income.science == 4 && income.culture == 2)
        #expect(income.upkeep == 0 && income.freeUnits == 3 && income.net == 3)

        let options = view.productionOptions(for: id)
        #expect(!options.contains { $0.item == .building("palace") })
        let warrior = try #require(options.first { $0.item == .unit(.warrior) })
        // The city's founding production (40) covers a Warrior; without it, 40 / 4 = 10 phases.
        #expect(warrior.cost == 40 && warrior.turns == 1 && warrior.buyPrice == 120)
        #expect(warrior.queueProblem == nil && warrior.buyProblem == nil)
        var bare = state
        updateCity(&bare, id) { $0.storedProgress = 0 }
        #expect(bare.view(for: PlayerID(0)).productionOptions(for: id).first { $0.item == .unit(.warrior) }?.turns == 10)
        #expect(options.first { $0.item == .unit(.archer) }?.queueProblem == "needs Archery")
        let settler = try #require(options.first { $0.item == .unit(.settler) })
        #expect(settler.queueProblem == nil && settler.buyProblem == "needs population 2")
        #expect(state.view(for: PlayerID(1)).productionOptions(for: id).isEmpty)
    }

    @Test func researchOptions() {
        var state = makeTestState()
        addCity(&state, PlayerID(0), at: hex(2, 2)) // Science 4
        let options = state.view(for: PlayerID(0)).researchOptions()
        #expect(options.map(\.tech) == state.rules.techs.map(\.id))
        #expect(options[0].available && !options[0].known && options[0].turns == 7 && options[0].unlocks == ["Granary"])
        #expect(!options[3].available && options[3].turns == 17) // Sailing: (25 + 40) / 4
        #expect(options[3].unlocks == ["Galley", "Fishing Boats", "+1 Food on Coast", "+1 Food on Lake", "Embark on Coast and Lake"])
        #expect(options[5].unlocks == ["Plantation", "Farm +1 Food by fresh water"])
        #expect(options[9].turns == 35) // Currency: 25 + 45 + 70
    }

    @Test func unitActions() throws {
        var state = makeTestState()
        let settler = state.addUnit(.settler, owner: PlayerID(0), at: hex(2, 2))
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(6, 6))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        let view = state.view(for: PlayerID(0))
        let settlerActions = view.unitActions(for: settler)
        #expect(settlerActions.first { $0.kind == .foundCity }?.isAvailable == true)
        #expect(!settlerActions.contains { $0.kind == .fortify })
        #expect(view.unitActions(for: builder).first { $0.kind == .buildFarm }?.problem == "tile not in your territory")
        let warriorActions = view.unitActions(for: warrior)
        #expect(warriorActions.map(\.kind) == [.pillage, .fortify, .sleep, .wake, .skip, .cancelOrders, .disband])
        #expect(warriorActions.filter(\.isAvailable).map(\.kind) == [.fortify, .sleep, .skip, .disband])
        try apply(.endTurn, &state)
        #expect(state.view(for: PlayerID(0)).unitActions(for: warrior).allSatisfy { $0.problem == "not your turn" })
        #expect(state.view(for: PlayerID(1)).unitActions(for: warrior).isEmpty)
    }

    /// Settling queries use only what the player knows: unexplored tiles count 0, and a city
    /// the player has not seen does not count (no information leaks).
    @Test func settlingQueriesUseOnlyWhatThePlayerKnows() {
        var state = makeTestState(width: 24, height: 12)
        state.addUnit(.scout, owner: PlayerID(0), at: hex(6, 6))
        let site = hex(6, 6)
        let full = state.view(for: PlayerID(0)).settleScore(at: site)
        #expect(full > 0)
        var partial = state
        for h in [hex(7, 6), hex(6, 7), hex(7, 7)] { partial.players[0].explored[partial.map.index(of: h)!] = false }
        #expect(partial.view(for: PlayerID(0)).settleScore(at: site) < full)
        #expect(state.view(for: PlayerID(0)).settleScore(at: hex(20, 2)) == 0) // unexplored

        // A city three tiles away that player 0 has not seen.
        var hidden = makeTestState(width: 24, height: 12)
        hidden.addUnit(.scout, owner: PlayerID(0), at: hex(1, 6))
        for t in 0..<hidden.map.tileCount { hidden.players[0].explored[t] = true }
        let city = addCity(&hidden, PlayerID(1), at: hex(9, 6))
        #expect(hidden.view(for: PlayerID(0)).canFoundCity(at: site))
        #expect(hidden.view(for: PlayerID(0)).settleScore(at: site) > 0)
        hidden.remember(hidden.city(city)!, by: PlayerID(0))
        #expect(!hidden.view(for: PlayerID(0)).canFoundCity(at: site))
        #expect(hidden.view(for: PlayerID(0)).settleScore(at: site) == 0)
    }
}
