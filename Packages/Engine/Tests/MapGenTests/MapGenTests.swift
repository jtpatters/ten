import Testing
import GameCore
@testable import MapGen

@Suite struct MapGenTests {
    @Test(arguments: MapSize.allCases)
    func generatesValidMap(size: MapSize) {
        let result = MapGenerator.generate(MapGenSettings(size: size, seed: 2026))
        let map = result.map
        #expect(map.width == size.dimensions.width)
        #expect(map.height == size.dimensions.height)

        let landShare = Double(map.tiles.filter(\.isLand).count) / Double(map.tileCount)
        #expect(landShare > 0.30 && landShare < 0.45)

        #expect(result.startPositions.count == size.defaultPlayers)
        for start in result.startPositions {
            #expect(map[start].landMovementCost != nil)
            #expect(Ruleset.standard.feature(map[start].feature).allowsCity)
        }
        // Starts are spread out (M1 §2: at least 6 apart unless the retries ran out).
        for (i, a) in result.startPositions.enumerated() {
            for b in result.startPositions[(i + 1)...] {
                #expect(map.distance(a, b) >= 6)
            }
        }
        // All on the largest passable landmass (no embarking in M1).
        let landmass = Set(MapGenerator.largestLandmass(map))
        #expect(result.startPositions.allSatisfy { landmass.contains(map.index(of: $0)!) })
    }

    /// Every start is on one landmass for many seeds; when a seed cannot fit the starts, the
    /// terrain is regenerated with derived seeds, then the distance is lowered (M1 §2).
    @Test(arguments: [MapSize.duel, .small, .standard])
    func startsShareOneLandmass(size: MapSize) {
        for seed: UInt64 in 1...12 {
            let result = MapGenerator.generate(MapGenSettings(size: size, seed: seed))
            let landmass = Set(MapGenerator.largestLandmass(result.map))
            #expect(result.startPositions.count == size.defaultPlayers, "seed \(seed)")
            #expect(result.startPositions.allSatisfy { landmass.contains(result.map.index(of: $0)!) }, "seed \(seed)")
            for (i, a) in result.startPositions.enumerated() {
                for b in result.startPositions[(i + 1)...] {
                    #expect(result.map.distance(a, b) >= MapGenerator.lowestStartDistance, "seed \(seed)")
                }
            }
        }
    }

    @Test func crowdedMapsRetryThenLowerTheDistance() {
        // Eight players on a Duel map with little land: no attempt fits them 6 apart.
        let settings = MapGenSettings(size: .duel, seed: 5, playerCount: 8, landFraction: 0.1)
        let result = MapGenerator.generate(settings)
        let again = MapGenerator.generate(settings)
        #expect(result.map == again.map && result.startPositions == again.startPositions)
        #expect(result.startPositions.count == 8)
        let landmass = Set(MapGenerator.largestLandmass(result.map))
        #expect(result.startPositions.allSatisfy { landmass.contains(result.map.index(of: $0)!) })
        let closest = result.startPositions.indices.flatMap { i in
            result.startPositions.indices.filter { $0 > i }.map { result.map.distance(result.startPositions[i], result.startPositions[$0]) }
        }.min()!
        #expect(closest < MapGenerator.startDistance && closest >= MapGenerator.lowestStartDistance)
        // Derived seeds differ per attempt and are reproducible.
        #expect(MapGenerator.terrainSeed(5, attempt: 1) != MapGenerator.terrainSeed(5, attempt: 2))
        #expect(MapGenerator.terrainSeed(5, attempt: 1) == MapGenerator.terrainSeed(5, attempt: 1))
    }

    @Test func sameSeedSameMap() {
        let a = MapGenerator.generate(MapGenSettings(size: .standard, seed: 7))
        let b = MapGenerator.generate(MapGenSettings(size: .standard, seed: 7))
        #expect(a.map == b.map)
        #expect(a.startPositions == b.startPositions)
    }

    @Test func differentSeedDifferentMap() {
        let a = MapGenerator.generate(MapGenSettings(size: .small, seed: 7))
        let b = MapGenerator.generate(MapGenSettings(size: .small, seed: 8))
        #expect(a.map != b.map)
    }

    @Test func noLandRightNextToPolesMostly() {
        let map = MapGenerator.generate(MapGenSettings(size: .standard, seed: 11)).map
        let edgeRows = [0, map.height - 1]
        let edgeLand = edgeRows.flatMap { row in (0..<map.width).map { OffsetCoord(col: $0, row: row).hex } }
            .filter { map[$0].isLand }.count
        #expect(edgeLand < map.width / 4)
    }

    @Test func noiseWrapsSeamlessly() {
        let noise = ValueNoise(seed: 42)
        for y in stride(from: 0.0, to: 3.0, by: 0.37) {
            let left = noise.fbm(x: 0, y: y, octaves: 4, period: 4)
            let right = noise.fbm(x: 4, y: y, octaves: 4, period: 4)
            #expect(abs(left - right) < 1e-12)
        }
    }

