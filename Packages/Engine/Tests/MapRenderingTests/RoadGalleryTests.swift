import CoreGraphics
import Foundation
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// Roads and the Trader beside the Settler, for judging their art: a network of roads (a long
/// straight road, bends of every angle, a T and a crossroads, a hairpin, a dense cluster and a
/// lone road) across open land, hills and woods, partly out of sight; and Traders and Settlers
/// of two players standing on it. Runs only when RENDER_OUT is set:
///
///     RENDER_OUT=/some/dir swift test --filter RoadGallery
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_OUT"] != nil))
struct RoadGallery {
    /// A Small map with the road network round its most open land, the roads, the hex in the
    /// middle and the units' tile.
    static func scene() throws -> (state: GameState, roads: [Bool], center: HexCoord, units: HexCoord) {
        let generated = MapGenerator.generate(MapGenSettings(size: .small, seed: 42))
        var state = GameState.newGame(seed: 42, map: generated.map, startPositions: generated.startPositions)
        let map = state.map
        func score(_ hex: HexCoord) -> Int {
            guard let t = map.tile(at: hex) else { return -9 }
            if !t.isLand { return -6 }
            if t.elevation == .mountains { return -8 }
            return (t.terrain == .grassland || t.terrain == .plains ? 3 : 0) + (t.feature == .jungle || t.feature == .marsh ? -2 : 0)
        }
        let starts = state.units.map(\.position)
        var best = (score: Int.min, hex: map.coord(at: 0))
        for i in 0..<map.tileCount {
            let hex = map.coord(at: i)
            guard starts.allSatisfy({ map.distance($0, hex) > 9 }) else { continue }
            let total = map.coords(within: 4, of: hex).reduce(0) { $0 + score($1) }
            if total > best.score { best = (total, hex) }
        }
        let c = best.hex
        var roads = [Bool](repeating: false, count: map.tileCount)
        func mark(_ hex: HexCoord) {
            if let n = map.normalize(hex), let i = map.index(of: n), map.tile(at: n)?.isLand == true { roads[i] = true }
        }
        func walk(from start: HexCoord, _ steps: [HexDirection]) {
            var at = start
            mark(at)
            for step in steps {
                at = at.neighbor(step)
                mark(at)
            }
        }
        func offset(_ q: Int, _ r: Int) -> HexCoord { HexCoord(q: c.q + q, r: c.r + r) }
        // A long straight road west to east through the middle.
        walk(from: offset(-5, 0), Array(repeating: .east, count: 10))
        // North from the middle: gentle and sharp bends.
        walk(from: c, [.northEast, .northEast, .east, .northEast, .northWest, .northWest])
        // South from two east of the middle: a crossroads there, then a winding road.
        walk(from: offset(2, 0), [.southWest, .southWest, .southEast, .east, .east, .northEast])
        // A hairpin off the west end.
        walk(from: offset(-4, 0), [.northWest, .northEast, .east, .southEast])
        // A dense cluster (a city's roads) and a lone road.
        for hex in map.coords(within: 1, of: offset(-3, 3)) { mark(hex) }
        mark(offset(4, -3))
        // Explored all round, in sight only near the units (west), so the east lies in the fog.
        for hex in map.coords(within: 9, of: c) { if let i = map.index(of: hex) { state.players[0].explored[i] = true } }
        let units = offset(-2, 0)
        for (type, owner, at) in [(UnitType.trader, 0, units), (.settler, 0, offset(-1, 0)), (.trader, 1, offset(-3, 0)),
                                  (.settler, 1, offset(-1, 1)), (.trader, 0, offset(-2, 1)), (.trader, 1, offset(-1, -1)),
                                  (.scout, 0, offset(1, 0))]
            as [(UnitType, Int, HexCoord)] {
            if let n = map.normalize(at), state.canEnd(type, owner: PlayerID(owner), at: n), state.units(at: n).isEmpty {
                _ = state.addUnit(type, owner: PlayerID(owner), at: n)
            }
        }
        // Escorted civilians (the escort carries the standard).
        for (civilian, escort, owner, at) in [(UnitType.settler, UnitType.warrior, 0, offset(0, -2)), (.trader, .spearman, 0, offset(1, -2)),
                                              (.trader, .warrior, 1, offset(0, -3)), (.settler, .archer, 1, offset(1, -3)),
                                              (.trader, .archer, 0, offset(2, -3))]
            as [(UnitType, UnitType, Int, HexCoord)] {
            if let n = map.normalize(at), state.canEnd(civilian, owner: PlayerID(owner), at: n), state.units(at: n).isEmpty {
                _ = state.addUnit(civilian, owner: PlayerID(owner), at: n)
                _ = state.addUnit(escort, owner: PlayerID(owner), at: n)
            }
        }
        return (state, roads, c, units)
    }

    @Test func roads() throws {
        let (state, roads, center, units) = try Self.scene()
        for (name, scale, tilted, fog, on, width, height) in [
            ("r01-roads-close", 0.45, true, true, center, 1600, 1100),
            ("r02-roads-standard", 1.0, true, true, center, 1600, 1100),
            ("r03-roads-strategic", 2.4, true, true, center, 800, 550),
            ("r04-roads-topdown", 0.8, false, false, center, 1600, 1100),
            ("r05-roads-junction", 0.3, true, false, center, 1600, 1100),
            ("r06-roads-far", 1.7, true, false, center, 1600, 1100),
            ("t01-trader-settler", 0.3, true, false, units, 1600, 1100),
            ("t02-trader-settler-standard", 0.8, true, false, units, 1600, 1100),
            ("t03-escorted", 0.3, true, false, HexCoord(q: center.q + 1, r: center.r - 2), 1600, 1100),
            ("t04-strategic", 2.4, true, false, units, 800, 550),
        ] as [(String, CGFloat, Bool, Bool, HexCoord, Int, Int)] {
            let r = MapRenderer(state: state, viewer: PlayerID(0))
            r.fogEnabled = fog
            r.animationTime = 5
            r.tilted = tilted
            r.setRoads(roads)
            _ = r.renderImage(width: width, height: height)
            r.setCameraScale(scale)
            r.centerCamera(on: on, animated: false)
            let image = try #require(r.renderImage(width: width, height: height))
            MapRendererTests.save(image, "\(name).png")
            if name == "r01-roads-close" {
                print("roads: \(r.roadGeometry().count) vertices for \(roads.filter { $0 }.count) road tiles")
            }
        }
        // GPU time with the roads against without (1600×1100), close up and at standard zoom.
        for scale in [0.45, 1.0] as [CGFloat] {
            var ms: [Double] = []
            for withRoads in [true, false, true, false] {
                let r = MapRenderer(state: state, viewer: PlayerID(0))
                r.fogEnabled = false
                r.animationTime = 5
                r.setRoads(withRoads ? roads : [])
                _ = r.renderImage(width: 1600, height: 1100)
                r.setCameraScale(scale)
                r.centerCamera(on: center, animated: false)
                ms.append(ArtGallery.medianGPU(r))
            }
            print(String(format: "roads gpu at %.2f: %.2f / %.2f ms with, %.2f / %.2f ms without", scale, ms[0], ms[2], ms[1], ms[3]))
        }
    }
}
