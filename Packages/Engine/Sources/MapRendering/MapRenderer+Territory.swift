import CoreGraphics
import GameCore
import Metal
import simd

// Territory, improvements, the movement range and the settler scores (M1 §15): the inputs
// that live in spare bits of the tile texture (`TileInfo` in `ShaderCommon.swift`), so the
// ground and decoration shaders read them with the tile they already fetch, and the borders
// and the movement range's outline, built here as overlay ribbons whenever what they depend on
// changes (`ShaderOverlay.swift` shades them).
//
// Fog: everything follows the viewer's knowledge as the App passes it in, and nothing is drawn
// on an unexplored tile: the shaders test the fog bits, and a border edge is drawn only when
// the tiles on both sides are explored (ART.md §8).

/// The tile texture's input bits (`MapRenderer.tileBytes`, four bytes per tile).
enum TileBits {
    /// Byte 0: the territory owner's style index + 1 (0 none).
    static let ownerShift: UInt8 = 3
    static let ownerMask: UInt8 = 0x78
    /// Byte 1: the `Improvement` raw value's low three bits (0 none); byte 0: its bit 3.
    static let improvementShift: UInt8 = 5
    static let improvementMask: UInt8 = 0xE0
    static let improvementHigh: UInt8 = 0x80
    /// Byte 2: the viewer knows the tile's resource (`setResources`).
    static let resourceKnown: UInt8 = 0x80
    /// Byte 3: in the movement range.
    static let range: UInt8 = 0x04
    /// Byte 3: a tribal village's tile (known, or a taken one's ghost still fading): the plants
    /// standing on it hide (`kTileTribalVillageBit`, `decor_vertex`).
    static let tribalVillage: UInt8 = 0x08
    /// Byte 3: the settler score tier, 0 none, 1 (poor) ... 7 (best).
    static let scoreShift: UInt8 = 4
    static let scoreMask: UInt8 = 0x70
}

/// The overlay ribbons for borders and the movement range's outline, cached until the inputs
/// or the fog they depend on change. `MapRenderer` stores one as `territoryArt`.
struct TerritoryArtState {
    /// Bumped by `setTerritory`, and by `setMovementRange` and `setSelection`.
    var territoryVersion = 0
    var rangeVersion = 0
    var borders: [OverlayVertex] = []
    var bordersKey: SIMD2<Int>?
    var range: [OverlayVertex] = []
    var rangeKey: SIMD2<Int>?
}

extension MapRenderer {
    // MARK: Tile bits

    /// Writes `value(i) & mask` into byte `byte` (0-3) of every tile, keeping its other bits.
    private func writeTileBits(byte: Int, mask: UInt8, _ value: (Int) -> UInt8) {
        var changed = false
        for i in 0..<state.map.tileCount {
            let old = tileBytes[i * 4 + byte]
            let new = (old & ~mask) | (value(i) & mask)
            if new != old {
                tileBytes[i * 4 + byte] = new
                changed = true
            }
        }
        if changed { tileVersion += 1 }
    }

    /// The tile indices of a list of hexes (off-map hexes dropped).
    func tileIndices(_ hexes: [HexCoord]) -> Set<Int> {
        Set(hexes.compactMap { state.map.normalize($0).flatMap(state.map.index(of:)) })
    }

    /// Territory owners into the tile texture: a player's style index + 1 (players beyond the
    /// eight styles share them, as everywhere else: `Palette.player`).
    func writeTerritoryBits() {
        let owners = inputs.territory
        writeTileBits(byte: 0, mask: TileBits.ownerMask) { i in
            guard i < owners.count, owners[i] != 0 else { return 0 }
            return UInt8(Palette.styleIndex(Int(owners[i]) - 1) + 1) << TileBits.ownerShift
        }
        territoryArt.territoryVersion += 1
    }

