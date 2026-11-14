import Testing
@testable import GameCore
@testable import MapGen

/// Resource placement (M2 §3.1).
@Suite struct ResourcePlacementTests {
    @Test(arguments: [MapSize.duel, .small, .standard])
    func everyStartGetsItsShare(size: MapSize) {
        let rules = Ruleset.standard
        func kind(_ r: Resource) -> ResourceKind { rules.resource(r)!.kind }
        for seed: UInt64 in 1...6 {
            let result = MapGenerator.generate(MapGenSettings(size: size, seed: seed))
            let map = result.map
            func near(_ radius: Int, _ start: HexCoord, _ k: ResourceKind) -> Int {
                map.coords(within: radius, of: start).filter { map[$0].resource.map(kind) == k }.count
            }
            for start in result.startPositions {
                #expect(map[start].resource == nil, "seed \(seed)")
                #expect(near(3, start, .bonus) >= 2, "seed \(seed) start \(start)")
                #expect(near(3, start, .luxury) >= 1, "seed \(seed) start \(start)")
                #expect(near(6, start, .strategic) >= 1, "seed \(seed) start \(start)")
            }
            for t in map.tiles.indices {
                let tile = map.tiles[t]
                guard let r = tile.resource else { continue }
                #expect(tile.feature != .oasis && tile.terrain != .snow)
                #expect(rules.resource(r)!.sites.contains { site in
                    site.terrains.contains(caseName(tile.terrain)) && site.elevations.contains(caseName(tile.elevation))
                        && site.features.contains(caseName(tile.feature))
                }, "\(r) on \(tile)")
            }
            let land = map.tiles.filter(\.isLand).count
            let placed = map.tiles.compactMap(\.resource)
            for k in [ResourceKind.bonus, .luxury, .strategic] {
                #expect(placed.filter { kind($0) == k }.count >= land * (k == .bonus ? 32 : k == .luxury ? 18 : 14) / 1000 / 2,
                        "seed \(seed): too few \(k)")
            }
        }
    }

    @Test func placementIsDeterministic() {
        let a = MapGenerator.generate(MapGenSettings(size: .small, seed: 77)).map
        let b = MapGenerator.generate(MapGenSettings(size: .small, seed: 77)).map
        #expect(a.tiles.map(\.resource) == b.tiles.map(\.resource))
        #expect(a.tiles.contains { $0.resource != nil })
    }
}
