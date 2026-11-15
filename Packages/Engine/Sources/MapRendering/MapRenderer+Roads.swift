import CoreGraphics
import GameCore
import Metal
import simd

// Roads and pillaged improvements (M2 §3.3), as the App passes them from the viewer's
// knowledge: roads as remembered (`PlayerView.tile(at:)`), pillaged improvements only where in
// sight. Nothing is drawn on an unexplored tile.
//
// - A road is a band of packed earth on the ground (the overlay pipeline, drawn before the units'
//   bases and the decorations), painted per road tile by the overlay shader (`overlayRoad` in
//   `ShaderOverlay.swift`) along a path planned here (`planRoad`) from which of its edges it
//   shares with another explored road tile. Paths are planned in world space: each tile's ideal
//   path is moved by one smooth field over the whole map (`RoadField`), a slow wander a few tiles
//   long plus a push off what stands near the road (hills and mounds, a mine's entrance, a
//   village), so a road flows on across tile edges, crossing each at the same place and in the
//   same direction from both sides, and bends but never kinks. Into cities it runs
//   straight. What it still crosses, it goes through on purpose: plants, rocks and herds on its way
//   are cleared, and the one mound per tile that would hide it is cut (`roadClearings`). A dead
//   end reaches the middle of its tile, then narrows and fades out, like a track petering out; a
//   lone road is a small worn patch. A known city's tile counts as a road, so roads lead into
//   it. Where three road tiles all touch, one link is left out (`roadLinks`). Out of sight it
//   takes the explored-fog look.
// - A pillaged improvement gets a mark, a flame on a cream disc in a red rim, on its tile's north
//   side, drawn by the unit pass with the job marks.

/// The road ribbons and the paths they paint, cached until the roads, the fog or what stands
/// on the road tiles change (`MapRenderer.roadArt`).
struct RoadArtState {
    /// Bumped by `setRoads`, and when the cities, improvements or tribal villages change.
    var version = 0
    var key: SIMD2<Int>?
    var ribbons: [OverlayVertex] = []
    /// Every road tile's path points (`RoadPlan.points`), read by the overlay shader.
    var points: MTLBuffer?
    /// The plans by tile, as last made.
    var plans: [Int: RoadPlan] = [:]
    /// Decorations hidden because a road runs through them (`DecorFlags.roadCleared`).
    var cleared: Set<Int32> = []
    /// Every decoration (shadows included) by the tile it belongs to; built on first use.
    var allByTile: [Int: [Int32]]?
    /// The relief footprints (`MapRenderer.reliefSpots` indices) by the tile they lie on; built
    /// on first use.
    var reliefByTile: [Int: [Int]]?
}

/// One road tile's road, planned on the CPU so it can wander and give way.
///
/// Roads are planned in world space, not tile by tile, so they flow on across the tiles: each
/// tile's ideal path (from each linked edge's middle, square to it, to the next edge or to the
/// centre) is moved by one displacement field over the whole map (`RoadField`): a slow wander
/// a few tiles long, plus a push away from what stands near the road (hill and mountain mounds,
/// a mine's entrance, a tribal village). Two tiles sharing an edge move the points on it alike,
/// so the road crosses it at the same place in the same direction from both sides, and the field
/// is smooth, so it bends but never kinks. Near an edge the field may slide the crossing along
/// the edge a little but never off it; it keeps the road off the edges it does not cross. What
/// the road still runs over it goes through on purpose (`clearings`).
struct RoadPlan {
    /// The edges the road crosses (a bit per `HexDirection`).
    var key: Int
    /// The path: x, y from the tile's centre; z the place along its branch (0 at the edge, 1 at
    /// the far end); w the branch's code (`branch · 4`, + 1 for a dead end that fades out, + 2
    /// for a lone road's patch). Consecutive points of one branch make its segments.
    var points: [SIMD4<Float>]
    /// Where the branches meet (from the tile's centre), or far away when they do not.
    var hub: SIMD2<Float>
    /// Decorations the road clears (indices into the decoration buffer).
    var clearings: [Int32]
}

/// Something a road bends around: a capsule from its foot back (north) over the ground it hides
/// in the tilted view, in world units.
struct RoadObstacle {
    var foot: SIMD2<Float>
    var back: SIMD2<Float>
    var radius: Float
}

