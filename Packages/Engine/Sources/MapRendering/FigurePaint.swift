import CoreGraphics
import CoreText
import Foundation
import GameCore

/// The painting toolkit unit and settlement art share (ART.md §1-3): figures recorded as paint
/// steps in cell fractions (`Figure`), materials with the one-sided light model (`Tone`,
/// `Material`), and the canvas that paints the steps with a soft outer outline, west-lit volume,
/// brushwork, a cool terminator and a warm rim light (`Canvas`). A namespace, so its type names
/// never meet the decoration painter's own file-private ones.
enum FigurePaint {
    // MARK: - Recording

    /// A color with the light model of ART.md §1: lit faces brighter and warmer, shadow faces
    /// darker and cooler.
    struct Tone {
        var r, g, b: CGFloat
        init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { self.r = r; self.g = g; self.b = b }

        func cg(_ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1), alpha: a)
        }
        func scaled(_ k: CGFloat) -> Tone { Tone(r * k, g * k, b * k) }
        var lit: Tone { Tone(r * 1.1 + 0.07, g * 1.08 + 0.055, b * 1.02 + 0.025) }
        var shadow: Tone { Tone(r * 0.55 + 0.02, g * 0.56 + 0.025, b * 0.66 + 0.07) }
        /// More (k > 1) or less chroma at the same luminance.
        func chroma(_ k: CGFloat) -> Tone {
            let y = 0.3 * r + 0.59 * g + 0.11 * b
            return Tone(y + (r - y) * k, y + (g - y) * k, y + (b - y) * k)
        }
    }

    /// A fixed color or the player's color (scaled), resolved when painting.
    enum Ink {
        case tone(Tone)
        case team(CGFloat)

        /// Shared bodies paint team parts in this grey; the unit shader multiplies the owner's
        /// color in at twice its value, so the grey's own light and shade carry over.
        static let teamGrey: CGFloat = 0.5

        var isTeam: Bool { if case .team = self { return true } else { return false } }

        func resolve(_ style: PlayerStyle?) -> Tone {
            switch self {
            case let .tone(t): return t
            case let .team(k):
                return style.map { Tone($0.r * k, $0.g * k, $0.b * k) } ?? Tone(Self.teamGrey * k, Self.teamGrey * k, Self.teamGrey * k)
            }
        }
    }

    /// Surface texture: painterly strokes that suggest the material at close zoom.
    enum Grain { case none, cloth, wood, planks, hide, metal }

    struct Material {
        var ink: Ink
        var shade: CGFloat = 1
        var light: CGFloat = 1
        var grain: Grain = .none
        var gloss: CGFloat = 0

        init(_ tone: Tone, shade: CGFloat = 1, light: CGFloat = 1, grain: Grain = .none, gloss: CGFloat = 0) {
            self.init(ink: .tone(tone), shade: shade, light: light, grain: grain, gloss: gloss)
        }

        /// The player's color, scaled by `team`.
        init(team: CGFloat, shade: CGFloat = 1, light: CGFloat = 1, grain: Grain = .none, gloss: CGFloat = 0) {
            self.init(ink: .team(team), shade: shade, light: light, grain: grain, gloss: gloss)
        }

        private init(ink: Ink, shade: CGFloat, light: CGFloat, grain: Grain, gloss: CGFloat) {
            self.ink = ink
            self.shade = shade
            self.light = light
            self.grain = grain
            self.gloss = gloss
        }
    }

    enum Step {
        case part(CGPath, Material, outline: CGFloat, seed: UInt64)
        case decal(CGPath, Ink, alpha: CGFloat, clip: CGPath?)
        case stroke(CGPath, Ink, width: CGFloat, offset: (CGFloat, CGFloat), clip: CGPath?)
        case emblem(center: CGPoint, size: CGFloat, clip: CGPath?)
        case glyph([CGPath], halo: CGFloat)

        /// Whether the step is team paint (tinted per player).
        var isTeam: Bool {
            switch self {
            case let .part(_, m, _, _): m.ink.isTeam
            case let .decal(_, ink, _, _), let .stroke(_, ink, _, _, _): ink.isTeam
            case .emblem, .glyph: true
            }
        }
    }

    /// Records a figure as paint steps, in fractions of a canonical cell (x right, y up) whose
    /// origin is zero; `Canvas` paints the steps into any cell. A mirrored figure flips every
    /// shape left to right as it is recorded, so the same drawing code paints both facings and
    /// the canvas still lights them from the upper left.
    struct Figure {
        typealias P = (CGFloat, CGFloat)

        let size: CGFloat
        let mirrored: Bool
        /// Uniform scale about `pivot` (cell fractions) applied to everything recorded, so a figure
        /// drawn a little large still fits inside the cell's 1/20 margin (`UnitSprite.bodyFit`).
        let fit: CGFloat
        let pivot: P
        private(set) var steps: [Step] = []
        /// Emblem spots for bodies (x, y, cell width and height, as fractions of the cell; already
        /// mirrored).
        private(set) var emblems: [SIMD4<Float>] = []

        init(size: CGFloat, mirrored: Bool = false, fit: CGFloat = 1, pivot: P = (0.5, CGFloat(UnitSprite.groundLine))) {
            self.size = size
            self.mirrored = mirrored
            self.fit = fit
            self.pivot = pivot
        }

        /// Where a point given in cell fractions is recorded: fitted, then mirrored.
        private func place(_ p: P) -> P {
            let x = pivot.0 + (p.0 - pivot.0) * fit, y = pivot.1 + (p.1 - pivot.1) * fit
            return (mirrored ? 1 - x : x, y)
        }

        func pt(_ p: P) -> CGPoint { CGPoint(x: p.0 * size, y: p.1 * size) }

        private func flip(_ path: CGPath) -> CGPath {
            guard mirrored || fit != 1 else { return path }
            let px = pivot.0 * size, py = pivot.1 * size
            var t = CGAffineTransform(a: fit, b: 0, c: 0, d: fit, tx: px * (1 - fit), ty: py * (1 - fit))
            if mirrored { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size, ty: 0)) }
            return path.copy(using: &t) ?? path
        }

        func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: (cx - rx) * size, y: (cy - ry) * size, width: 2 * rx * size, height: 2 * ry * size), transform: nil)
        }

        func rectPath(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
            CGPath(rect: CGRect(x: x * size, y: y * size, width: w * size, height: h * size), transform: nil)
        }

        func poly(_ pts: [P]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: pts.map(pt))
            path.closeSubpath()
            return path
        }

        /// Smooth closed curve through the points (Catmull–Rom).
        func blob(_ pts: [P]) -> CGPath {
            let n = pts.count
            let path = CGMutablePath()
            path.move(to: pt(pts[0]))
            for i in 0..<n {
                let p0 = pts[(i + n - 1) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
                path.addCurve(to: pt(p2), control1: pt((p1.0 + (p2.0 - p0.0) / 6, p1.1 + (p2.1 - p0.1) / 6)),
                              control2: pt((p2.0 - (p3.0 - p1.0) / 6, p2.1 - (p3.1 - p1.1) / 6)))
            }
            path.closeSubpath()
            return path
        }

        /// A tapered stroke along a smooth curve through the points, with round ends: legs, arms,
        /// tails, shafts. Widths are in cell fractions.
        func limb(_ pts: [P], _ w0: CGFloat, _ w1: CGFloat) -> CGPath {
            let ext = [pts[0]] + pts + [pts[pts.count - 1]]
            var samples: [P] = []
            let per = 6
            for i in 1..<(ext.count - 2) {
                let p0 = ext[i - 1], p1 = ext[i], p2 = ext[i + 1], p3 = ext[i + 2]
                for s in 0..<per {
                    let t = CGFloat(s) / CGFloat(per), t2 = t * t, t3 = t2 * t
                    func cr(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                        0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                    }
                    samples.append((cr(p0.0, p1.0, p2.0, p3.0), cr(p0.1, p1.1, p2.1, p3.1)))
                }
            }
            samples.append(pts[pts.count - 1])
            var left: [CGPoint] = [], right: [CGPoint] = []
            for (j, s) in samples.enumerated() {
                let a = samples[max(j - 1, 0)], b = samples[min(j + 1, samples.count - 1)]
                let len = max(hypot(b.0 - a.0, b.1 - a.1), 1e-6)
                let nx = -(b.1 - a.1) / len, ny = (b.0 - a.0) / len
                let w = (w0 + (w1 - w0) * CGFloat(j) / CGFloat(samples.count - 1)) / 2
                left.append(pt((s.0 + nx * w, s.1 + ny * w)))
                right.append(pt((s.0 - nx * w, s.1 - ny * w)))
            }
            let path = CGMutablePath()
            path.addLines(between: left)
            let end = pt(samples[samples.count - 1]), start = pt(samples[0])
            path.addArc(center: end, radius: w1 / 2 * size, startAngle: atan2(left.last!.y - end.y, left.last!.x - end.x),
                        endAngle: atan2(right.last!.y - end.y, right.last!.x - end.x), clockwise: true)
            path.addLines(between: right.reversed())
            path.addArc(center: start, radius: w0 / 2 * size, startAngle: atan2(right[0].y - start.y, right[0].x - start.x),
                        endAngle: atan2(left[0].y - start.y, left[0].x - start.x), clockwise: true)
            path.closeSubpath()
            return path
        }

        /// Heater shield: straight top with rounded corners, curving to a point.
        func shieldPath(cx: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
            let path = CGMutablePath()
            let l = cx - width / 2, r = cx + width / 2, bottom = top - height, c = width * 0.12
            path.move(to: pt((cx, top)))
            path.addLine(to: pt((r - c, top)))
            path.addQuadCurve(to: pt((r, top - c)), control: pt((r, top)))
            path.addLine(to: pt((r, top - height * 0.42)))
            path.addCurve(to: pt((cx, bottom)), control1: pt((r, top - height * 0.78)), control2: pt((cx + width * 0.2, bottom + height * 0.06)))
            path.addCurve(to: pt((l, top - height * 0.42)), control1: pt((cx - width * 0.2, bottom + height * 0.06)), control2: pt((l, top - height * 0.78)))
            path.addLine(to: pt((l, top - c)))
            path.addQuadCurve(to: pt((l + c, top)), control: pt((l, top)))
            path.closeSubpath()
            return path
        }

        /// Kite: a lozenge with softly bowed sides, its widest point above the middle.
        func kitePath(cx: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
            let path = CGMutablePath()
            let mid = top - height * 0.42, bottom = top - height, h = width / 2
            path.move(to: pt((cx, top)))
            path.addQuadCurve(to: pt((cx + h, mid)), control: pt((cx + h * 0.82, top - height * 0.08)))
            path.addQuadCurve(to: pt((cx, bottom)), control: pt((cx + h * 0.78, bottom + height * 0.16)))
            path.addQuadCurve(to: pt((cx - h, mid)), control: pt((cx - h * 0.78, bottom + height * 0.16)))
            path.addQuadCurve(to: pt((cx, top)), control: pt((cx - h * 0.82, top - height * 0.08)))
            path.closeSubpath()
            return path
        }

        /// A painted part; `outline` is the silhouette edge width in cell fractions (0 = none).
        mutating func add(_ path: CGPath, _ material: Material, outline: CGFloat = 0.021) {
            steps.append(.part(flip(path), material, outline: outline, seed: UInt64(steps.count) &* 0x9E37_79B9 &+ 17))
        }

        /// A flat translucent mark (seams, straps, folds), optionally confined to a shape.
        mutating func decal(_ path: CGPath, _ tone: Tone, alpha: CGFloat, clip: CGPath? = nil) {
            steps.append(.decal(flip(path), .tone(tone), alpha: alpha, clip: clip.map(flip)))
        }

        mutating func decal(_ path: CGPath, teamShade: CGFloat, alpha: CGFloat, clip: CGPath? = nil) {
            steps.append(.decal(flip(path), .team(teamShade), alpha: alpha, clip: clip.map(flip)))
        }

        mutating func decalStroke(_ path: CGPath, _ tone: Tone, width: CGFloat, offset: P = (0, 0), clip: CGPath? = nil) {
            // The offset nudges a highlight toward the light, which stays at the upper left.
            steps.append(.stroke(flip(path), .tone(tone), width: width, offset: offset, clip: clip.map(flip)))
        }

        mutating func decalStroke(_ path: CGPath, teamShade: CGFloat, width: CGFloat, clip: CGPath? = nil) {
            steps.append(.stroke(flip(path), .team(teamShade), width: width, offset: (0, 0), clip: clip.map(flip)))
        }

        /// The player's emblem: painted in per-player sprites, exported as a spot by shared bodies
        /// (`size` is the emblem's own extent; the exported cell leaves room for its halo, and
        /// `aspect` narrows it on a shield seen at an angle).
        mutating func emblem(center: P, size s: CGFloat, aspect: CGFloat = 1, clip: CGPath? = nil) {
            let c = place(center), s = s * fit
            emblems.append([Float(c.0), Float(c.1), Float(s / 0.8 * aspect), Float(s / 0.8)])
            steps.append(.emblem(center: pt(c), size: s * size, clip: clip.map(flip)))
        }

        /// The unit type as a bold dark silhouette (medallion badges).
        mutating func glyph(_ type: UnitType, center: P, size s: CGFloat) {
            let h = s * size / 2, c = pt(center)
            func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * h, y: c.y + y * h) }
            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect { CGRect(x: c.x + (x - r) * h, y: c.y + (y - r) * h, width: 2 * r * h, height: 2 * r * h) }
            /// A thick polyline with round ends, as a filled shape.
            func line(_ points: [CGPoint], width: CGFloat) -> CGPath {
                let path = CGMutablePath()
                path.addLines(between: points)
                return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
            }
            var shapes: [CGPath] = []
            switch type {
            case .settler:
                // Covered wagon: hood, bed, two wheels.
                let hood = CGMutablePath()
                hood.move(to: q(-0.86, -0.12))
                hood.addCurve(to: q(0.86, -0.12), control1: q(-0.9, 1.0), control2: q(0.9, 1.0))
                hood.closeSubpath()
                shapes.append(hood)
                shapes.append(CGPath(rect: CGRect(x: q(-0.98, 0).x, y: q(0, -0.42).y, width: 1.96 * h, height: 0.3 * h), transform: nil))
                for x in [-0.5, 0.52] as [CGFloat] { shapes.append(CGPath(ellipseIn: circle(x, -0.66, 0.3), transform: nil)) }
            case .builder:
                // A pick and a shovel crossed: the pick's curved head across the top right, the
                // shovel's grip at the top left and its blade at the bottom right.
                shapes.append(line([q(-0.78, -0.88), q(0.5, 0.52)], width: 0.17 * h))
                let head = CGMutablePath()
                head.move(to: q(-0.04, 0.96))
                head.addQuadCurve(to: q(0.96, -0.04), control: q(0.82, 0.82))
                head.addQuadCurve(to: q(-0.04, 0.96), control: q(0.6, 0.6))
                head.closeSubpath()
                shapes.append(head)
                shapes.append(line([q(-0.56, 0.6), q(0.36, -0.3)], width: 0.15 * h))
                shapes.append(line([q(-0.74, 0.5), q(-0.44, 0.8)], width: 0.15 * h))
                let blade = CGMutablePath()
                blade.move(to: q(0.18, -0.26))
                blade.addLine(to: q(0.48, -0.56))
                blade.addQuadCurve(to: q(0.98, -0.98), control: q(1.0, -0.62))
                blade.addQuadCurve(to: q(0.18, -0.26), control: q(0.48, -0.94))
                blade.closeSubpath()
                shapes.append(blade)
            case .warrior:
                // A broad sword, point up: blade, crossguard, grip and pommel, a silhouette no other
                // type shares and that stays clear at the smallest medallion.
                let blade = CGMutablePath()
                blade.addLines(between: [q(-0.17, -0.2), q(-0.15, 0.62), q(0, 1.0), q(0.15, 0.62), q(0.17, -0.2)])
                blade.closeSubpath()
                shapes.append(blade)
                shapes.append(CGPath(roundedRect: CGRect(x: q(-0.58, 0).x, y: q(0, -0.4).y, width: 1.16 * h, height: 0.2 * h),
                                     cornerWidth: 0.1 * h, cornerHeight: 0.1 * h, transform: nil))
                shapes.append(CGPath(rect: CGRect(x: q(-0.09, 0).x, y: q(0, -0.78).y, width: 0.18 * h, height: 0.42 * h), transform: nil))
                shapes.append(CGPath(ellipseIn: circle(0, -0.86, 0.15), transform: nil))
            case .archer:
                // A bow drawn on an arrow, which points west as the figures face.
                let bow = CGMutablePath()
                bow.move(to: q(0.16, 0.95))
                bow.addCurve(to: q(0.16, -0.95), control1: q(-0.62, 0.72), control2: q(-0.62, -0.72))
                shapes.append(bow.copy(strokingWithWidth: 0.2 * h, lineCap: .round, lineJoin: .round, miterLimit: 4))
                shapes.append(line([q(0.16, 0.95), q(0.6, 0), q(0.16, -0.95)], width: 0.07 * h))
                shapes.append(line([q(0.7, 0), q(-0.66, 0)], width: 0.1 * h))
                let head = CGMutablePath()
                head.addLines(between: [q(-0.98, 0), q(-0.62, 0.22), q(-0.68, 0), q(-0.62, -0.22)])
                head.closeSubpath()
                shapes.append(head)
                for side in [1, -1] as [CGFloat] {
                    let fletch = CGMutablePath()
                    fletch.addLines(between: [q(0.52, 0), q(0.7, 0.2 * side), q(0.98, 0.2 * side), q(0.84, 0)])
                    fletch.closeSubpath()
                    shapes.append(fletch)
                }
            case .spearman:
                // A spear slanting behind a round shield seen face on: a broad rim and a boss
                // (hollow, so it never reads as a ball).
                let shield = CGPath(ellipseIn: circle(-0.2, -0.2, 0.64), transform: nil)
                shapes.append(line([q(-0.86, -0.98), q(0.5, 0.5)], width: 0.13 * h).subtracting(shield))
                let head = CGMutablePath()
                head.move(to: q(0.36, 0.5))
                head.addQuadCurve(to: q(0.98, 0.98), control: q(0.66, 0.92))
                head.addQuadCurve(to: q(0.5, 0.36), control: q(0.92, 0.66))
                head.closeSubpath()
                shapes.append(head)
                shapes.append(CGPath(ellipseIn: circle(-0.2, -0.2, 0.52), transform: nil)
                    .copy(strokingWithWidth: 0.24 * h, lineCap: .butt, lineJoin: .round, miterLimit: 4))
                shapes.append(CGPath(ellipseIn: circle(-0.2, -0.2, 0.17), transform: nil))
            case .scout:
                // Horse head with an ear and a notched mane.
                let head = CGMutablePath()
                head.move(to: q(0.62, -0.98))
                head.addCurve(to: q(0.2, 0.74), control1: q(0.74, -0.2), control2: q(0.6, 0.5))
                head.addLine(to: q(0.26, 1.0))
                head.addLine(to: q(0.02, 0.8))
                head.addCurve(to: q(-0.86, -0.04), control1: q(-0.38, 0.62), control2: q(-0.66, 0.3))
                head.addCurve(to: q(-0.64, -0.3), control1: q(-0.98, -0.2), control2: q(-0.8, -0.32))
                head.addCurve(to: q(-0.1, 0.0), control1: q(-0.44, -0.22), control2: q(-0.26, -0.08))
                head.addCurve(to: q(-0.34, -0.98), control1: q(-0.08, -0.38), control2: q(-0.3, -0.62))
                head.closeSubpath()
                shapes.append(head)
            case .horseman:
                // A lance with its pennon, slanting up to the west.
                shapes.append(line([q(0.9, -0.9), q(-0.6, 0.6)], width: 0.13 * h))
                let tip = CGMutablePath()
                tip.addLines(between: [q(-0.98, 0.98), q(-0.5, 0.74), q(-0.74, 0.5)])
                tip.closeSubpath()
                shapes.append(tip)
                let pennon = CGMutablePath()
                pennon.addLines(between: [q(-0.4, 0.4), q(0.3, 0.62), q(0.0, 0.36), q(0.22, 0.12), q(-0.2, 0.2)])
                pennon.closeSubpath()
                shapes.append(pennon)
            case .heavyChariot:
                // A spoked wheel.
                shapes.append(CGPath(ellipseIn: circle(0, 0, 0.8), transform: nil)
                    .copy(strokingWithWidth: 0.22 * h, lineCap: .butt, lineJoin: .round, miterLimit: 4))
                for i in 0..<4 {
                    let a = CGFloat(i) * .pi / 4
                    shapes.append(line([q(cos(a) * 0.8, sin(a) * 0.8), q(-cos(a) * 0.8, -sin(a) * 0.8)], width: 0.12 * h))
                }
                shapes.append(CGPath(ellipseIn: circle(0, 0, 0.22), transform: nil))
            case .swordsman:
                // Two swords crossed, points up.
                for side in [1, -1] as [CGFloat] {
                    shapes.append(line([q(-0.8 * side, -0.8), q(0.72 * side, 0.9)], width: 0.16 * h))
                    shapes.append(line([q(-0.66 * side - 0.26, -0.44), q(-0.66 * side + 0.26, -0.72)], width: 0.12 * h))
                }
            case .manAtArms:
                // A long axe: a haft and a broad crescent blade.
                shapes.append(line([q(0.5, -0.98), q(-0.2, 0.9)], width: 0.14 * h))
                let blade = CGMutablePath()
                blade.move(to: q(-0.14, 0.86))
                blade.addQuadCurve(to: q(-0.4, 0.0), control: q(-0.98, 0.6))
                blade.addQuadCurve(to: q(-0.14, 0.86), control: q(-0.4, 0.5))
                blade.closeSubpath()
                shapes.append(blade)
            case .crossbowman:
                // A crossbow seen from above: the bow across, the stock along it, the bolt.
                let bow = CGMutablePath()
                bow.move(to: q(-0.95, 0.1))
                bow.addQuadCurve(to: q(0.95, 0.1), control: q(0, 0.95))
                shapes.append(bow.copy(strokingWithWidth: 0.18 * h, lineCap: .round, lineJoin: .round, miterLimit: 4))
                shapes.append(line([q(-0.95, 0.1), q(0.95, 0.1)], width: 0.06 * h))
                shapes.append(line([q(0, 0.9), q(0, -0.95)], width: 0.2 * h))
            case .pikeman:
                // Three pikes upright, heads up.
                for x in [-0.55, 0, 0.55] as [CGFloat] {
                    shapes.append(line([q(x, -0.95), q(x, 0.5)], width: 0.12 * h))
                    let head = CGMutablePath()
                    head.addLines(between: [q(x, 0.98), q(x + 0.16, 0.5), q(x - 0.16, 0.5)])
                    head.closeSubpath()
                    shapes.append(head)
                }
            case .knight:
                // A great helm: a flat-topped bucket with a visor slit and breaths.
                let helm = CGMutablePath()
                helm.addRoundedRect(in: CGRect(x: q(-0.66, 0).x, y: q(0, -0.9).y, width: 1.32 * h, height: 1.7 * h),
                                    cornerWidth: 0.3 * h, cornerHeight: 0.3 * h)
                let slit = CGPath(rect: CGRect(x: q(-0.66, 0).x, y: q(0, 0.12).y, width: 1.32 * h, height: 0.16 * h), transform: nil)
                shapes.append(helm.subtracting(slit))
            case .catapult:
                // A throwing arm on a frame, its bucket loaded.
                shapes.append(CGPath(rect: CGRect(x: q(-0.95, 0).x, y: q(0, -0.8).y, width: 1.9 * h, height: 0.24 * h), transform: nil))
                shapes.append(line([q(0.8, -0.6), q(-0.5, 0.6)], width: 0.14 * h))
                shapes.append(line([q(0.1, -0.6), q(0.1, 0.1)], width: 0.14 * h))
                shapes.append(CGPath(ellipseIn: circle(-0.62, 0.72, 0.26), transform: nil))
            case .trebuchet:
                // An A-frame, the long arm across it and the counterweight.
                shapes.append(line([q(-0.7, -0.95), q(0, 0.4), q(0.7, -0.95)], width: 0.14 * h))
                shapes.append(line([q(-0.9, 0.9), q(0.6, 0.05)], width: 0.12 * h))
                shapes.append(CGPath(rect: CGRect(x: q(0.4, 0).x, y: q(0, -0.45).y, width: 0.5 * h, height: 0.5 * h), transform: nil))
            case .trader:
                // A tied sack of goods with a coin beside it.
                let sack = CGMutablePath()
                sack.move(to: q(-0.28, 0.42))
                sack.addCurve(to: q(-0.3, -0.9), control1: q(-1.0, 0.2), control2: q(-1.05, -0.9))
                sack.addLine(to: q(0.3, -0.9))
                sack.addCurve(to: q(0.28, 0.42), control1: q(1.05, -0.9), control2: q(1.0, 0.2))
                sack.closeSubpath()
                shapes.append(sack)
                shapes.append(line([q(-0.3, 0.55), q(0.3, 0.55)], width: 0.16 * h))
                shapes.append(line([q(-0.32, 0.9), q(0, 0.6), q(0.32, 0.9)], width: 0.14 * h))
                shapes.append(CGPath(ellipseIn: circle(0.68, 0.58, 0.28), transform: nil))
            case .galley, .quadrireme, .cog, .dromon:
                // A hull under a mast and sail: one sail (galley, cog) or two (quadrireme, dromon);
                // the war galleys carry a ram.
                let hull = CGMutablePath()
                hull.move(to: q(-0.95, -0.35))
                hull.addLine(to: q(0.95, -0.35))
                hull.addQuadCurve(to: q(-0.95, -0.35), control: q(0, -1.15))
                hull.closeSubpath()
                shapes.append(hull)
                let masts: [CGFloat] = type == .quadrireme || type == .dromon ? [-0.35, 0.35] : [0]
                for x in masts {
                    shapes.append(line([q(x, -0.4), q(x, 0.95)], width: 0.1 * h))
                    shapes.append(CGPath(rect: CGRect(x: q(x - 0.3, 0).x, y: q(0, -0.1).y, width: 0.6 * h, height: 0.85 * h), transform: nil))
                }
                if type != .cog { shapes.append(line([q(-0.95, -0.55), q(-1.15, -0.62)], width: 0.12 * h)) }
            }
            steps.append(.glyph(shapes.map(flip), halo: h * 0.14))
        }

        /// Pictogram shapes (pixels of the cell, y up) in ink over a faint cream halo, as a unit
        /// type's are painted (`glyph(_:center:size:)`).
        mutating func glyph(shapes: [CGPath], halo: CGFloat) {
            steps.append(.glyph(shapes.map(flip), halo: halo))
        }

        /// Spoked wheel: iron tire, wooden felloe, eight spokes and a hub.
        mutating func wheel(_ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat) {
            let hole = ellipse(cx, cy, rad * 0.76, rad * 0.76)
            add(ellipse(cx, cy, rad, rad).subtracting(hole), Material(Tone(0.4, 0.4, 0.44), grain: .metal, gloss: 0.3))
            add(ellipse(cx, cy, rad * 0.85, rad * 0.85).subtracting(hole), Material(Tone(0.52, 0.36, 0.21), grain: .wood), outline: 0)
            decal(hole, Tone(0.16, 0.12, 0.1), alpha: 0.32)
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4 + 0.2
                add(limb([(cx + cos(a) * rad * 0.16, cy + sin(a) * rad * 0.16), (cx + cos(a) * rad * 0.8, cy + sin(a) * rad * 0.8)], rad * 0.13, rad * 0.1),
                    Material(Tone(0.58, 0.41, 0.24), shade: 0.5), outline: 0)
            }
            add(ellipse(cx, cy, rad * 0.22, rad * 0.22), Material(Tone(0.36, 0.25, 0.16), gloss: 0.3), outline: 0.008)
            add(ellipse(cx, cy, rad * 0.09, rad * 0.09), Material(Tone(0.5, 0.52, 0.56), gloss: 0.6), outline: 0)
        }
    }

    // MARK: - Painting

    /// What a canvas paints of a figure.
    enum Pass {
        /// Finished art for one player (standards, medallions): team inks take the player's color.
        case player(PlayerStyle)
        /// A shared body: team inks are a neutral grey the unit shader tints; emblems are skipped
        /// (they are their own instances).
        case body
        /// How much of each pixel is team paint, as alpha: team steps add coverage and every other
        /// step covers what lies beneath it.
        case teamMask
    }

    /// Paints recorded steps into a cell of a context.
    ///
    /// Two passes: every outlined part is stroked into one layer composited at 45%, so only the
    /// outer silhouette shows a soft dark edge (ART.md §3); then parts are filled back to front,
    /// each with west-lit volume, brush dabs and strokes, a cool terminator on its east and south
    /// side, a warm rim light on its west and north edge and a light interior line that keeps
    /// overlapping parts apart.
    struct Canvas {
        let ctx: CGContext
        let origin: CGPoint
        let size: CGFloat

        private static let inkTone = Tone(0.1, 0.07, 0.05)
        private static let coolShadow = Tone(0.16, 0.12, 0.32)
        private static let warmLight = Tone(1.0, 0.93, 0.76)
        /// The sunlit face's wash: golden rather than cream, so it lifts value without greying
        /// the materials (units stay more saturated than the ground, ART.md §2).
        private static let sunWash = Tone(1.0, 0.8, 0.46)
        private static let vivid: CGFloat = 1.3
        private static let space = CGColorSpace(name: CGColorSpace.sRGB)

        func paint(_ steps: [Step], pass: Pass) {
            switch pass {
            case .teamMask:
                for step in steps { mask(step) }
            case let .player(style):
                outline(steps)
                for step in steps { paint(step, style: style) }
            case .body:
                outline(steps)
                for step in steps { paint(step, style: nil) }
            }
        }

        /// The figure's painted silhouette in opaque white: parts with their outlines, decals and
        /// strokes (emblems and glyphs lie inside parts). The cream rim starts where it ends.
        func silhouette(_ steps: [Step]) {
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            let white = CGColor(gray: 1, alpha: 1)
            ctx.setFillColor(white)
            ctx.setStrokeColor(white)
            for step in steps {
                ctx.saveGState()
                switch step {
                case let .part(path, _, outline, _):
                    ctx.addPath(path)
                    ctx.fillPath()
                    if outline > 0 {
                        // As `outline` strokes it.
                        ctx.setLineJoin(.round)
                        ctx.setLineCap(.round)
                        ctx.addPath(path)
                        ctx.setLineWidth(outline * 2 * size)
                        ctx.strokePath()
                    }
                case let .decal(path, _, _, clip):
                    if let clip { ctx.addPath(clip); ctx.clip() }
                    ctx.addPath(path)
                    ctx.fillPath()
                case let .stroke(path, _, width, offset, clip):
                    if let clip { ctx.addPath(clip); ctx.clip() }
                    ctx.translateBy(x: offset.0 * size, y: offset.1 * size)
                    ctx.addPath(path)
                    ctx.setLineWidth(width * size)
                    ctx.strokePath()
                case .emblem, .glyph:
                    break
                }
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }

        private func outline(_ steps: [Step]) {
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.setAlpha(0.45)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setStrokeColor(Self.inkTone.cg())
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            for case let .part(path, _, outline, _) in steps where outline > 0 {
                ctx.addPath(path)
                ctx.setLineWidth(outline * 2 * size)
                ctx.strokePath()
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        private func paint(_ step: Step, style: PlayerStyle?) {
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            switch step {
            case let .part(path, material, _, seed):
                part(path, material, style: style, seed: seed)
            case let .decal(path, ink, alpha, clip):
                if let clip { ctx.addPath(clip); ctx.clip() }
                ctx.addPath(path)
                ctx.setFillColor(ink.resolve(style).cg(alpha))
                ctx.fillPath()
            case let .stroke(path, ink, width, offset, clip):
                if let clip { ctx.addPath(clip); ctx.clip() }
                ctx.translateBy(x: offset.0 * size, y: offset.1 * size)
                ctx.addPath(path)
                ctx.setStrokeColor(ink.resolve(style).cg())
                ctx.setLineWidth(width * size)
                ctx.strokePath()
            case let .emblem(center, s, clip):
                if let style { emblem(style, center: center, size: s, clip: clip, crisp: false) }
            case let .glyph(shapes, halo):
                glyph(shapes, halo: halo)
            }
            ctx.restoreGState()
        }

        /// Team-paint coverage: team steps add theirs, any other step covers what lies beneath.
        private func mask(_ step: Step) {
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.setBlendMode(step.isTeam ? .normal : .destinationOut)
            let white = CGColor(gray: 1, alpha: 1)
            switch step {
            case let .part(path, _, _, _):
                ctx.addPath(path)
                ctx.setFillColor(white)
                ctx.fillPath()
                if !step.isTeam {
                    // A neutral part's interior line also darkens the team paint just outside it.
                    ctx.addPath(path)
                    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.3))
                    ctx.setLineWidth(size * 0.005)
                    ctx.strokePath()
                }
            case let .decal(path, _, alpha, clip):
                if let clip { ctx.addPath(clip); ctx.clip() }
                ctx.addPath(path)
                ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
                ctx.fillPath()
            case let .stroke(path, _, width, offset, clip):
                if let clip { ctx.addPath(clip); ctx.clip() }
                ctx.translateBy(x: offset.0 * size, y: offset.1 * size)
                ctx.addPath(path)
                ctx.setStrokeColor(white)
                ctx.setLineWidth(width * size)
                ctx.strokePath()
            case .emblem, .glyph:
                break
            }
            ctx.restoreGState()
        }

        /// Fills the part of the current clip lying outside `path` moved by `shift`: a crescent
        /// along the edges facing away from the shift.
        private func fillOutside(_ path: CGPath, box: CGRect, shift: (CGFloat, CGFloat), color: CGColor) {
            var t = CGAffineTransform(translationX: shift.0, y: shift.1)
            guard let moved = path.copy(using: &t) else { return }
            let region = CGMutablePath()
            region.addRect(box.insetBy(dx: -abs(shift.0) - 2, dy: -abs(shift.1) - 2))
            region.addPath(moved)
            ctx.addPath(region)
            ctx.setFillColor(color)
            ctx.fillPath(using: .evenOdd)
        }

        private func part(_ path: CGPath, _ m: Material, style: PlayerStyle?, seed: UInt64) {
            let box = path.boundingBoxOfPath
            guard box.width > 0.5, box.height > 0.5 else { return }
            let mixed = m.ink.resolve(style)
            let extent = min(box.width, box.height)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()

            // Volume: a broad falloff from a hotspot toward the sun (upper left), whose light holds
            // across the west face, and a warm wash over that face, so the lit side of a figure
            // reads a clear step lighter than its shade (ART.md §1).
            let hot = CGPoint(x: box.minX + box.width * 0.24, y: box.maxY - box.height * 0.24)
            // Painted a little richer than mixed: lit faces and the cool shade both pull a color
            // toward grey, and the units must stay clearly more saturated than the ground (ART.md §2).
            let lit = mixed.lit.chroma(Self.vivid), shadow = mixed.shadow.chroma(Self.vivid), tone = mixed.chroma(Self.vivid)
            let mid = Tone((tone.r + shadow.r) / 2, (tone.g + shadow.g) / 2, (tone.b + shadow.b) / 2)
            if let g = CGGradient(colorsSpace: Self.space, colors: [lit.cg(), lit.cg(), tone.cg(), mid.cg()] as CFArray,
                                  locations: [0, 0.16, 0.58, 1]) {
                ctx.drawRadialGradient(g, startCenter: hot, startRadius: 0, endCenter: hot, endRadius: hypot(box.width, box.height) * 0.9,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            if m.light > 0, let wash = CGGradient(colorsSpace: Self.space, colors: [Self.sunWash.cg(0.22 * m.light), Self.sunWash.cg(0)] as CFArray,
                                                  locations: [0, 1]) {
                ctx.drawLinearGradient(wash, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.minX + box.width * 0.62, y: box.midY),
                                       options: [.drawsBeforeStartLocation])
            }

            // Painterly dabs and strokes, seeded per part so every copy is identical. Larger
            // surfaces get more of them, so brushwork reads on hoods and flanks at close zoom.
            if extent > size * 0.03 {
                var rng = SplitMix64(seed: seed)
                func rnd() -> CGFloat { CGFloat(rng.nextUnit()) }
                let area = box.width * box.height / (size * size)
                let many = Int(min(max(area * 120, 2), 9))
                for _ in 0..<many {
                    let w = box.width * (0.22 + 0.3 * rnd()), h = box.height * (0.18 + 0.3 * rnd())
                    let x = box.minX + rnd() * box.width - w / 2, y = box.minY + rnd() * box.height - h / 2
                    ctx.setFillColor((rnd() < 0.5 ? lit : shadow).cg(0.13))
                    ctx.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
                }
                ctx.setLineCap(.round)
                switch m.grain {
                case .cloth:
                    for _ in 0..<(4 + many) {
                        let x = box.minX + rnd() * box.width, y0 = box.minY + rnd() * box.height * 0.4
                        let y1 = y0 + box.height * (0.3 + 0.5 * rnd())
                        ctx.move(to: CGPoint(x: x, y: y0))
                        ctx.addQuadCurve(to: CGPoint(x: x + (rnd() - 0.5) * size * 0.02, y: y1), control: CGPoint(x: x + (rnd() - 0.5) * size * 0.03, y: (y0 + y1) / 2))
                        ctx.setStrokeColor((rnd() < 0.6 ? shadow : lit).cg(0.3))
                        ctx.setLineWidth(size * (0.005 + 0.006 * rnd()))
                        ctx.strokePath()
                    }
                case .wood, .planks:
                    for i in 0..<(m.grain == .planks ? 3 : 2 + many / 2) {
                        let y = m.grain == .planks ? box.minY + box.height * CGFloat(i + 1) / 4 : box.minY + rnd() * box.height
                        let x0 = box.minX + rnd() * box.width * 0.2, x1 = box.maxX - rnd() * box.width * 0.2
                        ctx.move(to: CGPoint(x: x0, y: y))
                        ctx.addLine(to: CGPoint(x: x1, y: y + (rnd() - 0.5) * size * 0.006))
                        ctx.setStrokeColor(shadow.cg(m.grain == .planks ? 0.5 : 0.32))
                        ctx.setLineWidth(size * (m.grain == .planks ? 0.006 : 0.004))
                        ctx.strokePath()
                    }
                case .hide:
                    for _ in 0..<(4 + 2 * many) {
                        let x = box.minX + rnd() * box.width, y = box.minY + rnd() * box.height
                        let a = (rnd() - 0.5) * 0.8, l = size * (0.015 + 0.03 * rnd())
                        ctx.move(to: CGPoint(x: x, y: y))
                        ctx.addQuadCurve(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l),
                                         control: CGPoint(x: x + cos(a) * l * 0.5, y: y + sin(a) * l * 0.5 + (rnd() - 0.5) * size * 0.008))
                        ctx.setStrokeColor((rnd() < 0.5 ? shadow : lit).cg(0.24))
                        ctx.setLineWidth(size * (0.004 + 0.005 * rnd()))
                        ctx.strokePath()
                    }
                case .metal:
                    for _ in 0..<2 {
                        let x = box.minX + rnd() * box.width * 0.6
                        ctx.move(to: CGPoint(x: x, y: box.maxY))
                        ctx.addLine(to: CGPoint(x: x + box.width * 0.3, y: box.minY))
                        ctx.setStrokeColor(lit.cg(0.14))
                        ctx.setLineWidth(size * 0.008)
                        ctx.strokePath()
                    }
                case .none:
                    break
                }
            }

            // Terminator: cool core shadow on the east and south side, in two soft steps.
            let k = min(max(extent * 0.22, size * 0.005), size * 0.04)
            if m.shade > 0 {
                for step in [1.0, 0.5] as [CGFloat] {
                    fillOutside(path, box: box, shift: (-k * step, k * step), color: Self.coolShadow.cg(0.18 * m.shade))
                }
            }
            // Rim light along the west and north edge.
            if m.light > 0 {
                let r = min(max(extent * 0.07, size * 0.004), size * 0.012)
                fillOutside(path, box: box, shift: (r, -r), color: Self.warmLight.cg(0.38 * m.light))
            }
            // Specular glint on metal and leather.
            if m.gloss > 0, let g = CGGradient(colorsSpace: Self.space, colors: [Tone(1, 0.97, 0.88).cg(0.75 * m.gloss), Tone(1, 0.97, 0.88).cg(0)] as CFArray,
                                               locations: [0, 1]) {
                let c = CGPoint(x: box.minX + box.width * 0.32, y: box.maxY - box.height * 0.3)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: extent * 0.32, options: [])
            }
            ctx.restoreGState()

            // Interior edge.
            ctx.addPath(path)
            ctx.setStrokeColor(Self.inkTone.cg(0.3))
            ctx.setLineWidth(size * 0.005)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }

        /// The player's emblem in its contrasting ink with a faint opposite-value halo. `crisp`
        /// (emblem decal cells, which already sit on a shaded shield) skips the lighting gradient.
        func emblem(_ style: PlayerStyle, center c: CGPoint, size s: CGFloat, clip: CGPath?, crisp: Bool) {
            ctx.saveGState()
            defer { ctx.restoreGState() }
            if crisp { ctx.translateBy(x: origin.x, y: origin.y) }
            let rect = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
            let shapes = style.emblem.shapes(in: rect)
            let ink = style.darkInk ? Tone(0.2, 0.13, 0.08) : Tone(0.98, 0.94, 0.84)
            if let clip { ctx.addPath(clip); ctx.clip() }
            ctx.setLineJoin(.round)
            ctx.setStrokeColor((style.darkInk ? Tone(1, 0.95, 0.8) : Tone(0.12, 0.08, 0.05)).cg(0.28))
            ctx.setLineWidth(s * 0.07)
            for shape in shapes { ctx.addPath(shape); ctx.strokePath() }
            ctx.setFillColor(ink.cg())
            for shape in shapes { ctx.addPath(shape); ctx.fillPath() }
            // Cream emblems catch the light from the upper left.
            if !crisp, !style.darkInk, let g = CGGradient(colorsSpace: Self.space, colors: [Tone(1, 0.97, 0.9).cg(0.25), Tone(0, 0, 0.1).cg(0.18)] as CFArray,
                                                         locations: [0, 1]) {
                let merged = CGMutablePath()
                for shape in shapes { merged.addPath(shape) }
                ctx.addPath(merged)
                ctx.clip()
                ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
            }
        }

        /// A badge's unit-type silhouette: dark ink with a faint light halo.
        private func glyph(_ shapes: [CGPath], halo: CGFloat) {
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(Tone(1, 0.97, 0.88).cg(0.5))
            ctx.setLineWidth(halo)
            for shape in shapes { ctx.addPath(shape); ctx.strokePath() }
            ctx.setFillColor(Tone(0.17, 0.11, 0.07).cg())
            for shape in shapes { ctx.addPath(shape); ctx.fillPath() }
        }
    }

}

