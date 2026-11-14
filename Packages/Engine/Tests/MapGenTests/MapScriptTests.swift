import Testing
import GameCore
@testable import MapGen

/// Continents and Archipelago (M2 §3.5).
@Suite struct MapScriptTests {
    static func landmassOf(_ hex: HexCoord, in map: HexMap) -> Int? {
        MapGenerator.components(in: map, where: { $0.landMovementCost != nil }).firstIndex { $0.contains(map.index(of: hex)!) }
    }

    @Test(arguments: [MapScript.continents, .archipelago])
    func generatesPlayableStarts(script: MapScript) {
        for size in MapSize.allCases {
            for seed: UInt64 in 1...3 {
                let result = MapGenerator.generate(MapGenSettings(size: size, seed: seed, script: script))
                #expect(result.startPositions.count == size.defaultPlayers, "\(size) seed \(seed)")
                for start in result.startPositions {
                    #expect(result.map[start].landMovementCost != nil)
                    #expect(Ruleset.standard.feature(result.map[start].feature).allowsCity)
                }
                for (i, a) in result.startPositions.enumerated() {
                    for b in result.startPositions[(i + 1)...] { #expect(result.map.distance(a, b) >= MapGenerator.lowestStartDistance) }
                }
            }
        }
    }

    @Test(arguments: [MapScript.continents, .archipelago])
    func duelKeepsOneLandmass(script: MapScript) {
        for seed: UInt64 in 1...8 {
            let result = MapGenerator.generate(MapGenSettings(size: .duel, seed: seed, script: script))
            let masses = Set(result.startPositions.map { Self.landmassOf($0, in: result.map) })
            #expect(masses.count == 1, "seed \(seed)")
        }
    }

    /// On Small and larger, the scripts put starts on more than one landmass (most seeds).
    @Test(arguments: [MapScript.continents, .archipelago])
    func separatesStartsOffDuel(script: MapScript) {
        var separated = 0
        for seed: UInt64 in 1...8 {
            let result = MapGenerator.generate(MapGenSettings(size: .standard, seed: seed, script: script))
            if Set(result.startPositions.map { Self.landmassOf($0, in: result.map) }).count > 1 { separated += 1 }
        }
        #expect(separated >= 6)
    }

    /// Continents: two large landmasses, each with a fair share of the land.
    @Test func continentsHasTwoLargeLandmasses() {
        for seed: UInt64 in 1...8 {
            let map = MapGenerator.generate(MapGenSettings(size: .standard, seed: seed, script: .continents)).map
            let sizes = MapGenerator.components(in: map, where: { $0.landMovementCost != nil }).map(\.count).sorted(by: >)
            let land = sizes.reduce(0, +)
            #expect(sizes.count >= 2 && sizes[1] * 8 >= land, "seed \(seed): \(sizes.prefix(4))")
        }
    }

    /// Archipelago: less land, in many pieces, none holding most of it.
    @Test func archipelagoIsBroken() {
        for seed: UInt64 in 1...8 {
            let map = MapGenerator.generate(MapGenSettings(size: .standard, seed: seed, script: .archipelago)).map
            let sizes = MapGenerator.components(in: map, where: { $0.landMovementCost != nil }).map(\.count).sorted(by: >)
            let land = sizes.reduce(0, +)
            #expect(Double(land) / Double(map.tileCount) < 0.32)
            #expect(sizes.count >= 8 && sizes[0] * 10 <= land * 7, "seed \(seed): \(sizes.prefix(4))")
        }
    }

    @Test(arguments: MapScript.allCases)
    func deterministic(script: MapScript) {
        let a = MapGenerator.generate(MapGenSettings(size: .small, seed: 77, script: script))
        let b = MapGenerator.generate(MapGenSettings(size: .small, seed: 77, script: script))
        #expect(a.map == b.map && a.startPositions == b.startPositions)
    }

    /// Pangaea is the default and M1's generator, unchanged.
    @Test func pangaeaIsDefault() {
        let a = MapGenerator.generate(MapGenSettings(size: .small, seed: 5))
        let b = MapGenerator.generate(MapGenSettings(size: .small, seed: 5, script: .pangaea))
        #expect(a.map == b.map && a.startPositions == b.startPositions)
    }
}
