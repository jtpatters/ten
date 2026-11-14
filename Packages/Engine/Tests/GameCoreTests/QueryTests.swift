import Foundation
import Testing
@testable import GameCore

// PlayerView queries for movement, distance and danger (M1 §12.6), what they and the combat
// commands reveal (M1 §8.6, §11), and the audiences of combat events (M1 §12.5).

@Suite struct MovementQueryTests {
    /// Movement points to each tile, counting points left unused at turn ends; zones of control
    /// from visible enemies end the turn (M1 §12.6).
    @Test func movementFieldCountsTurnEndsAndZonesOfControl() throws {
        var state = corridorState()
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(3, 0))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 1))
        let view = state.view(for: PlayerID(0))
        let field = view.movementField(for: scout)
        func cost(_ h: HexCoord) -> Int32 { field[tile(state, h)] }
        #expect(field.count == state.map.tileCount)
        #expect(cost(hex(3, 0)) == 0 && cost(hex(4, 0)) == 3 && cost(hex(2, 0)) == 3)
        #expect(cost(hex(5, 0)) == 6) // enters the zone with a move left: the turn ends there
        #expect(cost(hex(6, 0)) == 12) // 1 point wasted at (5,0)
        #expect(cost(hex(7, 0)) == 21) // 2 more wasted at (6,0)
        #expect(cost(hex(9, 0)) == 27 && cost(hex(10, 0)) == 30)
        #expect(cost(hex(4, 1)) == -1) // a known mountain
        #expect(cost(hex(5, 1)) == -1) // the enemy

        // At peace (no zone of control): plain step counts with turn ends.
        var peace = state
        peace.updateRelation(PlayerID(0), PlayerID(1)) { $0.stance = .peace }
        let free = peace.view(for: PlayerID(0)).movementField(for: scout)
        #expect(free[tile(peace, hex(6, 0))] == 9 && free[tile(peace, hex(7, 0))] == 12 && free[tile(peace, hex(10, 0))] == 21)

        // A limit stops the search; other players' units have no field.
        let near = view.movementField(for: scout, limit: 9)
        #expect(near[tile(state, hex(6, 0))] == -1 && near[tile(state, hex(5, 0))] == 6)
        #expect(view.movementField(for: parkedSettler(of: PlayerID(1))).isEmpty)

        // A unit stopped by a zone of control plans from next turn.
        try apply(.moveUnit(unit: scout, to: hex(5, 0)), &state)
        let stopped = state.view(for: PlayerID(0)).movementField(for: scout)
        #expect(stopped[tile(state, hex(5, 0))] == 0 && stopped[tile(state, hex(6, 0))] == 3)
    }

    /// Steps over land as the player knows it: explored impassable tiles block, unexplored
    /// tiles count as land; units are ignored (M1 §12.6).
    @Test func distanceFieldUsesKnownTerrain() {
        var state = makeTestState()
        state.addUnit(.warrior, owner: PlayerID(0), at: hex(4, 3))
        let mine = state.view(for: PlayerID(0)).distanceField(from: hex(4, 3))
        #expect(mine[tile(state, hex(4, 3))] == 0 && mine[tile(state, hex(3, 3))] == 1)
        #expect(mine[tile(state, hex(5, 3))] == -1) // a mountain it has seen
        #expect(mine[tile(state, hex(6, 3))] == 5) // around the range
        // Player 1 has not seen the mountains.
        let theirs = state.view(for: PlayerID(1)).distanceField(from: hex(4, 3))
        #expect(theirs[tile(state, hex(5, 3))] == 1 && theirs[tile(state, hex(6, 3))] == 2)
        // Several sources, and a limit.
        let two = state.view(for: PlayerID(0)).distanceField(from: [hex(0, 0), hex(11, 7)], limit: 2)
        #expect(two[tile(state, hex(1, 0))] == 1 && two[tile(state, hex(10, 7))] == 1)
        #expect(two[tile(state, hex(3, 0))] == -1)
    }

    /// The power of the visible enemy units able to attack each tile next phase (M1 §12.6).
    @Test func dangerMapSumsVisibleThreats() {
        var state = makeWarState(width: 16, height: 10)
        state.addUnit(.scout, owner: PlayerID(0), at: hex(3, 3))
        let warrior = state.addUnit(.warrior, owner: PlayerID(1), at: hex(6, 3))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(6, 7)) // unseen
        let danger = state.view(for: PlayerID(0)).dangerMap()
        let centre = state.unit(warrior)!.position
        for t in 0..<state.map.tileCount {
            let d = state.map.distance(state.map.coord(at: t), centre)
            #expect(danger[t] == (d <= 2 ? 20 : 0), "tile \(state.map.coord(at: t).offset)")
        }

        // An archer (range 2) reaches a tile further; threats add up.
        let archer = state.addUnit(.archer, owner: PlayerID(1), at: hex(6, 2))
        let more = state.view(for: PlayerID(0)).dangerMap()
        let archerAt = state.unit(archer)!.position
        for t in 0..<state.map.tileCount {
            let h = state.map.coord(at: t)
            let expected = (state.map.distance(h, centre) <= 2 ? 20 : 0) + (state.map.distance(h, archerAt) <= 3 ? 25 : 0)
            #expect(more[t] == Int32(expected), "tile \(h.offset)")
        }
        #expect(more[tile(state, hex(6, 3))] == 45)
    }

    /// Power = (Ranged Strength if any, else Strength) × HP / 100; the garrison is the lowest-id
    /// military unit in a city, for own cities and visible foreign ones (M1 §13).
    @Test func powerAndGarrisons() throws {
        var state = makeWarState(width: 16, height: 10)
        let own = addCity(&state, PlayerID(0), at: hex(3, 3))
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(3, 3))
        #expect(state.view(for: PlayerID(0)).garrison(of: own) == nil) // civilians do not garrison
        let guardian = state.addUnit(.archer, owner: PlayerID(0), at: hex(3, 3))
        state.addUnit(.scout, owner: PlayerID(0), at: hex(4, 4)) // sees (6,3), not (12,7)
        let near = addCity(&state, PlayerID(1), at: hex(6, 3))
        let far = addCity(&state, PlayerID(1), at: hex(12, 7))
        let defender = state.addUnit(.warrior, owner: PlayerID(1), at: hex(6, 3))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(12, 7))
        state.updateUnit(defender) { $0.hp = 50 }
        refreshKnowledge(&state)
        let view = state.view(for: PlayerID(0))
        #expect(view.garrison(of: own)?.id == guardian && guardian != builder)
        #expect(view.garrison(of: near)?.id == defender)
        #expect(view.garrison(of: far) == nil) // not seen
        #expect(view.power(of: state.unit(guardian)!) == 25 && view.power(of: state.unit(defender)!) == 10)
        #expect(view.power(of: .scout, hp: 99) == 9)
        let sighting = try #require(view.sightings(of: PlayerID(1)).first)
        #expect(sighting.id == defender && view.power(of: sighting) == 10)
    }
}

