import CoreGraphics
import Foundation
import Testing
import GameCore
@testable import MapRendering

/// The Trader's own figure (ART.md §9, §10): a body cell of its own, mirrored to face east like
/// the other M2 types, within the unit atlas's budget, its data sharing the Builder's data cell
/// and the escorted settler's sharing the Settler's.
@MainActor
struct TraderArtTests {
    @Test func traderHasItsOwnBodyWithinTheAtlas() throws {
        #expect(UnitSprite.hasOwnBody(.trader) && UnitSprite.sharesWestBody(.trader))
        #expect(SpriteSheet<UnitSprite>.width == 2048 && SpriteSheet<UnitSprite>.height == 1536)
        let r = MapRendererTests.makeRenderer()
        let table = r.unitAtlasTable()
        #expect(table.body(.trader, east: false) != table.body(.settler, east: false))
        #expect(table.bodyBounds(.trader, east: false) != table.bodyBounds(.settler, east: false))
        // Facing east: the west-facing cell read right to left, its data read as it is, escorted
        // or not (only the Settler has an escorted body of its own).
        let west = table.body(.trader, east: false), east = table.body(.trader, east: true)
        #expect(east.z == -west.z && east.x == west.x + west.z)
        #expect(table.maskCode(.trader, east: true) > 0 && table.maskCode(.trader, east: true, escorted: true) > 0)
        #expect(table.maskCode(.settler, east: true, escorted: true) < 0)
        // The shared data cells: blue and alpha (a quarter added to the code).
        #expect(table.maskCode(.trader, east: false) == table.maskCode(.builder, east: false) + 0.25)
        #expect(table.maskCode(.settler, east: false, escorted: true) == table.maskCode(.settler, east: false) + 0.25)

        // And they are painted there: the second figure's silhouette field fills alpha.
        let image = try #require(r.unitAtlas.makeImage())
        let bytes = try #require(image.dataProvider?.data as Data?)
        func secondFigure(_ type: UnitType) -> Int {
            let uv = r.unitAtlas.uv(.teamMask(type)), n = UnitSprite.bodyCell
            let x0 = Int((uv.x * Float(image.width)).rounded()), y0 = Int((uv.y * Float(image.height)).rounded())
            var count = 0
            for y in y0..<(y0 + n) {
                for x in x0..<(x0 + n) where bytes[y * image.bytesPerRow + x * 4 + 3] > 128 { count += 1 }
            }
            return count
        }
        #expect(secondFigure(.settler) > 2000, "the escorted settler's data")
        #expect(secondFigure(.builder) > 2000, "the Trader's data")
        #expect(secondFigure(.scout) == 0)
    }
}
