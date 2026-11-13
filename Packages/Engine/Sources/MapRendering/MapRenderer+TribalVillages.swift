import CoreGraphics
import GameCore
import simd

// Tribal villages (M1 §7.7, ART.md §11 "Tribal villages"): small clearings of round huts put
// together from the settlement kit (`SettlementSprites.swift`) and drawn by the unit pass the way
// cities are. Each is two round huts and a wood pile on a little trodden ground round a hearth,
// laid out from its tile index; while its tile is in sight a thin, pale column of smoke rises
// from the cooking fire. It must never read as a small city: no hall, no square houses, no
// lanes, no banner, no player colour and no name, and it is smaller than a city of one.
//
// - Only the markers the App passes are drawn (`setTribalVillages`), never on tiles the viewer
//   has not explored. A remembered one (out of sight) takes the explored-fog look, without
//   smoke or embers. Zoomed out to strategic scale a small ivory token with a hut glyph takes
//   its place (`UnitSprite.tribalVillage`), never in a player's colour.
// - On its tile the plants that stand on it (and their cast shadows) hide: the huts stand in a
//   clearing among the tile's relief and rocks, and whatever reaches over from the neighbours
//   stays (`TileBits.tribalVillage`, `decor_vertex`). Hills still read as hills.
// - A shown `tribalVillageTaken` fades a ghost of the old marker out while the plants fade back
//   in, from the moment the unit that took it reaches the tile (at once for a city's claim), and
//   reports the event through `onEventShown` as the fade starts (`scheduleTribalVillageFade`).
// - A tap on one picks the ground: nothing of it is a tap target.

/// A tribal village as the kit puts it together.
struct TribalVillageLayout {
    /// The huts and the wood pile, back to front (feet relative to the hex centre, tile sizes, y
    /// north).
    var pieces: [CityLayout.Placed] = []
    /// The hearth relative to the hex centre (tile sizes, y north): the fire pit in the trodden
    /// ground and the smoke's foot.
    var hearth = SIMD2<Float>.zero
    /// The ground's own pattern (0...1).
    var seed: Float = 0
}

/// A taken tribal village fading out: the marker as the viewer knew it, and when the fade starts
/// on the animation clock (`AnimationState.tribalVillageFades`).
struct TribalVillageFade {
    var marker: TribalVillageMarker
    var tile: Int
    var start: Double

    var end: Double { start + MapRenderer.tribalVillageFadeDuration }
}

/// A tribal village drawn this frame.
struct ShownTribalVillage {
    var hex: HexCoord
    var tile: Int
    /// Its hex centre (world, the copy nearest the camera).
    var center: SIMD2<Float>
    /// Remembered, or its tile out of sight: the explored-fog look, with no smoke and no embers.
    var fogged: Bool
    /// 1, or a taken one's ghost's as it fades.
    var opacity: Float
    var layout: TribalVillageLayout
}

extension MapRenderer {
    /// Meaning of `SpriteInstance.flags.y` for the tribal villages' own instance in the unit pass
    /// (their huts, ground and smoke are `CitySpriteKind`s: a piece with no team paint, the
    /// ground with w 1, the smoke with z 1). Must match `ShaderUnits.swift`.
    enum TribalVillageSpriteKind: Float {
        /// The strategic token, standing: its atlas cell (`UnitSprite.tribalVillage`), an ivory
        /// disc in a dark rim with a hut glyph. tint.a: opacity. z: 1 when fogged.
        case token = 24
    }

