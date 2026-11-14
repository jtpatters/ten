import CoreGraphics
import GameCore
import simd

// Cities (M1 §15, ART.md §11): settlements put together from the kit in the settlement atlas
// (`SettlementSprites.swift`) and drawn in the unit pass, so they take part in its layering:
// each city is one figure group, sorted just behind the units on its tile (which stand on the
// plaza in front of the hall, over it), and plants standing in front of its walls are drawn
// over it again (`liftedDecorations`). Zoomed out to strategic scale the pieces fade and a
// token with the owner's emblem takes their place. Decorations other than relief hide on city
// centres (`markCityCentres`). Only cities the App passes in are drawn (`setCities`), and never
// on tiles the viewer has not explored; on explored tiles out of sight they are dimmed like the
// ground, as last seen.

/// What the renderer keeps of the cities between frames.
struct CityArtState {
    /// Each city's settlement, keyed by everything that shapes it.
    var layouts: [CityMarker: CityLayout] = [:]
    /// Bumped whenever the cities change (tap targets are redrawn).
    var version = 0
    var atlasTable: TownAtlasTable?
}

/// A settlement put together from the kit: its pieces in drawing order, the roofs smoke rises
/// from while it is damaged, and the top of its tallest piece (where its banner hangs).
struct CityLayout {
    struct Placed {
        var piece: SettlementPiece
        /// Its foot relative to the city's hex center (tile sizes, y north) and its scale.
        var at: SIMD2<Float>
        var scale: Float = 1
    }

    var pieces: [Placed] = []
    /// Roof tops: x and y (north) of the foot and the height above it, tile sizes.
    var roofs: [SIMD3<Float>] = []
    /// The top of the tallest piece as the tilted camera shows it: its foot (x, y north) and
    /// height, tile sizes.
    var crown = SIMD3<Float>(0, 0, 1)
    /// The trodden ground's width (tile sizes): a village's smaller, a walled town's filling
    /// its ring.
    var ground: Float = 1.85
    /// Whether the plan is mirrored (east for west), as its ground is drawn too.
    var mirrored = false
    /// A walled town's ground: its square and main lane paved.
    var paved = false

    /// Population tier: 1–2, 3–5, 6 and more.
    static func tier(_ population: Int) -> Int { population <= 2 ? 0 : (population <= 5 ? 1 : 2) }
}

/// The settlement atlas rects the unit pass uses, looked up once.
struct TownAtlasTable {
    var pieces: [SettlementPiece: SIMD4<Float>] = [:]
    /// Per piece with team paint: its team cell's index in rows of cells its size, plus one
    /// (`cityPiece` in `ShaderUnits.swift`); 0 for none.
    var team: [SettlementPiece: Float] = [:]
    var ground = SIMD4<Float>.zero
    var pavedGround = SIMD4<Float>.zero
}

/// A city drawn this frame.
struct ShownCity {
    var marker: CityMarker
    /// Its hex center (world, the copy nearest the camera).
    var center: SIMD2<Float>
    /// Explored but out of sight: drawn as last seen, dimmed.
    var fogged: Bool
    var layout: CityLayout
}

extension MapRenderer {
    /// Meaning of `SpriteInstance.flags.y` for city instances in the unit pass (after the unit
    /// kinds, `UnitSpriteKind`). Must match `ShaderUnits.swift`.
    enum CitySpriteKind: Float {
        /// A settlement piece standing on its foot. uv: its cell; tint: owner color, opacity.
        /// z: 1 when fogged; w: its team cell (`TownAtlasTable.team`), 0 for none (a tribal
        /// village's huts, tinted white).
        case piece = 11
        /// The trodden ground under a settlement, flat. tint: rgb multiplier, opacity. z: 1
        /// when fogged. w: 1 for a tribal village's, drawn procedurally with no lanes (uv: its
        /// hearth in quad fractions and its pattern's seed; `tribalVillageGround`).
        case ground = 12
        /// Smoke rising from a damaged city's roof. tint.a: how thick. w: the column's seed. z:
        /// 1 for a tribal village's cooking smoke (thin and pale, with no embers).
        case smoke = 13
        /// The strategic token: a crenellated plate in the owner's color with their emblem. uv:
        /// the emblem cell (unit atlas); tint: owner color, opacity. z: 1 when fogged; w: 1 for
        /// a capital.
        case token = 14
    }

    /// The token's width in strategic medallion frames, and how far its middle stands above
    /// the hex center (in token widths): a unit's medallion in the city covers its foot only.
    static let cityTokenSize: Float = 1.3
    static let cityTokenLift: Float = 0.42
    /// A settlement's reach from its hex center (tile sizes): the wall ring and its towers.
    static let cityReach: Float = 0.95
    /// How much bigger settlements are drawn zoomed out (from the figures' close zoom to their
    /// standard size, `figureSize(scale:)`), so they keep their presence next to the units.
    static let cityGrowth: Float = 0.18

