import CoreGraphics
import Foundation
import GameCore
import Testing
@testable import MapRendering

// The Explore order's heading (GameCore `HexMap.compassPoint`, M1 §16) against the map as it is
// drawn (`HexLayout.center`, y up): in p3e the card named north for a goal drawn below the unit.

@Suite struct ExploreCompassTests {
    /// For every pair of tiles in a block of the map, the compass point is the one nearest the
    /// line between the two tiles' drawn centres (pairs within half a degree of a boundary
    /// between two points left out).
    @Test func theCompassMatchesTheDrawnMap() {
        let map = HexMap(width: 24, height: 16, wrapsX: false, fill: Tile(terrain: .grassland))
        let layout = HexLayout(size: 32, map: map)
        let block = (4..<16).flatMap { col in (3..<13).map { row in OffsetCoord(col: col, row: row).hex } }
        var checked = 0
        for a in block {
            for b in block where b != a {
                let pa = layout.center(of: a), pb = layout.center(of: b)
                // Counter-clockwise from east, in eighths of a turn.
                let eighths = atan2(Double(pb.y - pa.y), Double(pb.x - pa.x)) / (Double.pi / 4)
                guard abs(eighths - eighths.rounded()) < 0.5 - 0.5 / 45 else { continue }
                let drawn = CompassPoint(rawValue: (Int(eighths.rounded()) % 8 + 8) % 8)
                #expect(map.compassPoint(from: a, to: b) == drawn, "\(a) → \(b)")
                checked += 1
            }
        }
        #expect(checked > 10_000)
    }

    /// Up the screen is north: the tile drawn above another is north of it.
    @Test func upIsNorth() {
        let map = HexMap(width: 24, height: 16, wrapsX: true, fill: Tile(terrain: .grassland))
        let layout = HexLayout(size: 32, map: map)
        let low = OffsetCoord(col: 10, row: 4).hex, high = OffsetCoord(col: 10, row: 6).hex
        #expect(layout.center(of: high).y > layout.center(of: low).y)
        #expect(map.compassPoint(from: low, to: high) == .north)
        #expect(map.compassPoint(from: high, to: low) == .south)
    }
}
