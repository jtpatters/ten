import CoreGraphics
import GameCore
import simd

// Roads and pillaged improvements (M2 §3.3), as the App passes them from the viewer's
// knowledge: roads as remembered (`PlayerView.tile(at:)`), pillaged improvements only where in
// sight. Nothing is drawn on an unexplored tile.
//
// - A road is a band of packed earth on the ground (the overlay pipeline, drawn before the units'
//   bases and the decorations, so plants and relief stand on it), painted per road tile by the
//   overlay shader (`overlayRoad` in `ShaderOverlay.swift`) from which of its
//   edges it shares with another explored road tile. It crosses each such edge at its middle,
//   square to the edge, so neighbouring tiles' halves meet seamlessly: straight through the tile
//   between opposite edges, on a circular arc between any other two (a gentle bend, or a tight one
//   round a corner), and through a junction as straight through-roads with branches joining them,
//   their joins filleted into a worn crossing. A dead end stops in the middle of its tile; a lone
//   road is a short band across its centre. Out of sight it takes the explored-fog look.
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

    /// Each explored road tile's hexagon, as four triangles (`OverlayStyle.road`): the shader
    /// paints the road from the tile's links.
    private func makeRoads() -> [OverlayVertex] {
        let roads = inputs.roads
        guard roads.contains(true) else { return [] }
        let s = Float(layout.size), halfX = s * 0.8660254, style = OverlayStyle.road.rawValue
        var out: [OverlayVertex] = []
        func road(_ i: Int) -> Bool { i < roads.count && roads[i] }
        for i in 0..<state.map.tileCount where road(i) {
            let hex = state.map.coord(at: i), fog = fogLevel(hex)
            guard fog < 2 else { continue }
            let c = Self.vec(layout.center(of: hex)), dim: Float = fog == 1 ? 1 : 0
            var links = 0
            for (bit, direction) in HexDirection.allCases.enumerated() {
                guard let nh = state.map.normalize(hex.neighbor(direction)), let n = state.map.index(of: nh), road(n),
                      fogLevel(nh) < 2 else { continue }
                links |= 1 << bit
            }
            let terrain = Float(state.map[index: i].terrain.rawValue)
            func vertex(_ dx: Float, _ dy: Float) -> OverlayVertex {
                OverlayVertex(position: [c.x + dx, c.y + dy, 0, style], color: [dx, dy, Float(links), 0], aux: [0, dim, terrain, 0])
            }
            // The hexagon (pointy-top) as four triangles.
            let top = vertex(0, s), bottom = vertex(0, -s)
            let upperLeft = vertex(-halfX, s / 2), upperRight = vertex(halfX, s / 2)
            let lowerLeft = vertex(-halfX, -s / 2), lowerRight = vertex(halfX, -s / 2)
            out += [top, upperLeft, upperRight, upperLeft, lowerLeft, upperRight, upperRight, lowerLeft, lowerRight,
                    lowerLeft, bottom, lowerRight]
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
