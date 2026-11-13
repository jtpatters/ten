import CoreGraphics
import GameCore
import simd

extension MapRenderer {
    /// Every decoration (mountains, hills, trees, plants, rocks, and the shadows they cast on
    /// the ground) as sprite instances, built once at startup and sorted for drawing. See
    /// `DecorPlacer` for the rules.
    static func makeDecorations(map: HexMap, layout: HexLayout, atlas: SpriteAtlas<DecorSprite>) -> [SpriteInstance] {
        var placer = DecorPlacer(map: map, layout: layout, atlas: atlas)
        placer.placeAll()
        return placer.sorted()
    }

    /// Where relief stands, for the ground to shade beneath it: one splat per summit, massif,
    /// butte, hill or knoll the decorations place (the same deterministic placement, without
    /// the atlas): x and y of the middle of its base and its radius (world units), and its
    /// crest height relative to the tallest relief (crest / two tile sizes, 0...1). No splat
    /// reaches more than 0.65 tile sizes outside its own tile.
    static func reliefFootprints(map: HexMap, layout: HexLayout) -> [SIMD4<Float>] {
        var placer = DecorPlacer(map: map, layout: layout, atlas: nil)
        placer.placeAll(reliefOnly: true)
        return placer.footprints
    }
}

/// Instance flags.w for decorations (see `ShaderDecor.swift`): bits 0-1 wind response, bits
/// 2-3 level-of-detail class, bits 4-11 a per-instance random byte (sway phase, fade order),
/// bit 12 marks a cast shadow, bit 13 a tree that grows a little as the secondary trees around
/// it fade out at strategic zoom, so woods keep their mass instead of turning to speckle, bit
/// 14 relief, bits 15-16 the improvement an instance needs, bit 17 open-land clutter that
/// clears from improved tiles. (The flags travel as a Float: exact up to bit 23.)
enum DecorFlags {
    enum Wind: UInt32 { case none = 0, tree, grass, palm }
    /// 0: always drawn; 1: small scatter, gone by the strategic zoom; 2: secondary trees that
    /// thin out at the strategic zoom.
    enum Detail: UInt32 { case always = 0, scatter, secondary }
    static let shadow: UInt32 = 1 << 12
    static let grows: UInt32 = 1 << 13
    /// Relief (hills, summits and the snow on them) and its shadows. A city centre hides its
    /// own tile's relief with everything else, but a neighbour's relief reaching onto it stays,
    /// unlike other straddling sprites (`decor_vertex`).
    static let relief: UInt32 = 1 << 14
    /// Shown only while the tile has this improvement (as the viewer knows it): a mine's
    /// entrance and spoil, a pasture's herd. Placed on every tile that could take one, so
    /// building or losing an improvement never rebuilds the decorations.
    static func needs(_ improvement: Improvement) -> UInt32 { UInt32(improvement.rawValue) &<< 15 }
    /// Open-land scatter and landmarks: hidden on farms and mines, thinned on pastures.
    static let clears: UInt32 = 1 << 17

    static func pack(_ wind: Wind, _ detail: Detail, random: UInt32, extra: UInt32 = 0) -> Float {
        Float(wind.rawValue | detail.rawValue &<< 2 | (random & 255) &<< 4 | extra)
    }
}

/// Placement rules (deterministic: all randomness hashes lattice indices, tile indices and
/// world positions, never a shared RNG stream, so nothing depends on visit order).
///
/// - Mountains are composed as ranges, not stamped per tile: summits stand on a jittered
///   world-space lattice (about 0.6 of a tile apart, its rows gently undulating so they never
///   run along the map's rows) wherever it falls on a mountain tile, so a range flows across
///   tile edges. Heights come from world noise (a broad massif field and ridged spine lines
///   along which the tallest, snow-capped summits gather), never from the size or border of
///   the range; a few hero summits (at most one per coarse world cell of about seven tiles)
///   tower over the rest, and the summits around a hero step down. Silhouettes follow a
///   three-colouring of the lattice, so neighboring summits never share one, and every summit
///   is scaled in width and height separately (never mirrored: the light is one-sided). Broad
///   low shoulders fill the gaps between summits; foothills step down to open land. Rock style
///   follows the tile's terrain and a world climate field (latitude and slow noise): alpine,
///   frozen, dry ochre. Desert mountains are broad, overlapping massifs (tiered mesas, cliff
///   ridges, cuestas) on a coarser lattice, with tall buttes and spires as accents.
/// - Hills: chains of one to three asymmetric mounds per tile along a world ridge-direction
///   field (a main mound and smaller companions, each scaled in width and height separately),
///   sometimes a rocky knoll beside them, and bridge mounds over edges shared with other
///   hills. Tundra hills carry patches of lingering snow, placed per hill.
/// - Woods: trees on a world-space jittered grid, so a forest flows across tile edges; thinner
///   toward the nearest edge when it faces open land or water; low-frequency clearings; trees
///   shortened (or shrubs) where they would stand up into the tile behind on screen, unless
///   the woods continue there; biome-specific species; river banks kept clear. Wooded hills
///   show their hills first: one or two big sunlit mounds with a thinned canopy of shorter
///   trees standing on their flanks, lit on the west and cooler on the east.
/// - Marsh reeds, oasis palms, river-bank reeds on floodplains, and open-land scatter in world
///   clusters (patches of groups, empty stretches between), kept off tile centers (units),
///   rivers and shores.
///
/// Fog: a tile's decorations depend only on the tile itself and on world fields. Anything
/// that depends on a neighbor (bridges, foothills, full-size trees at a forest's north edge,
/// tree shadows over open land) straddles the edge and shows only once that neighbor is
/// revealed, and its shadow stays out of the tile's shadow balancing; anything left out
/// because of a neighbor (thinned edge trees, short trees replaced by tall ones, scatter near
/// a shore) stays as a stand-in while the neighbor is unexplored.
///
/// Startup cost matters (it runs on every renderer setup, and tests run unoptimized), so the
/// per-tree path sticks to scalar math, table lookups and while loops.
struct DecorPlacer {
    let map: HexMap
    let layout: HexLayout
    /// False when only measuring relief (`reliefFootprints`): no atlas, no instances.
    private let drawing: Bool
    private let s: Float
    private let apothem: Float
    /// Trimmed quads per `DecorArt.code`: the whole image, and the part above its foot (which
    /// is what casts a shadow).
    private var quads: [Quad]
    private var shadowQuads: [Quad]
    private var instances: [SpriteInstance] = []
    private var shadows: [SpriteInstance] = []
    /// Shadows of sprites that exist because of a neighbor (foothills, bridges, edge trees):
    /// kept out of the per-tile balancing, so the other shadows never change with what lies
    /// beyond an unexplored edge.
    private var looseShadows: [SpriteInstance] = []
    private(set) var footprints: [SIMD4<Float>] = []

    // World-space grid for trees: square-ish cells, a whole number per world period.
    private let gridX: Float
    private let gridY: Float
    private let gridColumns: Int
    // Jittered lattices for summits, desert massifs, hero summits and scatter groups.
    private let summitGrid: Grid
    private let massifGrid: Grid
    private let heroGrid: Grid
    private let groupGrid: Grid
    // Noise lattices that tile the world width exactly (so they wrap without a seam).
    private let clearingNoise: Lattice
    private let pineNoise: Lattice
    private let massifNoise: Lattice
    private let spineNoise: Lattice
    private let ridgeNoise: Lattice
    private let climateNoise: Lattice
    private let aridNoise: Lattice
    private let patchNoise: Lattice

    private struct Lattice {
        let cell: Float
        let period: Int

        init(worldWidth: Float, cell: Float) {
            period = max(1, Int((worldWidth / cell).rounded()))
            self.cell = worldWidth / Float(period)
        }
    }

    /// Rows of points `dx` apart, every other row shifted half a step (a triangular lattice
    /// when `dy` = 0.866 `dx`). The column count is a multiple of six, so the three-colouring
    /// and the jitter pairs wrap with the world. The rows may undulate (`wave`, a share of a
    /// row, over a whole number of wavelengths per world), so they never run along the map's
    /// rows of tiles.
    private struct Grid {
        let columns: Int
        let dx: Float
        let dy: Float
        let amplitude: Float
        let frequency: Float

        init(worldWidth: Float, spacing: Float, rows: Float = 0.8660254, wave: Float = 0, wavelength: Float = 1) {
            columns = max(6, Int((worldWidth / spacing / 6).rounded()) * 6)
            dx = worldWidth / Float(columns)
            dy = dx * rows
            amplitude = wave * dy
            frequency = 2 * .pi * max(1, (worldWidth / wavelength).rounded()) / worldWidth
        }

        func wrap(_ gx: Int) -> Int { ((gx % columns) + columns) % columns }
        func x(_ gx: Int, _ gy: Int) -> Float { (Float(gx) + (gy & 1 == 0 ? 0 : 0.5)) * dx }
        /// Height of row `row` (fractional rows allowed) at `x`.
        func y(_ row: Float, at x: Float) -> Float { row * dy + (amplitude == 0 ? 0 : amplitude * sin(frequency * x)) }
        /// Three-colouring: lattice neighbors always differ.
        func colour(_ gx: Int, _ gy: Int) -> Int {
            let q = wrap(gx) - (gy - (gy & 1)) / 2
            return ((q - gy) % 3 + 3) % 3
        }
    }

    /// An image's quad trimmed to its painted pixels: atlas UVs, size in painter units (world
    /// size = size * height), and where the foot sits in it (from the left, from the bottom).
    private struct Quad {
        var uv: SIMD4<Float> = .zero
        var size: SIMD2<Float> = .zero
        var anchor: SIMD2<Float> = .zero

        init() {}

        init(_ art: DecorArt, cellUV: SIMD4<Float>, aboveFoot: Bool) {
            let l = DecorSprite.layout(of: art)
            var b = l.bounds
            if aboveFoot { b.size.height = max(1, l.foot.y - b.minY) }
            let cell = Float(art.cell.cellSize)
            uv = SIMD4(cellUV.x + Float(b.minX) / cell * cellUV.z, cellUV.y + Float(b.minY) / cell * cellUV.w,
                       Float(b.width) / cell * cellUV.z, Float(b.height) / cell * cellUV.w)
            size = SIMD2(Float(b.width / l.unit), Float(b.height / l.unit))
            anchor = SIMD2(Float((l.foot.x - b.minX) / b.width), Float((b.maxY - l.foot.y) / b.height))
        }
    }