    func writeImprovementBits() {
        let kinds = inputs.improvements
        writeTileBits(byte: 1, mask: TileBits.improvementMask) { i in
            guard i < kinds.count else { return 0 }
            return (kinds[i] & 7) << TileBits.improvementShift
        }
        writeTileBits(byte: 0, mask: TileBits.improvementHigh) { i in
            i < kinds.count && kinds[i] & 8 != 0 ? TileBits.improvementHigh : 0
        }
    }

    func writeResourceBits() {
        let kinds = inputs.resources
        writeTileBits(byte: 2, mask: TileBits.resourceKnown) { i in i < kinds.count && kinds[i] != 0 ? TileBits.resourceKnown : 0 }
    }

    func writeRangeBits() {
        let tiles = tileIndices(inputs.movementRange)
        writeTileBits(byte: 3, mask: TileBits.range) { tiles.contains($0) ? TileBits.range : 0 }
        territoryArt.rangeVersion += 1
    }

    /// Scores 1...255 fall into seven tiers (1 + score · 7 / 256), 0 stays none.
    func writeScoreBits() {
        let scores = inputs.tileScores
        writeTileBits(byte: 3, mask: TileBits.scoreMask) { i in
            guard i < scores.count, scores[i] != 0 else { return 0 }
            let tier = UInt8(1 + Int(scores[i]) * 7 / 256)
            return tier << TileBits.scoreShift
        }
    }

    /// The tribal villages' tiles into the tile texture (`TileBits.tribalVillage`): the known
    /// ones and the ghosts still fading (`tribalVillageTiles`). Only this bit is touched, as
    /// `setCities` touches only the city centres' (`markCityCentres`), so neither setter undoes
    /// the other.
    func writeTribalVillageBits() {
        let tiles = tribalVillageTiles()
        writeTileBits(byte: 3, mask: TileBits.tribalVillage) { tiles.contains($0) ? TileBits.tribalVillage : 0 }
    }

    /// Whether the viewer has explored tile `i` (always with the fog off).
    private func explored(_ i: Int) -> Bool { tileBytes[i * 4 + 3] & 3 != 2 }

    /// The world centres of the farms the viewer knows (explored tiles), where the ground draws
    /// its fields variant (`kGroundFields`): rebuilt when the tile texture changes. No buffer
    /// when there are none.
    func knownFarmCenters() -> (buffer: MTLBuffer?, count: Int) {
        if farmCentersVersion != tileVersion {
            var centers: [SIMD2<Float>] = []
            let farm = Improvement.farm.rawValue << TileBits.improvementShift
            for i in 0..<state.map.tileCount where tileBytes[i * 4 + 1] & TileBits.improvementMask == farm && tileBytes[i * 4] & TileBits.improvementHigh == 0 && explored(i) {
                centers.append(Self.vec(layout.center(of: state.map.coord(at: i))))
            }
            farmCentersBuffer = centers.isEmpty ? nil
                : device.makeBuffer(bytes: centers, length: MemoryLayout<SIMD2<Float>>.stride * centers.count, options: .storageModeShared)
            farmCentersCount = centers.count
            farmCentersVersion = tileVersion
        }
        return (farmCentersBuffer, farmCentersCount)
    }

    // MARK: Ribbons

    /// This frame's border and range-outline ribbons, rebuilt only when their inputs or the
    /// fog changed.
    func territoryGeometry() -> [OverlayVertex] {
        let borderKey = SIMD2(territoryArt.territoryVersion, fogVersion)
        if territoryArt.bordersKey != borderKey {
            territoryArt.borders = makeBorders()
            territoryArt.bordersKey = borderKey
        }
        let rangeKey = SIMD2(territoryArt.rangeVersion, fogVersion)
        if territoryArt.rangeKey != rangeKey {
            territoryArt.range = makeRangeOutline()
            territoryArt.rangeKey = rangeKey
        }
        return territoryArt.borders + territoryArt.range
    }

