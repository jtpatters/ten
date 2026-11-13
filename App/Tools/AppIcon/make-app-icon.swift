// Renders Ten Thousand Years' app icon: the game's own art, drawn with Core Graphics (no image
// files, no third-party art).
//
// One hex tile of the map as a painted diorama (docs/ART.md): grassland with a river falling
// from a snow-capped mountain, a wood and two fields, and a walled city of plaster houses
// under red tiles around a keep flying a pennant. The tile is bound in the HUD's bronze
// (App/HUDStyle.swift) and stands in the start screen's sea. One sun at the upper left, cool
// blue-violet shades, warm ink outlines and cast shadows to the lower right, as on the map.
//
// Writes the asset catalog's icon set: AppIcon.png (1024 px, opaque: the default appearance),
// AppIcon-Dark.png (the tile on a transparent ground: the dark appearance, over the system's
// dark backdrop), AppIcon-Tinted.png (its luminance: the tinted appearance) and Contents.json
// (and the catalog's own Contents.json, when missing).
// With --preview, also a sheet of the three at home-screen sizes, masked as iOS masks them.
//
//   swift App/Tools/AppIcon/make-app-icon.swift App/Assets.xcassets/AppIcon.appiconset [--preview build/icon]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Colour

struct Tone {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { self.r = r; self.g = g; self.b = b }
    func scaled(_ k: CGFloat) -> Tone { Tone(min(r * k, 1), min(g * k, 1), min(b * k, 1)) }
    func mixed(_ o: Tone, _ t: CGFloat) -> Tone { Tone(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
    /// Core shade: darker and cooler, toward blue-violet (docs/ART.md §1).
    func shade(_ k: CGFloat = 0.7) -> Tone { scaled(k).mixed(Tone(0.24, 0.24, 0.42), 0.22) }
    /// Highlight: lighter and warmer, toward sunlight.
    func lit(_ k: CGFloat = 1.12) -> Tone { scaled(k).mixed(Tone(1.0, 0.93, 0.74), 0.18) }
    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}

/// The game's colours: HUDStyle.swift (sea, bronze, cream), Palette.swift (terrain),
/// SettlementSprites.swift (buildings), docs/ART.md (ink, shadows).
enum Paint {
    static let seaLight = Tone(0.13, 0.30, 0.42)
    static let seaDark = Tone(0.04, 0.11, 0.19)
    static let bronzeTop = Tone(0.90, 0.72, 0.40)
    static let bronzeBottom = Tone(0.70, 0.48, 0.22)
    static let cream = Tone(1.00, 0.96, 0.86)
    static let ink = Tone(0.12, 0.08, 0.06)
    static let shadow = Tone(0.10, 0.10, 0.20)
    static let grass = Tone(0.49, 0.60, 0.35)
    static let plains = Tone(0.71, 0.66, 0.45)
    static let forest = Tone(0.17, 0.35, 0.17)
    static let rock = Tone(0.62, 0.58, 0.55)
    static let snow = Tone(0.93, 0.93, 0.95)
    static let water = Tone(0.30, 0.54, 0.70)
    static let foam = Tone(0.84, 0.92, 0.94)
    static let earth = Tone(0.58, 0.42, 0.27)
    static let plaster = Tone(0.90, 0.84, 0.72)
    static let stone = Tone(0.70, 0.67, 0.61)
    static let tiles = Tone(0.74, 0.38, 0.25)
    static let slate = Tone(0.42, 0.45, 0.52)
    static let timber = Tone(0.38, 0.26, 0.17)
    static let dark = Tone(0.16, 0.12, 0.10)
    static let dirt = Tone(0.66, 0.58, 0.42)
    static let wheat = Tone(0.80, 0.70, 0.40)
}

// MARK: - Geometry

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { pt(a.x + b.x, a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { pt(a.x - b.x, a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { pt(a.x * k, a.y * k) }
    func lerp(_ b: CGPoint, _ t: CGFloat) -> CGPoint { pt(x + (b.x - x) * t, y + (b.y - y) * t) }
    func up(_ h: CGFloat) -> CGPoint { pt(x, y - h) }
}

func poly(_ p: [CGPoint]) -> CGPath {
    let m = CGMutablePath()
    m.addLines(between: p)
    m.closeSubpath()
    return m
}

func polyline(_ p: [CGPoint]) -> CGPath {
    let m = CGMutablePath()
    m.addLines(between: p)
    return m
}

func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
}

func moved(_ path: CGPath, _ dx: CGFloat, _ dy: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: dx, y: dy)
    return path.copy(using: &t) ?? path
}

/// Points along a Catmull-Rom spline through `p` (open), `steps` per segment.
func spline(_ p: [CGPoint], steps: Int = 12) -> [CGPoint] {
    guard p.count > 1 else { return p }
    func at(_ i: Int) -> CGPoint { p[min(max(i, 0), p.count - 1)] }
    var out: [CGPoint] = []
    for i in 0..<(p.count - 1) {
        let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
        for s in 0..<steps {
            let t = CGFloat(s) / CGFloat(steps), t2 = t * t, t3 = t2 * t
            func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
            }
            out.append(pt(axis(p0.x, p1.x, p2.x, p3.x), axis(p0.y, p1.y, p2.y, p3.y)))
        }
    }
    out.append(p[p.count - 1])
    return out
}

/// A closed, smooth blob through `p`.
func blob(_ p: [CGPoint]) -> CGPath {
    let n = p.count
    let m = CGMutablePath()
    m.move(to: p[0])
    for i in 0..<n {
        let p0 = p[(i + n - 1) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
        m.addCurve(to: p2, control1: p1 + (p2 - p0) * (1.0 / 6), control2: p2 - (p3 - p1) * (1.0 / 6))
    }
    m.closeSubpath()
    return m
}

/// SplitMix64: the same strokes on every run.
struct RNG {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
}

// MARK: - Painter

let side = 1024
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// A 1024 px canvas whose y runs down (the coordinates below), and the strokes on it.
struct Painter {
    let ctx: CGContext

    init() {
        ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
    }

    func fill(_ path: CGPath, _ tone: Tone, _ alpha: CGFloat = 1) {
        ctx.addPath(path)
        ctx.setFillColor(tone.cg(alpha))
        ctx.fillPath()
    }

    func stroke(_ path: CGPath, _ tone: Tone, width: CGFloat, alpha: CGFloat = 1) {
        ctx.addPath(path)
        ctx.setStrokeColor(tone.cg(alpha))
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    /// An ink outline (docs/ART.md §3): silhouettes at alpha 0.45, interior lines lighter.
    func outline(_ path: CGPath, width: CGFloat = 3, alpha: CGFloat = 0.45) { stroke(path, Paint.ink, width: width, alpha: alpha) }

    func brush(_ pts: [CGPoint], _ tone: Tone, width: CGFloat, alpha: CGFloat) {
        stroke(polyline(spline(pts, steps: 6)), tone, width: width, alpha: alpha)
    }

    func clipped(_ path: CGPath, _ body: () -> Void) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        body()
        ctx.restoreGState()
    }

    func gradient(_ stops: [(CGFloat, Tone)], alpha: CGFloat = 1) -> CGGradient {
        CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1.cg(alpha) } as CFArray, locations: stops.map(\.0))!
    }

    func linear(_ path: CGPath, _ stops: [(CGFloat, Tone)], from a: CGPoint, to b: CGPoint, alpha: CGFloat = 1) {
        clipped(path) {
            ctx.drawLinearGradient(gradient(stops, alpha: alpha), start: a, end: b,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// A radial wash from `tone` at `alpha` in the middle to nothing at `radius`.
    func glow(_ c: CGPoint, radius: CGFloat, _ tone: Tone, alpha: CGFloat) {
        let g = CGGradient(colorsSpace: sRGB, colors: [tone.cg(alpha), tone.cg(0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
    }

    /// `path` filled with soft edges: the shape is drawn off the canvas and only its shadow,
    /// blurred, lands on it. (Shadow offsets and blur are in the base space, whose x runs as
    /// ours but which the scene's scale does not reach: `k` converts.)
    func soft(_ path: CGPath, _ tone: Tone, alpha: CGFloat, blur: CGFloat) {
        ctx.saveGState()
        let k = ctx.ctm.a
        ctx.setShadow(offset: CGSize(width: -4096, height: 0), blur: blur * k, color: tone.cg(alpha))
        ctx.translateBy(x: 4096 / k, y: 0)
        ctx.addPath(path)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: - The tile

/// A pointy-top hex (the map's orientation) seen from the south: its top squashed for the
/// tilt, standing `thickness` out of the sea.
enum Tile {
    static let center = pt(512, 476)
    static let radius: CGFloat = 384
    static let squash: CGFloat = 0.8
    static let thickness: CGFloat = 70
    /// A point on the top, from map-plane offsets of the tile's middle (x east, y south).
    static func ground(_ u: CGFloat, _ v: CGFloat) -> CGPoint { pt(center.x + u, center.y + v * squash) }
    /// Top, upper right, lower right, bottom, lower left, upper left.
    static let corners: [CGPoint] = (0..<6).map { i in
        let a = CGFloat(-90 + 60 * i) * .pi / 180
        return ground(radius * cos(a), radius * sin(a))
    }
    static let top = poly(corners)
    static func down(_ p: CGPoint) -> CGPoint { pt(p.x, p.y + thickness) }
    static let silhouette = poly([corners[0], corners[1], down(corners[2]), down(corners[3]), down(corners[4]), corners[5]])
    /// The front edge of the top, lower left to lower right, where the river leaves it.
    static func frontEdge(_ x: CGFloat) -> CGPoint {
        let (l, b, r) = (corners[4], corners[3], corners[2])
        return x <= b.x ? l.lerp(b, (x - l.x) / (b.x - l.x)) : b.lerp(r, (x - b.x) / (r.x - b.x))
    }
}

/// Shading of a wall facing `normal` (map plane, x east, y south): lit from the west and from
/// the viewer's side, east faces in shade (×0.7 as on the map's sprites).
func faceLight(_ normal: CGPoint) -> CGFloat {
    let l = pt(-0.8, 0.6), n = hypot(normal.x, normal.y)
    return 0.86 + 0.23 * (normal.x * l.x + normal.y * l.y) / max(n, 0.0001)
}

func drawSea(_ p: Painter) {
    p.ctx.drawRadialGradient(p.gradient([(0, Paint.seaLight.scaled(1.18)), (0.55, Paint.seaLight.mixed(Paint.seaDark, 0.55)),
                                         (1, Paint.seaDark.scaled(0.85))]),
                             startCenter: pt(400, 330), startRadius: 0, endCenter: pt(470, 420), endRadius: 860,
                             options: [.drawsAfterEndLocation])
    // Swell: long, faint strokes, brighter toward the sun.
    var rng = RNG(11)
    for _ in 0..<170 {
        let x = rng.range(-60, 1000), y = rng.range(10, 1014), len = rng.range(40, 140)
        let lit = max(0, 1 - hypot(x - 360, y - 300) / 760)
        let tone = Paint.seaLight.mixed(Paint.foam, 0.3 + 0.2 * lit)
        p.brush([pt(x, y), pt(x + len * 0.5, y + rng.range(-4, 4)), pt(x + len, y + rng.range(-3, 3))], tone,
                width: rng.range(2, 5), alpha: 0.04 + 0.12 * lit)
    }
}

/// The tile's shadow on the water and the foam at its foot.
func drawWaterline(_ p: Painter, rng: inout RNG) {
    p.soft(moved(Tile.silhouette, 44, 30), Paint.shadow.scaled(0.4), alpha: 0.6, blur: 34)
    let base = [pt(Tile.corners[4].x - 14, Tile.down(Tile.corners[4]).y - 6), Tile.down(Tile.corners[4]),
                Tile.down(Tile.corners[3]), Tile.down(Tile.corners[2]), pt(Tile.corners[2].x + 14, Tile.down(Tile.corners[2]).y - 6)]
    var along: [CGPoint] = []
    for i in 0..<(base.count - 1) {
        for s in 0..<16 { along.append(base[i].lerp(base[i + 1], CGFloat(s) / 16)) }
    }
    along.append(base[base.count - 1])
    for ring in 0..<4 {
        let off = CGFloat(ring) * 7 + 3
        var i = 0
        while i < along.count - 3 {
            let n = 2 + Int(rng.range(0, 4))
            let seg = along[i..<min(i + n + 1, along.count)].map { pt($0.x + rng.range(-2, 2), $0.y + off + rng.range(-2, 2)) }
            if rng.unit() < 0.85 - CGFloat(ring) * 0.18 {
                p.brush(seg, Paint.foam, width: 5 - CGFloat(ring), alpha: 0.75 - CGFloat(ring) * 0.16)
            }
            i += n + Int(rng.range(0, 2))
        }
    }
}

/// The tile's sides: earth under a lip of turf, lit to the south-west, in shade to the
/// south-east.
func drawSides(_ p: Painter, rng: inout RNG) {
    let c = Tile.corners
    let faces: [(CGPoint, CGPoint, Bool)] = [(c[4], c[3], true), (c[3], c[2], false)]
    for (a, b, lit) in faces {
        let face = poly([a, b, Tile.down(b), Tile.down(a)])
        let earth = lit ? Paint.earth : Paint.earth.shade(0.62)
        p.linear(face, [(0, earth.lit(1.04)), (1, earth.scaled(0.74))], from: pt(0, min(a.y, b.y)), to: pt(0, max(a.y, b.y) + Tile.thickness))
        p.clipped(face) {
            // Strata.
            for k in 0..<4 {
                let depth = 26 + CGFloat(k) * 11 + rng.range(-2, 2)
                let pts = (0...10).map { i -> CGPoint in let q = a.lerp(b, CGFloat(i) / 10); return pt(q.x, q.y + depth + rng.range(-2.5, 2.5)) }
                p.brush(pts, earth.shade(0.7), width: rng.range(2, 3.5), alpha: 0.35)
            }
            // Stones.
            for _ in 0..<26 {
                let q = a.lerp(b, rng.unit())
                let s = pt(q.x, q.y + rng.range(22, Tile.thickness - 6))
                p.fill(ellipse(s, rng.range(3, 6), rng.range(2, 4)), earth.lit(1.25), lit ? 0.45 : 0.25)
            }
            // Turf, with a ragged edge.
            let turf = earthLip(a, b, rng: &rng)
            p.fill(turf, lit ? Paint.grass.scaled(0.78) : Paint.grass.shade(0.6))
            p.stroke(turf, Paint.ink, width: 1.5, alpha: 0.18)
        }
        p.outline(face, width: 3, alpha: 0.4)
    }
}

func earthLip(_ a: CGPoint, _ b: CGPoint, rng: inout RNG) -> CGPath {
    var pts: [CGPoint] = []
    for i in 0...24 {
        let q = a.lerp(b, CGFloat(i) / 24)
        pts.append(pt(q.x, q.y + 14 + rng.range(-3, 5) + (i % 3 == 0 ? rng.range(2, 6) : 0)))
    }
    return poly([a.up(4)] + pts + [b.up(4)])
}

/// The river: from the foot of the mountain to the tile's front edge, where it falls into
/// the sea.
let riverCourse: [CGPoint] = [pt(408, 344), pt(398, 402), pt(380, 452), pt(372, 500), pt(380, 548), pt(366, 606), pt(352, 652),
                              Tile.frontEdge(346), Tile.frontEdge(346) + pt(-1, 8)]

func riverShape() -> (CGPath, [CGPoint]) {
    let mid = spline(riverCourse, steps: 10)
    var left: [CGPoint] = [], right: [CGPoint] = []
    for (i, q) in mid.enumerated() {
        let a = mid[max(i - 1, 0)], b = mid[min(i + 1, mid.count - 1)]
        let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 0.001)
        let t = CGFloat(i) / CGFloat(mid.count - 1)
        let half = 4 + 9 * t
        left.append(pt(q.x - dy / len * half, q.y + dx / len * half))
        right.append(pt(q.x + dy / len * half, q.y - dx / len * half))
    }
    return (poly(left + right.reversed()), mid)
}

func drawGround(_ p: Painter, rng: inout RNG) {
    let c = Tile.corners
    p.linear(Tile.top, [(0, Paint.grass.mixed(Paint.plains, 0.22).lit(1.06)), (0.55, Paint.grass), (1, Paint.grass.scaled(0.9))],
             from: c[0], to: c[3])
    p.clipped(Tile.top) {
        // Patches: regional tint.
        let tints = [Paint.grass.mixed(Paint.plains, 0.45), Paint.grass.scaled(0.84), Paint.grass.lit(1.1), Paint.grass.mixed(Paint.forest, 0.3)]
        for i in 0..<34 {
            let cx = rng.range(150, 870), cy = rng.range(170, 780), r = rng.range(36, 90)
            let pts = (0..<8).map { k -> CGPoint in
                let a = CGFloat(k) / 8 * 2 * .pi, rr = r * rng.range(0.7, 1.15)
                return pt(cx + cos(a) * rr, cy + sin(a) * rr * Tile.squash)
            }
            p.fill(blob(pts), tints[i % tints.count], rng.range(0.16, 0.3))
        }
        // Fine strokes.
        let strokeTones = [Paint.grass.lit(1.16), Paint.grass.scaled(0.82), Paint.grass.mixed(Paint.plains, 0.5), Paint.grass.shade(0.85)]
        for i in 0..<520 {
            let x = rng.range(150, 870), y = rng.range(170, 780)
            let a = rng.range(-0.35, 0.35), len = rng.range(10, 30)
            let s = pt(x, y), e = pt(x + cos(a) * len, y + sin(a) * len * Tile.squash)
            p.brush([s, s.lerp(e, 0.5) + pt(0, rng.range(-3, 3)), e], strokeTones[i % strokeTones.count], width: rng.range(2.5, 5.5),
                    alpha: rng.range(0.16, 0.3))
        }
        drawFields(p, rng: &rng)
        // The road from the city gate toward the front.
        let road = spline([pt(546, 618), pt(560, 664), pt(546, 712), pt(556, 770)], steps: 10)
        p.stroke(polyline(road), Paint.dirt.shade(0.8), width: 15, alpha: 0.35)
        p.stroke(polyline(road), Paint.dirt, width: 10, alpha: 0.85)
        p.stroke(polyline(road.map { $0 + pt(-2, -1) }), Paint.dirt.lit(1.15), width: 3, alpha: 0.5)
        // The city's ground: its shadow, then the trodden earth inside the wall.
        p.soft(ellipse(City.center + pt(18, 14), City.a + 8, City.b + 8), Paint.shadow, alpha: 0.38, blur: 14)
        p.soft(ellipse(City.center, City.a + 4, City.b + 4), Paint.dirt.scaled(0.9), alpha: 0.6, blur: 8)
        p.fill(ellipse(City.center, City.a - 6, City.b - 6), Paint.dirt, 0.9)
        for _ in 0..<60 {
            let q = City.center + pt(rng.range(-130, 130), rng.range(-95, 95))
            p.brush([q, q + pt(rng.range(8, 18), rng.range(-2, 2))], Paint.dirt.scaled(rng.range(0.85, 1.12)), width: 3, alpha: 0.35)
        }
        drawRiver(p)
        // The mountain's shoulder and the wood's floor darken the ground around them.
        p.soft(ellipse(pt(352, 362), 150, 34), Paint.grass.shade(0.7), alpha: 0.5, blur: 16)
        p.soft(ellipse(pt(276, 516), 92, 120), Paint.forest, alpha: 0.32, blur: 24)
        // The sun at the upper left; the far corner in shade.
        p.glow(pt(300, 250), radius: 560, Paint.cream, alpha: 0.12)
        p.glow(pt(800, 720), radius: 420, Paint.shadow, alpha: 0.16)
    }
}

func drawFields(_ p: Painter, rng: inout RNG) {
    let fields: [([CGPoint], Tone)] = [
        ([pt(604, 646), pt(694, 622), pt(726, 658), pt(636, 684)], Paint.wheat),
        ([pt(708, 616), pt(784, 598), pt(808, 628), pt(734, 648)], Paint.grass.mixed(Paint.wheat, 0.45)),
        ([pt(642, 696), pt(724, 672), pt(746, 700), pt(668, 724)], Paint.grass.mixed(Paint.wheat, 0.7)),
    ]
    for (corners, tone) in fields {
        let field = poly(corners)
        p.fill(field, tone, 0.92)
        p.clipped(field) {
            for k in 1..<9 {
                let t = CGFloat(k) / 9
                p.stroke(polyline([corners[0].lerp(corners[1], t), corners[3].lerp(corners[2], t)]), tone.shade(0.8), width: 2.5, alpha: 0.45)
            }
            p.glow(corners[0], radius: 90, Paint.cream, alpha: 0.18)
        }
        // A hedge on the far and east sides.
        p.stroke(polyline([corners[0], corners[1], corners[2]]), Paint.forest.scaled(1.2), width: 4.5, alpha: 0.7)
    }
}

func drawRiver(_ p: Painter) {
    let (shape, mid) = riverShape()
    p.stroke(shape, Paint.grass.shade(0.55), width: 7, alpha: 0.45)  // banks
    p.fill(shape, Paint.water)
    p.clipped(shape) {
        p.stroke(polyline(mid.map { $0 + pt(4, 2) }), Paint.water.shade(0.75), width: 9, alpha: 0.6)
        p.stroke(polyline(mid.map { $0 + pt(-3, -1) }), Paint.foam, width: 3, alpha: 0.55)
    }
}

/// The waterfall down the lit side, into the foam.
func drawFall(_ p: Painter, rng: inout RNG) {
    let x0: CGFloat = 334, x1: CGFloat = 358
    let a = Tile.frontEdge(x0), b = Tile.frontEdge(x1)
    let fall = poly([a, b, pt(x1 + 3, b.y + Tile.thickness + 4), pt(x0 - 3, a.y + Tile.thickness + 4)])
    p.fill(fall, Paint.water.lit(1.08))
    p.clipped(fall) {
        for k in 0..<7 {
            let x = x0 + 2 + CGFloat(k) * 3.6 + rng.range(-1, 1)
            p.brush([pt(x, a.y), pt(x + rng.range(-1, 1), a.y + 40), pt(x + rng.range(-1, 1), a.y + 90)], Paint.foam, width: rng.range(1.5, 3),
                    alpha: rng.range(0.35, 0.7))
        }
    }
    p.outline(fall, width: 2, alpha: 0.25)
    for _ in 0..<16 {
        let q = pt(rng.range(x0 - 10, x1 + 10), b.y + Tile.thickness + rng.range(-2, 10))
        p.fill(ellipse(q, rng.range(4, 9), rng.range(3, 5)), Paint.foam, rng.range(0.5, 0.85))
    }
}

/// The bronze binding round the top.
func drawRim(_ p: Painter) {
    p.stroke(Tile.top, Paint.ink, width: 14, alpha: 0.5)
    p.ctx.saveGState()
    p.ctx.addPath(Tile.top)
    p.ctx.setLineWidth(9)
    p.ctx.replacePathWithStrokedPath()
    p.ctx.clip()
    p.ctx.drawLinearGradient(p.gradient([(0, Paint.bronzeTop.lit(1.08)), (0.5, Paint.bronzeTop), (1, Paint.bronzeBottom)]),
                             start: pt(260, 200), end: pt(780, 800), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    p.ctx.restoreGState()
    p.stroke(polyline([Tile.corners[4], Tile.corners[5], Tile.corners[0], Tile.corners[1]].map { $0 + pt(0.5, -1.5) }), Paint.cream,
             width: 2, alpha: 0.55)
}

// MARK: - The mountain and the wood

func drawMountain(_ p: Painter, rng: inout RNG) {
    let peak = pt(340, 128)
    let west = [pt(222, 360), pt(246, 316), pt(262, 296), pt(280, 262), pt(296, 236), pt(308, 204), pt(324, 170), peak]
    let east = [pt(356, 150), pt(370, 176), pt(386, 192), pt(404, 228), pt(424, 258), pt(444, 296), pt(466, 330), pt(486, 356)]
    let foot = [pt(452, 372), pt(400, 382), pt(348, 384), pt(292, 380), pt(246, 372)]
    let ridge = [peak, pt(348, 176), pt(340, 220), pt(356, 262), pt(350, 310), pt(366, 352), pt(372, 383)]
    let shape = poly(west + east + foot)
    p.soft(ellipse(pt(450, 382), 96, 22), Paint.shadow, alpha: 0.4, blur: 12)
    let litFace = poly(west + ridge.dropFirst() + [pt(348, 384), pt(292, 380), pt(246, 372)])
    let shadeFace = poly([peak] + east + [pt(452, 372), pt(400, 382)] + ridge.reversed())
    p.linear(litFace, [(0, Paint.rock.lit(1.08)), (1, Paint.rock.mixed(Paint.grass, 0.3).scaled(0.92))], from: peak, to: pt(300, 384))
    p.linear(shadeFace, [(0, Paint.rock.shade(0.7)), (1, Paint.rock.mixed(Paint.grass, 0.25).shade(0.62))], from: peak, to: pt(420, 384))
    // Snow, its lower edge broken by the gullies.
    let line = [pt(286, 260), pt(300, 238), pt(312, 252), pt(324, 228), pt(334, 252), pt(346, 232), pt(356, 250), pt(368, 226),
                pt(380, 244), pt(392, 220), pt(408, 238)]
    let snow = poly(line + [pt(430, 90), pt(260, 90)])
    p.clipped(shape) {
        p.clipped(litFace) { p.fill(snow, Paint.snow) }
        p.clipped(shadeFace) { p.fill(snow, Paint.snow.shade(0.84)) }
        // Gullies and strata.
        for k in 0..<9 {
            let x = 250 + CGFloat(k) * 26 + rng.range(-6, 6)
            let y = 250 + abs(x - 340) * 0.5 + rng.range(-10, 10)
            let litSide = x < 352
            p.brush([pt(x, y), pt(x + (litSide ? -10 : 8), y + 30), pt(x + (litSide ? -18 : 14), y + 62)],
                    litSide ? Paint.rock.shade(0.7) : Paint.rock.shade(0.55), width: 3, alpha: 0.35)
        }
        for k in 0..<6 {
            let x = 300 + CGFloat(k) * 16 + rng.range(-4, 4)
            p.brush([pt(x, 232 + rng.range(0, 16)), pt(x - 4, 262 + rng.range(0, 12))], Paint.snow, width: 2.5, alpha: 0.6)
        }
        p.brush([peak + pt(-4, 10), pt(316, 190), pt(296, 236)], Paint.cream, width: 3, alpha: 0.5)
    }
    p.outline(shape, width: 3.5, alpha: 0.45)
}

func drawTree(_ p: Painter, foot f: CGPoint, r: CGFloat, rng: inout RNG) {
    p.soft(ellipse(f + pt(r * 0.7, r * 0.12), r * 1.15, r * 0.42), Paint.shadow, alpha: 0.42, blur: 6)
    let trunk = poly([f + pt(-r * 0.12, 1), f + pt(r * 0.12, 1), f + pt(r * 0.08, -r * 0.9), f + pt(-r * 0.08, -r * 0.9)])
    p.fill(trunk, Paint.timber)
    p.outline(trunk, width: 2, alpha: 0.45)
    let c = f.up(r * 1.42)
    let lobes: [(CGPoint, CGFloat)] = [(c, r), (c + pt(-r * 0.56, r * 0.24), r * 0.64), (c + pt(r * 0.58, r * 0.2), r * 0.68),
                                       (c + pt(r * 0.06, -r * 0.52), r * 0.6)]
    let crown = CGMutablePath()
    for (o, rr) in lobes { crown.addPath(ellipse(o, rr * rng.range(0.94, 1.06), rr)) }
    for (o, rr) in lobes { p.stroke(ellipse(o, rr, rr), Paint.ink, width: 5, alpha: 0.42) }
    let leaf = Paint.forest.scaled(1.25)
    p.fill(crown, leaf)
    p.clipped(crown) {
        p.soft(ellipse(c + pt(r * 0.55, r * 0.6), r * 0.95, r * 0.85), leaf.shade(0.62), alpha: 0.85, blur: r * 0.3)
        p.soft(ellipse(c + pt(-r * 0.36, -r * 0.42), r * 0.72, r * 0.6), leaf.lit(1.5), alpha: 0.8, blur: r * 0.3)
        for _ in 0..<7 {
            let d = c + pt(rng.range(-0.85, 0.25) * r, rng.range(-0.95, 0.05) * r)
            p.fill(ellipse(d, r * 0.15, r * 0.1), leaf.lit(1.8), 0.45)
        }
    }
}

// MARK: - The city

enum City {
    static let center = Tile.ground(56, 22)
    static let a: CGFloat = 152
    static let b: CGFloat = a * Tile.squash
    static let wallHeight: CGFloat = 36
    static let wallThickness: CGFloat = 11
    static func at(_ du: CGFloat, _ dv: CGFloat) -> CGPoint { pt(center.x + du, center.y + dv * Tile.squash) }
    static func ring(_ t: CGFloat, inset: CGFloat = 0) -> CGPoint {
        pt(center.x + (a - inset) * cos(t), center.y + (a - inset) * Tile.squash * sin(t))
    }
}

/// How depth runs on a building: back and a little to the right, so its east side shows in
/// shade (SettlementSprites' oblique).
func depth(_ dp: CGFloat) -> CGPoint { pt(dp * 0.42, -dp * 0.5) }

/// One half of the ring wall: the back half shows its inner face, the front half its outer.
func drawWall(_ p: Painter, front: Bool) {
    let n = 44, h = City.wallHeight
    let (t0, t1): (CGFloat, CGFloat) = front ? (0, .pi) : (.pi, 2 * .pi)
    let inset = front ? 0 : City.wallThickness
    func angle(_ i: Int) -> CGFloat { t0 + (t1 - t0) * CGFloat(i) / CGFloat(n) }
    if !front {
        // The walkway seen from above, behind the inner face.
        let outer = (0...n).map { City.ring(angle($0)).up(h) }, inner = (0...n).map { City.ring(angle($0), inset: inset).up(h) }
        p.fill(poly(outer + inner.reversed()), Paint.stone.lit(1.06))
    }
    for i in 0..<n {
        let a0 = angle(i), a1 = angle(i + 1) + 0.004, mid = (a0 + a1) / 2
        let b0 = City.ring(a0, inset: inset), b1 = City.ring(a1, inset: inset)
        let normal = front ? pt(cos(mid), sin(mid)) : pt(-cos(mid), -sin(mid))
        let tone = faceLight(normal) < 0.8 ? Paint.stone.shade(faceLight(normal)) : Paint.stone.scaled(faceLight(normal))
        p.fill(poly([b0, b1, b1.up(h), b0.up(h)]), tone)
    }
    let base = (0...n).map { City.ring(angle($0), inset: inset) }
    // Courses of stone.
    for k in 1..<3 {
        p.stroke(polyline(base.map { $0.up(h * CGFloat(k) / 3) }), Paint.stone.shade(0.6), width: 1.5, alpha: 0.3)
    }
    if front {
        let inner = (0...n).map { City.ring(angle($0), inset: City.wallThickness).up(h) }
        p.fill(poly(base.map { $0.up(h) } + inner.reversed()), Paint.stone.lit(1.08))
    }
    // Merlons on the outer edge.
    let count = 30
    for i in 0..<count {
        let t = t0 + (t1 - t0) * (CGFloat(i) + 0.5) / CGFloat(count)
        let q = City.ring(t).up(h)
        let normal = front ? pt(cos(t), sin(t)) : pt(-cos(t), -sin(t))
        let tone = faceLight(normal) < 0.8 ? Paint.stone.shade(faceLight(normal)) : Paint.stone.scaled(faceLight(normal) * 1.04)
        let m = poly([q + pt(-4.5, 1), q + pt(4.5, 1), q + pt(4.5, -10), q + pt(-4.5, -10)])
        p.fill(m, tone)
        p.outline(m, width: 1.5, alpha: 0.3)
    }
    p.outline(polyline(base), width: 3, alpha: front ? 0.45 : 0.3)
    p.outline(polyline(base.map { $0.up(h) }), width: 2, alpha: 0.35)
}

func drawWindow(_ p: Painter, _ c: CGPoint, w: CGFloat = 7, h: CGFloat = 9) {
    let r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    p.fill(CGPath(rect: r, transform: nil), Paint.dark, 0.85)
    p.stroke(polyline([pt(r.minX - 1, r.maxY + 1), pt(r.maxX + 1, r.maxY + 1)]), Paint.cream, width: 2, alpha: 0.6)
}

/// A house: the middle of its front wall at `f`. `ridgeAcross` runs the ridge east–west (the
/// gables to the sides), otherwise the gable faces the front.
func drawHouse(_ p: Painter, foot f: CGPoint, width w: CGFloat, depth dp: CGFloat, height h: CGFloat, roof rh: CGFloat,
               wall: Tone = Paint.plaster, roof: Tone = Paint.tiles, ridgeAcross: Bool) {
    let d = depth(dp), x0 = f.x - w / 2, x1 = f.x + w / 2, top = f.y - h, e: CGFloat = 5
    p.soft(poly([pt(x1, f.y), pt(x1 + d.x, f.y + d.y), pt(x1 + d.x + h * 0.6, f.y + d.y + h * 0.4), pt(x1 + h * 0.5, f.y + h * 0.35)]),
           Paint.shadow, alpha: 0.4, blur: 5)
    let east = poly([pt(x1, f.y), pt(x1 + d.x, f.y + d.y), pt(x1 + d.x, top + d.y), pt(x1, top)])
    p.fill(east, wall.shade())
    p.outline(east, width: 2.5)
    if ridgeAcross {
        let rise = pt(d.x / 2, d.y / 2 - rh)
        let gable = poly([pt(x1, top), pt(x1 + d.x, top + d.y), pt(x1, top) + rise])
        p.fill(gable, wall.shade())
        p.outline(gable, width: 2.5)
        let front = CGPath(rect: CGRect(x: x0, y: top, width: w, height: h), transform: nil)
        p.fill(front, wall)
        p.fill(CGPath(rect: CGRect(x: f.x - w * 0.09, y: f.y - h * 0.58, width: w * 0.18, height: h * 0.58), transform: nil), Paint.timber.shade(0.8))
        drawWindow(p, pt(x0 + w * 0.22, top + h * 0.42))
        drawWindow(p, pt(x1 - w * 0.22, top + h * 0.42))
        p.outline(front, width: 2.5)
        let eaveL = pt(x0 - e, top + 3), eaveR = pt(x1 + e, top + 3)
        let slope = poly([eaveL, eaveR, eaveR + rise, eaveL + rise])
        p.linear(slope, [(0, roof.lit(1.1)), (1, roof)], from: eaveL + rise, to: eaveL)
        p.clipped(slope) {
            for k in 1..<4 {
                let t = CGFloat(k) / 4
                p.stroke(polyline([eaveL.lerp(eaveL + rise, t), eaveR.lerp(eaveR + rise, t)]), roof.shade(0.7), width: 1.5, alpha: 0.4)
            }
            var x = eaveL.x + 6
            while x < eaveR.x {
                p.stroke(polyline([pt(x, eaveL.y), pt(x, eaveL.y) + rise]), roof.shade(0.7), width: 1.2, alpha: 0.22)
                x += 7
            }
        }
        p.stroke(polyline([eaveR, eaveR + rise, eaveR + d]), roof.shade(0.72), width: 5)
        p.outline(slope, width: 2.5)
        p.stroke(polyline([eaveL + rise, eaveR + rise]), roof.shade(0.6), width: 3)
    } else {
        let apex = pt(f.x, top - rh), eaveL = pt(x0 - e, top + 3), eaveR = pt(x1 + e, top + 3)
        let westSlope = poly([eaveL, apex, apex + d, eaveL + d]), eastSlope = poly([eaveR, apex, apex + d, eaveR + d])
        p.fill(westSlope, roof.lit(1.08))
        p.clipped(westSlope) {
            for k in 1..<5 {
                let q = eaveL.lerp(apex, CGFloat(k) / 5)
                p.stroke(polyline([q, q + d]), roof.shade(0.7), width: 1.5, alpha: 0.4)
            }
        }
        p.outline(westSlope, width: 2.5)
        p.fill(eastSlope, roof.shade(0.74))
        p.outline(eastSlope, width: 2.5)
        let front = poly([pt(x0, f.y), pt(x1, f.y), pt(x1, top), apex.up(-4), pt(x0, top)])
        p.fill(front, wall)
        p.fill(CGPath(rect: CGRect(x: f.x - w * 0.1, y: f.y - h * 0.6, width: w * 0.2, height: h * 0.6), transform: nil), Paint.timber.shade(0.8))
        drawWindow(p, pt(f.x, top - rh * 0.3), w: 6, h: 7)
        drawWindow(p, pt(x1 - w * 0.2, top + h * 0.42))
        p.outline(front, width: 2.5)
        p.stroke(polyline([eaveL, apex, eaveR]), roof.scaled(0.86), width: 6)
        p.stroke(polyline([eaveL, apex, eaveR]), Paint.ink, width: 1.5, alpha: 0.3)
    }
}

/// The keep: a square stone tower under a pyramid of tiles, flying a pennant.
func drawKeep(_ p: Painter, foot f: CGPoint) {
    let w: CGFloat = 62, dp: CGFloat = 50, h: CGFloat = 154, rh: CGFloat = 62
    let d = depth(dp), x0 = f.x - w / 2, x1 = f.x + w / 2, top = f.y - h
    p.soft(poly([pt(x1, f.y), pt(x1 + d.x, f.y + d.y), pt(x1 + d.x + 70, f.y + d.y + 40), pt(x1 + 60, f.y + 48)]),
           Paint.shadow, alpha: 0.4, blur: 8)
    let east = poly([pt(x1, f.y), pt(x1 + d.x, f.y + d.y), pt(x1 + d.x, top + d.y), pt(x1, top)])
    p.fill(east, Paint.stone.shade())
    let front = CGPath(rect: CGRect(x: x0, y: top, width: w, height: h), transform: nil)
    p.linear(front, [(0, Paint.stone.lit(1.1)), (1, Paint.stone.scaled(0.92))], from: pt(x0, top), to: pt(x1, f.y))
    for face in [east, front] {
        p.clipped(face) {
            var y = f.y - 13
            while y > top {
                p.stroke(polyline([pt(x0, y), pt(x1, y), pt(x1 + d.x, y + d.y)]), Paint.stone.shade(0.6), width: 1.5, alpha: 0.28)
                y -= 13
            }
        }
        p.outline(face, width: 2.5)
    }
    for (x, y) in [(f.x, top + 32), (f.x, top + 78), (x0 + 15, top + 122), (x1 - 15, top + 122)] as [(CGFloat, CGFloat)] {
        let slit = poly([pt(x - 3, y + 9), pt(x + 3, y + 9), pt(x + 3, y - 6), pt(x, y - 9), pt(x - 3, y - 6)])
        p.fill(slit, Paint.dark, 0.9)
    }
    // Parapet, a little wider than the tower.
    let pw: CGFloat = 5, ph: CGFloat = 15
    let band = CGPath(rect: CGRect(x: x0 - pw, y: top - ph, width: w + 2 * pw, height: ph), transform: nil)
    let bandEast = poly([pt(x1 + pw, top), pt(x1 + pw + d.x, top + d.y), pt(x1 + pw + d.x, top - ph + d.y), pt(x1 + pw, top - ph)])
    p.fill(bandEast, Paint.stone.shade(0.66))
    p.outline(bandEast, width: 2.5)
    p.fill(band, Paint.stone.lit(1.06))
    for k in 0..<6 { p.fill(CGPath(rect: CGRect(x: x0 - pw + 4 + CGFloat(k) * 12, y: top - 4, width: 5, height: 5), transform: nil), Paint.dark, 0.45) }
    p.outline(band, width: 2.5)
    // The roof.
    let f0 = pt(x0 - pw - 3, top - ph), f1 = pt(x1 + pw + 3, top - ph), b0 = f0 + d, b1 = f1 + d
    let apex = pt((f0.x + b1.x) / 2, (f0.y + b1.y) / 2 - rh)
    let roof = Paint.tiles
    for (face, tone) in [(poly([b0, b1, apex]), roof.shade(0.8)), (poly([f0, b0, apex]), roof.lit(1.1)),
                         (poly([f1, b1, apex]), roof.shade(0.72)), (poly([f0, f1, apex]), roof.scaled(1.0))] {
        p.fill(face, tone)
        p.clipped(face) {
            for k in 1..<6 {
                let t = CGFloat(k) / 6
                p.stroke(polyline([f0.lerp(apex, t), f1.lerp(apex, t), b1.lerp(apex, t)]), roof.shade(0.65), width: 1.5, alpha: 0.35)
            }
        }
        p.outline(face, width: 2.5)
    }
    // The pennant: cream, edged in gilt (player colours are for ownership, docs/ART.md §2).
    let pole = polyline([apex.up(-2), apex.up(56)])
    p.stroke(pole, Paint.ink, width: 6, alpha: 0.5)
    p.stroke(pole, Paint.timber.lit(1.2), width: 3.5)
    let t = apex.up(54)
    let cloth = blob([t + pt(2, 0), t + pt(30, 2), t + pt(62, 9), t + pt(50, 15), t + pt(64, 24), t + pt(28, 24), t + pt(2, 22)])
    p.stroke(cloth, Paint.ink, width: 5, alpha: 0.45)
    p.fill(cloth, Paint.cream.scaled(0.95))
    p.clipped(cloth) {
        p.soft(ellipse(t + pt(44, 24), 30, 12), Paint.cream.shade(0.75), alpha: 0.8, blur: 6)
        p.stroke(polyline([t + pt(4, 0), t + pt(36, 4), t + pt(62, 9)]), Paint.bronzeTop, width: 4)
    }
}

/// A round wall tower under a cone of slate (SettlementSprites' tower).
func drawRoundTower(_ p: Painter, foot f: CGPoint, radius r: CGFloat = 19, height h: CGFloat = 74, roof rh: CGFloat = 46) {
    let ry = r * 0.42, top = f.y - h
    func arc(_ c: CGPoint, _ rx: CGFloat, front: Bool) -> [CGPoint] {
        (0...12).map { k in
            let t = CGFloat.pi * (1 - CGFloat(k) / 12)
            return pt(c.x + rx * cos(t), c.y + (front ? 1 : -1) * ry * (rx / r) * sin(t))
        }
    }
    p.soft(ellipse(f + pt(r * 1.4, 4), r * 1.8, ry * 1.5), Paint.shadow, alpha: 0.4, blur: 6)
    let body = poly([pt(f.x - r, top)] + arc(f, r, front: true) + [pt(f.x + r, top)])
    p.linear(body, [(0, Paint.stone.scaled(0.95)), (0.28, Paint.stone.lit(1.12)), (0.62, Paint.stone), (1, Paint.stone.shade(0.62))],
             from: pt(f.x - r, 0), to: pt(f.x + r, 0))
    p.clipped(body) {
        var y = f.y - 12
        while y > top { p.stroke(polyline(arc(pt(f.x, y), r, front: true)), Paint.stone.shade(0.6), width: 1.5, alpha: 0.3); y -= 12 }
        p.fill(poly([pt(f.x - 7, top + h * 0.45 + 8), pt(f.x - 3, top + h * 0.45 + 8), pt(f.x - 3, top + h * 0.45 - 6), pt(f.x - 7, top + h * 0.45 - 6)]),
               Paint.dark, 0.9)
    }
    p.outline(body, width: 2.5)
    let pr = r * 1.18, pTop = top - 12
    let parapet = poly(arc(pt(f.x, pTop), pr, front: false).reversed() + arc(pt(f.x, top), pr, front: true))
    p.linear(parapet, [(0, Paint.stone.lit(1.1)), (0.6, Paint.stone), (1, Paint.stone.shade(0.62))], from: pt(f.x - pr, 0), to: pt(f.x + pr, 0))
    p.outline(parapet, width: 2.5)
    let cr = r * 1.32
    let cone = poly(arc(pt(f.x, pTop), cr, front: true) + [pt(f.x, pTop - rh)])
    p.fill(cone, Paint.slate.lit(1.1))
    p.clipped(cone) {
        p.fill(poly([pt(f.x, pTop - rh), pt(f.x + cr * 0.15, pTop + 20), pt(f.x + cr + 4, pTop + 20)]), Paint.slate.shade(0.66))
        for k in 1..<4 {
            let y = pTop - rh * CGFloat(k) / 4
            p.stroke(polyline([pt(f.x - cr, y + 10), pt(f.x, y + 14), pt(f.x + cr, y + 10)]), Paint.slate.shade(0.6), width: 1.2, alpha: 0.3)
        }
    }
    p.outline(cone, width: 2.5)
}

/// The gate: a block over the wall with an arched way through it.
func drawGate(_ p: Painter, foot f: CGPoint) {
    let w: CGFloat = 54, h: CGFloat = 54, d = depth(16)
    let x0 = f.x - w / 2, x1 = f.x + w / 2, top = f.y - h
    let east = poly([pt(x1, f.y), pt(x1 + d.x, f.y + d.y), pt(x1 + d.x, top + d.y), pt(x1, top)])
    p.fill(east, Paint.stone.shade())
    p.outline(east, width: 2.5)
    let front = CGPath(rect: CGRect(x: x0, y: top, width: w, height: h), transform: nil)
    p.linear(front, [(0, Paint.stone.lit(1.1)), (1, Paint.stone.scaled(0.95))], from: pt(x0, top), to: pt(x1, f.y))
    p.clipped(front) {
        for k in 1..<4 { p.stroke(polyline([pt(x0, f.y - CGFloat(k) * 14), pt(x1, f.y - CGFloat(k) * 14)]), Paint.stone.shade(0.6), width: 1.5, alpha: 0.28) }
    }
    let arch = CGMutablePath()
    arch.move(to: pt(f.x - 11, f.y))
    arch.addLine(to: pt(f.x - 11, f.y - 20))
    arch.addArc(center: pt(f.x, f.y - 20), radius: 11, startAngle: .pi, endAngle: 0, clockwise: false)
    arch.addLine(to: pt(f.x + 11, f.y))
    arch.closeSubpath()
    p.fill(arch, Paint.dark)
    p.outline(front, width: 2.5)
    for k in 0..<4 {
        let x = x0 + 3 + CGFloat(k) * 15
        let m = CGPath(rect: CGRect(x: x, y: top - 10, width: 9, height: 10), transform: nil)
        p.fill(m, Paint.stone.lit(1.06))
        p.outline(m, width: 1.5, alpha: 0.35)
    }
}

func drawCity(_ p: Painter) {
    drawWall(p, front: false)
    for t in [1.22 * CGFloat.pi, 1.78 * CGFloat.pi] { drawRoundTower(p, foot: City.ring(t), radius: 17, height: 66, roof: 42) }
    typealias House = (du: CGFloat, dv: CGFloat, w: CGFloat, dp: CGFloat, h: CGFloat, rh: CGFloat, across: Bool)
    let houses: [House] = [
        (-72, -62, 54, 38, 30, 24, true), (72, -68, 56, 40, 32, 28, false),
        (-100, 2, 48, 36, 30, 24, false), (90, 0, 62, 40, 34, 26, true),
        (-42, 52, 58, 40, 32, 26, true), (52, 56, 52, 36, 30, 26, false),
    ]
    var placed = houses.map { (foot: City.at($0.du, $0.dv), house: $0) }
    placed.sort { $0.foot.y < $1.foot.y }
    let keepFoot = City.at(0, -34)
    var keepDrawn = false
    for (foot, house) in placed {
        if !keepDrawn, foot.y > keepFoot.y { drawKeep(p, foot: keepFoot); keepDrawn = true }
        drawHouse(p, foot: foot, width: house.w, depth: house.dp, height: house.h, roof: house.rh, ridgeAcross: house.across)
    }
    if !keepDrawn { drawKeep(p, foot: keepFoot) }
    drawWall(p, front: true)
    drawGate(p, foot: City.ring(0.56 * .pi) + pt(0, 3))
    for t in [0.1 * CGFloat.pi, 0.9 * CGFloat.pi] { drawRoundTower(p, foot: City.ring(t) + pt(0, 2)) }
}

// MARK: - The icon

/// The tile with everything on it; the sea behind it when `sea` (the default appearance).
/// The scene is drawn this much larger than its coordinates, about its middle, so the tile
/// fills the icon at home-screen sizes; the sea fills the canvas as it is.
let sceneScale: CGFloat = 1.13
let sceneMiddle = pt(512, 499)
let sceneMiddleOnCanvas = pt(512, 510)

func drawIcon(_ p: Painter, sea: Bool) {
    var rng = RNG(2026)
    if sea { drawSea(p) }
    p.ctx.saveGState()
    defer { p.ctx.restoreGState() }
    p.ctx.translateBy(x: sceneMiddleOnCanvas.x, y: sceneMiddleOnCanvas.y)
    p.ctx.scaleBy(x: sceneScale, y: sceneScale)
    p.ctx.translateBy(x: -sceneMiddle.x, y: -sceneMiddle.y)
    if sea {
        drawWaterline(p, rng: &rng)
    } else {
        p.soft(moved(Tile.silhouette, 30, 34), Paint.shadow.scaled(0.3), alpha: 0.55, blur: 30)
    }
    drawSides(p, rng: &rng)
    drawFall(p, rng: &rng)
    drawGround(p, rng: &rng)
    drawRim(p)
    drawMountain(p, rng: &rng)
    let wood: [(CGPoint, CGFloat)] = [
        (pt(236, 430), 25), (pt(288, 416), 23), (pt(330, 446), 21), (pt(220, 492), 26), (pt(268, 476), 24),
        (pt(318, 506), 25), (pt(246, 550), 25), (pt(298, 566), 23), (pt(338, 590), 19), (pt(226, 608), 21),
        (pt(744, 398), 22), (pt(786, 424), 24), (pt(752, 456), 20), (pt(706, 380), 19),
    ]
    for (foot, r) in wood.sorted(by: { $0.0.y < $1.0.y }) { drawTree(p, foot: foot, r: r, rng: &rng) }
    drawCity(p)
}

func image(_ p: Painter) -> CGImage { p.ctx.makeImage()! }

/// The same pixels without an alpha channel (App Store icons must be opaque).
func opaque(_ img: CGImage) -> CGImage {
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return ctx.makeImage()!
}

/// The tinted appearance: the icon's luminance in grey, a little lifted, keeping its alpha.
func luminance(_ img: CGImage) -> CGImage {
    let w = img.width, h = img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    for i in 0..<(w * h) {
        let a = Double(px[4 * i + 3]) / 255
        guard a > 0 else { continue }
        let r = Double(px[4 * i]) / 255 / a, g = Double(px[4 * i + 1]) / 255 / a, b = Double(px[4 * i + 2]) / 255 / a
        let l = min(1, pow(0.2126 * r + 0.7152 * g + 0.0722 * b, 0.8) * 1.08)
        let v = UInt8(max(0, min(255, (l * a * 255).rounded())))
        px[4 * i] = v; px[4 * i + 1] = v; px[4 * i + 2] = v
    }
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

/// A sheet of the icon at home-screen sizes, masked to iOS's rounded square: the default
/// appearance on a light wallpaper, the dark one over a dark backdrop, the tinted one in amber.
func previewSheet(light: CGImage, dark: CGImage, tinted: CGImage) -> CGImage {
    let sizes: [CGFloat] = [180, 152, 120, 87, 80, 58]
    let gap: CGFloat = 28, rowH: CGFloat = 230
    let width = Int(gap + sizes.reduce(0, +) + gap * CGFloat(sizes.count)), height = Int(rowH * 3)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let rows: [(CGImage, Tone, Tone, Bool)] = [
        (light, Tone(0.55, 0.66, 0.82), Tone(0.86, 0.72, 0.62), false),
        (dark, Tone(0.10, 0.10, 0.13), Tone(0.02, 0.02, 0.03), false),
        (tinted, Tone(0.10, 0.09, 0.07), Tone(0.02, 0.02, 0.02), true),
    ]
    for (row, (img, top, bottom, tint)) in rows.enumerated() {
        let y0 = CGFloat(height) - CGFloat(row + 1) * rowH
        let band = CGRect(x: 0, y: y0, width: CGFloat(width), height: rowH)
        ctx.saveGState()
        ctx.clip(to: band)
        ctx.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: [top.cg(), bottom.cg()] as CFArray, locations: [0, 1])!,
                               start: pt(0, band.maxY), end: pt(0, band.minY), options: [])
        ctx.restoreGState()
        var x = gap
        for s in sizes {
            let r = CGRect(x: x, y: y0 + (rowH - s) / 2, width: s, height: s)
            ctx.saveGState()
            ctx.addPath(squircle(r))
            ctx.clip()
            if row > 0 {
                // The system's backdrop for the dark and tinted appearances.
                ctx.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: [Tone(0.20, 0.20, 0.22).cg(), Tone(0.07, 0.07, 0.08).cg()] as CFArray,
                                                  locations: [0, 1])!, start: pt(0, r.maxY), end: pt(0, r.minY), options: [])
            }
            ctx.draw(img, in: r)
            if tint {
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(Tone(1.0, 0.72, 0.30).cg())
                ctx.fill(r)
            }
            ctx.restoreGState()
            x += s + gap
        }
    }
    return ctx.makeImage()!
}

/// iOS's icon shape, near enough: a superellipse.
func squircle(_ r: CGRect) -> CGPath {
    let n: CGFloat = 5, steps = 240
    let pts = (0..<steps).map { k -> CGPoint in
        let t = CGFloat(k) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = (c < 0 ? -1 : 1) * pow(abs(c), 2 / n), y = (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        return pt(r.midX + x * r.width / 2, r.midY + y * r.height / 2)
    }
    return poly(pts)
}

// MARK: - Main

let args = CommandLine.arguments.dropFirst()
guard let outPath = args.first else {
    print("usage: make-app-icon.swift <AppIcon.appiconset> [--preview <dir>]")
    exit(2)
}
let out = URL(fileURLWithPath: outPath, isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let lightPainter = Painter()
drawIcon(lightPainter, sea: true)
let light = opaque(image(lightPainter))
let darkPainter = Painter()
drawIcon(darkPainter, sea: false)
let dark = image(darkPainter)
let tinted = luminance(dark)

writePNG(light, out.appendingPathComponent("AppIcon.png"))
writePNG(dark, out.appendingPathComponent("AppIcon-Dark.png"))
writePNG(tinted, out.appendingPathComponent("AppIcon-Tinted.png"))
let contents = """
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIcon-Dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "AppIcon-Tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
// The catalog's own Contents.json, as Xcode writes it (so opening the catalog in Xcode adds none).
let catalog = out.deletingLastPathComponent()
if catalog.pathExtension == "xcassets", !FileManager.default.fileExists(atPath: catalog.appendingPathComponent("Contents.json").path) {
    try "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"
        .write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
print("wrote \(out.path)")

if let i = args.firstIndex(of: "--preview"), args.index(after: i) < args.endIndex {
    let dir = URL(fileURLWithPath: args[args.index(after: i)], isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    writePNG(previewSheet(light: light, dark: dark, tinted: tinted), dir.appendingPathComponent("icon-preview.png"))
    print("wrote \(dir.appendingPathComponent("icon-preview.png").path)")
}