    /// How long a taken tribal village takes to fade (seconds at `animationSpeed` 1); its
    /// plants fade back in over the same time.
    nonisolated static let tribalVillageFadeDuration: Double = 0.6
    /// The trodden ground's width (tile sizes, as a city's `CityLayout.ground`): smaller than a
    /// city of one's.
    static let tribalVillageGroundSize: Float = 1.25
    /// The strategic token's disc, in strategic medallion frames: smaller than a unit's.
    static let tribalVillageTokenSize: Float = 0.74
    /// The smoke column's quad (tile sizes) and how thick it is: about a third of a damaged
    /// city's (`citySmoke`).
    static let tribalVillageSmokeSize: SIMD2<Float> = [0.46, 1.15]
    static let tribalVillageSmokeThickness: Float = 0.5
    /// The ring the huts stand in for the layering (`UnitFrame.Figures`): its middle above the
    /// hex centre and its radius (tile sizes).
    static let tribalVillageRing: SIMD2<Float> = [0.06, 0.42]

    // MARK: Layout

    /// A tribal village's huts, wood pile and hearth, from its tile index alone. The three stand
    /// round the hearth (a little south of the hex centre) about a third of a tile from it, a
    /// third of a turn apart, the whole ring turned by the tile: the wood pile (the kit's `hay`)
    /// takes the place nearest the front, so no hut ever hides the fire, and the two round huts,
    /// one a little bigger, the others. The plan may be mirrored, never the pieces (they are lit
    /// from the upper left).
    static func tribalVillageLayout(tile: Int) -> TribalVillageLayout {
        let seed = UInt64(truncatingIfNeeded: tile) &* 0x9E37_79B9_7F4A_7C15 &+ 0x7B1B_A1F1
        func roll(_ k: Int) -> Float {
            var x = seed &+ UInt64(k) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            x ^= x >> 31
            return Float(x >> 40) / Float(1 << 24)
        }
        let flip: Float = roll(0) < 0.5 ? 1 : -1
        let hearth = SIMD2<Float>((roll(1) - 0.5) * 0.08, -0.05 + (roll(2) - 0.5) * 0.04)
        /// A point `distance` from the hearth at `degrees` (counterclockwise from east), the
        /// ground seen a little foreshortened.
        func around(_ degrees: Float, _ distance: Float) -> SIMD2<Float> {
            let a = degrees * .pi / 180
            return hearth + SIMD2(cos(a), sin(a) * 0.86) * distance
        }
        // The wood pile within 55 degrees of straight in front, the huts a third of a turn on
        // either side of it (each nudged a little).
        let pile = -90 + 110 * (roll(3) - 0.5)
        let big = 1.1 + 0.06 * roll(7), small = 0.96 + 0.06 * roll(9)
        let firstBig = roll(10) < 0.5
        var pieces: [CityLayout.Placed] = [
            .init(piece: .house5, at: around(pile + 120 + 24 * (roll(4) - 0.5), 0.29 + 0.05 * roll(6)), scale: firstBig ? big : small),
            .init(piece: .house5, at: around(pile + 240 + 24 * (roll(5) - 0.5), 0.29 + 0.05 * roll(8)), scale: firstBig ? small : big),
            .init(piece: .hay, at: around(pile, 0.3 + 0.04 * roll(11)), scale: 0.78),
        ]
        for k in pieces.indices { pieces[k].at.x *= flip }
        pieces.sort { $0.at.y > $1.at.y }
        return TribalVillageLayout(pieces: pieces, hearth: [hearth.x * flip, hearth.y], seed: roll(12))
    }

    // MARK: Shown