/// The displacement every road point goes through (`RoadPlan`): the same smooth function of
/// world position for every tile.
struct RoadField {
    /// The wander's waves: wave vector, phase, weight; the first two move x, the others y.
    var waves: [(k: SIMD2<Float>, phase: Float, weight: Float)]
    /// The wander's size.
    var amplitude: Float
    /// The obstacles the roads go round, by the tile they lie on.
    var obstacles: [Int: [RoadObstacle]]
    /// Known cities' centres: the wander dies away into them.
    var cities: [SIMD2<Float>]
    /// The road's half width and a little room.
    var half: Float
    /// The most the field moves a point.
    var limit: Float
    var size: Float
    var worldWidth: Float
    var wrapsX: Bool

    func delta(_ d: SIMD2<Float>) -> SIMD2<Float> {
        guard wrapsX else { return d }
        var d = d
        d.x -= (d.x / worldWidth).rounded() * worldWidth
        return d
    }

    /// The slow wander at `p`, fading out toward the cities.
    func wander(_ p: SIMD2<Float>) -> SIMD2<Float> {
        var x: Float = 0, y: Float = 0
        for (n, w) in waves.enumerated() {
            let v = sin(simd_dot(w.k, p) + w.phase) * w.weight
            if n < 2 { x += v } else { y += v }
        }
        var fade: Float = 1
        for c in cities {
            let d = simd_length(delta(p - c))
            if d < size * 1.8 { fade *= simd_smoothstep(size * 0.5, size * 1.8, d) }
        }
        return SIMD2(x, y) * amplitude * fade
    }

    /// The push off obstacle `o` at `p`: none well clear of it, enough to clear it where the road
    /// grazes it, easing off again toward its middle (a road aimed through it goes through).
    func push(_ p: SIMD2<Float>, from o: RoadObstacle) -> SIMD2<Float> {
        let foot = o.foot, ab = o.back - o.foot
        let q = delta(p - foot)
        let h = simd_clamp(simd_dot(q, ab) / max(simd_dot(ab, ab), 1e-8), 0, 1)
        let v = q - ab * h, d = simd_length(v), room = o.radius + half
        guard d < room * 1.8, d > 1e-5 else { return .zero }
        let m = room * (1 - simd_smoothstep(0, room * 1.8, d)) * simd_smoothstep(0, room * 0.35, d)
        return v / d * m
    }

    /// The whole displacement at world point `p` with the obstacles `near`, its size held
    /// under `limit` smoothly.
    func displacement(_ p: SIMD2<Float>, near: [RoadObstacle]) -> SIMD2<Float> {
        var d = wander(p)
        for o in near { d += push(p, from: o) }
        let length = simd_length(d)
        guard length > 1e-6 else { return .zero }
        return d * (limit * tanh(length / limit) / length)
    }
}

extension MapRenderer {
    /// Roads as the viewer knows them: per tile true where there is one (empty: none).
    public func setRoads(_ roads: [Bool]) {
        assert(roads.isEmpty || roads.count == state.map.tileCount, "roads need one entry per tile")
        guard roads != inputs.roads else { return }
        inputs.roads = roads
        roadArt.version += 1
    }

    /// The pillaged improvements the viewer sees (M2 §3.3); kept one per tile, in tile order.
    public func setPillaged(_ tiles: [HexCoord]) {
        inputs.pillaged = tileIndices(tiles).sorted().map { state.map.coord(at: $0) }
    }

    /// This frame's road ribbons, rebuilt only when the roads or the fog changed.
    func roadGeometry() -> [OverlayVertex] {
        let key = SIMD2(roadArt.version, fogVersion)
        if roadArt.key != key {
            roadArt.ribbons = makeRoads()
            roadArt.key = key
        }
        return roadArt.ribbons
    }

    /// The edge normals in `HexDirection` order (the shader's `kNormals`).
    static let roadNormals: [SIMD2<Float>] = [[1, 0], [0.5, -0.8660254], [-0.5, -0.8660254], [-1, 0], [-0.5, 0.8660254], [0.5, 0.8660254]]
    /// Samples per branch.
    static let roadSamples = 12