    /// The tile size a settlement is laid out in at the current zoom (world units).
    func cityUnit() -> Float {
        let t = (Self.figureSize(scale: camera.scale) - Self.figureCloseSize) / (Self.figureSize - Self.figureCloseSize)
        return Float(layout.size) * (1 + Self.cityGrowth * t)
    }

    /// The cities to draw this frame: known to the viewer, on explored tiles, near the view.
    func shownCities(bounds: (lo: SIMD2<Float>, hi: SIMD2<Float>)?) -> [ShownCity] {
        let s = Float(layout.size)
        var shown: [ShownCity] = []
        for city in inputs.cities {
            guard let hex = state.map.normalize(city.hex) else { continue }
            let fog = fogLevel(hex)
            guard fog < 2 else { continue }
            let c = Self.vec(layout.center(of: hex))
            let x = Float(layout.nearestCopy(of: CGFloat(c.x), to: CGFloat(camera.target.x)))
            if let bounds, x < bounds.lo.x - 1.5 * s || x > bounds.hi.x + 1.5 * s || c.y < bounds.lo.y - 2 * s || c.y > bounds.hi.y + 1.5 * s {
                continue
            }
            shown.append(ShownCity(marker: city, center: [x, c.y], fogged: fog == 1, layout: cityLayout(city)))
        }
        return shown
    }

    /// A city's settlement, cached.
    func cityLayout(_ city: CityMarker) -> CityLayout {
        if let cached = cityArt.layouts[city] { return cached }
        let built = Self.buildLayout(city)
        if cityArt.layouts.count > 512 { cityArt.layouts.removeAll() }
        cityArt.layouts[city] = built
        return built
    }

    func townAtlasTable() -> TownAtlasTable {
        if let table = cityArt.atlasTable { return table }
        var table = TownAtlasTable()
        let width = Float(SpriteSheet<SettlementSprite>.width), height = Float(SpriteSheet<SettlementSprite>.height)
        assert(townAtlas.width == SpriteSheet<SettlementSprite>.width && townAtlas.height == SpriteSheet<SettlementSprite>.height)
        for piece in SettlementPiece.allCases {
            table.pieces[piece] = townAtlas.uv(.piece(piece))
            guard piece.hasTeam else { table.team[piece] = 0; continue }
            let uv = townAtlas.uv(.team(piece)), cell = Float(piece.cellSize)
            let column = (uv.x * width / cell).rounded(), row = (uv.y * height / cell).rounded()
            table.team[piece] = row * (width / cell) + column + 1
        }
        table.ground = townAtlas.uv(.ground)
        table.pavedGround = townAtlas.uv(.pavedGround)
        cityArt.atlasTable = table
        return table
    }

    // MARK: Layout

