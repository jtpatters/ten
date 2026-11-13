import CoreGraphics
import GameCore
import QuartzCore
import simd

/// A path turn marker: the hex where one turn's movement ends.
struct PathMarker {
    /// The hex (normalized) and its center (world, on the route's side of the wrap).
    var hex: HexCoord
    var position: SIMD2<Float>
    var turn: Int
    var final: Bool
}

/// Per-renderer state for selection, path preview, markers and the unit pass's frame-to-frame
/// bookkeeping. `MapRenderer` stores one as `unitArt`; fields are added freely (with defaults).
struct UnitArtState {
    /// The selected hex (normalized). The unit pass rings it under the figures.
    var selection: HexCoord?
    /// The previewed route as far as the viewer has explored: a smooth curve through the hex
    /// centers (world), the distance along it at each sample, and the turn each sample's step
    /// is reached in.
    var route: [SIMD2<Float>] = []
    var routeAlong: [Float] = []
    var routeTurns: [Int] = []
    /// The rest of the route when it leads through unexplored land: the same curve on from the
    /// last explored step through the planned steps (empty when the whole route is explored),
    /// and the distance along it at each sample. Drawn as faint open rings.
    var unknownRoute: [SIMD2<Float>] = []
    var unknownAlong: [Float] = []
    var destination: SIMD2<Float>?
    /// Turn markers, back to front (drawn by `unitFrame`, above the units).
    var markers: [PathMarker] = []

    /// Strategic zoom: the mode (switched with hysteresis), how far the crossfade to it has
    /// run, and the frame it was last advanced on (`strategicBlend`).
    var strategic = false
    var blend: Float = 0
    var lastFrame: CFTimeInterval?
    var lastScale: Float = 0
    /// Seconds since the previous frame (capped), for easing.
    var frameDelta: Float = 1
    /// Where each figure (and the base under it) was drawn last frame (`settle`), and the
    /// feet offset (it follows the tilt) they were placed with.
    var poses: [UnitID: FigurePose] = [:]
    var posesFootY: Float = .nan
    var posesScale: Float = .nan
    /// How tall the drawn unit tokens stand (`unitTapSize`), from the last unit pass.
    var tapSize: Float = 1.8
    /// Where each unit drawn in the last unit pass stands (its figure's feet up close, its
    /// medallion's middle zoomed out, blending between): `screenPoint(ofUnit:)`.
    var anchors: [UnitID: SIMD2<Float>] = [:]
    /// Atlas rects the unit pass needs every frame, looked up once.
    var atlasTable: UnitAtlasTable?
}

/// Where a unit's figure stood and how big it was, and the center and radii of the base it
/// stood on (shared by a pair), as last drawn.
struct FigurePose {
    var feet: SIMD2<Float>
    var d: Float
    var base: SIMD4<Float>?
}

/// Meaning of `OverlayVertex.position.w` in the overlay pass; `color` carries that style's
/// parameters (see each case). Must match `ShaderOverlay.swift`.
enum OverlayStyle: Float {
    /// color: premultiplied RGBA.
    case plain = 0
    /// The route. color: offset across (-1...1), distance along (world units), opacity (its
    /// sign is negative past this turn's reach), half width (world units); aux.y: 1 over
    /// remembered land (explored, out of sight), where it is drawn with more contrast.
    case trail = 2
    /// Soft shadow under the route. color: offset across (-1...1), opacity.
    case trailShadow = 3
    /// Destination ring. color: offset across (-1...1), distance along, dash period, half width.
    case destination = 4
    /// The unexplored rest of the way, as faint open rings. Same parameters as `destination`.
    case unknown = 5
    /// A border: a band in the owner's colour and ring pattern just inside a territory edge
    /// (`MapRenderer+Territory.swift`). position: a corner of the edge; color: across (+1 on
    /// the edge's side, -1 inside), along (hex edges from the chain's start), the corner's
    /// miter direction into the territory (the vertex shader sets the inset and width for the
    /// zoom); aux: the owner's style index, dim (explored, out of sight), the chain's first
    /// and last along (its ends fade).
    case border = 6
    /// The movement range's outline: a cream line just inside the range's edge. Same
    /// parameters as `border` (aux.x unused).
    case rangeEdge = 7
}