    /// Each explored road tile's hexagon, as four triangles (`OverlayStyle.road`), carrying where
    /// its path's points lie in `roadArt.points` (color z, w) and its hub (aux x, w); and the
    /// decorations on the roads hidden.
    private func makeRoads() -> [OverlayVertex] {
        let links = roadLinks()
        func road(_ i: Int) -> Bool { i < inputs.roads.count && inputs.roads[i] }
        let s = Float(layout.size), halfX = s * 0.8660254, style = OverlayStyle.road.rawValue
        // A city's tile shows only the roads leading into it (under its buildings).
        let tiles = links.keys.sorted().filter { links[$0]! != 0 || road($0) }
        let field = roadField(tiles: tiles, links: links)
        var out: [OverlayVertex] = []
        var points: [SIMD4<Float>] = []
        var plans: [Int: RoadPlan] = [:]
        for i in tiles {
            let plan = planRoad(tile: i, links: links[i]!, field: field)
            plans[i] = plan
            let first = Float(points.count), count = Float(plan.points.count)
            points += plan.points
            let hex = state.map.coord(at: i)
            let c = Self.vec(layout.center(of: hex)), dim: Float = fogLevel(hex) == 1 ? 1 : 0
            let terrain = Float(state.map[index: i].terrain.rawValue)
            func vertex(_ dx: Float, _ dy: Float) -> OverlayVertex {
                OverlayVertex(position: [c.x + dx, c.y + dy, 0, style], color: [dx, dy, first, count],
                              aux: [plan.hub.x, dim, terrain, plan.hub.y])
            }
            // The hexagon (pointy-top) as four triangles.
            let top = vertex(0, s), bottom = vertex(0, -s)
            let upperLeft = vertex(-halfX, s / 2), upperRight = vertex(halfX, s / 2)
            let lowerLeft = vertex(-halfX, -s / 2), lowerRight = vertex(halfX, -s / 2)
            out += [top, upperLeft, upperRight, upperLeft, lowerLeft, upperRight, upperRight, lowerLeft, lowerRight,
                    lowerLeft, bottom, lowerRight]
        }
        roadArt.plans = plans
        roadArt.points = points.isEmpty ? nil
            : device.makeBuffer(bytes: points, length: MemoryLayout<SIMD4<Float>>.stride * points.count, options: .storageModeShared)
        clearRoadDecorations(Set(plans.values.flatMap(\.clearings)))
        return out
    }

