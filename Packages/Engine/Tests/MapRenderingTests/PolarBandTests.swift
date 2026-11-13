import CoreGraphics
import Foundation
import Metal
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// Zoomed out past the map's height (`MapCamera.zoomOutFloor`), an upright view shows bands
/// beyond the poles: the polar pack under a haze, which must fill them (never the backdrop) and
/// must not repeat the edge row's fog out into the haze.
@MainActor
@Suite struct PolarBandTests {
    /// An upright iPad (834×1210 points, drawn at 1x) on the Duel map at the widest zoom.
    static func uprightView(_ state: GameState, fog: Bool) -> MapRenderer {
        let renderer = MapRenderer(state: state, viewer: PlayerID(0))
        renderer.animationTime = 100
        renderer.fogEnabled = fog
        _ = renderer.renderImage(width: 834, height: 1210, scale: 1)
        renderer.setCameraScale(1000)
        return renderer
    }

    static func duel() -> GameState {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: 11))
        return GameState.newGame(seed: 11, map: generated.map, startPositions: generated.startPositions)
    }

    /// BGRA bytes of an image (`renderImage`'s layout).
    static func pixels(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        return [UInt8](data)
    }

    /// The ground quad reaches past everything in view, so no backdrop shows above or below
    /// the polar bands (the quad used to stop 60% of the map's height past each pole).
    @Test(arguments: [true, false])
    func theGroundFillsAnUprightViewAtTheWidestZoom(fog: Bool) throws {
        let renderer = Self.uprightView(Self.duel(), fog: fog)
        #expect(renderer.camera.scale > 2.2)
        let span = try #require(renderer.camera.groundSpanY)
        let h = Float(renderer.layout.worldHeight)
        #expect(span.south < -0.6 * h && span.north > 1.6 * h, "the view reaches past the old ground quad: \(span)")
        let uniforms = renderer.makeUniforms()
        #expect(uniforms.ground.y < span.south && uniforms.ground.w > span.north)
        renderer.backdrop = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
        let image = try #require(renderer.renderImage(width: 834, height: 1210, scale: 1))
        let bytes = Self.pixels(image)
        var backdrop = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i] > 250 && bytes[i + 1] < 5 && bytes[i + 2] > 250 { backdrop += 1 }
        #expect(backdrop == 0, "\(backdrop) pixels of backdrop")
    }

    /// With the fog on, the cloud over an unexplored edge tile spills at most three rows past
    /// the edge, and everything beyond is the same explored pack and haze whatever the edge row
    /// holds: two worlds whose north edge rows differ in what the viewer explored render the
    /// same beyond those rows. (Off-map tiles once copied the nearest edge tile's fog, so each
    /// column's cloud or clear ice ran on into the haze.) The far band is not a flat fill.
    @Test func pastThePolesNothingRepeatsTheEdgeRow() throws {
        let hidden = Self.duel()
        var explored = hidden
        let map = hidden.map
        for col in 0..<(map.width / 2) {
            explored.players[0].explored[(map.height - 1) * map.width + col] = true
        }
        #expect(!hidden.players[0].explored[(map.height - 1) * map.width])
        let a = Self.uprightView(hidden, fog: true), b = Self.uprightView(explored, fog: true)
        #expect(a.camera == b.camera)
        let imageA = try #require(a.renderImage(width: 834, height: 1210, scale: 1))
        let imageB = try #require(b.renderImage(width: 834, height: 1210, scale: 1))
        // Screen rows showing ground more than five rows north of the map.
        let layout = a.layout
        let line = Float(layout.worldHeight + 5 * layout.rowHeight)
        let edge = try #require(a.camera.viewPoint(of: [a.camera.target.x, line, 0]))
        let rows = Int(edge.y)
        #expect(rows > 100, "the band beyond is \(rows) points tall")
        let pa = Self.pixels(imageA), pb = Self.pixels(imageB)
        var diff = 0
        var colors = Set<UInt32>()
        for i in 0..<(rows * 834 * 4) {
            diff = max(diff, abs(Int(pa[i]) - Int(pb[i])))
            if i % 4 == 0, (i / 4) % 7 == 0 {
                colors.insert(UInt32(pa[i]) | UInt32(pa[i + 1]) << 8 | UInt32(pa[i + 2]) << 16)
            }
        }
        #expect(diff <= 1, "beyond the spill the band differs by \(diff)/255")
        #expect(colors.count > 200, "\(colors.count) colours in the band beyond")
        // Nearer the edge they do differ: the explored half shows the pack, the other the cloud.
        let near = try #require(a.camera.viewPoint(of: [a.camera.target.x, Float(layout.worldHeight), 0]))
        let band = (Int(near.y) - 20) * 834 * 4..<(Int(near.y) - 10) * 834 * 4
        #expect(band.contains { pa[$0] != pb[$0] })
    }

    /// Mean lightness (Rec. 709 luma, 0...1) of an 834-pixel-wide BGRA image over pixel ranges.
    static func lightness(_ bytes: [UInt8], x: Range<Int>, y: Range<Int>) -> Double {
        var sum = 0.0
        for row in y {
            for col in x {
                let i = (row * 834 + col) * 4
                sum += 0.0722 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.2126 * Double(bytes[i + 2])
            }
        }
        return sum / 255 / Double(x.count * y.count)
    }

    /// The bands beyond the poles are the same on either side of the seam (x = 0), where one
    /// wrapped copy of the world meets the next: the cloud bank over the unexplored north edge
    /// spills as far past it west of the seam as east. (Measuring columns as well as rows past
    /// the edge once kept every copy but the camera's own from spilling.)
    @Test func theCloudBankSpillsAlikeEitherSideOfTheSeam() throws {
        let state = Self.duel()
        let map = state.map
        let renderer = Self.uprightView(state, fog: true)
        renderer.centerCamera(on: map.coord(at: (map.height / 2) * map.width), animated: false)
        let image = try #require(renderer.renderImage(width: 834, height: 1210, scale: 1))
        // A row of ground a row past the north edge, inside the spill, and the seam on it.
        let layout = renderer.layout
        let y = Float(layout.worldHeight + layout.rowHeight)
        let seam = try #require(renderer.camera.viewPoint(of: [0, y, 0]))
        #expect(seam.x > 250 && seam.x < 584, "the seam is near the middle of the view: \(seam.x)")
        let x = Int(seam.x), rows = Int(seam.y) - 2..<Int(seam.y) + 3
        let bytes = Self.pixels(image)
        let west = Self.lightness(bytes, x: x - 200..<x - 20, y: rows), east = Self.lightness(bytes, x: x + 20..<x + 200, y: rows)
        #expect(west < 0.45 && east < 0.45, "the bank's grey on both sides of the seam: west \(west), east \(east)")
        #expect(abs(west - east) < 0.06, "west \(west), east \(east)")
    }

    /// A seen polar edge stays lit for a row or two past it, as the pack beyond a seen edge
    /// always looked, while farther out the pack and haze are those beyond explored ground: a
    /// scout on the south coast changes the band just past the edge and nothing six rows out.
    @Test func aSeenEdgeStaysLitJustPastIt() throws {
        let start = Self.duel()
        let map = start.map
        // A tile in the three southernmost rows a scout may stand on: from there it sees the edge.
        let hex = try #require((0..<3).flatMap { row in (0..<map.width).map { map.coord(at: row * map.width + $0) } }.first { hex in
            start.canEnd(.scout, owner: PlayerID(0), at: hex) && start.units(at: hex).isEmpty
        })
        var seen = start
        seen.addUnit(.scout, owner: PlayerID(0), at: hex)
        let edge = map.coord(at: map.index(of: hex)! % map.width)
        #expect(seen.visibleTiles(for: PlayerID(0))[map.index(of: edge)!])
        // The same knowledge without the scout: the tiles it sees are explored, out of sight.
        var explored = start
        explored.players[0].explored = seen.players[0].explored
        #expect(!explored.visibleTiles(for: PlayerID(0))[map.index(of: edge)!])
        let images = try [seen, explored].map { state in
            let renderer = Self.uprightView(state, fog: true)
            renderer.centerCamera(on: hex, animated: false)
            let image = try #require(renderer.renderImage(width: 834, height: 1210, scale: 1))
            let c = renderer.layout.center(of: edge)
            let near = try #require(renderer.camera.viewPoint(of: [Float(c.x), -0.3 * Float(renderer.layout.rowHeight), 0]))
            let far = try #require(renderer.camera.viewPoint(of: [Float(c.x), -6 * Float(renderer.layout.rowHeight), 0]))
            return (bytes: Self.pixels(image), near: near, far: far)
        }
        let (lit, dim) = (images[0], images[1])
        #expect(lit.near == dim.near && lit.far == dim.far)
        let x = Int(lit.near.x), near = Int(lit.near.y) - 3..<Int(lit.near.y) + 3
        let litNear = Self.lightness(lit.bytes, x: x - 10..<x + 10, y: near), dimNear = Self.lightness(dim.bytes, x: x - 10..<x + 10, y: near)
        #expect(litNear > dimNear + 0.04, "just past the edge, seen \(litNear) and explored \(dimNear)")
        var diff = 0
        for row in Int(lit.far.y) - 4..<Int(lit.far.y) + 4 {
            for col in x - 40..<x + 40 {
                for k in 0..<3 { diff = max(diff, abs(Int(lit.bytes[(row * 834 + col) * 4 + k]) - Int(dim.bytes[(row * 834 + col) * 4 + k]))) }
            }
        }
        #expect(diff <= 1, "six rows out the band differs by \(diff)/255")
    }
}
