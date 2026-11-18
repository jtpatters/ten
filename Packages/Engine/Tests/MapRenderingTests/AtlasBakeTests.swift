import CoreGraphics
import Foundation
import Testing
@testable import MapRendering

/// Packed atlases and their bakes (docs/ART.md §10): every sprite keeps the part of its cell
/// the renderer samples, packed without overlap on the mip alignment, and a bake reads back as
/// exactly the sheet it was made from, or not at all when it was made from other code.
struct AtlasBakeTests {
    private static let decor = SpriteSheet<DecorSprite>()
    private static let units = SpriteSheet<UnitSprite>()
    private static let towns = SpriteSheet<SettlementSprite>()

    private func checkPacking<Key: SpriteSet>(_ sheet: SpriteSheet<Key>) {
        let a = Int32(SpriteSheet<Key>.alignment), g = Float(SpriteSheet<Key>.gutter)
        let windows = Key.all.map { ($0, sheet.windows[$0] ?? .zero) }
        #expect(sheet.width == 2048 && sheet.height % Int(a) == 0)
        for (key, w) in windows {
            #expect(w.x % a == 0 && w.y % a == 0 && w.z % a == 0 && w.w % a == 0 && w.z > 0 && w.w > 0, "\(key) aligned")
            #expect(w.x + w.z <= Int32(sheet.width) && w.y + w.w <= Int32(sheet.height), "\(key) inside the atlas")
            // The window holds the sampled region and its gutter (or reaches the cell's edge).
            if let s = key.sampled, let uv = sheet.uvs[key] {
                let size = Float(key.cellSize)
                let cellX = uv.x * Float(sheet.width), cellY = uv.y * Float(sheet.height)
                let lo = SIMD2(Float(w.x) - cellX, Float(w.y) - cellY), hi = lo + SIMD2(Float(w.z), Float(w.w))
                #expect(lo.x <= max(s.x * size - g, 0) + 1e-3 && lo.y <= max((1 - s.w) * size - g, 0) + 1e-3, "\(key) low side")
                #expect(hi.x >= min(s.z * size + g, size) - 1e-3 && hi.y >= min((1 - s.y) * size + g, size) - 1e-3, "\(key) high side")
            }
        }
        for i in windows.indices {
            for j in windows.indices where j > i {
                let p = windows[i].1, q = windows[j].1
                #expect(!(p.x < q.x + q.z && q.x < p.x + p.z && p.y < q.y + q.w && q.y < p.y + p.w),
                        "\(windows[i].0) and \(windows[j].0) overlap")
            }
        }
    }

    @Test func windowsArePackedAlignedAndApart() {
        checkPacking(Self.decor)
        checkPacking(Self.units)
        checkPacking(Self.towns)
    }

    /// Decorations are trimmed to their paint: every image's quad (its layout) lies inside its
    /// cell's window, gutter included.
    @Test func decorationQuadsStayInTheirWindows() {
        let sheet = Self.decor, g = CGFloat(SpriteSheet<DecorSprite>.gutter)
        for cell in DecorSprite.all {
            guard let w = sheet.windows[cell], let uv = sheet.uvs[cell] else { continue }
            // The window in cell pixels, y down (as layouts are), less its gutter where it does
            // not reach the cell's edge.
            let size = CGFloat(cell.cellSize)
            let x0 = (CGFloat(w.x) - CGFloat(uv.x) * CGFloat(sheet.width)).rounded()
            let y0 = (CGFloat(w.y) - CGFloat(uv.y) * CGFloat(sheet.height)).rounded()
            let x1 = x0 + CGFloat(w.z), y1 = y0 + CGFloat(w.w)
            for art in cell.images {
                let b = DecorSprite.layout(of: art).bounds
                #expect(b.minX >= x0 + (x0 > 0 ? g : 0) - 0.5 && b.minY >= y0 + (y0 > 0 ? g : 0) - 0.5
                        && b.maxX <= x1 - (x1 < size ? g : 0) + 0.5 && b.maxY <= y1 - (y1 < size ? g : 0) + 0.5,
                        "\(art) (\(b)) inside \(cell)'s window")
            }
        }
    }

    private func checkRoundTrip<Key: SpriteSet>(_ sheet: SpriteSheet<Key>) throws {
        let data = try sheet.encoded()
        let read = try SpriteSheet<Key>(decoding: data)
        #expect(read.width == sheet.width && read.height == sheet.height)
        #expect(read.pixels == sheet.pixels)
        #expect(read.uvs == sheet.uvs && read.windows == sheet.windows)
    }

    @Test func bakesReadBackAsTheirSheets() throws {
        _ = Self.decor
        let layouts = DecorSprite.bakeExtras()
        #expect(!layouts.isEmpty)
        try checkRoundTrip(Self.decor)
        #expect(DecorSprite.bakeExtras() == layouts, "the decorations' image layouts come back with it")
        try checkRoundTrip(Self.units)
        try checkRoundTrip(Self.towns)
    }

    /// A bake made from other code (another fingerprint) or damaged is not used: the app paints
    /// the atlas instead.
    @Test func otherCodesBakesAreIgnored() throws {
        var data = try Self.towns.encoded()
        data[data.startIndex + 4] ^= 0xFF // the fingerprint
        #expect(throws: SpriteSheet<SettlementSprite>.BakeError.otherCode) { try SpriteSheet<SettlementSprite>(decoding: data) }
        let whole = try Self.towns.encoded()
        #expect(throws: SpriteSheet<SettlementSprite>.BakeError.self) { try SpriteSheet<SettlementSprite>(decoding: whole.prefix(whole.count - 100)) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-bake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SpriteSheetPainter.loadBake(SettlementSprite.self, from: directory) == nil, "none there")
        try data.write(to: directory.appendingPathComponent(SettlementSprite.bakeName))
        #expect(SpriteSheetPainter.loadBake(SettlementSprite.self, from: directory) == nil, "another code's")
        try whole.write(to: directory.appendingPathComponent(SettlementSprite.bakeName))
        #expect(SpriteSheetPainter.loadBake(SettlementSprite.self, from: directory)?.pixels == Self.towns.pixels)
    }
}