    /// A tile's ideal road, before the field moves it: per branch its samples (from the tile's
    /// centre) and whether it is a dead end. Each branch leaves its edge's middle square to it:
    /// with two edges it runs from one to the other; with three or more each runs to the centre;
    /// a dead end runs a little past the centre.
    private func idealRoad(links mask: Int) -> [(points: [SIMD2<Float>], fades: Bool)] {
        let s = Float(layout.size), apothem = s * 0.8660254, reach = apothem * 0.55
        let normals = Self.roadNormals
        let linked = (0..<6).filter { mask >> $0 & 1 == 1 }
        var cubics: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, Bool)] = []
        switch linked.count {
        case 0:
            break
        case 1:
            let n = normals[linked[0]], m = n * apothem, end = -n * s * 0.3
            cubics.append((m, m - n * reach, end + (m - end) * 0.25, end, true))
        case 2:
            let (a, b) = (normals[linked[0]], normals[linked[1]])
            let ma = a * apothem, mb = b * apothem
            cubics.append((ma, ma - a * reach, mb - b * reach, mb, false))
        default:
            for b in linked {
                let n = normals[b], m = n * apothem
                cubics.append((m, m - n * reach, (m - n * reach) * 0.3, .zero, false))
            }
        }
        let k = Self.roadSamples
        return cubics.map { p0, p1, p2, p3, fades in
            let points = (0..<k).map { j -> SIMD2<Float> in
                let t = Float(j) / Float(k - 1), u = 1 - t
                return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
            }
            return (points, fades)
        }
    }

    /// The field the roads are moved by (`RoadField`), with the obstacles near the road tiles
    /// that a road passes beside. One a road runs straight over is left out: the road goes
    /// through it (`roadClearings` cuts the mound).
    private func roadField(tiles: [Int], links: [Int: Int]) -> RoadField {
        let s = Float(layout.size), width = Float(layout.worldWidth)
        // The wander: waves four to six tiles long, at slants, whole numbers round a wrapping map.
        let twoPi = Float.pi * 2
        let shapes: [(length: Float, angle: Float, phase: Float, weight: Float)] =
            [(9.0, 0.5, 1.3, 0.6), (5.6, 2.2, 4.0, 0.4), (8.2, 1.3, 2.7, 0.6), (5.1, 2.9, 0.6, 0.4)]
        let waves = shapes.map { w -> (k: SIMD2<Float>, phase: Float, weight: Float) in
            var k = SIMD2(cos(w.angle), sin(w.angle)) * (twoPi / (w.length * s))
            if layout.wrapsX, width > 0 { k.x = (k.x * width / twoPi).rounded() * twoPi / width }
            return (k, w.phase, w.weight)
        }
        let cityCentres = inputs.cities.compactMap { state.map.normalize($0.hex) }.map { Self.vec(layout.center(of: $0)) }
        var field = RoadField(waves: waves, amplitude: s * 0.2, obstacles: [:], cities: cityCentres, half: s * 0.14,
                              limit: s * 0.32, size: s, worldWidth: width, wrapsX: layout.wrapsX)
        guard !tiles.isEmpty else { return field }

        // Every obstacle on the road tiles and the tiles beside them.
        var near = Set<Int>()
        for i in tiles {
            near.insert(i)
            for n in neighbourTiles(i) { near.insert(n) }
        }
        let byRelief = reliefByTile()
        let cityTiles = Set(inputs.cities.compactMap { state.map.normalize($0.hex).flatMap(state.map.index(of:)) })
        let villages = Set(inputs.tribalVillages.compactMap { state.map.index(of: $0.hex) })
        var candidates: [Int: [RoadObstacle]] = [:]
        for t in near where !cityTiles.contains(t) {
            var list: [RoadObstacle] = []
            for f in byRelief[t] ?? [] {
                // The footprint lies 0.3 radii behind the foot; the crest (w: of two tile sizes)
                // hides about two thirds of its height of ground behind it.
                let spot = reliefSpots[f], r = spot.z * 0.75
                let foot = SIMD2(spot.x, spot.y - 0.3 * spot.z)
                list.append(RoadObstacle(foot: foot, back: foot + SIMD2(0, max(0, spot.w * 2 * s * 0.65 - r)), radius: r))
            }
            let c = Self.vec(layout.center(of: state.map.coord(at: t)))
            if villages.contains(t) { list.append(RoadObstacle(foot: c, back: c + SIMD2(0, s * 0.15), radius: s * 0.3)) }
            if t < inputs.improvements.count, inputs.improvements[t] == Improvement.mine.rawValue, let buffer = decorationBuffer {
                let all = buffer.contents().assumingMemoryBound(to: SpriteInstance.self)
                for index in decorationsByTile()[t] ?? [] {
                    let d = all[Int(index)]
                    let needs = UInt32(d.flags.w) >> 15 & 15
                    guard d.flags.x > 0.5, needs == UInt32(Improvement.mine.rawValue) else { continue }
                    let foot = SIMD2(d.position.x, d.position.y)
                    list.append(RoadObstacle(foot: foot, back: foot + SIMD2(0, d.sizeAnchor.y * 0.4), radius: d.sizeAnchor.x * 0.35))
                }
            }
            if !list.isEmpty { candidates[t] = list }
        }

        // Which of them a road passes beside (measured on the wandering roads): kept. One the
        // road runs over, or nowhere near, is dropped.
        var wandering: [Int: [[SIMD2<Float>]]] = [:]
        for i in tiles {
            let c = Self.vec(layout.center(of: state.map.coord(at: i)))
            wandering[i] = idealRoad(links: links[i]!).map { branch in branch.points.map { c + $0 + field.wander(c + $0) } }
        }
        for (t, list) in candidates {
            let lines = ([t] + neighbourTiles(t)).compactMap { wandering[$0] }.flatMap { $0 }
            guard !lines.isEmpty else { continue }
            let kept = list.filter { o in
                let ab = o.back - o.foot, room = o.radius + field.half
                var nearest = Float.infinity
                for line in lines {
                    for p in line {
                        let q = field.delta(p - o.foot)
                        let h = simd_clamp(simd_dot(q, ab) / max(simd_dot(ab, ab), 1e-8), 0, 1)
                        nearest = min(nearest, simd_length(q - ab * h))
                    }
                }
                return nearest >= room * 0.3 && nearest < room * 1.8 + s * 0.1
            }
            if !kept.isEmpty { field.obstacles[t] = kept }
        }
        return field
    }

    /// The tiles beside tile `i` (fewer at the map's edge).
    private func neighbourTiles(_ i: Int) -> [Int] {
        let hex = state.map.coord(at: i)
        return HexDirection.allCases.compactMap { state.map.normalize(hex.neighbor($0)).flatMap(state.map.index(of:)) }
    }

    /// The relief footprints by the tile they lie on.
    private func reliefByTile() -> [Int: [Int]] {
        if let index = roadArt.reliefByTile { return index }
        var index: [Int: [Int]] = [:]
        for (n, f) in reliefSpots.enumerated() {
            let hex = layout.hex(at: CGPoint(x: CGFloat(f.x), y: CGFloat(f.y)))
            if let h = state.map.normalize(hex), let t = state.map.index(of: h) { index[t, default: []].append(n) }
        }
        roadArt.reliefByTile = index
        return index
    }

    /// Plans one tile's road (`RoadPlan`): its ideal road moved by the field. Near an edge the
    /// road crosses, the move along the edge is held to a little and the move across it eases
    /// to nothing at the edge (alike from both sides, so the two halves still meet, in the same
    /// direction); near an edge it does not cross, it may not come closer than about a road's
    /// width.
    private func planRoad(tile i: Int, links mask: Int, field: RoadField) -> RoadPlan {
        let s = Float(layout.size), apothem = s * 0.8660254
        let c = Self.vec(layout.center(of: state.map.coord(at: i)))
        let normals = Self.roadNormals
        // The obstacles out to two tiles away, so both sides of an edge feel the same ones.
        var around = Set([i])
        for n in neighbourTiles(i) {
            around.insert(n)
            for m in neighbourTiles(n) { around.insert(m) }
        }
        let obstacles = around.sorted().flatMap { field.obstacles[$0] ?? [] }
        let band = s * 0.4, slide = s * 0.12, margin = s * 0.2
        func moved(_ p: SIMD2<Float>) -> SIMD2<Float> {
            var d = field.displacement(c + p, near: obstacles)
            // The edges the road crosses first: held on the edge, sliding a little along it.
            for e in 0..<6 where mask >> e & 1 == 1 {
                let n = normals[e], along = SIMD2(-n.y, n.x)
                let gap = max(0, apothem - simd_dot(p, n)), ease = simd_smoothstep(0, band, gap)
                let dn = simd_dot(d, n) * ease
                let dt = simd_dot(d, along)
                d = n * dn + along * simd_mix(slide * tanh(dt / slide), dt, ease)
            }
            // Then the others: kept off them.
            for e in 0..<6 where mask >> e & 1 == 0 {
                let n = normals[e], dn = simd_dot(d, n)
                guard dn > 0 else { continue }
                let room = max(0, apothem - simd_dot(p, n) - margin)
                d += n * ((room > 0 ? room * tanh(dn / room) : 0) - dn)
            }
            return p + d
        }
        var points: [SIMD4<Float>] = []
        let k = Self.roadSamples
        for (index, branch) in idealRoad(links: mask).enumerated() {
            let code = Float(index * 4 + (branch.fades ? 1 : 0))
            for (j, p) in branch.points.enumerated() {
                let q = moved(p)
                points.append(SIMD4(q.x, q.y, Float(j) / Float(k - 1), code))
            }
        }
        let hub = moved(.zero)
        if mask == 0 {
            // A lone road: a small worn patch.
            points = [SIMD4(hub.x - s * 0.05, hub.y, 0, 2), SIMD4(hub.x + s * 0.05, hub.y, 1, 2)]
        }
        let meets = mask.nonzeroBitCount >= 3 || mask == 0
        return RoadPlan(key: mask, points: points, hub: meets ? hub : SIMD2(repeating: 1e4),
                        clearings: roadClearings(tile: i, centre: c, points: points))
    }

    /// Every decoration's index by its tile, shadows included (they share their caster's foot).
    private func decorationsByTile() -> [Int: [Int32]] {
        if let index = roadArt.allByTile { return index }
        var index: [Int: [Int32]] = [:]
        if let buffer = decorationBuffer {
            let all = buffer.contents().assumingMemoryBound(to: SpriteInstance.self)
            for n in 0..<decorationCount {
                let tile = Int(all[n].position.w)
                if tile >= 0 { index[tile, default: []].append(Int32(n)) }
            }
        }
        roadArt.allByTile = index
        return index
    }

    /// The plants, rocks, scatter and herds whose foot lies on a tile's road (this tile's and its
    /// neighbours' decorations), and the hills' relief (a mound, a knoll, with their shadows;
    /// never on a mountain tile) that would hide the road where it could not get round: the road
    /// cuts through there, and the ground keeps the hill's shading. Never resource icons or a
    /// mine's entrance.
    private func roadClearings(tile i: Int, centre c: SIMD2<Float>, points: [SIMD4<Float>]) -> [Int32] {
        guard let buffer = decorationBuffer, points.count > 1 else { return [] }
        let all = buffer.contents().assumingMemoryBound(to: SpriteInstance.self)
        let s = Float(layout.size), width = Float(layout.worldWidth), clear = s * 0.19
        let byTile = decorationsByTile()
        let hex = state.map.coord(at: i)
        var tiles = [i]
        for direction in HexDirection.allCases {
            if let n = state.map.normalize(hex.neighbor(direction)), let t = state.map.index(of: n) { tiles.append(t) }
        }
        var out: [Int32] = []
        // Per tile, the one mound that hides the road most: its foot and how close.
        var worst: [Int: (foot: SIMD2<Float>, gap: Float)] = [:]
        for t in tiles {
            for index in byTile[t] ?? [] {
                let d = all[Int(index)]
                let bits = UInt32(d.flags.w)
                guard bits & DecorFlags.resource == 0, bits >> 15 & 15 != UInt32(Improvement.mine.rawValue) else { continue }
                let relief = bits & DecorFlags.relief != 0
                if relief, d.sizeAnchor.x > s * 2 || state.map[index: t].elevation == .mountains { continue }
                var p = SIMD2(d.position.x, d.position.y) - c
                if layout.wrapsX { p.x -= (p.x / width).rounded() * width }
                guard simd_length(p) < s * 1.2 else { continue }
                func nearest(_ q: SIMD2<Float>) -> Float {
                    var best = Float.infinity
                    for j in 0..<(points.count - 1) where points[j].w == points[j + 1].w {
                        let a = SIMD2(points[j].x, points[j].y), b = SIMD2(points[j + 1].x, points[j + 1].y)
                        let ab = b - a, h = simd_clamp(simd_dot(q - a, ab) / max(simd_dot(ab, ab), 1e-8), 0, 1)
                        best = min(best, simd_length(q - a - ab * h))
                    }
                    return best
                }
                if relief {
                    // A mound hides the ground from its foot back to about a third of its
                    // width behind it, most of all in its middle third.
                    guard d.flags.x > 0.5 else { continue }
                    let w = d.sizeAnchor.x
                    let gap = [0.05, 0.18, 0.3].map { nearest(p + SIMD2(0, w * $0)) }.min()! - w * 0.18
                    if gap < s * 0.03, gap < worst[t]?.gap ?? .infinity { worst[t] = (p, gap) }
                } else if nearest(p) < clear {
                    out.append(index)
                }
            }
        }
        // The mounds cut, with their shadows (which share the foot): at most one a tile, so a
        // hill keeps its others and still reads as a hill.
        for (t, cut) in worst {
            for index in byTile[t] ?? [] {
                let d = all[Int(index)]
                guard UInt32(d.flags.w) & DecorFlags.relief != 0 else { continue }
                var p = SIMD2(d.position.x, d.position.y) - c
                if layout.wrapsX { p.x -= (p.x / width).rounded() * width }
                if simd_length(p - cut.foot) < 1e-3 * s { out.append(index) }
            }
        }
        return out
    }

    /// Hides the decorations in `wanted` (and shows again those no longer on a road), through
    /// their flag in the decoration buffer (`DecorFlags.roadCleared`).
    private func clearRoadDecorations(_ wanted: Set<Int32>) {
        guard wanted != roadArt.cleared, let buffer = decorationBuffer else { return }
        let all = buffer.contents().assumingMemoryBound(to: SpriteInstance.self)
        let bit = DecorFlags.roadCleared
        for index in roadArt.cleared.subtracting(wanted) {
            all[Int(index)].flags.w = Float(UInt32(all[Int(index)].flags.w) & ~bit)
        }
        for index in wanted.subtracting(roadArt.cleared) {
            all[Int(index)].flags.w = Float(UInt32(all[Int(index)].flags.w) | bit)
        }
        roadArt.cleared = wanted
    }

    /// The explored road tiles and, per tile, the edges its road crosses (a bit per
    /// `HexDirection`): one to each explored road tile beside it, except across a triangle. Where
    /// three road tiles all touch one another, linking every pair closes a little loop; instead
    /// the link between the two lesser tiles is left out and both reach each other through the
    /// third, the one with the most road neighbours (ties: the lowest tile index). A link left
    /// out is always replaced by a way through a greater tile, so every road that joins still
    /// joins, and a cluster of road tiles (a city's) reads as roads from its hub, not a web.
    /// A known city's tile counts as a road (roads lead into cities, not past them) and is the
    /// hub before any other.
    func roadLinks() -> [Int: Int] {
        let roads = inputs.roads
        guard roads.contains(true) else { return [:] }
        let cities = Set(inputs.cities.compactMap { state.map.normalize($0.hex).flatMap(state.map.index(of:)) })
        func road(_ i: Int) -> Bool { (i < roads.count && roads[i]) || cities.contains(i) }
        let directions = HexDirection.allCases
        // Explored road tiles, and each one's neighbours there by direction.
        var neighbours: [Int: [Int?]] = [:]
        for i in 0..<state.map.tileCount where road(i) {
            let hex = state.map.coord(at: i)
            guard fogLevel(hex) < 2 else { continue }
            neighbours[i] = directions.map { direction in
                guard let nh = state.map.normalize(hex.neighbor(direction)), let n = state.map.index(of: nh), road(n),
                      fogLevel(nh) < 2 else { return nil }
                return n
            }
        }
        func rank(_ i: Int) -> (Int, Int, Int) { (cities.contains(i) ? 1 : 0, neighbours[i]?.compactMap { $0 }.count ?? 0, -i) }
        var links: [Int: Int] = [:]
        for (i, around) in neighbours {
            var mask = 0
            for (b, j) in around.enumerated() {
                guard let j else { continue }
                // The two tiles beside both i and j lie one step either side of j round i.
                let cut = [around[(b + 5) % 6], around[(b + 1) % 6]].contains { k in
                    guard let k else { return false }
                    return rank(k) > rank(i) && rank(k) > rank(j)
                }
                if !cut { mask |= 1 << b }
            }
            links[i] = mask
        }
        return links
    }

    /// The pillaged improvements' marks, flat on the ground on their tiles' north side, over the
    /// bases (with the job marks).
    func appendPillagedMarks(into sprites: inout [SpriteInstance], table: UnitAtlasTable) {
        guard !inputs.pillaged.isEmpty, let uv = table.pillaged else { return }
        let s = Float(layout.size), scale = camera.scale, camX = CGFloat(camera.target.x)
        let disc = Self.jobBadgePoints(tileWidthPoints: s * 1.7320508 / max(scale, 1e-3)) * scale
        let edge = disc / UnitSprite.badgeDisc
        for hex in inputs.pillaged where fogLevel(hex) < 2 {
            let c = layout.center(of: hex)
            let x = Float(layout.nearestCopy(of: c.x, to: camX)), y = Float(c.y) + s * 0.55
            sprites.append(SpriteInstance(position: [x, y, 0, -1], sizeAnchor: [edge, edge, 0.5, 0.5], uv: uv,
                                          tint: [1, 1, 1, 1], flags: [0, UnitSpriteKind.sprite.rawValue, 0, 0]))
        }
    }
}