extension MapRenderer {
    /// Selects a hex, or clears the selection. The unit pass draws its ring and lifts the base
    /// of a unit standing there. Same as `setSelection(hex, kind: .unit)`.
    public func setSelection(_ hex: HexCoord?) {
        setSelection(hex, kind: .unit)
    }

    /// Path preview: a route of marching chevrons from the unit to a ring at the destination,
    /// with a numbered marker where each turn's movement ends. Chevrons and markers stop at the
    /// last explored step (ART.md §8); from there faint open rings follow the rest of the
    /// planned steps to the destination, with no markers. The plan counts unexplored tiles as
    /// passable land (`PlayerView.path`, M1 §8.6), so its line through the fog shows nothing
    /// hidden; its turns there are guesses.
    public func showPath(_ path: Path?, from start: HexCoord) {
        unitArt.route = []
        unitArt.routeAlong = []
        unitArt.routeTurns = []
        unitArt.unknownRoute = []
        unitArt.unknownAlong = []
        unitArt.destination = nil
        unitArt.markers = []
        guard let path, !path.steps.isEmpty else { return }
        var points = [Self.vec(layout.center(of: start))]
        var x = points[0].x
        for step in path.steps {
            let c = Self.vec(layout.center(of: step.hex))
            x = Float(layout.nearestCopy(of: CGFloat(c.x), to: CGFloat(x)))
            points.append([x, c.y])
        }
        var known = path.steps.count
        if fogEnabled, let explored = state.players.first(where: { $0.id == viewer })?.explored {
            known = path.steps.firstIndex { step in state.map.index(of: step.hex).map { !explored[$0] } ?? true } ?? known
        }
        unitArt.destination = points[points.count - 1]

        // Catmull–Rom through all the hex centers, so the explored part leads smoothly into the
        // rest; each sample keeps its step's turn. Sample known × perSegment is the last
        // explored step's center, where the two parts meet.
        let n = path.steps.count, perSegment = 10
        var curve: [SIMD2<Float>] = [], turns: [Int] = []
        curve.reserveCapacity(n * perSegment + 1)
        turns.reserveCapacity(n * perSegment + 1)
        for i in 0..<n {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, n)]
            for k in 0..<perSegment {
                let t = Float(k) / Float(perSegment), t2 = t * t, t3 = t2 * t
                let a = 2 * p1, b = p2 - p0, c = 2 * p0 - 5 * p1 + 4 * p2 - p3, d = 3 * p1 - p0 - 3 * p2 + p3
                curve.append(0.5 * (a + b * t + c * t2 + d * t3))
                turns.append(path.steps[i].turn)
            }
        }
        curve.append(points[n])
        turns.append(path.steps[n - 1].turn)
        let split = known * perSegment
        if known > 0 {
            unitArt.route = Array(curve[0...split])
            unitArt.routeAlong = Self.distances(along: unitArt.route)
            unitArt.routeTurns = Array(turns[0..<split]) + [path.steps[known - 1].turn]
        }
        if known < n {
            unitArt.unknownRoute = Array(curve[split...])
            unitArt.unknownAlong = Self.distances(along: unitArt.unknownRoute)
        }

        for i in 0..<known {
            let step = path.steps[i], isLast = i == path.steps.count - 1
            guard isLast || path.steps[i + 1].turn != step.turn else { continue }
            let hex = state.map.normalize(step.hex) ?? step.hex
            unitArt.markers.append(PathMarker(hex: hex, position: points[i + 1], turn: step.turn, final: isLast))
        }
        unitArt.markers.sort { $0.position.y > $1.position.y }
    }

    /// Ground-plane overlay triangles for this frame: the route with its shadow, the rings of
    /// its unexplored remainder and the destination ring. Rebuilt each frame (a few hundred
    /// vertices) so their widths can follow the zoom and keep their weight on screen.
    func overlayGeometry() -> [OverlayVertex] {
        let ribbons = territoryGeometry()
        guard let destination = unitArt.destination else { return ribbons }
        let s = Float(layout.size)
        let widen = max(1, camera.scale * 0.85)
        let half = s * 0.17 * widen
        let ringRadius = s * 0.52
        var out = ribbons
        out.reserveCapacity(ribbons.count + unitArt.route.count * 12 + unitArt.unknownRoute.count * 6 + 400)

        let route = unitArt.route, along = unitArt.routeAlong
        let unknown = unitArt.unknownRoute
        if route.count >= 2 {
            // The route leaves from under the selection ring and stops short of the
            // destination ring; it fades in and out over its ends and where turns change.
            let total = along[along.count - 1]
            let from = s * 0.8
            let to = unknown.isEmpty ? total - ringRadius - half * 0.7 : total
            let fade = half * 0.8
            var pts: [SIMD2<Float>] = [], dist: [Float] = [], alpha: [Float] = []
            for i in route.indices where along[i] >= from - fade && along[i] <= to + fade {
                pts.append(route[i])
                dist.append(along[i])
                let a = min(max(min(along[i] - from, to - along[i]) / fade, 0), 1)
                alpha.append(unitArt.routeTurns[i] > 1 ? -a : a)
            }
            if pts.count >= 2 {
                let shadow = SIMD2<Float>(0.05, -0.04) * s * widen // away from the sun
                out += Self.ribbon(pts.map { $0 + shadow }, along: dist, half: half * 1.2, style: .trailShadow, params: { [abs(alpha[$0]), 0] })
                let remembered = pts.map { p -> Float in
                    let hex = state.map.normalize(layout.hex(at: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))))
                    return hex.map { fogLevel($0) == 1 ? 1 : 0 } ?? 0
                }
                out += Self.ribbon(pts, along: dist, half: half, style: .trail, params: { [alpha[$0], half] },
                                   aux: { [0, remembered[$0], 0, 0] })
            }
        }
        if unknown.count >= 2 {
            // On along the planned steps to the destination ring, from the end of the drawn
            // route, or from outside the unit's own hex when even the first step is unexplored.
            let along = unitArt.unknownAlong, total = along[along.count - 1]
            let from = route.isEmpty ? s * 0.8 : 0, to = total - ringRadius - half * 0.5
            if to > from {
                let part = Self.stretch(of: unknown, along: along, from: from, to: to)
                out += Self.ribbon(part.points, along: part.along, half: half * 0.6, style: .unknown,
                                   params: { _ in [half * 2.4, half * 0.6] })
            }
        }
        out += destinationRing(around: destination, radius: ringRadius, half: half * 0.42)
        return out
    }

    // MARK: Overlay geometry

    /// The distance along a polyline at each of its points (at least one point).
    static func distances(along pts: [SIMD2<Float>]) -> [Float] {
        var along: [Float] = [0]
        along.reserveCapacity(pts.count)
        for i in pts.indices.dropFirst() { along.append(along[i - 1] + simd_distance(pts[i - 1], pts[i])) }
        return along
    }

    /// The stretch of a polyline between distances `a` < `b` along it (`along` its distances,
    /// ascending), with interpolated ends and distances counted from `a`.
    static func stretch(of pts: [SIMD2<Float>], along: [Float], from a: Float, to b: Float) -> (points: [SIMD2<Float>], along: [Float]) {
        func point(at d: Float) -> SIMD2<Float> {
            var i = 1
            while i < along.count - 1, along[i] < d { i += 1 }
            let span = along[i] - along[i - 1]
            let t = span > 1e-6 ? min(max((d - along[i - 1]) / span, 0), 1) : 0
            return pts[i - 1] + (pts[i] - pts[i - 1]) * t
        }
        // Points closer than this to a cut end are dropped, so no segment is degenerate.
        let eps: Float = 1e-2
        var points = [point(at: a)], distances: [Float] = [0]
        for i in pts.indices where along[i] > a + eps && along[i] < b - eps {
            points.append(pts[i])
            distances.append(along[i] - a)
        }
        points.append(point(at: b))
        distances.append(b - a)
        return (points, distances)
    }

    /// Dashed ring around the destination.
    private func destinationRing(around c: SIMD2<Float>, radius: Float, half: Float) -> [OverlayVertex] {
        let n = 48
        let pts = (0..<n).map { i -> SIMD2<Float> in
            let a = Float(i) / Float(n) * 2 * .pi
            return c + SIMD2(cos(a), sin(a)) * radius
        }
        let circumference = 2 * Float.pi * radius
        let along = (0..<n).map { Float($0) / Float(n) * circumference }
        // A whole number of dashes, so the pattern closes without a seam.
        let period = circumference / max(round(circumference / (half * 7)), 6)
        return Self.ribbon(pts, along: along, closingAlong: circumference, half: half, style: .destination) { _ in [period, half] }
    }

    /// Triangles for a band of half width `half` along a polyline. Each vertex carries its
    /// offset across (-1 left ... 1 right), its distance along and two style parameters. A
    /// closed loop (`closingAlong` set) ends on its first point with that distance, so patterns
    /// along it don't jump at the seam.
    private static func ribbon(_ pts: [SIMD2<Float>], along: [Float], closingAlong: Float? = nil, half: Float, style: OverlayStyle,
                               params: (Int) -> SIMD2<Float>, aux: ((Int) -> SIMD4<Float>)? = nil) -> [OverlayVertex] {
        let n = pts.count, closed = closingAlong != nil
        guard n >= 2 else { return [] }
        func perp(_ v: SIMD2<Float>) -> SIMD2<Float> {
            let l = simd_length(v)
            return l > 1e-5 ? SIMD2(-v.y, v.x) / l : .zero
        }
        var left: [OverlayVertex] = [], right: [OverlayVertex] = []
        left.reserveCapacity(n)
        right.reserveCapacity(n)
        for i in 0..<n {
            let prev = closed ? pts[(i + n - 1) % n] : pts[max(i - 1, 0)]
            let next = closed ? pts[(i + 1) % n] : pts[min(i + 1, n - 1)]
            let n0 = perp(pts[i] - prev), n1 = perp(next - pts[i])
            var normal = n0 + n1
            normal = simd_length(normal) > 1e-5 ? simd_normalize(normal) : (n0 == .zero ? n1 : n0)
            // Miter, so the band keeps its width through bends (capped on sharp ones).
            let miter = half / max(simd_dot(normal, n1 == .zero ? n0 : n1), 0.6)
            let p = params(i), a = aux?(i) ?? .zero
            left.append(OverlayVertex(position: [pts[i].x + normal.x * miter, pts[i].y + normal.y * miter, 0, style.rawValue],
                                      color: [-1, along[i], p.x, p.y], aux: a))
            right.append(OverlayVertex(position: [pts[i].x - normal.x * miter, pts[i].y - normal.y * miter, 0, style.rawValue],
                                       color: [1, along[i], p.x, p.y], aux: a))
        }
        var out: [OverlayVertex] = []
        out.reserveCapacity((closed ? n : n - 1) * 6)
        for i in 0..<(closed ? n : n - 1) {
            let j = (i + 1) % n
            var l1 = left[j], r1 = right[j]
            if j == 0, let end = closingAlong {
                l1.color.y = end
                r1.color.y = end
            }
            out += [left[i], right[i], l1, l1, right[i], r1]
        }
        return out
    }
}
