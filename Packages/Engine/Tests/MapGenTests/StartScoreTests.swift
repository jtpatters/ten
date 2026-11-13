import Testing
import GameCore
@testable import MapGen

/// Start scoring (M1 §2, p3b): starts favour land the capital can work and improve.
@Suite struct StartScoreTests {
    /// Every land tile MapGen can make: terrain, elevation and feature.
    static var landTiles: [Tile] {
        Terrain.allCases.filter { !$0.isWater }.flatMap { terrain in
            Elevation.allCases.flatMap { elevation in Feature.allCases.map { Tile(terrain: terrain, elevation: elevation, feature: $0) } }
        }
    }

    /// MapGen's own terrain facts agree with the rules data: which tiles a Farm, Mine or
    /// Pasture may stand on (any tech), and a workable tile's unimproved Food.
    @Test func terrainFactsMatchTheRules() {
        let rules = Ruleset.standard
        for tile in Self.landTiles {
            let sites = Improvement.allCases.contains { rules.allowsImprovement($0, on: tile) }
            #expect(MapGenerator.isImprovable(tile) == sites, "\(tile)")
            if rules.isWorkable(tile) {
                #expect(MapGenerator.food(tile) == rules.tileYields(tile, knows: { _ in false }).food, "\(tile)")
            }
        }
        for terrain in [Terrain.coast, .lake, .ocean] {
            #expect(!MapGenerator.isImprovable(Tile(terrain: terrain)))
            #expect(MapGenerator.food(Tile(terrain: terrain)) == rules.tileYields(Tile(terrain: terrain), knows: { _ in false }).food)
        }
    }

    /// Forest earns nothing over the bare tile, and improvable land earns a capped bonus: a start
    /// ringed by forest scores exactly the bonuses below the same start on open grassland, and a
    /// start with only a few open tiles sits between them.
    @Test func forestLockedStartsScoreBelowOpenLand() {
        let centre = HexCoord(q: 6, r: 5)
        func map(_ ring: (HexCoord) -> Tile) -> HexMap {
            var map = HexMap(width: 14, height: 10, wrapsX: false, fill: Tile(terrain: .grassland))
            for c in map.coords(within: 2, of: centre) where c != centre { map[c] = ring(c) }
            return map
        }
        let open = map { _ in Tile(terrain: .grassland) }
        let woods = map { _ in Tile(terrain: .grassland, feature: .forest) }
        // Two open tiles next to the centre, the rest forest.
        let clearing = map { c in [centre.neighbor(.east), centre.neighbor(.west)].contains(c) ? Tile(terrain: .grassland) : Tile(terrain: .grassland, feature: .forest) }
        let bonus = MapGenerator.improvableBonus * MapGenerator.improvableWanted + MapGenerator.firstRingBonus * MapGenerator.firstRingWanted
        #expect(MapGenerator.startScore(centre, in: woods) == MapGenerator.startScore(centre, in: open) - bonus)
        #expect(MapGenerator.startScore(centre, in: clearing) == MapGenerator.startScore(centre, in: woods)
            + 2 * (MapGenerator.improvableBonus + MapGenerator.firstRingBonus))
    }

    /// Fresh water at the start counts whether it is a river edge or a lake next to it (M1 §4).
    @Test func lakesCountAsFreshWater() {
        let centre = HexCoord(q: 6, r: 5)
        var dry = HexMap(width: 14, height: 10, wrapsX: false, fill: Tile(terrain: .grassland))
        var lake = dry
        lake[centre.neighbor(.east)] = Tile(terrain: .lake)
        dry[centre.neighbor(.east)] = Tile(terrain: .grassland, feature: .forest)
        var river = dry
        river[centre] = Tile(terrain: .grassland, riverEdges: 1)
        #expect(MapGenerator.hasFreshWater(centre, in: lake) && MapGenerator.hasFreshWater(centre, in: river))
        #expect(!MapGenerator.hasFreshWater(centre, in: dry))
        #expect(MapGenerator.startScore(centre, in: river) == MapGenerator.startScore(centre, in: dry) + 6)
    }

    /// Generated Duel starts are never forest-locked: each has at least 6 tiles within 2 that a
    /// Farm, Mine or Pasture may stand on, and at least 1 next to the centre (seeds 1–20; the
    /// p2e scoring had starts with 0).
    @Test func duelStartsHaveImprovableLand() {
        for seed: UInt64 in 1...20 {
            let result = MapGenerator.generate(MapGenSettings(size: .duel, seed: seed))
            let map = result.map
            for start in result.startPositions {
                let near = map.coords(within: 2, of: start).filter { $0 != start && MapGenerator.isImprovable(map[$0]) }
                #expect(near.count >= 6, "seed \(seed) start \(start): \(near.count) improvable tiles within 2")
                #expect(near.contains { map.distance($0, start) == 1 }, "seed \(seed) start \(start): none next to it")
            }
        }
    }
}
