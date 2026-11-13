import CoreGraphics
import GameCore

/// A player's heraldry: a color from the Okabe–Ito colorblind-safe set, a bold emblem and a
/// ring pattern, so ownership never relies on color alone (SPEC §14.4). The emblem appears on
/// banners, shields and the strategic-zoom medallions; the pattern runs around the base ring
/// under each unit and around its medallion.
struct PlayerStyle: Sendable {
    let r, g, b: CGFloat
    let emblem: Emblem
    /// Emblem ink on this field: dark brown on the light fields, cream on the darker ones,
    /// whichever has the higher contrast.
    let darkInk: Bool
    let ring: RingPattern

    var color: CGColor { Palette.rgb(r, g, b) }
    var rgb: SIMD3<Float> { [Float(r), Float(g), Float(b)] }
}

/// How a player's color runs around a base band or medallion frame, between dark keylines
/// (`unitPattern` in `ShaderUnits.swift`, `UnitSprite.ringPattern`). Every player has its own,
/// so two rings that look alike in color (to anyone, under any color vision) still differ.
enum RingPattern: Int, CaseIterable, Sendable {
    /// One even band.
    case solid
    /// Two lines with a dark rule between them.
    case double
    /// Long dashes.
    case dashed
    /// Round beads on a dark cord.
    case beaded
    /// A band with dark V notches cut into its outer edge.
    case notched
    /// Dark twists slanting across the band.
    case rope
    /// A zigzag between the keylines.
    case chevron
    /// A band with a thin line of the color outside it.
    case thickThin
}

/// Emblems are simple filled silhouettes with distinct outlines (radial, winged, tall, lobed,
/// curved, striped, pointed, blocky) so they stay apart even a dozen pixels wide.
enum Emblem: Int, CaseIterable, Sendable {
    case sun, bird, tree, trefoil, crescent, wave, star, tower

