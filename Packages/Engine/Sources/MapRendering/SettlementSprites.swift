import CoreGraphics
import Foundation
import GameCore
import Synchronization

// The shared painting toolkit (`FigurePaint.swift`).
private typealias Tone = FigurePaint.Tone
private typealias Material = FigurePaint.Material
private typealias Step = FigurePaint.Step
private typealias Figure = FigurePaint.Figure
private typealias Canvas = FigurePaint.Canvas

/// One piece of the settlement kit (ART.md §11): buildings, the four quarters of a town wall,
/// a breach, and props. Cities are put together from these per tier and seed
/// (`MapRenderer+Cities.swift`).
enum SettlementPiece: Int, CaseIterable, Sendable {
    /// The capital's stone keep, flying the owner's banner.
    case keep
    /// A town's timber hall, the owner's banners at its door.
    case hall
    case house0, house1, house2, house3, house4, house5
    case granary, library, market, tower, gatehouse, well, hay
    /// The quarters of the wall ring (back quarters show their inner face, front ones their
    /// outer face), and the front left quarter with a breach.
    case wallBackLeft, wallBackRight, wallFrontLeft, wallFrontRight, wallBreach

    static let houses: [SettlementPiece] = [.house0, .house1, .house2, .house3, .house4, .house5]

    var cellSize: Int {
        switch self {
        case .keep, .hall, .wallBackLeft, .wallBackRight, .wallFrontLeft, .wallFrontRight, .wallBreach: 256
        default: 128
        }
    }

    /// The cell's edge in tile sizes: one texel density for the whole kit (about 233 texels per
    /// tile size), so pieces of either cell size match.
    var edge: Float { cellSize == 256 ? 1.1 : 0.55 }

    /// Whether some of it is team paint (banners, pennants, awnings), with a team cell.
    var hasTeam: Bool {
        switch self {
        case .keep, .hall, .market, .tower, .gatehouse: true
        default: false
        }
    }

    /// Where the piece stands, in cell fractions (y up): a building's front foot, the middle of
    /// a tower's or the well's base, and for wall quarters the middle of the ring.
    var foot: SIMD2<Float> {
        switch self {
        case .keep: [0.4, 0.07]
        case .hall: [0.4, 0.09]
        case .wallBackLeft: [0.82, 0.07]
        case .wallBackRight: [0.18, 0.07]
        case .wallFrontLeft, .wallBreach: [0.82, 0.66]
        case .wallFrontRight: [0.18, 0.66]
        case .tower, .well, .granary: [0.5, 0.08]
        case .gatehouse, .hay: [0.5, 0.09]
        default: [0.42, 0.09]
        }
    }

    /// Wall ring geometry (tile sizes): the radius of its middle, thickness, height and the
    /// height of its merlons. The plaza inside stays clear for the units' base.
    static let wallRadius: CGFloat = 0.74
    static let wallThickness: CGFloat = 0.06
    static let wallHeight: CGFloat = 0.17
    static let merlonHeight: CGFloat = 0.034
}

/// City art, drawn procedurally with Core Graphics into the 2048x512 settlement atlas at startup
/// (ART.md §11).
///
/// - `piece`: a building, wall quarter or prop of the kit in the units' painted style (west-lit
///   volume, soft outline, brushwork), shared by every player: team parts (banners, pennants,
///   awnings) are painted in the neutral grey the unit shader tints.
/// - `team`: how much of each pixel of a piece is team paint, as alpha (the unit shader
///   multiplies the owner's color in there, `cityPiece`).
/// - `ground`: the trodden earth an open village or town stands on, laid flat on its tile;
///   `pavedGround`: a walled town's, its square and main lane paved.
///
/// Pieces stand as billboards on their `foot`; a ground point `d` tile sizes behind the foot
/// is painted `depth` x d above it, as the tilted camera shows it.
enum SettlementSprite: SpriteSet {
    case piece(SettlementPiece)
    case team(SettlementPiece)
    case ground
    case pavedGround

    static var all: [SettlementSprite] {
        var keys: [SettlementSprite] = SettlementPiece.allCases.map { .piece($0) }
        keys += SettlementPiece.allCases.filter(\.hasTeam).map { .team($0) }
        keys += [.ground, .pavedGround]
        return keys
    }

    var cellSize: Int {
        switch self {
        case let .piece(p), let .team(p): p.cellSize
        case .ground, .pavedGround: 256
        }
    }

    /// How ground depth shows on a billboard: the tilt's cosine (`MapRenderer.tiltPitch`).
    static let depth: CGFloat = cos(0.6)

    func draw(in r: CGRect, ctx: CGContext) {
        // Art is laid out in fractions of the whole cell and kept inside the 1/20 margin.
        let cell = r.insetBy(dx: -r.width / 18, dy: -r.height / 18)
        let canvas = Canvas(ctx: ctx, origin: cell.origin, size: cell.width)
        switch self {
        case let .piece(p): canvas.paint(Self.recorded(p), pass: .body)
        case let .team(p): canvas.paint(Self.recorded(p), pass: .teamMask)
        case .ground: Self.paintGround(cell: cell, ctx: ctx, paved: false)
        case .pavedGround: Self.paintGround(cell: cell, ctx: ctx, paved: true)
        }
    }

    // MARK: Recording

    /// A piece's paint steps (immutable once recorded, so shared across threads).
    private struct RecordedPiece: @unchecked Sendable {
        let steps: [Step]
    }

    /// Every piece recorded once, shared by the atlas build and the bounds.
    private static let recordings: [SettlementPiece: RecordedPiece] = {
        let pieces = SettlementPiece.allCases
        let done = Mutex<[SettlementPiece: RecordedPiece]>([:])
        DispatchQueue.concurrentPerform(iterations: pieces.count) { i in
            let piece = pieces[i]
            var d = Draft(piece)
            switch piece {
            case .keep: keep(&d)
            case .hall: hall(&d)
            case .house0: house(&d, style: .thatch)
            case .house1: house(&d, style: .tiles)
            case .house2: house(&d, style: .timber)
            case .house3: house(&d, style: .stone)
            case .house4: house(&d, style: .longhouse)
            case .house5: house(&d, style: .hut)
            case .granary: granary(&d)
            case .library: library(&d)
            case .market: market(&d)
            case .tower: tower(&d)
            case .gatehouse: gatehouse(&d)
            case .well: well(&d)
            case .hay: hay(&d)
            case .wallBackLeft: wall(&d, from: .pi, to: .pi / 2, back: true)
            case .wallBackRight: wall(&d, from: .pi / 2, to: 0, back: true)
            case .wallFrontLeft: wall(&d, from: .pi, to: 1.5 * .pi, back: false)
            case .wallFrontRight: wall(&d, from: 1.5 * .pi, to: 2 * .pi, back: false)
            case .wallBreach: wall(&d, from: .pi, to: 1.5 * .pi, back: false, breach: 1.25 * .pi)
            }
            let recorded = RecordedPiece(steps: d.f.steps)
            done.withLock { $0[piece] = recorded }
        }
        return done.withLock { $0 }
    }()

    private static func recorded(_ piece: SettlementPiece) -> [Step] { recordings[piece]?.steps ?? [] }

    /// The painted extent of each piece (lo x, lo y, hi x, hi y, cell fractions, y up).
    static let bounds: [SettlementPiece: SIMD4<Float>] = {
        var out: [SettlementPiece: SIMD4<Float>] = [:]
        for piece in SettlementPiece.allCases { out[piece] = recorded(piece).bounds(size: CGFloat(piece.cellSize)) }
        return out
    }()

    /// A figure in tile sizes: x right and y up from the piece's foot, converted to its cell.
    private struct Draft {
        typealias P = (CGFloat, CGFloat)
        var f: Figure
        let foot: P
        let edge: CGFloat

        init(_ piece: SettlementPiece) {
            f = Figure(size: CGFloat(piece.cellSize))
            foot = (CGFloat(piece.foot.x), CGFloat(piece.foot.y))
            edge = CGFloat(piece.edge)
        }

        func p(_ q: P) -> P { (foot.0 + q.0 / edge, foot.1 + q.1 / edge) }
        func w(_ v: CGFloat) -> CGFloat { v / edge }