    /// Puts a settlement together: the hall (or a capital's keep) at the back of the hex, houses
    /// around it and props by tier, the plaza in front left clear for the units' base, and the
    /// wall ring with its towers and gate (breached when the walls are down). Variety (which
    /// houses, the mirror image of the plan, small offsets) is seeded by the city's id, so a
    /// city keeps its look as it grows.
    static func buildLayout(_ city: CityMarker) -> CityLayout {
        let tier = CityLayout.tier(city.population)
        let seed = UInt64(bitPattern: Int64(city.id)) &* 0x9E37_79B9_7F4A_7C15 &+ 0x5EED
        func roll(_ k: Int) -> Float {
            var x = seed &+ UInt64(k) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            x ^= x >> 31
            return Float(x >> 40) / Float(1 << 24)
        }
        let flip: Float = roll(0) < 0.5 ? 1 : -1
        var buildings: [CityLayout.Placed] = []
        func put(_ piece: SettlementPiece, _ x: Float, _ y: Float, scale: Float = 1, slot: Int) {
            let jitter = SIMD2(roll(10 + slot) - 0.5, roll(30 + slot) - 0.5) * 0.04
            buildings.append(.init(piece: piece, at: SIMD2(x * flip, y) + jitter, scale: scale))
        }
        // Houses: modest ones in a village, two storeys and stone in a city.
        let pools: [[SettlementPiece]] = [[.house0, .house5, .house4, .house1], SettlementPiece.houses, [.house2, .house3, .house1, .house0, .house4]]
        let pool = pools[tier]
        var lastHouse: SettlementPiece?
        func house(_ x: Float, _ y: Float, slot: Int) {
            var piece = pool[Int(roll(50 + slot) * Float(pool.count)) % pool.count]
            if piece == lastHouse { piece = pool[(pool.firstIndex(of: piece)! + 1) % pool.count] }
            lastHouse = piece
            put(piece, x, y, scale: 0.92 + 0.14 * roll(70 + slot), slot: slot)
        }
        // The hall (a capital's keep) stands at the back, rising over the units on the plaza.
        put(city.capital ? .keep : .hall, 0.02, 0.36, scale: city.capital ? 1.12 : 1.05, slot: 0)
        switch tier {
        case 0:
            house(-0.42, 0.26, slot: 1)
            house(0.44, 0.22, slot: 2)
            if roll(3) < 0.5 { house(-0.2, 0.56, slot: 3) } else { house(0.26, 0.58, slot: 3) }
            put(.well, 0.56, -0.06, slot: 4)
        case 1:
            house(-0.42, 0.26, slot: 1)
            house(0.44, 0.22, slot: 2)
            house(-0.22, 0.56, slot: 3)
            house(0.27, 0.58, slot: 4)
            house(-0.55, -0.02, slot: 5)
            put(.granary, 0.56, -0.04, slot: 6)
            if !city.walls { put(.hay, -0.66, -0.3, scale: 0.9, slot: 7) }
        default:
            house(-0.42, 0.26, slot: 1)
            house(0.44, 0.22, slot: 2)
            put(.granary, -0.24, 0.57, slot: 3)
            house(0.27, 0.58, slot: 4)
            house(-0.28, 0.07, slot: 5)
            house(0.3, 0.06, slot: 6)
            put(.market, -0.54, -0.06, slot: 7)
            put(.library, 0.55, -0.08, slot: 8)
            if !city.walls { put(.well, -0.7, -0.32, scale: 0.9, slot: 9) }
        }
        buildings.sort { $0.at.y > $1.at.y }

        var out = CityLayout()
        out.ground = city.walls ? 1.85 : [1.5, 1.7, 1.85][tier]
        out.mirrored = flip < 0
        out.paved = city.walls
        let r = Float(SettlementPiece.wallRadius)
        if city.walls {
            out.pieces += [.init(piece: .wallBackLeft, at: .zero), .init(piece: .wallBackRight, at: .zero), .init(piece: .tower, at: [0, r])]
        }
        out.pieces += buildings
        if city.walls {
            let breached = city.wallHP <= 0
            out.pieces += [.init(piece: breached ? .wallBreach : .wallFrontLeft, at: .zero), .init(piece: .wallFrontRight, at: .zero),
                           .init(piece: .tower, at: [-r, 0]), .init(piece: .tower, at: [r, 0]),
                           .init(piece: .gatehouse, at: [0, -r - 0.05])]
        }
        // Roofs (the hall first), and the crown: the highest top on screen.
        let depth = Float(SettlementSprite.depth)
        var best = -Float.infinity
        for placed in out.pieces {
            guard let box = SettlementSprite.bounds[placed.piece] else { continue }
            let top = (box.w - placed.piece.foot.y) * placed.piece.edge * placed.scale
            let screen = placed.at.y * depth + top
            if screen > best {
                best = screen
                out.crown = SIMD3(0, placed.at.y, top)
            }
        }
        for placed in buildings where placed.piece == .hall || placed.piece == .keep || SettlementPiece.houses.contains(placed.piece) {
            guard let box = SettlementSprite.bounds[placed.piece] else { continue }
            let top = (box.w - placed.piece.foot.y) * placed.piece.edge * placed.scale
            out.roofs.append(SIMD3(placed.at.x + 0.03, placed.at.y, top * 0.78))
        }
        out.roofs.sort { abs($0.x) + abs($0.y - 0.3) < abs($1.x) + abs($1.y - 0.3) }
        return out
    }

    // MARK: Instances

    /// A city's ground patch, flat on its hex (the unit pass's ground layer, under the
    /// decorations), tinted toward the terrain and mirrored with the city's plan. Zoomed out it
    /// fades (`opacity`) to a faint clearing under the token.
    func cityGround(_ city: ShownCity, table: TownAtlasTable, opacity: Float) -> SpriteInstance {
        let s = cityUnit()
        let tint = Self.groundTint(state.map.tile(at: city.marker.hex)?.terrain ?? .grassland)
        let size = city.layout.ground * s
        // A negative width mirrors the quad (and its texture) east for west.
        return SpriteInstance(position: [city.center.x, city.center.y + 0.04 * s, 0, -1],
                              sizeAnchor: [city.layout.mirrored ? -size : size, size, 0.5, 0.5],
                              uv: city.layout.paved ? table.pavedGround : table.ground, tint: SIMD4(tint, 0.85 * opacity),
                              flags: [0, CitySpriteKind.ground.rawValue, city.fogged ? 1 : 0, 0])
    }

