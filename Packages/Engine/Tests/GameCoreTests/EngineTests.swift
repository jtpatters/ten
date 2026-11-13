import Foundation
import Testing
@testable import GameCore

@Suite struct PathfinderTests {
    @Test func straightLineOneTurn() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        let path = try #require(Pathfinder.findPath(for: state.unit(id)!, to: hex(3, 1), in: state))
        #expect(path.steps.count == 2)
        #expect(path.turns == 1)
    }

    @Test func multiTurnPathCountsTurns() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        // 6 tiles of flat grass with 2 moves per turn = 3 turns.
        let path = try #require(Pathfinder.findPath(for: state.unit(id)!, to: hex(6, 0), in: state))
        #expect(path.steps.count == 6)
        #expect(path.turns == 3)
        #expect(path.steps.map(\.turn) == [1, 1, 2, 2, 3, 3])
    }

    @Test func aUnitWithoutMovesStartsNextTurn() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        state.updateUnit(id) { $0.movesLeft = 0 }
        let path = try #require(Pathfinder.findPath(for: state.unit(id)!, to: hex(2, 0), in: state))
        #expect(path.steps.map(\.turn) == [2, 2])
    }

    /// Paths use the moving player's knowledge (M1 §8.6): explored obstacles are avoided, an
    /// unexplored tile counts as passable land with cost 1.
    @Test func routesAroundKnownMountainsAndPlansThroughUnexploredTiles() throws {
        var state = makeTestState()
        let id = state.addUnit(.scout, owner: PlayerID(0), at: hex(3, 3))
        let path = try #require(Pathfinder.findPath(for: state.unit(id)!, to: hex(7, 3), in: state))
        for step in path.steps {
            #expect(state.rules.isPassable(state.map[step.hex]))
        }
        // The lake at (8,6) is unexplored, so it looks like land...
        let lake = state.map.index(of: hex(8, 6))!
        #expect(!state.players[0].explored[lake])
        #expect(Pathfinder.findPath(for: state.unit(id)!, to: hex(8, 6), in: state) != nil)
        // ...until it is explored.
        state.players[0].explored[lake] = true
        #expect(Pathfinder.findPath(for: state.unit(id)!, to: hex(8, 6), in: state) == nil)
    }

    @Test func roughTerrainCanBeEnteredWithPartialMoves() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(2, 6))
        state.updateUnit(id) { $0.movesLeft = 1 }
        let path = try #require(Pathfinder.findPath(for: state.unit(id)!, to: hex(3, 6), in: state))
        #expect(path.turns == 1) // forest costs 2, but any remaining move lets you enter
    }

    @Test func riverCrossingCostsAnExtraMove() throws {
        var map = makeTestMap()
        let a = map.index(of: hex(1, 1))!, b = map.index(of: hex(2, 1))!
        map[index: a].riverEdges |= 1 << HexDirection.east.rawValue
        map[index: b].riverEdges |= 1 << HexDirection.west.rawValue
        var state = makeTestState(map: map)
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        #expect(state.moveCost(from: a, to: b, .east) == 2)
        let path = try #require(Pathfinder.findPath(for: state.unit(id)!, to: hex(3, 1), in: state))
        #expect(path.steps.map(\.turn) == [1, 2])
    }

    @Test func visibleForeignUnitsBlock() {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(2, 1))
        #expect(Pathfinder.findPath(for: state.unit(id)!, to: hex(2, 1), in: state) == nil)
        // Not through it either: the way round is longer.
        let path = Pathfinder.findPath(for: state.unit(id)!, to: hex(3, 1), in: state)
        #expect(path?.steps.contains { $0.hex == hex(2, 1) } == false)
    }

    /// Hidden units are ignored, including at the goal (no information leaks, M1 §8.6).
    @Test func hiddenForeignUnitsAreIgnored() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 0))
        #expect(!state.players[0].visible[state.map.index(of: hex(4, 0))!])
        #expect(Pathfinder.findPath(for: state.unit(id)!, to: hex(4, 0), in: state) != nil)
    }

    @Test func passesThroughOwnUnitsButDoesNotStopOnThem() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        state.addUnit(.warrior, owner: PlayerID(0), at: hex(2, 1))
        #expect(Pathfinder.findPath(for: state.unit(id)!, to: hex(2, 1), in: state) == nil)
        let path = try #require(Pathfinder.findPath(for: state.unit(id)!, to: hex(3, 1), in: state))
        #expect(path.steps.map(\.hex) == [hex(2, 1), hex(3, 1)])
        // A civilian may share the tile.
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(1, 2))
        #expect(Pathfinder.findPath(for: state.unit(builder)!, to: hex(2, 1), in: state) != nil)
    }

    /// A turn may not end on a tile the unit may only pass through: it waits a turn instead,
    /// and the move this phase stops on the last tile it may stop on, keeping the order.
    @Test func turnsNeverEndOnPassThroughTiles() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        for blocker in [hex(2, 0), hex(1, 1), hex(2, 1)] { state.addUnit(.warrior, owner: PlayerID(0), at: blocker) }
        let path = try #require(Pathfinder.findPath(for: state.unit(id)!, to: hex(3, 0), in: state))
        #expect(path.steps.map(\.hex) == [hex(1, 0), hex(2, 0), hex(3, 0)])
        #expect(path.steps.map(\.turn) == [1, 2, 2])
        try apply(.moveUnit(unit: id, to: hex(3, 0)), &state)
        #expect(state.unit(id)!.position == hex(1, 0))
        #expect(state.unit(id)!.movesLeft == 1)
        #expect(state.unit(id)!.destination == hex(3, 0))
        try nextTurn(&state)
        #expect(state.unit(id)!.position == hex(3, 0))
    }

    @Test func reachableTilesThisPhase() {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        let reachable = Pathfinder.reachableTiles(for: state.unit(id)!, in: state)
        #expect(reachable.count == state.map.coords(within: 2, of: hex(1, 1)).count - 1)
        #expect(!reachable.contains(hex(1, 1)))
        state.updateUnit(id) { $0.movesLeft = 0 }
        #expect(Pathfinder.reachableTiles(for: state.unit(id)!, in: state).isEmpty)
    }
}

