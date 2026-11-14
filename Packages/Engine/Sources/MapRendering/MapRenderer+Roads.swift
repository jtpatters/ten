import CoreGraphics
import GameCore
import simd

// Roads and pillaged improvements (M2 §3.3), as the App passes them from the viewer's
// knowledge: roads as remembered (`PlayerView.tile(at:)`), pillaged improvements only where in
// sight. Nothing is drawn on an unexplored tile.
//
// - A road is a packed-earth band on the ground (the overlay pass, under the borders): from each
//   road tile's centre to the middle of every edge it shares with another explored road tile,
//   so neighbouring halves meet; a lone road is a short band across its centre. Out of sight it
//   takes the explored-fog look.
// - A pillaged improvement gets a mark, a flame on a cream disc in a red rim, on its tile's north
//   side, drawn by the unit pass with the job marks.

/// The road ribbons, cached until the roads or the fog change (`MapRenderer.roadArt`).
struct RoadArtState {
    /// Bumped by `setRoads`.
    var version = 0
    var key: SIMD2<Int>?
    var ribbons: [OverlayVertex] = []
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

    /// A road's half width (world units).
    static func roadHalfWidth(size: Float) -> Float { size * 0.085 }

    private func makeRoads() -> [OverlayVertex] {
        let roads = inputs.roads
        guard roads.contains(true) else { return [] }
        let s = Float(layout.size), half = Self.roadHalfWidth(size: s)
        var out: [OverlayVertex] = []
        func band(_ a: SIMD2<Float>, _ b: SIMD2<Float>, dim: Float) {
            let d = simd_normalize(b - a), n = SIMD2(-d.y, d.x) * half
            let start = a - d * half * 0.7, length = simd_distance(start, b)
            func vertex(_ p: SIMD2<Float>, _ across: Float, _ along: Float) -> OverlayVertex {
                OverlayVertex(position: [p.x, p.y, 0, OverlayStyle.road.rawValue], color: [across, along, 0, 0], aux: [0, dim, 0, 0])
            }
            let v0 = vertex(start + n, 1, 0), v1 = vertex(start - n, -1, 0)
            let v2 = vertex(b + n, 1, length), v3 = vertex(b - n, -1, length)
            out += [v0, v1, v2, v2, v1, v3]
        }
        func road(_ i: Int) -> Bool { i < roads.count && roads[i] }
        for i in 0..<state.map.tileCount where road(i) {
            let hex = state.map.coord(at: i), fog = fogLevel(hex)
            guard fog < 2 else { continue }
            let c = Self.vec(layout.center(of: hex)), dim: Float = fog == 1 ? 1 : 0
            var linked = false
            for direction in HexDirection.allCases {
                guard let nh = state.map.normalize(hex.neighbor(direction)), let n = state.map.index(of: nh), road(n),
                      fogLevel(nh) < 2 else { continue }
                linked = true
                var nc = Self.vec(layout.center(of: nh))
                nc.x = Float(layout.nearestCopy(of: CGFloat(nc.x), to: CGFloat(c.x)))
                band(c, (c + nc) / 2, dim: dim)
            }
            if !linked { band(c - [s * 0.3, 0], c + [s * 0.3, 0], dim: dim) }
        }
        return out
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
