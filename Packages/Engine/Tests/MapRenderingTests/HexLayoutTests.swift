import CoreGraphics
import Testing
import GameCore
@testable import MapRendering

@Suite struct HexLayoutTests {
    let layout = HexLayout(size: 32, mapWidth: 20, mapHeight: 12, wrapsX: true)

    @Test func centerRoundTrip() {
        for row in 0..<12 {
            for col in 0..<20 {
                let hex = OffsetCoord(col: col, row: row).hex
                #expect(layout.hex(at: layout.center(of: hex)) == hex)
            }
        }
    }

    @Test func pointsNearCenterResolveToThatHex() {
        let hex = OffsetCoord(col: 5, row: 3).hex
        let c = layout.center(of: hex)
        for (dx, dy) in [(10.0, 0.0), (-10.0, 5.0), (0.0, 20.0), (12.0, -14.0)] {
            #expect(layout.hex(at: CGPoint(x: c.x + dx, y: c.y + dy)) == hex)
        }
    }

    @Test func offsetLayoutMatchesOddR() {
        // Odd rows are shifted half a tile east.
        let even = layout.center(of: OffsetCoord(col: 2, row: 2).hex)
        let odd = layout.center(of: OffsetCoord(col: 2, row: 3).hex)
        #expect(abs((odd.x - even.x) - layout.tileWidth / 2) < 0.001)
        #expect(abs((odd.y - even.y) - layout.rowHeight) < 0.001)
    }

    @Test func nearestCopyWraps() {
        let w = layout.worldWidth
        #expect(abs(layout.nearestCopy(of: 10, to: w - 5) - (10 + w)) < 0.001)
        #expect(abs(layout.nearestCopy(of: w - 10, to: 5) - (-10)) < 0.001)
        #expect(layout.nearestCopy(of: 100, to: 120) == 100)
    }
}