    /// The tribal villages to draw this frame: the known ones on explored tiles near the view,
    /// and the ghosts of taken ones still fading (where the App no longer passes a marker).
    func shownTribalVillages(bounds: (lo: SIMD2<Float>, hi: SIMD2<Float>)?) -> [ShownTribalVillage] {
        let markers = inputs.tribalVillages, fades = animation.tribalVillageFades
        guard !markers.isEmpty || !fades.isEmpty else { return [] }
        let s = Float(layout.size), now = animation.clock
        var shown: [ShownTribalVillage] = []
        func show(_ marker: TribalVillageMarker, tile: Int, opacity: Float) {
            let fog = fogLevel(marker.hex)
            guard fog < 2, opacity > 0.003 else { return }
            let c = Self.vec(layout.center(of: marker.hex))
            let x = Float(layout.nearestCopy(of: CGFloat(c.x), to: CGFloat(camera.target.x)))
            if let bounds, x < bounds.lo.x - 1.5 * s || x > bounds.hi.x + 1.5 * s || c.y < bounds.lo.y - 2 * s || c.y > bounds.hi.y + 1.5 * s {
                return
            }
            shown.append(ShownTribalVillage(hex: marker.hex, tile: tile, center: [x, c.y], fogged: !marker.seen || fog == 1,
                                            opacity: opacity, layout: Self.tribalVillageLayout(tile: tile)))
        }
        let marked = markers.compactMap { marker in state.map.index(of: marker.hex).map { (marker, $0) } }
        for (marker, tile) in marked { show(marker, tile: tile, opacity: 1) }
        for fade in fades where !marked.contains(where: { $0.1 == fade.tile }) {
            show(fade.marker, tile: fade.tile, opacity: 1 - Self.tribalVillageEase(Float((now - fade.start) / Self.tribalVillageFadeDuration)))
        }
        return shown
    }

