import Testing
import GameCore
import MapGen

/// The GameCore and MapGen APIs M1 freezes (docs/M1.md §12.3): the renderer, its tests, the App
/// and HeadlessSim use them while M1 Core rewrites the engine behind them. Each is called or
/// referenced with its labels and types pinned, so removing or changing one breaks this build.
@Suite struct FrozenAPITests {
    @Test func frozenAPIsKeepTheirShape() throws {
        // MapGen: MapSize, MapGenSettings(size:seed:), MapGenerator.generate, GeneratedMap.
        let sizes: [MapSize] = MapSize.allCases
        #expect(sizes.count == 4)
        let size = try #require(MapSize(rawValue: "duel"))
        let _: String = size.rawValue
        let _: String = size.displayName
        let dimensions: (width: Int, height: Int) = size.dimensions
        let _: Int = size.defaultPlayers
        let generated: GeneratedMap = MapGenerator.generate(MapGenSettings(size: size, seed: 7))
        let starts: [HexCoord] = generated.startPositions

        // GameState: newGame (rules, civs and placeTribalVillages gain defaults), seed, turn, map,
        // settable players.
        var state: GameState = GameState.newGame(seed: 7, map: generated.map, startPositions: starts, humanPlayers: [0])
        let _: GameState = GameState.newGame(seed: 7, map: generated.map, startPositions: starts, humanPlayers: [0], placeTribalVillages: false)
        let _: UInt64 = state.seed
        let _: Int = state.turn
        let map: HexMap = state.map
        #expect(map.width == dimensions.width && map.height == dimensions.height)
        let player: Player = state.players[0]
        let _: PlayerID = player.id
        state.players[0].explored = TileBitSet(count: map.tileCount)
        state.players[0].explored[0] = true

        // TileBitSet(count:), its subscript setter and setCount.
        var bits = TileBitSet(count: map.tileCount)
        bits[1] = true
        #expect(bits.setCount == 1 && state.players[0].explored.setCount == 1)

        // HexMap.
        let _: Int = map.tileCount
        let _: Bool = map.wrapsX
        let _: [Tile] = map.tiles
        let _: [HexCoord] = map.allCoords
        let first: HexCoord = map.coord(at: 0)
        let _: Int? = map.index(of: first)
        let _: HexCoord? = map.normalize(first)
        let _: Tile = map[first]
        let _: Tile = map[index: 0]
        let _: Tile? = map.tile(at: first)
        let _: [HexCoord] = map.neighbors(of: first)
        let _: Int = map.distance(first, first)
        let _: [HexCoord] = map.coords(within: 1, of: first)

        // HexCoord, HexDirection (order), OffsetCoord.
        let hex = HexCoord(q: 2, r: 3)
        let _: Int = hex.q + hex.r + hex.s + hex.distance(to: first)
        let _: HexCoord = hex.neighbor(.east)
        let offset: OffsetCoord = hex.offset
        #expect(OffsetCoord(col: offset.col, row: offset.row).hex == hex)
        #expect(HexDirection.allCases == [.east, .southEast, .southWest, .west, .northWest, .northEast])
        #expect(HexDirection.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5])

        // Tile.init(terrain:elevation:feature:riverEdges:), landMovementCost, isLand,
        // Terrain.isWater, and the UInt8 raw values and order of Terrain, Elevation, Feature.
        let tile = Tile(terrain: .grassland, elevation: .hills, feature: .forest, riverEdges: 0b11)
        #expect(tile.landMovementCost == 3 && tile.isLand && Terrain.coast.isWater)
        let _: UInt8 = Terrain.grassland.rawValue
        #expect(Terrain.allCases == [.grassland, .plains, .desert, .tundra, .snow, .coast, .ocean, .lake])
        #expect(Terrain.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 6, 7])
        let _: UInt8 = Elevation.flat.rawValue
        #expect(Elevation.allCases == [.flat, .hills, .mountains])
        #expect(Elevation.allCases.map(\.rawValue) == [0, 1, 2])
        let _: UInt8 = Feature.none.rawValue
        #expect(Feature.allCases == [.none, .forest, .jungle, .marsh, .floodplain, .oasis, .reef, .ice])
        #expect(Feature.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 6, 7])

        // UnitType (CaseIterable, isCivilian, displayName); UnitID and PlayerID.
        #expect(UnitType.allCases == [.settler, .builder, .scout, .warrior, .archer, .spearman, .horseman, .heavyChariot, .swordsman,
                                  .catapult, .manAtArms, .crossbowman, .pikeman, .knight, .trebuchet, .galley, .quadrireme,
                                  .cog, .dromon, .trader])
        #expect(UnitType.allCases.filter(\.isCivilian) == [.settler, .builder, .trader])
        let _: String = UnitType.archer.displayName
        let unitID = UnitID(3), playerID = PlayerID(1)
        let _: Int = unitID.rawValue + playerID.rawValue
        #expect(UnitID(1) < unitID && PlayerID(0) < playerID)

        // Units: addUnit(_:owner:at:), units, unit(_:), units(at:), units(of:), canEnd.
        let units: [GameCore.Unit] = state.units(of: PlayerID(0))
        let warrior = try #require(units.first { !$0.type.isCivilian })
        let spot = try #require(map.neighbors(of: warrior.position).first {
            state.canEnd(.warrior, owner: PlayerID(0), at: $0, ignoring: nil) && state.units(at: $0).isEmpty
        })
        let added: UnitID = state.addUnit(.warrior, owner: PlayerID(0), at: spot)
        let all: [GameCore.Unit] = state.units
        #expect(all.contains { $0.id == added })
        let unit: GameCore.Unit = try #require(state.unit(added))
        #expect(state.units(at: spot).map(\.id) == [added])
        let _: UnitID = unit.id
        let _: PlayerID = unit.owner
        let _: UnitType = unit.type
        let _: HexCoord = unit.position
        let _: Int = unit.movesLeft
        let _: HexCoord? = unit.destination
        let _: Int = unit.hp

        // Visibility and hashing.
        let _: TileBitSet = state.visibleTiles(for: PlayerID(0))
        let _: UInt64 = state.stateHash()

        // Paths: Pathfinder.findPath(for:to:in:), Path, PathStep.
        let target = map.coords(within: 2, of: spot).first {
            $0 != spot && state.canEnd(.warrior, owner: PlayerID(0), at: $0) && state.units(at: $0).isEmpty
        }
        if let target, let path: Path = Pathfinder.findPath(for: unit, to: target, in: state) {
            let steps: [PathStep] = path.steps
            let _: HexCoord = steps[0].hex
            let _: Int = steps[0].turn
            #expect(path.destination == target)
            let _: Int = path.turns
        }

        // GameEngine.apply(_:by:to:) with moveUnit, cancelOrders and endTurn, returning event
        // records; GameEvent.unitMoved(unit:from:path:).
        let moved: [EventRecord] = (try? GameEngine.apply(.moveUnit(unit: added, to: target ?? spot), by: PlayerID(0), to: &state)) ?? []
        for record in moved {
            if case let .unitMoved(unit: id, from: from, path: path) = record.event {
                #expect(id == added && from == spot && !path.isEmpty)
            }
        }
        let _: GameEvent = .unitMoved(unit: added, from: spot, path: [warrior.position])
        let _: [EventRecord] = try GameEngine.apply(.cancelOrders(unit: added), by: PlayerID(0), to: &state)
        let _: [EventRecord] = try GameEngine.apply(.endTurn, by: PlayerID(0), to: &state)

        // DebugTools and SplitMix64(seed:salts:).
        DebugTools.spawnUnits(count: 4, seed: 1, in: &state)
        var rng = SplitMix64(seed: 7, salts: 1, 2)
        let _: [(PlayerID, Command)] = DebugTools.randomMoves(in: state, rng: &rng)
    }
}