    /// A placed hill or knoll, so trees and snow can be set on its face: its foot, its scale
    /// (world units per painter unit, vertically), its horizontal stretch and its image's
    /// relief.
    private struct Mound {
        var foot: SIMD2<Float>
        var scale: Float
        var width: Float
        var relief: DecorRelief

        /// Half the span of the relief's profile (world units).
        var half: Float { relief.halfWidth * scale * width }
        /// How far the base reaches west and east of the foot (world units).
        var west: Float { relief.west * scale * width }
        var east: Float { relief.east * scale * width }
        /// Height of the skyline above the foot (world units), `dx` east of the foot.
        func face(_ dx: Float) -> Float { relief.height(at: dx / half) * scale }
    }

    private static let white = SIMD4<Float>(1, 1, 1, 1)
    private static let edgeNormals: [SIMD2<Float>] = [[1, 0], [0.5, -0.8660254], [-0.5, -0.8660254],
                                                      [-1, 0], [-0.5, 0.8660254], [0.5, 0.8660254]]
    private static let temperateBroadleaf = [0, 1, 2, 3, 5, 6, 0]
    private static let dryBroadleaf = [1, 6, 3, 2, 5]
    /// Screen-space rise of a world unit of height and of depth (toward the north) in the
    /// tilted view: things set on a hill's face are lifted by height so they land where the
    /// face is painted.
    /// (sin and cos of `MapRenderer.tiltPitch`, 0.6.)
    private static let riseOfHeight: Float = 0.5646425
    private static let riseOfDepth: Float = 0.8253356

    init(map: HexMap, layout: HexLayout, atlas: SpriteAtlas<DecorSprite>?) {
        self.map = map
        self.layout = layout
        drawing = atlas != nil
        s = Float(layout.size)
        apothem = s * 0.8660254
        quads = []
        shadowQuads = []
        if let atlas {
            quads = Array(repeating: Quad(), count: DecorArt.codeCount)
            shadowQuads = quads
            for art in DecorArt.all {
                let cellUV = atlas.uv(art.cell)
                quads[art.code] = Quad(art, cellUV: cellUV, aboveFoot: false)
                shadowQuads[art.code] = Quad(art, cellUV: cellUV, aboveFoot: true)
            }
            instances.reserveCapacity(map.tileCount * 4)
        }
        let width = Float(layout.worldWidth)
        gridColumns = max(1, Int((width / (s * 0.37)).rounded()))
        gridX = width / Float(gridColumns)
        gridY = gridX * 0.866
        summitGrid = Grid(worldWidth: width, spacing: s * 1.1, wave: 0.5, wavelength: s * 5.2)
        massifGrid = Grid(worldWidth: width, spacing: s * 1.45, wave: 0.4, wavelength: s * 9)
        heroGrid = Grid(worldWidth: width, spacing: s * 4.4, rows: 1)
        groupGrid = Grid(worldWidth: width, spacing: s * 1.4)
        clearingNoise = Lattice(worldWidth: width, cell: s * 2.6)
        pineNoise = Lattice(worldWidth: width, cell: s * 3.5)
        massifNoise = Lattice(worldWidth: width, cell: s * 6.5)
        spineNoise = Lattice(worldWidth: width, cell: s * 3.4)
        ridgeNoise = Lattice(worldWidth: width, cell: s * 5)
        climateNoise = Lattice(worldWidth: width, cell: s * 9)
        aridNoise = Lattice(worldWidth: width, cell: s * 8)
        patchNoise = Lattice(worldWidth: width, cell: s * 3.2)
    }

    // MARK: Order

    /// Cast shadows first (they lie on the ground, under everything standing), then the
    /// standing instances; each block far (north, larger y) to near, ties in placement order.
    func sorted() -> [SpriteInstance] {
        var out = Self.sortedByDepth(shadows + looseShadows)
        out += Self.sortedByDepth(instances)
        return out
    }