        func poly(_ pts: [P]) -> CGPath { f.poly(pts.map(p)) }
        func blob(_ pts: [P]) -> CGPath { f.blob(pts.map(p)) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ wd: CGFloat, _ h: CGFloat) -> CGPath { f.rectPath(p((x, y)).0, p((x, y)).1, w(wd), w(h)) }
        func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
            let c = p((x, y))
            return f.ellipse(c.0, c.1, w(rx), w(ry))
        }
        func line(_ pts: [P], _ w0: CGFloat, _ w1: CGFloat? = nil) -> CGPath { f.limb(pts.map(p), w(w0), w(w1 ?? w0)) }

        /// Outline widths in tile sizes.
        mutating func add(_ path: CGPath, _ m: Material, outline: CGFloat = 0.009) { f.add(path, m, outline: w(outline)) }
        mutating func decal(_ path: CGPath, _ tone: Tone, alpha: CGFloat, clip: CGPath? = nil) { f.decal(path, tone, alpha: alpha, clip: clip) }
        mutating func stroke(_ pts: [P], _ tone: Tone, width: CGFloat, alpha: CGFloat = 1, clip: CGPath? = nil) {
            f.decal(line(pts, width), tone, alpha: alpha, clip: clip)
        }
        mutating func teamDecal(_ path: CGPath, shade: CGFloat, alpha: CGFloat, clip: CGPath? = nil) {
            f.decal(path, teamShade: shade, alpha: alpha, clip: clip)
        }
    }

    // MARK: Palette

    private static let plaster = Tone(0.9, 0.84, 0.72)
    private static let timber = Tone(0.38, 0.26, 0.17)
    private static let stone = Tone(0.7, 0.67, 0.61)
    private static let stoneWarm = Tone(0.74, 0.67, 0.55)
    private static let thatch = Tone(0.8, 0.65, 0.38)
    private static let tiles = Tone(0.74, 0.38, 0.25)
    private static let slate = Tone(0.42, 0.45, 0.52)
    private static let shingle = Tone(0.53, 0.38, 0.25)
    private static let wood = Tone(0.56, 0.39, 0.24)
    private static let dark = Tone(0.16, 0.12, 0.1)
    private static let marble = Tone(0.9, 0.87, 0.8)
    private static let iron = Tone(0.36, 0.37, 0.4)
    /// East faces are in shade (the sun is at the upper left).
    private static let shaded: CGFloat = 0.7
    /// How a building's depth runs on its sprite: back and a little to the right, so its east
    /// side shows in shade.
    private static let oblique: (CGFloat, CGFloat) = (0.42, 0.5)

    // MARK: Houses

    private enum HouseStyle { case thatch, tiles, timber, stone, longhouse, hut }

    /// A house: walls, a door, windows and its roof, seen a little from the east. The foot is
    /// the middle of its front wall.
    private static func house(_ d: inout Draft, style: HouseStyle) {
        switch style {
        case .thatch:
            box(&d, width: 0.27, depth: 0.2, height: 0.12, roof: 0.12, wall: plaster, roofTone: thatch, ridgeAlong: false, thatched: true)
            door(&d, x: -0.05, width: 0.05, height: 0.08)
            window(&d, x: 0.06, y: 0.055)
        case .tiles:
            box(&d, width: 0.24, depth: 0.22, height: 0.14, roof: 0.11, wall: stoneWarm.scaled(1.08), roofTone: tiles, ridgeAlong: true)
            door(&d, x: 0.03, width: 0.05, height: 0.085)
            window(&d, x: -0.06, y: 0.065)
            chimney(&d, at: (0.05, 0.27))
        case .timber:
            // Two storeys, half-timbered, its upper floor jutting out a little.
            box(&d, width: 0.24, depth: 0.2, height: 0.24, roof: 0.13, wall: plaster, roofTone: shingle, ridgeAlong: false, beams: true)
            door(&d, x: -0.06, width: 0.05, height: 0.085)
            window(&d, x: 0.05, y: 0.055)
            window(&d, x: -0.05, y: 0.165)
            window(&d, x: 0.06, y: 0.165)
        case .stone:
            box(&d, width: 0.25, depth: 0.2, height: 0.13, roof: 0.1, wall: stone, roofTone: slate, ridgeAlong: false, coursed: true)
            door(&d, x: 0.0, width: 0.055, height: 0.085)
            window(&d, x: -0.075, y: 0.06)
            window(&d, x: 0.075, y: 0.06)
            chimney(&d, at: (-0.08, 0.27))
        case .longhouse:
            box(&d, width: 0.33, depth: 0.18, height: 0.1, roof: 0.12, wall: wood.scaled(1.05), roofTone: thatch.scaled(0.92), ridgeAlong: false,
                thatched: true, planked: true)
            door(&d, x: 0.08, width: 0.05, height: 0.075)
            window(&d, x: -0.08, y: 0.045)
        case .hut:
            // A round hut of wattle and daub under a conical thatch.
            let r: CGFloat = 0.1, h: CGFloat = 0.1
            let body = d.blob([(-r, 0.01), (-r * 0.98, h), (0, h + 0.01), (r * 0.98, h), (r, 0.01), (0, -0.025)])
            d.add(body, Material(plaster.scaled(0.95), grain: .cloth))
            d.decal(d.rect(r * 0.3, -0.03, r * 0.8, h + 0.05), dark, alpha: 0.22, clip: body)
            door(&d, x: -0.025, width: 0.045, height: 0.07)
            let cone = d.blob([(-r - 0.035, h - 0.012), (-r * 0.4, h + 0.09), (0, h + 0.15), (r * 0.4, h + 0.09), (r + 0.035, h - 0.012),
                               (0, h - 0.03)])
            d.add(cone, Material(thatch, grain: .hide))
            for t in [-0.6, -0.2, 0.2, 0.6] as [CGFloat] {
                d.stroke([(t * (r + 0.03), h - 0.012), (t * 0.12, h + 0.13)], thatch.shadow, width: 0.006, alpha: 0.45, clip: cone)
            }
            d.stroke([(-r - 0.03, h - 0.006), (r + 0.03, h - 0.006)], thatch.shadow, width: 0.012, alpha: 0.5, clip: cone)
        }
    }

    /// A rectangular building `width` wide and `depth` deep (tile sizes) with walls `height`
    /// high, seen from the front and a little from the east, under a gable roof `roof` high
    /// whose ridge runs across the front (`ridgeAlong` false) or back from it.
    private static func box(_ d: inout Draft, width w: CGFloat, depth dp: CGFloat, height h: CGFloat, roof rh: CGFloat, wall: Tone,
                            roofTone: Tone, ridgeAlong: Bool, thatched: Bool = false, beams: Bool = false, coursed: Bool = false,
                            planked: Bool = false) {
        let x0 = -w / 2, x1 = w / 2
        let b = (oblique.0 * dp, oblique.1 * dp)
        let eave: CGFloat = thatched ? 0.03 : 0.02, drop: CGFloat = thatched ? 0.02 : 0.012
        let wallGrain: FigurePaint.Grain = planked ? .planks : .cloth
        // East wall, in shade.
        let side = d.poly([(x1, 0), (x1 + b.0, b.1), (x1 + b.0, h + b.1), (x1, h)])
        d.add(side, Material(wall.scaled(shaded), shade: 0.6, light: 0.3, grain: wallGrain))
        let front = d.rect(x0, 0, w, h)
        if ridgeAlong {
            // The gable faces the front: the west slope rises behind it, the east slope over
            // the east wall.
            let apex = (CGFloat(0), h + rh)
            d.add(d.poly([(x0 - eave, h - drop), apex, (apex.0 + b.0, apex.1 + b.1), (x0 - eave + b.0, h - drop + b.1)]),
                  Material(roofTone.scaled(1.05), grain: thatched ? .hide : .planks))
            let east = d.poly([apex, (x1 + eave, h - drop), (x1 + eave + b.0, h - drop + b.1), (apex.0 + b.0, apex.1 + b.1)])
            d.add(east, Material(roofTone.scaled(0.78), shade: 0.7, grain: thatched ? .hide : .planks))
            if !thatched { courses(&d, roof: east, from: (x1 + eave, h - drop), to: apex, depth: b, tone: roofTone) }
            let gable = d.poly([(x0, 0), (x1, 0), (x1, h), apex, (x0, h)])
            d.add(gable, Material(wall, grain: wallGrain))
            d.add(d.line([(x0 - eave, h - drop), apex, (x1 + eave, h - drop)], 0.016), Material(roofTone.scaled(0.86)), outline: 0.006)
            dress(&d, front: gable, x0: x0, x1: x1, h: h + rh * 0.4, beams: beams, coursed: coursed, wall: wall)
        } else {
            // The ridge runs across the front: the front slope faces the viewer, the east
            // gable shows on the side.
            let ridge = h + rh + b.1 / 2
            let gable = d.poly([(x1, h), (x1 + b.0, h + b.1), (x1 + b.0 / 2, ridge)])
            d.add(gable, Material(wall.scaled(shaded * 1.05), shade: 0.6, light: 0.3, grain: wallGrain))
            d.add(d.line([(x1 + b.0 / 2 + eave * 0.6, ridge), (x1 + b.0 + eave, h + b.1 - drop)], 0.016),
                  Material(roofTone.scaled(0.7)), outline: 0.006)
            d.add(front, Material(wall, grain: wallGrain))
            dress(&d, front: front, x0: x0, x1: x1, h: h, beams: beams, coursed: coursed, wall: wall)
            let slope = d.poly([(x0 - eave, h - drop), (x1 + eave, h - drop), (x1 + eave + b.0 / 2, ridge), (x0 - eave + b.0 / 2, ridge)])
            d.add(slope, Material(roofTone, grain: thatched ? .hide : .planks))
            if thatched {
                // Thick thatch: a darker drip edge and combed straw.
                d.stroke([(x0 - eave, h - drop + 0.006), (x1 + eave, h - drop + 0.006)], roofTone.shadow, width: 0.014, alpha: 0.55, clip: slope)
                var x = x0
                while x < x1 + eave {
                    d.stroke([(x, h - drop), (x + b.0 / 2 + 0.01, ridge)], roofTone.shadow, width: 0.005, alpha: 0.3, clip: slope)
                    x += 0.035
                }
            } else {
                courses(&d, roof: slope, from: (x0 - eave, h - drop), to: (x0 - eave + b.0 / 2, ridge), depth: (w + 2 * eave, 0), tone: roofTone)
            }
            d.stroke([(x0 - eave + b.0 / 2, ridge), (x1 + eave + b.0 / 2, ridge)], roofTone.scaled(0.6), width: 0.012, alpha: 0.8)
        }
    }

    /// Courses of tiles or shingles across a roof slope, from its eave line up to its ridge:
    /// lines parallel to `depth` starting along the eave-to-ridge edge.
    private static func courses(_ d: inout Draft, roof: CGPath, from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat),
                                depth: (CGFloat, CGFloat), tone: Tone) {
        for t in stride(from: CGFloat(0.22), to: 1, by: 0.26) {
            let s = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
            d.stroke([s, (s.0 + depth.0, s.1 + depth.1)], tone.shadow, width: 0.006, alpha: 0.5, clip: roof)
        }
    }

    /// Timber framing or stone courses on a front wall, and the shadow under the eaves.
    private static func dress(_ d: inout Draft, front: CGPath, x0: CGFloat, x1: CGFloat, h: CGFloat, beams: Bool, coursed: Bool, wall: Tone) {
        if beams {
            for x in [x0 + 0.012, (x0 + x1) / 2, x1 - 0.012] {
                d.stroke([(x, 0), (x, h)], timber, width: 0.014, alpha: 0.9, clip: front)
            }
            d.stroke([(x0, h * 0.48), (x1, h * 0.48)], timber, width: 0.016, alpha: 0.9, clip: front)
            d.stroke([(x0, h - 0.008), (x1, h - 0.008)], timber, width: 0.014, alpha: 0.9, clip: front)
            d.stroke([(x0 + 0.012, h * 0.48), ((x0 + x1) / 2, h - 0.01)], timber, width: 0.01, alpha: 0.8, clip: front)
        }
        if coursed {
            var y: CGFloat = 0.03
            var row = 0
            while y < h {
                d.stroke([(x0, y), (x1, y)], wall.shadow, width: 0.005, alpha: 0.4, clip: front)
                var x = x0 + (row % 2 == 0 ? 0.03 : 0.055)
                while x < x1 {
                    d.stroke([(x, y), (x, y + 0.03)], wall.shadow, width: 0.004, alpha: 0.35, clip: front)
                    x += 0.05
                }
                y += 0.03
                row += 1
            }
        }
        // Shade under the eaves.
        d.decal(d.rect(x0, h - 0.03, x1 - x0, 0.03), dark, alpha: 0.18, clip: front)
    }

    private static func door(_ d: inout Draft, x: CGFloat, width: CGFloat, height: CGFloat) {
        let path = d.poly([(x - width / 2, 0), (x + width / 2, 0), (x + width / 2, height - width * 0.3), (x, height),
                           (x - width / 2, height - width * 0.3)])
        d.add(path, Material(wood.scaled(0.62), grain: .planks), outline: 0.005)
        d.stroke([(x - width / 2 - 0.004, 0.002), (x + width / 2 + 0.004, 0.002)], stone.scaled(0.8), width: 0.008, alpha: 0.9)
    }

    private static func window(_ d: inout Draft, x: CGFloat, y: CGFloat) {
        d.add(d.rect(x - 0.019, y - 0.018, 0.038, 0.036), Material(dark, shade: 0, light: 0), outline: 0.004)
        d.stroke([(x - 0.022, y - 0.02), (x + 0.022, y - 0.02)], plaster.scaled(1.05), width: 0.007, alpha: 0.95)
        d.stroke([(x, y - 0.018), (x, y + 0.018)], wood, width: 0.005, alpha: 0.8)
    }

    private static func chimney(_ d: inout Draft, at c: (CGFloat, CGFloat)) {
        d.add(d.rect(c.0 - 0.018, c.1 - 0.05, 0.036, 0.075), Material(stone.scaled(0.9), grain: .hide), outline: 0.006)
        d.add(d.rect(c.0 - 0.023, c.1 + 0.02, 0.046, 0.014), Material(stone.scaled(0.75)), outline: 0.005)
    }

    // MARK: Great buildings

    /// The capital's keep: a tall square tower of dressed stone with a crenellated top and a
    /// corner turret, a lower hall at its back, and the owner's banner over it.
    private static func keep(_ d: inout Draft) {
        // The hall behind, to the west.
        box(&d, width: 0.3, depth: 0.2, height: 0.16, roof: 0.13, wall: stoneWarm, roofTone: slate, ridgeAlong: false, coursed: true)
        let w: CGFloat = 0.34, dp: CGFloat = 0.28, h: CGFloat = 0.44
        let ox: CGFloat = 0.13, oy: CGFloat = -0.02
        let x0 = ox - w / 2, x1 = ox + w / 2
        let b = (oblique.0 * dp, oblique.1 * dp)
        let side = d.poly([(x1, oy), (x1 + b.0, oy + b.1), (x1 + b.0, oy + h + b.1), (x1, oy + h)])
        d.add(side, Material(stone.scaled(shaded), shade: 0.6, light: 0.3, grain: .hide))
        let top = d.poly([(x0, oy + h), (x1, oy + h), (x1 + b.0, oy + h + b.1), (x0 + b.0, oy + h + b.1)])
        d.add(top, Material(stone.scaled(0.62), shade: 0.3, grain: .planks), outline: 0.006)
        let front = d.rect(x0, oy, w, h)
        d.add(front, Material(stone, grain: .hide))
        dress(&d, front: front, x0: x0, x1: x1, h: h, beams: false, coursed: true, wall: stone)
        // Arched door, arrow slits, a string course.
        door(&d, x: ox, width: 0.075, height: 0.12)
        for (x, y) in [(ox - 0.08, 0.2), (ox + 0.08, 0.2), (ox, 0.3), (ox - 0.08, 0.34), (ox + 0.08, 0.34)] as [(CGFloat, CGFloat)] {
            d.add(d.rect(x - 0.008, oy + y - 0.03, 0.016, 0.05), Material(dark, shade: 0, light: 0), outline: 0.003)
        }
        d.stroke([(x0, oy + h - 0.06), (x1, oy + h - 0.06)], stone.lit, width: 0.01, alpha: 0.5, clip: front)
        // Battlements along the front and the east side.
        merlons(&d, from: (x0, oy + h), to: (x1, oy + h), size: 0.034, tone: stone)
        merlons(&d, from: (x1, oy + h), to: (x1 + b.0, oy + h + b.1), size: 0.034, tone: stone.scaled(shaded))
        // A round turret on the front west corner, with a pointed slate cap.
        let tx = x0 + 0.005, ty = oy + h * 0.55
        let turret = d.blob([(tx - 0.05, ty), (tx - 0.05, oy + h + 0.06), (tx, oy + h + 0.075), (tx + 0.05, oy + h + 0.06), (tx + 0.05, ty),
                             (tx, ty - 0.035)])
        d.add(turret, Material(stone.scaled(1.04), grain: .hide))
        d.decal(d.rect(tx + 0.015, ty - 0.05, 0.04, h), dark, alpha: 0.25, clip: turret)
        let cap = d.poly([(tx - 0.066, oy + h + 0.05), (tx, oy + h + 0.2), (tx + 0.066, oy + h + 0.05)])
        d.add(cap, Material(slate, grain: .planks))
        d.decal(d.poly([(tx, oy + h + 0.2), (tx + 0.066, oy + h + 0.05), (tx + 0.02, oy + h + 0.05)]), dark, alpha: 0.3, clip: cap)
        // The banner on a pole from the middle of the roof.
        let pole = (ox + b.0 / 2 + 0.02, oy + h + b.1 / 2)
        banner(&d, pole: pole, height: 0.3, width: 0.17, drop: 0.1)
    }

    /// A town's timber hall: a long, steep-roofed hall with its gable to the front, carved
    /// crossed boards at the peak, and the owner's banners hanging beside the door.
    private static func hall(_ d: inout Draft) {
        let w: CGFloat = 0.36, h: CGFloat = 0.16
        box(&d, width: w, depth: 0.4, height: h, roof: 0.22, wall: wood, roofTone: shingle, ridgeAlong: true, planked: true)
        // Crossed gable boards.
        d.add(d.line([(-0.07, h + 0.16), (0.045, h + 0.29)], 0.016), Material(timber), outline: 0.005)
        d.add(d.line([(0.07, h + 0.16), (-0.045, h + 0.29)], 0.016), Material(timber), outline: 0.005)
        door(&d, x: 0, width: 0.08, height: 0.12)
        // Banners on the posts either side of the door.
        for x in [-0.1, 0.1] as [CGFloat] {
            d.add(d.rect(x - 0.008, 0, 0.016, h + 0.03), Material(timber, grain: .wood), outline: 0.005)
            let cloth = d.poly([(x - 0.032, h + 0.01), (x + 0.032, h + 0.01), (x + 0.032, h - 0.09), (x, h - 0.11), (x - 0.032, h - 0.09)])
            d.add(cloth, Material(team: 1, grain: .cloth), outline: 0.006)
            d.teamDecal(d.rect(x - 0.032, h - 0.005, 0.064, 0.012), shade: 0.55, alpha: 0.8, clip: cloth)
        }
        window(&d, x: -0.13, y: 0.07)
        window(&d, x: 0.13, y: 0.07)
    }

    /// A banner flying from a pole standing at `pole` (tile sizes): the pole, a gilt finial and
    /// a swallow-tailed flag in team paint.
    private static func banner(_ d: inout Draft, pole: (CGFloat, CGFloat), height: CGFloat, width: CGFloat, drop: CGFloat) {
        let top = (pole.0, pole.1 + height)
        d.add(d.line([pole, top], 0.014, 0.011), Material(timber, grain: .wood), outline: 0.005)
        let y0 = top.1 - 0.012
        let flag = d.blob([(top.0 + 0.004, y0), (top.0 + width * 0.35, y0 + 0.012), (top.0 + width * 0.7, y0 - 0.006), (top.0 + width, y0 + 0.004),
                           (top.0 + width * 0.8, y0 - drop * 0.5), (top.0 + width, y0 - drop), (top.0 + width * 0.62, y0 - drop - 0.004),
                           (top.0 + width * 0.3, y0 - drop + 0.012), (top.0 + 0.004, y0 - drop)])
        d.add(flag, Material(team: 1, grain: .cloth), outline: 0.007)
        d.teamDecal(d.line([(top.0 + width * 0.1, y0 - drop * 0.3), (top.0 + width * 0.5, y0 - drop * 0.25), (top.0 + width * 0.85, y0 - drop * 0.35)],
                           0.012), shade: 0.6, alpha: 0.6, clip: flag)
        d.add(d.ellipse(top.0, top.1 + 0.006, 0.012, 0.012), Material(Tone(0.86, 0.68, 0.3), gloss: 0.8), outline: 0.004)
    }

    /// A row of merlons standing on the line from `a` to `b` (tile sizes).
    private static func merlons(_ d: inout Draft, from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat), size: CGFloat, tone: Tone) {
        let length = hypot(b.0 - a.0, b.1 - a.1)
        let count = max(Int((length / (size * 1.8)).rounded()), 2)
        for i in 0..<count {
            let t = (CGFloat(i) + 0.5) / CGFloat(count)
            let c = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
            d.add(d.rect(c.0 - size * 0.45, c.1 - 0.004, size * 0.9, size), Material(tone, grain: .hide), outline: 0.005)
        }
    }

    // MARK: Props

    /// A round thatched granary raised on staddle stones, a ladder at its door.
    private static func granary(_ d: inout Draft) {
        let r: CGFloat = 0.1, lift: CGFloat = 0.045, h: CGFloat = 0.11
        for x in [-0.07, 0.0, 0.07] as [CGFloat] {
            d.add(d.rect(x - 0.012, 0, 0.024, lift), Material(stone, grain: .hide), outline: 0.005)
            d.add(d.ellipse(x, lift, 0.026, 0.01), Material(stone.scaled(1.05)), outline: 0.004)
        }
        let body = d.blob([(-r, lift + 0.005), (-r, lift + h), (0, lift + h + 0.012), (r, lift + h), (r, lift + 0.005), (0, lift - 0.012)])
        d.add(body, Material(wood, grain: .planks))
        d.decal(d.rect(r * 0.35, lift - 0.02, r, h + 0.04), dark, alpha: 0.25, clip: body)
        for y in [0.03, 0.065, 0.1] as [CGFloat] {
            d.stroke([(-r, lift + y), (0, lift + y - 0.01), (r, lift + y)], timber, width: 0.006, alpha: 0.5, clip: body)
        }
        let roof = d.blob([(-r - 0.04, lift + h - 0.01), (-r * 0.45, lift + h + 0.1), (0, lift + h + 0.17), (r * 0.45, lift + h + 0.1),
                           (r + 0.04, lift + h - 0.01), (0, lift + h - 0.035)])
        d.add(roof, Material(thatch, grain: .hide))
        for t in [-0.6, -0.2, 0.2, 0.6] as [CGFloat] {
            d.stroke([(t * (r + 0.035), lift + h - 0.01), (t * 0.12, lift + h + 0.15)], thatch.shadow, width: 0.006, alpha: 0.45, clip: roof)
        }
        d.add(d.ellipse(0, lift + h + 0.172, 0.012, 0.012), Material(timber), outline: 0.004)
        // Ladder.
        d.add(d.line([(-0.03, 0), (-0.045, lift + 0.06)], 0.007), Material(timber), outline: 0.003)
        d.add(d.line([(0.0, 0), (-0.015, lift + 0.06)], 0.007), Material(timber), outline: 0.003)
        for y in [0.02, 0.045, 0.07] as [CGFloat] {
            d.stroke([(-0.032 - y * 0.15, y), (-0.002 - y * 0.15, y)], timber, width: 0.005)
        }
    }

    /// A small library in the classical style: steps, four columns, a pediment and a tiled roof.
    private static func library(_ d: inout Draft) {
        let w: CGFloat = 0.3, dp: CGFloat = 0.24, col: CGFloat = 0.13
        let x0 = -w / 2, x1 = w / 2
        let b = (oblique.0 * dp, oblique.1 * dp)
        let base: CGFloat = 0.04, top = base + col + 0.03
        // Cella walls behind the columns, east side in shade.
        d.add(d.poly([(x1, base), (x1 + b.0, base + b.1), (x1 + b.0, top + b.1), (x1, top)]),
              Material(marble.scaled(shaded), shade: 0.6, light: 0.3))
        let roofEast = d.poly([(x1 + 0.015, top), (x1 + 0.015 + b.0, top + b.1), (b.0, top + 0.08 + b.1), (0, top + 0.08)])
        d.add(roofEast, Material(tiles.scaled(0.8), shade: 0.7, grain: .planks))
        d.add(d.rect(x0 + 0.02, base, w - 0.04, col), Material(dark.scaled(1.8), shade: 0, light: 0), outline: 0.004)
        // Steps.
        for (i, y) in [0.0, 0.014, 0.028].enumerated() {
            let inset = CGFloat(i) * 0.012
            d.add(d.poly([(x0 - 0.03 + inset, y), (x1 + 0.03 - inset, y), (x1 + 0.03 - inset + b.0 * 0.15, y + 0.014), (x0 - 0.03 + inset, y + 0.014)]),
                  Material(marble.scaled(0.95 - CGFloat(i) * 0.03)), outline: 0.004)
        }
        // Columns with capitals.
        for i in 0..<4 {
            let x = x0 + 0.03 + CGFloat(i) * (w - 0.06) / 3
            d.add(d.rect(x - 0.015, base, 0.03, col), Material(marble, grain: .cloth), outline: 0.005)
            d.decal(d.rect(x + 0.004, base, 0.011, col), dark, alpha: 0.18)
            d.add(d.rect(x - 0.021, base + col - 0.004, 0.042, 0.014), Material(marble.scaled(1.02)), outline: 0.004)
        }
        // Entablature and pediment.
        d.add(d.rect(x0 - 0.012, base + col + 0.008, w + 0.024, 0.026), Material(marble), outline: 0.006)
        let pediment = d.poly([(x0 - 0.016, top + 0.004), (x1 + 0.016, top + 0.004), (0, top + 0.085)])
        d.add(pediment, Material(marble.scaled(1.02)), outline: 0.007)
        d.decal(d.poly([(x0 + 0.03, top + 0.014), (x1 - 0.03, top + 0.014), (0, top + 0.064)]), dark, alpha: 0.16, clip: pediment)
        // A scroll over the door: what the building is.
        d.add(d.rect(-0.025, base + col * 0.5, 0.05, 0.022), Material(Tone(0.93, 0.86, 0.66)), outline: 0.004)
    }

    /// Two market stalls under striped awnings in team paint, with produce, crates and a barrel.
    private static func market(_ d: inout Draft) {
        for (cx, back) in [(-0.09, true), (0.1, false)] as [(CGFloat, Bool)] {
            let y0: CGFloat = back ? 0.05 : 0
            let w: CGFloat = 0.17, h: CGFloat = 0.12
            for x in [cx - w / 2 + 0.01, cx + w / 2 - 0.01] {
                d.add(d.rect(x - 0.006, y0, 0.012, h), Material(timber, grain: .wood), outline: 0.004)
            }
            // The counter and its wares.
            d.add(d.rect(cx - w / 2 + 0.005, y0, w - 0.01, 0.055), Material(wood, grain: .planks), outline: 0.006)
            let wares: [Tone] = [Tone(0.86, 0.5, 0.18), Tone(0.62, 0.72, 0.28), Tone(0.78, 0.2, 0.16), Tone(0.92, 0.78, 0.36)]
            for i in 0..<5 {
                let x = cx - w / 2 + 0.025 + CGFloat(i) * (w - 0.05) / 4
                d.add(d.ellipse(x, y0 + 0.066, 0.016, 0.014), Material(wares[(i + (back ? 1 : 0)) % wares.count], gloss: 0.3), outline: 0.004)
            }
            // The awning: stripes of team paint and cream, sloping toward the front.
            let awning = d.poly([(cx - w / 2 - 0.012, y0 + h - 0.015), (cx + w / 2 + 0.012, y0 + h - 0.015), (cx + w / 2 + 0.012 + 0.03, y0 + h + 0.05),
                                 (cx - w / 2 - 0.012 + 0.03, y0 + h + 0.05)])
            d.add(awning, Material(Tone(0.95, 0.91, 0.82), grain: .cloth), outline: 0.007)
            let stripes = 5
            for i in stride(from: 0, to: stripes, by: 2) {
                let t0 = CGFloat(i) / CGFloat(stripes), t1 = CGFloat(i + 1) / CGFloat(stripes)
                let l = cx - w / 2 - 0.012, span = w + 0.024
                d.add(d.poly([(l + span * t0, y0 + h - 0.015), (l + span * t1, y0 + h - 0.015), (l + span * t1 + 0.03, y0 + h + 0.05),
                              (l + span * t0 + 0.03, y0 + h + 0.05)]), Material(team: 1, grain: .cloth), outline: 0)
            }
            // Its scalloped valance.
            for i in 0..<5 {
                let x = cx - w / 2 - 0.004 + CGFloat(i) * (w + 0.008) / 4
                d.add(d.ellipse(x, y0 + h - 0.016, 0.019, 0.013), Material(team: 0.85, grain: .cloth), outline: 0.004)
            }
        }
        // Crates and a barrel in front.
        d.add(d.rect(-0.2, -0.01, 0.06, 0.05), Material(wood.scaled(1.1), grain: .planks), outline: 0.005)
        d.add(d.rect(-0.17, 0.035, 0.05, 0.04), Material(wood, grain: .planks), outline: 0.005)
        let barrel = d.blob([(0.2, 0.0), (0.188, 0.035), (0.2, 0.07), (0.245, 0.07), (0.257, 0.035), (0.245, 0.0)])
        d.add(barrel, Material(wood.scaled(0.9), grain: .planks), outline: 0.005)
        for y in [0.016, 0.054] as [CGFloat] { d.stroke([(0.19, y), (0.255, y)], iron, width: 0.006, clip: barrel) }
    }

    /// A round stone tower with a parapet and a conical roof flying the owner's pennant. Its
    /// foot is the middle of its base.
    private static func tower(_ d: inout Draft) {
        let r: CGFloat = 0.075, h: CGFloat = 0.22
        roundTower(&d, x: 0, radius: r, height: h)
        let y = h + 0.035
        let cone = d.poly([(-r * 1.25, y), (0, y + 0.12), (r * 1.25, y)])
        d.add(cone, Material(slate, grain: .planks))
        d.decal(d.poly([(0, y + 0.12), (r * 1.25, y), (r * 0.3, y)]), dark, alpha: 0.3, clip: cone)
        d.stroke([(-r * 1.25, y + 0.004), (r * 1.25, y + 0.004)], slate.shadow, width: 0.01, alpha: 0.7, clip: cone)
        // Pennant.
        let top = (CGFloat(0), y + 0.12)
        d.add(d.line([top, (top.0, top.1 + 0.065)], 0.008), Material(timber), outline: 0.003)
        let pennant = d.poly([(0.004, top.1 + 0.062), (0.1, top.1 + 0.047), (0.004, top.1 + 0.03)])
        d.add(pennant, Material(team: 1, grain: .cloth), outline: 0.005)
    }

    /// A round stone tower body from the ground to its parapet (tile sizes; `x` its middle).
    private static func roundTower(_ d: inout Draft, x: CGFloat, radius r: CGFloat, height h: CGFloat) {
        let body = d.blob([(x - r, 0.006), (x - r, h * 0.5), (x - r, h), (x, h + 0.012), (x + r, h), (x + r, h * 0.5), (x + r, 0.006),
                           (x, -0.022)])
        d.add(body, Material(stone, grain: .hide))
        d.decal(d.rect(x + r * 0.3, -0.03, r, h + 0.05), dark, alpha: 0.28, clip: body)
        d.decal(d.rect(x - r * 0.8, -0.03, r * 0.35, h + 0.05), Tone(1, 0.95, 0.85), alpha: 0.12, clip: body)
        var y: CGFloat = 0.035
        while y < h {
            d.stroke([(x - r, y), (x, y - 0.01), (x + r, y)], stone.shadow, width: 0.004, alpha: 0.35, clip: body)
            y += 0.035
        }
        d.add(d.rect(x - 0.008, h * 0.55, 0.016, 0.045), Material(dark, shade: 0, light: 0), outline: 0.003)
        // Parapet, wider than the body, crenellated.
        let parapet = d.blob([(x - r * 1.18, h - 0.006), (x - r * 1.18, h + 0.03), (x, h + 0.042), (x + r * 1.18, h + 0.03), (x + r * 1.18, h - 0.006),
                              (x, h - 0.03)])
        d.add(parapet, Material(stone.scaled(1.04), grain: .hide), outline: 0.007)
        d.decal(d.rect(x + r * 0.3, h - 0.04, r, 0.09), dark, alpha: 0.22, clip: parapet)
        for t in [-0.75, -0.25, 0.25, 0.75] as [CGFloat] {
            let mx = x + t * r * 1.1
            d.add(d.rect(mx - 0.012, h + 0.024 - abs(t) * 0.01, 0.024, 0.026), Material(stone.scaled(1.04 - (t > 0 ? 0.2 : 0))), outline: 0.004)
        }
    }

    /// The wall's gate: two round towers either side of an arched gateway with its doors open,
    /// battlements over it and the owner's banner hanging below them.
    private static func gatehouse(_ d: inout Draft) {
        let h: CGFloat = 0.2, w: CGFloat = 0.13
        let block = d.rect(-w, 0, 2 * w, h)
        d.add(block, Material(stone, grain: .hide))
        dress(&d, front: block, x0: -w, x1: w, h: h, beams: false, coursed: true, wall: stone)
        let arch = d.poly([(-0.045, 0), (0.045, 0), (0.045, 0.075), (0.032, 0.1), (0, 0.112), (-0.032, 0.1), (-0.045, 0.075)])
        d.add(arch, Material(dark, shade: 0, light: 0), outline: 0.004)
        d.add(d.poly([(-0.045, 0), (-0.062, -0.012), (-0.062, 0.07), (-0.045, 0.075)]), Material(wood.scaled(0.8), grain: .planks), outline: 0.004)
        d.add(d.poly([(0.045, 0), (0.062, -0.012), (0.062, 0.07), (0.045, 0.075)]), Material(wood.scaled(0.7), grain: .planks), outline: 0.004)
        merlons(&d, from: (-w, h), to: (w, h), size: 0.03, tone: stone)
        let cloth = d.poly([(-0.035, h - 0.012), (0.035, h - 0.012), (0.035, h - 0.07), (0, h - 0.085), (-0.035, h - 0.07)])
        d.add(cloth, Material(team: 1, grain: .cloth), outline: 0.005)
        for x in [-0.165, 0.165] as [CGFloat] {
            roundTower(&d, x: x, radius: 0.058, height: h + 0.05)
        }
    }

    /// The town well under its little roof, a bucket on the rim and a young tree beside it.
    private static func well(_ d: inout Draft) {
        // Tree behind, to the east.
        d.add(d.line([(0.1, 0.02), (0.11, 0.12)], 0.016, 0.01), Material(timber, grain: .wood), outline: 0.004)
        let crown = d.blob([(0.04, 0.12), (0.06, 0.2), (0.11, 0.23), (0.17, 0.2), (0.18, 0.13), (0.12, 0.09)])
        d.add(crown, Material(Tone(0.42, 0.56, 0.26), grain: .hide))
        d.decal(d.blob([(0.12, 0.1), (0.17, 0.14), (0.16, 0.19), (0.13, 0.13)]), Tone(0.15, 0.25, 0.12), alpha: 0.35, clip: crown)
        let r: CGFloat = 0.065
        let rim = d.blob([(-r, 0.004), (-r, 0.05), (0, 0.062), (r, 0.05), (r, 0.004), (0, -0.016)])
        d.add(rim, Material(stone, grain: .hide))
        d.add(d.ellipse(0, 0.05, r * 0.82, 0.016), Material(dark, shade: 0, light: 0), outline: 0.003)
        for x in [-r * 0.85, r * 0.85] {
            d.add(d.rect(x - 0.007, 0.03, 0.014, 0.12), Material(timber, grain: .wood), outline: 0.004)
        }
        d.add(d.poly([(-r - 0.025, 0.14), (r + 0.025, 0.14), (0.0, 0.19)]), Material(shingle, grain: .planks), outline: 0.006)
        d.add(d.line([(-r * 0.85, 0.12), (r * 0.85, 0.12)], 0.008), Material(timber), outline: 0.003)
        d.add(d.blob([(0.03, 0.06), (0.03, 0.09), (0.06, 0.09), (0.06, 0.06)]), Material(wood, grain: .planks), outline: 0.004)
    }

    /// Two haystacks and a split-rail fence.
    private static func hay(_ d: inout Draft) {
        for (x, y, s) in [(0.07, 0.04, 0.9), (-0.06, 0.0, 1.0)] as [(CGFloat, CGFloat, CGFloat)] {
            let stack = d.blob([(x - 0.08 * s, y + 0.004), (x - 0.07 * s, y + 0.07 * s), (x, y + 0.14 * s), (x + 0.07 * s, y + 0.07 * s),
                                (x + 0.08 * s, y + 0.004), (x, y - 0.014)])
            d.add(stack, Material(thatch.scaled(1.05), grain: .hide))
            d.decal(d.rect(x + 0.02 * s, y - 0.02, 0.07 * s, 0.17 * s), dark, alpha: 0.2, clip: stack)
            d.stroke([(x - 0.075 * s, y + 0.05 * s), (x + 0.075 * s, y + 0.05 * s)], thatch.shadow, width: 0.005, alpha: 0.4, clip: stack)
        }
        for x in [-0.2, -0.13, 0.15, 0.22] as [CGFloat] {
            d.add(d.rect(x - 0.006, -0.03, 0.012, 0.06), Material(timber, grain: .wood), outline: 0.003)
        }
        d.add(d.line([(-0.21, 0.0), (-0.12, 0.0)], 0.008), Material(wood), outline: 0.003)
        d.add(d.line([(-0.21, 0.02), (-0.12, 0.02)], 0.008), Material(wood), outline: 0.003)
        d.add(d.line([(0.14, -0.006), (0.23, -0.006)], 0.008), Material(wood), outline: 0.003)
        d.add(d.line([(0.14, 0.016), (0.23, 0.016)], 0.008), Material(wood), outline: 0.003)
    }

    // MARK: Walls

    /// A quarter of the town wall's ring from angle `a0` to `a1` (radians from east, counter-
    /// clockwise, so pi is west and pi/2 north), its foot the middle of the ring. Back quarters
    /// show the inner face and the wall walk with the outer parapet beyond it; front quarters
    /// show the outer face, crenellated. `breach` (an angle) knocks a gap into it with rubble.
    private static func wall(_ d: inout Draft, from a0: CGFloat, to a1: CGFloat, back: Bool, breach: CGFloat? = nil) {
        let k = depth
        let R = SettlementPiece.wallRadius, t = SettlementPiece.wallThickness
        let H = SettlementPiece.wallHeight, mh = SettlementPiece.merlonHeight
        let ri = R - t / 2, ro = R + t / 2
        let steps = 24
        func at(_ r: CGFloat, _ a: CGFloat, _ lift: CGFloat = 0) -> (CGFloat, CGFloat) { (r * cos(a), r * sin(a) * k + lift) }
        // The angle ranges drawn (split around a breach).
        var spans: [(CGFloat, CGFloat)] = [(a0, a1)]
        let gap: CGFloat = 0.17
        if let breach { spans = [(a0, breach - gap), (breach + gap, a1)] }
        // Which way the visible face looks: sunward faces (west) are lit, the rest in shade.
        let mid = (a0 + a1) / 2
        let facing = back ? -cos(mid) : cos(mid)   // > 0: the face looks east
        let faceTone = stone.scaled(facing > 0 ? 0.74 : 1.0)
        for (s0, s1) in spans {
            let angles = (0...steps).map { s0 + (s1 - s0) * CGFloat($0) / CGFloat(steps) }
            // How far the wall stands near the breach (1 whole, lower toward the gap).
            func height(_ a: CGFloat) -> CGFloat {
                guard let breach else { return H }
                let off = abs(a - breach) - gap
                return H * min(1, 0.35 + off * 4.5 + 0.08 * sin(a * 97))
            }
            if back {
                // Wall walk on top (lit), the parapet's inner face beyond it, then the inner face.
                let walk = d.poly(angles.map { at(ri, $0, H) } + angles.reversed().map { at(ro, $0, H) })
                d.add(walk, Material(stone.scaled(0.86), shade: 0.4, grain: .planks), outline: 0.006)
                let parapet = d.poly(angles.map { at(ro, $0, H) } + crenellated(angles.reversed(), radius: ro, base: { _ in H }, height: mh))
                d.add(parapet, Material(faceTone.scaled(0.95), grain: .hide), outline: 0.007)
                let face = d.poly(angles.map { at(ri, $0) } + angles.reversed().map { at(ri, $0, H) })
                d.add(face, Material(faceTone, shade: 0.6, grain: .hide))
                masonry(&d, face: face, angles: angles, radius: ri, height: H, tone: faceTone)
            } else {
                // The wall walk peeks over the outer face, which carries the battlements.
                let walk = d.poly(angles.map { at(ro, $0, height($0)) } + angles.reversed().map { at(ri, $0, height($0)) })
                d.add(walk, Material(stone.scaled(0.8), shade: 0.4, grain: .planks), outline: 0.006)
                let top = crenellated(angles.reversed(), radius: ro, base: height, height: mh)
                let face = d.poly(angles.map { at(ro, $0) } + top)
                d.add(face, Material(faceTone, shade: 0.6, grain: .hide))
                masonry(&d, face: face, angles: angles, radius: ro, height: H, tone: faceTone)
                // The wall's foot: a darker band of rougher stone.
                d.stroke(angles.map { at(ro, $0, 0.012) }, faceTone.shadow, width: 0.02, alpha: 0.3, clip: face)
            }
        }
        if let breach {
            // Rubble spilling out of the gap.
            let c = at(ro + 0.02, breach)
            let stones: [(CGFloat, CGFloat, CGFloat)] = [(-0.07, 0.0, 0.03), (-0.025, -0.02, 0.035), (0.03, -0.012, 0.03), (0.07, 0.01, 0.026),
                                                          (-0.045, 0.03, 0.028), (0.005, 0.025, 0.032), (0.045, 0.04, 0.025), (-0.01, 0.06, 0.024)]
            for (i, s) in stones.enumerated() {
                let x = c.0 + s.0, y = c.1 + s.1
                d.add(d.blob([(x - s.2, y), (x - s.2 * 0.6, y + s.2 * 0.8), (x + s.2 * 0.5, y + s.2 * 0.9), (x + s.2, y + s.2 * 0.1),
                              (x + s.2 * 0.3, y - s.2 * 0.5)]),
                      Material(stone.scaled(0.8 + 0.06 * CGFloat(i % 4)), grain: .hide), outline: 0.005)
            }
            // Scorched, broken edges.
            d.decal(d.ellipse(c.0, c.1 + 0.07, 0.12, 0.09), dark, alpha: 0.18)
        }
    }

    /// The top edge of a parapet along `angles` at `radius` (tile sizes): merlons and crenels
    /// alternating from the wall's height there (`base`) up to `height` more; where the wall
    /// is broken down (lower than its full height) the edge is ragged instead.
    private static func crenellated(_ angles: [CGFloat], radius r: CGFloat, base: (CGFloat) -> CGFloat,
                                    height mh: CGFloat) -> [(CGFloat, CGFloat)] {
        let k = depth
        guard let first = angles.first, let last = angles.last else { return [] }
        let span = last - first
        let length = abs(span) * r
        let teeth = max(Int((length / 0.075).rounded()), 2)
        var out: [(CGFloat, CGFloat)] = []
        for i in 0..<teeth {
            let ta = CGFloat(i) / CGFloat(teeth), tb = (CGFloat(i) + 0.55) / CGFloat(teeth), tc = (CGFloat(i) + 1) / CGFloat(teeth)
            for (t, up) in [(ta, true), (tb, true), (tb, false), (tc, false)] {
                let a = first + span * t
                let h = base(a), whole = h >= SettlementPiece.wallHeight * 0.98
                out.append((r * cos(a), r * sin(a) * k + h + (up && whole ? mh : 0)))
            }
        }
        return out
    }

    /// Stone courses along a curved wall face.
    private static func masonry(_ d: inout Draft, face: CGPath, angles: [CGFloat], radius r: CGFloat, height: CGFloat, tone: Tone) {
        let k = depth
        var y: CGFloat = 0.04
        var row = 0
        while y < height {
            d.stroke(angles.map { (r * cos($0), r * sin($0) * k + y) }, tone.shadow, width: 0.004, alpha: 0.35, clip: face)
            var i = row % 2
            while i < angles.count {
                let a = angles[i]
                let p = (r * cos(a), r * sin(a) * k + y)
                d.stroke([p, (p.0, p.1 + 0.04)], tone.shadow, width: 0.0035, alpha: 0.3, clip: face)
                i += 2
            }
            y += 0.04
            row += 1
        }
    }

    // MARK: Ground

    /// The ground a settlement stands on, laid flat (y up: south, where the gate is, at the
    /// bottom of the cell; the hex's middle a little below the cell's, `MapRenderer.cityGround`):
    /// packed earth in soft patches of lighter and darker soil, worn paler where feet go — a
    /// lane winding up from the south to the hall, lanes off to the houses and one out of the
    /// village, and a square in front of the hall where the units muster — with ruts, scuffs
    /// and pebbles. A walled town (`paved`) has its square and main lane laid with flagstones.
    /// The alpha fades out toward a ragged rim so the tile's own ground shows through, and the
    /// lanes thin out into it. Nothing in it is lit from one side, so cities mirror it with
    /// their plan (`CityLayout.mirrored`); the unit shader tints it per terrain.
    private static func paintGround(cell: CGRect, ctx: CGContext, paved: Bool) {
        let size = cell.width
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cell.minX + x * size, y: cell.minY + y * size) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        var rng = SplitMix64(seed: paved ? 0x5E77_1F : 0x5E77_1E)
        func rnd() -> CGFloat { CGFloat(rng.nextUnit()) }
        let earth = Tone(0.6, 0.5, 0.37), darkEarth = Tone(0.47, 0.38, 0.28), paleEarth = Tone(0.69, 0.6, 0.45)
        let worn = Tone(0.77, 0.68, 0.52)
        // Cell fractions of the places the plan puts things (`MapRenderer.buildLayout`, for a
        // ground about 1.75 tile sizes wide): the square where units stand, the hall's door and
        // the two houses beside it.
        let square = CGPoint(x: 0.5, y: 0.31), hall = CGPoint(x: 0.51, y: 0.64)
        let left = CGPoint(x: 0.28, y: 0.575), right = CGPoint(x: 0.74, y: 0.56)

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // The patch: a soft disc, its rim broken up by lobes of different sizes.
        if let g = CGGradient(colorsSpace: space, colors: [earth.cg(0.92), earth.cg(0.86), earth.cg(0)] as CFArray, locations: [0, 0.6, 1]) {
            let c = pt(0.5, 0.49)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: size * 0.4, options: [])
            for i in 0..<13 {
                let a = CGFloat(i) / 13 * 2 * .pi + (rnd() - 0.5) * 0.5
                let r = 0.2 + 0.07 * rnd()
                let p = pt(0.5 + cos(a) * r, 0.49 + sin(a) * r * 0.94)
                ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: size * (0.11 + 0.08 * rnd()), options: [])
            }
        }
        // Soil in patches at two scales, drawn only where the patch is (source atop).
        ctx.setBlendMode(.sourceAtop)
        for scale in [0.07, 0.035] as [CGFloat] {
            for _ in 0..<(scale > 0.05 ? 26 : 60) {
                let a = rnd() * 2 * .pi, r = sqrt(rnd()) * 0.36
                let p = pt(0.5 + cos(a) * r, 0.49 + sin(a) * r)
                let s = size * scale * (0.6 + 0.8 * rnd())
                let tone = rnd() < 0.5 ? darkEarth : paleEarth
                ctx.setFillColor(tone.cg(0.18 + 0.14 * rnd()))
                ctx.fillEllipse(in: CGRect(x: p.x - s, y: p.y - s * (0.55 + 0.3 * rnd()), width: 2 * s, height: 2 * s * (0.55 + 0.3 * rnd())))
            }
        }
        ctx.setBlendMode(.normal)

        /// A lane along a cubic from `a` to `b` (cell fractions), `w0` wide at its start and `w1`
        /// at its end, thinning to nothing over the last `fade` of it: a soft band (a faint wide
        /// one under a stronger narrow one), filled as one outline so nothing overlaps itself.
        func lane(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, _ w0: CGFloat, _ w1: CGFloat, fade: CGFloat,
                  tone: Tone, alpha: CGFloat) {
            let n = 32
            var spine: [(CGPoint, CGPoint, CGFloat)] = [] // point, normal, half width
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n), u = 1 - t
                let p = CGPoint(x: u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x,
                                y: u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y)
                let d = CGPoint(x: 3 * u * u * (c1.x - a.x) + 6 * u * t * (c2.x - c1.x) + 3 * t * t * (b.x - c2.x),
                                y: 3 * u * u * (c1.y - a.y) + 6 * u * t * (c2.y - c1.y) + 3 * t * t * (b.y - c2.y))
                let l = max(hypot(d.x, d.y), 1e-6)
                let ends = min(1, t / 0.06) * (fade > 0 ? min(1, (1 - t) / fade) : 1)
                // A little wobble in width, as feet wear it unevenly.
                let w = (w0 + (w1 - w0) * t) * (0.9 + 0.2 * sin(t * 19 + a.x * 40)) * sqrt(ends)
                spine.append((p, CGPoint(x: -d.y / l, y: d.x / l), w / 2))
            }
            for (k, opacity) in [(1.7, alpha * 0.4), (1.0, alpha)] as [(CGFloat, CGFloat)] {
                let path = CGMutablePath()
                path.addLines(between: spine.map { pt($0.0.x + $0.1.x * $0.2 * k, $0.0.y + $0.1.y * $0.2 * k) }
                    + spine.reversed().map { pt($0.0.x - $0.1.x * $0.2 * k, $0.0.y - $0.1.y * $0.2 * k) })
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(tone.cg(opacity))
                ctx.fillPath()
            }
        }
        /// Flagstones in rows across an ellipse (cell fractions), thinning out toward its rim.
        func flagstones(center: CGPoint, radii: CGSize, stone: CGFloat) {
            var y = center.y - radii.height
            var row = 0
            while y <= center.y + radii.height {
                var x = center.x - radii.width + (row % 2 == 0 ? 0 : stone * 0.55)
                while x <= center.x + radii.width {
                    let dx = (x - center.x) / radii.width, dy = (y - center.y) / radii.height
                    let rim = dx * dx + dy * dy
                    if rim < 1, rnd() > max(0, rim - 0.55) * 2.2 {
                        let w = stone * (0.78 + 0.3 * rnd()), h = stone * (0.62 + 0.22 * rnd())
                        let p = pt(x + (rnd() - 0.5) * stone * 0.12, y + (rnd() - 0.5) * stone * 0.1)
                        let rect = CGRect(x: p.x - w * size / 2, y: p.y - h * size / 2, width: w * size, height: h * size)
                        let v = 0.9 + 0.16 * rnd()
                        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height * 0.3, cornerHeight: rect.height * 0.3, transform: nil))
                        ctx.setFillColor(Tone(0.7 * v, 0.66 * v, 0.58 * v).cg(0.9))
                        ctx.fillPath()
                        // A worn, paler top (straight up: the ground is mirrored, so no side light).
                        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.22)
                            .offsetBy(dx: 0, dy: rect.height * 0.08), cornerWidth: rect.height * 0.2, cornerHeight: rect.height * 0.2, transform: nil))
                        ctx.setFillColor(Tone(0.8, 0.77, 0.7).cg(0.22))
                        ctx.fillPath()
                    }
                    x += stone * 1.1
                }
                y += stone * 0.86
                row += 1
            }
        }

        // The square in front of the hall, worn pale (paved in a walled town).
        if let g = CGGradient(colorsSpace: space, colors: [worn.cg(0.5), worn.cg(0.34), worn.cg(0)] as CFArray, locations: [0, 0.55, 1]) {
            ctx.saveGState()
            ctx.translateBy(x: cell.minX + square.x * size, y: cell.minY + square.y * size)
            ctx.scaleBy(x: 1, y: 0.62)
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: size * (paved ? 0.3 : 0.24), options: [])
            ctx.restoreGState()
        }
        // Lanes: up from the south (the gate) through the square to the hall, to the houses on
        // either side, and one wandering out of the village to the east.
        let lanes = Tone(0.75, 0.66, 0.5)
        lane(CGPoint(x: 0.5, y: -0.02), CGPoint(x: 0.46, y: 0.1), CGPoint(x: 0.54, y: 0.18), square, 0.085, 0.1, fade: 0, tone: lanes, alpha: 0.5)
        lane(square, CGPoint(x: 0.48, y: 0.44), CGPoint(x: 0.53, y: 0.53), hall, 0.1, 0.07, fade: 0.25, tone: lanes, alpha: 0.5)
        lane(CGPoint(x: 0.41, y: 0.35), CGPoint(x: 0.33, y: 0.41), CGPoint(x: 0.27, y: 0.47), left, 0.06, 0.05, fade: 0.3, tone: lanes, alpha: 0.42)
        lane(CGPoint(x: 0.58, y: 0.36), CGPoint(x: 0.66, y: 0.41), CGPoint(x: 0.73, y: 0.46), right, 0.055, 0.045, fade: 0.3, tone: lanes, alpha: 0.42)
        lane(CGPoint(x: 0.62, y: 0.3), CGPoint(x: 0.74, y: 0.27), CGPoint(x: 0.84, y: 0.34), CGPoint(x: 0.99, y: 0.3), 0.06, 0.035, fade: 0.45,
             tone: lanes, alpha: 0.38)
        if paved {
            // Flagstones on the square and up the main lane.
            flagstones(center: square, radii: CGSize(width: 0.25, height: 0.15), stone: 0.036)
            flagstones(center: CGPoint(x: 0.5, y: 0.1), radii: CGSize(width: 0.06, height: 0.12), stone: 0.034)
            flagstones(center: CGPoint(x: 0.505, y: 0.5), radii: CGSize(width: 0.055, height: 0.12), stone: 0.034)
        } else {
            // Cart ruts along the main lane.
            for side in [-1, 1] as [CGFloat] {
                ctx.move(to: pt(0.5 + side * 0.022, 0.0))
                ctx.addCurve(to: pt(0.5 + side * 0.03, 0.3), control1: pt(0.46 + side * 0.022, 0.1), control2: pt(0.54 + side * 0.026, 0.18))
                ctx.setStrokeColor(darkEarth.cg(0.22))
                ctx.setLineWidth(size * 0.006)
                ctx.setLineCap(.round)
                ctx.strokePath()
            }
        }
        // Scuffs and pebbles, only on the patch.
        ctx.setBlendMode(.sourceAtop)
        for _ in 0..<80 {
            let a = rnd() * 2 * .pi, r = sqrt(rnd()) * 0.36
            let p = pt(0.5 + cos(a) * r, 0.49 + sin(a) * r)
            let s = size * (0.006 + 0.011 * rnd())
            ctx.setFillColor((rnd() < 0.45 ? Tone(0.74, 0.68, 0.58) : Tone(0.36, 0.29, 0.21)).cg(0.3 + 0.15 * rnd()))
            ctx.fillEllipse(in: CGRect(x: p.x - s, y: p.y - s * 0.7, width: 2 * s, height: 1.4 * s))
        }
        ctx.setBlendMode(.normal)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

