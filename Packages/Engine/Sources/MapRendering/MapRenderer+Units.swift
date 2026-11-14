import CoreGraphics
import GameCore
import QuartzCore
import simd

/// A unit's picture: where it rests and, while event animations run, its scheduled steps and
/// this frame's pose (`MapRenderer+Animation.swift`).
struct UnitVisual {
    var type: UnitType
    var owner: PlayerID
    /// Where it rests in the current state (with a stack's offset).
    var base: SIMD2<Float>
    /// Where it stands while it has steps: the end of its last finished move (any wrapped copy).
    var position: SIMD2<Float>
    /// Scheduled changes, by start time.
    var steps: [UnitStep] = []
    /// This frame's pose while a move or a lunge runs (any wrapped copy); nil otherwise.
    var current: SIMD2<Float>?
    /// Where its scheduled moves end, so moves applied while one still runs chain on.
    var planned: SIMD2<Float>?
    var opacity: Float = 1
    /// Hit flash (0...1) this frame.
    var flash: Float = 0
    /// Hit points shown on its HP bar, and the share of full health (0...1) just lost, which
    /// shows cream above them and shrinks away.
    var hp: Int = 100
    var hpTrail: Float = 0
    /// An own unit with no moves left, an activity or a standing order (M1 §15).
    var dimmed = false
    var fortified = false
    /// Gone from the state (killed, disbanded, captured or out of sight): drawn until its
    /// steps end, then dropped.
    var ghost = false
    /// Set by the unit's last movement step or blow (the art faces west). Until it first
    /// moves, a unit faces a side seeded by its id, so a row of idle units doesn't look stamped.
    var facesEast: Bool?

    /// Whether it is walking or striking this frame (it gets a base of its own).
    var moving: Bool { current != nil }

    func display(cameraX: Float, layout: HexLayout) -> SIMD2<Float> {
        if let current { return current }
        let rest = steps.isEmpty ? base : position
        return [Float(layout.nearestCopy(of: CGFloat(rest.x), to: CGFloat(cameraX))), rest.y]
    }
}

/// Meaning of `SpriteInstance.flags.y` in the unit pass, and of flags.z and flags.w for each
/// kind. Must match `ShaderUnits.swift`.
enum UnitSpriteKind: Float {
    /// A unit's shared body, anchored at its feet; its quad is trimmed to the painted figure
    /// and its rim (`UnitSprite.bounds`). tint: owner color, opacity. z: dim amount; w: how
    /// light the ground under it is (`groundLightness`), which sets its rim. position.w: where
    /// its data cell is (`UnitAtlasTable.maskCode`).
    case figure = 0
    /// A standard on its pole, anchored at the pole foot and trimmed like a figure. tint.xy:
    /// the atlas offset from its cell to the shared `standardField` cell; tint.z: the ground's
    /// lightness; tint.w: opacity. z: dim amount (it hangs limp); w: sway phase.
    case standard = 1
    /// A figure's silhouette laid flat away from the sun, trimmed like the figure. w: the
    /// feet's height in the quad.
    case castShadow = 2
    /// A base's band between dark keylines, flat (its contact shadow and wash are
    /// `baseFill`). tint: owner color, opacity. z: dim amount, plus 2 when selected, plus 4 x
    /// the owner's `RingPattern`, plus 32 x the ground's lightness in 255ths; w: band width
    /// (world units).
    case base = 3
    /// An emblem painted on a body's shield. z: dim amount.
    case emblem = 4
    /// An atlas sprite placed by its anchor (medallions, badges, markers, numerals). z: dim
    /// amount.
    case sprite = 5
    /// Breathing ring around the selected strategic medallion.
    case halo = 6
    /// The selection ring on the ground. w: band width (world units).
    case selection = 7
    /// A base's contact shadow and wash, drawn under the decorations (`base` draws its band
    /// over them). Same parameters as `base`.
    case baseFill = 8
    /// A strategic medallion's frame and field (`unitMedallion`): uv is the unit type's
    /// `badge` cell, whose middle fills the field. tint: owner color, opacity. z: dim amount;
    /// w: the owner's `RingPattern`.
    case medallion = 9
    /// A disc in the owner's color with their emblem (`unitEmblemBadge`): uv is the emblem
    /// cell. tint: owner color, opacity. z: dim amount.
    case emblemBadge = 10
    // 11...14 are the cities' (`CitySpriteKind`).
    /// An attack target's threat ring on the ground: crimson corner brackets (`unitThreatHex`).
    /// tint.a: opacity. z: the hex size it rings (world units; 0: a tile); w: band width.
    case threat = 15
    /// A worked tile's gilt ring on the ground. As `threat`.
    case worked = 16
    /// A hurt unit's HP bar, standing. z: hit points (0...1); w: what it had before the
    /// latest hit, shown cream while it shrinks away.
    case hpBar = 17
    /// The fortified marker, standing.
    case fortified = 18
    /// An arrow in flight, standing, turned `w` radians on screen.
    case arrow = 19
    /// A blow's burst, standing. z: how far it has run (0...1).
    case burst = 20
    /// A hit flash over a figure: the figure's quad and uv. tint: color and strength.
    case flash = 21
    /// A Builder's job ring on the ground: an ink line between cream keylines
    /// (`unitJobHex`), its glyph badges `sprite`s (`MapRenderer+Guidance.swift`). tint.x: 1
    /// solid (it can start this phase), 0 dashed; tint.y: how far inside the tile's edge it
    /// runs (world units); tint.a: opacity. z: the hex size it rings; w: line width.
    case job = 22
    /// A ring round one of the settler overlay's best sites: a gilt band between ink keylines
    /// (`unitSiteHex`). tint.x: strength (1 for the best tier); tint.y: its inset, as `job`;
    /// tint.a: opacity. z and w as `job`.
    case site = 23
}

extension MapRenderer {
    /// A unit figure's sprite edge in tile sizes, from standard zoom outward. Closer in it
    /// shrinks toward `figureCloseSize`, so a figure never towers over the trees and hills
    /// around it (ART.md §6).
    static let figureSize: Float = 1.45
    static let figureCloseSize: Float = 1.15

    /// A figure's sprite edge (tile sizes) at a camera scale: `figureSize` from 0.9 outward,
    /// easing (smoothly in log scale) to `figureCloseSize` at 0.4 and closer. A 1% zoom step
    /// changes it by well under 1%, so it never pops.
    static func figureSize(scale: Float) -> Float {
        let t = min(max(log(max(scale, 1e-3) / 0.4) / log(0.9 / 0.4), 0), 1)
        return figureCloseSize + (figureSize - figureCloseSize) * t * t * (3 - 2 * t)
    }

    /// How tall a unit's token stands, as the diameter (in tile sizes) of a circle centered
    /// half of it above the unit's position: a standing figure with its standard or, zoomed
    /// out, a medallion. Updated whenever the unit pass is built. Taps follow the drawn tokens
    /// themselves (`MapRenderer+Picking.swift`); this is the token's rough reach.
    var unitTapSize: Float { unitArt.tapSize }

    /// Camera scales at which units switch to strategic medallions and back. The gap keeps a
    /// resting zoom from ever showing a half-and-half state; the switch itself crossfades.
    /// Where 98% of the widest zoom is below `strategicEnter`, both move down in proportion
    /// (`strategicSwitch`), so the widest zoom always shows the medallions.
    static let strategicEnter: Float = 2.1
    static let strategicLeave: Float = 1.9
    private static let strategicFade: Double = 0.25
    /// The share of the widest zoom from which the medallions show where that is below
    /// `strategicEnter` (a little under 1, so a pinch that stops just short of the widest zoom
    /// still shows them).
    static let strategicWidestShare: Float = 0.98

    /// The scales at which units switch to strategic medallions and back in this view: on from
    /// 2.1 or from 98% of the widest zoom the camera allows (`MapCamera.maxScale`), whichever is
    /// lower, and off below 1.9/2.1 of that (1.9). Only the map's width (the wrap) stops zoom-out
    /// short of 2.1, where the view spans most of a small map (the Duel map on an iPad on its
    /// side stops at about 1.56), so there the widest zoom is already the overview.
    func strategicSwitch() -> (enter: Float, leave: Float) {
        let widest = camera.maxScale(layout: layout) * Self.strategicWidestShare
        guard widest < Self.strategicEnter else { return (Self.strategicEnter, Self.strategicLeave) }
        return (widest, widest * Self.strategicLeave / Self.strategicEnter)
    }