@Suite struct EngineTests {
    @Test func moveConsumesMovesAndStoresOrders() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        let records = try GameEngine.apply(.moveUnit(unit: id, to: hex(6, 0)), by: PlayerID(0), to: &state)
        let unit = try #require(state.unit(id))
        #expect(unit.position == hex(2, 0))
        #expect(unit.movesLeft == 0)
        #expect(unit.destination == hex(6, 0))
        #expect(events(records) == [.unitMoved(unit: id, from: hex(0, 0), path: [hex(1, 0), hex(2, 0)])])

        // Standing orders continue at the owner's next phase start (M1 §3 step 5).
        try endPhases(until: PlayerID(1), &state)
        #expect(state.unit(id)!.position == hex(2, 0))
        try nextTurn(&state)
        #expect(state.unit(id)!.position == hex(4, 0))
        try nextTurn(&state)
        #expect(state.unit(id)!.position == hex(6, 0))
        #expect(state.unit(id)!.destination == nil)
        #expect(state.turn == 3)
    }

    @Test func cancelOrdersClearsTheDestination() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        try apply(.moveUnit(unit: id, to: hex(6, 0)), &state)
        try apply(.cancelOrders(unit: id), &state)
        #expect(state.unit(id)!.destination == nil)
        try nextTurn(&state)
        #expect(state.unit(id)!.position == hex(2, 0))
    }

    /// Another player's unit is `notYourUnit` when seen or remembered, and `unknownUnit` (like
    /// an id that does not exist) when hidden, so ids cannot be probed (core-3 audit, M1 §11).
    @Test func cannotMoveOthersUnits() {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(1), at: hex(0, 0))
        #expect(throws: CommandError.unknownUnit(id)) {
            try GameEngine.apply(.moveUnit(unit: id, to: hex(1, 0)), by: PlayerID(0), to: &state)
        }
        #expect(throws: CommandError.unknownUnit(UnitID(99))) {
            try GameEngine.apply(.moveUnit(unit: UnitID(99), to: hex(1, 0)), by: PlayerID(0), to: &state)
        }
        state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 1))
        #expect(state.players[0].visible[tile(state, hex(0, 0))])
        #expect(throws: CommandError.notYourUnit(id)) {
            try GameEngine.apply(.moveUnit(unit: id, to: hex(1, 0)), by: PlayerID(0), to: &state)
        }
    }

    @Test func unreachableTargetsAreRejected() {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(4, 3))
        #expect(throws: CommandError.noPath) {
            try GameEngine.apply(.moveUnit(unit: id, to: hex(5, 3)), by: PlayerID(0), to: &state) // mountains
        }
        #expect(state.unit(id)!.position == hex(4, 3))
    }

    @Test func stackingRules() {
        var state = makeTestState()
        let tile = hex(1, 1)
        state.addUnit(.warrior, owner: PlayerID(0), at: tile)
        #expect(state.canEnd(.settler, owner: PlayerID(0), at: tile))
        #expect(!state.canEnd(.scout, owner: PlayerID(0), at: tile))
        #expect(!state.canEnd(.settler, owner: PlayerID(1), at: tile))
        #expect(!state.canEnd(.warrior, owner: PlayerID(0), at: hex(5, 3))) // mountains
    }

    @Test func explorationGrowsWithMovement() throws {
        var state = makeTestState(width: 30, height: 8)
        let id = state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 4))
        let before = state.players[0].explored.setCount
        try GameEngine.apply(.moveUnit(unit: id, to: hex(4, 4)), by: PlayerID(0), to: &state)
        #expect(state.players[0].explored.setCount > before)
    }

    /// Moves execute step by step against the real world (M1 §8.6): a tile that turns out to be
    /// impassable or occupied stops the move, clears the order and reports `moveInterrupted`.
    @Test func movesStopAtTilesThatTurnOutBlocked() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(4, 3))
        // Forget what player 0 knows: the mountain east of the warrior looks like land.
        state.players[0].explored = TileBitSet(count: state.map.tileCount)
        state.players[0].visible = TileBitSet(count: state.map.tileCount)
        let records = try apply(.moveUnit(unit: id, to: hex(6, 3)), &state)
        #expect(state.unit(id)!.position == hex(4, 3))
        #expect(state.unit(id)!.destination == nil)
        #expect(events(records) == [.moveInterrupted(unit: id, at: hex(4, 3))])

        // A hidden foreign unit on the way.
        var other = makeTestState()
        let mover = other.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        other.addUnit(.warrior, owner: PlayerID(1), at: hex(2, 0))
        other.players[0].visible = TileBitSet(count: other.map.tileCount)
        let stopped = try apply(.moveUnit(unit: mover, to: hex(3, 0)), &other)
        #expect(other.unit(mover)!.position == hex(1, 0))
        #expect(other.unit(mover)!.destination == nil)
        #expect(events(stopped).contains(.moveInterrupted(unit: mover, at: hex(1, 0))))
    }

    /// Only the current player may issue commands (M1 §3).
    @Test func onlyTheCurrentPlayerMayAct() throws {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(1), at: hex(0, 0))
        #expect(throws: CommandError.notYourTurn) {
            try GameEngine.apply(.moveUnit(unit: id, to: hex(1, 0)), by: PlayerID(1), to: &state)
        }
        #expect(throws: CommandError.notYourTurn) {
            try GameEngine.apply(.endTurn, by: PlayerID(1), to: &state)
        }
        try GameEngine.apply(.endTurn, by: PlayerID(0), to: &state)
        try GameEngine.apply(.moveUnit(unit: id, to: hex(1, 0)), by: PlayerID(1), to: &state)
        #expect(state.unit(id)!.position == hex(1, 0))
    }

    /// Every M1 command has its rules: none is refused as not implemented.
    @Test func everyCommandIsImplemented() {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        let city = addCity(&state, PlayerID(0), at: hex(2, 2))
        for command in [Command.attack(unit: id, target: hex(1, 0)), .cityAttack(city: city, target: hex(1, 0)),
                        .declareWar(on: PlayerID(1)), .proposePeace(to: PlayerID(1)),
                        .respondToPeace(from: PlayerID(1), accept: true), .razeCity(city: city)] {
            var copy = state
            #expect(throws: CommandError.self) { try GameEngine.apply(command, by: PlayerID(0), to: &copy) }
            do {
                try GameEngine.apply(command, by: PlayerID(0), to: &copy)
            } catch {
                #expect(error != .notImplemented, "\(command)")
            }
        }
    }

    /// A rejected command leaves the state unchanged.
    @Test func rejectedCommandsChangeNothing() {
        var state = makeTestState()
        let id = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        let before = state
        for command in [Command.moveUnit(unit: id, to: hex(0, 0)), .foundCity(unit: id), .fortify(unit: parkedSettler(of: PlayerID(0))),
                        .buildImprovement(unit: id, improvement: .farm), .setResearch(tech: "nothing"),
                        .setQueue(city: CityID(7), items: []), .wake(unit: id),
                        .attack(unit: id, target: hex(1, 0)), .cityAttack(city: CityID(7), target: hex(1, 0)),
                        .declareWar(on: PlayerID(1)), .proposePeace(to: PlayerID(1)),
                        .respondToPeace(from: PlayerID(1), accept: false), .razeCity(city: CityID(7))] {
            #expect(throws: CommandError.self) { try GameEngine.apply(command, by: PlayerID(0), to: &state) }
        }
        #expect(state == before)
    }

    /// `randomMoves` plans moves for the current player only; `moveAllUnchecked` moves every
    /// player's units whoever's phase it is (the App's stress button).
    @Test func debugToolsMoveTheRightUnits() {
        var state = makeTestState(width: 24, height: 12)
        DebugTools.spawnUnits(count: 12, seed: 3, in: &state)
        #expect(state.units.contains { $0.owner == PlayerID(1) && $0.type == .warrior })
        var rng = SplitMix64(seed: 1)
        let planned = DebugTools.randomMoves(in: state, rng: &rng)
        #expect(!planned.isEmpty && planned.allSatisfy { $0.0 == state.currentPlayer })
        let records = DebugTools.moveAllUnchecked(in: &state, rng: &rng)
        let movers = records.compactMap { record -> PlayerID? in
            if case let .unitMoved(id, _, _) = record.event { return state.unit(id)?.owner }
            return nil
        }
        #expect(movers.contains(PlayerID(0)) && movers.contains(PlayerID(1)))
        #expect(state.currentPlayer == PlayerID(0))
        expectSound(state)
    }

    /// The Developer menu's Spawn Units after an elimination gives units only to living
    /// players, so the state stays sound and its saves are not refused (verify-lifecycle's
    /// spawnAfterElimination; save-invariants-1).
    @Test func spawnedUnitsGoOnlyToLivingPlayers() {
        var state = makeTestState(width: 24, height: 12, players: 3)
        var fx = Effects()
        state.eliminate(PlayerID(1), &fx)
        state.updateKnowledge(&fx)
        expectSound(state)
        DebugTools.spawnUnits(count: 60, seed: 3, in: &state)
        #expect(!state.units.contains { $0.owner == PlayerID(1) })
        #expect(state.units.contains { $0.owner == PlayerID(0) && $0.type == .warrior })
        #expect(state.units.contains { $0.owner == PlayerID(2) && $0.type == .warrior })
        expectSound(state)
    }

    @Test func replayIsDeterministic() throws {
        func run() throws -> (hash: UInt64, cities: Int) {
            var state = makeTestState(width: 30, height: 20, players: 3)
            DebugTools.spawnUnits(count: 12, seed: 5, in: &state)
            var rng = SplitMix64(seed: 77)
            for _ in 0..<30 * state.players.count {
                for command in DebugTools.scriptedCommands(in: state, rng: &rng) {
                    _ = try? apply(command, &state)
                }
                try apply(.endTurn, &state)
            }
            expectSound(state)
            return (state.stateHash(), state.cities.count)
        }
        let first = try run()
        #expect(first.cities > 0)
        #expect(try run() == first)
    }

    @Test func saveRoundTripPreservesHash() throws {
        var state = makeTestState(width: 24, height: 16)
        DebugTools.spawnUnits(count: 10, seed: 3, in: &state)
        var rng = SplitMix64(seed: 9)
        for _ in 0..<20 {
            for command in DebugTools.scriptedCommands(in: state, rng: &rng) { _ = try? apply(command, &state) }
            try apply(.endTurn, &state)
        }
        #expect(!state.cities.isEmpty)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(GameState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.stateHash() == state.stateHash())
    }
}
