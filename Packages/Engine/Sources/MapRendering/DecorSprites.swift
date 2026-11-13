import CoreGraphics
import Foundation
import GameCore
import Synchronization

/// Terrain decorations (mountains, hills, trees, plants, rocks), painted procedurally with Core
/// Graphics into their own atlas at startup. Placement lives in `MapRenderer+Decor.swift`,
/// shading (wind, level of detail, cast shadows, fog) in `ShaderDecor.swift`.
///
/// `DecorSprite` is an atlas cell; `DecorArt` is one painted image, which is what placement puts
/// on the map. Most cells hold one image. Low, wide images (hills, ridges) come two to a cell, one
/// above the other, so they keep full resolution across their width. Every image is painted in
/// *painter space*: x in 0...aspect, y in 0...1 (y up), mapped without distortion into its slot.
/// The bake records where each image's painted pixels are (`DecorImageLayout`), so placement can
/// trim every quad to its content, which saves a lot of fill on big sprites.
///
/// Everything follows docs/ART.md: one sun from the upper left, warm highlights, cool blue-violet
/// shadows, a soft warm-dark outline on the silhouette, a contact shadow under the foot and a base
/// that meets the ground on a soft, irregular edge. Mountains and hills also cast a shadow on the
/// ground (a second, flat instance drawn by the shader from the same image).
enum DecorSprite: SpriteSet {
    /// One summit with its shoulders (alpine, frozen and dry rock).
    case peak(MountainStyle, Int)
    /// Desert massifs 2k and 2k + 1, one above the other.
    case mesas(Int)
    /// A low summit, foothill or (desert) a lone butte or spire.
    case shoulder(MountainStyle, Int)
    /// Hills 2k and 2k + 1 of a style, one above the other.
    case hills(HillStyle, Int)
    /// The two small knolls of a style, one above the other.
    case knolls(HillStyle)
    case tree(TreeKind, Int)
    case plant(PlantKind, Int)
    case rock(RockKind, Int)
    /// A patch of lingering snow, laid on tundra hills.
    case snow(Int)
    /// Improvements (shown only on tiles that have them, `DecorFlags.needs`): a mine's
    /// entrance in a hillside, a heap of its spoil, and grazing animals for pastures, each
    /// kind painted facing west (0) and east (1).
    case mine(Int)
    case spoil(Int)
    case animal(AnimalKind, Int)

    /// Mountains by climate: snow-capped grey rock (temperate), heavily snowed peaks (cold), ochre
    /// rock with little snow (dry; the bridge between temperate and desert ranges), red sandstone
    /// massifs, buttes and spires (desert).
    enum MountainStyle: Int, CaseIterable { case alpine, frozen, dry, desert }
    /// Hills by the terrain they stand on (base color from `Palette`).
    enum HillStyle: Int, CaseIterable { case grassy, dry, sandy, tundra, snowy }
    enum TreeKind: Int, CaseIterable { case pine, snowyPine, broadleaf, jungle, palm, datePalm }
    enum PlantKind: Int, CaseIterable { case reeds, fern, shrub, dryGrass, flowers, cactus }
    enum RockKind: Int, CaseIterable { case boulder, sandstone, snowy }
    enum AnimalKind: Int, CaseIterable { case cow, sheep, goat }

    // The atlas is 2048 x 1536: all 32 cells of 256 are used (18 summits, 6 of desert massifs,
    // 8 of hills); 46 of 48 cells of 128 (the last two: mine entrances) and 43 of 64 (spoil
    // heaps and six animals among them).
    /// Summit silhouettes per rock style (none for desert, which has massifs instead).
    static let peakCount = 6
    static let mesaCount = 12
    static func shoulders(_ s: MountainStyle) -> Int { s == .desert ? 3 : 2 }
    static let knollCount = 2
    static let snowCount = 3
    static let mineCount = 2
    static let spoilCount = 2
    static func variants(_ s: HillStyle) -> Int { [4, 4, 4, 2, 2][s.rawValue] }
    static func variants(_ k: TreeKind) -> Int { [6, 5, 7, 5, 4, 3][k.rawValue] }
    static func variants(_ k: PlantKind) -> Int { [4, 3, 4, 3, 3, 4][k.rawValue] }
    static func variants(_ k: RockKind) -> Int { [4, 4, 3][k.rawValue] }

    static var all: [DecorSprite] {
        var cells: [DecorSprite] = []
        for s in MountainStyle.allCases where s != .desert { cells += (0..<peakCount).map { .peak(s, $0) } }
        cells += (0..<mesaCount / 2).map { .mesas($0) }
        for s in HillStyle.allCases { cells += (0..<(variants(s) + 1) / 2).map { .hills(s, $0) } }
        for s in MountainStyle.allCases { cells += (0..<shoulders(s)).map { .shoulder(s, $0) } }
        cells += HillStyle.allCases.map { .knolls($0) }
        for k in TreeKind.allCases { cells += (0..<variants(k)).map { .tree(k, $0) } }
        for k in PlantKind.allCases { cells += (0..<variants(k)).map { .plant(k, $0) } }
        for k in RockKind.allCases { cells += (0..<variants(k)).map { .rock(k, $0) } }
        cells += (0..<snowCount).map { .snow($0) }
        cells += (0..<mineCount).map { .mine($0) }
        cells += (0..<spoilCount).map { .spoil($0) }
        for k in AnimalKind.allCases { cells += [0, 1].map { .animal(k, $0) } }
        return cells
    }

    var cellSize: Int {
        switch self {
        case .peak, .mesas, .hills: 256
        case .shoulder, .knolls, .tree, .mine: 128
        case .plant, .rock, .snow, .spoil, .animal: 64
        }
    }

    /// The images painted into this cell.
    var images: [DecorArt] {
        switch self {
        case let .peak(s, v): [.peak(s, v)]
        case let .mesas(k): [.mesa(2 * k), .mesa(2 * k + 1)]
        case let .shoulder(s, v): [.shoulder(s, v)]
        case let .hills(s, k): (2 * k..<min(2 * k + 2, Self.variants(s))).map { .hill(s, $0) }
        case let .knolls(s): (0..<Self.knollCount).map { .knoll(s, $0) }
        case let .tree(k, v): [.tree(k, v)]
        case let .plant(k, v): [.plant(k, v)]
        case let .rock(k, v): [.rock(k, v)]
        case let .snow(v): [.snow(v)]
        case let .mine(v): [.mine(v)]
        case let .spoil(v): [.spoil(v)]
        case let .animal(k, v): [.animal(k, v)]
        }
    }
}

/// One painted image: what placement puts on the map (see `DecorSprite`).
enum DecorArt: Hashable {
    case peak(DecorSprite.MountainStyle, Int)
    /// A desert massif: tiered mesas, cliff ridges and butte groups.
    case mesa(Int)
    case shoulder(DecorSprite.MountainStyle, Int)
    case hill(DecorSprite.HillStyle, Int)
    case knoll(DecorSprite.HillStyle, Int)
    case tree(DecorSprite.TreeKind, Int)
    case plant(DecorSprite.PlantKind, Int)
    case rock(DecorSprite.RockKind, Int)
    case snow(Int)
    case mine(Int)
    case spoil(Int)
    /// An animal facing west (0) or east (1).
    case animal(DecorSprite.AnimalKind, Int)

    var cell: DecorSprite {
        switch self {
        case let .peak(s, v): .peak(s, v)
        case let .mesa(v): .mesas(v / 2)
        case let .shoulder(s, v): .shoulder(s, v)
        case let .hill(s, v): .hills(s, v / 2)
        case let .knoll(s, _): .knolls(s)
        case let .tree(k, v): .tree(k, v)
        case let .plant(k, v): .plant(k, v)
        case let .rock(k, v): .rock(k, v)
        case let .snow(v): .snow(v)
        case let .mine(v): .mine(v)
        case let .spoil(v): .spoil(v)
        case let .animal(k, v): .animal(k, v)
        }
    }

    /// 0: the whole cell; 1: its upper half; 2: its lower half.
    var slot: Int {
        switch self {
        case let .mesa(v), let .hill(_, v), let .knoll(_, v): 1 + v % 2
        default: 0
        }
    }

    /// A small unique integer per image, below `codeCount`: seeds the painting and indexes
    /// placement lookup tables.
    var code: Int {
        switch self {
        case let .peak(s, v): s.rawValue * 16 + v
        case let .mesa(v): 0x40 + v
        case let .shoulder(s, v): 0x80 + s.rawValue * 16 + v
        case let .hill(s, v): 0x100 + s.rawValue * 16 + v
        case let .knoll(s, v): 0x180 + s.rawValue * 16 + v
        case let .tree(k, v): 0x200 + k.rawValue * 16 + v
        case let .plant(k, v): 0x300 + k.rawValue * 16 + v
        case let .rock(k, v): 0x400 + k.rawValue * 16 + v
        case let .snow(v): 0x480 + v
        case let .mine(v): 0x4A0 + v
        case let .spoil(v): 0x4B0 + v
        case let .animal(k, v): 0x4C0 + k.rawValue * 2 + v
        }
    }

    static let codeCount = 0x500

    /// Every image, for building lookup tables.
    static var all: [DecorArt] { DecorSprite.all.flatMap(\.images) }

    /// Painter-space aspect (width / height) and the foot: the point that stands on the ground.
    /// Below the foot there is only the contact shadow.
    var shape: (aspect: CGFloat, foot: CGPoint) {
        switch self {
        case let .peak(_, v):
            let a = DecorSprite.peakAspect(v)
            return (a, CGPoint(x: a / 2, y: 0.07))
        case .mesa: return (2.0, CGPoint(x: 1.0, y: 0.1))
        case .hill, .knoll: return (2.0, CGPoint(x: 1.0, y: 0.12))
        case let .shoulder(s, _): return s == .desert ? (0.9, CGPoint(x: 0.45, y: 0.08)) : (1.6, CGPoint(x: 0.8, y: 0.1))
        case let .tree(kind, _):
            switch kind {
            case .pine, .snowyPine: return (0.62, CGPoint(x: 0.31, y: 0.06))
            case .broadleaf: return (0.86, CGPoint(x: 0.43, y: 0.06))
            case .jungle: return (1.0, CGPoint(x: 0.5, y: 0.05))
            case .palm, .datePalm: return (0.96, CGPoint(x: 0.48, y: 0.05))
            }
        case let .plant(kind, _):
            switch kind {
            case .reeds: return (0.9, CGPoint(x: 0.45, y: 0.12))
            case .cactus: return (0.8, CGPoint(x: 0.4, y: 0.12))
            default: return (1.4, CGPoint(x: 0.7, y: 0.16))
            }
        case .rock: return (1.4, CGPoint(x: 0.7, y: 0.2))
        case .snow: return (2.0, CGPoint(x: 1.0, y: 0.3))
        case .mine: return (1.3, CGPoint(x: 0.65, y: 0.12))
        case .spoil: return (1.5, CGPoint(x: 0.75, y: 0.18))
        case .animal: return (1.4, CGPoint(x: 0.7, y: 0.14))
        }
    }

    /// Relief images (summits, massifs, buttes, hills, knolls): how tall the painted form rises
    /// above its foot and how far its base reaches to either side, in painter units. Taken from
    /// the same seeded plan the painting follows, so placement (and the ground's relief
    /// footprints) can size and space relief without the atlas.
    var relief: DecorRelief? { DecorRelief.table[code] }
}

/// The size of a relief image in painter units (see `DecorArt.relief`).
struct DecorRelief: Sendable {
    /// Height of the highest summit above the foot.
    var crest: Float
    /// How far the base reaches west and east of the foot.
    var west: Float
    var east: Float
    /// Skyline height above the foot at 17 evenly spaced points from the foot's x -
    /// `halfWidth` to its x + `halfWidth`.
    var profile: [Float]

    /// The larger of `west` and `east`: the half width `profile` spans.
    var halfWidth: Float { max(west, east) }

    /// Skyline height above the foot `u` half widths east of it (-1...1).
    func height(at u: Float) -> Float {
        let t = min(max((u + 1) * 8, 0), 16)
        let i = min(Int(t), 15), f = t - Float(i)
        return profile[i] + (profile[i + 1] - profile[i]) * f
    }

    /// Indexed by `DecorArt.code`.
    static let table: [Int: DecorRelief] = {
        var table: [Int: DecorRelief] = [:]
        for art in DecorArt.all {
            if let relief = DecorSprite.reliefSize(art) { table[art.code] = relief }
        }
        return table
    }()
}

/// Where a painted image sits in its cell, in cell pixels with y down: the box around its
/// painted pixels (plus a little margin), its foot, and pixels per painter unit.
struct DecorImageLayout: Sendable {
    var bounds: CGRect
    var foot: CGPoint
    var unit: CGFloat
}

extension DecorSprite {
    /// Painting the whole set takes a while, so the first `draw` paints every cell in parallel,
    /// each into its own bitmap, and each call then copies its image into the atlas. Images are
    /// handed out once, so nothing stays cached after the atlas is built; only the small
    /// per-image layouts are kept (they are the same every time).
    private static let baked = Mutex<[DecorSprite: CGImage]>([:])
    private static let layouts = Mutex<[Int: DecorImageLayout]>([:])

    func draw(in r: CGRect, ctx: CGContext) {
        let size = CGFloat(cellSize)
        let cell = CGRect(x: r.minX - size / 20, y: r.minY - size / 20, width: size, height: size)
        var image = Self.baked.withLock { $0.removeValue(forKey: self) }
        if image == nil {
            Self.bakeAll()
            image = Self.baked.withLock { $0.removeValue(forKey: self) }
        }
        ctx.saveGState()
        if let image {
            ctx.interpolationQuality = .none
            ctx.draw(image, in: cell)
        } else {
            ctx.translateBy(x: cell.minX, y: cell.minY)
            for art in images { art.paint(in: art.paintRect.rect, ctx: ctx) }
        }
        ctx.restoreGState()
    }

    /// The image's layout as recorded by the bake (untrimmed if it was never baked).
    static func layout(of art: DecorArt) -> DecorImageLayout {
        layouts.withLock { $0[art.code] } ?? art.untrimmedLayout
    }

    private static func bakeAll() {
        let cells = all
        let images = Mutex<[DecorSprite: CGImage]>([:])
        DispatchQueue.concurrentPerform(iterations: cells.count) { k in
            let cell = cells[k], size = cell.cellSize
            guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            var found: [(Int, DecorImageLayout)] = []
            for art in cell.images {
                art.paint(in: art.paintRect.rect, ctx: ctx)
                found.append((art.code, art.measure(ctx)))
            }
            if let image = ctx.makeImage() { images.withLock { $0[cell] = image } }
            layouts.withLock { table in
                for (code, layout) in found { table[code] = layout }
            }
        }
        let done = images.withLock { $0 }
        baked.withLock { $0.merge(done) { a, _ in a } }
    }
}

extension DecorArt {
    /// The image's slot in its cell (pixels, y up), inside a small margin.
    var slotRect: CGRect {
        let size = CGFloat(cell.cellSize), half = size / 2
        let raw = switch slot {
        case 1: CGRect(x: 0, y: half, width: size, height: half)
        case 2: CGRect(x: 0, y: 0, width: size, height: half)
        default: CGRect(x: 0, y: 0, width: size, height: size)
        }
        let margin = max(2, size * 0.03)
        return raw.insetBy(dx: margin, dy: margin)
    }

    /// Painter space inside the slot: as large as fits without distortion, centered.
    var paintRect: (rect: CGRect, unit: CGFloat) {
        let slot = slotRect, aspect = shape.aspect
        let unit = min(slot.width / aspect, slot.height)
        let width = unit * aspect
        return (CGRect(x: slot.minX + (slot.width - width) / 2, y: slot.minY + (slot.height - unit) / 2, width: width, height: unit), unit)
    }

    var untrimmedLayout: DecorImageLayout {
        let size = CGFloat(cell.cellSize), slot = slotRect, (rect, unit) = paintRect, foot = shape.foot
        return DecorImageLayout(bounds: CGRect(x: slot.minX, y: size - slot.maxY, width: slot.width, height: slot.height),
                                foot: CGPoint(x: rect.minX + foot.x * unit, y: size - (rect.minY + foot.y * unit)), unit: unit)
    }

    /// The layout with its bounds trimmed to the pixels this image painted in its slot.
    func measure(_ ctx: CGContext) -> DecorImageLayout {
        var layout = untrimmedLayout
        guard let data = ctx.data else { return layout }
        let size = cell.cellSize, stride = ctx.bytesPerRow / 4
        let px = data.assumingMemoryBound(to: UInt32.self)
        let slot = slotRect
        // Memory row 0 is the top of the cell.
        let r0 = max(0, size - Int(slot.maxY.rounded(.up))), r1 = min(size - 1, size - 1 - Int(slot.minY.rounded(.down)))
        let c0 = max(0, Int(slot.minX.rounded(.down))), c1 = min(size - 1, Int(slot.maxX.rounded(.up)) - 1)
        // RGBA bytes read as a little-endian word: alpha is the high byte. Plain index loops,
        // cheap in debug builds too.
        func ink(_ r: Int, _ c: Int) -> Bool { px[r * stride + c] > 0x03FF_FFFF }
        func rowInk(_ r: Int) -> Bool {
            var c = c0
            while c <= c1 {
                if ink(r, c) { return true }
                c += 1
            }
            return false
        }
        var top = r0
        while top <= r1, !rowInk(top) { top += 1 }
        guard top <= r1 else { return layout }
        var bottom = r1
        while bottom > top, !rowInk(bottom) { bottom -= 1 }
        var left = c1, right = c0
        var r = top
        while r <= bottom {
            var c = c0
            while c < left, !ink(r, c) { c += 1 }
            if c < left { left = c }
            c = c1
            while c > right, !ink(r, c) { c -= 1 }
            if c > right { right = c }
            r += 1
        }
        let pad = 2
        let x0 = max(c0, left - pad), x1 = min(c1, right + pad) + 1
        let y0 = max(r0, top - pad), y1 = min(r1, bottom + pad) + 1
        layout.bounds = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        return layout
    }

    /// Paints the image into `rect` (its painter space, y up) of a cell-sized context.
    func paint(in rect: CGRect, ctx: CGContext) {
        let (aspect, foot) = shape
        ctx.saveGState()
        let c = Canvas(ctx: ctx, rect: rect, aspect: aspect, foot: foot, seed: UInt64(0x2100 + code))
        switch self {
        case .peak, .mesa, .shoulder: DecorSprite.mountain(c, self)
        case .hill, .knoll: DecorSprite.hill(c, self)
        case let .tree(kind, v):
            switch kind {
            case .pine: DecorSprite.pine(c, snowy: false, variant: v)
            case .snowyPine: DecorSprite.pine(c, snowy: true, variant: v)
            case .broadleaf: DecorSprite.broadleaf(c, variant: v)
            case .jungle: DecorSprite.jungleTree(c, variant: v)
            case .palm: DecorSprite.palm(c, date: false, variant: v)
            case .datePalm: DecorSprite.palm(c, date: true, variant: v)
            }
        case let .plant(kind, v):
            switch kind {
            case .reeds: DecorSprite.reeds(c, variant: v)
            case .fern: DecorSprite.fern(c, variant: v)
            case .shrub: DecorSprite.shrub(c, variant: v)
            case .dryGrass: DecorSprite.tuft(c, flowers: false, variant: v)
            case .flowers: DecorSprite.tuft(c, flowers: true, variant: v)
            case .cactus: DecorSprite.cactus(c, variant: v)
            }
        case let .rock(kind, v): DecorSprite.rocks(c, kind: kind, variant: v)
        case let .snow(v): DecorSprite.snowPatch(c, variant: v)
        case let .mine(v): DecorSprite.mineEntrance(c, variant: v)
        case let .spoil(v): DecorSprite.spoilHeap(c, variant: v)
        case let .animal(k, v): DecorSprite.animal(c, kind: k, east: v == 1)
        }
        ctx.restoreGState()
    }
}

// MARK: - Painting toolkit

/// An sRGB color with the art bible's lighting moves: warm highlights, cool blue-violet shadows.
private struct Tone {
    var r: CGFloat, g: CGFloat, b: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Darkest ink: a warm brown-black, never pure black.
    static let ink = Tone(0.13, 0.09, 0.07)
    static let sunlight = Tone(1.0, 0.93, 0.72)
    static let skylight = Tone(0.24, 0.27, 0.50)

    func mix(_ o: Tone, _ t: CGFloat) -> Tone { Tone(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
    func scaled(_ k: CGFloat) -> Tone { Tone(r * k, g * k, b * k) }
    /// Sunlit: brighter and warmer.
    func lit(_ k: CGFloat = 1) -> Tone { mix(.sunlight, 0.22 * k).scaled(1 + 0.2 * k) }
    /// Turned from the sun: darker and cooler.
    func shade(_ k: CGFloat = 1) -> Tone { mix(.skylight, 0.3 * k).scaled(1 - 0.28 * k) }

    func cg(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1), alpha: alpha)
    }
}

/// Seeded dice: the random choices of one image, deterministic per variant.
private class Dice {
    var rng: SplitMix64

    init(seed: UInt64, salt: UInt64) {
        rng = SplitMix64(seed: seed, salts: salt)
    }

    func f(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + (hi - lo) * CGFloat(rng.nextUnit()) }
    func int(_ range: ClosedRange<Int>) -> Int { rng.nextInt(in: range) }
    func chance(_ p: Double) -> Bool { rng.chance(p) }
    func sign() -> CGFloat { rng.chance(0.5) ? -1 : 1 }
}

/// One image being painted: painter space (x 0...aspect, y 0...1, y up) over its rect, plus a
/// seeded RNG so every variant is deterministic.
private final class Canvas: Dice {
    let ctx: CGContext
    let aspect: CGFloat
    let foot: CGPoint
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Toward the light in painter space: the upper left.
    static let light = CGPoint(x: -0.6, y: 0.8)