    static func tribalVillageEase(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    // MARK: Instances

    /// A tribal village's trodden ground, flat on its hex (the unit pass's ground layer, under
    /// the decorations): procedural, with no lanes (`tribalVillageGround` in `ShaderUnits.swift`),
    /// tinted toward the terrain as a city's is. uv carries the hearth (quad fractions) and the
    /// pattern's seed. Zoomed out it fades (`opacity`) to a faint clearing under the token.
    func tribalVillageGround(_ village: ShownTribalVillage, opacity: Float) -> SpriteInstance {
        let s = cityUnit(), size = Self.tribalVillageGroundSize * s
        let terrain = state.map.tile(at: village.hex)?.terrain ?? .grassland
        let middle = village.center + [0, 0.02 * s]
        let hearth = (village.center + village.layout.hearth * s - middle) / size + 0.5
        return SpriteInstance(position: [middle.x, middle.y, 0, -1], sizeAnchor: [size, size, 0.5, 0.5],
                              uv: [hearth.x, hearth.y, village.layout.seed, 0], tint: SIMD4(Self.groundTint(terrain), opacity),
                              flags: [0, CitySpriteKind.ground.rawValue, village.fogged ? 1 : 0, 1])
    }

    /// A tribal village's huts and wood pile in drawing order: settlement pieces with no team
    /// paint and no player colour.
    func tribalVillagePieces(_ village: ShownTribalVillage, table: TownAtlasTable, opacity: Float) -> [SpriteInstance] {
        let s = cityUnit()
        return village.layout.pieces.map { placed in
            let edge = placed.piece.edge * placed.scale * s, foot = placed.piece.foot
            return SpriteInstance(position: [village.center.x + placed.at.x * s, village.center.y + placed.at.y * s, 0, 0],
                                  sizeAnchor: [edge, edge, foot.x, foot.y], uv: table.pieces[placed.piece] ?? .zero,
                                  tint: [1, 1, 1, opacity], flags: [1, CitySpriteKind.piece.rawValue, village.fogged ? 1 : 0, 0])
        }
    }

    /// The cooking fire's smoke while the village is in sight: one thin, pale column from the
    /// hearth (`citySmoke` with z 1), seeded by the tile. None when remembered.
    func tribalVillageSmoke(_ village: ShownTribalVillage, opacity: Float) -> [SpriteInstance] {
        guard !village.fogged, opacity > 0 else { return [] }
        let s = cityUnit(), size = Self.tribalVillageSmokeSize * s
        let foot = village.center + village.layout.hearth * s
        return [SpriteInstance(position: [foot.x, foot.y, 0, -1], sizeAnchor: [size.x, size.y, 0.5, 0.03], uv: .zero,
                               tint: [1, 1, 1, opacity * Self.tribalVillageSmokeThickness],
                               flags: [1, CitySpriteKind.smoke.rawValue, 1, Float(village.tile % 17) * 0.29])]
    }

    /// The strategic token, standing on the hex centre: smaller than a unit's medallion, ivory,
    /// never in a player's colour.
    func tribalVillageToken(_ village: ShownTribalVillage, medallion: Float, uv: SIMD4<Float>, opacity: Float) -> SpriteInstance {
        let disc = medallion * Self.tribalVillageTokenSize, quad = disc / UnitSprite.badgeDisc
        return SpriteInstance(position: [village.center.x, village.center.y, 0, -1], sizeAnchor: [quad, quad, 0.5, 0.5], uv: uv,
                              tint: [1, 1, 1, opacity], flags: [1, TribalVillageSpriteKind.token.rawValue, village.fogged ? 1 : 0, 0])
    }

    /// Where a shown tribal village's figure group stands for the layering
    /// (`UnitFrame.Figures`): the front of the ring its huts stand in, and the ring's middle and
    /// radius (world units).
    func tribalVillageFront(_ village: ShownTribalVillage) -> (feet: SIMD2<Float>, ring: SIMD3<Float>) {
        let s = cityUnit(), middle = village.center + [0, Self.tribalVillageRing.x * s], r = Self.tribalVillageRing.y * s
        return ([middle.x, middle.y - r], SIMD3(middle, r))
    }

    // MARK: Taking

    /// A shown `tribalVillageTaken` at `hex` (normalized): a ghost of the marker the renderer
    /// still holds (the App passes the new markers after `apply`) fades out from `start` on the
    /// animation clock, while its plants fade back in. With no marker there (it was found and
    /// taken in one command) the ghost is the tile's as the viewer sees it now. Nothing fades on
    /// a tile the viewer has not explored, or one already fading.
    func scheduleTribalVillageFade(at hex: HexCoord, start: Double) {
        guard let tile = state.map.index(of: hex), fogLevel(hex) < 2,
              !animation.tribalVillageFades.contains(where: { $0.tile == tile }) else { return }
        let marker = inputs.tribalVillages.first { $0.hex == hex } ?? TribalVillageMarker(hex: hex, seen: fogLevel(hex) == 0)
        animation.tribalVillageFades.append(TribalVillageFade(marker: marker, tile: tile, start: start))
        writeTribalVillageBits()
    }

    /// Drops the fades that are over at `now`: their plants are back for good.
    func finishTribalVillageFades(at now: Double) {
        let count = animation.tribalVillageFades.count
        animation.tribalVillageFades.removeAll { $0.end <= now }
        if animation.tribalVillageFades.count != count { writeTribalVillageBits() }
    }

    /// The `Uniforms` slot (`options.w`) the decorations read: the tile of the running fade that
    /// started first (ties: the lower tile) plus how far its plants are back (0...0.99), or -1
    /// when none runs. A second fade at the same moment brings its plants back at its end.
    func tribalVillageFadeSlot() -> Float {
        let fades = animation.tribalVillageFades
        guard !fades.isEmpty else { return -1 }
        let now = animation.clock
        var best: TribalVillageFade?
        for fade in fades where fade.start <= now && now < fade.end && !inputs.tribalVillages.contains(where: { $0.hex == fade.marker.hex }) {
            if let b = best, (b.start, b.tile) <= (fade.start, fade.tile) { continue }
            best = fade
        }
        guard let best else { return -1 }
        let back = Self.tribalVillageEase(Float((now - best.start) / Self.tribalVillageFadeDuration))
        return Float(best.tile) + min(back, 0.99)
    }

    /// The tiles whose plants hide: every known tribal village's, and every fading ghost's.
    func tribalVillageTiles() -> Set<Int> {
        Set(inputs.tribalVillages.compactMap { state.map.index(of: $0.hex) } + animation.tribalVillageFades.map(\.tile))
    }
}
