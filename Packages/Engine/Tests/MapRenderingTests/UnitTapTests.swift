import CoreGraphics
import Foundation
import Metal
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// Tapping a unit's drawn token selects its tile; tapping the ground beside it selects the
/// tile under the finger. Measured on a crowd of units of four players around player 0's
/// start, at close, standard, mid and strategic zoom.
@MainActor
@Suite struct UnitTapTests {
    static let width = 1600, height = 1100 // pixels, 2 per view point
    nonisolated static let scales: [CGFloat] = [0.4, 1.0, 1.6, 2.6]

    /// Player 0's start (a settler and a warrior on one tile) and seven more units of four
    /// players two to three tiles around it.
    static func crowd() -> (GameState, HexCoord) {
        let generated = MapGenerator.generate(MapGenSettings(size: .small, seed: 42))
        var state = GameState.newGame(seed: 42, map: generated.map, startPositions: generated.startPositions)
        let home = state.units(of: PlayerID(0)).first!.position
        var spots = state.map.coords(within: 3, of: home).filter { state.map.distance($0, home) >= 2 }.makeIterator()
        let crowd: [(Int, UnitType)] = [(1, .warrior), (1, .scout), (2, .settler), (2, .warrior), (3, .scout), (3, .warrior), (0, .scout)]
        for (player, type) in crowd {
            while let hex = spots.next() {
                guard state.canEnd(type, owner: PlayerID(player), at: hex), state.units(at: hex).isEmpty else { continue }
                _ = state.addUnit(type, owner: PlayerID(player), at: hex)
                break
            }
        }
        return (state, home)
    }

    static func view(_ state: GameState, on hex: HexCoord, scale: CGFloat) throws -> MapRenderer {
        let r = MapRenderer(state: state, viewer: PlayerID(0))
        r.fogEnabled = false
        r.animationTime = 5
        r.setCameraScale(scale)
        r.centerCamera(on: hex, animated: false)
        _ = try #require(r.renderImage(width: width, height: height))
        return r
    }

    static func bytes(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        return [UInt8](data)
    }

    /// Alpha coverage of the unit pass alone at the center of each view point (2x2 pixels):
    /// rendered over black and over white, a premultiplied pixel differs by (1 - alpha) * 255.
    static func unitCoverage(_ r: MapRenderer) throws -> [Float] {
        r.passes = .units
        defer { r.passes = .all; r.backdrop = nil }
        r.backdrop = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let black = bytes(try #require(r.renderImage(width: width, height: height)))
        r.backdrop = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        let white = bytes(try #require(r.renderImage(width: width, height: height)))
        var alpha = [Float](repeating: 0, count: (width / 2) * (height / 2))
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                let i = ((2 * y + 1) * width + 2 * x + 1) * 4
                let d = Int(white[i]) + Int(white[i + 1]) + Int(white[i + 2]) - Int(black[i]) - Int(black[i + 1]) - Int(black[i + 2])
                alpha[y * (width / 2) + x] = 1 - Float(d) / (3 * 255)
            }
        }
        return alpha
    }

    /// The center of an unoccupied neighbor of a unit selects the neighbor, and so do points
    /// on the way from it toward the unit (10-40% of the way), all but a few that the
    /// unit's figure covers.
    @Test(arguments: scales)
    func tapsBesideAUnitSelectTheTileUnderTheFinger(scale: CGFloat) throws {
        let (state, home) = Self.crowd()
        let r = try Self.view(state, on: home, scale: scale)
        let occupied = Set(r.unitVisuals.keys.compactMap { r.state.unit($0)?.position })
        let size = CGSize(width: CGFloat(Self.width) / 2, height: CGFloat(Self.height) / 2)
        var stolenCenters: [String] = [], inner = 0, stolenInner = 0
        for hex in occupied {
            for direction in HexDirection.allCases {
                guard let n = state.map.normalize(hex.neighbor(direction)), !occupied.contains(n) else { continue }
                var c = r.layout.center(of: n)
                c.x = r.layout.nearestCopy(of: c.x, to: CGFloat(r.camera.target.x))
                guard let v = r.camera.viewPoint(of: [Float(c.x), Float(c.y), 0]),
                      v.x > 20, v.y > 20, v.x < size.width - 20, v.y < size.height - 20 else { continue }
                if r.hex(atViewPoint: v) != n { stolenCenters.append("\(n) (\(direction) of \(hex))") }
                var u = r.layout.center(of: hex)
                u.x = r.layout.nearestCopy(of: u.x, to: c.x)
                for k in 1...4 {
                    let t = CGFloat(k) / 10
                    let p = SIMD3(Float(c.x + (u.x - c.x) * t), Float(c.y + (u.y - c.y) * t), 0)
                    guard let point = r.camera.viewPoint(of: p) else { continue }
                    inner += 1
                    if r.hex(atViewPoint: point) != n { stolenInner += 1 }
                }
            }
        }
        #expect(inner >= 40)
        #expect(stolenCenters.isEmpty, "neighbor centers that select a unit at \(scale): \(stolenCenters)")
        #expect(Double(stolenInner) <= 0.05 * Double(inner), "\(stolenInner) of \(inner) points near a neighbor's center select a unit at \(scale)")
    }

    /// Nearly every view point where a tile's units are drawn (more than 80% opaque, so not
    /// their shadows) selects that tile.
    @Test(arguments: scales)
    func tapsOnADrawnUnitSelectItsTile(scale: CGFloat) throws {
        let (state, home) = Self.crowd()
        let r = try Self.view(state, on: home, scale: scale)
        let all = r.unitVisuals
        var byHex: [HexCoord: Set<UnitID>] = [:]
        for id in all.keys { if let unit = r.state.unit(id) { byHex[unit.position, default: []].insert(id) } }
        // Owner of each view point's token: a tile index, -1 none, -2 several tiles' tokens.
        let columns = Self.width / 2, rows = Self.height / 2
        var owner = [Int](repeating: -1, count: columns * rows)
        let hexes = byHex.keys.sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        for (k, hex) in hexes.enumerated() {
            r.unitVisuals = all.filter { byHex[hex]!.contains($0.key) }
            let alpha = try Self.unitCoverage(r)
            for i in alpha.indices where alpha[i] > 0.8 { owner[i] = owner[i] == -1 ? k : -2 }
        }
        r.unitVisuals = all
        _ = try #require(r.renderImage(width: Self.width, height: Self.height))

        var drawn = 0, missed: [HexCoord: Int] = [:]
        for y in 0..<rows {
            for x in 0..<columns {
                let k = owner[y * columns + x]
                guard k >= 0 else { continue }
                drawn += 1
                if r.hex(atViewPoint: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) != hexes[k] { missed[hexes[k], default: 0] += 1 }
            }
        }
        let misses = missed.values.reduce(0, +)
        #expect(drawn > 1000)
        #expect(Double(misses) <= 0.02 * Double(drawn), "\(misses) of \(drawn) drawn unit points select another tile at \(scale): \(missed)")
    }
}
