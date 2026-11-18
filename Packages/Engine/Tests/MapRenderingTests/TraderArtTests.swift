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
        let r = MapRendererTests.makeRenderer()
        #expect(r.unitAtlas.width == 2048 && r.unitAtlas.height <= 1536)
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
        #expect(UnitSprite.figureCells(.trader, east: false).data == .teamMask(.builder))
        #expect(UnitSprite.figureCells(.settler, east: false, escorted: true).data == .teamMask(.settler))
        #expect(table.maskCode(.trader, east: false).truncatingRemainder(dividingBy: 1) == 0.25)
        #expect(table.maskCode(.settler, east: false, escorted: true).truncatingRemainder(dividingBy: 1) == 0.25)
        #expect(table.maskCode(.builder, east: false).truncatingRemainder(dividingBy: 1) == 0)

        // And they are painted there: the second figure's silhouette field fills alpha.
        let image = try #require(r.unitAtlas.makeImage())
        let bytes = try #require(image.dataProvider?.data as Data?)
        // Only the part of a cell its figures cover is in the atlas (`SpriteSet.sampled`).
        func secondFigure(_ type: UnitType) throws -> Int {
            let key = UnitSprite.teamMask(type)
            let uv = r.unitAtlas.uv(key), n = Float(UnitSprite.bodyCell), part = try #require(key.sampled)
            let x0 = Int((uv.x * Float(image.width)).rounded()), y0 = Int((uv.y * Float(image.height)).rounded())
            var count = 0
            for y in (y0 + Int(((1 - part.w) * n).rounded(.up)))..<(y0 + Int(((1 - part.y) * n).rounded(.down))) {
                for x in (x0 + Int((part.x * n).rounded(.up)))..<(x0 + Int((part.z * n).rounded(.down)))
                where bytes[y * image.bytesPerRow + x * 4 + 3] > 128 { count += 1 }
            }
            return count
        }
        #expect(try secondFigure(.settler) > 2000, "the escorted settler's data")
        #expect(try secondFigure(.builder) > 2000, "the Trader's data")
        #expect(try secondFigure(.scout) == 0)
    }
}
