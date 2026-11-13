import CoreGraphics
import Foundation
import Metal
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// Units standing in woods: their bases lie under the trees, and trees standing in front of a
/// figure are drawn over it (ART.md §5).
@MainActor
@Suite struct UnitLayeringTests {
    static let width = 1200, height = 900

    /// Warriors, scouts (on horseback) and a settler (ox cart) of two players on the wooded
    /// tiles nearest player 0's start (seed 7 has plenty of forest there).
    static func woods() throws -> (GameState, HexCoord) {
        let generated = MapGenerator.generate(MapGenSettings(size: .small, seed: 7))
        var state = GameState.newGame(seed: 7, map: generated.map, startPositions: generated.startPositions)
        let home = try #require(state.units(of: PlayerID(0)).first).position
        let woods = state.map.coords(within: 6, of: home).filter { hex in
            guard let tile = state.map.tile(at: hex) else { return false }
            return (tile.feature == .forest || tile.feature == .jungle) && state.units(at: hex).isEmpty
        }
        .sorted { state.map.distance($0, home) < state.map.distance($1, home) }
        let types: [UnitType] = [.warrior, .scout, .warrior, .scout, .settler]
        try #require(woods.count >= types.count)
        for (i, (hex, type)) in zip(woods, types).enumerated() {
            _ = state.addUnit(type, owner: PlayerID(i % 2), at: hex)
        }
        return (state, woods[0])
    }

    static func view(_ state: GameState, on hex: HexCoord, scale: CGFloat) -> MapRenderer {
        let r = MapRenderer(state: state, viewer: PlayerID(0))
        r.fogEnabled = false
        r.animationTime = 5
        r.setCameraScale(scale)
        r.centerCamera(on: hex, animated: false)
        return r
    }

    static func pixels(_ r: MapRenderer) throws -> [UInt8] {
        let image = try #require(r.renderImage(width: width, height: height))
        return try #require(image.dataProvider?.data as Data?).map { $0 }
    }

    /// Alpha of the given passes alone per pixel, from renders over black and over white.
    static func coverage(_ r: MapRenderer, _ passes: MapRenderer.Passes) throws -> [Float] {
        r.passes = passes
        defer { r.passes = .all; r.backdrop = nil }
        r.backdrop = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let black = try pixels(r)
        r.backdrop = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        let white = try pixels(r)
        return (0..<(width * height)).map { i in
            let d = Int(white[i * 4]) + Int(white[i * 4 + 1]) + Int(white[i * 4 + 2])
                - Int(black[i * 4]) - Int(black[i * 4 + 1]) - Int(black[i * 4 + 2])
            return 1 - Float(d) / (3 * 255)
        }
    }

    /// Redrawing the trees in front of figures changes only pixels where a unit is drawn, and
    /// in woods it does change some (trees now overlap the figures behind them).
    @Test(arguments: [0.4, 0.8] as [CGFloat])
    func treesInFrontCoverFiguresAndNothingElse(scale: CGFloat) throws {
        let (state, hex) = try Self.woods()
        let r = Self.view(state, on: hex, scale: scale)
        let units = try Self.coverage(r, .units)
        let lifted = try Self.pixels(r)
        r.liftDecorations = false
        let flat = try Self.pixels(r)
        var inside = 0, outside = 0
        for i in 0..<(Self.width * Self.height) {
            let d = (0..<3).map { abs(Int(lifted[i * 4 + $0]) - Int(flat[i * 4 + $0])) }.max()!
            guard d > 1 else { continue }
            if units[i] > 0.001 { inside += 1 } else { outside += 1 }
        }
        #expect(outside == 0, "\(outside) pixels changed away from any unit")
        #expect(inside > 200, "trees in front changed only \(inside) unit pixels")
    }

    /// Plants in front cover a figure's legs only: on every wooded tile, at least 75% of the
    /// unit pixels (figures, emblems, standards, band) look the same as with nothing lifted.
    @Test(arguments: [0.4, 1.4] as [CGFloat])
    func figuresStayMostlyVisible(scale: CGFloat) throws {
        let (state, hex) = try Self.woods()
        let r = Self.view(state, on: hex, scale: scale)
        let all = r.unitVisuals
        var tiles: [HexCoord: [UnitID: UnitVisual]] = [:]
        for (id, visual) in all { if let unit = r.state.unit(id) { tiles[unit.position, default: [:]][id] = visual } }
        var report: [String] = []
        var covered = 0
        for (tile, visuals) in tiles.sorted(by: { ($0.key.q, $0.key.r) < ($1.key.q, $1.key.r) }) {
            r.unitVisuals = visuals
            let units = try Self.coverage(r, .units)
            r.liftDecorations = true
            let lifted = try Self.pixels(r)
            r.liftDecorations = false
            let flat = try Self.pixels(r)
            var drawn = 0, hidden = 0
            for i in units.indices where units[i] > 0.5 {
                drawn += 1
                let d = (0..<3).map { abs(Int(lifted[i * 4 + $0]) - Int(flat[i * 4 + $0])) }.max()!
                if d > 24 { hidden += 1 }
            }
            guard drawn > 0 else { continue }
            covered += hidden
            let share = Double(hidden) / Double(drawn)
            if share > 0.25 { report.append("\(tile): \(hidden) of \(drawn)") }
        }
        r.unitVisuals = all
        r.liftDecorations = true
        #expect(report.isEmpty, "plants hide more than 25% of the units on \(report) at \(scale)")
        #expect(covered > 0, "no plant stands in front of any unit at \(scale)")
    }

    /// A base's wash and contact shadow lie under the trees: where a tree stands and no band,
    /// figure or marker is drawn over it, the frame is the same with and without units.
    @Test func basesDoNotTintTheTreesOnTheirTile() throws {
        let (state, hex) = try Self.woods()
        let r = Self.view(state, on: hex, scale: 0.5)
        let trees = try Self.coverage(r, .decor)
        let standing = try Self.coverage(r, .units)
        let with = try Self.pixels(r)
        let all = r.unitVisuals
        r.unitVisuals = [:]
        let without = try Self.pixels(r)
        r.unitVisuals = all
        var count = 0, total = 0
        for i in 0..<(Self.width * Self.height) where trees[i] > 0.97 && standing[i] < 0.002 {
            count += 1
            total += (0..<3).reduce(0) { $0 + abs(Int(with[i * 4 + $1]) - Int(without[i * 4 + $1])) }
        }
        #expect(count > 10_000)
        let mean = Double(total) / Double(max(count * 3, 1))
        #expect(mean < 0.5, "tree pixels change by \(mean)/255 on average when units are added")
    }
}