    /// How a settlement's trodden ground is tinted on each terrain (a tribal village's too).
    static func groundTint(_ terrain: Terrain) -> SIMD3<Float> {
        switch terrain {
        case .desert: [1.1, 1.04, 0.9]
        case .tundra: [0.9, 0.93, 0.95]
        case .snow: [0.96, 0.98, 1.04]
        case .plains: [1.04, 0.99, 0.9]
        default: [0.96, 0.95, 0.88]
        }
    }

    /// A city's pieces in drawing order.
    func cityPieces(_ city: ShownCity, table: TownAtlasTable, opacity: Float) -> [SpriteInstance] {
        let s = cityUnit()
        let color = Palette.playerStyle(city.marker.owner.rawValue).rgb
        return city.layout.pieces.map { placed in
            let edge = placed.piece.edge * placed.scale * s, foot = placed.piece.foot
            return SpriteInstance(position: [city.center.x + placed.at.x * s, city.center.y + placed.at.y * s, 0, 0],
                                  sizeAnchor: [edge, edge, foot.x, foot.y], uv: table.pieces[placed.piece] ?? .zero,
                                  tint: SIMD4(color, opacity),
                                  flags: [1, CitySpriteKind.piece.rawValue, city.fogged ? 1 : 0, table.team[placed.piece] ?? 0])
        }
    }

    /// Smoke over a damaged city's roofs: one column per third of its hit points lost.
    func citySmoke(_ city: ShownCity, opacity: Float) -> [SpriteInstance] {
        let hp = min(max(city.marker.hp, 0), 1)
        guard hp < 1, !city.fogged else { return [] }
        let s = cityUnit(), up = camera.up
        let columns = min(Int(((1 - hp) * 3).rounded(.up)), city.layout.roofs.count)
        return city.layout.roofs.prefix(columns).enumerated().map { i, roof in
            let lift = roof.z * s
            return SpriteInstance(position: [city.center.x + roof.x * s, city.center.y + roof.y * s + up.y * lift, up.z * lift, -1],
                                  sizeAnchor: [0.5 * s, 1.15 * s, 0.5, 0.04], uv: .zero, tint: [1, 1, 1, opacity * (0.8 + 0.2 * (1 - hp))],
                                  flags: [1, CitySpriteKind.smoke.rawValue, 0, Float(city.marker.id % 7) + Float(i) * 0.31])
        }
    }

    /// The strategic token, its middle raised above the hex center.
    func cityToken(_ city: ShownCity, medallion: Float, emblem: SIMD4<Float>, opacity: Float) -> SpriteInstance {
        let size = medallion * Self.cityTokenSize, up = camera.up
        let lift = size * Self.cityTokenLift
        let style = Palette.playerStyle(city.marker.owner.rawValue)
        return SpriteInstance(position: [city.center.x, city.center.y + up.y * lift, up.z * lift, -1], sizeAnchor: [size, size, 0.5, 0.5],
                              uv: emblem, tint: SIMD4(style.rgb, opacity),
                              flags: [1, CitySpriteKind.token.rawValue, city.fogged ? 1 : 0, city.marker.capital ? 1 : 0])
    }

    /// Where a shown city's figure group stands for the layering (`UnitFrame.Figures`): the
    /// front of its wall ring, and the ring's middle and radius (world units).
    func cityFront(_ city: ShownCity) -> (feet: SIMD2<Float>, ring: SIMD3<Float>) {
        let s = cityUnit(), r = Float(SettlementPiece.wallRadius) + 0.05
        return ([city.center.x, city.center.y - r * s], SIMD3(city.center, r * s))
    }

    // MARK: Banner anchor

    /// The top of a city's sprite in view points: above its tallest piece, or zoomed out, its
    /// token (blending with the crossfade between them).
    func cityTop(_ city: CityMarker) -> CGPoint? {
        guard let hex = state.map.normalize(city.hex) else { return nil }
        let c = Self.vec(layout.center(of: hex))
        let x = Float(layout.nearestCopy(of: CGFloat(c.x), to: CGFloat(camera.target.x)))
        let s = cityUnit(), up = camera.up
        let crown = cityLayout(city).crown
        let near = SIMD3(x + crown.x * s, c.y + crown.y * s, 0) + up * (crown.z * s)
        let token = medallionSize() * Self.cityTokenSize
        let far = SIMD3(x, c.y, 0) + up * (token * (Self.cityTokenLift + 0.5))
        let blend = unitArt.blend
        guard let a = camera.viewPoint(of: near), let b = camera.viewPoint(of: far),
              let middle = camera.viewPoint(of: SIMD3(x, c.y, 0)) else { return nil }
        let y = a.y + (b.y - a.y) * CGFloat(blend)
        return CGPoint(x: middle.x, y: y)
    }
}
