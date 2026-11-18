import CoreGraphics
import Foundation
import Testing
import GameCore
@testable import MapRendering

/// M3a's units have art of their own (M3a-D10, ART.md §10): a body cell for each facing, both
/// lit from the upper left (never a mirrored cell), data cells shared two to a cell, and a badge
/// of their own.
@MainActor
struct RenaissanceArtTests {
    static let types: [UnitType] = [.musketman, .pikeAndShot, .hussar, .bombard, .caravel, .privateer, .frigate]

    @Test func eachHasItsOwnBodiesDataAndBadge() throws {
        let r = MapRendererTests.makeRenderer()
        let table = r.unitAtlasTable()
        var bodies: Set<UnitSprite> = []
        for type in Self.types {
            #expect(UnitSprite.hasOwnBody(type) && !UnitSprite.sharesWestBody(type) && UnitSprite.badgeType(type) == type, "\(type)")
            for east in [false, true] {
                let cells = UnitSprite.figureCells(type, east: east)
                #expect(cells.body == .body(type, east: east) && !cells.mirroredBody, "\(type) has its own \(east ? "east" : "west")-facing body")
                #expect(cells.mirroredData == east, "\(type) reads its data mirrored facing east")
                #expect(table.body(type, east: east).z > 0, "\(type)'s body is read left to right")
                bodies.insert(cells.body)
            }
            #expect(UnitSprite.all.contains(.badge(type)))
            #expect(table.bodyBounds(type, east: false) != table.bodyBounds(UnitSprite.bodyType(.manAtArms), east: false))
        }
        #expect(bodies.count == Self.types.count * 2)
        // Two to a data cell (the last alone): four cells for the seven.
        let dataCells = Set(Self.types.map { UnitSprite.figureCells($0, east: false).data })
        #expect(dataCells.count == 4)
        // The ships no longer share the Galley's body; the older ships still do.
        for ship in [UnitType.caravel, .privateer, .frigate] { #expect(UnitSprite.bodyType(ship) == ship) }
        for ship in [UnitType.quadrireme, .cog, .dromon] { #expect(UnitSprite.bodyType(ship) == .galley) }
    }

    /// A body painted facing east is the west-facing body drawn again, not mirrored: the same
    /// figure, but its light is not mirrored (both are lit from the west).
    @Test func eastFacingBodiesAreLitFromTheWest() throws {
        let r = MapRendererTests.makeRenderer()
        guard let atlas = r.unitAtlas.makeImage(), let data = atlas.dataProvider?.data as Data? else {
            Issue.record("no atlas image")
            return
        }
        let bytes = [UInt8](data), row = atlas.bytesPerRow, w = Float(atlas.width), h = Float(atlas.height)
        let table = r.unitAtlasTable()
        for type in Self.types {
            let west = table.body(type, east: false), east = table.body(type, east: true)
            var coverWest = 0, coverEast = 0, lightDiffers = 0, painted = 0
            let n = 64
            for j in 0..<n {
                for i in 0..<n {
                    let u = (Float(i) + 0.5) / Float(n), v = (Float(j) + 0.5) / Float(n)
                    func px(_ cell: SIMD4<Float>, _ u: Float) -> (Int, Int) {
                        (Int((cell.x + u * cell.z) * w), Int((cell.y + v * cell.w) * h))
                    }
                    let (wx, wy) = px(west, u), (ex, ey) = px(east, 1 - u)
                    let a = wy * row + wx * 4, b = ey * row + ex * 4
                    let alphaA = Int(bytes[a + 3]), alphaB = Int(bytes[b + 3])
                    coverWest += alphaA
                    coverEast += alphaB
                    if alphaA > 200 && alphaB > 200 {
                        painted += 1
                        let lumA = Int(bytes[a]) + Int(bytes[a + 1]) + Int(bytes[a + 2])
                        let lumB = Int(bytes[b]) + Int(bytes[b + 1]) + Int(bytes[b + 2])
                        if abs(lumA - lumB) > 24 { lightDiffers += 1 }
                    }
                }
            }
            #expect(painted > 200, "\(type) paints its body")
            // The same figure (the soft outline leans away from the light, so edges differ a little).
            #expect(abs(coverWest - coverEast) * 25 < coverWest, "\(type)'s facings paint the same figure")
            #expect(lightDiffers * 10 > painted, "\(type)'s east-facing body has its own light, not a mirror of the west's")
        }
    }
}
