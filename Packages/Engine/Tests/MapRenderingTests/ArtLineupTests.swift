import CoreGraphics
import Foundation
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// Every unit type side by side, for judging the unit art: two rows of the six types (two
/// owners), on open land, close up, at standard zoom and at strategic zoom. Runs only when
/// RENDER_OUT is set (with the gallery):
///
///     RENDER_OUT=/some/dir swift test --filter ArtLineup
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_OUT"] != nil))
struct ArtLineup {
    /// A Small map with the six unit types of two players in two rows on open land, and the
    /// hex in the middle of the lineup.
    static func lineup() throws -> (GameState, HexCoord) {
        let generated = MapGenerator.generate(MapGenSettings(size: .small, seed: 42))
        var state = GameState.newGame(seed: 42, map: generated.map, startPositions: generated.startPositions)
        let map = state.map
        func open(_ hex: HexCoord) -> Bool {
            guard let t = map.tile(at: hex) else { return false }
            return t.isLand && t.elevation == .flat && t.feature != .forest && t.feature != .jungle && t.feature != .marsh
        }
        // The first row of tiles whose two rows of six (and the row between) are all open, well
        // away from the starting units.
        let starts = state.units.map(\.position)
        var origin: HexCoord?
        search: for i in 0..<map.tileCount {
            let hex = map.coord(at: i)
            guard starts.allSatisfy({ map.distance($0, hex) > 9 }) else { continue }
            for dr in 0..<3 {
                for dq in 0..<6 {
                    let h = HexCoord(q: hex.q + dq - (dr + 1) / 2, r: hex.r + dr)
                    guard let n = map.normalize(h), open(n) else { continue search }
                }
            }
            origin = hex
            break
        }
        let start = try #require(origin)
        for (row, owner) in [(0, 0), (2, 1)] {
            for (dq, type) in UnitType.allCases.enumerated() {
                let hex = try #require(map.normalize(HexCoord(q: start.q + dq - (row + 1) / 2, r: start.r + row)))
                _ = state.addUnit(type, owner: PlayerID(owner), at: hex)
            }
        }
        let middle = try #require(map.normalize(HexCoord(q: start.q + 3 - 1, r: start.r + 1)))
        return (state, middle)
    }

    @Test func lineup() throws {
        let (state, middle) = try Self.lineup()
        // The strategic view is rendered smaller: a Small map caps the zoom of a large view
        // below the switch to medallions. Zoom is clamped for the view size, so each renderer
        // renders once at its size before zooming.
        for (name, scale, tilted, width, height) in [("close", 0.45, true, 1600, 1100), ("standard", 1.0, true, 1600, 1100),
                                                     ("strategic", 2.5, true, 800, 550), ("topdown", 0.8, false, 1600, 1100)]
            as [(String, CGFloat, Bool, Int, Int)] {
            let r = MapRenderer(state: state, viewer: PlayerID(0))
            r.fogEnabled = false
            r.animationTime = 5
            r.tilted = tilted
            _ = r.renderImage(width: width, height: height)
            r.setCameraScale(scale)
            r.centerCamera(on: middle, animated: false)
            let image = try #require(r.renderImage(width: width, height: height))
            print("lineup \(name): camera scale \(r.camera.scale)")
            MapRendererTests.save(image, "g05b-lineup-\(name).png")
            if name == "close", let atlas = r.unitAtlas.makeImage() { MapRendererTests.save(atlas, "atlas-units.png") }
        }
    }
}