    /// Strategic medallion frame width in view points: about 0.85 of the hex's width on
    /// screen, but no more than `medallionPoints` and no less than `medallionMinPoints`
    /// (`medallionSize`). And the smallest turn markers.
    static let medallionPoints: Float = 24
    static let medallionMinPoints: Float = 18
    static let markerPoints: Float = 16
    /// Smallest emblem on a standard, in view points; the standard grows to keep it, but only a
    /// little (`standardMaxGrowth`): zoomed out further a taller standard would reach over the
    /// row of tiles behind and take their taps (`UnitTapTests`), and the base's ring pattern
    /// and color carry the owner there.
    private static let standardEmblemPoints: Float = 7
    private static let standardMaxGrowth: Float = 1.15
    /// How far a figure's or standard's rim reaches outside its painted extent, in view points
    /// (the cream, the dark line beyond it and some slack for perspective), and how far a cast
    /// shadow's blur reaches outside the figure (left, bottom, right, top, cell fractions).
    private static let rimPadPoints: Float = UnitSprite.rimPoints + UnitSprite.rimLinePoints + 1.2
    private static let shadowPad: SIMD4<Float> = [0.07, 0.02, 0.07, 0.08]
    /// Band widths around an unselected base's ellipse on its quad: the band's outer half, its
    /// keylines (thick-thin's outer line) and the rim, with a little to spare.
    private static let baseTightRoom: Float = 2.8
    /// How far a standard's cloth flutters sideways (cell fractions, `unitStandardWarp`).
    private static let standardFlutter: Float = 0.03

    /// How strongly each part of a unit with no moves left is muted (`dimmed` in
    /// `ShaderUnits.swift`); the standard also hangs limp, which is the clearest cue.
    private static let figureDim: Float = 1, standardDim: Float = 0.5, baseDim: Float = 0.6, medallionDim: Float = 0.6

    /// What `unitFrame` needs of each unit on screen this frame.
    private struct ShownUnit {
        var id: UnitID
        var p: SIMD2<Float>
        var type: UnitType
        var owner: Int
        var dimmed: Bool
        var east: Bool
        /// The hex it stands on, when not moving.
        var hex: HexCoord?
        var opacity: Float = 1
        var flash: Float = 0
        /// Hit points shown (0...1), and what it had before the latest hit (shrinking away).
        var hp: Float = 1
        var hpWas: Float = 1
        var fortified = false
    }

    /// One figure of a spot: which shown unit, where its feet are and its sprite edge.
    private struct Member {
        var index: Int
        var feet: SIMD2<Float>
        var d: Float
    }

    /// Units drawn on one base: a lone unit, or a civilian with its escort.
    private struct Spot {
        var center: SIMD2<Float>
        var owner: Int
        /// The unit carrying the standard (an escort rather than its civilian), and a
        /// civilian traveling with it (indices into the shown units).
        var lead: Int
        var escorted: Int?
        var dimmed: Bool
        var east: Bool
        var hex: HexCoord?
        /// Opacity: a picture fading in or out (its fainter unit's, for a pair).
        var opacity: Float = 1
        /// Its figures, back to front (`placeMembers`), and its base's center and radii.
        var back: Member?
        var front = Member(index: 0, feet: .zero, d: 0)
        var base = SIMD4<Float>.zero
        /// How light the ground it stands on is (`groundLightness`).
        var ground: Float = 0.6
    }