    init(ctx: CGContext, rect: CGRect, aspect: CGFloat, foot: CGPoint, seed: UInt64) {
        self.ctx = ctx
        self.aspect = aspect
        self.foot = foot
        super.init(seed: seed, salt: 0xA27)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / aspect, y: rect.height)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
    }

    func fill(_ path: CGPath, _ tone: Tone, _ alpha: CGFloat = 1) {
        ctx.addPath(path)
        ctx.setFillColor(tone.cg(alpha))
        ctx.fillPath()
    }

    func stroke(_ path: CGPath, _ tone: Tone, _ alpha: CGFloat = 1, width: CGFloat) {
        ctx.addPath(path)
        ctx.setStrokeColor(tone.cg(alpha))
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    func clip(_ path: CGPath, _ body: () -> Void) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        body()
        ctx.restoreGState()
    }

    /// Paints `body` into its own layer, composited at `alpha` (so overlaps don't double up).
    func layer(alpha: CGFloat = 1, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Paints `body` multiplied over what is already there (shading that keeps the texture).
    func multiply(_ body: () -> Void) {
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    func gradient(_ stops: [(Tone, CGFloat)]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: stops.map { $0.0.cg($0.1) } as CFArray, locations: nil)!
    }

    func linear(_ path: CGPath, _ stops: [(Tone, CGFloat)], from p0: CGPoint, to p1: CGPoint) {
        clip(path) {
            ctx.drawLinearGradient(gradient(stops), start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// Linear gradient over the whole current clip (for callers already clipped to a shape).
    func sweep(_ stops: [(Tone, CGFloat)], from p0: CGPoint, to p1: CGPoint) {
        ctx.drawLinearGradient(gradient(stops), start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Radial gradient around `p`, optionally clipped to `path`; `squash` flattens it vertically.
    func radial(_ path: CGPath?, at p: CGPoint, radius: CGFloat, squash: CGFloat = 1, _ stops: [(Tone, CGFloat)]) {
        ctx.saveGState()
        if let path {
            ctx.addPath(path)
            ctx.clip()
        }
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: 1, y: squash)
        ctx.drawRadialGradient(gradient(stops), startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    /// Soft contact shadow on the ground: darkest at the foot, pushed toward the lower right
    /// (away from the sun). Painted first so the sprite's base sits on it.
    func contactShadow(_ p: CGPoint, width: CGFloat, height: CGFloat, alpha: CGFloat = 0.45) {
        let shadow = Tone(0.09, 0.09, 0.19)
        radial(nil, at: CGPoint(x: p.x + width * 0.14, y: p.y - height * 0.1), radius: width / 2, squash: height / width,
               [(shadow, alpha * 0.75), (shadow, alpha * 0.45), (shadow, 0)])
        radial(nil, at: CGPoint(x: p.x + width * 0.04, y: p.y), radius: width * 0.26, squash: height / width,
               [(shadow, alpha * 0.6), (shadow, 0)])
    }

    /// Paints `body`, then fades it to transparent from y1 (opaque) down to y0: for small sprites
    /// (trunks, stems) that only need their very base softened.
    func fadeBase(_ y0: CGFloat, _ y1: CGFloat, _ body: () -> Void) {
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.saveGState()
        ctx.setBlendMode(.destinationIn)
        ctx.clip(to: CGRect(x: -1, y: -1, width: aspect + 2, height: y1 + 1))
        ctx.drawLinearGradient(gradient([(.ink, 0), (.ink, 1)]), start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                               options: [.drawsBeforeStartLocation])
        ctx.restoreGState()
        ctx.endTransparencyLayer()
    }

    /// Paints `body` (opaque down to its foot), then cuts it along an irregular line at `base`
    /// with a short soft edge above the cut: big sprites meet the ground without a ruler-straight
    /// seam and without a misty fade showing the ground through them. `swell` adds slow
    /// undulation (scree fans and hollows along a long foot), `jag` a finer ragged edge.
    func groundCut(_ base: CGFloat, soft: CGFloat = 0.02, jag: CGFloat = 0.01, swell: CGFloat = 0, _ body: () -> Void) {
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        let n = max(8, Int(aspect / 0.012))
        let walk = bridge(n)
        // The slow undulation: a coarse random walk, smoothly interpolated.
        let knots = max(3, Int(aspect / 0.18)), slow = bridge(knots)
        var line: [CGPoint] = []
        line.reserveCapacity(n + 3)
        var i = 0
        while i <= n {
            let t = CGFloat(i) / CGFloat(n) * CGFloat(knots), k = min(Int(t), knots - 1), u = smoothstep(0, 1, t - CGFloat(k))
            let undulation = (slow[k] + (slow[k + 1] - slow[k]) * u) * swell
            line.append(CGPoint(x: -0.02 + (aspect + 0.04) * CGFloat(i) / CGFloat(n),
                                y: base - jag * 0.4 + walk[i] * jag + undulation + f(-0.002, 0.002)))
            i += 1
        }
        // Fully cut below the line, then three thin, fading cuts above it.
        var k = 0
        while k < 4 {
            let lift = soft * CGFloat(k) / 3
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -1, y: -1))
            for p in line { path.addLine(to: CGPoint(x: p.x, y: p.y + lift)) }
            path.addLine(to: CGPoint(x: aspect + 1, y: -1))
            path.closeSubpath()
            fill(path, .ink, k == 0 ? 1 : 0.24)
            k += 1
        }
        ctx.restoreGState()
        ctx.endTransparencyLayer()
    }

    /// Soft warm-dark silhouette outline: every part is stroked opaque in a layer composited at
    /// `alpha`, before the fills, so only the outer half of the union's edge stays visible.
    func outline(_ paths: [CGPath], width: CGFloat = 0.022, alpha: CGFloat = 0.45) {
        layer(alpha: alpha) {
            for p in paths { ctx.addPath(p) }
            ctx.setStrokeColor(Tone.ink.cg())
            ctx.setLineWidth(width * 2)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    /// An irregular rounded blob (leaf clump, bush, rock lump, snow patch).
    func blob(_ p: CGPoint, _ rx: CGFloat, _ ry: CGFloat, lobes: Int = 8, wobble: CGFloat = 0.15) -> CGMutablePath {
        let phase = f(0, 2 * .pi)
        var pts: [CGPoint] = []
        pts.reserveCapacity(lobes)
        var k = 0
        while k < lobes {
            let t = phase + 2 * .pi * CGFloat(k) / CGFloat(lobes)
            let w = 1 + f(-wobble, wobble)
            pts.append(CGPoint(x: p.x + cos(t) * rx * w, y: p.y + sin(t) * ry * w))
            k += 1
        }
        return smoothClosed(pts)
    }

    /// Random walk pinned to zero at both ends (a Brownian bridge), `steps + 1` values with
    /// roughly unit amplitude: organic wobble for ridges and lines that must hit their endpoints.
    func bridge(_ steps: Int) -> [CGFloat] {
        var walk = [CGFloat](repeating: 0, count: steps + 1)
        var k = 1
        while k <= steps {
            walk[k] = walk[k - 1] + f(-1, 1)
            k += 1
        }
        let end = walk[steps], norm = 1 / CGFloat(max(steps, 1)).squareRoot()
        k = 0
        while k <= steps {
            walk[k] = (walk[k] - end * CGFloat(k) / CGFloat(steps)) * norm
            k += 1
        }
        return walk
    }
}

/// Many small strokes or dabs per tone, each tone painted in one call (much faster than one
/// call per mark).
private struct Marks {
    let paths: [CGMutablePath]
    init(_ tones: Int) { paths = (0..<tones).map { _ in CGMutablePath() } }

    func line(_ tone: Int, _ a: CGPoint, _ b: CGPoint) {
        paths[tone].move(to: a)
        paths[tone].addLine(to: b)
    }

    func curve(_ tone: Int, _ a: CGPoint, _ ctl: CGPoint, _ b: CGPoint) {
        paths[tone].move(to: a)
        paths[tone].addQuadCurve(to: b, control: ctl)
    }

    func dab(_ tone: Int, _ p: CGPoint, _ rx: CGFloat, _ ry: CGFloat) {
        paths[tone].addEllipse(in: CGRect(x: p.x - rx, y: p.y - ry, width: rx * 2, height: ry * 2))
    }

    func poly(_ tone: Int, _ pts: [CGPoint]) {
        paths[tone].addLines(between: pts)
        paths[tone].closeSubpath()
    }

    func stroke(_ c: Canvas, _ tones: [Tone], alpha: CGFloat = 1, width: CGFloat) {
        stroke(c, tones, alphas: tones.map { _ in alpha }, width: width)
    }

    func stroke(_ c: Canvas, _ tones: [Tone], alphas: [CGFloat], width: CGFloat) {
        for (i, tone) in tones.enumerated() where i < paths.count && !paths[i].isEmpty {
            c.stroke(paths[i], tone, alphas[i], width: width)
        }
    }

    func fill(_ c: Canvas, _ tones: [Tone], alpha: CGFloat = 1) {
        for (i, tone) in tones.enumerated() where i < paths.count && !paths[i].isEmpty {
            c.fill(paths[i], tone, alpha)
        }
    }
}

/// Closed Catmull-Rom spline through `p`.
private func smoothClosed(_ p: [CGPoint]) -> CGMutablePath {
    let path = CGMutablePath()
    let n = p.count
    path.move(to: p[0])
    var i = 0
    while i < n {
        let p0 = p[(i + n - 1) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
        path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        i += 1
    }
    path.closeSubpath()
    return path
}

/// Open Catmull-Rom spline through `p`, appended to `path`.
private func smoothOpen(_ p: [CGPoint], into path: CGMutablePath) {
    guard p.count > 1 else { return }
    path.move(to: p[0])
    var i = 0
    while i < p.count - 1 {
        let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
        path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        i += 1
    }
}

private func polygon(_ p: [CGPoint]) -> CGMutablePath {
    let path = CGMutablePath()
    path.addLines(between: p)
    path.closeSubpath()
    return path
}

private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

/// Lighting factor of an offset from a form's center: 1 toward the sun (upper left), -1 away.
private func facing(_ d: CGPoint) -> CGFloat {
    let len = max(hypot(d.x, d.y), 1e-5)
    return (d.x * Canvas.light.x + d.y * Canvas.light.y) / len
}

private func smoothstep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

// MARK: - Mountains

/// Rock and snow colors for one climate. `shadow` is multiplied over faces turned from the sun,
/// so the texture painted beneath keeps showing through. Values keep snow the lightest band
/// (ART.md §2): lit rock well below lit snow, which stays under pure white.
private struct Rock {
    var lit, mid, deep, strata, scree, snowLit, snowShade, shadow: Tone
    /// Snow line of a full peak, in painter units above the foot (nil: bare rock).
    var snowLine: ClosedRange<CGFloat>?
    var heavySnow = false
    /// Sedimentary rock shows bedding planes; crystalline alpine rock only ribs and joints.
    var bedded = false

    static let alpine = Rock(lit: Tone(0.70, 0.66, 0.60), mid: Tone(0.49, 0.47, 0.48), deep: Tone(0.22, 0.23, 0.34),
                             strata: Tone(0.34, 0.31, 0.33), scree: Tone(0.63, 0.60, 0.55),
                             snowLit: Tone(0.95, 0.94, 0.90), snowShade: Tone(0.62, 0.69, 0.87), shadow: Tone(0.50, 0.53, 0.77),
                             snowLine: 0.5...0.62)
    static let frozen = Rock(lit: Tone(0.66, 0.67, 0.71), mid: Tone(0.45, 0.47, 0.53), deep: Tone(0.20, 0.23, 0.36),
                             strata: Tone(0.32, 0.33, 0.40), scree: Tone(0.60, 0.62, 0.66),
                             snowLit: Tone(0.95, 0.95, 0.93), snowShade: Tone(0.62, 0.70, 0.88), shadow: Tone(0.50, 0.55, 0.80),
                             snowLine: 0.18...0.3, heavySnow: true)
    static let dry = Rock(lit: Tone(0.80, 0.69, 0.53), mid: Tone(0.60, 0.50, 0.41), deep: Tone(0.29, 0.24, 0.31),
                          strata: Tone(0.46, 0.36, 0.30), scree: Tone(0.74, 0.64, 0.50),
                          snowLit: Tone(0.95, 0.93, 0.88), snowShade: Tone(0.66, 0.70, 0.86), shadow: Tone(0.58, 0.51, 0.74),
                          snowLine: 0.72...0.8, bedded: true)
    static let desert = Rock(lit: Tone(0.93, 0.66, 0.44), mid: Tone(0.78, 0.47, 0.33), deep: Tone(0.36, 0.20, 0.27),
                             strata: Tone(0.60, 0.30, 0.22), scree: Tone(0.88, 0.72, 0.53),
                             snowLit: Tone(0.95, 0.93, 0.88), snowShade: Tone(0.80, 0.76, 0.86), shadow: Tone(0.60, 0.46, 0.68))

    static func of(_ style: DecorSprite.MountainStyle) -> Rock {
        switch style {
        case .alpine: .alpine
        case .frozen: .frozen
        case .dry: .dry
        case .desert: .desert
        }
    }
}

/// How a climate's rock weathers: the shape language of its skylines.
private struct Weathering {
    /// Peak flank profile (1 - t)^concave: above 1 a steep crest over a broad foot.
    var concave: CGFloat = 1.15
    /// Skyline irregularity: broad wander, angular crags, and how many shoulders or pinnacles
    /// break each summit's flanks.
    var wander: CGFloat
    var crag: CGFloat
    var knobs: ClosedRange<Int> = 0...0
    /// Ledges: how strongly slopes break into benches and cliffs, and their spacing.
    var terrace: CGFloat = 0
    var step: CGFloat = 0.07

    static let alpine = Weathering(concave: 1.45, wander: 0.045, crag: 0.02, knobs: 1...2)
    static let frozen = Weathering(concave: 1.2, wander: 0.035, crag: 0.012, knobs: 0...1)
    static let dry = Weathering(concave: 1.35, wander: 0.05, crag: 0.026, knobs: 1...3)
    static let sandstone = Weathering(concave: 1.0, wander: 0.016, crag: 0.009, knobs: 0...0, terrace: 0.35, step: 0.075)
}

/// One summit: apex, half widths of its west and east flanks, and an optional flat top (as a
/// fraction of the half widths). `wall` > 0 makes it a butte: a flat top, a near-vertical wall
/// over a run of `wall` (fraction of the half width), and a talus skirt from `talus` of the
/// height down to the ground.
private struct Summit {
    var x: CGFloat, y: CGFloat, west: CGFloat, east: CGFloat
    var plateau: CGFloat = 0
    var wall: CGFloat = 0
    var talus: CGFloat = 0.3
    /// Overrides the layer's flank profile.
    var concave: CGFloat? = nil
    /// A rounded dome, (1 - t^2)^1.6, instead of a concave peak.
    var bell = false
    /// A sheer east face: the east flank drops as a cliff over this fraction of its run, then
    /// runs out in a talus slope from `talus` of the height.
    var eastCliff: CGFloat = 0
    /// Pinnacles along the east ridge: a serrated crest.
    var teeth = 0

    /// Kept inside the cell; peaks no steeper than the rock can stand.
    func fitted(aspect a: CGFloat, base: CGFloat) -> Summit {
        var s = self
        s.west = max(0.02, min(west, x - 0.01))
        s.east = max(0.02, min(east, a - 0.01 - x))
        if wall == 0 && eastCliff == 0 { s.y = min(y, base + 2.4 * min(s.west, s.east) * (1 + plateau)) }
        return s
    }

    /// Skyline height of this summit at `x` (`base` beyond its foot).
    func height(at x: CGFloat, base: CGFloat, concave: CGFloat) -> CGFloat {
        var t = abs(x - self.x) / (x < self.x ? west : east)
        guard t < 1 else { return base }
        let rise = y - base
        if wall > 0 {
            if t <= plateau { return y }
            if t < plateau + wall { return y - rise * (1 - talus) * pow((t - plateau) / wall, 0.8) }
            let w = (t - plateau - wall) / max(1 - plateau - wall, 0.01)
            return base + rise * talus * pow(1 - w, 1.7)
        }
        if eastCliff > 0, x > self.x {
            if t < eastCliff { return y - rise * (1 - talus) * pow(t / eastCliff, 0.7) }
            let w = (t - eastCliff) / max(1 - eastCliff, 0.01)
            return base + rise * talus * pow(1 - w, 1.5)
        }
        t = max(0, t - plateau) / (1 - plateau)
        if bell { return base + rise * pow(max(0, 1 - t * t), 1.6) }
        return base + rise * pow(1 - t, self.concave ?? concave)
    }
}

/// A face turned from the sun: shaded fully down to `fadeTop`, fading out by `fadeBottom`;
/// reflected light lifts it from the spur (`from`) toward the gully (`to`).
private struct Facet {
    var path: CGMutablePath
    var from: CGFloat, to: CGFloat
    var fadeTop: CGFloat, fadeBottom: CGFloat
}

/// One skyline of a mountain image. Every peak of the skyline sends a spur down toward the viewer
/// and every col a gully; the face east of a spur, up to the next gully, faces away from the sun.
/// Spurs and gullies stop partway down: below them the slopes merge into one apron.
private struct RangeLayer {
    var skyline: [CGPoint]
    var silhouette: CGMutablePath
    var spurs: [[CGPoint]] = []
    var gullies: [[CGPoint]] = []
    var facets: [Facet] = []
    var top: CGFloat
    /// x of the highest peak.
    var crest: CGFloat
    /// Bench heights (terraced rock only).
    var ledges: [CGFloat] = []

    var minX: CGFloat { skyline[0].x }
    var maxX: CGFloat { skyline[skyline.count - 1].x }

    func height(at x: CGFloat) -> CGFloat {
        let t = (x - minX) / max(maxX - minX, 1e-4) * CGFloat(skyline.count - 1)
        let i = min(max(Int(t), 0), skyline.count - 2)
        let f = min(max(t - CGFloat(i), 0), 1)
        return skyline[i].y + (skyline[i + 1].y - skyline[i].y) * f
    }
}

/// The folds a rock texture carves into a layer: the rib lines falling from its skyline and the
/// narrow faces beside them (shaded east of a rib on the sunlit flank, lit west of it on the
/// shaded flank). Snow lies in the hollows between the ribs and keeps their relief.
private struct Folds {
    var ribs: [[CGPoint]] = []
    var shaded = CGMutablePath(), lit = CGMutablePath()
}

/// The layers of one mountain image, back to front.
private struct MountainLayerPlan {
    var summits: [Summit]
    var weathering: Weathering
    /// Behind the front layer: painted a little darker and cooler, as if in its shadow.
    var back = false
}

extension DecorSprite {
    /// A line from `top` down to `bottom`, drifting to `endX`, wandering a little.
    private static func fallLine(_ c: Canvas, from top: CGPoint, toX endX: CGFloat, bottom: CGFloat, wander: CGFloat) -> [CGPoint] {
        let steps = max(4, Int((top.y - bottom) / 0.03))
        let wobble = c.bridge(steps)
        var line: [CGPoint] = []
        line.reserveCapacity(steps + 1)
        var i = 0
        while i <= steps {
            let t = CGFloat(i) / CGFloat(steps)
            line.append(CGPoint(x: top.x + (endX - top.x) * pow(t, 1.3) + wobble[i] * wander, y: top.y + (bottom - top.y) * t))
            i += 1
        }
        return line
    }

    /// Builds one skyline from overlapping summits (the highest flank wins at every x), breaks
    /// it with shoulders, pinnacles, ledges, a broad wander and angular crags (all fading out
    /// toward the calm foot), then finds its peaks and cols and cuts the facets.
    private static func rangeLayer(_ c: Canvas, _ summits: [Summit], base: CGFloat, _ w: Weathering) -> RangeLayer {
        let minX = max(0.005, summits.map { $0.x - $0.west }.min() ?? 0)
        let maxX = min(c.aspect - 0.005, summits.map { $0.x + $0.east }.max() ?? c.aspect)
        let n = max(40, Int((maxX - minX) / 0.005))
        let peak = summits.map(\.y).max() ?? base + 0.5

        // Shoulders (broad, low) and pinnacles (narrow, sharp) along the flanks.
        struct Knob { var x, h, w: CGFloat }
        var knobs: [Knob] = []
        for s in summits where s.y - base > 0.15 && s.wall == 0 {
            for _ in 0..<c.int(w.knobs) {
                let east = c.chance(0.5), t = c.f(0.2, 0.72)
                let x = s.x + (east ? s.east : -s.west) * (s.plateau + (1 - s.plateau) * t)
                knobs.append(c.chance(0.4) ? Knob(x: x, h: c.f(0.022, 0.045), w: c.f(0.016, 0.03))
                                           : Knob(x: x, h: c.f(0.02, 0.05), w: c.f(0.06, 0.12)))
            }
            // A serrated crest: sharp pinnacles of uneven size and spacing down the east ridge.
            var k = 0
            while k < s.teeth {
                let t = 0.16 + 0.66 * (CGFloat(k) + c.f(0.15, 0.85)) / CGFloat(s.teeth)
                knobs.append(Knob(x: s.x + s.east * t, h: c.f(0.035, 0.07) * (1 - 0.4 * t), w: c.f(0.016, 0.03)))
                k += 1
            }
        }
        // The per-sample loops below are index loops rather than ranges, maps or closures: all
        // sprites bake in parallel at setup, and in debug builds range iteration goes through a
        // locked runtime metadata cache that the threads contend on.
        let wander = c.bridge(n)
        var crags = [CGFloat](repeating: 0, count: n + 1)
        var i0 = 0, o0: CGFloat = 0
        while i0 < n {
            let i1 = min(n, i0 + c.int(3...9)), o1: CGFloat = i1 == n ? 0 : c.f(-1, 1)
            var i = i0
            while i <= i1 {
                crags[i] = o0 + (o1 - o0) * CGFloat(i - i0) / CGFloat(i1 - i0)
                i += 1
            }
            i0 = i1
            o0 = o1
        }
        let phase = c.f(0, w.step)
        var sky: [CGPoint] = []
        sky.reserveCapacity(n + 1)
        var i = 0
        while i <= n {
            let x = minX + (maxX - minX) * CGFloat(i) / CGFloat(n)
            var u = -CGFloat.infinity
            var k = 0
            while k < summits.count {
                u = max(u, summits[k].height(at: x, base: base, concave: w.concave))
                k += 1
            }
            u -= base
            if w.terrace > 0, u > 0.01 {
                // Benches and cliffs: most of each step is a gentle ledge, then a cliff.
                let q = (u + phase) / w.step, k = q.rounded(.down)
                let stair = (k + smoothstep(0.62, 1, q - k)) * w.step - phase
                u += (max(stair, 0) - u) * w.terrace
            }
            if u > 0.02 {
                k = 0
                while k < knobs.count {
                    let knob = knobs[k]
                    u += knob.h * pow(max(0, 1 - abs(x - knob.x) / knob.w), 1.3)
                    k += 1
                }
            }
            let rise = min(1, u / max(peak - base, 0.01) * 2.5)
            u += (wander[i] * w.wander + crags[i] * w.crag) * rise
            sky.append(CGPoint(x: x, y: base + max(u, 0)))
            i += 1
        }
        let bottom = base - 0.1
        let top = sky.map(\.y).max() ?? peak
        var layer = RangeLayer(skyline: sky, silhouette: polygon(sky + [CGPoint(x: maxX, y: bottom), CGPoint(x: minX, y: bottom)]),
                               top: top, crest: sky.first { $0.y == top }?.x ?? (minX + maxX) / 2)
        if w.terrace > 0 {
            var y = base + w.step - phase
            while y < peak {
                layer.ledges.append(y)
                y += w.step
            }
        }

        // Peaks: local maxima, merged until each stands clear of the cols beside it (the weakest
        // goes first; its two cols merge into the lower one).
        var peaks: [Int] = []
        i = 1
        while i < n {
            if sky[i].y > base + 0.04 {
                var top = true
                var j = max(0, i - 4)
                let last = min(n, i + 4)
                while j <= last {
                    if sky[j].y > sky[i].y { top = false }
                    j += 1
                }
                if top, peaks.isEmpty || i - peaks[peaks.count - 1] > 4 { peaks.append(i) }
            }
            i += 1
        }
        guard !peaks.isEmpty else { return layer }
        var cols: [Int] = []
        for k in 1..<max(peaks.count, 1) {
            var low = peaks[k - 1], j = peaks[k - 1]
            while j <= peaks[k] {
                if sky[j].y < sky[low].y { low = j }
                j += 1
            }
            cols.append(low)
        }
        func prominence(_ k: Int) -> CGFloat {
            let west = k > 0 ? sky[cols[k - 1]].y : base
            let east = k < cols.count ? sky[cols[k]].y : base
            return sky[peaks[k]].y - max(west, east)
        }
        while peaks.count > 1 {
            var weakest = 0
            for k in 1..<peaks.count where prominence(k) < prominence(weakest) { weakest = k }
            guard prominence(weakest) < 0.025 else { break }
            if weakest == 0 {
                cols.removeFirst()
            } else if weakest == peaks.count - 1 {
                cols.removeLast()
            } else {
                if sky[cols[weakest]].y < sky[cols[weakest - 1]].y { cols[weakest - 1] = cols[weakest] }
                cols.remove(at: weakest)
            }
            peaks.remove(at: weakest)
        }
        let proms = peaks.indices.map(prominence)

        for (k, p0) in peaks.enumerated() {
            // A flat top turns away from the sun at its east rim: once the top proves flat, the
            // walk east tolerates the small dips of weathered caprock and stops at the wall.
            var e = p0
            while e < n, sky[e + 1].y > sky[p0].y - 0.014, e - p0 < n / 3 { e += 1 }
            let flat = e - p0 > 6
            if flat { while e < n, sky[e + 1].y > sky[p0].y - 0.04 { e += 1 } }
            let apex = sky[e]
            let end = proms[k] > 0.12 ? base + (apex.y - base) * c.f(0.12, 0.3)
                : apex.y - min(apex.y - base - 0.02, max(0.06, proms[k] * c.f(1.6, 2.6)))
            let room = (k < cols.count ? sky[cols[k]].x : maxX + 0.1) - apex.x
            let drift = flat ? c.f(-0.005, 0.012) : min((apex.y - end) * c.f(0.18, 0.4), room * 0.55)
            layer.spurs.append(fallLine(c, from: apex, toX: apex.x + drift, bottom: end, wander: flat ? 0.004 : 0.009))
        }
        for (k, ci) in cols.enumerated() {
            let p = sky[ci]
            let depth = min(p.y - base - 0.01, min(proms[k], proms[k + 1]) * c.f(1.2, 2.0) + 0.04)
            layer.gullies.append(fallLine(c, from: p, toX: p.x + c.f(-0.02, 0.03), bottom: p.y - max(depth, 0.02), wander: 0.01))
        }
        for (k, spur) in layer.spurs.enumerated() {
            let spurEnd = spur[spur.count - 1]
            let right = k < layer.gullies.count ? layer.gullies[k]
                : [CGPoint(x: maxX + 0.2, y: 1.3), CGPoint(x: maxX + 0.2, y: spurEnd.y)]
            let rightEnd = right[right.count - 1]
            // The shade carries on well below the spur's end, so the faces turned from the sun
            // read as one dark plane down to the apron: the face runs on to the foot along the
            // spur's and the gully's lines carried on straight, and fades out on the way rather
            // than ending on a line between them.
            func carried(_ line: [CGPoint]) -> CGPoint {
                let a = line[max(line.count - 2, 0)], b = line[line.count - 1]
                let slope = (b.x - a.x) / max(a.y - b.y, 1e-3)
                return CGPoint(x: b.x + slope * (b.y - bottom), y: bottom)
            }
            let rightFoot = carried(right)
            var spurFoot = carried(spur)
            spurFoot.x = min(spurFoot.x, rightFoot.x - 0.01)
            let path = polygon(spur + [spurFoot, rightFoot] + right.reversed() + [CGPoint(x: right[0].x, y: 1.3), CGPoint(x: spur[0].x, y: 1.3)])
            let low = min(spurEnd.y, rightEnd.y)
            layer.facets.append(Facet(path: path, from: spur[0].x, to: min(right[0].x, maxX),
                                      fadeTop: max(spurEnd.y, rightEnd.y) + 0.04, fadeBottom: base + (low - base) * 0.3))
        }
        return layer
    }

    /// Width / height of each summit silhouette (narrow ones keep the most resolution for the
    /// tallest summits).
    static func peakAspect(_ v: Int) -> CGFloat { [1.15, 1.4, 1.25, 1.35, 1.1, 1.45][v % 6] }

    /// A mountain image: a summit, a low shoulder, a desert massif or a lone butte or spire.
    fileprivate static func mountain(_ c: Canvas, _ art: DecorArt) {
        let base = c.foot.y
        guard let (style, plan) = reliefPlan(art, aspect: c.aspect, base: base) else { return }
        let rock = Rock.of(style)
        let layers = plan.map { rangeLayer(c, $0.summits.map { $0.fitted(aspect: c.aspect, base: base) }, base: base, $0.weathering) }
        let crest = (layers.map(\.top).max() ?? base + 0.5) - base
        // Snow lies above a share of the summit's height: low on frozen rock, high on dry rock.
        // Shoulders stand below the snow line except in the cold.
        var snowLine = rock.snowLine.map { base + crest * c.f($0.lowerBound, $0.upperBound) }
        if case .shoulder = art { snowLine = style == .frozen ? base + crest * c.f(0.4, 0.55) : nil }
        // The low form of each summit (odd variants, placed below the high summits of a range)
        // carries at most a small cap outside the cold, so snow marks the spine of a range.
        if case let .peak(_, v) = art, v % 2 == 1, style != .frozen { snowLine = style == .alpine ? base + crest * c.f(0.78, 0.86) : nil }
        let west = layers.map(\.minX).min() ?? 0, east = layers.map(\.maxX).max() ?? c.aspect
        c.contactShadow(CGPoint(x: (west + east) / 2, y: base), width: (east - west) * 0.9, height: style == .desert ? 0.1 : 0.07, alpha: 0.42)
        c.groundCut(base, soft: 0.03, jag: style == .desert ? 0.014 : 0.01, swell: 0.022) {
            c.outline(layers.map(\.silhouette), width: 0.015)
            for (i, layer) in layers.enumerated() {
                if i > 0 { c.stroke(layer.silhouette, .ink, 0.3, width: 0.007) } // edge over the layer behind
                paintLayer(c, layer, plan[i], rock: rock, base: base, snowLine: snowLine, heavySnow: rock.heavySnow,
                           sandstone: style == .desert)
            }
            rubble(c, from: west, to: east, base: base, rock: rock)
        }
    }

    /// The style and layers of a mountain image, from its own seeded dice (separate from the
    /// painting's), so placement can measure it without painting it.
    private static func reliefPlan(_ art: DecorArt, aspect a: CGFloat, base: CGFloat) -> (MountainStyle, [MountainLayerPlan])? {
        let d = Dice(seed: UInt64(0x2100 + art.code), salt: 0x51A)
        switch art {
        case let .peak(style, v): return (style, [peakPlan(d, style: style, variant: v, aspect: a, base: base)])
        case let .shoulder(style, v):
            return (style, [style == .desert ? accentPlan(d, variant: v, aspect: a, base: base)
                                             : shoulderPlan(d, style: style, variant: v, aspect: a, base: base)])
        case let .mesa(v): return (.desert, [mesaPlan(d, variant: v, aspect: a, base: base)])
        default: return nil
        }
    }

    /// The size of a relief image (see `DecorArt.relief`).
    static func reliefSize(_ art: DecorArt) -> DecorRelief? {
        let (aspect, foot) = art.shape
        switch art {
        case .peak, .mesa, .shoulder:
            guard let (_, plan) = reliefPlan(art, aspect: aspect, base: foot.y) else { return nil }
            let layers = plan.map { ($0.weathering.concave, $0.summits.map { $0.fitted(aspect: aspect, base: foot.y) }) }
            let summits = layers.flatMap(\.1)
            let crest = (summits.map(\.y).max() ?? foot.y + 0.5) - foot.y
            let west = summits.map { $0.x - $0.west }.min() ?? 0, east = summits.map { $0.x + $0.east }.max() ?? aspect
            let half = max(foot.x - west, east - foot.x)
            let samples = (0...16).map { k -> Float in
                let x = foot.x + half * (CGFloat(k) / 8 - 1)
                var top: CGFloat = 0
                for (concave, list) in layers {
                    for s in list { top = max(top, s.height(at: x, base: foot.y, concave: concave) - foot.y) }
                }
                return Float(top)
            }
            return DecorRelief(crest: Float(crest), west: Float(foot.x - west), east: Float(east - foot.x), profile: samples)
        case let .hill(style, v), let .knoll(style, v):
            let knoll: Bool
            if case .knoll = art { knoll = true } else { knoll = false }
            let plan = hillPlan(style: style, variant: v, knoll: knoll, code: art.code, aspect: aspect)
            let half = plan.halfWidth
            let samples = (0...16).map { k in Float(plan.surface(foot.x + half * (CGFloat(k) / 8 - 1))) }
            let west = plan.bumps.map { $0.x - $0.west }.min() ?? foot.x, east = plan.bumps.map { $0.x + $0.east }.max() ?? foot.x
            return DecorRelief(crest: Float(plan.crest), west: Float(foot.x - west), east: Float(east - foot.x), profile: samples)
        default:
            return nil
        }
    }

    /// One summit per image, each a different silhouette; ranges come from overlapping many of
    /// them. Placement pairs them in threes (0-1, 2-3, 4-5) and uses the first of each pair for
    /// the tallest summits: 0 a horn (a sharp apex over concave flanks, a shoulder low on its
    /// east ridge), 1 a broad dome, 2 a long sunlit west ridge up to a summit that drops in a
    /// sheer shaded east face, 3 a saddle between two summits, 4 a needle over a lower
    /// shoulder, 5 a serrated crest stepping down east from its summit.
    private static func peakPlan(_ d: Dice, style: MountainStyle, variant v: Int, aspect a: CGFloat, base: CGFloat) -> MountainLayerPlan {
        let w: Weathering = style == .frozen ? .frozen : (style == .dry ? .dry : .alpine)
        let lift = 0.86 - base
        func s(_ x: CGFloat, _ h: CGFloat, _ west: CGFloat, _ east: CGFloat, concave: CGFloat? = nil) -> Summit {
            Summit(x: a * x, y: base + lift * h, west: a * west, east: a * east, concave: concave)
        }
        var summits: [Summit]
        switch v % 6 {
        case 0:
            let x = d.f(0.44, 0.5)
            summits = [s(x, 1, d.f(0.4, 0.44), d.f(0.44, 0.48), concave: 1.75),
                       s(x + d.f(0.2, 0.25), d.f(0.48, 0.58), d.f(0.13, 0.16), d.f(0.17, 0.2)),
                       s(x - d.f(0.24, 0.3), d.f(0.34, 0.42), d.f(0.12, 0.15), d.f(0.12, 0.15))]
        case 1:
            var dome = s(0.5 + d.f(-0.03, 0.03), d.f(0.84, 0.9), d.f(0.44, 0.47), d.f(0.44, 0.47))
            dome.bell = true
            summits = [dome, s(d.f(0.2, 0.26), d.f(0.48, 0.56), d.f(0.12, 0.16), d.f(0.14, 0.18))]
        case 2:
            let x = d.f(0.58, 0.63)
            var main = s(x, 1, d.f(0.54, 0.58), d.f(0.3, 0.34), concave: 1.3)
            main.eastCliff = d.f(0.24, 0.32)
            main.talus = d.f(0.36, 0.44)
            summits = [main, s(x - d.f(0.3, 0.36), d.f(0.5, 0.6), d.f(0.15, 0.18), d.f(0.12, 0.15))]
        case 3:
            let westHigher = d.chance(0.5)
            summits = [s(d.f(0.28, 0.32), westHigher ? 1 : d.f(0.82, 0.9), d.f(0.26, 0.3), d.f(0.24, 0.28), concave: 1.55),
                       s(d.f(0.68, 0.72), westHigher ? d.f(0.82, 0.9) : 1, d.f(0.24, 0.28), d.f(0.26, 0.3), concave: 1.55)]
        case 4:
            let x = d.f(0.52, 0.57)
            summits = [s(x, 1, d.f(0.36, 0.4), d.f(0.36, 0.4), concave: 2.1),
                       s(x - d.f(0.26, 0.3), d.f(0.5, 0.58), d.f(0.15, 0.18), d.f(0.13, 0.16)),
                       s(x + d.f(0.22, 0.27), d.f(0.3, 0.38), d.f(0.1, 0.13), d.f(0.12, 0.15))]
        default:
            var main = s(d.f(0.3, 0.35), d.f(0.94, 1), d.f(0.27, 0.3), d.f(0.62, 0.66), concave: 1.25)
            main.teeth = d.int(4...6)
            summits = [main]
        }
        return MountainLayerPlan(summits: summits, weathering: w)
    }

    /// Low summits that fill the gaps in a range and step it down to open land: 0 a rounded
    /// double shoulder, 1 a low craggy ridge.
    private static func shoulderPlan(_ d: Dice, style: MountainStyle, variant v: Int, aspect a: CGFloat, base: CGFloat) -> MountainLayerPlan {
        let w: Weathering = style == .frozen ? .frozen : (style == .dry ? .dry : .alpine)
        let lift = 0.62 - base
        func s(_ x: CGFloat, _ h: CGFloat, _ west: CGFloat, _ east: CGFloat, concave: CGFloat) -> Summit {
            Summit(x: a * x, y: base + lift * h, west: a * west, east: a * east, concave: concave)
        }
        if v % 2 == 0 {
            return MountainLayerPlan(summits: [s(d.f(0.33, 0.38), 1, d.f(0.3, 0.33), d.f(0.28, 0.32), concave: 1.3),
                                               s(d.f(0.64, 0.7), d.f(0.7, 0.82), d.f(0.26, 0.3), d.f(0.27, 0.3), concave: 1.25)],
                                     weathering: w)
        }
        var main = s(d.f(0.38, 0.44), 1, d.f(0.34, 0.37), d.f(0.5, 0.54), concave: 1.4)
        main.teeth = 3
        return MountainLayerPlan(summits: [main], weathering: w)
    }

    /// Desert accents standing alone or at a massif's flank: 0 a tall narrow butte, 1 a spire
    /// on its talus cone, 2 a small two-tiered butte.
    private static func accentPlan(_ d: Dice, variant v: Int, aspect a: CGFloat, base: CGFloat) -> MountainLayerPlan {
        func butte(_ x: CGFloat, _ h: CGFloat, _ half: CGFloat, top: CGFloat, wall: CGFloat, talus: CGFloat) -> Summit {
            Summit(x: a * x, y: base + h, west: a * half * d.f(0.92, 1.08), east: a * half * d.f(0.92, 1.08),
                   plateau: top, wall: wall, talus: talus * d.f(0.9, 1.1))
        }
        let summits: [Summit]
        switch v % 3 {
        case 0:
            summits = [butte(0.48, d.f(0.7, 0.78), d.f(0.3, 0.34), top: d.f(0.4, 0.5), wall: 0.16, talus: 0.36)]
        case 1:
            summits = [butte(0.5, d.f(0.18, 0.24), 0.46, top: 0.3, wall: 0.1, talus: 0.7),
                       butte(0.5 + d.f(-0.04, 0.04), d.f(0.78, 0.86), d.f(0.13, 0.15), top: 0.3, wall: 0.45, talus: 0.25)]
        default:
            summits = [butte(0.5, d.f(0.34, 0.4), d.f(0.44, 0.47), top: 0.62, wall: 0.1, talus: 0.5),
                       butte(0.46 + d.f(-0.04, 0.04), d.f(0.6, 0.68), d.f(0.22, 0.26), top: 0.5, wall: 0.14, talus: 0.5)]
        }
        return MountainLayerPlan(summits: summits, weathering: .sandstone)
    }

    /// Desert massifs of red sandstone: wide flat-topped forms with sheer walls (lit to the
    /// west, shaded east) over talus skirts, tiered and eroded rather than boxes. Six families,
    /// each painted twice with its high part on either side: a grand tiered mesa, a cliff ridge
    /// cut by a notch, two buttes on a shared talus base, a cuesta stepping down, a mesa with a
    /// spire at its end, and a stepped pyramid.
    private static func mesaPlan(_ d: Dice, variant v: Int, aspect a: CGFloat, base: CGFloat) -> MountainLayerPlan {
        let flip = v >= 6
        func butte(_ x: CGFloat, _ h: CGFloat, _ half: CGFloat, top: CGFloat, wall: CGFloat = 0.1, talus: CGFloat = 0.45) -> Summit {
            // Tops a little narrower and talus aprons a little higher than drawn up: eroded forms
            // on scree skirts rather than boxes standing on the sand.
            Summit(x: a * (flip ? 1 - x : x), y: base + h * d.f(0.94, 1.06), west: a * half * d.f(0.92, 1.08),
                   east: a * half * d.f(0.92, 1.08), plateau: top * 0.84, wall: wall, talus: min(0.72, talus * 1.15 * d.f(0.88, 1.12)))
        }
        let summits: [Summit]
        switch v % 6 {
        case 0:
            summits = [butte(0.5, 0.36, 0.45, top: 0.72, wall: 0.08, talus: 0.45),
                       butte(d.f(0.38, 0.44), 0.6, 0.23, top: 0.55, wall: 0.12, talus: 0.5)]
        case 1:
            summits = [butte(0.29, 0.56, 0.25, top: 0.62, wall: 0.12, talus: 0.4),
                       butte(0.7, 0.46, 0.26, top: 0.6, wall: 0.12, talus: 0.4),
                       butte(0.5, 0.24, 0.46, top: 0.82, wall: 0.06, talus: 0.6)]
        case 2:
            summits = [butte(0.3, 0.64, 0.15, top: 0.4, wall: 0.18, talus: 0.36),
                       butte(0.63, 0.48, 0.2, top: 0.5, wall: 0.14, talus: 0.4),
                       butte(0.47, 0.16, 0.45, top: 0.5, wall: 0.08, talus: 0.7)]
        case 3:
            summits = [butte(0.3, 0.6, 0.27, top: 0.6, wall: 0.12, talus: 0.42),
                       butte(0.54, 0.44, 0.28, top: 0.62, wall: 0.1, talus: 0.45),
                       butte(0.76, 0.28, 0.2, top: 0.55, wall: 0.1, talus: 0.5)]
        case 4:
            summits = [butte(0.4, 0.42, 0.36, top: 0.7, wall: 0.1, talus: 0.45),
                       butte(0.81, 0.72, 0.065, top: 0.22, wall: 0.45, talus: 0.3),
                       butte(0.8, 0.16, 0.16, top: 0.3, wall: 0.1, talus: 0.7)]
        default:
            summits = [butte(0.5, 0.24, 0.46, top: 0.76, wall: 0.08, talus: 0.6),
                       butte(0.5 + d.f(-0.04, 0.04), 0.44, 0.3, top: 0.6, wall: 0.1, talus: 0.55),
                       butte(0.5 + d.f(-0.06, 0.06), 0.64, 0.14, top: 0.45, wall: 0.14, talus: 0.5)]
        }
        return MountainLayerPlan(summits: summits, weathering: .sandstone)
    }

    private static func paintLayer(_ c: Canvas, _ layer: RangeLayer, _ plan: MountainLayerPlan, rock r: Rock, base: CGFloat,
                                   snowLine: CGFloat?, heavySnow: Bool, sandstone: Bool) {
        let top = layer.top, height = top - base
        c.clip(layer.silhouette) {
            // Sunlit rock, warmer toward the top.
            c.sweep([(r.lit.lit(0.5), 1), (r.lit, 1), (r.mid, 1)], from: CGPoint(x: layer.crest - height * 0.3, y: top),
                     to: CGPoint(x: layer.crest + height * 0.25, y: base))
            var folds = Folds()
            if sandstone {
                sandstoneTexture(c, layer, plan.summits, rock: r, base: base)
            } else {
                folds = rockTexture(c, layer, rock: r, base: base)
            }
            // Shade, multiplied over the texture: a gentle darkening toward the lower right, then
            // every face east of a spur, lifted by reflected light toward its gully.
            c.multiply {
                c.sweep([(r.shadow, 0), (r.shadow, 0.45)], from: CGPoint(x: layer.crest, y: top),
                        to: CGPoint(x: layer.maxX + 0.05, y: base))
                for f in layer.facets {
                    c.clip(f.path) {
                        c.ctx.drawLinearGradient(c.gradient([(r.shadow.scaled(0.88), 1), (r.shadow, 0)]),
                                                 start: CGPoint(x: 0, y: f.fadeTop), end: CGPoint(x: 0, y: f.fadeBottom),
                                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                        c.ctx.drawLinearGradient(c.gradient([(Tone(1, 1, 1), 0), (Tone(1, 1, 1), 0.18)]),
                                                 start: CGPoint(x: f.from + 0.02, y: 0), end: CGPoint(x: max(f.to, f.from + 0.06), y: 0),
                                                 options: [.drawsAfterEndLocation])
                    }
                }
            }
            if let snowLine, top > snowLine + 0.02 {
                snow(c, layer, folds, rock: r, line: snowLine, base: base, heavy: heavySnow)
            }
            crests(c, layer, rock: r, base: base, snowLine: snowLine, sandstone: sandstone)
            // Ambient occlusion toward the foot.
            c.sweep([(r.deep, 0), (r.deep, 0.26)], from: CGPoint(x: 0, y: base + height * 0.4), to: CGPoint(x: 0, y: base))
            if plan.back {
                // Behind the front summits: in their shadow, darker and cooler.
                c.multiply { c.sweep([(Tone(0.8, 0.82, 0.93), 1), (Tone(0.8, 0.82, 0.93), 1)], from: .zero, to: CGPoint(x: 0, y: 1)) }
            }
        }
    }

    /// Rock texture, painted before the shading. Ribs carry the form: minor ridges falling from
    /// the skyline and fanning outward, each splitting a sunlit west side from a shaded east
    /// side, so the faces read as folded rock rather than flat planes (on the sunlit flank a
    /// shaded face east of each rib; on the shaded flank a lit strip west of it, which the
    /// shading darkens with the rest). Then, on bedded rock, a few long strata dipping across
    /// the faces; sparse crevices; and a lighter talus apron with chips at the foot. Returns
    /// the ribs and their faces, for the snow to follow.
    private static func rockTexture(_ c: Canvas, _ layer: RangeLayer, rock r: Rock, base: CGFloat) -> Folds {
        let width = layer.maxX - layer.minX, height = layer.top - base
        var folds = Folds()
        let shaded = folds.shaded, lit = folds.lit, edges = CGMutablePath()
        // Ribs at two scales, so the faces never read as rows of identical slashes: every few
        // a major rib (long, broad, carrying the form), minor ones between (short and narrow,
        // starting below the skyline as often as on it).
        let minorShaded = CGMutablePath(), minorLit = CGMutablePath()
        var x = layer.minX + c.f(0.03, 0.08)
        var sinceMajor = c.int(0...2)
        while x < layer.maxX - 0.03 {
            let sky = layer.height(at: x)
            if sky > base + 0.1 {
                let east = x > layer.crest
                let major = sinceMajor >= 2 && c.chance(0.7)
                sinceMajor = major ? 0 : sinceMajor + 1
                let start = major || c.chance(0.4) ? sky - 0.004 : sky - (sky - base) * c.f(0.1, 0.35)
                let depth = (start - base) * (major ? c.f(0.55, 0.88) : c.f(0.18, 0.45))
                let drift = (east ? 1 : -1) * depth * c.f(0.12, 0.4)
                let line = fallLine(c, from: CGPoint(x: x, y: start), toX: x + drift, bottom: start - depth, wander: 0.01)
                // A leaf-shaped face beside the rib, widest partway down.
                let w0 = (major ? c.f(0.035, 0.06) : c.f(0.012, 0.028)) * (east ? -0.8 : 1), last = CGFloat(line.count - 1)
                var side: [CGPoint] = []
                side.reserveCapacity(line.count)
                var k = 0
                while k < line.count {
                    let t = CGFloat(k) / last
                    side.append(CGPoint(x: line[k].x + w0 * pow(sin(.pi * min(1, t * 1.15)), 0.7), y: line[k].y - abs(w0) * 0.3 * t))
                    k += 1
                }
                if major {
                    (east ? lit : shaded).addPath(polygon(line + side.reversed()))
                    edges.addLines(between: line.map { CGPoint(x: $0.x - 0.004, y: $0.y) })
                    folds.ribs.append(line)
                } else {
                    (east ? minorLit : minorShaded).addPath(polygon(line + side.reversed()))
                }
            }
            x += c.f(0.04, 0.09)
        }
        c.multiply {
            c.fill(shaded, r.shadow, 0.72)
            c.fill(minorShaded, r.shadow, 0.42)
        }
        c.fill(lit, r.lit.lit(0.5), 0.4)
        c.fill(minorLit, r.lit.lit(0.5), 0.24)
        c.stroke(edges, r.lit.lit(), 0.4, width: 0.007)

        if r.bedded {
            // Bedding planes all dip the same way across the massif, in broken runs.
            let dip = c.sign() * c.f(0.22, 0.36)
            let strata = Marks(2)
            var y = base + c.f(0.04, 0.08)
            while y < layer.top - 0.04 {
                var x = layer.minX + c.f(0, 0.06)
                while x < layer.maxX {
                    let len = c.f(0.08, 0.2)
                    let y0 = y + dip * (x - layer.minX) + c.f(-0.005, 0.005)
                    if c.chance(0.35), y0 > base + 0.03, y0 < layer.height(at: x + len / 2) - 0.03 {
                        let y1 = y0 + dip * len + c.f(-0.006, 0.006)
                        let mid = CGPoint(x: x + len / 2, y: (y0 + y1) / 2 + c.f(-0.005, 0.005))
                        strata.curve(0, CGPoint(x: x, y: y0), mid, CGPoint(x: x + len, y: y1))
                        strata.curve(1, CGPoint(x: x + 0.004, y: y0 + 0.0065), CGPoint(x: mid.x, y: mid.y + 0.0065), CGPoint(x: x + len - 0.004, y: y1 + 0.0065))
                    }
                    x += len + c.f(0.04, 0.12)
                }
                y += c.f(0.07, 0.12)
            }
            strata.stroke(c, [r.strata, r.lit.lit(0.6)], alphas: [0.32, 0.22], width: 0.006)
        }

        let carve = Marks(2)
        for _ in 0..<Int(width * 6) {
            let x = c.f(layer.minX + 0.03, layer.maxX - 0.03), sky = layer.height(at: x)
            guard sky > base + 0.1 else { continue }
            let y0 = c.f(base + 0.06, sky - 0.03), drop = c.f(0.04, 0.1)
            let pts = fallLine(c, from: CGPoint(x: x, y: y0), toX: x + c.f(-0.02, 0.02), bottom: max(base, y0 - drop), wander: 0.006)
            var k = 1
            while k < pts.count {
                carve.line(0, pts[k - 1], pts[k])
                carve.line(1, CGPoint(x: pts[k - 1].x - 0.006, y: pts[k - 1].y + 0.002), CGPoint(x: pts[k].x - 0.006, y: pts[k].y + 0.002))
                k += 1
            }
        }
        carve.stroke(c, [r.deep, r.lit.lit()], alphas: [0.4, 0.28], width: 0.006)

        let apron = min(0.15, height * 0.3)
        c.sweep([(r.scree, 0.5), (r.scree, 0)], from: CGPoint(x: 0, y: base), to: CGPoint(x: 0, y: base + apron))
        let talus = Marks(3)
        for _ in 0..<Int(width * 60) {
            let x = c.f(layer.minX, layer.maxX)
            let y = base + pow(c.f(0, 1), 1.6) * apron
            guard y < layer.height(at: x) - 0.01 else { continue }
            let w = c.f(0.005, 0.012)
            talus.poly(c.int(0...2), [CGPoint(x: x - w, y: y - w * 0.4), CGPoint(x: x - w * 0.2, y: y + w * 0.6),
                                      CGPoint(x: x + w, y: y - w * 0.2)])
        }
        talus.fill(c, [r.scree.lit(0.4), r.mid, r.deep], alpha: 0.55)
        return folds
    }

    /// Sandstone, painted before the shading: soft bedding bands of uneven thickness, a little
    /// cross-bedding, joints at irregular spacing (short, a few reaching the rim), benches on
    /// terraced rock, a bright caprock band with a dark seam under each flat top, and pale talus
    /// banked against the foot.
    private static func sandstoneTexture(_ c: Canvas, _ layer: RangeLayer, _ summits: [Summit], rock r: Rock, base: CGFloat) {
        let x0 = layer.minX - 0.05, x1 = layer.maxX + 0.05, width = layer.maxX - layer.minX
        let tones = [r.strata, r.scree, r.mid.mix(r.strata, 0.4), r.lit.lit(0.6), r.deep.mix(r.strata, 0.5)]
        var y = base - 0.04, k = c.int(0...4)
        while y < layer.top {
            let h = c.f(0.012, 0.05)
            var lower: [CGPoint] = [], upper: [CGPoint] = []
            var i = 0
            while i <= 10 {
                let x = x0 + (x1 - x0) * CGFloat(i) / 10
                lower.append(CGPoint(x: x, y: y + c.f(-0.004, 0.004)))
                upper.append(CGPoint(x: x, y: y + h + c.f(-0.004, 0.004)))
                i += 1
            }
            c.fill(polygon(lower + upper.reversed()), tones[k % tones.count], c.f(0.08, 0.22))
            y += h
            k += c.int(1...3)
        }
        // Brush marks at three scales, never in a grid (a grid of ledges and joints reads as
        // brickwork): long varnish streaks hanging from the rims, a few deep fissures, and
        // short broken ledge lines on some of the benches.
        let marks = Marks(3)
        for _ in 0..<Int(width * 5) {
            let x = c.f(layer.minX, layer.maxX), sky = layer.height(at: x)
            guard sky > base + 0.06 else { continue }
            let y0 = c.f(base + 0.02, sky - 0.02), len = c.f(0.05, 0.12)
            marks.curve(0, CGPoint(x: x, y: y0), CGPoint(x: x + len * 0.5, y: y0 - c.f(0.004, 0.014)), CGPoint(x: x + len, y: y0 + c.f(-0.006, 0.008)))
        }
        let varnish = CGMutablePath()
        var x = layer.minX + c.f(0.02, 0.08)
        while x < layer.maxX - 0.02 {
            let sky = layer.height(at: x)
            if sky > base + 0.12 {
                if c.chance(0.55) {
                    // Desert varnish: a dark stain running down the wall from the rim, tapering.
                    let len = (sky - base) * c.f(0.25, 0.65), w = c.f(0.008, 0.022)
                    let pts = fallLine(c, from: CGPoint(x: x, y: sky - 0.012), toX: x + c.f(-0.006, 0.006), bottom: sky - len, wander: 0.003)
                    let last = CGFloat(pts.count - 1)
                    var left: [CGPoint] = [], right: [CGPoint] = []
                    for (k, p) in pts.enumerated() {
                        let taper = w * (1 - CGFloat(k) / last * 0.85)
                        left.append(CGPoint(x: p.x - taper * 0.5, y: p.y))
                        right.append(CGPoint(x: p.x + taper * 0.5, y: p.y))
                    }
                    varnish.addPath(polygon(left + right.reversed()))
                } else if c.chance(0.4) {
                    // A deep fissure, lit on its west lip.
                    let y0 = sky - c.f(0, 0.02)
                    let pts = fallLine(c, from: CGPoint(x: x, y: y0), toX: x + c.f(-0.012, 0.012),
                                       bottom: y0 - (y0 - base) * c.f(0.25, 0.6), wander: 0.005)
                    var i = 1
                    while i < pts.count {
                        marks.line(1, pts[i - 1], pts[i])
                        marks.line(2, CGPoint(x: pts[i - 1].x - 0.007, y: pts[i - 1].y), CGPoint(x: pts[i].x - 0.007, y: pts[i].y))
                        i += 1
                    }
                }
            }
            x += c.f(0.07, 0.2)
        }
        c.fill(varnish, r.deep.mix(r.strata, 0.3), 0.2)
        for ledge in layer.ledges where c.chance(0.45) {
            var x = layer.minX + c.f(0, 0.1)
            while x < layer.maxX {
                let len = c.f(0.05, 0.2), y0 = ledge + c.f(-0.006, 0.006)
                if c.chance(0.6) {
                    marks.line(2, CGPoint(x: x, y: y0), CGPoint(x: x + len, y: y0 + c.f(-0.004, 0.004)))
                    marks.line(1, CGPoint(x: x, y: y0 - 0.009), CGPoint(x: x + len, y: y0 - 0.009))
                }
                x += len + c.f(0.04, 0.14)
            }
        }
        marks.stroke(c, [r.strata, r.deep, r.lit.lit()], alphas: [0.24, 0.36, 0.3], width: 0.007)
        // Caprock on every flat top: the resistant cap catches the light; a seam of shadow
        // under its lip.
        let cap = CGMutablePath(), seam = CGMutablePath()
        for s in summits where s.wall > 0 && s.plateau > 0.12 {
            let xa = s.x - s.west * s.plateau, xb = s.x + s.east * s.plateau
            var top: [CGPoint] = [], under: [CGPoint] = []
            var i = 0
            while i <= 12 {
                let x = xa + (xb - xa) * CGFloat(i) / 12, sky = layer.height(at: x)
                top.append(CGPoint(x: x, y: sky - 0.011))
                under.append(CGPoint(x: x, y: sky - 0.03 + c.f(-0.002, 0.002)))
                i += 1
            }
            cap.addLines(between: top)
            seam.addLines(between: under)
        }
        c.stroke(cap, r.lit.lit(0.8), 0.7, width: 0.014)
        c.stroke(seam, r.deep, 0.45, width: 0.008)
        let grit = Marks(3)
        for _ in 0..<Int(width * 60) {
            let x = c.f(layer.minX, layer.maxX), y = base + pow(c.f(0, 1), 2) * 0.12
            guard y < layer.height(at: x) - 0.01 else { continue }
            let w = c.f(0.005, 0.011)
            grit.poly(c.int(0...2), [CGPoint(x: x - w, y: y - w * 0.4), CGPoint(x: x, y: y + w * 0.5), CGPoint(x: x + w, y: y - w * 0.3)])
        }
        // Talus: pale sand and rubble banked against the foot, streaked down the slope.
        c.linear(layer.silhouette, [(r.scree, 0.85), (r.scree, 0)], from: CGPoint(x: 0, y: base), to: CGPoint(x: 0, y: base + 0.12))
        grit.fill(c, [r.scree.lit(0.5), r.deep, r.mid], alpha: 0.5)
    }

    /// Snow above `line`, lying in the folds of the rock. Its lower edge runs higher on the
    /// sunlit west, stays off every rock rib and reaches down the hollow between two ribs in a
    /// tongue (now and then trailing a thin streak down the gully), dips into couloirs below the
    /// cols, and rises over the spurs where rock stays bare. Warm white in sunlit faces, blue in
    /// shaded ones; the ribs' faces shade the snowfield as they shade the rock; a soft shadow
    /// under the edge only on the shaded side. Heavy snow (frozen peaks) also leaves bare rock
    /// where it is too steep to stick.
    private static func snow(_ c: Canvas, _ layer: RangeLayer, _ folds: Folds, rock r: Rock, line: CGFloat, base: CGFloat,
                             heavy: Bool) {
        let x0 = layer.minX, x1 = layer.maxX
        // Sun-facing slopes melt first: the line climbs west of the crest.
        let climb: CGFloat = heavy ? 0.1 : 0.12
        func lineAt(_ x: CGFloat) -> CGFloat { line + (layer.crest - x) * climb }

        struct Dip { var x, depth, width: CGFloat }
        var dips: [Dip] = []
        for g in layer.gullies where g[0].y > line - 0.02 {
            let end = g[g.count - 1]
            dips.append(Dip(x: g[0].x + (end.x - g[0].x) * 0.4, depth: c.f(0.08, 0.15) * (heavy ? 0.7 : 1), width: c.f(0.035, 0.055)))
        }
        for _ in 0..<c.int(1...2) {
            // A couloir or two down the shaded flank.
            dips.append(Dip(x: c.f(layer.crest + 0.04, x1 - 0.04), depth: c.f(0.05, 0.11), width: c.f(0.025, 0.04)))
        }
        // Where the rock ribs cross the snow line: bare rock along each rib, a tongue of snow
        // down the hollow between neighbors.
        var crossings: [CGFloat] = []
        for rib in folds.ribs where rib[0].y > lineAt(rib[0].x) + 0.015 {
            if let p = rib.first(where: { $0.y <= lineAt($0.x) }) { crossings.append(p.x) }
        }
        crossings.sort()
        struct Bump { var x, h, w: CGFloat }
        var bumps = crossings.map { Bump(x: $0, h: c.f(0.018, 0.04), w: c.f(0.012, 0.02)) }
        var tongues: [Dip] = []
        if crossings.count > 1 {
            for k in 1..<crossings.count where crossings[k] - crossings[k - 1] < 0.17 {
                let gap = crossings[k] - crossings[k - 1]
                tongues.append(Dip(x: crossings[k - 1] + gap * c.f(0.4, 0.6), depth: c.f(0.03, 0.075) * (heavy ? 0.8 : 1),
                                   width: gap * c.f(0.36, 0.46)))
            }
        }
        bumps += layer.spurs.map { spur in
            Bump(x: (spur.min { abs($0.y - line) < abs($1.y - line) }?.x ?? spur[0].x) + 0.008, h: c.f(0.03, 0.06), w: 0.032)
        }
        dips += tongues

        let n = max(48, Int((x1 - x0) / 0.005))
        let wobble = c.bridge(n)
        var edge: [CGPoint] = []
        edge.reserveCapacity(n + 1)
        var i = 0
        while i <= n {
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(n)
            var y = lineAt(x) + wobble[i] * (heavy ? 0.026 : 0.018)
            var k = 0
            while k < dips.count {
                let t = abs(x - dips[k].x) / dips[k].width
                if t < 1 { y -= dips[k].depth * pow(1 - t, 1.4) }
                k += 1
            }
            k = 0
            while k < bumps.count {
                let t = abs(x - bumps[k].x) / bumps[k].w
                if t < 1 { y += bumps[k].h * (1 - t * t) }
                k += 1
            }
            edge.append(CGPoint(x: x, y: y))
            i += 1
        }
        let cap = polygon(edge + [CGPoint(x: x1 + 0.1, y: 1.3), CGPoint(x: x0 - 0.1, y: 1.3)])
        // Streaks: snow left in the narrow gully below a tongue, tapering down the fall line.
        let streaks = CGMutablePath()
        for t in tongues where c.chance(heavy ? 0.6 : 0.45) {
            let i = min(max(Int((t.x - x0) / (x1 - x0) * CGFloat(n)), 0), n)
            let tip = edge[i]
            let len = c.f(0.05, 0.13), w = c.f(0.007, 0.012)
            guard tip.y - len > base + 0.05, tip.y < layer.height(at: tip.x) - 0.02 else { continue }
            let drift = (tip.x > layer.crest ? 1 : -1) * len * c.f(0.1, 0.3)
            let end = CGPoint(x: tip.x + drift, y: tip.y - len)
            let mid = CGPoint(x: tip.x + drift * 0.45 + c.f(-0.004, 0.004), y: tip.y - len * 0.5)
            streaks.addPath(smoothClosed([CGPoint(x: tip.x - w, y: tip.y + 0.01), CGPoint(x: mid.x - w * 0.55, y: mid.y), end,
                                          CGPoint(x: mid.x + w * 0.55, y: mid.y), CGPoint(x: tip.x + w, y: tip.y + 0.01)]))
        }
        // A soft shadow under the snow's edge, only where the slope faces away from the sun
        // (painted first, so the streaks lie over it).
        let lip = CGMutablePath()
        lip.addLines(between: edge.filter { $0.x > layer.crest + 0.01 }.map { CGPoint(x: $0.x, y: $0.y - 0.006) })
        c.ctx.saveGState()
        c.ctx.addPath(cap)
        c.ctx.addRect(CGRect(x: -1, y: -1, width: c.aspect + 2, height: 3))
        c.ctx.clip(using: .evenOdd)
        c.stroke(lip, r.deep, 0.28, width: 0.01)
        c.ctx.restoreGState()
        c.layer {
            c.fill(cap, r.snowLit)
            c.fill(streaks, r.snowLit)
            c.ctx.setBlendMode(.sourceAtop)
            // The same shading as the rock, in snow colors.
            let height = layer.top - base
            c.sweep([(r.snowShade, 0), (r.snowShade, 0.55)], from: CGPoint(x: layer.crest, y: layer.top),
                    to: CGPoint(x: x1 + 0.05, y: base + height * 0.3))
            for f in layer.facets {
                c.clip(f.path) {
                    c.ctx.drawLinearGradient(c.gradient([(r.snowShade, 1), (r.snowShade, 0)]),
                                             start: CGPoint(x: 0, y: f.fadeTop), end: CGPoint(x: 0, y: f.fadeBottom),
                                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
            }
            // The rock's folds under the snow: a blue face east of each rib on the sunlit flank,
            // a lit strip west of it on the shaded one.
            c.fill(folds.shaded, r.snowShade, 0.5)
            c.fill(folds.lit, r.snowLit, 0.35)
            c.sweep([(r.snowShade, 0), (r.snowShade, 0.3)], from: CGPoint(x: 0, y: layer.top), to: CGPoint(x: 0, y: line - 0.08))
            let drift = Marks(2)
            for _ in 0..<Int((x1 - x0) * 16) {
                let q = CGPoint(x: c.f(x0, x1), y: c.f(line - 0.03, layer.top))
                drift.line(q.x > layer.crest ? 0 : 1, q, CGPoint(x: q.x + c.f(0.015, 0.04), y: q.y - c.f(0.008, 0.025)))
            }
            drift.stroke(c, [r.snowShade.scaled(0.9), r.snowShade.mix(r.snowLit, 0.6)], alphas: [0.55, 0.35], width: 0.006)
            // Rock ribs where it is too steep for snow to stick: dark blades running down and away
            // from each spur, thickest in the shaded faces.
            let ribPaths = CGMutablePath()
            for spur in layer.spurs where spur.count > 3 {
                let apex = spur[0]
                let count = heavy ? c.int(4...6) : c.int(2...3)
                for _ in 0..<count {
                    let k = c.int(1...max(1, spur.count * 2 / 3))
                    let start = spur[min(k, spur.count - 1)]
                    guard start.y > line, start.y < apex.y - 0.02 else { continue }
                    let east = c.chance(0.75)
                    let len = c.f(0.05, heavy ? 0.18 : 0.13) * (east ? 1 : 0.6)
                    let w0 = c.f(0.01, east ? (heavy ? 0.03 : 0.022) : 0.016)
                    let end = CGPoint(x: start.x + (east ? 1 : -1) * len * c.f(0.35, 0.7), y: start.y - len)
                    let mid = CGPoint(x: (start.x + end.x) / 2 + c.f(-0.01, 0.01), y: (start.y + end.y) / 2)
                    let side = CGPoint(x: mid.x + (east ? w0 : -w0), y: mid.y + w0 * 0.4)
                    ribPaths.addPath(polygon([start, side, end, CGPoint(x: mid.x - (east ? w0 : -w0) * 0.3, y: mid.y)]))
                }
                // The spur's own crest stays partly bare on its shaded side.
                var k = 1
                while k < spur.count - 1, spur[k].y > line {
                    let run = min(spur.count - 1, k + c.int(1...3))
                    let pts = Array(spur[k...run]), w0 = c.f(0.007, heavy ? 0.018 : 0.012)
                    ribPaths.addPath(polygon(pts.map { CGPoint(x: $0.x + 0.002, y: $0.y) } + pts.reversed().map { CGPoint(x: $0.x + w0, y: $0.y) }))
                    k = run + c.int(1...3)
                }
            }
            c.fill(ribPaths, r.deep.mix(r.mid, 0.2), 0.85)
        }
    }

    /// Ridge crests and sunlit edges, painted over shading and snow: each spur gets a lit edge
    /// with a crisp dark line on its shaded side, and the skyline catches a warm rim wherever it
    /// faces the sun (on snow too, but never brighter than the snow itself).
    private static func crests(_ c: Canvas, _ layer: RangeLayer, rock r: Rock, base: CGFloat, snowLine: CGFloat?, sandstone: Bool) {
        let lit = CGMutablePath(), dark = CGMutablePath()
        for spur in layer.spurs {
            let upper = Array(spur.prefix(max(2, spur.count * 3 / 5)))
            lit.addLines(between: upper.map { CGPoint(x: $0.x - 0.006, y: $0.y - 0.003) })
            dark.addLines(between: upper.map { CGPoint(x: $0.x + 0.004, y: $0.y - 0.003) })
        }
        if !sandstone {
            c.stroke(dark, r.deep, 0.4, width: 0.006)
            c.stroke(lit, r.lit.lit(), 0.42, width: 0.008)
        }
        // Rim runs split at the snow line: warm rock below, snow above.
        let rims = [CGMutablePath(), CGMutablePath()]
        var run: [CGPoint] = [], runSnowy = false
        func flush() {
            if run.count > 2 { rims[runSnowy ? 1 : 0].addLines(between: run) }
            run.removeAll()
        }
        var i = 1
        while i < layer.skyline.count {
            let p = layer.skyline[i - 1], q = layer.skyline[i]
            let snowy = snowLine.map { p.y > $0 + 0.02 } ?? false
            if snowy != runSnowy {
                flush()
                runSnowy = snowy
            }
            if q.y >= p.y - 0.002, p.y > base + 0.04 { run.append(CGPoint(x: p.x + 0.004, y: p.y - 0.006)) } else { flush() }
            i += 1
        }
        flush()
        c.stroke(rims[0], r.lit.lit(), 0.5, width: 0.008)
        c.stroke(rims[1], r.snowLit, 0.9, width: 0.008)
    }

    /// Rubble at the foot: small angular stones lying on the ground along the base.
    private static func rubble(_ c: Canvas, from west: CGFloat, to east: CGFloat, base: CGFloat, rock r: Rock) {
        let chips = Marks(3)
        for _ in 0..<Int((east - west) * 34) {
            let x = c.f(west + 0.02, east - 0.02), y = base + c.f(-0.002, 0.024)
            let w = c.f(0.007, 0.016), h = w * c.f(0.5, 0.8)
            chips.poly(c.int(0...2), [CGPoint(x: x - w, y: y - h * 0.5), CGPoint(x: x - w * 0.3, y: y + h * 0.5),
                                      CGPoint(x: x + w * 0.6, y: y + h * 0.4), CGPoint(x: x + w, y: y - h * 0.5)])
        }
        chips.fill(c, [r.scree.lit(0.3), r.mid, r.deep.mix(r.mid, 0.3)], alpha: 0.8)
    }
}

// MARK: - Hills

extension DecorSprite {
    /// The color a hill style is painted in: its terrain's palette color (tundra a little
    /// mossier). Placement tints every hill by the ratio of the ground around it to this color,
    /// so hills, and the bridges between hills of different terrains, match what they stand on.
    static func hillGround(_ style: HillStyle) -> SIMD3<Float> {
        let terrain: Terrain = [.grassland, .plains, .desert, .tundra, .snow][style.rawValue]
        let p = Palette.terrain(terrain)
        var color = SIMD3(Float(p.r), Float(p.g), Float(p.b))
        if style == .tundra { color += (SIMD3<Float>(0.45, 0.53, 0.31) - color) * 0.2 }
        return color
    }

    /// The shape of a hill or knoll image, from its own seeded dice: humps with a long back
    /// slope to the west and a steeper lee to the east (dunes: a long windward slope and a
    /// slip face), joined by a smooth union so the valleys between them stay soft.
    fileprivate struct HillPlan {
        struct Bump { var x, west, east, h: CGFloat }
        var bumps: [Bump]
        /// Height of the tallest hump above the foot.
        var rise: CGFloat
        var dune: Bool
        /// A rocky knoll: an outcrop breaks through at the crest.
        var rocky: Bool
        var crest: CGFloat { rise * (bumps.map(\.h).max() ?? 1) }
        var halfWidth: CGFloat {
            let west = bumps.map { $0.x - $0.west }.min() ?? 0, east = bumps.map { $0.x + $0.east }.max() ?? 0
            return max(1 - west, east - 1) // the foot is at x = 1 (aspect 2)
        }

        func height(_ b: Bump, _ x: CGFloat) -> CGFloat {
            let east = x > b.x
            let u = (x - b.x) / (east ? b.east : b.west)
            guard abs(u) < 1 else { return 0 }
            return b.h * pow(1 - u * u, dune && east ? 1.0 : (east ? 1.15 : 1.4))
        }

        /// Smooth union (a 4-norm) of the humps at `x`, in painter units above the foot.
        func surface(_ x: CGFloat) -> CGFloat {
            var sum: CGFloat = 0
            var k = 0
            while k < bumps.count {
                let h = height(bumps[k], x)
                sum += h * h * h * h
                k += 1
            }
            return pow(sum, 0.25) * rise
        }
    }

    fileprivate static func hillPlan(style: HillStyle, variant v: Int, knoll: Bool, code: Int, aspect a: CGFloat) -> HillPlan {
        let d = Dice(seed: UInt64(0x2100 + code), salt: 0x41B)
        let dune = style == .sandy
        typealias Bump = HillPlan.Bump
        // Lee sides are steeper: a shorter run to the east (much shorter on a dune's slip face).
        func hump(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Bump {
            dune ? Bump(x: x, west: w / 0.72, east: w / 1.7, h: h) : Bump(x: x, west: w * d.f(1.05, 1.2), east: w * d.f(0.58, 0.7), h: h)
        }
        var bumps: [Bump]
        var rise: CGFloat
        var rocky = false
        if knoll {
            // Small knolls: a rocky one and a soft double one.
            rise = d.f(0.56, 0.66)
            let w = a * d.f(0.22, 0.26)
            if v % 2 == 0 {
                bumps = [hump(1 + d.f(-0.06, 0.02), w, 1)]
                rocky = !dune && style != .snowy
            } else {
                bumps = [hump(0.9, w * 0.9, 1), hump(0.9 + a * d.f(0.14, 0.18), w * 0.7, d.f(0.6, 0.72))]
            }
        } else {
            rise = dune ? d.f(0.4, 0.48) : d.f(0.38, 0.46)
            let main = a * (dune ? d.f(0.24, 0.28) : d.f(0.3, 0.35))
            let x0 = a * d.f(0.42, 0.5)
            let kinds = style == .tundra || style == .snowy ? 2 : 4
            switch v % kinds {
            case 0:
                // One long swell (tundra and snow: with a rocky knoll on its crest).
                bumps = [hump(x0, main * 1.2, 1)]
                rocky = style == .tundra
            case 1:
                // A double hump, the lower one downwind.
                bumps = [hump(x0 - a * 0.06, main * 0.95, 1), hump(x0 + a * d.f(0.18, 0.24), main * d.f(0.62, 0.72), d.f(0.62, 0.76))]
            case 2:
                // Three humps stepping down to the east.
                bumps = [hump(x0 - a * 0.12, main * 0.8, 1), hump(x0 + a * d.f(0.06, 0.1), main * 0.7, d.f(0.74, 0.84)),
                         hump(x0 + a * d.f(0.24, 0.3), main * 0.6, d.f(0.5, 0.6))]
            default:
                // A long low swell with a terraced shoulder: a small rise on its west back.
                bumps = [hump(x0 + a * 0.04, main * 1.35, 0.72), hump(x0 - a * d.f(0.08, 0.12), main * 0.48, 1)]
            }
        }
        // Keep every foot inside the slot.
        for k in bumps.indices {
            bumps[k].x = min(max(bumps[k].x, 0.04 + bumps[k].west), a - 0.04 - bumps[k].east)
        }
        return HillPlan(bumps: bumps, rise: rise, dune: dune, rocky: rocky)
    }

    /// Rolling mounds in the color of their terrain (placement tints them to the ground they
    /// stand on): opaque down to an irregular foot that melts into the ground, every hump lit
    /// on its west back and shaded softly on its east lee, grass, heath or sand ripples all the
    /// way down. Only the skyline is outlined.
    fileprivate static func hill(_ c: Canvas, _ art: DecorArt) {
        let style: HillStyle, variant: Int, knoll: Bool
        switch art {
        case let .hill(s, v): (style, variant, knoll) = (s, v, false)
        case let .knoll(s, v): (style, variant, knoll) = (s, v, true)
        default: return
        }
        let a = c.aspect, base = c.foot.y
        let plan = hillPlan(style: style, variant: variant, knoll: knoll, code: art.code, aspect: a)
        let g = hillGround(style)
        let ground = Tone(CGFloat(g.x), CGFloat(g.y), CGFloat(g.z))
        let snowy = style == .snowy
        let lit = snowy ? Tone(0.95, 0.95, 0.92) : ground.lit(0.9)
        let shade = snowy ? Tone(0.70, 0.76, 0.90) : ground.shade(1.25)
        let deep = snowy ? Tone(0.55, 0.62, 0.80) : ground.shade(1.7)
        // Highlights brighten the sunlit color, except on snow, which is already the lightest
        // value the art allows.
        let glint = snowy ? lit : lit.lit(0.4), rimTone = snowy ? lit : lit.lit(0.7)

        let n = 128
        var profile: [CGPoint] = []
        profile.reserveCapacity(n + 1)
        var i = 0
        while i <= n {
            let x = a * CGFloat(i) / CGFloat(n)
            profile.append(CGPoint(x: x, y: base + plan.surface(x)))
            i += 1
        }
        guard let first = profile.firstIndex(where: { $0.y > base + 0.002 }),
              let last = profile.lastIndex(where: { $0.y > base + 0.002 }) else { return }
        let i0 = max(first - 1, 0), i1 = min(last + 1, n)
        let mound = polygon([CGPoint(x: profile[i0].x, y: base - 0.06)] + Array(profile[i0...i1]) + [CGPoint(x: profile[i1].x, y: base - 0.06)])
        let crest = profile.max { $0.y < $1.y } ?? CGPoint(x: a / 2, y: base + plan.rise)
        let skyline = CGMutablePath(), rim = CGMutablePath()
        var run: [CGPoint] = [], litRun: [CGPoint] = []
        for (k, p) in profile.enumerated() {
            if p.y > base + 0.03 { run.append(p) } else {
                if run.count > 1 { skyline.addLines(between: run) }
                run.removeAll()
            }
            // The rim catches the light where the skyline faces the sun (rising to the east).
            let rising = k < n && profile[k + 1].y >= p.y - 0.004
            if rising, p.y > base + 0.05 { litRun.append(CGPoint(x: p.x + 0.004, y: p.y - 0.01)) } else {
                if litRun.count > 2 { rim.addLines(between: litRun) }
                litRun.removeAll()
            }
        }
        if run.count > 1 { skyline.addLines(between: run) }
        if litRun.count > 2 { rim.addLines(between: litRun) }

        let footWest = profile[i0].x, footEast = profile[i1].x
        c.contactShadow(CGPoint(x: (footWest + footEast) / 2 + (footEast - footWest) * 0.1, y: base),
                        width: (footEast - footWest) * 0.8, height: 0.08, alpha: 0.3)
        c.groundCut(base, soft: 0.03, jag: 0.018, swell: 0.025) {
            c.outline([skyline], width: 0.016, alpha: 0.42)
            c.fill(mound, ground)
            c.clip(mound) {
                // Larger humps first, so smaller ones read as standing in front; dunes from west
                // to east, each downwind dune in front of the slip face of the one before it.
                let order = plan.dune ? plan.bumps.sorted { $0.x < $1.x } : plan.bumps.sorted { $0.h * $0.west > $1.h * $1.west }
                for b in order {
                    let top = base + b.h * plan.rise
                    var outline: [CGPoint] = [CGPoint(x: b.x - b.west, y: base - 0.06)]
                    var k = 0
                    while k <= 32 {
                        let x = b.x - b.west + (b.west + b.east) * CGFloat(k) / 32
                        outline.append(CGPoint(x: x, y: base + plan.height(b, x) * plan.rise + 0.002))
                        k += 1
                    }
                    outline.append(CGPoint(x: b.x + b.east, y: base - 0.06))
                    let dome = polygon(outline)
                    if plan.dune {
                        // Windward slopes take the full sun; the lee face falls into shade where
                        // the crest stands on the skyline (a crest inside the mound has none).
                        c.fill(dome, ground)
                        c.linear(dome, [(lit, 0.6), (lit, 0)], from: CGPoint(x: b.x - b.west * 0.7, y: top), to: CGPoint(x: b.x, y: base))
                        duneLee(c, dome: dome, crest: CGPoint(x: b.x, y: top), toe: b.x + b.east, base: base, lit: lit)
                    } else {
                        // Soft light and shade: a warm glow on the west back, cool shade pooling
                        // on the east lee and toward its foot, no straight band between them.
                        c.fill(dome, ground)
                        c.clip(dome) {
                            c.radial(nil, at: CGPoint(x: b.x + b.east * 0.75, y: base + (top - base) * 0.12), radius: b.east * 1.5,
                                     squash: 0.55, [(shade, 0.9), (shade, 0.55), (shade, 0)])
                            c.radial(nil, at: CGPoint(x: b.x - b.west * 0.3, y: top - (top - base) * 0.3), radius: b.west * 0.95,
                                     squash: 0.5, [(lit, 0.85), (lit, 0.35), (lit, 0)])
                            c.radial(nil, at: CGPoint(x: b.x - b.west * 0.18, y: top - (top - base) * 0.12), radius: b.west * 0.45,
                                     squash: 0.4, [(glint, 0.5), (glint, 0)])
                        }
                    }
                }
                hillMarks(c, style: style, profile: profile, base: base, ground: ground, lit: lit, shade: shade, deep: deep)
                if plan.rocky { outcrop(c, at: crest, base: base, snowy: snowy) }
                // Cool occlusion at the foot, deepest under the lee.
                c.sweep([(deep, 0.2), (deep, 0)], from: CGPoint(x: 0, y: base), to: CGPoint(x: 0, y: base + plan.rise * 0.22))
                c.radial(nil, at: CGPoint(x: footEast - (footEast - crest.x) * 0.3, y: base), radius: (footEast - crest.x) * 0.9,
                         squash: 0.4, [(deep, 0.3), (deep, 0)])
            }
            c.clip(mound) { c.stroke(rim, rimTone, 0.55, width: 0.012) }
        }
    }

    /// A rocky outcrop breaking through a crest: a few lumps of grey stone, lit on top.
    private static func outcrop(_ c: Canvas, at crest: CGPoint, base: CGFloat, snowy: Bool) {
        let stone = Tone(0.56, 0.55, 0.52)
        let lumps = Marks(3)
        for k in 0..<c.int(3...5) {
            let x = crest.x + c.f(-0.12, 0.1) + CGFloat(k) * 0.01, y = crest.y - c.f(0.025, 0.07)
            let w = c.f(0.035, 0.07), h = w * c.f(0.5, 0.8)
            lumps.poly(0, [CGPoint(x: x - w, y: y - h * 0.4), CGPoint(x: x - w * 0.6, y: y + h * 0.5), CGPoint(x: x + w * 0.2, y: y + h * 0.7),
                           CGPoint(x: x + w, y: y + h * 0.1), CGPoint(x: x + w * 0.8, y: y - h * 0.5)])
            lumps.poly(1, [CGPoint(x: x - w * 0.9, y: y - h * 0.1), CGPoint(x: x - w * 0.55, y: y + h * 0.48),
                           CGPoint(x: x + w * 0.15, y: y + h * 0.66), CGPoint(x: x - w * 0.05, y: y + h * 0.05)])
            lumps.poly(2, [CGPoint(x: x + w * 0.2, y: y - h * 0.45), CGPoint(x: x + w * 0.95, y: y + h * 0.05), CGPoint(x: x + w * 0.8, y: y - h * 0.5)])
        }
        let edge = CGMutablePath()
        edge.addPath(lumps.paths[0])
        c.stroke(edge, .ink, 0.35, width: 0.012)
        lumps.fill(c, [stone.shade(0.6), snowy ? Tone(0.93, 0.93, 0.92) : stone.lit(0.9), stone.shade(1.5)], alpha: 0.95)
    }

    /// The slip face of a dune east of its crest, seen a little from the side: the region
    /// between the brink, which leaves the crest almost level and curves down toward the toe
    /// (x = crest + k * drop^0.8), and the steep lee profile. Multiplied over the sand so its
    /// texture shows through, with a narrow soft edge, sunlit sand reflecting into its foot, and
    /// a warm highlight on the brink's lip.
    private static func duneLee(_ c: Canvas, dome: CGPath, crest: CGPoint, toe: CGFloat, base: CGFloat, lit: Tone) {
        let drop = crest.y - base, run = toe - crest.x
        guard drop > 0.05, run > 0.02 else { return }
        let k = run * 0.42 / pow(drop, 0.8)
        var brink: [CGPoint] = []
        var i = 0
        while i <= 20 {
            let y = crest.y + 0.004 - (drop + 0.05) * CGFloat(i) / 20
            brink.append(CGPoint(x: crest.x + k * pow(max(crest.y - y, 0), 0.8), y: y))
            i += 1
        }
        func face(_ shift: CGFloat) -> CGMutablePath {
            polygon(brink.map { CGPoint(x: $0.x + shift, y: $0.y) }
                    + [CGPoint(x: toe + 0.3, y: base - 0.1), CGPoint(x: toe + 0.3, y: crest.y + 0.1), CGPoint(x: crest.x + shift, y: crest.y + 0.1)])
        }
        c.clip(dome) {
            c.multiply {
                c.fill(face(-0.005), Tone(0.76, 0.66, 0.82), 0.5)
                c.fill(face(0), Tone(0.76, 0.66, 0.82), 0.84)
            }
            c.clip(face(0)) {
                c.radial(nil, at: CGPoint(x: toe - run * 0.1, y: base), radius: run * 0.9, squash: 0.7, [(lit, 0.35), (lit, 0)])
            }
            let lip = CGMutablePath()
            lip.addLines(between: brink.prefix(12).map { CGPoint(x: $0.x - 0.008, y: $0.y + 0.001) })
            c.stroke(lip, lit.lit(1.1), 0.7, width: 0.01)
        }
    }

    private static func hillMarks(_ c: Canvas, style: HillStyle, profile: [CGPoint], base: CGFloat,
                                  ground: Tone, lit: Tone, shade: Tone, deep: Tone) {
        let a = c.aspect
        func surface(_ x: CGFloat) -> CGFloat {
            let i = min(max(Int(x / a * CGFloat(profile.count - 1)), 0), profile.count - 1)
            return profile[i].y
        }
        /// A random point on the mound, kept off the soft foot, and how sunlit it is (-1...1).
        func spot(margin: CGFloat = 0.015) -> (CGPoint, CGFloat)? {
            let x = c.f(0.02, a - 0.02), top = surface(x)
            guard top > base + 0.06 else { return nil }
            let y = c.f(base + 0.03, top - margin)
            guard y < top - margin else { return nil }
            let slope = (surface(x + 0.03) - surface(x - 0.03)) / 0.06
            let light = slope * 0.7 + (y - base) / max(top - base, 0.01) * 0.6 - 0.2 + c.f(-0.15, 0.15)
            return (CGPoint(x: x, y: y), max(-1, min(1, light)))
        }
        switch style {
        case .grassy, .dry:
            // Soft patches of lusher and drier growth, then grass strokes leaning with the
            // slope, pale on the lit side, cool in shadow.
            let patches = Marks(2)
            for _ in 0..<c.int(7...10) {
                guard let (p, _) = spot(margin: 0.04) else { continue }
                patches.paths[c.int(0...1)].addPath(c.blob(p, c.f(0.06, 0.13), c.f(0.02, 0.04), lobes: 7, wobble: 0.3))
            }
            let lush = style == .grassy ? Tone(0.30, 0.52, 0.22) : Tone(0.58, 0.58, 0.32)
            let dry = style == .grassy ? Tone(0.58, 0.66, 0.34) : Tone(0.86, 0.76, 0.48)
            patches.fill(c, [ground.mix(lush, 0.45), ground.mix(dry, 0.4)], alpha: 0.4)
            let blades = Marks(4)
            for _ in 0..<(style == .grassy ? 150 : 110) {
                guard let (p, light) = spot() else { continue }
                let tone = light > 0.45 ? 0 : (light > 0.05 ? 1 : (light > -0.35 ? 2 : 3))
                let h = c.f(0.03, 0.06), lean = c.f(-0.01, 0.018)
                blades.curve(tone, p, CGPoint(x: p.x + lean * 0.3, y: p.y + h * 0.6), CGPoint(x: p.x + lean, y: p.y + h))
            }
            let tips = style == .grassy ? [lit.lit(0.6), lit, ground.shade(0.5), shade]
                : [Tone(0.95, 0.87, 0.62), lit, ground.shade(0.6), shade]
            blades.stroke(c, tips, alphas: [0.7, 0.6, 0.6, 0.65], width: 0.014)
            // A few pale flowers (cream and blush: nothing near the player colors).
            let flowers = Marks(2)
            for _ in 0..<(style == .grassy ? 12 : 5) {
                guard let (p, light) = spot(), light > -0.1 else { continue }
                flowers.dab(c.chance(0.6) ? 0 : 1, p, 0.01, 0.008)
            }
            flowers.fill(c, [Tone(0.97, 0.95, 0.86), Tone(0.95, 0.84, 0.86)], alpha: 0.85)
        case .sandy:
            // Wind ripples: long, low wavy lines across the slopes, a shaded trough under a lit
            // crest.
            let ripples = Marks(2)
            for _ in 0..<22 {
                guard let (p, _) = spot(margin: 0.03) else { continue }
                let w = c.f(0.12, 0.24), phase = c.f(0, 6.28)
                var pts: [CGPoint] = []
                var k = 0
                while k <= 6 {
                    let t = CGFloat(k) / 6
                    pts.append(CGPoint(x: p.x - w / 2 + w * t, y: p.y + sin(phase + t * 7) * 0.005 - t * 0.012))
                    k += 1
                }
                ripples.paths[0].addLines(between: pts)
                ripples.paths[1].addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y + 0.006) })
            }
            ripples.stroke(c, [ground.shade(0.5), lit.lit(0.6)], alphas: [0.28, 0.4], width: 0.009)
        case .tundra:
            // Heath: short tufts in olive, rust and dusky purple and a few stones. Lingering snow
            // is placed per hill (`DecorArt.snow`), so no two hills carry the same patches.
            let tufts = Marks(4)
            for _ in 0..<140 {
                guard let (p, light) = spot() else { continue }
                let h = c.f(0.02, 0.04), lean = c.f(-0.01, 0.016)
                let tone = light > 0.3 ? 0 : (c.chance(0.25) ? 2 : (c.chance(0.3) ? 3 : 1))
                tufts.curve(tone, p, CGPoint(x: p.x + lean * 0.3, y: p.y + h * 0.6), CGPoint(x: p.x + lean, y: p.y + h))
            }
            tufts.stroke(c, [lit.lit(0.5), shade, Tone(0.60, 0.42, 0.30), Tone(0.48, 0.42, 0.48)], alpha: 0.7, width: 0.014)
            stones(c, count: 6, spot: { spot() })
        case .snowy:
            // Drift streaks and a few dark stones breaking the snow.
            let drift = Marks(2)
            for _ in 0..<34 {
                guard let (p, light) = spot() else { continue }
                drift.line(light > 0 ? 0 : 1, p, CGPoint(x: p.x + c.f(0.04, 0.09), y: p.y - c.f(0.004, 0.015)))
            }
            drift.stroke(c, [Tone(0.95, 0.95, 0.93), Tone(0.66, 0.73, 0.88)], alpha: 0.6, width: 0.01)
            stones(c, count: 5, spot: { spot() })
        }
    }

    /// Small stones half sunk in the ground: dark with a lit top.
    private static func stones(_ c: Canvas, count: Int, spot: () -> (CGPoint, CGFloat)?) {
        let marks = Marks(2)
        for _ in 0..<count {
            guard let (p, _) = spot() else { continue }
            let rx = c.f(0.012, 0.022), ry = rx * c.f(0.55, 0.7)
            marks.dab(0, p, rx, ry)
            marks.dab(1, CGPoint(x: p.x - rx * 0.25, y: p.y + ry * 0.35), rx * 0.6, ry * 0.45)
        }
        marks.fill(c, [Tone(0.38, 0.38, 0.42), Tone(0.62, 0.61, 0.60)], alpha: 0.9)
    }
}

// MARK: - Trees

extension DecorSprite {
    /// Bark: a tapered trunk lit on its west side.
    private static func trunk(from foot: CGPoint, to top: CGPoint, width w: CGFloat, curve: CGFloat = 0) -> CGMutablePath {
        let mid = CGPoint(x: (foot.x + top.x) / 2 + curve, y: (foot.y + top.y) / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: foot.x - w * 0.62, y: foot.y - 0.012))
        path.addQuadCurve(to: CGPoint(x: top.x - w * 0.28, y: top.y), control: CGPoint(x: mid.x - w * 0.4, y: mid.y))
        path.addLine(to: CGPoint(x: top.x + w * 0.28, y: top.y))
        path.addQuadCurve(to: CGPoint(x: foot.x + w * 0.62, y: foot.y - 0.012), control: CGPoint(x: mid.x + w * 0.4, y: mid.y))
        path.closeSubpath()
        return path
    }

    private static func paintTrunk(_ c: Canvas, _ path: CGPath, bark: Tone, foot: CGPoint, width w: CGFloat) {
        c.linear(path, [(bark.lit(0.9), 1), (bark, 1), (bark.shade(1.2), 1)],
                 from: CGPoint(x: foot.x - w * 0.6, y: 0), to: CGPoint(x: foot.x + w * 0.6, y: 0))
    }

    /// A leafy mass of clumps. Each clump is a ball lit from the upper left (cool shadow tone,
    /// a mid tone shifted toward the sun, a warm highlight) covered in leaf dabs; clumps on the
    /// crown's sunny side are lighter. Upper clumps first, so lower ones hang in front.
    private static func canopy(_ c: Canvas, _ clumps: [(p: CGPoint, r: CGFloat)], center: CGPoint, size: CGFloat, leaf: Tone, dab: CGFloat) {
        let mass = CGMutablePath()
        for k in clumps { mass.addPath(c.blob(k.p, k.r * 0.95, k.r * 0.9, lobes: 7, wobble: 0.1)) }
        c.fill(mass, leaf.shade(1.6))
        for k in clumps.sorted(by: { $0.p.y > $1.p.y }) {
            let g = facing(CGPoint(x: k.p.x - center.x, y: k.p.y - center.y)) * min(1, hypot(k.p.x - center.x, k.p.y - center.y) / size * 1.6)
            let base = g > 0 ? leaf.mix(leaf.lit(), g * 0.55) : leaf.mix(leaf.shade(), -g * 0.7)
            let ball = c.blob(k.p, k.r, k.r * 0.92, lobes: 9, wobble: 0.12)
            c.fill(ball, base.shade(1.05))
            c.clip(ball) {
                c.fill(c.blob(CGPoint(x: k.p.x - k.r * 0.2, y: k.p.y + k.r * 0.24), k.r * 0.92, k.r * 0.85, lobes: 8, wobble: 0.14), base)
                c.fill(c.blob(CGPoint(x: k.p.x - k.r * 0.4, y: k.p.y + k.r * 0.46), k.r * 0.5, k.r * 0.42, lobes: 7, wobble: 0.2), base.lit(0.9), 0.9)
                let dabs = Marks(4)
                for _ in 0..<Int(10 + k.r * 120) {
                    let ang = c.f(0, 2 * .pi), d = k.r * c.f(0, 1).squareRoot()
                    let q = CGPoint(x: k.p.x + cos(ang) * d, y: k.p.y + sin(ang) * d)
                    let light = facing(CGPoint(x: q.x - k.p.x, y: q.y - k.p.y)) * (d / k.r) + c.f(-0.35, 0.35)
                    let tone = light > 0.5 ? 0 : (light > 0.05 ? 1 : (light > -0.4 ? 2 : 3))
                    dabs.dab(tone, q, dab * c.f(0.8, 1.3), dab * c.f(0.55, 0.85))
                }
                dabs.fill(c, [base.lit(1.3), base.lit(0.5), base.shade(0.6), base.shade(1.4)], alpha: 0.85)
            }
        }
    }

    /// Conifers: drooping tiers with needle strokes, lit west and cool east, each tier shading
    /// the one below; every tier reaches and droops a little differently on each side. Builds:
    /// firs (0-2), a narrow spruce (3), an old tree with a broken top (4), a broad fir (5).
    /// Snowy trees carry irregular clumps of snow where branches are open to the sky: on each
    /// tier's upper edges below the tier above, and at the branch tips.
    fileprivate static func pine(_ c: Canvas, snowy: Bool, variant v: Int) {
        let a = c.aspect, foot = c.foot, cx = foot.x + c.f(-0.01, 0.01)
        let greens = [Tone(0.14, 0.34, 0.23), Tone(0.19, 0.38, 0.20), Tone(0.11, 0.30, 0.26),
                      Tone(0.15, 0.33, 0.24), Tone(0.17, 0.33, 0.20), Tone(0.20, 0.39, 0.21)]
        let build = v % 6
        var green = greens[build]
        if snowy { green = green.mix(Tone(0.10, 0.25, 0.28), 0.45) }
        let lit = green.lit(1.1), shade = green.shade(), deep = green.shade(1.8)
        let spruce = build == 3, broken = build == 4, broad = build == 5
        let top = broken ? c.f(0.8, 0.85) : c.f(0.91, 0.98)
        let crownBottom = foot.y + c.f(0.07, 0.11)
        let tiers = spruce ? c.int(6...7) : (broad ? c.int(4...5) : c.int(4...6))
        let maxHalf = a * (spruce ? c.f(0.3, 0.34) : (broad ? c.f(0.45, 0.48) : c.f(0.4, 0.45)))
        let snowLit = Tone(0.94, 0.94, 0.92), snowShade = Tone(0.68, 0.75, 0.89)

        c.contactShadow(foot, width: maxHalf * 2.3, height: 0.085)
        let trunkWidth: CGFloat = spruce ? 0.042 : 0.05
        let trunkPath = trunk(from: foot, to: CGPoint(x: cx, y: crownBottom + 0.1), width: trunkWidth)

        struct Tier { var path: CGMutablePath; var apex: CGPoint; var yBot: CGFloat; var west, east: CGFloat; var westEdge, eastEdge: [CGPoint] }
        var list: [Tier] = []
        var drift: CGFloat = 0
        for i in 0..<tiers {
            let t = CGFloat(i) / CGFloat(tiers)
            let yBot = crownBottom + (top - crownBottom) * t * (spruce ? 0.84 : 0.8)
            let yTop = i == tiers - 1 ? top : min(top - 0.02, yBot + (top - crownBottom) * (spruce ? c.f(0.3, 0.36) : c.f(0.4, 0.48)))
            let half = maxHalf * (1 - (spruce ? 0.8 : 0.76) * t)
            let west = half * c.f(0.86, 1.08), east = half * c.f(0.86, 1.08)
            drift += c.f(-0.006, 0.006)
            let apex = CGPoint(x: cx + drift, y: yTop)
            let droopW = c.f(0.012, 0.04), droopE = c.f(0.012, 0.04)
            var westEdge: [CGPoint] = [], eastEdge: [CGPoint] = []
            for k in 0...5 {
                let s = CGFloat(k) / 5, reach = 0.2 * s + 0.8 * pow(s, 1.25)
                westEdge.append(CGPoint(x: apex.x - west * reach, y: yTop + (yBot - droopW - yTop) * s))
                eastEdge.append(CGPoint(x: apex.x + east * reach, y: yTop + (yBot - droopE - yTop) * s))
            }
            var pts = westEdge
            let scallops = max(3, Int((west + east) / 0.05))
            for k in 1..<(scallops * 2) {
                let s = CGFloat(k) / CGFloat(scallops * 2)
                let x = apex.x - west + (west + east) * s
                let sag = sin(s * .pi) * 0.012
                pts.append(CGPoint(x: x + c.f(-0.004, 0.004), y: yBot - sag + (k % 2 == 1 ? c.f(0.012, 0.026) : -c.f(0, 0.012))))
            }
            pts += eastEdge.reversed()
            list.append(Tier(path: polygon(pts), apex: apex, yBot: yBot, west: west, east: east, westEdge: westEdge, eastEdge: eastEdge))
        }
        // The broken top: a bare, bent snag above a ragged crown.
        var snag: CGMutablePath?
        if broken, let crown = list.last {
            let tip = CGPoint(x: crown.apex.x + c.f(-0.03, 0.03), y: crown.apex.y + c.f(0.07, 0.1))
            let path = trunk(from: CGPoint(x: crown.apex.x, y: crown.apex.y - 0.05), to: tip, width: 0.026, curve: c.f(-0.015, 0.015))
            let twig = CGPoint(x: tip.x + c.sign() * 0.04, y: tip.y - 0.025)
            path.addPath(polygon([CGPoint(x: tip.x - 0.004, y: tip.y - 0.045), twig, CGPoint(x: tip.x + 0.004, y: tip.y - 0.035)]))
            snag = path
        }

        c.fadeBase(foot.y - 0.03, foot.y + 0.02) {
            c.outline([trunkPath] + list.map(\.path) + (snag.map { [$0] } ?? []), width: 0.022)
            paintTrunk(c, trunkPath, bark: Tone(0.36, 0.25, 0.17), foot: foot, width: trunkWidth)
            if let snag {
                c.linear(snag, [(Tone(0.62, 0.56, 0.50), 1), (Tone(0.40, 0.35, 0.33), 1)],
                         from: CGPoint(x: cx - 0.02, y: 0), to: CGPoint(x: cx + 0.02, y: 0))
            }
            let drawn = CGMutablePath()
            for (i, tier) in list.enumerated() {
                if i > 0 {
                    // This tier's shadow on the tiers below.
                    c.clip(drawn) {
                        var shift = CGAffineTransform(translationX: 0.012, y: snowy ? -0.016 : -0.03)
                        if let cast = tier.path.copy(using: &shift) { c.fill(cast, deep, snowy ? 0.42 : 0.55) }
                    }
                }
                c.fill(tier.path, green)
                c.clip(tier.path) {
                    // Shade east of a ragged line down from the apex; light down the west flank.
                    let x = tier.apex.x, bottom = tier.yBot - 0.06
                    var split: [CGPoint] = [CGPoint(x: x, y: tier.apex.y + 0.02)]
                    for k in 1...5 {
                        let s = CGFloat(k) / 5
                        split.append(CGPoint(x: x + tier.east * 0.12 * s + c.f(-0.014, 0.014) * s, y: tier.apex.y + (bottom - tier.apex.y) * s))
                    }
                    c.fill(polygon(split + [CGPoint(x: x + tier.east + 0.05, y: bottom), CGPoint(x: x + tier.east + 0.05, y: tier.apex.y + 0.02)]),
                           shade, snowy ? 0.82 : 1)
                    c.fill(polygon([tier.apex, CGPoint(x: x - tier.west * 1.1, y: bottom), CGPoint(x: x - tier.west * 0.42, y: bottom)]), lit, 0.7)
                    // Needles: short strokes falling outward from the stem.
                    let needles = Marks(4)
                    for _ in 0..<Int(14 + (tier.west + tier.east) * 35) {
                        let s = c.f(0.12, 1), side = c.sign()
                        let y = tier.apex.y + (tier.yBot - tier.apex.y) * s
                        let px = x + side * (side < 0 ? tier.west : tier.east) * s * c.f(0.1, 0.95)
                        let tone = side < 0 ? (s < 0.55 && c.chance(0.6) ? 0 : 1) : (c.chance(0.55) ? 2 : 3)
                        needles.line(tone, CGPoint(x: px, y: y), CGPoint(x: px + side * c.f(0.018, 0.035), y: y - c.f(0.016, 0.03)))
                    }
                    needles.stroke(c, [lit.lit(0.7), lit, green.shade(0.5), deep], alpha: 0.8, width: 0.012)
                }
                if snowy {
                    // Snow where this tier is open to the sky: below the next tier's skirt.
                    let covered = i + 1 < list.count ? list[i + 1].yBot - 0.01 : tier.apex.y - 0.03
                    let clumps = Marks(2)
                    for (edge, west) in [(tier.westEdge, true), (tier.eastEdge, false)] {
                        let count = west ? c.int(2...4) : c.int(0...2)
                        for _ in 0..<count {
                            let s = c.f(0.15, 0.92)
                            let k = min(Int(s * 5), 4), f = s * 5 - CGFloat(k)
                            let p = lerp(edge[k], edge[k + 1], f)
                            guard p.y < covered else { continue }
                            let rx = c.f(0.014, west ? 0.03 : 0.02)
                            clumps.paths[west ? 0 : 1].addPath(c.blob(CGPoint(x: p.x + (west ? 1 : -1) * rx * 0.5, y: p.y - 0.004), rx, rx * c.f(0.4, 0.6),
                                                                      lobes: 6, wobble: 0.3))
                        }
                    }
                    // Along the upper surface, peeking out under the next tier.
                    if i + 1 < list.count {
                        for _ in 0..<c.int(1...3) {
                            let x = tier.apex.x + c.f(-0.8, 0.5) * list[i + 1].west
                            let rx = c.f(0.018, 0.034)
                            clumps.paths[x < tier.apex.x ? 0 : 1].addPath(c.blob(CGPoint(x: x, y: list[i + 1].yBot - 0.004), rx, rx * 0.45, lobes: 6, wobble: 0.3))
                        }
                    }
                    // Branch tips.
                    if c.chance(0.8) {
                        clumps.paths[0].addPath(c.blob(CGPoint(x: tier.westEdge[5].x + 0.012, y: tier.westEdge[5].y + 0.004), c.f(0.018, 0.03), 0.011, lobes: 6, wobble: 0.25))
                    }
                    if c.chance(0.5) {
                        clumps.paths[1].addPath(c.blob(CGPoint(x: tier.eastEdge[5].x - 0.012, y: tier.eastEdge[5].y + 0.004), c.f(0.014, 0.022), 0.009, lobes: 6, wobble: 0.25))
                    }
                    clumps.fill(c, [snowLit, snowShade])
                }
                drawn.addPath(tier.path)
            }
            if snowy, let crown = list.last, !broken {
                // A cap on the crown, heavier on the sunlit side.
                let h = crown.apex.y - crown.yBot
                let cap = polygon([CGPoint(x: crown.apex.x, y: crown.apex.y + 0.004),
                                   CGPoint(x: crown.apex.x - crown.west * c.f(0.36, 0.5), y: crown.apex.y - h * c.f(0.36, 0.46)),
                                   CGPoint(x: crown.apex.x - crown.west * 0.1, y: crown.apex.y - h * c.f(0.26, 0.34)),
                                   CGPoint(x: crown.apex.x + crown.east * c.f(0.2, 0.32), y: crown.apex.y - h * c.f(0.3, 0.4))])
                c.fill(cap, snowLit)
                c.clip(cap) {
                    c.fill(polygon([crown.apex, CGPoint(x: crown.apex.x + 0.2, y: crown.apex.y - 0.3), CGPoint(x: crown.apex.x + 0.2, y: crown.apex.y)]), snowShade)
                }
            }
        }
    }

    /// Deciduous trees: oak, linden, poplar, birch, olive and darker woodland variants.
    fileprivate static func broadleaf(_ c: Canvas, variant v: Int) {
        let a = c.aspect, foot = c.foot
        // (leaf, crown rx, ry, crown center height, clump count, bark)
        let looks: [(leaf: Tone, rx: CGFloat, ry: CGFloat, cy: CGFloat, clumps: Int, bark: Tone)] = [
            (Tone(0.25, 0.46, 0.16), 0.40, 0.33, 0.58, 9, Tone(0.38, 0.27, 0.19)),  // oak
            (Tone(0.32, 0.52, 0.16), 0.37, 0.34, 0.59, 8, Tone(0.40, 0.29, 0.20)),  // linden
            (Tone(0.26, 0.47, 0.18), 0.23, 0.40, 0.55, 7, Tone(0.38, 0.28, 0.20)),  // poplar
            (Tone(0.40, 0.56, 0.20), 0.31, 0.33, 0.60, 7, Tone(0.86, 0.84, 0.78)),  // birch
            (Tone(0.37, 0.53, 0.21), 0.45, 0.21, 0.56, 9, Tone(0.36, 0.29, 0.22)),  // olive: sage umbrella
            (Tone(0.19, 0.40, 0.15), 0.40, 0.34, 0.58, 9, Tone(0.33, 0.24, 0.18)),  // dark oak
            (Tone(0.29, 0.49, 0.14), 0.37, 0.31, 0.57, 8, Tone(0.38, 0.27, 0.19)),  // maple
        ]
        let kind = v % looks.count
        let look = looks[kind]
        let rx = look.rx * a * c.f(0.95, 1.05) / 0.86, ry = look.ry * c.f(0.95, 1.05)
        let center = CGPoint(x: foot.x + c.f(-0.02, 0.02), y: look.cy)
        c.contactShadow(foot, width: rx * 2.0, height: 0.09)

        // A short, sturdy trunk: the crown hangs low over it.
        let trunkTop = CGPoint(x: center.x + c.f(-0.02, 0.02), y: center.y - ry * 0.15)
        let w: CGFloat = kind == 2 ? 0.06 : (kind == 3 ? 0.066 : 0.085)
        // (An olive's trunk is gnarled and leaning.)
        let trunkPath = trunk(from: foot, to: trunkTop, width: w, curve: kind == 4 ? c.sign() * c.f(0.04, 0.06) : c.f(-0.02, 0.02))
        // Clumps around the crown's rim (irregular, some hanging lower) plus a core; upper ones
        // are drawn first.
        var clumps: [(p: CGPoint, r: CGFloat)] = [(center, min(rx, ry) * 0.66)]
        let phase = c.f(0, 2 * .pi)
        for k in 0..<look.clumps {
            let t = phase + 2 * .pi * CGFloat(k) / CGFloat(look.clumps) + c.f(-0.3, 0.3)
            let d = c.f(0.46, 0.7)
            clumps.append((CGPoint(x: center.x + cos(t) * rx * d, y: center.y + sin(t) * ry * d), min(rx, ry) * c.f(0.38, 0.56)))
        }
        let crownParts = clumps.map { c.blob($0.p, $0.r * 1.02, $0.r * 0.96, lobes: 7, wobble: 0.08) as CGPath }

        c.fadeBase(foot.y - 0.03, foot.y + 0.02) {
            c.outline([trunkPath] + crownParts, width: 0.02)
            paintTrunk(c, trunkPath, bark: look.bark, foot: foot, width: w)
            if kind == 3 { // birch bark marks
                let marks = Marks(1)
                for _ in 0..<7 {
                    let y = c.f(foot.y + 0.03, trunkTop.y - 0.05)
                    marks.line(0, CGPoint(x: foot.x - w * 0.3, y: y), CGPoint(x: foot.x + c.f(-0.01, w * 0.3), y: y + c.f(-0.004, 0.004)))
                }
                c.clip(trunkPath) { marks.stroke(c, [Tone(0.2, 0.17, 0.15)], alpha: 0.8, width: 0.01) }
            }
            // Branches into the crown and the crown's shadow on the trunk.
            let branches = Marks(1)
            branches.curve(0, CGPoint(x: trunkTop.x, y: trunkTop.y - 0.08), CGPoint(x: trunkTop.x - rx * 0.2, y: trunkTop.y),
                           CGPoint(x: trunkTop.x - rx * 0.45, y: trunkTop.y + ry * 0.3))
            branches.curve(0, CGPoint(x: trunkTop.x, y: trunkTop.y - 0.06), CGPoint(x: trunkTop.x + rx * 0.2, y: trunkTop.y + 0.02),
                           CGPoint(x: trunkTop.x + rx * 0.4, y: trunkTop.y + ry * 0.35))
            branches.stroke(c, [look.bark.shade(0.8)], width: 0.022)
            canopy(c, clumps, center: center, size: max(rx, ry), leaf: look.leaf, dab: 0.022)
            if kind == 4 {
                // Olive: silver-green glints only where the sun catches the top of the crown.
                let glints = Marks(1)
                for _ in 0..<26 {
                    let k = clumps[c.int(0...(clumps.count - 1))]
                    let ang = c.f(0.5, 2.4), d = k.r * c.f(0.3, 0.95)
                    glints.dab(0, CGPoint(x: k.p.x + cos(ang) * d, y: k.p.y + sin(ang) * d), 0.016, 0.009)
                }
                glints.fill(c, [Tone(0.68, 0.75, 0.54)], alpha: 0.7)
            }
            c.clip(trunkPath) {
                c.fill(polygon([CGPoint(x: foot.x - 0.2, y: center.y - ry * 0.75), CGPoint(x: foot.x + 0.2, y: center.y - ry * 0.95),
                                CGPoint(x: foot.x + 0.2, y: center.y), CGPoint(x: foot.x - 0.2, y: center.y)]), Tone(0.1, 0.1, 0.2), 0.35)
            }
        }
    }

    /// Rainforest trees: a broad, layered canopy of saturated greens hanging low over a short
    /// buttressed trunk, and vines; every other variant is an emergent whose crown rises above
    /// the canopy, and one flowers.
    fileprivate static func jungleTree(_ c: Canvas, variant v: Int) {
        let a = c.aspect, foot = c.foot
        // Darker and bluer than the temperate broadleaf greens, so jungle never reads as forest.
        let leaves = [Tone(0.06, 0.31, 0.15), Tone(0.09, 0.35, 0.14), Tone(0.04, 0.28, 0.16), Tone(0.10, 0.37, 0.15), Tone(0.06, 0.33, 0.16)]
        let leaf = leaves[v % leaves.count]
        let emergent = v % 2 == 1
        let rx = a * c.f(0.4, 0.45), ry = c.f(0.2, 0.25)
        let center = CGPoint(x: foot.x + c.f(-0.03, 0.03), y: emergent ? c.f(0.58, 0.62) : c.f(0.54, 0.58))
        c.contactShadow(foot, width: rx * 1.9, height: 0.1)
        let trunkTop = CGPoint(x: center.x + c.f(-0.02, 0.02), y: center.y - ry * 0.2)
        let bark = Tone(0.42, 0.34, 0.26)
        let trunkPath = trunk(from: foot, to: trunkTop, width: 0.07, curve: c.f(-0.02, 0.02))
        let roots = CGMutablePath()
        for side: CGFloat in [-1, 1] {
            let reach = c.f(0.08, 0.12)
            roots.addPath(polygon([CGPoint(x: foot.x + side * reach, y: foot.y - 0.012), CGPoint(x: foot.x + side * 0.012, y: foot.y + c.f(0.1, 0.15)),
                                   CGPoint(x: foot.x - side * 0.01, y: foot.y - 0.012)]))
        }

        // Canopy: a flattened dome of clumps across the crown, a few hanging lower, and for
        // emergents a crown above.
        var clumps: [(p: CGPoint, r: CGFloat)] = []
        let count = c.int(8...10)
        for k in 0..<count {
            let ang = CGFloat.pi * (1 - CGFloat(k) / CGFloat(count - 1))
            clumps.append((CGPoint(x: center.x + cos(ang) * rx * c.f(0.62, 0.8), y: center.y + sin(ang) * ry * c.f(0.5, 0.95) - ry * 0.1),
                           ry * c.f(0.6, 0.8)))
        }
        for _ in 0..<2 {
            clumps.append((CGPoint(x: center.x + c.f(-rx * 0.6, rx * 0.6), y: center.y - ry * c.f(0.35, 0.55)), ry * c.f(0.5, 0.62)))
        }
        if emergent { clumps.append((CGPoint(x: center.x + c.f(-0.05, 0.05), y: center.y + ry * 1.05), ry * c.f(0.62, 0.75))) }
        let crownParts = clumps.map { c.blob($0.p, $0.r * 1.02, $0.r * 0.96, lobes: 7, wobble: 0.08) as CGPath }

        c.fadeBase(foot.y - 0.03, foot.y + 0.02) {
            c.outline([trunkPath, roots] + crownParts, width: 0.02)
            c.fill(roots, bark.shade(0.6))
            paintTrunk(c, trunkPath, bark: bark, foot: foot, width: 0.07)
            canopy(c, clumps, center: center, size: max(rx, ry), leaf: leaf, dab: 0.02)
            // Hanging vines.
            let vines = Marks(1)
            for _ in 0..<c.int(3...5) {
                let x = center.x + c.f(-rx * 0.8, rx * 0.8), y = center.y - ry * c.f(0.3, 0.6)
                vines.curve(0, CGPoint(x: x, y: y), CGPoint(x: x + c.f(-0.02, 0.02), y: y - 0.06), CGPoint(x: x + c.f(-0.01, 0.01), y: y - c.f(0.08, 0.18)))
            }
            vines.stroke(c, [leaf.shade(1.3)], alpha: 0.9, width: 0.01)
            if v % 5 == 4 {
                // A flowering tree: pale blossoms over the sunlit top of the crown (soft pink,
                // cream and lilac, well away from the saturated player colors).
                let blossoms = Marks(3)
                for _ in 0..<28 {
                    let k = clumps[c.int(0...(clumps.count - 1))]
                    let ang = c.f(0.2, 2.6), d = k.r * c.f(0.2, 0.9)
                    blossoms.dab(c.int(0...2), CGPoint(x: k.p.x + cos(ang) * d, y: k.p.y + sin(ang) * d), 0.014, 0.011)
                }
                blossoms.fill(c, [Tone(0.97, 0.86, 0.88), Tone(0.95, 0.93, 0.84), Tone(0.84, 0.76, 0.94)], alpha: 0.95)
            }
        }
    }

    /// Palms: arching fronds with serrated leaflets over a ringed trunk; the date palm is
    /// stiffer and sage green with brown date clusters.
    fileprivate static func palm(_ c: Canvas, date: Bool, variant v: Int) {
        let foot = c.foot
        let lean = date ? c.f(-0.04, 0.04) : (v % 2 == 0 ? 1 : -1) * c.f(0.08, 0.16)
        let crown = CGPoint(x: foot.x + lean, y: date ? c.f(0.62, 0.7) : c.f(0.66, 0.74))
        let leaf = date ? Tone(0.30, 0.47, 0.2) : [Tone(0.11, 0.40, 0.17), Tone(0.15, 0.43, 0.16), Tone(0.09, 0.36, 0.18), Tone(0.13, 0.41, 0.17)][v % 4]
        let bark = date ? Tone(0.50, 0.38, 0.26) : Tone(0.52, 0.42, 0.30)
        c.contactShadow(foot, width: 0.5, height: 0.08)
        let w: CGFloat = date ? 0.075 : 0.05
        let trunkPath = trunk(from: foot, to: crown, width: w, curve: -lean * 0.4)

        // Fronds: angle around the crown, drooping with length.
        let count = date ? c.int(12...14) : c.int(8...10)
        struct Frond { var path: CGMutablePath; var rib: [CGPoint]; var light: CGFloat }
        var fronds: [Frond] = []
        for k in 0..<count {
            let t = CGFloat(k) / CGFloat(count)
            let ang = .pi * (date ? 0.05 + 0.9 * t : -0.1 + 1.2 * t) + c.f(-0.12, 0.12)
            let len = (date ? c.f(0.3, 0.38) : c.f(0.32, 0.42)) * (0.8 + 0.2 * sin(ang))
            let droop = date ? c.f(0.04, 0.1) : c.f(0.1, 0.2)
            let tip = CGPoint(x: crown.x + cos(ang) * len, y: crown.y + sin(ang) * len * 0.75 - droop)
            let ctl = CGPoint(x: crown.x + cos(ang) * len * 0.55, y: crown.y + sin(ang) * len * 0.6 + 0.05)
            var rib: [CGPoint] = []
            for i in 0...10 {
                let s = CGFloat(i) / 10
                rib.append(lerp(lerp(crown, ctl, s), lerp(ctl, tip, s), s))
            }
            // Serrated blade: leaflets alternate long and short on both sides.
            var upper: [CGPoint] = [], lower: [CGPoint] = []
            for i in 1..<rib.count {
                let s = CGFloat(i) / CGFloat(rib.count - 1)
                let d = CGPoint(x: rib[i].x - rib[i - 1].x, y: rib[i].y - rib[i - 1].y)
                let l = max(hypot(d.x, d.y), 1e-4)
                let nrm = CGPoint(x: -d.y / l, y: d.x / l)
                let width = (date ? 0.048 : 0.056) * sin(min(1, s * 1.15) * .pi) * (i % 2 == 0 ? 1 : 0.55)
                upper.append(CGPoint(x: rib[i].x + nrm.x * width + d.x * 0.6, y: rib[i].y + nrm.y * width + d.y * 0.6 - width * 0.3))
                lower.append(CGPoint(x: rib[i].x - nrm.x * width + d.x * 0.6, y: rib[i].y - nrm.y * width + d.y * 0.6 - width * 0.3))
            }
            fronds.append(Frond(path: polygon([crown] + upper + lower.reversed()), rib: rib, light: facing(CGPoint(x: cos(ang), y: sin(ang)))))
        }
        // Back fronds (pointing up and away) first; the drooping front ones last.
        let order = fronds.indices.sorted { fronds[$0].rib[10].y > fronds[$1].rib[10].y }

        c.fadeBase(foot.y - 0.03, foot.y + 0.02) {
            c.outline([trunkPath] + fronds.map(\.path), width: 0.018)
            paintTrunk(c, trunkPath, bark: bark, foot: foot, width: w)
            let rings = Marks(1)
            for k in 0..<14 {
                let p = lerp(foot, crown, CGFloat(k) / 14 + 0.03)
                let bend = -lean * 0.4 * sin(CGFloat(k) / 14 * .pi)
                rings.curve(0, CGPoint(x: p.x + bend - w * 0.5, y: p.y), CGPoint(x: p.x + bend, y: p.y - 0.012), CGPoint(x: p.x + bend + w * 0.5, y: p.y))
            }
            c.clip(trunkPath) { rings.stroke(c, [bark.shade(1.3)], alpha: 0.6, width: 0.007) }
            if date {
                let dates = Marks(2)
                for k in 0..<c.int(3...5) {
                    let x = crown.x + c.f(-0.07, 0.07), y = crown.y - c.f(0.03, 0.06)
                    for _ in 0..<6 { dates.dab(k % 2, CGPoint(x: x + c.f(-0.02, 0.02), y: y - c.f(0, 0.05)), 0.011, 0.011) }
                }
                dates.fill(c, [Tone(0.50, 0.32, 0.18), Tone(0.38, 0.24, 0.14)])
            } else {
                let nuts = Marks(1)
                for _ in 0..<c.int(2...4) { nuts.dab(0, CGPoint(x: crown.x + c.f(-0.03, 0.03), y: crown.y - c.f(0.01, 0.04)), 0.02, 0.02) }
                nuts.fill(c, [Tone(0.40, 0.30, 0.16)])
            }
            for i in order {
                let fr = fronds[i]
                let tone = fr.light > 0.2 ? leaf.mix(leaf.lit(), fr.light * 0.6) : leaf.mix(leaf.shade(1.3), (0.2 - fr.light) * 0.6)
                c.fill(fr.path, tone)
                let rib = CGMutablePath()
                smoothOpen(fr.rib, into: rib)
                c.clip(fr.path) {
                    var shift = CGAffineTransform(translationX: 0.01, y: -0.012)
                    if let under = fr.path.copy(using: &shift) { c.fill(under, tone.shade(1.2), 0.5) }
                }
                c.stroke(rib, tone.lit(0.8), 0.7, width: 0.008)
            }
        }
    }
}

// MARK: - Plants and rocks

extension DecorSprite {
    /// Marsh reeds and cattails: a fan of blades, a few velvet-brown heads.
    fileprivate static func reeds(_ c: Canvas, variant v: Int) {
        let a = c.aspect, foot = c.foot
        c.contactShadow(foot, width: a * 0.7, height: 0.09, alpha: 0.35)
        let blades = Marks(4), heads = Marks(2)
        let count = 13 + v * 2
        let outline = CGMutablePath()
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let x = foot.x + (t - 0.5) * a * 0.5 + c.f(-0.03, 0.03)
            let h = c.f(0.45, 0.85) * (1 - abs(t - 0.5) * 0.6)
            let lean = (t - 0.5) * 0.35 + c.f(-0.08, 0.08)
            let p0 = CGPoint(x: x, y: foot.y), tip = CGPoint(x: x + lean, y: foot.y + h)
            let ctl = CGPoint(x: x + lean * 0.2, y: foot.y + h * 0.6)
            let tone = lean < -0.02 ? 0 : (lean < 0.06 ? 1 : (c.chance(0.5) ? 2 : 3))
            blades.curve(tone, p0, ctl, tip)
            outline.move(to: p0)
            outline.addQuadCurve(to: tip, control: ctl)
            if i % 4 == 1 {
                let hp = CGPoint(x: x + lean * 0.75, y: foot.y + h * 0.82)
                heads.paths[0].addPath(CGPath(roundedRect: CGRect(x: hp.x - 0.022, y: hp.y - 0.07, width: 0.044, height: 0.14),
                                              cornerWidth: 0.02, cornerHeight: 0.02, transform: nil))
                heads.dab(1, CGPoint(x: hp.x - 0.007, y: hp.y + 0.02), 0.007, 0.03)
            }
        }
        let silhouette = outline.copy(strokingWithWidth: 0.022, lineCap: .round, lineJoin: .round, miterLimit: 2)
        c.fadeBase(foot.y - 0.04, foot.y + 0.06) {
            c.outline([silhouette, heads.paths[0]], width: 0.022, alpha: 0.4)
            blades.stroke(c, [Tone(0.62, 0.70, 0.34), Tone(0.42, 0.56, 0.24), Tone(0.30, 0.42, 0.22), Tone(0.22, 0.32, 0.22)], width: 0.022)
            heads.fill(c, [Tone(0.42, 0.27, 0.15), Tone(0.62, 0.44, 0.28)])
        }
    }

    /// Jungle undergrowth: broad fern fronds radiating from the base.
    fileprivate static func fern(_ c: Canvas, variant v: Int) {
        let a = c.aspect, foot = c.foot
        let leaf = [Tone(0.16, 0.48, 0.16), Tone(0.22, 0.52, 0.14), Tone(0.12, 0.42, 0.20)][v % 3]
        c.contactShadow(foot, width: a * 0.75, height: 0.12, alpha: 0.4)
        var fronds: [(CGPath, CGFloat)] = []
        let count = c.int(6...8)
        for k in 0..<count {
            let t = CGFloat(k) / CGFloat(count - 1)
            let ang = .pi * (0.08 + 0.84 * t) + c.f(-0.1, 0.1)
            let len = c.f(0.45, 0.62) * (0.7 + 0.3 * sin(ang))
            let tip = CGPoint(x: foot.x + cos(ang) * len * 1.2, y: foot.y + sin(ang) * len * 0.9 - 0.1)
            let ctl = CGPoint(x: foot.x + cos(ang) * len * 0.6, y: foot.y + sin(ang) * len * 1.05)
            var upper: [CGPoint] = [], lower: [CGPoint] = []
            var prev = foot
            for i in 1...9 {
                let s = CGFloat(i) / 9
                let p = lerp(lerp(foot, ctl, s), lerp(ctl, tip, s), s)
                let d = CGPoint(x: p.x - prev.x, y: p.y - prev.y), l = max(hypot(d.x, d.y), 1e-4)
                let nrm = CGPoint(x: -d.y / l, y: d.x / l)
                let wdt = 0.07 * sin(min(1, s * 1.1) * .pi) * (i % 2 == 0 ? 1 : 0.6)
                upper.append(CGPoint(x: p.x + nrm.x * wdt, y: p.y + nrm.y * wdt))
                lower.append(CGPoint(x: p.x - nrm.x * wdt, y: p.y - nrm.y * wdt))
                prev = p
            }
            fronds.append((polygon([foot] + upper + lower.reversed()), facing(CGPoint(x: cos(ang), y: sin(ang)))))
        }
        c.fadeBase(foot.y - 0.05, foot.y + 0.05) {
            c.outline(fronds.map(\.0), width: 0.03, alpha: 0.4)
            for (path, light) in fronds.sorted(by: { $0.1 < $1.1 }) {
                c.fill(path, light > 0 ? leaf.mix(leaf.lit(), light * 0.6) : leaf.mix(leaf.shade(), -light * 0.7))
            }
        }
    }

    /// A low, flat-bottomed bush: a row of three or four clumps on the ground with one or two
    /// above, a dome rather than a row; some carry pale blossoms.
    fileprivate static func shrub(_ c: Canvas, variant v: Int) {
        let a = c.aspect, foot = c.foot
        let leaf = [Tone(0.24, 0.44, 0.18), Tone(0.36, 0.46, 0.22), Tone(0.30, 0.40, 0.24), Tone(0.20, 0.40, 0.20)][v % 4]
        let width = a * c.f(0.5, 0.58)
        c.contactShadow(foot, width: width * 1.25, height: 0.14, alpha: 0.4)
        var clumps: [(p: CGPoint, r: CGFloat)] = []
        let lower = c.int(3...4)
        for k in 0..<lower {
            let t = CGFloat(k) / CGFloat(lower - 1), r = c.f(0.14, 0.18)
            clumps.append((CGPoint(x: foot.x + (t - 0.5) * (width - r * 1.4) + c.f(-0.02, 0.02), y: foot.y + r * 0.85 + c.f(-0.01, 0.01)), r))
        }
        let upper = c.int(1...2)
        for k in 0..<upper {
            let x = upper == 1 ? c.f(-0.06, 0.06) : (k == 0 ? -1 : 1) * c.f(0.08, 0.13)
            let r = c.f(0.14, 0.18)
            clumps.append((CGPoint(x: foot.x + x - 0.02, y: foot.y + c.f(0.3, 0.36)), r))
        }
        let parts = clumps.map { c.blob($0.p, $0.r, $0.r * 0.95, lobes: 7, wobble: 0.1) as CGPath }
        c.fadeBase(foot.y - 0.05, foot.y + 0.05) {
            c.outline(parts, width: 0.035, alpha: 0.4)
            canopy(c, clumps, center: CGPoint(x: foot.x, y: foot.y + 0.26), size: 0.4, leaf: leaf, dab: 0.04)
            if v % 2 == 1 {
                let blossoms = Marks(1)
                for _ in 0..<9 {
                    let k = clumps[c.int(0...(clumps.count - 1))]
                    blossoms.dab(0, CGPoint(x: k.p.x + c.f(-k.r, k.r) * 0.6, y: k.p.y + c.f(-k.r, k.r) * 0.5), 0.022, 0.018)
                }
                blossoms.fill(c, [v == 1 ? Tone(0.97, 0.95, 0.86) : Tone(0.95, 0.84, 0.88)], alpha: 0.9)
            }
        }
    }

    /// Grass tuft: many thin blades springing from a dense base, dry gold or green with small
    /// pale flowers.
    fileprivate static func tuft(_ c: Canvas, flowers: Bool, variant v: Int) {
        let a = c.aspect, foot = c.foot
        let tones = flowers ? [Tone(0.60, 0.74, 0.34), Tone(0.42, 0.60, 0.24), Tone(0.28, 0.44, 0.20)]
            : [Tone(0.94, 0.85, 0.56), Tone(0.80, 0.67, 0.40), Tone(0.56, 0.45, 0.29)]
        c.contactShadow(foot, width: a * 0.55, height: 0.12, alpha: 0.32)
        let blades = Marks(3)
        let outline = CGMutablePath()
        let count = c.int(22...26)
        for _ in 0..<count {
            let t = c.f(0, 1)
            let x = foot.x + (t - 0.5) * a * 0.2
            let h = c.f(0.3, 0.66) * (1 - abs(t - 0.5) * 0.7)
            // Mostly upright with a gentle outward lean; a few cross over.
            let lean = (t - 0.5) * 0.34 + c.f(-0.1, 0.1)
            let tip = CGPoint(x: x + lean, y: foot.y + h), ctl = CGPoint(x: x + lean * 0.15, y: foot.y + h * 0.65)
            let tone = lean < -0.05 ? 0 : (lean < 0.08 ? 1 : 2)
            blades.curve(tone, CGPoint(x: x, y: foot.y), ctl, tip)
            outline.move(to: CGPoint(x: x, y: foot.y))
            outline.addQuadCurve(to: tip, control: ctl)
        }
        let silhouette = outline.copy(strokingWithWidth: 0.026, lineCap: .round, lineJoin: .round, miterLimit: 2)
        c.fadeBase(foot.y - 0.05, foot.y + 0.08) {
            c.outline([silhouette], width: 0.026, alpha: 0.35)
            blades.stroke(c, tones, width: 0.026)
            // The dense base, shaded.
            c.fill(c.blob(CGPoint(x: foot.x + 0.01, y: foot.y + 0.03), a * 0.11, 0.05, lobes: 7, wobble: 0.2), tones[2].shade(0.6), 0.85)
            if flowers {
                let petals = Marks(3)
                for _ in 0..<7 {
                    petals.dab(v % 3, CGPoint(x: foot.x + c.f(-0.24, 0.24), y: foot.y + c.f(0.25, 0.52)), 0.036, 0.03)
                }
                petals.fill(c, [Tone(0.97, 0.95, 0.86), Tone(0.95, 0.84, 0.88), Tone(0.84, 0.78, 0.95)])
            }
        }
    }

    /// Cacti: saguaro with arms, barrel cactus, prickly pear pads; ribbed and lit from the west.
    fileprivate static func cactus(_ c: Canvas, variant v: Int) {
        let a = c.aspect, foot = c.foot
        let green = Tone(0.38, 0.52, 0.30)
        c.contactShadow(foot, width: a * 0.7, height: 0.1, alpha: 0.4)
        var parts: [CGPath] = []
        switch v % 4 {
        case 0, 1:
            let w: CGFloat = 0.13, h = c.f(0.72, 0.82)
            parts.append(CGPath(roundedRect: CGRect(x: foot.x - w / 2, y: foot.y - 0.02, width: w, height: h), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
            for side in v % 4 == 0 ? [-1.0, 1.0] : [1.0] {
                let s = CGFloat(side)
                let y0 = foot.y + c.f(0.22, 0.36), reach = c.f(0.13, 0.17), up = c.f(0.18, 0.28)
                let arm = CGMutablePath()
                arm.addRoundedRect(in: CGRect(x: min(foot.x, foot.x + s * reach) - (s < 0 ? w * 0.4 : 0), y: y0, width: reach + w * 0.4, height: w * 0.8),
                                   cornerWidth: w * 0.4, cornerHeight: w * 0.4)
                arm.addRoundedRect(in: CGRect(x: foot.x + s * reach - w * 0.4, y: y0, width: w * 0.8, height: up), cornerWidth: w * 0.4, cornerHeight: w * 0.4)
                parts.append(arm)
            }
        case 2:
            parts.append(c.blob(CGPoint(x: foot.x, y: foot.y + 0.22), 0.24, 0.24, lobes: 10, wobble: 0.04))
        default:
            for (dx, dy, r) in [(-0.12, 0.22, 0.15), (0.1, 0.3, 0.16), (-0.02, 0.5, 0.13), (0.16, 0.56, 0.11)] as [(CGFloat, CGFloat, CGFloat)] {
                parts.append(CGPath(ellipseIn: CGRect(x: foot.x + dx - r * 0.8, y: foot.y + dy - r, width: r * 1.6, height: r * 2), transform: nil))
            }
        }
        c.fadeBase(foot.y - 0.04, foot.y + 0.03) {
            c.outline(parts, width: 0.035, alpha: 0.42)
            for part in parts {
                let b = part.boundingBoxOfPath
                c.linear(part, [(green.lit(1.2), 1), (green, 1), (green.shade(1.3), 1)], from: CGPoint(x: b.minX, y: 0), to: CGPoint(x: b.maxX, y: 0))
                let ribs = Marks(1)
                for k in 1..<4 {
                    let x = b.minX + b.width * CGFloat(k) / 4
                    ribs.line(0, CGPoint(x: x, y: b.minY + 0.02), CGPoint(x: x, y: b.maxY - 0.03))
                }
                c.clip(part) { ribs.stroke(c, [green.shade(1.6)], alpha: 0.45, width: 0.012) }
            }
            if v % 4 == 2 { c.fill(c.blob(CGPoint(x: foot.x, y: foot.y + 0.45), 0.05, 0.03), Tone(0.96, 0.82, 0.86)) }
        }
    }

    /// Boulders: faceted lumps, lit top-left faces, cracks; mossy, sandstone or snow-capped.
    fileprivate static func rocks(_ c: Canvas, kind: RockKind, variant v: Int) {
        let a = c.aspect, foot = c.foot
        let stone: Tone = switch kind {
        case .boulder: [Tone(0.60, 0.58, 0.54), Tone(0.54, 0.54, 0.56), Tone(0.64, 0.60, 0.52), Tone(0.56, 0.55, 0.50)][v % 4]
        case .sandstone: [Tone(0.84, 0.58, 0.40), Tone(0.78, 0.52, 0.36), Tone(0.86, 0.66, 0.46), Tone(0.74, 0.46, 0.34)][v % 4]
        case .snowy: Tone(0.50, 0.51, 0.56)
        }
        c.contactShadow(foot, width: a * 0.8, height: 0.16, alpha: 0.45)
        let count = [1, 2, 3, 2][v % 4]
        var lumps: [(CGPoint, CGFloat)] = []
        for k in 0..<count {
            let r = k == 0 ? c.f(0.3, 0.38) : c.f(0.16, 0.24)
            let x = foot.x + (k == 0 ? 0 : (k == 1 ? 1 : -1) * c.f(0.28, 0.36))
            lumps.append((CGPoint(x: x, y: foot.y + r * 0.62), r))
        }
        lumps.sort { $0.0.y > $1.0.y }
        var parts: [CGPath] = []
        for (p, r) in lumps {
            // Faceted: few corners, flat bottom.
            var pts: [CGPoint] = []
            for k in 0..<6 {
                let t = CGFloat(k) / 6 * 2 * .pi + c.f(-0.2, 0.2)
                let w = 1 + c.f(-0.12, 0.12)
                pts.append(CGPoint(x: p.x + cos(t) * r * 1.15 * w, y: max(foot.y - 0.02, p.y + sin(t) * r * 0.8 * w)))
            }
            parts.append(polygon(pts))
        }
        c.fadeBase(foot.y - 0.05, foot.y + 0.03) {
            c.outline(parts, width: 0.035, alpha: 0.45)
            for (i, part) in parts.enumerated() {
                let (p, r) = lumps[i]
                c.fill(part, stone.shade(1.1))
                c.clip(part) {
                    c.fill(polygon([CGPoint(x: p.x - r * 2, y: p.y + r * 2), CGPoint(x: p.x + r * 0.35, y: p.y + r * 2),
                                    CGPoint(x: p.x + r * 0.1, y: p.y - r * 0.2), CGPoint(x: p.x - r * 2, y: p.y - r * 0.5)]), stone)
                    c.fill(polygon([CGPoint(x: p.x - r * 2, y: p.y + r * 2), CGPoint(x: p.x + r * 0.5, y: p.y + r * 2),
                                    CGPoint(x: p.x + r * 0.2, y: p.y + r * 0.35), CGPoint(x: p.x - r * 2, y: p.y + r * 0.2)]), stone.lit(), 0.85)
                    let crack = Marks(1)
                    crack.line(0, CGPoint(x: p.x + c.f(-0.3, 0.1) * r, y: p.y + r * 0.6), CGPoint(x: p.x + c.f(-0.1, 0.3) * r, y: p.y - r * 0.3))
                    crack.stroke(c, [stone.shade(1.8)], alpha: 0.6, width: 0.02)
                    if kind == .boulder, v % 2 == 0 { // moss on the sunny top
                        c.fill(c.blob(CGPoint(x: p.x - r * 0.3, y: p.y + r * 0.75), r * 0.6, r * 0.25), Tone(0.42, 0.52, 0.24), 0.8)
                    }
                    if kind == .sandstone {
                        let bands = Marks(1)
                        for k in 0..<3 {
                            bands.line(0, CGPoint(x: p.x - r * 1.3, y: p.y - r * 0.3 + CGFloat(k) * r * 0.35),
                                       CGPoint(x: p.x + r * 1.3, y: p.y - r * 0.32 + CGFloat(k) * r * 0.35))
                        }
                        bands.stroke(c, [Tone(0.62, 0.34, 0.26)], alpha: 0.35, width: 0.018)
                    }
                    if kind == .snowy {
                        c.fill(c.blob(CGPoint(x: p.x - r * 0.1, y: p.y + r * 0.7), r * 1.0, r * 0.38, lobes: 7, wobble: 0.18), Tone(0.94, 0.94, 0.93))
                        c.fill(c.blob(CGPoint(x: p.x + r * 0.55, y: p.y + r * 0.55), r * 0.45, r * 0.22), Tone(0.72, 0.78, 0.92))
                    }
                }
            }
        }
    }
}

extension DecorSprite {
    /// Lingering snow lying on a slope: a ragged white patch with a few flecks around it,
    /// blue where it turns from the sun and along its lower edge. A surface marking, so only a
    /// faint outline and no shadow.
    fileprivate static func snowPatch(_ c: Canvas, variant v: Int) {
        let a = c.aspect, foot = c.foot
        let snowLit = Tone(0.94, 0.95, 0.94), snowShade = Tone(0.72, 0.79, 0.92)
        let patch = CGMutablePath()
        let rx = a * c.f(0.3, 0.36), ry = c.f(0.16, 0.2)
        let center = CGPoint(x: foot.x + c.f(-0.05, 0.05), y: foot.y + ry * 0.9)
        patch.addPath(c.blob(center, rx, ry, lobes: 11, wobble: 0.3))
        for _ in 0..<(1 + v % 3) {
            let q = CGPoint(x: center.x + c.sign() * rx * c.f(0.55, 0.9), y: center.y + c.f(-0.5, 0.3) * ry)
            patch.addPath(c.blob(q, rx * c.f(0.3, 0.5), ry * c.f(0.5, 0.8), lobes: 8, wobble: 0.35))
        }
        let flecks = Marks(2)
        for _ in 0..<c.int(4...7) {
            let q = CGPoint(x: center.x + c.f(-1.5, 1.5) * rx, y: center.y + c.f(-1.6, 1.4) * ry)
            flecks.dab(q.x > center.x + rx * 0.4 ? 1 : 0, q, c.f(0.03, 0.06), c.f(0.012, 0.024))
        }
        c.layer(alpha: 0.25) { c.stroke(patch, .ink, 1, width: 0.03) }
        c.fill(patch, snowLit)
        c.clip(patch) {
            c.sweep([(snowShade, 0), (snowShade, 0.8)], from: CGPoint(x: center.x - rx * 0.3, y: center.y + ry), to: CGPoint(x: center.x + rx, y: center.y - ry))
            c.sweep([(snowShade, 0.5), (snowShade, 0)], from: CGPoint(x: 0, y: center.y - ry), to: CGPoint(x: 0, y: center.y))
        }
        flecks.fill(c, [snowLit, snowShade], alpha: 0.9)
    }
}

// MARK: - Improvements

extension DecorSprite {
    /// A mine's entrance, set into a bare hillside: a rocky cut lit from the upper left, the
    /// adit's dark mouth in a timber frame (variant 1 under a little lean-to roof), loose stones
    /// and a pair of rails running out of it.
    fileprivate static func mineEntrance(_ c: Canvas, variant v: Int) {
        let a = c.aspect, foot = c.foot
        let rock = v == 0 ? Tone(0.60, 0.54, 0.46) : Tone(0.56, 0.52, 0.48)
        let wood = Tone(0.52, 0.35, 0.21), dark = Tone(0.10, 0.07, 0.06)
        c.contactShadow(CGPoint(x: foot.x + 0.02, y: foot.y), width: a * 0.9, height: 0.2, alpha: 0.42)
        // The cut: a low dome of faceted rock.
        var rim: [CGPoint] = []
        let n = 10
        for k in 0...n {
            let t = CGFloat(k) / CGFloat(n)
            let x = foot.x - a * 0.42 + a * 0.84 * t
            rim.append(CGPoint(x: x, y: foot.y + (0.66 + c.f(-0.05, 0.03)) * pow(sin(.pi * t), 0.7)))
        }
        rim.append(CGPoint(x: foot.x + a * 0.42, y: foot.y - 0.04))
        rim.append(CGPoint(x: foot.x - a * 0.42, y: foot.y - 0.04))
        let face = polygon(rim)
        // The adit: an arch-topped mouth, its frame two posts and a lintel.
        let w: CGFloat = 0.36, h: CGFloat = 0.42, x0 = foot.x - w / 2
        let mouth = CGMutablePath()
        mouth.move(to: CGPoint(x: x0, y: foot.y - 0.02))
        mouth.addLine(to: CGPoint(x: x0, y: foot.y + h * 0.7))
        mouth.addQuadCurve(to: CGPoint(x: x0 + w, y: foot.y + h * 0.7), control: CGPoint(x: foot.x, y: foot.y + h * 1.15))
        mouth.addLine(to: CGPoint(x: x0 + w, y: foot.y - 0.02))
        mouth.closeSubpath()
        let postW: CGFloat = 0.065
        let left = CGPath(rect: CGRect(x: x0 - postW * 0.6, y: foot.y - 0.01, width: postW, height: h * 0.95), transform: nil)
        let right = CGPath(rect: CGRect(x: x0 + w - postW * 0.4, y: foot.y - 0.01, width: postW, height: h * 0.95), transform: nil)
        let lintel = CGPath(rect: CGRect(x: x0 - 0.09, y: foot.y + h * 0.88, width: w + 0.18, height: 0.075), transform: nil)
        var roof: CGPath?
        if v == 1 {
            roof = polygon([CGPoint(x: x0 - 0.14, y: foot.y + h * 0.95), CGPoint(x: x0 + w + 0.14, y: foot.y + h * 0.95),
                            CGPoint(x: x0 + w + 0.06, y: foot.y + h * 1.22), CGPoint(x: x0 - 0.06, y: foot.y + h * 1.22)])
        }
        c.fadeBase(foot.y - 0.06, foot.y + 0.02) {
            c.outline([face], width: 0.03, alpha: 0.45)
            c.fill(face, rock.shade(0.9))
            c.clip(face) {
                // Facets: lit planes on the west, the rest in cool shade, a few cracks.
                c.linear(face, [(rock.lit(0.9), 1), (rock, 1), (rock.shade(1.1), 1)],
                         from: CGPoint(x: foot.x - a * 0.4, y: foot.y + 0.7), to: CGPoint(x: foot.x + a * 0.35, y: foot.y))
                let cracks = Marks(2)
                for _ in 0..<5 {
                    let x = foot.x + c.f(-0.5, 0.5) * a * 0.75, y = foot.y + c.f(0.12, 0.5)
                    cracks.line(c.chance(0.5) ? 0 : 1, CGPoint(x: x, y: y), CGPoint(x: x + c.f(-0.08, 0.08), y: y - c.f(0.08, 0.16)))
                }
                cracks.stroke(c, [rock.shade(1.8), rock.lit(1.2)], alphas: [0.55, 0.4], width: 0.018)
                // A darker ring of disturbed earth round the mouth.
                c.radial(nil, at: CGPoint(x: foot.x, y: foot.y + h * 0.4), radius: 0.36, squash: 1.1,
                         [(Tone(0.30, 0.24, 0.20), 0.55), (Tone(0.30, 0.24, 0.20), 0)])
            }
            c.fill(mouth, dark)
            c.clip(mouth) {
                c.radial(nil, at: CGPoint(x: foot.x - 0.04, y: foot.y + 0.04), radius: 0.3, [(Tone(0.30, 0.20, 0.14), 0.6), (dark, 0)])
            }
            // Rails running out of the mouth.
            let rails = Marks(1)
            rails.line(0, CGPoint(x: foot.x - 0.07, y: foot.y + 0.1), CGPoint(x: foot.x - 0.16, y: foot.y - 0.05))
            rails.line(0, CGPoint(x: foot.x + 0.07, y: foot.y + 0.1), CGPoint(x: foot.x + 0.16, y: foot.y - 0.05))
            rails.stroke(c, [Tone(0.45, 0.43, 0.42)], alpha: 0.9, width: 0.02)
            c.outline([left, right, lintel] + (roof.map { [$0] } ?? []), width: 0.022, alpha: 0.7)
            for post in [left, right] {
                c.fill(post, wood)
                c.clip(post) { c.sweep([(wood.lit(1.2), 1), (wood.shade(1.1), 1)], from: CGPoint(x: x0 - 0.05, y: 0), to: CGPoint(x: x0 + w + 0.05, y: 0)) }
            }
            c.fill(lintel, wood.lit(0.6))
            c.fill(CGPath(rect: CGRect(x: x0 - 0.09, y: foot.y + h * 0.88, width: w + 0.18, height: 0.022), transform: nil), wood.shade(1.2), 0.8)
            if let roof {
                let thatch = Tone(0.62, 0.50, 0.32)
                c.fill(roof, thatch)
                c.clip(roof) { c.sweep([(thatch.lit(1.1), 1), (thatch.shade(1.0), 1)], from: CGPoint(x: x0, y: foot.y + h * 1.2), to: CGPoint(x: x0 + w, y: foot.y + h)) }
            }
            // Loose stones by the mouth.
            let stones = Marks(2)
            for _ in 0..<7 {
                let side: CGFloat = c.chance(0.5) ? -1 : 1
                stones.dab(c.chance(0.6) ? 0 : 1, CGPoint(x: foot.x + side * c.f(0.24, 0.5), y: foot.y + c.f(0.0, 0.07)), c.f(0.025, 0.045), c.f(0.018, 0.03))
            }
            stones.fill(c, [rock.lit(0.8), rock.shade(1.3)])
        }
    }

    /// A heap of a mine's spoil: a low, lumpy mound of grey-brown rubble lit from the upper left,
    /// stones picked out on it and a few rolled off at its foot.
    fileprivate static func spoilHeap(_ c: Canvas, variant v: Int) {
        let a = c.aspect, foot = c.foot
        let earth = v == 0 ? Tone(0.55, 0.49, 0.42) : Tone(0.50, 0.47, 0.45)
        c.contactShadow(foot, width: a * 0.85, height: 0.18, alpha: 0.42)
        var pts: [CGPoint] = []
        let n = 9, half = a * 0.4, top = c.f(0.34, 0.42), lean = c.f(-0.1, 0.05)
        for k in 0...n {
            let t = CGFloat(k) / CGFloat(n)
            let u = min(1, max(0, t + lean * sin(CGFloat.pi * t)))
            let rise = pow(sin(CGFloat.pi * u), 0.75)
            pts.append(CGPoint(x: foot.x - half + 2 * half * t, y: foot.y + top * rise * (1 + c.f(-0.1, 0.1))))
        }
        pts.append(CGPoint(x: foot.x + half * 0.6, y: foot.y - 0.04))
        pts.append(CGPoint(x: foot.x - half * 0.6, y: foot.y - 0.04))
        let heap = smoothClosed(pts)
        let rolled = Marks(2)
        for k in 0..<4 {
            let side: CGFloat = k % 2 == 0 ? -1 : 1
            rolled.dab(k % 2, CGPoint(x: foot.x + side * half * c.f(0.85, 1.1), y: foot.y + c.f(-0.02, 0.03)), c.f(0.03, 0.05), c.f(0.022, 0.035))
        }
        c.fadeBase(foot.y - 0.06, foot.y + 0.02) {
            c.outline([heap], width: 0.03, alpha: 0.45)
            c.fill(heap, earth)
            c.clip(heap) {
                c.sweep([(earth.lit(0.9), 1), (earth, 1), (earth.shade(1.1), 1)],
                        from: CGPoint(x: foot.x - half * 0.7, y: foot.y + top), to: CGPoint(x: foot.x + half * 0.6, y: foot.y))
                let stones = Marks(3)
                for _ in 0..<18 {
                    let x = foot.x + c.f(-0.9, 0.9) * half, y = foot.y + c.f(0.0, top * 0.95)
                    stones.dab(Int(c.f(0, 2.99)), CGPoint(x: x, y: y), c.f(0.022, 0.045), c.f(0.016, 0.03))
                }
                stones.fill(c, [earth.lit(1.2), earth.shade(1.6), Tone(0.36, 0.30, 0.26)], alpha: 0.8)
            }
            rolled.fill(c, [earth.lit(0.8), earth.shade(1.2)])
        }
    }

    /// A grazing animal for a pasture, painted facing west or east (never mirrored, so the
    /// light stays on its upper left): a red-brown cow with cream patches, a cream woolly sheep
    /// with a dark face, or a grey-brown horned goat, head down to the grass.
    fileprivate static func animal(_ c: Canvas, kind: AnimalKind, east: Bool) {
        let foot = c.foot
        let d: CGFloat = east ? 1 : -1 // the head's side
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: foot.x + d * x, y: foot.y + y) }
        c.contactShadow(p(-0.02, 0), width: c.aspect * 0.78, height: 0.16, alpha: 0.45)
        let coat: Tone, legsTone: Tone, headTone: Tone
        let bodyR: (CGFloat, CGFloat), bodyY: CGFloat
        switch kind {
        case .cow:
            coat = Tone(0.62, 0.38, 0.22); legsTone = Tone(0.34, 0.22, 0.15); headTone = Tone(0.50, 0.30, 0.18)
            bodyR = (0.4, 0.2); bodyY = 0.46
        case .sheep:
            coat = Tone(0.94, 0.91, 0.82); legsTone = Tone(0.20, 0.17, 0.16); headTone = Tone(0.24, 0.20, 0.18)
            bodyR = (0.36, 0.22); bodyY = 0.44
        case .goat:
            coat = Tone(0.66, 0.56, 0.44); legsTone = Tone(0.34, 0.28, 0.22); headTone = Tone(0.56, 0.47, 0.37)
            bodyR = (0.34, 0.17); bodyY = 0.47
        }
        let body: CGPath = kind == .sheep ? c.blob(p(-0.02, bodyY), bodyR.0, bodyR.1, lobes: 11, wobble: 0.1)
            : CGPath(roundedRect: CGRect(x: foot.x - bodyR.0 - 0.02 * d, y: foot.y + bodyY - bodyR.1, width: 2 * bodyR.0, height: 2 * bodyR.1),
                     cornerWidth: bodyR.1 * 0.9, cornerHeight: bodyR.1 * 0.9, transform: nil)
        // Grazing: the neck reaches forward and down, the head near the grass.
        let neck = CGMutablePath()
        neck.move(to: p(bodyR.0 - 0.12, bodyY + bodyR.1 * 0.6))
        neck.addQuadCurve(to: p(bodyR.0 + 0.16, bodyY - 0.14), control: p(bodyR.0 + 0.1, bodyY + 0.08))
        neck.addLine(to: p(bodyR.0 + 0.06, bodyY - 0.2))
        neck.addQuadCurve(to: p(bodyR.0 - 0.1, bodyY - bodyR.1 * 0.5), control: p(bodyR.0, bodyY - 0.05))
        neck.closeSubpath()
        let head = c.blob(p(bodyR.0 + 0.16, bodyY - 0.24), kind == .cow ? 0.1 : 0.08, kind == .cow ? 0.08 : 0.07, lobes: 7, wobble: 0.06)
        let legs = Marks(1)
        for x in [-bodyR.0 * 0.7, -bodyR.0 * 0.45, bodyR.0 * 0.45, bodyR.0 * 0.7] {
            legs.line(0, p(x - 0.02, bodyY - bodyR.1 * 0.6), p(x - 0.02 + c.f(-0.015, 0.015), 0.02))
        }
        let tail = Marks(1)
        tail.curve(0, p(-bodyR.0 - 0.0, bodyY + bodyR.1 * 0.4), p(-bodyR.0 - 0.08, bodyY), p(-bodyR.0 - 0.05, bodyY - 0.18))
        let horns = Marks(1)
        if kind != .sheep {
            let base = p(bodyR.0 + 0.2, bodyY - 0.16)
            horns.curve(0, base, CGPoint(x: base.x - d * 0.1, y: base.y + 0.1), CGPoint(x: base.x - d * 0.16, y: base.y + 0.04))
        }
        c.fadeBase(foot.y - 0.04, foot.y + 0.04) {
            c.layer(alpha: 0.5) {
                legs.stroke(c, [.ink], width: 0.085)
                tail.stroke(c, [.ink], width: 0.055)
                let parts: [CGPath] = [body, neck, head]
                for path in parts { c.ctx.addPath(path) }
                c.ctx.setStrokeColor(Tone.ink.cg())
                c.ctx.setLineWidth(0.05)
                c.ctx.strokePath()
            }
            legs.stroke(c, [legsTone], width: 0.05)
            tail.stroke(c, [coat.shade(0.8)], width: 0.03)
            c.fill(neck, coat.shade(0.25))
            c.fill(body, coat)
            c.clip(body) {
                c.sweep([(coat.lit(0.7), 1), (coat, 1), (coat.shade(1.0), 1)], from: p(-0.1, bodyY + bodyR.1), to: p(0.05, bodyY - bodyR.1))
                if kind == .cow {
                    // Brown patches.
                    let patches = Marks(1)
                    for _ in 0..<3 {
                        patches.dab(0, p(c.f(-0.3, 0.25), bodyY + c.f(-0.1, 0.12)), c.f(0.08, 0.13), c.f(0.06, 0.1))
                    }
                    patches.fill(c, [Tone(0.94, 0.90, 0.82)], alpha: 0.95)
                }
                if kind == .sheep {
                    let curls = Marks(1)
                    for _ in 0..<10 { curls.dab(0, p(c.f(-0.32, 0.3), bodyY + c.f(-0.15, 0.17)), 0.035, 0.03) }
                    curls.fill(c, [coat.lit(1.0)], alpha: 0.6)
                }
            }
            c.fill(head, headTone)
            c.clip(head) { c.sweep([(headTone.lit(0.8), 1), (headTone.shade(0.8), 1)], from: p(bodyR.0 + 0.08, bodyY - 0.16), to: p(bodyR.0 + 0.24, bodyY - 0.32)) }
            horns.stroke(c, [Tone(0.88, 0.84, 0.74)], width: 0.03)
        }
    }
}