    /// Borders: along every edge between an owned tile and a tile of another owner (or none),
    /// both explored, a band on the owned side in the owner's colour and ring pattern (two
    /// owners side by side each draw their own). Edges are chained into one polyline per
    /// stretch of border, so the pattern runs on around corners.
    private func makeBorders() -> [OverlayVertex] {
        let edges = borderEdges().map { e in
            edge(of: e.tile, direction: e.direction, group: e.group, dim: tileBytes[e.tile * 4 + 3] & 3 == 1 ? 1 : 0)
        }
        return ribbons(edges, style: .border)
    }

    /// The border's edges: the owned tile, the direction of the edge (`HexDirection` order)
    /// and the owner's style index. Edges at the map's north and south ends have no tile beyond
    /// and draw nothing.
    func borderEdges() -> [(tile: Int, direction: Int, group: Int)] {
        let owners = inputs.territory
        guard owners.contains(where: { $0 != 0 }) else { return [] }
        func owner(_ i: Int) -> Int { i < owners.count && owners[i] != 0 ? Palette.styleIndex(Int(owners[i]) - 1) + 1 : 0 }
        var edges: [(tile: Int, direction: Int, group: Int)] = []
        for i in 0..<state.map.tileCount {
            let o = owner(i)
            guard o != 0, explored(i) else { continue }
            let hex = state.map.coord(at: i)
            for (d, direction) in HexDirection.allCases.enumerated() {
                guard let n = state.map.normalize(hex.neighbor(direction)).flatMap(state.map.index(of:)), explored(n),
                      owner(n) != o else { continue }
                edges.append((i, d, o - 1))
            }
        }
        return edges
    }

    /// The movement range's outline: around the tiles in range (and the selected unit's own
    /// tile), explored ones only.
    private func makeRangeOutline() -> [OverlayVertex] {
        var region = tileIndices(inputs.movementRange).filter(explored)
        guard !region.isEmpty else { return [] }
        if inputs.selectionKind == .unit, let selected = unitArt.selection, let i = state.map.index(of: selected) { region.insert(i) }
        var edges: [RibbonEdge] = []
        for i in region.sorted() {
            let hex = state.map.coord(at: i)
            for (d, direction) in HexDirection.allCases.enumerated() {
                if let n = state.map.normalize(hex.neighbor(direction)).flatMap(state.map.index(of:)), region.contains(n) { continue }
                edges.append(edge(of: i, direction: d, group: 0, dim: 0))
            }
        }
        return ribbons(edges, style: .rangeEdge)
    }

    /// One hex edge of a region's outline, walked counter-clockwise around its tile (the
    /// region on the left): from corner 5 - d to corner 6 - d (corner k at 30° + 60°·k).
    private struct RibbonEdge {
        var from: SIMD2<Float>
        var to: SIMD2<Float>
        var fromKey: Int
        var toKey: Int
        var group: Int
        var dim: Float
    }

    private func edge(of i: Int, direction d: Int, group: Int, dim: Float) -> RibbonEdge {
        let c = Self.vec(layout.center(of: state.map.coord(at: i)))
        let s = Float(layout.size)
        func corner(_ k: Int) -> SIMD2<Float> {
            let a = (30 + 60 * Float(k)) * .pi / 180
            return c + SIMD2(cos(a), sin(a)) * s
        }
        let a = corner((5 - d + 6) % 6), b = corner((6 - d) % 6)
        return RibbonEdge(from: a, to: b, fromKey: cornerKey(a), toKey: cornerKey(b), group: group, dim: dim)
    }

    /// A corner's identity: its position on the lattice of half tile widths and half sizes,
    /// wrapped east–west.
    private func cornerKey(_ p: SIMD2<Float>) -> Int {
        var x = Int((p.x / Float(layout.tileWidth) * 2).rounded())
        let y = Int((p.y / Float(layout.size) * 2).rounded())
        if layout.wrapsX { x = ((x % (2 * layout.mapWidth)) + 2 * layout.mapWidth) % (2 * layout.mapWidth) }
        return (y + 4) * 8192 + x + 2
    }