    /// A stable radix sort on order-preserving float bits of the anchor y, descending. Written
    /// with raw pointers and while loops, which stay cheap in unoptimized builds too (setup
    /// time is measured in debug test runs).
    private static func sortedByDepth(_ list: [SpriteInstance]) -> [SpriteInstance] {
        let n = list.count
        guard n > 1 else { return list }
        let keys = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        let order = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        let scratch = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: 257)
        defer {
            keys.deallocate()
            order.deallocate()
            scratch.deallocate()
            counts.deallocate()
        }
        list.withUnsafeBufferPointer { sprites in
            guard let base = sprites.baseAddress else { return }
            var k = 0
            while k < n {
                let bits = base[k].position.y.bitPattern
                keys[k] = bits & 0x8000_0000 != 0 ? bits : ~(bits | 0x8000_0000) // descending y
                order[k] = Int32(truncatingIfNeeded: k)
                k += 1
            }
        }
        var src = order, dst = scratch
        var shift: UInt32 = 0
        while shift < 32 {
            var b = 0
            while b < 257 { counts[b] = 0; b += 1 }
            var k = 0
            while k < n { counts[Int(keys[Int(src[k])] &>> shift & 255) + 1] += 1; k += 1 }
            b = 0
            while b < 256 { counts[b + 1] += counts[b]; b += 1 }
            k = 0
            while k < n {
                let bucket = Int(keys[Int(src[k])] &>> shift & 255)
                dst[counts[bucket]] = src[k]
                counts[bucket] += 1
                k += 1
            }
            swap(&src, &dst)
            shift += 8
        }
        // Four passes: the result is back in `order`.
        var out: [SpriteInstance] = []
        out.reserveCapacity(n)
        list.withUnsafeBufferPointer { sprites in
            guard let base = sprites.baseAddress else { return }
            var k = 0
            while k < n { out.append(base[Int(order[k])]); k += 1 }
        }
        return out
    }

    // MARK: Helpers

    /// Stateless hash in [0, 1) of two integers and a salt.
    private static func hash(_ a: Int, _ b: Int, _ salt: UInt32) -> Float {
        // Masking shifts (&>>) keep this cheap in unoptimized builds too.
        var h = UInt32(truncatingIfNeeded: a) &* 0x9E37_79B1 ^ UInt32(truncatingIfNeeded: b) &* 0x85EB_CA77 ^ salt &* 0xC2B2_AE3D
        h ^= h &>> 15
        h &*= 0x2C1B_3C6D
        h ^= h &>> 12
        h &*= 0x297A_2D39
        h ^= h &>> 15
        return Float(h & 0xFF_FFFF) * (1 / 16_777_216)
    }

    /// Smooth value noise in [0, 1) over the world, wrapping with the lattice's period.
    private static func noise(_ x: Float, _ y: Float, _ lattice: Lattice, salt: UInt32) -> Float {
        let qx = x / lattice.cell, qy = y / lattice.cell
        let fx0 = qx.rounded(.down), fy0 = qy.rounded(.down)
        let period = lattice.period
        let i0 = ((Int(fx0) % period) + period) % period, i1 = (i0 + 1) % period, j = Int(fy0)
        var u = qx - fx0, v = qy - fy0
        u = u * u * (3 - 2 * u)
        v = v * v * (3 - 2 * v)
        let a = hash(i0, j, salt), b = hash(i1, j, salt), c = hash(i0, j + 1, salt), d = hash(i1, j + 1, salt)
        let near = a + (b - a) * u, far = c + (d - c) * u
        return near + (far - near) * v
    }

    private func center(_ i: Int) -> SIMD2<Float> {
        let p = layout.center(of: map.coord(at: i))
        return [Float(p.x), Float(p.y)]
    }

    /// Distances from a point (relative to a tile's center) to the tile's edges, in
    /// `HexDirection` order, or nil when it lies outside the tile. Half-open on opposite
    /// edges, so neighboring tiles partition the plane exactly.
    private func gaps(_ lx: Float, _ ly: Float) -> SIMD8<Float>? {
        let a = apothem
        let d0 = lx, d1 = 0.5 * lx - 0.8660254 * ly, d2 = -0.5 * lx - 0.8660254 * ly
        guard d0 > -a, d0 <= a, d1 > -a, d1 <= a, d2 > -a, d2 <= a else { return nil }
        return SIMD8(a - d0, a - d1, a - d2, a + d0, a + d1, a + d2, .infinity, .infinity)
    }

    /// The six neighbors of a tile in `HexDirection` order (nil off the map).
    private struct Ring {
        private var n: SIMD8<Int32> = .init(repeating: -1)

        init(_ map: HexMap, _ i: Int) {
            let coord = map.coord(at: i)
            var dir = 0
            while dir < 6 {
                if let k = map.index(of: coord.neighbor(Self.directions[dir])) { n[dir] = Int32(k) }
                dir += 1
            }
        }

        private static let directions = HexDirection.allCases.map { $0 }

        subscript(dir: Int) -> Int? { n[dir] < 0 ? nil : Int(n[dir]) }
    }

    /// Lattice point (gx, gy) of `grid`, jittered: up to a quarter step sideways, and up or
    /// down by 0.12-0.4 of a row, the two points of each pair in a row going opposite ways, so
    /// no three neighbors in a row stand on one line.
    private static func point(_ grid: Grid, _ gx: Int, _ gy: Int, salt: UInt32) -> SIMD2<Float> {
        let wx = grid.wrap(gx)
        let jx = (hash(wx, gy, salt) - 0.5) * 0.5
        let up = (hash(wx &>> 1, gy, salt &+ 1) < 0.5) != (wx & 1 == 1)
        let jy = (up ? 1 : -1) * (0.12 + 0.28 * hash(wx, gy, salt &+ 2))
        let x = grid.x(gx, gy) + jx * grid.dx
        return SIMD2(x, grid.y(Float(gy) + jy, at: x))
    }

    /// The gap between lattice point (gx, gy), its east neighbor and the point between them in
    /// the row below (the middle of a downward triangle) or above, jittered.
    private static func gapPoint(_ grid: Grid, _ gx: Int, _ gy: Int, below: Bool = true, salt: UInt32) -> SIMD2<Float> {
        let wx = grid.wrap(gx)
        let j = SIMD2(hash(wx, gy, salt) - 0.5, hash(wx, gy, salt &+ 1) - 0.5) * 0.3
        let x = grid.x(gx, gy) + (0.5 + j.x) * grid.dx
        return SIMD2(x, grid.y(Float(gy) + (below ? -1 : 1) / 3 + j.y, at: x))
    }

    /// The lattice index ranges around a tile, with `margin` to spare.
    private func span(_ grid: Grid, _ c: SIMD2<Float>, margin: Float) -> (x0: Int, x1: Int, y0: Int, y1: Int) {
        (Int(((c.x - apothem - margin) / grid.dx).rounded(.down)) - 1, Int(((c.x + apothem + margin) / grid.dx).rounded(.up)) + 1,
         Int(((c.y - s - margin - grid.amplitude) / grid.dy).rounded(.down)), Int(((c.y + s + margin + grid.amplitude) / grid.dy).rounded(.up)))
    }

    /// How cold a place is (0 temperate ... 1 polar): latitude, broken up by slow world noise.
    private func coldness(at p: SIMD2<Float>) -> Float {
        let row = (p.y - s) / (1.5 * s), mid = Float(max(map.height - 1, 2)) / 2
        let lat = abs(row - mid) / mid
        return min(1, max(0, (lat - 0.35) * 1.6 + (Self.noise(p.x, p.y, climateNoise, salt: 0x43) - 0.5) * 0.4))
    }

    /// One standing instance. `height` scales painter units to world units, `width` stretches
    /// the quad (around the foot) on top of that. `z` lifts it (things set on a hill's face).
    /// `straddles`: also hidden or dimmed by that tile's fog; `inverse`: shown only while that
    /// tile is unexplored.
    private mutating func add(_ art: DecorArt, at p: SIMD2<Float>, height: Float, width: Float = 1, z: Float = 0, tile: Int,
                              tint: SIMD4<Float> = DecorPlacer.white, straddles other: Int? = nil, inverse: Int? = nil,
                              wind: DecorFlags.Wind = .none, detail: DecorFlags.Detail = .always, random: Float = 0,
                              extra: UInt32 = 0) {
        guard drawing else { return }
        let q = quads[art.code]
        var link: Float = 0
        if let other { link = Float(other + 1) } else if let inverse { link = -Float(inverse + 1) }
        let packed = DecorFlags.pack(wind, detail, random: UInt32(min(random, 0.999) * 256), extra: extra)
        instances.append(SpriteInstance(position: SIMD4(p.x, p.y, z, Float(tile)),
                                        sizeAnchor: SIMD4(q.size.x * height * width, q.size.y * height, q.anchor.x, q.anchor.y),
                                        uv: q.uv, tint: tint, flags: SIMD4(1, 1, link, packed)))
    }

    /// The shadow an instance casts on the ground: the part of its image above the foot, laid
    /// flat and stretched away from the sun by the shader. It fades with its caster.
    private mutating func addShadow(_ art: DecorArt, at p: SIMD2<Float>, height: Float, width: Float = 1, tile: Int,
                                    strength: Float, straddles other: Int? = nil, detail: DecorFlags.Detail = .always,
                                    random: Float = 0, loose: Bool = false, extra: UInt32 = 0) {
        guard drawing else { return }
        let q = shadowQuads[art.code]
        let shadow = SpriteInstance(position: SIMD4(p.x, p.y, 0, Float(tile)),
                                      sizeAnchor: SIMD4(q.size.x * height * width, q.size.y * height, q.anchor.x, 0),
                                      uv: q.uv, tint: SIMD4(0, 0, 0, strength),
                                      flags: SIMD4(0, 1, Float((other ?? -1) + 1),
                                                   DecorFlags.pack(.none, detail, random: UInt32(min(random, 0.999) * 256),
                                                                   extra: DecorFlags.shadow | extra)))
        if loose { looseShadows.append(shadow) } else { shadows.append(shadow) }
    }

    /// Records relief for the ground: the middle of its base (`p`, moved a little behind the
    /// foot), its radius kept within 0.65 tile sizes of the tile, and its relative height.
    private mutating func footprint(_ p: SIMD2<Float>, radius r0: Float, crest: Float, tile i: Int) {
        let q = p + SIMD2(0, 0.3 * r0)
        let l = q - center(i)
        var r = r0
        var dir = 0
        while dir < 6 {
            r = min(r, apothem + 0.65 * s - simd_dot(l, Self.edgeNormals[dir]))
            dir += 1
        }
        footprints.append(SIMD4(q.x, q.y, max(r, 0.05 * s), min(crest / (2 * s), 1)))
    }

    /// Overlapping cast shadows of one tile would darken where they cross; each is lightened
    /// by how much of it the others cover, so a crossing stays close to the darkness of one
    /// shadow. (Only the tile's own shadows count, so nothing depends on a neighbor.)
    private mutating func balanceShadows(from start: Int) {
        let n = shadows.count - start
        guard drawing, n > 1 else { return }
        // Each shadow as a disc around the middle of its laid-down image.
        var discs: [SIMD3<Float>] = []
        discs.reserveCapacity(n)
        let away = SIMD2<Float>(0.47, -0.39)
        var k = start
        while k < shadows.count {
            let d = shadows[k]
            let w = d.sizeAnchor.x, h = d.sizeAnchor.y
            let mid = SIMD2(d.position.x + (0.5 - d.sizeAnchor.z) * w, d.position.y) + away * (0.32 * h)
            discs.append(SIMD3(mid.x, mid.y, 0.25 * (w + 0.6 * h)))
            k += 1
        }
        var a = 0
        while a < n {
            var cover: Float = 1
            var b = 0
            while b < n {
                if b != a {
                    let d = simd_distance(SIMD2(discs[a].x, discs[a].y), SIMD2(discs[b].x, discs[b].y))
                    let ra = discs[a].z, rb = discs[b].z
                    // Share of disc a under disc b (1 when it lies inside, 0 when apart).
                    let share = min(1, max(0, (ra + rb - d) / (2 * ra))) * min(1, rb / ra)
                    cover += share
                }
                b += 1
            }
            if cover > 1.05 {
                let alpha = shadows[start + a].tint.w
                shadows[start + a].tint.w = 1 - pow(1 - min(0.95, 1.1 * alpha), 1 / cover)
            }
            a += 1
        }
    }

    // MARK: Tiles

    /// Places the decorations of every tile; relief only for footprints.
    mutating func placeAll(reliefOnly: Bool = false) {
        var i = 0
        while i < map.tileCount {
            let tile = map[index: i]
            if tile.isLand {
                let start = shadows.count
                let wooded = Self.wooded(tile)
                switch tile.elevation {
                case .mountains: placeMountains(i, tile)
                case .hills: if wooded { placeWoods(i, tile, treesToo: !reliefOnly) } else { placeHills(i, tile) }
                case .flat: break
                }
                if !reliefOnly {
                    switch tile.feature {
                    case .forest, .jungle: if tile.elevation == .flat { placeWoods(i, tile, treesToo: true) }
                    case .marsh: placeMarsh(i)
                    case .oasis: placeOasis(i)
                    case .floodplain: placeBankReeds(i, tile)
                    default: break
                    }
                    if !wooded, tile.elevation == .flat, tile.feature != .marsh, tile.feature != .oasis {
                        placeScatter(i, tile)
                        placeHerd(i, tile)
                    }
                }
                balanceShadows(from: start)
            }
            i += 1
        }
    }

    private static func wooded(_ t: Tile) -> Bool { t.feature == .forest || t.feature == .jungle }

    private static func hillStyle(_ t: Terrain) -> DecorSprite.HillStyle {
        switch t {
        case .plains: .dry
        case .desert: .sandy
        case .tundra: .tundra
        case .snow: .snowy
        default: .grassy
        }
    }

    /// Ground color of a tile as the hills on it should match it: its terrain, darkened toward
    /// the forest floor under woods (as the ground shader does, a little less).
    private static func groundColor(_ t: Tile) -> SIMD3<Float> {
        let p = Palette.terrain(t.terrain)
        var c = SIMD3(Float(p.r), Float(p.g), Float(p.b))
        if t.feature == .forest { c += (SIMD3<Float>(0.22, 0.36, 0.17) - c) * 0.3 }
        if t.feature == .jungle { c += (SIMD3<Float>(0.11, 0.33, 0.15) - c) * 0.4 }
        return c
    }

    /// The tint that turns a hill painted in `style`'s color into `ground`, with a little
    /// brightness variety.
    private static func hillTint(_ ground: SIMD3<Float>, _ style: DecorSprite.HillStyle, variety: Float) -> SIMD4<Float> {
        let ratio = simd_clamp(ground / DecorSprite.hillGround(style), SIMD3(repeating: 0.6), SIMD3(repeating: 1.45))
        return SIMD4(ratio * (0.92 + 0.07 * variety), 1)
    }

    /// The direction hill chains run in around `p` (a slow world field), kept within 40
    /// degrees of east-west: a chain running north-south would stack its mounds into one.
    private func ridgeAxis(at p: SIMD2<Float>) -> SIMD2<Float> {
        let theta = (Self.noise(p.x, p.y, ridgeNoise, salt: 0x61) - 0.5) * 2 * 1.4
        return SIMD2(cos(theta), sin(theta) * 0.75)
    }

    /// Moves a point (world) back inside tile `c` until it is `margin` from every edge.
    private func inside(_ p: SIMD2<Float>, _ c: SIMD2<Float>, margin: Float) -> SIMD2<Float> {
        var l = p - c
        var dir = 0
        while dir < 6 {
            let n = Self.edgeNormals[dir]
            let over = simd_dot(l, n) - (apothem - margin)
            if over > 0 { l -= n * over }
            dir += 1
        }
        return c + l
    }

    // MARK: Mountains

    private mutating func placeMountains(_ i: Int, _ tile: Tile) {
        let ring = Ring(map, i)
        if tile.terrain == .desert { placeMassifs(i, tile, ring) } else { placeRange(i, tile, ring) }
        placeFoothills(i, tile, ring)
    }

    /// The rock style of a summit at `p` on `tile`: frozen in the cold (tundra and snow, and
    /// high latitudes); dry ochre rock where the world's aridity field runs high (and on most
    /// plains); alpine otherwise.
    private func rockStyle(_ tile: Tile, at p: SIMD2<Float>) -> DecorSprite.MountainStyle {
        if tile.terrain == .tundra || tile.terrain == .snow || coldness(at: p) > 0.8 { return .frozen }
        let arid = Self.noise(p.x, p.y, aridNoise, salt: 0x44)
        return arid > (tile.terrain == .plains ? 0.45 : 0.78) ? .dry : .alpine
    }

    /// Hero summits near `c`: the lattice point each coarse world cell elects, with its place.
    private func heroes(near c: SIMD2<Float>) -> [(gx: Int, gy: Int, p: SIMD2<Float>)] {
        let g = heroGrid, sg = summitGrid
        var list: [(gx: Int, gy: Int, p: SIMD2<Float>)] = []
        let reach = 2.6 * s
        var hy = Int(((c.y - reach) / g.dy).rounded(.down))
        while Float(hy) * g.dy < c.y + reach {
            var hx = Int(((c.x - reach) / g.dx).rounded(.down))
            while Float(hx) * g.dx < c.x + reach {
                let w = g.wrap(hx)
                let cand = SIMD2((Float(hx) + 0.2 + 0.6 * Self.hash(w, hy, 0x4E01)) * g.dx,
                                 (Float(hy) + 0.2 + 0.6 * Self.hash(w, hy, 0x4E02)) * g.dy)
                let gy = Int(((cand.y - sg.y(0, at: cand.x)) / sg.dy).rounded())
                let gx = Int((cand.x / sg.dx - (gy & 1 == 0 ? 0 : 0.5)).rounded())
                list.append((gx, gy, Self.point(sg, gx, gy, salt: 0x5301)))
                hx += 1
            }
            hy += 1
        }
        return list
    }

    /// A summit, massif or butte with its cast shadow, scaled to `crest` (world units above its
    /// foot) and stretched by `stretch`. Each gets a slightly different brightness and warmth,
    /// so repeats don't read as copies. When its base crosses an edge, it shows only once the
    /// tile beyond is revealed too.
    private mutating func summit(_ art: DecorArt, at p: SIMD2<Float>, crest: Float, stretch: Float, tile i: Int,
                                 ring: Ring, center c: SIMD2<Float>, salt: Int, shadow: Float,
                                 detail: DecorFlags.Detail = .always, random: Float = 0, extra: UInt32 = 0) {
        guard let relief = art.relief else { return }
        let scale = crest / relief.crest
        let west = relief.west * scale * stretch, east = relief.east * scale * stretch
        let l = p - c
        var other: Int?
        var deepest = 0.32 * s
        var dir = 0
        while dir < 6 {
            let n = Self.edgeNormals[dir]
            let cross = simd_dot(l, n) + (n.x > 0 ? east : west) * abs(n.x) - apothem
            if cross > deepest, let k = ring[dir] {
                deepest = cross
                other = k
            }
            dir += 1
        }
        // Low forms stand in the shade of the valleys between the high ones: darker and cooler,
        // so a range reads by its sunlit, snowy spine first.
        let b = 0.95 + 0.07 * Self.hash(i, salt, 0x6D76), warm = (Self.hash(i, salt, 0x6D77) - 0.5) * 0.05
        let high = Self.smoothstep(0.55, 1.25, crest / s)
        let tone = SIMD3<Float>(0.84, 0.86, 0.95) + (SIMD3<Float>(1.03, 1.01, 0.98) - SIMD3<Float>(0.84, 0.86, 0.95)) * high
        add(art, at: p, height: scale, width: stretch, tile: i,
            tint: SIMD4(tone * SIMD3(b * (1 + warm), b, b * (1 - warm)), 1), straddles: other,
            detail: detail, random: random, extra: extra | DecorFlags.relief)
        addShadow(art, at: p, height: scale, width: stretch, tile: i, strength: shadow, straddles: other, detail: detail,
                  random: random, extra: DecorFlags.relief)
        footprint(p + SIMD2((east - west) * 0.5, 0), radius: (east + west) * 0.5, crest: crest, tile: i)
    }

    /// Where the world lattice's summit (gx, gy) stands: its jittered lattice point, pushed
    /// clear of the nearby points that share its colour (and so its silhouette), so two
    /// summits of one silhouette never stand side by side. A pure function of the lattice,
    /// so every tile computes the same foot for it.
    private func peakFoot(_ gx: Int, _ gy: Int) -> SIMD2<Float> {
        let g = summitGrid
        let p = Self.point(g, gx, gy, salt: 0x5301)
        let cls = g.colour(gx, gy)
        let clear = 1.42 * s
        var push = SIMD2<Float>(0, 0)
        var dy = -2
        while dy <= 2 {
            var dx = -2
            while dx <= 2 {
                if dx != 0 || dy != 0, g.colour(gx + dx, gy + dy) == cls {
                    let q = Self.point(g, gx + dx, gy + dy, salt: 0x5301)
                    let d = p - q, len = simd_length(d)
                    if len < clear, len > 1e-4 { push += d / len * (clear - len) * 0.5 }
                }
                dx += 1
            }
            dy += 1
        }
        return p + push
    }

    /// Which half of a tile (1 north, -1 south) its lead summit stands in: the other half from
    /// the tiles beside it in its row.
    private func lean(of hex: HexCoord) -> Float {
        let row = hex.r, columns = max(map.width, 1), col = ((hex.q + (row - (row & 1)) / 2) % columns + columns) % columns
        return (col + (Self.hash(row, 0, 0x5330) < 0.5 ? 0 : 1)) & 1 == 0 ? 1 : -1
    }

    /// The world lattice's summit (gx, gy), from world fields and lattice geometry only (fog:
    /// never from terrain): its foot, its crest (world units above the foot), its lattice
    /// colour and whether it is a hero.
    private func peakSpot(_ gx: Int, _ gy: Int) -> (p: SIMD2<Float>, crest: Float, cls: Int, hero: Bool) {
        let g = summitGrid
        let wx = g.wrap(gx)
        let h = { (k: UInt32) in Self.hash(wx, gy, 0x5320 &+ k) }
        let p = peakFoot(gx, gy)
        // Height: spine lines (where the spine field crosses its middle) carry the high, snowy
        // summits as ridgelines; the broad massif field lifts whole regions; a little of its own.
        let massif = Self.noise(p.x, p.y, massifNoise, salt: 0x41)
        let ridge = 1 - abs(2 * Self.noise(p.x, p.y, spineNoise, salt: 0x42) - 1)
        let spine = Self.smoothstep(0.5, 0.92, ridge)
        let cls = g.colour(gx, gy)
        let lift: Float = [0.06, 0, -0.05][cls]
        // Every tile's lead summit leans to the north or the south half of its tile, the other
        // way from the tiles beside it in its row, so the lead summits of a row never line up.
        let hex = layout.hex(at: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
        let home = layout.center(of: hex)
        let side = min(1, max(-1, lean(of: hex) * (p.y - Float(home.y)) / (0.6 * s)))
        let t = min(1, max(0, 0.08 + lift + 0.72 * spine + 0.3 * (massif - 0.4) + 0.3 * (h(0) - 0.5) + 0.16 * side))
        var crest = s * (0.75 + 0.55 * t)
        var hero = false
        var nearest = Float.infinity
        for e in heroes(near: p) {
            if g.wrap(e.gx) == wx && e.gy == gy { hero = true } else { nearest = min(nearest, simd_distance(e.p, p)) }
        }
        if hero {
            crest = s * (1.7 + 0.22 * h(1))
        } else if nearest < 2.2 * s {
            // Summits around a hero step down toward it, so it stands clear.
            crest = max(0.75 * s, crest * (0.7 + 0.3 * nearest / (2.2 * s)))
        }
        return (p, crest, cls, hero)
    }

    /// A rock range: summits on the world lattice and shoulders in the gaps between them.
    /// From the strategic zoom out only the high summits remain, a little larger, so a range
    /// reads as massifs along its spines rather than a field of small peaks.
    private mutating func placeRange(_ i: Int, _ tile: Tile, _ ring: Ring) {
        let c = center(i)
        let g = summitGrid
        let (x0, x1, y0, y1) = span(g, c, margin: 0.3 * g.dy + 0.5 * s)
        var spots: [(gx: Int, gy: Int, p: SIMD2<Float>, crest: Float, cls: Int, hero: Bool)] = []
        var gy = y0
        while gy <= y1 {
            var gx = x0
            while gx <= x1 {
                defer { gx += 1 }
                let wx = g.wrap(gx)
                let h = { (k: UInt32) in Self.hash(wx, gy, 0x5320 &+ k) }
                // Shoulders in most gaps below and above this point: broad low ridges that join
                // the summits' bases and hide the floor between them.
                for (k, below) in [(UInt32(0), true), (UInt32(8), false)] {
                    let q = Self.gapPoint(g, gx, gy, below: below, salt: 0x5311 &+ k)
                    guard h(10 + k) < (below ? 0.72 : 0.52), gaps(q.x - c.x, q.y - c.y) != nil else { continue }
                    let style = rockStyle(tile, at: q)
                    let v = (wx + gy + (h(11 + k) < 0.3 ? 1 : 0) + (below ? 0 : 1)) & 1
                    let massif = Self.noise(q.x, q.y, massifNoise, salt: 0x41)
                    summit(.shoulder(style, v), at: q, crest: s * (0.46 + 0.24 * h(12 + k) + 0.12 * massif),
                           stretch: 1.25 + 0.4 * h(13 + k), tile: i, ring: ring, center: c, salt: 4 * (gx * 31 + gy) + 1 + Int(k / 8),
                           shadow: 0.3, detail: .secondary, random: h(14 + k))
                }
                // (A lattice point's foot moves less than 0.4 tile sizes from it: skip the far ones.)
                let near = Self.point(g, gx, gy, salt: 0x5301) - c
                guard abs(near.x) < apothem + 0.4 * s, abs(near.y) < 1.4 * s else { continue }
                let spot = peakSpot(gx, gy)
                if gaps(spot.p.x - c.x, spot.p.y - c.y) != nil { spots.append((gx, gy, spot.p, spot.crest, spot.cls, spot.hero)) }
            }
            gy += 1
        }
        // The tile's lead summit: the one furthest into the half its tile leans to, a little
        // taller than the rest (unless a hero stands here), so the leads of a row zigzag.
        if !spots.isEmpty, !spots.contains(where: \.hero) {
            let lean = lean(of: map.coord(at: i))
            var lead = 0
            for k in spots.indices where lean * spots[k].p.y > lean * spots[lead].p.y { lead = k }
            var others: Float = 0
            for k in spots.indices where k != lead { others = max(others, spots[k].crest) }
            spots[lead].crest = min(1.32 * s, max(spots[lead].crest, others * 1.06))
            // Well into its half: up to 0.3 tile sizes further, to 0.35 from the middle.
            let into = lean * (spots[lead].p.y - c.y)
            spots[lead].p.y += lean * min(0.3 * s, max(0, 0.35 * s - into))
            spots[lead].p = inside(spots[lead].p, c, margin: 0.12 * s)
            for k in spots.indices where k != lead { spots[k].crest = min(spots[k].crest, spots[lead].crest / 1.06) }
        }
        for spot in spots {
            let wx = g.wrap(spot.gx), gy = spot.gy
            let h = { (k: UInt32) in Self.hash(wx, gy, 0x5320 &+ k) }
            // Three silhouettes by the lattice colouring (neighbors never share one), each in a
            // high form (snow-capped outside dry country) and a low, bare one.
            let crest = spot.crest, cls = spot.cls, hero = spot.hero
            let tall = hero || crest >= 1.0 * s
            let variant = hero && cls == 2 ? (h(2) < 0.5 ? 0 : 2) : 2 * cls + (tall ? 0 : 1)
            let style = rockStyle(tile, at: spot.p)
            // Broad (the paintings are narrow), each a little more or less so; width and height
            // vary separately.
            let stretch = hero ? 1.25 + 0.2 * h(3) : 1.12 + 0.36 * h(3)
            summit(.peak(style, variant), at: spot.p, crest: crest, stretch: stretch, tile: i, ring: ring,
                   center: c, salt: 4 * (spot.gx * 31 + gy), shadow: 0.38, detail: crest < 1.02 * s ? .secondary : .always,
                   random: h(4), extra: crest > 1.12 * s && !hero ? DecorFlags.grows : 0)
        }
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Desert mountains: broad massifs of red sandstone on a coarser lattice (three height
    /// classes by the lattice colouring, so no three neighbors stand level), each most of a
    /// tile wide and overlapping the next; now and then a tall butte or spire standing out of
    /// them, and a small butte in a gap.
    private mutating func placeMassifs(_ i: Int, _ tile: Tile, _ ring: Ring) {
        let c = center(i)
        let g = massifGrid
        let (x0, x1, y0, y1) = span(g, c, margin: 0.3 * g.dy)
        let classHeight: [Float] = [0.8, 1.0, 1.3]
        var gy = y0
        while gy <= y1 {
            var gx = x0
            while gx <= x1 {
                defer { gx += 1 }
                let wx = g.wrap(gx)
                let h = { (k: UInt32) in Self.hash(wx, gy, 0x5420 &+ k) }
                // Small buttes and talus mounds in the gaps below and above, so the floor between
                // the massifs doesn't run in bands along their feet: one gap or the other, never
                // both (the two are neighbors that share a height class).
                for (k, below) in [(UInt32(0), true), (UInt32(8), false)] {
                    let q = Self.gapPoint(g, gx, gy, below: below, salt: 0x5411 &+ k)
                    guard h(10 + k) < (below ? 0.42 : 0.4), below || h(10) >= 0.42, gaps(q.x - c.x, q.y - c.y) != nil else { continue }
                    // Three height classes by the lattice point's colour, all below the lowest
                    // massif. The other gaps of a class are some 1.5 lattice steps away or more, so
                    // three of one height hardly ever stand together.
                    let level: Float = [0.34, 0.41, 0.5][g.colour(gx, gy)]
                    summit(.shoulder(.desert, 2), at: q, crest: s * level * (0.96 + 0.08 * h(12 + k)), stretch: 0.95 + 0.45 * h(13 + k),
                           tile: i, ring: ring, center: c, salt: 2 * (gx * 31 + gy) + 1 + Int(k), shadow: 0.3,
                           detail: .secondary, random: h(14 + k))
                }
                let p = Self.point(g, gx, gy, salt: 0x5401)
                guard gaps(p.x - c.x, p.y - c.y) != nil else { continue }
                let cls = g.colour(gx, gy)
                let t = Self.noise(p.x, p.y, massifNoise, salt: 0x45)
                if h(0) < 0.08 {
                    // A tall butte or spire standing out of the massifs.
                    summit(.shoulder(.desert, h(1) < 0.5 ? 0 : 1), at: p, crest: s * (1.05 + 0.3 * h(1)), stretch: 0.9 + 0.25 * h(2), tile: i,
                           ring: ring, center: c, salt: 2 * (gx * 31 + gy), shadow: 0.38)
                    continue
                }
                // Low classes are the broad forms (cuesta, stepped pyramid), the middle ones cliff
                // ridges and grand tiered mesas, the tallest grand mesas and now and then twin
                // buttes or a mesa ending in a spire.
                let roll = h(3)
                let family = [roll < 0.5 ? 3 : 5, roll < 0.5 ? 1 : 0, roll < 0.5 ? 0 : (roll < 0.78 ? 2 : 4)][cls]
                let flipped = h(4) < 0.5
                let art = DecorArt.mesa(family + (flipped ? 6 : 0))
                guard let relief = art.relief else { continue }
                let crest = s * (0.72 + 0.25 * t) * classHeight[cls]
                // Broad: well over a tile wide, overlapping the next.
                let natural = (relief.west + relief.east) * crest / relief.crest
                let stretch = max(0.95, min(1.5, s * (2.45 + 0.5 * h(5)) / natural))
                summit(art, at: p, crest: crest, stretch: stretch, tile: i, ring: ring, center: c, salt: 2 * (gx * 31 + gy),
                       shadow: 0.38)
            }
            gy += 1
        }
    }

    /// Foothills where a range meets open land: low mounds straddling the edge.
    private mutating func placeFoothills(_ i: Int, _ tile: Tile, _ ring: Ring) {
        let c = center(i)
        let style = Self.hillStyle(tile.terrain)
        let own = Self.groundColor(tile)
        var dir = 0
        while dir < 6 {
            defer { dir += 1 }
            let h = { (k: Int) in Self.hash(i, dir * 16 + k, 0x666C) }
            guard let n = ring[dir], map[index: n].isLand, map[index: n].elevation != .mountains, h(0) < 0.45 else { continue }
            let edge = Self.edgeNormals[dir], tangent = SIMD2(-edge.y, edge.x)
            let p = c + edge * (apothem - 0.2 * s) + tangent * (h(1) - 0.5) * 0.7 * s
            let ground = (own + Self.groundColor(map[index: n])) * 0.5
            let v = Int(h(2) * Float(DecorSprite.variants(style))) % DecorSprite.variants(style)
            _ = mound(.hill(style, v), at: p, crest: s * (0.26 + 0.12 * h(3)), base: s * (0.8 + 0.35 * h(4)), tile: i,
                      tint: Self.hillTint(ground, style, variety: h(5)), straddles: n, shadow: 0.3)
        }
    }

    // MARK: Hills

    /// One mound (hill or knoll) with its cast shadow, scaled to `crest` high and `base` wide
    /// (world units).
    private mutating func mound(_ art: DecorArt, at p: SIMD2<Float>, crest: Float, base: Float, tile: Int, tint: SIMD4<Float>,
                                straddles other: Int? = nil, shadow: Float) -> Mound? {
        guard let relief = art.relief else { return nil }
        let scale = crest / relief.crest
        let width = base / ((relief.west + relief.east) * scale)
        let m = Mound(foot: p, scale: scale, width: width, relief: relief)
        add(art, at: p, height: scale, width: width, tile: tile, tint: tint, straddles: other, extra: DecorFlags.relief)
        addShadow(art, at: p, height: scale, width: width, tile: tile, strength: shadow, straddles: other, loose: other != nil,
                  extra: DecorFlags.relief)
        footprint(p + SIMD2((m.east - m.west) * 0.5, 0), radius: base * 0.5, crest: crest, tile: tile)
        return m
    }

    /// Where something set on a mound's face at `dx` east of its foot and `rise` (world units)
    /// above it stands: a hair in front of the foot (so it is drawn after the mound, the
    /// higher the sooner) and lifted so it lands on the painted face in the tilted view.
    private static func onFace(_ m: Mound, dx: Float, rise: Float, order: Float) -> (p: SIMD2<Float>, z: Float) {
        let ahead = 0.06 + 0.25 * (1 - order)
        return (SIMD2(m.foot.x + dx, m.foot.y - ahead), (rise + riseOfDepth * ahead) / riseOfHeight)
    }

    /// Hill country: a chain of mounds along the ridge field, sometimes a knoll beside it,
    /// bridges to the hills next door, and snow on tundra hills.
    private mutating func placeHills(_ i: Int, _ tile: Tile) {
        let c = center(i)
        let style = Self.hillStyle(tile.terrain)
        let h = { (k: Int) in Self.hash(i, k, 0x6869) }
        let tint = Self.hillTint(Self.groundColor(tile), style, variety: h(90))
        let axis = ridgeAxis(at: c), normal = SIMD2(-axis.y, axis.x)
        let variants = DecorSprite.variants(style)
        let hex = map.coord(at: i), row = hex.r, column = hex.q + (row - (row & 1)) / 2
        // One to three mounds, the cluster's size varying from tile to tile.
        let roll = h(0)
        let count = roll < 0.28 ? 1 : (roll < 0.74 ? 2 : 3)
        let cluster = 0.78 + 0.5 * h(1)
        let spacing = s * (count == 3 ? 0.5 : 0.58) * (0.9 + 0.2 * h(2))
        let origin = c + SIMD2(h(3) - 0.5, h(4) - 0.5) * 0.24 * s + SIMD2(0, -0.08 * s)
        let baseWidth: Float = count == 1 ? 1.3 : (count == 2 ? 1.05 : 0.88)
        var previous = -1
        var placed: [Mound] = []
        // The chain's main mound: height and width scale separately, mostly modest with a long
        // tail of big ones. Its companions are half to 0.7 of it each way.
        // A chain's main mound stands at least twice the size of its companions (and of a knoll
        // beside it), so every cluster has one clear lead form.
        let tall = 0.6 + 1.0 * pow(h(30), 1.7), broad = 0.6 + 1.0 * pow(h(40), 1.5)
        let mainCrest = min(0.75 * s, max((count > 1 ? 0.42 : 0.34) * s, s * 0.46 * tall * cluster))
        let mainBase = min(1.9 * s, max((count > 1 ? 0.9 : 0.8) * s, min(mainCrest * 5, max(mainCrest * 2.2, s * baseWidth * broad * cluster))))
        let mainAt = Int(h(95) * Float(count)) % count
        for k in 0..<count {
            let along = (Float(k) - Float(count - 1) / 2) * spacing
            let p = inside(origin + axis * along + normal * (h(10 + k) - 0.5) * 0.26 * s, c, margin: 0.2 * s)
            // The first mound's image steps along each row of tiles, so neighbors in a row never
            // repeat one; the rest differ from the mound before them.
            var v = k == 0 ? (column + Int(Self.hash(row, 1, 0x6870) * Float(variants))) % variants
                : Int(h(20 + k) * Float(variants)) % variants
            if v == previous { v = (v + 1) % variants }
            previous = v
            let main = k == mainAt
            let crest = main ? mainCrest : max(0.25 * s, mainCrest * (0.5 + 0.2 * h(31 + k)))
            let base = main ? mainBase : max(0.55 * s, mainBase * (0.5 + 0.2 * h(41 + k)))
            if let m = mound(.hill(style, v), at: p, crest: crest, base: base, tile: i, tint: tint, shadow: 0.3) { placed.append(m) }
        }
        if h(5) < 0.28, mainCrest >= 0.45 * s {
            // A knoll off the chain, well below the main mound.
            let side: Float = h(6) < 0.5 ? -1 : 1
            let p = inside(origin + normal * side * (0.34 + 0.12 * h(7)) * s + axis * (h(8) - 0.5) * 0.5 * s, c, margin: 0.22 * s)
            let crest = max(0.25 * s, mainCrest * (0.45 + 0.15 * h(9)))
            if let m = mound(.knoll(style, Int(h(11) * 2) % 2), at: p, crest: crest, base: crest * (2.1 + 0.5 * h(12)), tile: i,
                             tint: tint, shadow: 0.3) { placed.append(m) }
        }
        // Bridges over edges shared with other hills (each edge once, from its west or north
        // tile), likelier where the chain runs across the edge.
        let ring = Ring(map, i)
        for dir in 0..<3 {
            guard let n = ring[dir], map[index: n].isLand, map[index: n].elevation == .hills, !Self.wooded(map[index: n]) else { continue }
            let edge = Self.edgeNormals[dir], tangent = SIMD2(-edge.y, edge.x)
            guard h(50 + dir) < 0.3 + 0.5 * abs(simd_dot(edge, simd_normalize(axis))) else { continue }
            let p = c + edge * apothem + tangent * (h(53 + dir) - 0.5) * 0.45 * s
            let ground = (Self.groundColor(tile) + Self.groundColor(map[index: n])) * 0.5
            var v = Int(h(56 + dir) * Float(variants)) % variants
            if v == previous { v = (v + 1) % variants }
            _ = mound(.hill(style, v), at: p, crest: s * (0.26 + 0.14 * h(59 + dir)), base: s * (0.85 + 0.3 * h(62 + dir)), tile: i,
                      tint: Self.hillTint(ground, style, variety: h(65 + dir)), straddles: n, shadow: 0.3)
        }
        // A mine, shown once the tile has one: its entrance cut low into the lit west face of
        // the frontmost mound (so the tile's other mounds never hide it), with a heap or two of
        // spoil on the ground in front.
        if tile.terrain != .snow, let m = placed.min(by: { $0.foot.y < $1.foot.y }) {
            let r = { (q: Int) in Self.hash(i, 120 + q, 0x6D69) }
            let dx = -m.west * (0.2 + 0.25 * r(0))
            let u = 0.06 + 0.08 * r(1)
            let at = Self.onFace(m, dx: dx, rise: u * m.face(dx), order: u)
            let mine = DecorFlags.needs(.mine)
            add(.mine(Int(r(2) * 2) % DecorSprite.mineCount), at: at.p, height: s * (0.34 + 0.06 * r(3)), z: at.z, tile: i,
                random: r(4), extra: mine)
            for j in 0..<(r(5) < 0.55 ? 1 : 2) {
                let side: Float = j == 0 ? 1 : -1
                let p = inside(SIMD2(at.p.x + side * (0.2 + 0.1 * r(6 + j)) * s, m.foot.y - (0.06 + 0.08 * r(8 + j)) * s), c,
                               margin: 0.18 * s)
                add(.spoil((Int(r(10 + j) * 2) + j) % DecorSprite.spoilCount), at: p, height: s * (0.18 + 0.05 * r(12 + j)), tile: i,
                    detail: .scatter, random: r(14 + j), extra: mine)
            }
        }
        // Lingering snow on tundra hills, mostly on the shaded lee, different on every hill.
        if style == .tundra {
            for (k, m) in placed.enumerated() where m.face(0) > 0.22 * s {
                for j in 0..<(h(70 + k) < 0.5 ? 1 : 2) {
                    let r = { (q: Int) in Self.hash(i, 100 + k * 8 + j * 4 + q, 0x736E) }
                    let dx = r(0) < 0.75 ? m.east * (0.05 + 0.5 * r(1)) : -m.west * (0.1 + 0.35 * r(1))
                    let top = m.face(dx)
                    guard top > 0.12 * s else { continue }
                    let u = 0.45 + 0.35 * r(2)
                    let size = (m.west + m.east) * (0.16 + 0.12 * r(3)) / 1.4
                    let at = Self.onFace(m, dx: dx, rise: u * top - 0.2 * size, order: u)
                    add(.snow(Int(r(1) * 31) % DecorSprite.snowCount), at: at.p, height: size, width: 0.9 + 0.3 * r(2), z: at.z, tile: i,
                        detail: .scatter, random: r(3), extra: DecorFlags.relief)
                }
            }
        }
    }

    // MARK: Woods

    private mutating func placeWoods(_ i: Int, _ tile: Tile, treesToo: Bool) {
        let c = center(i)
        let ring = Ring(map, i)
        let jungle = tile.feature == .jungle
        let hilly = tile.elevation == .hills
        let snowy = tile.terrain == .tundra || tile.terrain == .snow
        let hh = { (k: Int) in Self.hash(i, k, 0x7768) }

        // Wooded hills show their hills first: one or two big mounds (60-70% of a tile wide) in
        // the color of open ground, a little sunnier (the trees on them are thinned), so the
        // dome reads against the woods around it.
        var mounds: [Mound] = []
        if hilly {
            let style = Self.hillStyle(tile.terrain)
            let tint = Self.hillTint(Self.groundColor(Tile(terrain: tile.terrain)), style, variety: hh(90)) * SIMD4(1.22, 1.17, 0.98, 1)
            let axis = ridgeAxis(at: c)
            let count = hh(0) < 0.4 ? 1 : 2
            let variants = DecorSprite.variants(style)
            // The image steps along each row of tiles, so neighbors in a row never repeat one.
            let hex = map.coord(at: i), row = hex.r, column = hex.q + (row - (row & 1)) / 2
            let first = (column + Int(Self.hash(row, 2, 0x6870) * Float(variants))) % variants
            // One broad mound, or two staggered in depth (one behind, one in front, to either
            // side), so together they fill most of the tile.
            let side: Float = hh(2) < 0.5 ? -1 : 1
            for k in 0..<count {
                let along = count == 1 ? (hh(2) - 0.5) * 0.2 * s : side * (k == 0 ? -1 : 1) * (0.25 + 0.08 * hh(3 + k)) * s
                let depth = count == 1 ? -0.1 * s : (k == 0 ? 0.15 : -0.3) * s
                let p = inside(c + axis * along + SIMD2((hh(5 + k) - 0.5) * 0.2, (hh(7 + k) - 0.5) * 0.1) * s + SIMD2(0, depth), c,
                               margin: 0.22 * s)
                let crest = s * (count == 1 ? 0.65 + 0.12 * hh(9 + k) : (k == 0 ? 0.55 : 0.48) + 0.12 * hh(9 + k))
                let base = s * (count == 1 ? 1.5 + 0.2 * hh(11 + k) : (k == 0 ? 1.2 : 1.1) + 0.2 * hh(11 + k))
                if let m = mound(.hill(style, (first + k) % variants), at: p, crest: crest, base: base, tile: i, tint: tint, shadow: 0.3) {
                    mounds.append(m)
                }
            }
        }
        guard treesToo else { return }

        let cold = snowy ? 1 : coldness(at: c)
        let pineBias = cold * 0.85 + (tile.terrain == .plains ? -0.15 : 0.12)
        let broadleaf = tile.terrain == .plains ? Self.dryBroadleaf : Self.temperateBroadleaf
        let pines = DecorSprite.variants(snowy ? .snowyPine : .pine)
        // Neighbors: woods continue (bit set) or open land, water or the map's end.
        var woods = 0
        var dir = 0
        while dir < 6 {
            if let n = ring[dir], Self.wooded(map[index: n]) { woods |= 1 &<< dir }
            dir += 1
        }
        let rivers = Int(tile.riverEdges)
        let band = s * 0.34
        // Wooded hills keep their mounds visible: a canopy thinned by 40%, and shorter.
        let baseDensity: Float = (jungle ? 0.95 : 0.86) * (hilly ? 0.6 : 1)
        var always = 0
        var secondaries: [Int] = []

        /// One tree (or palm or fern) of this tile's woods; returns its image. `room`: how tall it
        /// may stand (world units) before it reaches into the tile behind on screen; a tree too
        /// tall for it is shortened, or a shrub (a fern in jungle) where there is little room.
        func tree(_ placer: inout DecorPlacer, at p: SIMD2<Float>, size: Float, room: Float = .infinity, z: Float = 0,
                  tint: SIMD4<Float> = DecorPlacer.white, straddles: Int? = nil, inverse: Int? = nil, detail: DecorFlags.Detail,
                  edge: Bool, wx: Int, gy: Int) -> DecorArt? {
            let pick = Self.hash(wx, gy, 0x7705), variety = Self.hash(wx, gy, 0x7709), random = Self.hash(wx, gy, 0x7707)
            let extra = detail == .always ? DecorFlags.grows : 0
            let art: DecorArt, height: Float, wind: DecorFlags.Wind
            if jungle {
                if pick < 0.4 {
                    (art, height, wind) = (.tree(.palm, Int(variety * 4) % 4), 0.86, .palm)
                } else if pick < 0.46, edge {
                    placer.add(.plant(.fern, Int(variety * 3) % 3), at: p, height: placer.s * 0.36 * size, z: z, tile: i, tint: tint,
                               straddles: straddles, inverse: inverse, wind: .grass, detail: .scatter, random: random)
                    return .plant(.fern, 0)
                } else {
                    (art, height, wind) = (.tree(.jungle, Int(variety * 5) % 5), 0.78, .tree)
                }
            } else {
                // Conifers in cold woods and in patches elsewhere; broadleaf otherwise, olives
                // only now and then at the edge of dry woods.
                let conifer = pineBias + (Self.noise(p.x, p.y, placer.pineNoise, salt: 0x52) - 0.5) * 0.9
                if pick < conifer {
                    (art, height, wind) = (.tree(snowy ? .snowyPine : .pine, Int(variety * Float(pines)) % pines), 0.74, .tree)
                } else if tile.terrain == .plains, edge, Self.hash(wx, gy, 0x770A) < 0.15 {
                    (art, height, wind) = (.tree(.broadleaf, 4), 0.62, .tree)
                } else {
                    (art, height, wind) = (.tree(.broadleaf, broadleaf[Int(variety * Float(broadleaf.count)) % broadleaf.count]), 0.66, .tree)
                }
            }
            var tall = placer.s * height * size
            if tall > room {
                if room < 0.3 * placer.s {
                    guard room >= 0.16 * placer.s, Self.hash(wx, gy, 0x770C) < 0.6 else { return nil }
                    let bush: DecorArt = jungle ? .plant(.fern, Int(variety * 3) % 3) : .plant(.shrub, Int(variety * 4) % 4)
                    placer.add(bush, at: p, height: min(0.34 * placer.s, 1.15 * room), z: z, tile: i, tint: tint, straddles: straddles,
                               inverse: inverse, wind: .grass, detail: .scatter, random: random)
                    return bush
                }
                tall = room
            }
            placer.add(art, at: p, height: tall, z: z, tile: i, tint: tint, straddles: straddles, inverse: inverse,
                       wind: wind, detail: detail, random: random, extra: extra)
            return art
        }
        let crown = s * (jungle ? 0.3 : 0.22)
        /// The room above a point (relative to the tile's center, lifted by `z`) before a sprite
        /// standing there reaches more than a hair into the tile behind on screen. A crown is
        /// wide, so the tile's north edges are taken where its shoulders are, not at its trunk.
        func room(_ l: SIMD2<Float>, z: Float = 0) -> Float {
            Self.riseOfDepth * (s - 0.57735027 * (abs(l.x) + crown) - l.y) - Self.riseOfHeight * z + 0.05 * s
        }

        // Trees on the mounds' faces: thinned, shorter toward the crest, lit on the west flank
        // and cooler on the east (each from its own mound), drawn over the mound.
        for (k, m) in mounds.enumerated() {
            let count = Int((m.west + m.east) / s * (jungle ? 3.0 : 2.5) + hh(20 + k))
            for j in 0..<count {
                let r = { (q: Int) in Self.hash(i, 200 + k * 64 + j * 4 + q, 0x7766) }
                let slot = (Float(j) + 0.15 + 0.7 * r(0)) / Float(count)
                let dx = (slot * (m.west + m.east) - m.west) * 0.86
                let top = m.face(dx)
                guard top > 0.1 * s else { continue }
                let u = 0.12 + 0.8 * r(1)
                let at = Self.onFace(m, dx: dx, rise: u * top, order: u)
                let light = dx < 0 ? -dx / m.west : -dx / m.east
                let tint: SIMD4<Float> = light > 0 ? SIMD4(1 + 0.06 * light, 1 + 0.05 * light, 1 - 0.02 * light, 1)
                    : SIMD4(1 + 0.16 * light, 1 + 0.12 * light, 1 + 0.01 * light, 1)
                let detail: DecorFlags.Detail = j % 3 == 1 ? .always : .secondary
                let index = instances.count
                _ = tree(&self, at: at.p, size: (0.7 + 0.15 * r(2)) * (1 - 0.3 * u), room: room(at.p - c, z: at.z), z: at.z, tint: tint,
                         detail: detail, edge: false, wx: i &* 64 &+ k &* 16 &+ j, gy: -7)
                if instances.count > index {
                    if detail == .always { always += 1 } else { secondaries.append(index) }
                }
            }
        }

        let a = apothem
        let cx = c.x, cy = c.y
        let x0 = Int(((cx - a) / gridX).rounded(.down)), x1 = Int(((cx + a) / gridX).rounded(.up))
        let y0 = Int(((cy - s) / gridY).rounded(.down)), y1 = Int(((cy + s) / gridY).rounded(.up))
        // While loops rather than for-in over ranges: this runs for tens of thousands of grid
        // points at startup, and range iteration is slow in unoptimized builds.
        var gy = y0
        while gy <= y1 {
            let shift: Float = gy & 1 == 0 ? 0 : 0.5
            var gx = x0 - 1
            while gx < x1 {
                gx += 1
                let wx = ((gx % gridColumns) + gridColumns) % gridColumns
                let px = (Float(gx) + shift + (Self.hash(wx, gy, 0x7701) - 0.5) * 0.9) * gridX
                let py = (Float(gy) + (Self.hash(wx, gy, 0x7702) - 0.5) * 0.9) * gridY
                let lx = px - cx, ly = py - cy
                guard let edges = gaps(lx, ly) else { continue }

                // Not where a mound stands (its own trees are on its face), nor just in front of
                // it, where a crown would hide the dome.
                var onMound = false
                for m in mounds {
                    let dx = px - m.foot.x, d = py - m.foot.y
                    if dx > -m.west * 0.9, dx < m.east * 0.9, d > -0.5 * s, d < m.face(dx) / Self.riseOfDepth * 1.1 + 0.05 * s {
                        onMound = true
                    }
                }
                if onMound { continue }

                // Rivers stay visible: no trees on the banks, and fewer (and smaller) crowns
                // just south of a river or beside it, where they would stand in front of it.
                var scale: Float = 1
                if rivers != 0 {
                    var reject = false
                    var dir = 0
                    while dir < 6 {
                        if rivers & (1 &<< dir) != 0 {
                            let gap = edges[dir]
                            if gap < 0.3 * s {
                                reject = true
                            } else if dir >= 4, gap < 0.55 * s {
                                if Self.hash(wx, gy, 0x7708) < 0.6 { reject = true } else { scale = min(scale, 0.75) }
                            } else if dir == 0 || dir == 3, gap < 0.4 * s {
                                scale = min(scale, 0.8)
                            }
                        }
                        dir += 1
                    }
                    if reject { continue }
                }

                // Thinner toward the nearest edge when it faces open land, water or the map's
                // end, never below half density.
                var gap = edges[0], nearest = 0
                var dir = 1
                while dir < 6 {
                    if edges[dir] < gap {
                        gap = edges[dir]
                        nearest = dir
                    }
                    dir += 1
                }
                let openEdge = woods & (1 &<< nearest) == 0 && gap < band
                // Species that grow at a wood's edge (ferns, olives) take the tile's own edge band,
                // whatever lies beyond it (fog).
                let edge = gap < band
                let edgeFactor: Float = openEdge ? 0.5 + 0.5 * gap / band : 1
                var density = baseDensity
                // Clearings only in the tile's core, so they never read as torn edges.
                if gap > 0.3 * s {
                    let clearing = Self.noise(px, py, clearingNoise, salt: 0x51)
                    if clearing < 0.3 { density *= 0.675 + clearing }
                }
                let roll = Self.hash(wx, gy, 0x7703)
                guard roll < density else { continue }
                // Thinned out only because of an open edge: kept while the neighbor beyond that
                // edge is unexplored, so the woods' edge gives nothing away.
                var inverse: Int?
                if roll >= density * edgeFactor {
                    guard let n = ring[nearest] else { continue }
                    inverse = n
                }
                // Level of detail from its own hash, independent of species and size.
                let secondary = Self.hash(wx, gy, 0x7706) < 0.42
                let detail: DecorFlags.Detail = secondary ? .secondary : .always
                // Taller to the south of the tile, shorter to the north.
                let size = (0.86 + 0.28 * Self.hash(wx, gy, 0x7704)) * (1.05 - 0.1 * (ly + s) / (2 * s)) * (hilly ? 0.9 : 1) * scale
                let p = SIMD2(px, py)
                let count = instances.count
                // Toward the north edge a tree would stand up into the tile behind on screen, so
                // there it is shortened (or a shrub), whatever lies behind (fog). Where the woods
                // go on there, a full-size tree too, shown once that tile is revealed; the short
                // one stands in until then.
                let headroom = room(SIMD2(lx, ly))
                let behind = ring[lx < 0 ? 4 : 5]
                let continues = behind.map { Self.wooded(map[index: $0]) } ?? false
                let full = inverse == nil && continues && headroom < s * (jungle ? 0.86 : 0.74) * size ? behind : nil
                let made = tree(&self, at: p, size: size, room: headroom, inverse: full ?? inverse, detail: detail, edge: edge, wx: wx, gy: gy)
                if let full { _ = tree(&self, at: p, size: size, straddles: full, detail: detail, edge: edge, wx: wx, gy: gy) }
                if let art = made, case .tree = art {
                    if detail == .always { always += 1 } else if detail == .secondary { secondaries.append(count) }
                    // Edge trees cast their shadow onto the open land east and south of them.
                    if inverse == nil, full == nil, gap < 0.3 * s, nearest < 3, let n = ring[nearest], map[index: n].isLand,
                       !Self.wooded(map[index: n]) {
                        let tree = instances[count]
                        addShadow(art, at: p, height: tree.sizeAnchor.y / max(quads[art.code].size.y, 1e-4), tile: i, strength: 0.36,
                                  straddles: n, detail: detail, random: Self.hash(wx, gy, 0x7707), loose: true)
                    }
                }
            }
            gy += 1
        }
        // Every wooded tile keeps a few trees at strategic zoom.
        let minimum = hilly ? 3 : 6
        var k = 0
        while always < minimum, k < secondaries.count {
            var bits = UInt32(instances[secondaries[k]].flags.w)
            bits = bits & ~(UInt32(3) &<< 2) | DecorFlags.grows
            instances[secondaries[k]].flags.w = Float(bits)
            always += 1
            k += 1
        }
    }

    // MARK: Wetlands and oases

    private mutating func placeMarsh(_ i: Int) {
        let c = center(i)
        let h = { (k: Int) in Self.hash(i, k, 0x6D61) }
        let clumps = 4 + Int(h(0) * 4)
        for k in 0..<clumps {
            // Off the tile center, where units stand.
            let a = h(10 + k) * 2 * .pi, d = (0.3 + 0.4 * h(20 + k)) * s
            let p = c + SIMD2(cos(a), sin(a) * 0.85) * d
            add(.plant(.reeds, Int(h(30 + k) * 4) % 4), at: p, height: s * (0.4 + 0.14 * h(40 + k)), tile: i,
                wind: .grass, detail: k < 2 ? .always : .scatter, random: h(50 + k))
        }
    }

    private mutating func placeOasis(_ i: Int) {
        let c = center(i)
        let h = { (k: Int) in Self.hash(i, k, 0x6F61) }
        // Palms gather in two loose groves on the far and side banks, so the water stays
        // visible: a larger one to the north-west, a smaller one to the east. Lone trees on
        // open sand, so they cast their shadows.
        let groves: [(angle: Float, count: Int)] = [(0.62 + 0.12 * h(1), 2 + Int(h(2) * 1.99)), (0.08 + 0.12 * h(3), 1 + Int(h(4) * 1.6))]
        var k = 0
        for grove in groves {
            let a = Float.pi * grove.angle
            let center = c + SIMD2(cos(a) * 0.46, sin(a) * 0.32) * s
            for _ in 0..<grove.count {
                let p = center + SIMD2(h(10 + k) - 0.5, (h(20 + k) - 0.5) * 0.6) * s * 0.26
                let art = DecorArt.tree(.datePalm, Int(h(30 + k) * 3) % 3)
                let height = s * (0.72 + 0.32 * h(40 + k))
                add(art, at: p, height: height, tile: i, wind: .palm, random: h(50 + k))
                addShadow(art, at: p, height: height, tile: i, strength: 0.36)
                k += 1
            }
        }
        for j in 0..<2 {
            let a = Float.pi * (1.15 + 0.7 * h(60 + j))
            let p = c + SIMD2(cos(a) * 0.48, sin(a) * 0.38) * s
            add(.plant(j == 0 ? .shrub : .dryGrass, Int(h(70 + j) * 3) % 3), at: p, height: s * 0.32, tile: i, wind: .grass,
                detail: .scatter, random: h(80 + j))
        }
    }

    /// Floodplains: a thin line of reeds along their river banks, nothing else.
    private mutating func placeBankReeds(_ i: Int, _ tile: Tile) {
        let c = center(i)
        var dir = 0
        while dir < 6 {
            defer { dir += 1 }
            guard tile.riverEdges & (1 << dir) != 0 else { continue }
            let edge = Self.edgeNormals[dir], tangent = SIMD2(-edge.y, edge.x)
            for k in 0..<3 {
                let h = { (q: Int) in Self.hash(i, dir * 32 + k * 4 + q, 0x6272) }
                guard h(0) < 0.75 else { continue }
                let p = c + edge * (apothem - (0.13 + 0.06 * h(1)) * s) + tangent * ((Float(k) - 1) * 0.3 + (h(2) - 0.5) * 0.12) * s
                add(.plant(.reeds, Int(h(3) * 4) % 4), at: p, height: s * (0.3 + 0.08 * h(1)), tile: i, wind: .grass,
                    detail: .scatter, random: h(2))
            }
        }
    }

    // MARK: Open land

    /// Scatter in world clusters: group centers on a jittered world lattice, active where a
    /// slow patch field runs high (so there are patches of two to four tiles and empty
    /// stretches between), each a group of two to six rocks, shrubs, tufts or cacti; now
    /// and then a landmark. Each item belongs to the tile it lands on and shows only open flat
    /// land's own kinds there, clear of the center (units), rivers and shores.
    private mutating func placeScatter(_ i: Int, _ tile: Tile) {
        let kinds: Int
        switch tile.terrain {
        case .grassland: kinds = 0
        case .plains: kinds = 1
        case .desert: kinds = 2
        case .tundra: kinds = 3
        case .snow: kinds = 4
        default: return
        }
        let c = center(i)
        let g = groupGrid
        let ring = Ring(map, i)
        let rivers = Int(tile.riverEdges)
        let (x0, x1, y0, y1) = span(g, c, margin: 0.45 * s)
        var gy = y0
        while gy <= y1 {
            var gx = x0
            while gx <= x1 {
                defer { gx += 1 }
                let wx = g.wrap(gx)
                let h = { (k: UInt32) in Self.hash(wx, gy, 0x7300 &+ k) }
                let gc = SIMD2(g.x(gx, gy) + (h(0) - 0.5) * 0.7 * g.dx, (Float(gy) + (h(1) - 0.5) * 0.7) * g.dy)
                guard simd_distance(gc, c) < 1.45 * s else { continue }
                let patch = Self.noise(gc.x, gc.y, patchNoise, salt: 0x54)
                let landmark = h(2) < 0.035
                guard patch > 0.58 || landmark else { continue }
                let count = landmark ? 1 : 2 + Int(h(3) * 3.99 * min(1, (patch - 0.5) * 4))
                let groupSize = 0.75 + 0.5 * h(4)
                var k = 0
                while k < count {
                    defer { k += 1 }
                    let r = { (q: Int) in Self.hash(wx &* 8 &+ k, gy, 0x7310 &+ UInt32(q)) }
                    let ang = r(0) * 2 * .pi, d = (landmark ? 0 : 0.06 + 0.3 * r(1).squareRoot()) * s
                    let p = gc + SIMD2(cos(ang), sin(ang) * 0.8) * d
                    let l = p - c
                    guard let edges = gaps(l.x, l.y), simd_length(l) > 0.36 * s else { continue }
                    // Near an edge: kept off the map's end, and off a shore (shown only while
                    // the water beyond is unexplored). Near a corner (two edges) never, so the
                    // choice doesn't hang on which of two neighbors is water (fog).
                    var blocked = false
                    var near: Int?, edgesNear = 0
                    var dir = 0
                    while dir < 6 {
                        if rivers & (1 &<< dir) != 0, edges[dir] < 0.28 * s { blocked = true }
                        if edges[dir] < 0.3 * s {
                            if let n = ring[dir] { near = n } else { blocked = true }
                            edgesNear += 1
                        }
                        dir += 1
                    }
                    if blocked || edgesNear > 1 { continue }
                    let inverse = near.flatMap { map[index: $0].isLand ? nil : $0 }
                    let roll = r(2), v = Int(r(3) * 4)
                    let size = groupSize * (0.8 + 0.4 * r(4))
                    if landmark {
                        landmarkItem(kinds, at: p, tile: i, inverse: inverse, size: size, roll: roll, v: v)
                        continue
                    }
                    let art: DecorArt
                    var height: Float = 0.34
                    switch kinds {
                    case 0: art = roll < 0.45 ? .plant(.shrub, v % 4) : (roll < 0.8 ? .plant(.flowers, v % 3) : .rock(.boulder, v % 4))
                    case 1: art = roll < 0.5 ? .plant(.dryGrass, v % 3) : (roll < 0.78 ? .plant(.shrub, v % 4) : .rock(.boulder, v % 4))
                    case 2:
                        art = roll < 0.45 ? .rock(.sandstone, v % 4) : (roll < 0.65 ? .plant(.cactus, v % 4) : .plant(.dryGrass, v % 3))
                        if roll >= 0.45 && roll < 0.65 { height = 0.44 }
                    case 3: art = roll < 0.5 ? .rock(.boulder, v % 4) : (roll < 0.8 ? .plant(.shrub, 2 + v % 2) : .plant(.dryGrass, v % 3))
                    default: art = .rock(.snowy, v % 3)
                    }
                    var wind = DecorFlags.Wind.grass
                    if case .rock = art {
                        wind = .none
                        height = 0.3
                    }
                    add(art, at: p, height: s * height * size, tile: i, inverse: inverse, wind: wind, detail: .scatter, random: r(5),
                        extra: DecorFlags.clears)
                }
            }
            gy += 1
        }
    }

    /// A rare landmark on open land: a lone tree with its shadow on grass and plains, a big
    /// rock elsewhere.
    private mutating func landmarkItem(_ kinds: Int, at p: SIMD2<Float>, tile i: Int, inverse: Int?, size: Float, roll: Float, v: Int) {
        switch kinds {
        case 0, 1:
            let art = DecorArt.tree(.broadleaf, kinds == 0 ? [0, 1, 6][v % 3] : (roll < 0.5 ? 4 : 1))
            let height = s * 0.66 * (0.9 + 0.2 * size)
            add(art, at: p, height: height, tile: i, inverse: inverse, wind: .tree, random: roll,
                extra: DecorFlags.grows | DecorFlags.clears)
            if inverse == nil { addShadow(art, at: p, height: height, tile: i, strength: 0.36, random: roll, extra: DecorFlags.clears) }
        case 2: add(.rock(.sandstone, v % 4), at: p, height: s * 0.5 * size, tile: i, inverse: inverse, random: roll, extra: DecorFlags.clears)
        case 3: add(.rock(.boulder, v % 4), at: p, height: s * 0.48 * size, tile: i, inverse: inverse, random: roll, extra: DecorFlags.clears)
        default: add(.rock(.snowy, v % 3), at: p, height: s * 0.46 * size, tile: i, inverse: inverse, random: roll, extra: DecorFlags.clears)
        }
    }

    /// A pasture's herd, shown once the tile has one: three or four animals of one kind (mostly
    /// cattle on grassland, sheep on plains, goats on tundra) grazing in a loose group inside
    /// the fence the ground paints, a little behind the centre (a unit there stands in front).
    private mutating func placeHerd(_ i: Int, _ tile: Tile) {
        let h = { (k: Int) in Self.hash(i, k, 0x6864) }
        let roll = h(0)
        let kind: DecorSprite.AnimalKind
        switch tile.terrain {
        case .grassland: kind = roll < 0.7 ? .cow : .sheep
        case .plains: kind = roll < 0.6 ? .sheep : (roll < 0.85 ? .cow : .goat)
        case .tundra: kind = roll < 0.6 ? .goat : .sheep
        default: return
        }
        let c = center(i)
        let ang = (0.15 + 0.7 * h(1)) * Float.pi
        let mid = SIMD2(cos(ang) * 0.24, sin(ang) * 0.17) * (0.85 + 0.3 * h(2)) * s
        let count = h(3) < 0.5 ? 3 : 4
        let size: Float = kind == .cow ? 0.22 : 0.19
        let facing = h(4) < 0.5 ? 0 : 1
        var k = 0
        while k < count {
            let r = { (q: Int) in Self.hash(i, 10 + k * 8 + q, 0x6864) }
            var l = mid + SIMD2((Float(k) - Float(count - 1) / 2) * 0.15 + (r(0) - 0.5) * 0.06,
                                (k & 1 == 0 ? 0.05 : -0.05) + (r(1) - 0.5) * 0.14) * s
            // Well inside the paddock (its fence about 0.6 tile sizes out).
            let e = simd_length(SIMD2(l.x, l.y / 0.88))
            if e > 0.42 * s { l *= 0.42 * s / e }
            add(.animal(kind, r(2) < 0.75 ? facing : 1 - facing), at: c + l, height: s * size * (0.92 + 0.16 * r(3)), tile: i,
                detail: .scatter, random: r(4), extra: DecorFlags.needs(.pasture))
            k += 1
        }
    }
}