@Suite struct CombatKnowledgeTests {
    /// Attacking a hidden enemy is refused exactly like attacking an empty tile (M1 §8.6).
    @Test func hiddenTargetsAreRefusedLikeEmptyTiles() throws {
        var state = makeWarState(width: 16, height: 10)
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(2, 4))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(2, 7))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 4)) // 3 away: unseen
        addCity(&state, PlayerID(1), at: hex(5, 7))
        #expect(!state.players[0].visible[tile(state, hex(5, 4))] && !state.players[0].visible[tile(state, hex(5, 7))])
        func refusal(_ command: Command) -> CommandError? {
            var copy = state
            do { try apply(command, &copy) } catch { return error as? CommandError }
            return nil
        }
        let empty = refusal(.attack(unit: archer, target: hex(5, 2)))
        #expect(empty == .rejected(reason: "no enemy there"))
        #expect(refusal(.attack(unit: archer, target: hex(5, 4))) == empty)
        #expect(refusal(.attack(unit: warrior, target: hex(5, 7))) == empty)
        #expect(refusal(.attack(unit: warrior, target: hex(5, 6))) == empty)
        let view = state.view(for: PlayerID(0))
        #expect(view.attackOptions(for: archer).isEmpty && view.attackOptions(for: warrior).isEmpty)
        #expect(view.combatPreview(attacker: .unit(archer), target: hex(5, 4), from: hex(3, 4)) == nil)
        #expect(view.dangerMap().allSatisfy { $0 == 0 })
    }

    /// Every query works from what the player sees: with player 0's view fogged, nothing
    /// reveals the enemy next to its unit (M1 §8.6, §11).
    @Test func queriesIgnoreWhatThePlayerDoesNotSee() throws {
        var state = makeWarState()
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        let city = addCity(&state, PlayerID(1), at: hex(4, 3))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 3))
        let open = state.view(for: PlayerID(0))
        #expect(open.attackOptions(for: w).count == 2 && open.garrison(of: city) != nil)
        #expect(open.movementField(for: w)[tile(state, hex(4, 1))] == -1)

        var fogged = state
        fogged.players[0].visible = TileBitSet(count: fogged.map.tileCount)
        let view = fogged.view(for: PlayerID(0))
        #expect(view.attackOptions(for: w).isEmpty)
        #expect(view.combatPreview(attacker: .unit(w), target: hex(4, 1), from: hex(3, 1)) == nil)
        #expect(view.dangerMap().allSatisfy { $0 == 0 })
        #expect(view.garrison(of: city) == nil)
        #expect(view.movementField(for: w)[tile(fogged, hex(4, 1))] == 3) // as if empty, and no zone of control
        #expect(throws: CommandError.rejected(reason: "no enemy there")) { try apply(.attack(unit: w, target: hex(4, 1)), &fogged) }
    }

    /// The preview counts support, flanking and garrisons only on tiles the player sees.
    @Test func previewsUseOnlyVisibleUnits() throws {
        var state = makeWarState(width: 16, height: 10)
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(2, 4))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 4))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 4)) // support, but 3 from the archer
        #expect(!state.players[0].visible[tile(state, hex(5, 4))])
        // A melee attack from (3,4) would see the supporter once there; previewed from here it
        // does not count.
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 4))
        let preview = try #require(state.view(for: PlayerID(0)).combatPreview(attacker: .unit(warrior), target: hex(4, 4), from: hex(3, 4)))
        #expect(preview.defenderStrength.modifiers.isEmpty && preview.from == hex(3, 4))
        _ = archer
    }
}