    /// Chains edges into polylines (each corner has at most one edge leaving it per group, so
    /// chains never fork) and turns them into ribbon triangles: two vertices per corner, at
    /// the corner itself with its miter direction into the region, which the vertex shader
    /// scales to the band's inset and width at the current zoom. `color` is (across: +1 at
    /// the edge's side, -1 inside; along: edges from the chain's start; miter x, y), `aux` is
    /// (group, dim, the chain's first along, its last; ±1e6 for a closed loop, which fades
    /// nowhere).
    private func ribbons(_ edges: [RibbonEdge], style: OverlayStyle) -> [OverlayVertex] {
        guard !edges.isEmpty else { return [] }
        var leaving: [Int: Int] = [:]
        for (k, e) in edges.enumerated() { leaving[e.fromKey &* 16 &+ e.group] = k }
        var incoming = [Bool](repeating: false, count: edges.count)
        for e in edges { if let k = leaving[e.toKey &* 16 &+ e.group] { incoming[k] = true } }
        var used = [Bool](repeating: false, count: edges.count)
        var out: [OverlayVertex] = []
        out.reserveCapacity(edges.count * 6)
        func chain(from start: Int) {
            var list: [Int] = []
            var k: Int? = start
            while let current = k, !used[current] {
                used[current] = true
                list.append(current)
                k = leaving[edges[current].toKey &* 16 &+ edges[current].group]
            }
            let closed = k == start
            out += ribbon(list.map { edges[$0] }, closed: closed, style: style)
        }
        for k in edges.indices where !incoming[k] && !used[k] { chain(from: k) }
        for k in edges.indices where !used[k] { chain(from: k) }
        return out
    }

    private func ribbon(_ chain: [RibbonEdge], closed: Bool, style: OverlayStyle) -> [OverlayVertex] {
        guard let first = chain.first else { return [] }
        // Corners, unwrapped so the chain never jumps across the world's seam.
        var points = [first.from]
        for e in chain {
            let last = points[points.count - 1]
            let x = Float(layout.nearestCopy(of: CGFloat(e.to.x), to: CGFloat(last.x)))
            points.append([x, e.to.y])
        }
        // A loop all the way around the world does not meet itself again: drawn as open
        // without fading.
        let loops = closed && simd_distance(points[0], points[points.count - 1]) < 1
        let around = closed && !loops
        let n = chain.count
        func left(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
            let v = simd_normalize(b - a)
            return SIMD2(-v.y, v.x)
        }
        var miters: [SIMD2<Float>] = []
        var dims: [Float] = []
        for k in 0...n {
            let inNormal: SIMD2<Float>? = k > 0 ? left(points[k - 1], points[k]) : (loops ? left(points[n - 1], points[n]) : nil)
            let outNormal: SIMD2<Float>? = k < n ? left(points[k], points[k + 1]) : (loops ? left(points[0], points[1]) : nil)
            let m: SIMD2<Float>
            if let a = inNormal, let b = outNormal {
                let mid = simd_normalize(a + b)
                m = mid / max(simd_dot(mid, b), 0.5)
            } else {
                m = inNormal ?? outNormal ?? .zero
            }
            miters.append(m)
            let before = k > 0 ? chain[k - 1].dim : (loops ? chain[n - 1].dim : chain[0].dim)
            let after = k < n ? chain[k].dim : (loops ? chain[0].dim : chain[n - 1].dim)
            dims.append((before + after) / 2)
        }
        let a0: Float = loops || around ? -1e6 : 0, a1: Float = loops || around ? 1e6 : Float(n)
        let group = Float(first.group)
        func vertex(_ k: Int, _ across: Float) -> OverlayVertex {
            OverlayVertex(position: [points[k].x, points[k].y, 0, style.rawValue], color: [across, Float(k), miters[k].x, miters[k].y],
                          aux: [group, dims[k], a0, a1])
        }
        var out: [OverlayVertex] = []
        out.reserveCapacity(n * 6)
        for k in 0..<n {
            let a = vertex(k, 1), b = vertex(k, -1), c = vertex(k + 1, 1), d = vertex(k + 1, -1)
            out += [a, b, c, c, b, d]
        }
        return out
    }
}