    @Test func newGamePlacesStartingUnits() {
        let result = MapGenerator.generate(MapGenSettings(size: .duel, seed: 3))
        let state = GameState.newGame(seed: 3, map: result.map, startPositions: result.startPositions)
        for player in state.players where player.isMajor {
            let units = state.units(of: player.id)
            #expect(units.map(\.type) == [.settler, .warrior, .scout])
            #expect(player.explored.setCount > 0)
            #expect(player.gold == 10)
        }
        #expect(state.checkInvariants().isEmpty)
    }

    @Test func riversAreConnectedAndReachWater() {
        let map = MapGenerator.generate(MapGenSettings(size: .standard, seed: 7)).map
        var riverTiles = 0
        for i in 0..<map.tileCount {
            let tile = map[index: i]
            guard tile.riverEdges != 0 else { continue }
            riverTiles += 1
            #expect(tile.isLand)
            // Every river edge is mirrored on the neighbor across it.
            for d in HexDirection.allCases where tile.riverEdges & (1 << d.rawValue) != 0 {
                let n = map.normalize(map.coord(at: i).neighbor(d)).map { map[$0] }
                #expect(n.map { $0.riverEdges & (1 << d.opposite.rawValue) != 0 } == true)
            }
        }
        #expect(riverTiles > 40)
    }

    /// A river may bend around half a hex, but no tile ends up ringed by river edges (a moat),
    /// whether one river circles it or a tributary closes the ring. Bends are the exception:
    /// rivers mostly alternate turns, so their shape does not trace the hex outlines.
    static let riverSeeds: [UInt64] = [1, 2, 3, 7, 11, 42, 99, 123]

    @Test(arguments: [MapSize.standard, .large])
    func riversNeverEncircleATile(size: MapSize) {
        var riverTiles = 0, bends = 0
        for seed in Self.riverSeeds {
            let map = MapGenerator.generate(MapGenSettings(size: size, seed: seed)).map
            for i in 0..<map.tileCount {
                let edges = map[index: i].riverEdges
                guard edges != 0 else { continue }
                riverTiles += 1
                if MapGenerator.longestEdgeRun(edges) >= 3 { bends += 1 }
                #expect(edges.nonzeroBitCount <= MapGenerator.maxEdgesAroundTile,
                        "seed \(seed) tile \(map.coord(at: i)): \(edges.nonzeroBitCount) river edges")
            }
        }
        #expect(riverTiles > 0)
        #expect(Double(bends) < Double(riverTiles) * 0.05, "\(bends) of \(riverTiles) river tiles wrap half a hex")
    }

    /// Every river network (edges joined at their corners) reaches water somewhere: rivers end
    /// at the sea, a lake or another river that does.
    @Test(arguments: [MapSize.standard, .large])
    func everyRiverReachesWater(size: MapSize) {
        for seed in Self.riverSeeds {
            let map = MapGenerator.generate(MapGenSettings(size: size, seed: seed)).map
            var parent: [MapGenerator.Corner: MapGenerator.Corner] = [:]
            func root(_ c: MapGenerator.Corner) -> MapGenerator.Corner {
                var c = c
                while let p = parent[c], p != c { c = p }
                return c
            }
            for i in 0..<map.tileCount {
                for d in HexDirection.allCases where map[index: i].riverEdges & (1 << d.rawValue) != 0 {
                    guard let n = MapGenerator.neighborIndex(i, d, in: map), i < n,
                          let left = MapGenerator.neighborIndex(i, HexDirection(rawValue: (d.rawValue + 1) % 6)!, in: map),
                          let right = MapGenerator.neighborIndex(i, HexDirection(rawValue: (d.rawValue + 5) % 6)!, in: map) else { continue }
                    let a = MapGenerator.Corner(i, n, left), b = MapGenerator.Corner(i, n, right)
                    parent[a] = parent[a] ?? a
                    parent[b] = parent[b] ?? b
                    parent[root(a)] = root(b)
                }
            }
            var wet = Set<MapGenerator.Corner>()
            for corner in parent.keys where corner.tiles.contains(where: { map[index: $0].terrain.isWater }) { wet.insert(root(corner)) }
            let dry = Set(parent.keys.map(root)).subtracting(wet)
            #expect(!parent.isEmpty)
            #expect(dry.isEmpty, "\(size) seed \(seed): \(dry.count) river networks never reach water")
        }
    }

    @Test func longestEdgeRunWrapsAround() {
        #expect(MapGenerator.longestEdgeRun(0) == 0)
        #expect(MapGenerator.longestEdgeRun(0b000101) == 1)
        #expect(MapGenerator.longestEdgeRun(0b100011) == 3) // edges 5, 0, 1
        #expect(MapGenerator.longestEdgeRun(0b111111) == 6)
    }
}