extension Array where Element == FigurePaint.Step {
    /// The part of a cell of `size` pixels the steps paint, outlines and strokes included (lo
    /// x, lo y, hi x, hi y as fractions of the cell, y up), padded by a texel.
    func bounds(size: CGFloat) -> SIMD4<Float> {
        var box = CGRect.null
        for step in self {
            switch step {
            case let .part(path, _, outline, _):
                box = box.union(path.boundingBoxOfPath.insetBy(dx: -outline * size, dy: -outline * size))
            case let .decal(path, _, _, clip):
                box = box.union(clip.map { path.boundingBoxOfPath.intersection($0.boundingBoxOfPath) } ?? path.boundingBoxOfPath)
            case let .stroke(path, _, width, offset, clip):
                var b = path.boundingBoxOfPath.insetBy(dx: -width * size / 2, dy: -width * size / 2)
                    .offsetBy(dx: offset.0 * size, dy: offset.1 * size)
                if let clip { b = b.intersection(clip.boundingBoxOfPath) }
                box = box.union(b)
            case let .emblem(center, s, _):
                box = box.union(CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s))
            case let .glyph(shapes, halo):
                for shape in shapes { box = box.union(shape.boundingBoxOfPath.insetBy(dx: -halo, dy: -halo)) }
            }
        }
        guard !box.isNull else { return [0, 0, 1, 1] }
        box = box.insetBy(dx: -1, dy: -1)
        let lo = SIMD2<Float>(Float(box.minX / size), Float(box.minY / size)).clamped(lowerBound: .zero, upperBound: .one)
        let hi = SIMD2<Float>(Float(box.maxX / size), Float(box.maxY / size)).clamped(lowerBound: .zero, upperBound: .one)
        return SIMD4(lo.x, lo.y, hi.x, hi.y)
    }
}