    /// This frame's unit pass, in drawing order: city grounds, base fills and cast shadows
    /// (under the decorations), the rings of worked tiles, attack targets, settler sites and
    /// Builder jobs, base bands, the selection ring and job glyphs, figures with their emblems
    /// and standards and cities back to front, then smoke over damaged cities, (zoomed out)
    /// city tokens and strategic medallions, and turn markers on top.
    func unitFrame() -> UnitFrame {
        let table = unitAtlasTable()
        let s = Float(layout.size), scale = camera.scale, up = camera.up
        let far = strategicBlend(), near = 1 - far
        let tilt = min(camera.pitch / Self.tiltPitch, 1)
        let d = s * Self.figureSize(scale: scale), g = UnitSprite.groundLine
        let medallion = medallionSize()
        let emblemAtRest = UnitSprite.standardEmblemSize * UnitSprite.standardSize * d
        let growth = min(max(Self.standardEmblemPoints * scale / emblemAtRest, 1), Self.standardMaxGrowth)
        // Figures stand a little south of their hex center, on a base that stays inside the
        // hex; top-down (no foreshortening) they stand lower on a flatter base, so the picture
        // is about centered on the hex.
        let footY = s * (-0.3 * tilt - 0.42 * (1 - tilt))
        let single = SIMD2<Float>(0.5, 0.3) + SIMD2(0.1, 0.1) * tilt, stack = SIMD2<Float>(0.66, 0.42) + SIMD2(0.1, 0.06) * tilt

        unitArt.tapSize = figureTapSize(footY: footY, d: d, growth: growth) * near + medallion * 1.2 / s * far

        let camX = camera.target.x
        let players = Palette.playerStyles.count
        let bounds = visibleGround()
        let reach = max(far > 0 ? medallion : 0, s)
        var shown: [ShownUnit] = []
        shown.reserveCapacity(min(unitVisuals.count, 512))
        for (id, visual) in unitVisuals where visual.opacity > 0.003 {
            var p = visual.display(cameraX: camX, layout: layout)
            // Animated pictures may be in any wrapped copy: use the one nearest the camera, so
            // culling sees it where it is drawn. (A moving unit faces its step, `UnitVisual`.)
            p.x = Float(layout.nearestCopy(of: CGFloat(p.x), to: CGFloat(camX)))
            let east = visual.facesEast ?? ((UInt32(truncatingIfNeeded: id.rawValue &* 2_654_435_761) >> 9) & 1 == 1)
            // Cull to the ground in view, with room for figures standing up into it from below
            // and shadows and standards reaching in from the sides.
            if let bounds, p.x < bounds.lo.x - 1.5 * reach || p.x > bounds.hi.x + 1.5 * reach
                || p.y < bounds.lo.y - 2.6 * s - reach || p.y > bounds.hi.y + 1.5 * reach { continue }
            let hex = visual.moving ? nil : layout.hex(at: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
            // A unit is dimmed once its animations are over.
            shown.append(ShownUnit(id: id, p: p, type: visual.type, owner: visual.owner.rawValue % players,
                                   dimmed: visual.dimmed && visual.steps.isEmpty, east: east, hex: hex, opacity: visual.opacity,
                                   flash: visual.flash, hp: Float(visual.hp) / 100, hpWas: Float(visual.hp) / 100 + visual.hpTrail,
                                   fortified: visual.fortified))
        }
        shown.sort { $0.p.y != $1.p.y ? $0.p.y > $1.p.y : $0.id < $1.id }
        var spots = makeSpots(shown)
        // Back to front; level neighbors east to west, so a medallion's corner badges lie over
        // the neighbor to its right.
        spots.sort { $0.center.y != $1.center.y ? $0.center.y > $1.center.y : $0.center.x > $1.center.x }
        for i in spots.indices {
            placeMembers(&spots[i], lead: shown[spots[i].lead].type, footY: footY, d: d)
            if let hex = spots[i].hex {
                spots[i].ground = groundLightness(at: hex)
            } else {
                spots[i].ground = groundLightness(near: spots[i].center)
            }
        }
        settle(&spots, shown: shown, footY: footY, radii: (single * s, stack * s))
        let selected = unitArt.selection
        // Cities and tribal villages, merged into the spots' order just behind the units on
        // their tile: those stand on a city's plaza, in front of the hall, with their base bands
        // drawn after the city (on a tribal village's tile a unit stands only while it fades).
        let towns = shownCities(bounds: bounds)
        let villages = shownTribalVillages(bounds: bounds)
        let townTable = townAtlasTable()
        let cityTiles = Set(towns.compactMap { state.map.normalize($0.marker.hex) })
        var order: [FigureEntry] = []
        do {
            let byDepth = towns.indices.sorted { towns[$0].center.y > towns[$1].center.y }
            let villagesByDepth = villages.indices.sorted { villages[$0].center.y > villages[$1].center.y }
            var settlements: [(y: Float, entry: FigureEntry)] = []
            settlements.reserveCapacity(byDepth.count + villagesByDepth.count)
            var j = 0, k = 0
            while j < byDepth.count || k < villagesByDepth.count {
                if j < byDepth.count, k >= villagesByDepth.count || towns[byDepth[j]].center.y >= villages[villagesByDepth[k]].center.y {
                    settlements.append((towns[byDepth[j]].center.y, .city(byDepth[j])))
                    j += 1
                } else {
                    settlements.append((villages[villagesByDepth[k]].center.y, .tribalVillage(villagesByDepth[k])))
                    k += 1
                }
            }
            var i = 0
            j = 0
            while i < spots.count || j < settlements.count {
                if j < settlements.count, i >= spots.count || settlements[j].y + 0.25 * s > spots[i].center.y {
                    order.append(settlements[j].entry)
                    j += 1
                } else {
                    order.append(.spot(i))
                    i += 1
                }
            }
        }

        var frame = UnitFrame()
        var sprites: [SpriteInstance] = []
        sprites.reserveCapacity(spots.count * 9 + unitArt.markers.count * 3 + 4)
        /// The sprites appended since the last claim select `target` when tapped.
        func claim(_ target: PickTarget?) { frame.owners += repeatElement(target, count: sprites.count - frame.owners.count) }
        /// The tile a tap on a spot's unit selects: the unit's own (where a move is headed) when
        /// the viewer owns it or sees it there, else the spot's, so a ghost walking into the
        /// fog does not pick the hidden tile it is bound for.
        func tile(_ spot: Spot) -> HexCoord? {
            if let live = state.unit(shown[spot.lead].id), live.owner == viewer || fogLevel(live.position) == 0 {
                return live.position
            }
            return spot.hex
        }
        let band = UnitSprite.baseBandPoints * scale
        let rimPad = Self.rimPadPoints * scale
        func base(_ spot: Spot, _ kind: UnitSpriteKind) -> SpriteInstance {
            let isSelected = spot.hex != nil && spot.hex == selected
            // Only a selected base needs room around its band for the glow; the rest are
            // drawn on quads just big enough for the band, keylines and rim, and fills (which
            // stop inside the band) on quads the ellipse's size.
            let room: SIMD2<Float> = kind == .baseFill ? [1, 0]
                : isSelected ? [UnitSprite.baseMargin, UnitSprite.baseBandRoom] : [1, Self.baseTightRoom]
            let r = SIMD2(spot.base.z, spot.base.w) * room.x + band * room.y
            let style = Palette.playerStyles[spot.owner]
            let state = (spot.dimmed ? Self.baseDim : 0) + (isSelected ? 2 : 0) + 4 * Float(style.ring.rawValue)
                + 32 * (min(max(spot.ground, 0), 1) * 255).rounded()
            return SpriteInstance(position: [spot.base.x, spot.base.y, 0, -1], sizeAnchor: [2 * r.x, 2 * r.y, 0.5, 0.5],
                                  uv: [room.x, room.y, 0, 0], tint: SIMD4(style.rgb, near * spot.opacity), flags: [0, kind.rawValue, state, band])
        }

        // Ground layer, under the decorations: city and tribal village grounds, base fills, then
        // cast shadows. (Zoomed out, a faint clearing under the token.)
        for town in towns { sprites.append(cityGround(town, table: townTable, opacity: 0.3 + 0.7 * near)) }
        for village in villages { sprites.append(tribalVillageGround(village, opacity: (0.3 + 0.7 * near) * village.opacity)) }
        claim(nil)
        if near > 0 {
            for spot in spots { sprites.append(base(spot, .baseFill)) }
            for spot in spots {
                for member in [spot.back, spot.front].compactMap({ $0 }) {
                    let escorted = member.index == spot.escorted
                    let type = shown[member.index].type
                    let quad = Self.trim(table.body(type, east: spot.east, escorted: escorted),
                                         box: table.bodyBounds(type, east: spot.east, escorted: escorted),
                                         pad: Self.shadowPad, edge: member.d, pin: [0.5, g], cell: UnitSprite.bodyCell)
                    sprites.append(SpriteInstance(position: [member.feet.x, member.feet.y, 0, -1], sizeAnchor: quad.sizeAnchor,
                                                  uv: quad.uv, tint: [0, 0, 0, 0.38 * near * shown[member.index].opacity],
                                                  flags: [0, UnitSpriteKind.castShadow.rawValue, 0, quad.sizeAnchor.w]))
                }
            }
            claim(nil)
        }
        frame.ground = 0..<sprites.count
        let ringWidth = Self.selectionRingWidth(scale: scale)
        /// A ring on the ground around a hex (`UnitSpriteKind.selection`, `.threat`, `.worked`),
        /// for a hex `size` big (world units).
        func ring(_ hex: HexCoord, _ kind: UnitSpriteKind, size: Float, width: Float) {
            let c = layout.center(of: hex)
            let x = Float(layout.nearestCopy(of: c.x, to: CGFloat(camX)))
            let quad = size * 2.3
            sprites.append(SpriteInstance(position: [x, Float(c.y), 0, -1], sizeAnchor: [quad, quad, 0.5, 0.5], uv: .zero,
                                          tint: [1, 1, 1, 1], flags: [0, kind.rawValue, size, width]))
        }
        /// A settlement's rings run round its walls (zoomed out, round its tile).
        let cityRing = s + ((1.02 * cityUnit() + 1.3 * ringWidth) / 0.866 - s) * near
        // Worked tiles and attack targets, under the bases (a target city's under its walls).
        for hex in inputs.workedTiles where fogLevel(hex) < 2 {
            ring(hex, .worked, size: s, width: max(2.6 * scale, 1.5))
        }
        for hex in inputs.attackTargets where fogLevel(hex) < 2 {
            let city = state.map.normalize(hex).map(cityTiles.contains) ?? false
            ring(hex, .threat, size: city ? cityRing : s, width: ringWidth)
        }
        // A Settler's best sites and a Builder's job tiles (`MapRenderer+Guidance.swift`).
        appendGuidanceRings(into: &sprites)
        // A selected city's ring, under its walls.
        if let selected, inputs.selectionKind == .city, cityTiles.contains(selected) { ring(selected, .selection, size: cityRing, width: ringWidth) }
        claim(nil)
        if near > 0 {
            // Over the decorations: base bands (on a city's tile, after the city).
            for spot in spots where !(spot.hex.map(cityTiles.contains) ?? false) {
                sprites.append(base(spot, .base))
                claim(tile(spot).map(PickTarget.unit))
            }
        }
        /// A unit's selection ring lies over the bases and under every figure (on a city's
        /// tile, over the city).
        func selectionRing(_ selected: HexCoord) {
            ring(selected, .selection, size: s, width: ringWidth)
            claim(nil)
        }
        let unitSelected = inputs.selectionKind == .unit ? selected : nil
        if let unitSelected, near <= 0 || !cityTiles.contains(unitSelected) { selectionRing(unitSelected) }
        // The job marks' glyphs, over the selection ring.
        appendJobBadges(into: &sprites, table: table)
        appendPillagedMarks(into: &sprites, table: table)
        claim(nil)

        frame.bands = frame.ground.upperBound..<sprites.count
        if near > 0 {
            // Figures with their shield emblems and one standard per spot, and cities, back to
            // front.
            for entry in order {
                let index: Int
                switch entry {
                case let .city(j):
                    let town = towns[j], first = sprites.count
                    let target = state.map.normalize(town.marker.hex).map { PickTarget(hex: $0, city: town.marker.id) }
                    sprites += cityPieces(town, table: townTable, opacity: near)
                    claim(target)
                    if let unitSelected, unitSelected == target?.hex { selectionRing(unitSelected) }
                    let front = cityFront(town)
                    frame.figures.append(.init(range: first..<sprites.count, feet: front.feet, size: 2 * front.ring.z, ring: front.ring))
                    continue
                case let .tribalVillage(k):
                    // No tap target: a tap on a tribal village picks the ground.
                    let village = villages[k], first = sprites.count
                    sprites += tribalVillagePieces(village, table: townTable, opacity: near * village.opacity)
                    claim(nil)
                    let front = tribalVillageFront(village)
                    frame.figures.append(.init(range: first..<sprites.count, feet: front.feet, size: 2 * front.ring.z, ring: front.ring))
                    continue
                case let .spot(i):
                    index = i
                }
                let spot = spots[index]
                let first = sprites.count
                if let hex = spot.hex, cityTiles.contains(hex) {
                    sprites.append(base(spot, .base))
                    claim(tile(spot).map(PickTarget.unit))
                }
                let rgb = Palette.playerStyles[spot.owner].rgb
                for member in [spot.back, spot.front].compactMap({ $0 }) {
                    let u = shown[member.index], dm = member.d
                    let dim = u.dimmed ? Self.figureDim : 0
                    let escorted = member.index == spot.escorted
                    let quad = Self.trim(table.body(u.type, east: spot.east, escorted: escorted),
                                         box: table.bodyBounds(u.type, east: spot.east, escorted: escorted),
                                         pad: SIMD4(repeating: rimPad / dm), edge: dm, pin: [0.5, g], cell: UnitSprite.bodyCell)
                    let mask = table.maskCode(u.type, east: spot.east, escorted: escorted)
                    let alpha = near * u.opacity
                    sprites.append(SpriteInstance(position: [member.feet.x, member.feet.y, 0, mask], sizeAnchor: quad.sizeAnchor,
                                                  uv: quad.uv, tint: SIMD4(rgb, alpha), flags: [1, UnitSpriteKind.figure.rawValue, dim, spot.ground]))
                    for e in UnitSprite.emblemSpots(u.type, east: spot.east) {
                        let h = (e.y - g) * dm
                        sprites.append(SpriteInstance(position: [member.feet.x + (e.x - 0.5) * dm, member.feet.y + up.y * h, up.z * h, -1],
                                                      sizeAnchor: [e.z * dm, e.w * dm, 0.5, 0.5], uv: table.emblems[spot.owner],
                                                      tint: [1, 1, 1, alpha], flags: [1, UnitSpriteKind.emblem.rawValue, dim, 0]))
                    }
                    if u.flash > 0.004 {
                        sprites.append(SpriteInstance(position: [member.feet.x, member.feet.y, 0, -1], sizeAnchor: quad.sizeAnchor,
                                                      uv: quad.uv, tint: SIMD4(Self.flashColor, 0.85 * u.flash * alpha),
                                                      flags: [1, UnitSpriteKind.flash.rawValue, 0, 0]))
                    }
                }
                let lead = spot.front, u = shown[lead.index]
                let mount = UnitSprite.standardMount(u.type, east: spot.east)
                let h = (mount.y - g) * lead.d
                let size = UnitSprite.standardSize * lead.d * growth
                let phase = Float(UInt32(truncatingIfNeeded: u.id.rawValue &* 2_654_435_761) % 1000) * 0.0063
                let pad = rimPad / size
                let quad = Self.trim(table.standards[spot.owner], box: table.standardBounds,
                                     pad: [pad + Self.standardFlutter, pad, pad + Self.standardFlutter, pad], edge: size,
                                     pin: UnitSprite.standardFoot, cell: 128)
                let field = table.standardField - table.standards[spot.owner]
                sprites.append(SpriteInstance(position: [lead.feet.x + (mount.x - 0.5) * lead.d, lead.feet.y + up.y * h, up.z * h, -1],
                                              sizeAnchor: quad.sizeAnchor, uv: quad.uv, tint: [field.x, field.y, spot.ground, near * u.opacity],
                                              flags: [1, UnitSpriteKind.standard.rawValue, spot.dimmed ? Self.standardDim : 0, phase]))
                claim(tile(spot).map(PickTarget.unit))
                frame.figures.append(.init(range: first..<sprites.count, feet: lead.feet, size: lead.d))
            }
        }
        let topStart = sprites.count
        if near > 0 {
            for town in towns { sprites += citySmoke(town, opacity: near) }
            for village in villages { sprites += tribalVillageSmoke(village, opacity: near * village.opacity) }
            claim(nil)
        }

        var placed = spots.map(\.center)
        if far > 0 {
            // Tribal villages' tokens (a tap on one picks the ground), then city tokens, under the
            // units' medallions.
            if let uv = table.tribalVillage {
                for village in villages { sprites.append(tribalVillageToken(village, medallion: medallion, uv: uv, opacity: far * village.opacity)) }
                claim(nil)
            }
            for town in towns {
                let owner = town.marker.owner.rawValue % players
                sprites.append(cityToken(town, medallion: medallion, emblem: table.emblems[owner], opacity: far))
                claim(state.map.normalize(town.marker.hex).map { PickTarget(hex: $0, city: town.marker.id) })
            }
            // One medallion per spot, centered on its hex (stepping aside only where
            // neighbors would overlap); the selected one (with its halo) goes last so no
            // neighbor covers it.
            let quad = medallion * UnitSprite.medallionQuad
            let badgeQuad = medallion * UnitSprite.medallionBadgeSize * UnitSprite.badgeQuad
            placed = medallionCenters(spots, frame: medallion)
            var chosen: [SpriteInstance] = [], chosenTile: HexCoord?
            for (i, spot) in spots.enumerated() {
                let u = shown[spot.lead], c = placed[i]
                let isSelected = spot.hex != nil && spot.hex == selected
                var group: [SpriteInstance] = []
                let alpha = far * spot.opacity
                if isSelected {
                    group.append(SpriteInstance(position: [c.x, c.y, 0, -1],
                                                sizeAnchor: [medallion * 1.5, medallion * 1.5, 0.5, 0.5], uv: .zero, tint: [1, 1, 1, alpha],
                                                flags: [1, UnitSpriteKind.halo.rawValue, 0, 0]))
                }
                // The frame and field, then the owner's emblem on a badge at the lower right,
                // toward the hex's corner.
                let style = Palette.playerStyles[spot.owner], dim = spot.dimmed ? Self.medallionDim : 0
                group.append(SpriteInstance(position: [c.x, c.y, 0, -1], sizeAnchor: [quad, quad, 0.5, 0.5],
                                            uv: table.badge(u.type), tint: SIMD4(style.rgb, alpha),
                                            flags: [1, UnitSpriteKind.medallion.rawValue, dim, Float(style.ring.rawValue)]))
                let low = UnitSprite.medallionBadge * medallion
                group.append(SpriteInstance(position: [c.x + low.x, c.y - up.y * low.y, -up.z * low.y, -1],
                                            sizeAnchor: [badgeQuad, badgeQuad, 0.5, 0.5], uv: table.emblems[spot.owner],
                                            tint: SIMD4(style.rgb, alpha), flags: [1, UnitSpriteKind.emblemBadge.rawValue, dim, 0]))
                let off = UnitSprite.medallionBadge * medallion
                let badge = medallion * UnitSprite.medallionBadgeSize / UnitSprite.badgeDisc
                if let civilian = spot.escorted {
                    // An escort wears its civilian's badge on the frame's upper right, toward
                    // the hex's corner, as its emblem badge sits on the lower right.
                    let civ = shown[civilian]
                    group.append(SpriteInstance(position: [c.x + off.x, c.y + up.y * off.y, up.z * off.y, -1],
                                                sizeAnchor: [badge, badge, 0.5, 0.5], uv: table.badge(civ.type), tint: SIMD4(repeating: alpha),
                                                flags: [1, UnitSpriteKind.sprite.rawValue, civ.dimmed ? Self.medallionDim : 0, 0]))
                }
                if u.fortified {
                    // Fortified: the tower marker on the frame's upper left.
                    group.append(SpriteInstance(position: [c.x - off.x, c.y + up.y * off.y, up.z * off.y, -1],
                                                sizeAnchor: [badge, badge, 0.5, 0.5], uv: .zero, tint: SIMD4(repeating: alpha),
                                                flags: [1, UnitSpriteKind.fortified.rawValue, 0, 0]))
                }
                if isSelected {
                    chosen += group
                    chosenTile = tile(spot)
                } else {
                    sprites += group
                    claim(tile(spot).map(PickTarget.unit))
                }
            }
            sprites += chosen
            claim(chosenTile.map(PickTarget.unit))
        }

        // HP bars under hurt units' bases (zoomed out, under their medallions) and fortified
        // markers beside the bases, over everything but the turn markers; then arrows and
        // bursts in flight.
        sprites += unitMarks(spots: spots, shown: shown, placed: placed, near: near, far: far, medallion: medallion, d: d)
        appendEffects(footY: footY, near: near, into: &sprites)
        claim(nil)
        // Where each figure stands this frame, for `screenPoint(ofUnit:)`.
        var anchors: [UnitID: SIMD2<Float>] = [:]
        anchors.reserveCapacity(shown.count)
        for (i, spot) in spots.enumerated() {
            for member in [spot.back, spot.front].compactMap({ $0 }) {
                anchors[shown[member.index].id] = member.feet * near + placed[i] * far
            }
        }
        unitArt.anchors = anchors

        var standing: [HexCoord: (figure: SIMD2<Float>, medallion: SIMD2<Float>, east: Bool)] = [:]
        for (i, spot) in spots.enumerated() {
            if let hex = spot.hex { standing[hex] = (spot.center, placed[i], spot.east) }
        }
        let place = MarkerPlacement(footY: footY, d: d, far: far, medallion: medallion, standing: standing)
        appendMarkers(place: place, table: table, into: &sprites)
        claim(nil)
        frame.top = topStart..<sprites.count
        frame.sprites = sprites
        return frame
    }

    /// A hit flash's color: warm white.
    static let flashColor: SIMD3<Float> = [1, 0.95, 0.82]

    /// HP bars of hurt units and fortified markers (`unitFrame`): up close a bar stands under
    /// the front edge of the base and the tower marker by its left side; zoomed out the bar hangs
    /// under the medallion (whose frame carries the marker).
    private func unitMarks(spots: [Spot], shown: [ShownUnit], placed: [SIMD2<Float>], near: Float, far: Float, medallion m: Float,
                           d: Float) -> [SpriteInstance] {
        let s = Float(layout.size), scale = camera.scale, up = camera.up
        let k = d / (s * Self.figureSize) // figures shrink up close
        var out: [SpriteInstance] = []
        for (i, spot) in spots.enumerated() {
            let lead = shown[spot.lead]
            let hurt = lead.hp < 0.995 || lead.hpWas > lead.hp + 0.001
            let was = max(lead.hpWas, lead.hp)
            if near > 0 {
                let b = spot.base
                if hurt {
                    let w = max(1.25 * b.z, 18 * scale), h = 4.6 * scale
                    out.append(SpriteInstance(position: [b.x, b.y - b.w - 2 * scale, 0, -1], sizeAnchor: [w, h, 0.5, 1], uv: .zero,
                                              tint: [1, 1, 1, near * spot.opacity], flags: [1, UnitSpriteKind.hpBar.rawValue, lead.hp, was]))
                }
                if lead.fortified {
                    let size = max(0.42 * s * k, 12 * scale)
                    out.append(SpriteInstance(position: [b.x - 0.9 * b.z, b.y - 0.2 * b.w, 0, -1], sizeAnchor: [size, size, 0.5, 0.08],
                                              uv: .zero, tint: [1, 1, 1, near * spot.opacity],
                                              flags: [1, UnitSpriteKind.fortified.rawValue, 0, 0]))
                }
            }
            if far > 0, hurt {
                let c = placed[i], drop = 0.6 * m
                out.append(SpriteInstance(position: [c.x, c.y - up.y * drop, -up.z * drop, -1], sizeAnchor: [0.8 * m, 3.8 * scale, 0.5, 1],
                                          uv: .zero, tint: [1, 1, 1, far * spot.opacity],
                                          flags: [1, UnitSpriteKind.hpBar.rawValue, lead.hp, was]))
            }
        }
        return out
    }

    /// Arrows in flight and the bursts of blows (`MapRenderer+Animation.swift`), at the
    /// animation clock: up close they fly between the figures' chests, zoomed out between the
    /// medallions.
    private func appendEffects(footY: Float, near: Float, into sprites: inout [SpriteInstance]) {
        guard !animation.effects.isEmpty else { return }
        let s = Float(layout.size), scale = camera.scale, up = camera.up, now = animation.clock
        let camX = camera.target.x
        let feet = SIMD2<Float>(0, footY * near)
        for effect in animation.effects where effect.start <= now {
            let t = Float(min(max((now - effect.start) / max(effect.duration, 1e-6), 0), 1))
            let from = SIMD2(Float(layout.nearestCopy(of: CGFloat(effect.from.x), to: CGFloat(camX))), effect.from.y)
            let to = SIMD2(Float(layout.nearestCopy(of: CGFloat(effect.to.x), to: CGFloat(from.x))), effect.to.y)
            let lift = effect.lift * s * near
            switch effect.kind {
            case .arrow:
                let arc = 0.22 * simd_distance(from, to) + 0.2 * s
                let g = from + (to - from) * t + feet
                let p = SIMD3(g.x, g.y, 0) + up * (lift.x + (lift.y - lift.x) * t + arc * 4 * t * (1 - t))
                // Its heading on screen: the flight's direction across (x) and up the view.
                let v = SIMD3(to.x - from.x, to.y - from.y, 0) + up * ((lift.y - lift.x) + arc * 4 * (1 - 2 * t))
                let angle = atan2(simd_dot(v, up), v.x)
                let length = max(0.62 * s, 22 * scale)
                let alpha = min(t / 0.08, 1) * min((1 - t) / 0.06, 1)
                sprites.append(SpriteInstance(position: SIMD4(p, -1), sizeAnchor: [length, length * 0.24, 0.5, 0.5], uv: .zero,
                                              tint: [1, 1, 1, alpha], flags: [1, UnitSpriteKind.arrow.rawValue, 0, angle]))
            case .burst:
                let g = to + feet
                let p = SIMD3(g.x, g.y, 0) + up * lift.y
                let size = max(1.0 * s, 30 * scale)
                sprites.append(SpriteInstance(position: SIMD4(p, -1), sizeAnchor: [size, size, 0.5, 0.5], uv: .zero,
                                              tint: [1, 1, 1, 1], flags: [1, UnitSpriteKind.burst.rawValue, t, 0]))
            }
        }
    }

    /// A quad trimmed to `box` (lo x, lo y, hi x, hi y as fractions of its atlas cell, y up)
    /// grown by `pad` (left, bottom, right, top, cell fractions) and kept off the border of
    /// its `cell`-texel cell (so filtering never reaches a neighbor): its uv rect, and its size
    /// and anchor for a cell `edge` world units wide whose point `pin` (cell fractions) stays at
    /// the instance's position. The shader finds the whole cell again from any uv inside it.
    private static func trim(_ uv: SIMD4<Float>, box: SIMD4<Float>, pad: SIMD4<Float>, edge: Float, pin: SIMD2<Float>,
                             cell: Int) -> (uv: SIMD4<Float>, sizeAnchor: SIMD4<Float>) {
        let border = Float(UnitSprite.dataBorder) / Float(cell)
        let lo = simd_max(SIMD2(box.x - pad.x, box.y - pad.y), SIMD2(repeating: border))
        let hi = simd_min(SIMD2(box.z + pad.z, box.w + pad.w), SIMD2(repeating: 1 - border))
        let span = simd_max(hi - lo, SIMD2(repeating: 1e-3))
        let rect = SIMD4(uv.x + lo.x * uv.z, uv.y + (1 - hi.y) * uv.w, span.x * uv.z, span.y * uv.w)
        return (rect, SIMD4(span.x * edge, span.y * edge, (pin.x - lo.x) / span.x, (pin.y - lo.y) / span.y))
    }

    /// How light the ground a unit stands on reads (L* / 100, as measured around units on
    /// each terrain), which picks how its rim sets it apart (`unitRim`): cream lifts it off
    /// dark woods and marsh, and on lighter ground a dark line outside the cream does. Only
    /// the unit's own tile counts, which anyone who sees the unit sees too (ART.md §8).
    /// How light the ground is under a moving unit at `p`: within a quarter tile of a hex edge
    /// it blends toward the hex across it (half and half on the edge), so a unit walking from
    /// one terrain onto another changes its rim gradually instead of switching at the edge.
    private func groundLightness(near p: SIMD2<Float>) -> Float {
        let hex = layout.hex(at: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
        let own = groundLightness(at: hex)
        let c = layout.center(of: hex)
        let v = p - SIMD2(Float(c.x), Float(c.y))
        // The nearest edge: its outward normal (HexDirection order, 60 degrees apart clockwise
        // from east) has the largest projection.
        var nearest = HexDirection.east, reach = -Float.infinity
        for direction in HexDirection.allCases {
            let a = -Float(direction.rawValue) * Float.pi / 3
            let r = v.x * cos(a) + v.y * sin(a)
            if r > reach { (nearest, reach) = (direction, r) }
        }
        let gap = Float(layout.tileWidth) / 2 - reach
        let t = min(max(gap / (0.25 * Float(layout.size)), 0), 1)
        let w = 0.5 * (1 - t * t * (3 - 2 * t))
        guard w > 0 else { return own }
        return own + (groundLightness(at: hex.neighbor(nearest)) - own) * w
    }

    private func groundLightness(at hex: HexCoord) -> Float {
        guard let tile = state.map.normalize(hex).flatMap({ state.map.tile(at: $0) }) else { return 0.6 }
        switch tile.feature {
        case .forest, .jungle: return 0.43
        case .marsh: return 0.6
        default: break
        }
        switch tile.terrain {
        case .grassland, .plains: return 0.68
        case .desert: return 0.8
        case .tundra: return 0.6
        case .snow: return 0.88
        case .coast, .ocean, .lake: return 0.45
        }
    }

    // MARK: Layout

    /// One base per hex: units of one owner standing on the same hex share it (the core moves
    /// a civilian and its escort off the hex center). Moving units get their own.
    private func makeSpots(_ units: [ShownUnit]) -> [Spot] {
        var spots: [Spot] = []
        spots.reserveCapacity(units.count)
        var spotOfHex: [HexCoord: Int] = [:]
        for (i, u) in units.enumerated() {
            guard let hex = u.hex else {
                spots.append(Spot(center: u.p, owner: u.owner, lead: i, dimmed: u.dimmed, east: u.east, hex: nil, opacity: u.opacity))
                continue
            }
            let normalized = state.map.normalize(hex) ?? hex
            let c = layout.center(of: hex)
            var center = SIMD2<Float>(Float(c.x), Float(c.y))
            if let j = spotOfHex[normalized] {
                if spots[j].owner == u.owner, spots[j].escorted == nil {
                    // The second unit on a hex: the military one leads and carries the standard,
                    // and the pair shares one facing.
                    let other = spots[j].lead
                    let (lead, civilian) = u.type.isCivilian ? (other, i) : (i, other)
                    spots[j].lead = lead
                    spots[j].escorted = civilian
                    spots[j].east = units[lead].east
                    spots[j].dimmed = spots[j].dimmed && u.dimmed
                    spots[j].opacity = min(spots[j].opacity, u.opacity)
                    continue
                }
                center = u.p // never expected: keep any third unit where the core puts it
            } else {
                spotOfHex[normalized] = spots.count
            }
            spots.append(Spot(center: center, owner: u.owner, lead: i, dimmed: u.dimmed, east: u.east, hex: normalized, opacity: u.opacity))
        }
        return spots
    }

    /// Where a spot's figures stand. An escorted civilian walks a pace behind its escort,
    /// smaller (as if further away), on the side it is heading to, with a gap between them
    /// that shrinks with the figures up close.
    private func placeMembers(_ spot: inout Spot, lead: UnitType, footY: Float, d: Float) {
        let s = Float(layout.size)
        let feet = SIMD2<Float>(spot.center.x, spot.center.y + footY)
        // The standard bearer steps toward the middle, so the standard (the token's tallest
        // part) rises near the hex's center line rather than over the tiles behind beside it.
        let lean = Self.standardCentering * (UnitSprite.standardMount(lead, east: spot.east).x - 0.5)
        guard let civilian = spot.escorted else {
            spot.front = Member(index: spot.lead, feet: feet - SIMD2(lean * d, 0), d: d)
            return
        }
        let side: Float = spot.east ? 1 : -1, k = d / (s * Self.figureSize)
        spot.back = Member(index: civilian, feet: feet + SIMD2(0.38 * side, 0.24) * s * k, d: d * 0.74)
        spot.front = Member(index: spot.lead, feet: feet + SIMD2(-0.32 * side, -0.12) * s * k - SIMD2(lean * d * 0.86, 0), d: d * 0.86)
    }
    /// How far (as a fraction of its offset from the figure's middle) a standard bearer steps
    /// toward the middle of its spot.
    private static let standardCentering: Float = 0.5

    /// Eases figures and bases toward their places, so when a stack forms or splits its
    /// figures step aside and its base grows or shrinks instead of jumping. Moving units and
    /// anything that jumps far (a wrap, a new turn's state) are placed at once.
    private func settle(_ spots: inout [Spot], shown: [ShownUnit], footY: Float, radii: (single: SIMD2<Float>, stack: SIMD2<Float>)) {
        // Only stack changes ease: a change of tilt or zoom moves every figure and base at once.
        let s = Float(layout.size)
        let steady = abs(footY - unitArt.posesFootY) < 1e-3 * s && abs(camera.scale - unitArt.posesScale) <= 1e-4 * camera.scale
        let ease = steady ? min(unitArt.frameDelta / 0.16, 1) : 1
        let previous = unitArt.poses
        var poses: [UnitID: FigurePose] = [:]
        poses.reserveCapacity(spots.count + spots.count / 4)
        func settle(_ m: inout Member, moving: Bool) -> FigurePose? {
            let id = shown[m.index].id
            let last = previous[id]
            if !moving, let last, simd_distance(last.feet, m.feet) < 1.5 * s {
                m.feet += (last.feet - m.feet) * (1 - ease)
                m.d += (last.d - m.d) * (1 - ease)
            }
            poses[id] = FigurePose(feet: m.feet, d: m.d, base: last?.base)
            return last
        }
        for i in spots.indices {
            let moving = spots[i].hex == nil
            var backLast: FigurePose?
            if var back = spots[i].back {
                backLast = settle(&back, moving: moving)
                spots[i].back = back
            }
            let last = settle(&spots[i].front, moving: moving)
            let r = spots[i].escorted == nil ? radii.single : radii.stack
            var base = SIMD4(spots[i].center.x, spots[i].center.y + footY, r.x, r.y)
            // Both units of a pair remember the base they share. The base grows or shrinks from
            // the nearest one either stood on: after a merge the waiting unit's, after a split
            // the pair's.
            func gap(_ b: SIMD4<Float>) -> Float { simd_distance(SIMD2(b.x, b.y), SIMD2(base.x, base.y)) }
            let old = [last?.base, backLast?.base].compactMap { $0 }.min { gap($0) < gap($1) }
            if !moving, let old, gap(old) < 1.5 * s {
                base += (old - base) * (1 - ease)
            }
            spots[i].base = base
            for member in [spots[i].front, spots[i].back].compactMap({ $0 }) { poses[shown[member.index].id]?.base = base }
        }
        unitArt.poses = poses
        unitArt.posesFootY = footY
        unitArt.posesScale = camera.scale
    }

    /// Tap diameter (tile sizes) that covers a standing unit from its base to its standard's
    /// crossbar, given where its feet are, its figure's edge `d` and how much the standard has
    /// grown.
    private func figureTapSize(footY: Float, d: Float, growth: Float) -> Float {
        let s = Float(layout.size), up = camera.up
        let crossbar = (UnitSprite.standardMountY - UnitSprite.groundLine) * d
            + (UnitSprite.standardClothTop - UnitSprite.standardFoot.y) * UnitSprite.standardSize * d * growth
        // Measured up the view from the unit's position: the circle's center is half its size
        // up (foreshortened by the tilt), its top a radius above that.
        let top = footY * up.y + crossbar
        return max(2 * top / (1 + up.z * up.z), d) / s
    }

    /// Strategic medallion frame width (world units): about 0.85 of the hex's width, so
    /// neighbors' frames keep apart, within `medallionMinPoints`...`medallionPoints` on screen.
    func medallionSize() -> Float {
        let scale = camera.scale
        return min(max(0.85 * Float(layout.tileWidth), Self.medallionMinPoints * scale), Self.medallionPoints * scale)
    }

    /// Where each spot's strategic medallion goes: its hex's center. Zoomed out so far that
    /// frames would overlap (they keep `medallionMinPoints`), neighbors fan apart along the
    /// line between them, each by at most a quarter of a hex; moving units keep their place.
    private func medallionCenters(_ spots: [Spot], frame m: Float) -> [SIMD2<Float>] {
        var centers = spots.map(\.center)
        let width = Float(layout.tileWidth)
        guard m > 0.96 * width else { return centers }
        var index: [HexCoord: Int] = [:]
        for (i, spot) in spots.enumerated() { if let hex = spot.hex { index[hex] = i } }
        var push = [SIMD2<Float>](repeating: .zero, count: spots.count)
        let reach = m * 1.04 // a sliver of ground between frames
        for (i, spot) in spots.enumerated() {
            guard let hex = spot.hex else { continue }
            for direction in [HexDirection.east, .northEast, .northWest] {
                guard let n = state.map.normalize(hex.neighbor(direction)), let j = index[n] else { continue }
                var v = centers[j] - centers[i]
                v.x = Float(layout.nearestCopy(of: CGFloat(centers[j].x), to: CGFloat(centers[i].x))) - centers[i].x
                let gap = simd_length(v)
                guard gap < reach, gap > 1e-3 else { continue }
                let step = v / gap * (reach - gap) * 0.5
                push[i] -= step
                push[j] += step
            }
        }
        let cap = width * 0.25
        for i in centers.indices where spots[i].hex != nil {
            let l = simd_length(push[i])
            centers[i] += l > cap ? push[i] * (cap / l) : push[i]
        }
        return centers
    }

    /// The ground area in view that panels leave uncovered (`setViewportInsets`, with a
    /// margin): its bounding box, or nil when the view reaches the horizon.
    private func visibleGround() -> (lo: SIMD2<Float>, hi: SIMD2<Float>)? {
        let open = uncoveredRect(margin: Self.insetCullMargin)
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for corner in [CGPoint(x: open.minX, y: open.minY), CGPoint(x: open.maxX, y: open.minY), CGPoint(x: open.minX, y: open.maxY),
                       CGPoint(x: open.maxX, y: open.maxY)] {
            guard let g = camera.groundPoint(atViewPoint: corner) else { return nil }
            lo = simd_min(lo, g)
            hi = simd_max(hi, g)
        }
        return (lo, hi)
    }

    /// Advances the switch between standing figures and strategic medallions (0 figures, 1
    /// medallions). The mode flips with hysteresis (`strategicSwitch`) and crossfades over a
    /// quarter second; the first frame and programmatic jumps in zoom switch at once.
    private func strategicBlend() -> Float {
        var art = unitArt
        let now = CACurrentMediaTime(), scale = camera.scale
        let flip = strategicSwitch()
        if art.strategic ? scale < flip.leave : scale >= flip.enter { art.strategic.toggle() }
        let target: Float = art.strategic ? 1 : 0
        art.frameDelta = art.lastFrame.map { Float(min(max(now - $0, 0), 0.1)) } ?? 1
        if art.lastFrame != nil, art.lastScale > 0, abs(log(scale / art.lastScale)) < 0.25 {
            let step = art.frameDelta / Float(Self.strategicFade)
            art.blend += min(max(target - art.blend, -step), step)
        } else {
            art.blend = target
        }
        art.lastFrame = now
        art.lastScale = scale
        unitArt = art
        return art.blend
    }

    /// The atlas rects the unit pass uses every frame, looked up once.
    func unitAtlasTable() -> UnitAtlasTable {
        if let table = unitArt.atlasTable { return table }
        let players = Palette.playerStyles.indices
        var table = UnitAtlasTable()
        // The shader finds each cell's origin from any uv inside it, and a figure's data cell
        // from its index in rows of body cells, in an atlas of the size it was built for
        // (`kUnitAtlasTexels` in `ShaderUnits.swift`).
        assert(unitAtlas.width == SpriteSheet<UnitSprite>.width && unitAtlas.height == SpriteSheet<UnitSprite>.height)
        func code(_ mask: UnitSprite) -> Float {
            let uv = unitAtlas.uv(mask), cell = Float(UnitSprite.bodyCell)
            let x = Int((uv.x * Float(unitAtlas.width) / cell).rounded()), y = Int((uv.y * Float(unitAtlas.height) / cell).rounded())
            assert(abs(uv.z * Float(unitAtlas.width) - cell) < 1e-3, "data cells are body cells")
            return Float(y * (unitAtlas.width / UnitSprite.bodyCell) + x + 1)
        }
        for type in UnitType.allCases {
            for east in [false, true] {
                if east, UnitSprite.sharesWestBody(type) {
                    // The west-facing cell read right to left (a negative width), its box mirrored.
                    let uv = unitAtlas.uv(.body(type, east: false)), box = UnitSprite.bounds(.body(type, east: false))
                    table.bodies.append(SIMD4(uv.x + uv.z, uv.y, -uv.z, uv.w))
                    table.bodyBoxes.append(SIMD4(1 - box.z, box.y, 1 - box.x, box.w))
                } else {
                    table.bodies.append(unitAtlas.uv(.body(type, east: east)))
                    table.bodyBoxes.append(UnitSprite.bounds(.body(type, east: east)))
                }
            }
            // A fraction of a quarter: the data is in the cell's blue and alpha (`dataCell`).
            let data = UnitSprite.dataCell(type)
            table.masks.append(code(.teamMask(data.key)) + (data.high ? 0.25 : 0))
        }
        table.escorted = [false, true].map { unitAtlas.uv(.escortedBody(east: $0)) }
        table.escortedBoxes = [false, true].map { UnitSprite.bounds(.escortedBody(east: $0)) }
        table.escortedMask = code(.escortedMask)
        table.standards = players.map { unitAtlas.uv(.standard(player: $0)) }
        table.standardBounds = UnitSprite.bounds(.standard(player: 0))
        table.standardField = unitAtlas.uv(.standardField)
        table.emblems = players.map { unitAtlas.uv(.emblem(player: $0)) }
        table.badges = UnitType.allCases.map { unitAtlas.uv(.badge($0)) }
        table.markers = [unitAtlas.uv(.marker(final: false)), unitAtlas.uv(.marker(final: true))]
        table.digits = (0...9).map { unitAtlas.uv(.digit($0)) }
        for kind in Improvement.allCases { table.jobs[kind.rawValue] = unitAtlas.uv(.job(kind)) }
        table.tribalVillage = unitAtlas.uv(.tribalVillage)
        table.pillaged = unitAtlas.uv(.pillaged)
        unitArt.atlasTable = table
        return table
    }

    // MARK: Turn markers

    /// What turn markers need to step aside from units on their hexes.
    private struct MarkerPlacement {
        var footY: Float
        /// The figures' sprite edge.
        var d: Float
        /// How far the switch to strategic medallions has run, and the medallions' frame width.
        var far: Float
        var medallion: Float
        /// By hex, where a unit stands there: its spot's center, its medallion's and its facing.
        var standing: [HexCoord: (figure: SIMD2<Float>, medallion: SIMD2<Float>, east: Bool)]
    }

    /// The route's turn markers. Up close every turn end gets a numbered pin. Zoomed out
    /// (crossfading with the medallions) only the first turn, every fifth and the destination
    /// (which shows the total) keep their numbers, each only if clear of the labels kept
    /// before it by 1.2 markers; the rest become small ticks, so a long route doesn't bury the
    /// map in overlapping pins.
    private func appendMarkers(place: MarkerPlacement, table: UnitAtlasTable, into sprites: inout [SpriteInstance]) {
        let markers = unitArt.markers
        guard !markers.isEmpty else { return }
        let m = max(Float(layout.size) * 0.7, Self.markerPoints * camera.scale)
        var labeled = [Bool](repeating: true, count: markers.count)
        if place.far > 0 {
            func rank(_ i: Int) -> Int { markers[i].final ? 0 : (markers[i].turn == 1 ? 1 : 2) }
            let candidates = markers.indices.filter { markers[$0].final || markers[$0].turn == 1 || markers[$0].turn % 5 == 0 }
                .sorted { rank($0) != rank($1) ? rank($0) < rank($1) : markers[$0].turn < markers[$1].turn }
            var kept: [SIMD3<Float>] = []
            labeled = [Bool](repeating: false, count: markers.count)
            for i in candidates {
                let p = markerPoint(markers[i], place: place)
                guard kept.allSatisfy({ simd_distance($0, p) >= 1.2 * m }) else { continue }
                labeled[i] = true
                kept.append(p)
            }
        }
        for (i, marker) in markers.enumerated() {
            if labeled[i] {
                appendMarker(marker, size: m, opacity: 1, place: place, table: table, into: &sprites)
            } else {
                // Crossfades into a tick as the medallions come in.
                if place.far < 1 { appendMarker(marker, size: m, opacity: 1 - place.far, place: place, table: table, into: &sprites) }
                appendTick(marker, size: m, opacity: place.far, table: table, into: &sprites)
            }
        }
    }

    /// Where a marker floats: beside the figure standing on its hex on the side away from its
    /// heading (above the lower rump or tailboard, clear of heads and the standard), or beside
    /// the medallion zoomed out; on the hex's center when nothing stands there.
    private func markerPoint(_ marker: PathMarker, place: MarkerPlacement) -> SIMD3<Float> {
        let s = Float(layout.size), up = camera.up
        let x = Float(layout.nearestCopy(of: CGFloat(marker.position.x), to: CGFloat(camera.target.x)))
        guard let spot = place.standing[marker.hex] else { return [x, marker.position.y, 0] }
        if place.far >= 0.5 {
            let c = spot.medallion, h = -0.3 * place.medallion
            return [c.x + 0.62 * place.medallion, c.y + up.y * h, up.z * h]
        }
        let k = place.d / (s * Self.figureSize) // figures shrink up close
        let side = (spot.east ? -0.52 : 0.52) * s * k, h = 0.6 * s * k
        return [spot.figure.x + side, spot.figure.y + place.footY + up.y * h, up.z * h]
    }

    /// A numbered turn marker: a pin standing on its hex with the numerals floating on its
    /// face (the destination's shows the route's total turns).
    private func appendMarker(_ marker: PathMarker, size m: Float, opacity: Float, place: MarkerPlacement, table: UnitAtlasTable,
                              into sprites: inout [SpriteInstance]) {
        let up = camera.up
        let p = markerPoint(marker, place: place)
        sprites.append(SpriteInstance(position: SIMD4(p, -1), sizeAnchor: [m, m, 0.5, UnitSprite.markerPin],
                                      uv: table.markers[marker.final ? 1 : 0], tint: SIMD4(repeating: opacity),
                                      flags: [1, UnitSpriteKind.sprite.rawValue, 0, 0]))
        let h = (UnitSprite.markerFace - UnitSprite.markerPin) * m
        let center = p + SIMD3(0, up.y * h, up.z * h)
        let ink: SIMD3<Float> = marker.final ? [0.22, 0.14, 0.08] : [0.99, 0.95, 0.84]
        let digits = String(min(marker.turn, 99)).compactMap(\.wholeNumberValue)
        let size = m * (digits.count == 1 ? 0.7 : 0.58)
        for (i, digit) in digits.enumerated() {
            let dx = digits.count == 1 ? 0 : (Float(i) - 0.5) * m * 0.25
            sprites.append(SpriteInstance(position: [center.x + dx, center.y, center.z, -1], sizeAnchor: [size, size, 0.5, 0.5],
                                          uv: table.digits[digit], tint: SIMD4(ink * opacity, opacity),
                                          flags: [1, UnitSpriteKind.sprite.rawValue, 0, 0]))
        }
    }

    /// An unlabeled turn end zoomed out: a small blank pin on the route.
    private func appendTick(_ marker: PathMarker, size m: Float, opacity: Float, table: UnitAtlasTable,
                            into sprites: inout [SpriteInstance]) {
        guard opacity > 0 else { return }
        let x = Float(layout.nearestCopy(of: CGFloat(marker.position.x), to: CGFloat(camera.target.x)))
        let k = m * 0.45
        sprites.append(SpriteInstance(position: [x, marker.position.y, 0, -1], sizeAnchor: [k, k, 0.5, UnitSprite.markerPin],
                                      uv: table.markers[0], tint: SIMD4(repeating: opacity), flags: [1, UnitSpriteKind.sprite.rawValue, 0, 0]))
    }
}

/// One entry of the unit pass's figure groups, back to front (`unitFrame`): a spot of units, a
/// city or a tribal village, by its index this frame.
enum FigureEntry {
    case spot(Int), city(Int), tribalVillage(Int)
}

/// Atlas rects of the unit sprites, looked up once (`unitAtlasTable`).
struct UnitAtlasTable {
    /// Each unit type's position in `allCases` (which builds a new array on every call).
    private static let typeIndex = Dictionary(uniqueKeysWithValues: UnitType.allCases.enumerated().map { ($1, $0) })

    /// Bodies by type and facing (type index * 2 + east), and the settler without its pole by
    /// facing (when its escort carries the standard), with what each paints of its cell
    /// (`UnitSprite.bounds`).
    var bodies: [SIMD4<Float>] = []
    var bodyBoxes: [SIMD4<Float>] = []
    var escorted: [SIMD4<Float>] = []
    var escortedBoxes: [SIMD4<Float>] = []
    /// Where each type's data cell is (its index in rows of body cells, plus one), and the
    /// settler's without its pole: `maskCode`.
    var masks: [Float] = []
    var escortedMask: Float = 0
    var standards: [SIMD4<Float>] = []
    var standardBounds = SIMD4<Float>(0, 0, 1, 1)
    /// The silhouette distance field every standard shares (`UnitSprite.standardField`).
    var standardField = SIMD4<Float>.zero
    var emblems: [SIMD4<Float>] = []
    var badges: [SIMD4<Float>] = []
    var markers: [SIMD4<Float>] = []
    var digits: [SIMD4<Float>] = []
    /// The job marks' glyph badges, by `Improvement` raw value.
    var jobs: [UInt8: SIMD4<Float>] = [:]
    /// The tribal villages' strategic token (`UnitSprite.tribalVillage`).
    var tribalVillage: SIMD4<Float>?
    /// A pillaged improvement's mark (`UnitSprite.pillaged`).
    var pillaged: SIMD4<Float>?

    func body(_ type: UnitType, east: Bool, escorted isEscorted: Bool = false) -> SIMD4<Float> {
        // Only the settler sets its banner pole down when escorted: the builder's pole is its
        // surveyor's rod.
        if isEscorted, type == .settler { return escorted[east ? 1 : 0] }
        return bodies[(Self.typeIndex[type] ?? 0) * 2 + (east ? 1 : 0)]
    }

    func bodyBounds(_ type: UnitType, east: Bool, escorted isEscorted: Bool = false) -> SIMD4<Float> {
        if isEscorted, type == .settler { return escortedBoxes[east ? 1 : 0] }
        return bodyBoxes[(Self.typeIndex[type] ?? 0) * 2 + (east ? 1 : 0)]
    }

    /// A figure instance's position.w: its data cell's index in the atlas's rows of body cells
    /// plus one, negative when the east-facing body reads the west-facing body's data mirrored.
    func maskCode(_ type: UnitType, east: Bool, escorted isEscorted: Bool = false) -> Float {
        let code = isEscorted && type == .settler ? escortedMask : masks[Self.typeIndex[type] ?? 0]
        // A mirrored west-facing body reads its own data as it is.
        return east && (isEscorted || !UnitSprite.sharesWestBody(type)) ? -code : code
    }

    func badge(_ type: UnitType) -> SIMD4<Float> { badges[Self.typeIndex[type] ?? 0] }

    func job(_ kind: Improvement) -> SIMD4<Float>? { jobs[kind.rawValue] }
}