@Suite struct CombatAudienceTests {
    /// Combat, kill, capture and raze events go to the players who see a tile they name before
    /// or after the command (M1 §12.5).
    @Test func combatEventsGoToTheirWitnesses() throws {
        var state = makeWarState(width: 24, height: 12, players: 3)
        addCity(&state, PlayerID(0), at: hex(2, 2))
        addCity(&state, PlayerID(1), at: hex(20, 2))
        let city = addCity(&state, PlayerID(1), at: hex(10, 6))
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 6))
        let d = state.addUnit(.warrior, owner: PlayerID(1), at: hex(9, 7))
        state.updateUnit(d) { $0.hp = 5 }
        refreshKnowledge(&state)

        // Player 2 sees nothing of it.
        var records = try apply(.attack(unit: a, target: hex(9, 7)), &state)
        #expect(records.map(\.audience) == [0b011, 0b011, 0b011, 0b001]) // combat, killed, moved in, Insight (owner)
        #expect(events(records)[1] == .unitKilled(unit: d, type: .warrior, owner: PlayerID(1), at: hex(9, 7)))

        // A watcher of player 2 next to the city sees the capture.
        state.addUnit(.scout, owner: PlayerID(2), at: hex(12, 6))
        try nextTurn(&state)
        updateCity(&state, city) { $0.hp = 0 }
        records = try apply(.attack(unit: a, target: hex(10, 6)), &state)
        let capture = try #require(records.first { if case .cityCaptured = $0.event { true } else { false } })
        #expect(capture.audience == 0b111)
        // Razing: player 1 no longer sees the tile, player 2 does.
        records = try apply(.razeCity(city: city), &state)
        #expect(records.count == 1 && records[0].audience == 0b101)
        expectSound(state)
    }
}