    /// The emblem as filled shapes inside `rect` (y-up). Shapes are filled one at a time, so
    /// overlapping parts never cancel each other out.
    func shapes(in rect: CGRect) -> [CGPath] {
        // Unit box [-1, 1]² (y up) mapped onto the rect.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        }
        func poly(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: pts.map { p($0.0, $0.1) })
            path.closeSubpath()
            return path
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: rect.midX + (x - radius) * rect.width / 2, y: rect.midY + (y - radius) * rect.height / 2,
                                     width: radius * rect.width, height: radius * rect.height), transform: nil)
        }
        let unit = rect.width / 2

        switch self {
        case .sun:
            var shapes = [circle(0, 0, 0.42)]
            for i in 0..<12 {
                let a = CGFloat(i) * .pi / 6
                let tip: CGFloat = i % 2 == 0 ? 0.98 : 0.78, half: CGFloat = 0.13
                shapes.append(poly([(cos(a - half) * 0.54, sin(a - half) * 0.54), (cos(a) * tip, sin(a) * tip),
                                    (cos(a + half) * 0.54, sin(a + half) * 0.54)]))
            }
            return shapes

        case .bird:
            func wing(_ s: CGFloat) -> CGPath {
                let path = CGMutablePath()
                path.move(to: p(0.02 * s, 0.16))
                path.addQuadCurve(to: p(0.98 * s, 0.58), control: p(0.42 * s, 0.6))
                path.addQuadCurve(to: p(0.42 * s, 0.12), control: p(0.74 * s, 0.22))
                path.addQuadCurve(to: p(0.04 * s, -0.22), control: p(0.16 * s, -0.08))
                path.closeSubpath()
                return path
            }
            let body = CGPath(ellipseIn: CGRect(x: p(-0.15, 0).x, y: p(0, -0.5).y, width: 0.3 * unit, height: 0.86 * unit), transform: nil)
            return [wing(-1), wing(1), body, circle(0, 0.38, 0.16), poly([(-0.26, -0.86), (0, -0.4), (0.26, -0.86), (0, -0.7)])]

        case .tree:
            return [poly([(-0.13, -0.98), (0.13, -0.98), (0.13, -0.45), (-0.13, -0.45)]),
                    poly([(-0.78, -0.58), (0.78, -0.58), (0, 0.08)]),
                    poly([(-0.62, -0.2), (0.62, -0.2), (0, 0.5)]),
                    poly([(-0.46, 0.2), (0.46, 0.2), (0, 0.98)])]

        case .trefoil:
            let stem = CGMutablePath()
            stem.move(to: p(-0.1, -0.2))
            stem.addQuadCurve(to: p(-0.06, -0.98), control: p(-0.14, -0.62))
            stem.addLine(to: p(0.12, -0.98))
            stem.addQuadCurve(to: p(0.1, -0.2), control: p(0.08, -0.62))
            stem.closeSubpath()
            return [stem, circle(0, 0.46, 0.38), circle(-0.44, -0.08, 0.38), circle(0.44, -0.08, 0.38), circle(0, 0.1, 0.24)]

        case .crescent:
            // Outer circle (r 0.92) minus a circle raised by 0.42 (r 0.78): horns up.
            let path = CGMutablePath()
            path.addArc(center: p(0, 0), radius: 0.92 * unit, startAngle: 0.5657, endAngle: 2.5759, clockwise: true)
            path.addArc(center: p(0, 0.42), radius: 0.78 * unit, startAngle: 3.0473, endAngle: 6.3775, clockwise: false)
            path.closeSubpath()
            return [path]

        case .wave:
            return [0.42, -0.34].map { y in
                let path = CGMutablePath()
                let steps = 24
                let top = (0...steps).map { i -> CGPoint in
                    let x = -0.96 + 1.92 * CGFloat(i) / CGFloat(steps)
                    return p(x, y + 0.17 + 0.2 * sin(x * .pi * 1.25))
                }
                let bottom = (0...steps).reversed().map { i -> CGPoint in
                    let x = -0.96 + 1.92 * CGFloat(i) / CGFloat(steps)
                    return p(x, y - 0.17 + 0.2 * sin(x * .pi * 1.25))
                }
                path.addLines(between: top + bottom)
                path.closeSubpath()
                return path
            }

        case .star:
            return [poly((0..<10).map { i in
                let a = .pi / 2 + CGFloat(i) * .pi / 5
                let radius: CGFloat = i % 2 == 0 ? 1.0 : 0.42
                return (cos(a) * radius, sin(a) * radius - 0.06)
            })]

        case .tower:
            let body = CGMutablePath()
            body.addLines(between: [p(-0.5, -0.96), p(-0.17, -0.96), p(-0.17, -0.52)])
            body.addArc(center: p(0, -0.52), radius: 0.17 * unit, startAngle: .pi, endAngle: 0, clockwise: true)
            body.addLines(between: [p(0.17, -0.52), p(0.17, -0.96), p(0.5, -0.96), p(0.5, 0.3), p(-0.5, 0.3)])
            body.closeSubpath()
            return [body, poly([(-0.66, 0.22), (0.66, 0.22), (0.66, 0.56), (-0.66, 0.56)]),
                    poly([(-0.66, 0.5), (-0.36, 0.5), (-0.36, 0.92), (-0.66, 0.92)]),
                    poly([(-0.15, 0.5), (0.15, 0.5), (0.15, 0.92), (-0.15, 0.92)]),
                    poly([(0.36, 0.5), (0.66, 0.5), (0.66, 0.92), (0.36, 0.92)])]
        }
    }
}

extension Palette {
    /// Okabe–Ito hues, nudged slightly deeper so they hold up against sand and snow; the set's
    /// black becomes a warm charcoal (a mid grey would read as "inactive", which is what the
    /// dimmed no-moves-left state looks like).
    static let playerStyles: [PlayerStyle] = [
        PlayerStyle(r: 0.90, g: 0.59, b: 0.00, emblem: .sun, darkInk: true, ring: .solid),            // orange
        PlayerStyle(r: 0.34, g: 0.70, b: 0.92, emblem: .bird, darkInk: true, ring: .rope),            // sky blue
        PlayerStyle(r: 0.00, g: 0.60, b: 0.45, emblem: .tree, darkInk: false, ring: .notched),        // bluish green
        PlayerStyle(r: 0.95, g: 0.87, b: 0.20, emblem: .trefoil, darkInk: true, ring: .dashed),       // yellow
        PlayerStyle(r: 0.00, g: 0.43, b: 0.70, emblem: .crescent, darkInk: false, ring: .double),     // blue
        PlayerStyle(r: 0.84, g: 0.33, b: 0.00, emblem: .wave, darkInk: false, ring: .beaded),         // vermillion
        PlayerStyle(r: 0.80, g: 0.45, b: 0.65, emblem: .star, darkInk: true, ring: .chevron),         // reddish purple
        PlayerStyle(r: 0.24, g: 0.22, b: 0.24, emblem: .tower, darkInk: false, ring: .thickThin),     // charcoal
    ]

    static let players: [CGColor] = playerStyles.map(\.color)

    static func playerStyle(_ index: Int) -> PlayerStyle { playerStyles[index % playerStyles.count] }

    static func player(_ id: PlayerID) -> CGColor { players[id.rawValue % players.count] }
}