/// The phases `productionOptions` gives for adding an item (M1 §5, §12.6): a new entry starts
/// from nothing, and a queued building reports its queue row.
@Suite struct ProductionOptionTests {
    func option(_ item: ProductionItem, _ state: GameState, _ city: CityID) throws -> ProductionOption {
        try #require(state.view(for: PlayerID(0)).productionOptions(for: city).first { $0.item == item })
    }

    /// Another Builder, with one nearly built at the head of the queue: the new one needs its
    /// whole cost (it read "4 turns" with the queued Builder at 46/50, T6 on the iPad).
    @Test func aRepeatUnitStartsFromNothing() throws {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2)) // Production 4
        let builder = state.rules.unit(.builder).cost
        try apply(.setQueue(city: id, items: [.unit(.builder)]), &state)
        updateCity(&state, id) { $0.queue[0].progress = builder - 4 }
        let view = state.view(for: PlayerID(0))
        #expect(view.queueStatus(of: id).map(\.turns) == [1])
        #expect(try option(.unit(.builder), state, id).turns == (builder + 3) / 4)
    }

    /// A building queued behind another item reports its queue row (both read the same);
    /// stored progress goes to the entry that takes the production, not to a new one.
    @Test func aQueuedBuildingReportsItsRow() throws {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2)) // Production 4
        let warrior = state.rules.unit(.warrior).cost, monument = state.rules.building("monument")!.cost
        try apply(.setQueue(city: id, items: [.unit(.warrior), .building("monument")]), &state)
        updateCity(&state, id) { $0.storedProgress = 8 }
        let rows = state.view(for: PlayerID(0)).queueStatus(of: id)
        let first = (warrior - 8 + 3) / 4
        #expect(rows.map(\.turns) == [first, first + (monument + 3) / 4])
        let queued = try option(.building("monument"), state, id)
        #expect(queued.queueProblem == "already queued" && queued.turns == rows[1].turns)
        #expect(try option(.unit(.warrior), state, id).turns == (warrior + 3) / 4)
    }

    /// With nothing queued that can take the production (an empty queue, or only a full Settler
    /// waiting for population), a new entry gets the stored progress. p3f: a Settler that still
    /// fills while it waits takes it (M1 §5), so a new entry then starts from nothing.
    @Test func storedProgressGoesToTheNextEntry() throws {
        var state = makeTestState()
        let id = addCity(&state, PlayerID(0), at: hex(2, 2)) // Production 4, population 1
        let warrior = state.rules.unit(.warrior).cost, settler = state.rules.unit(.settler).cost
        updateCity(&state, id) { $0.storedProgress = 8 }
        #expect(try option(.unit(.warrior), state, id).turns == (warrior - 8 + 3) / 4)
        try apply(.setQueue(city: id, items: [.unit(.settler)]), &state)
        #expect(try option(.unit(.warrior), state, id).turns == (warrior + 3) / 4)
        updateCity(&state, id) { $0.queue[0].progress = settler }
        #expect(state.view(for: PlayerID(0)).queueStatus(of: id).first?.receivesProduction == false)
        #expect(try option(.unit(.warrior), state, id).turns == (warrior - 8 + 3) / 4)
    }
}
