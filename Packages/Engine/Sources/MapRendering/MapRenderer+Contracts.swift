import CoreGraphics
import GameCore
import simd
#if canImport(UIKit)
import UIKit
#endif

// The renderer's M1 interface to the App (M1 §15): cities, territory and improvements as the
// viewer knows them, overlays, picking, screen positions for text drawn over the map, and the
// players' heraldry. The App builds every input from the viewer's PlayerView, so fog never
// leaks; MapRendering never reads cities or memory from `GameState`.
//
// Cities are drawn by `MapRenderer+Cities.swift`; territory, improvements, the movement range
// and the settler scores by `MapRenderer+Territory.swift` (with the ground, decoration and
// overlay shaders); attack targets, the selection and worked tiles by the unit pass
// (`MapRenderer+Units.swift`), as are the rings of the best settler sites and Builder jobs, and
// which units are ready though spent (`MapRenderer+Guidance.swift`). Tribal villages (M1 §7.7)
// are drawn by the same pass, from the settlement kit (`MapRenderer+TribalVillages.swift`).

/// A city as the viewer knows it: own cities live, foreign ones as last seen.
public struct CityMarker: Hashable, Sendable {
    /// The city's id (`CityID.rawValue`).
    public var id: Int
    public var hex: HexCoord
    public var owner: PlayerID
    public var population: Int
    public var capital: Bool
    public var walls: Bool
    /// Hit points as a fraction of full (hp / 200).
    public var hp: Float
    /// Wall hit points as a fraction of full (wall HP / 100).
    public var wallHP: Float

    public init(id: Int, hex: HexCoord, owner: PlayerID, population: Int, capital: Bool, walls: Bool, hp: Float, wallHP: Float) {
        self.id = id
        self.hex = hex
        self.owner = owner
        self.population = population
        self.capital = capital
        self.walls = walls
        self.hp = hp
        self.wallHP = wallHP
    }
}

/// A tribal village as the viewer knows it (M1 §7.7): `seen` when its tile is in sight now,
/// else remembered (as last seen, in the fog).
public struct TribalVillageMarker: Hashable, Sendable {
    public var hex: HexCoord
    public var seen: Bool

    public init(hex: HexCoord, seen: Bool) {
        self.hex = hex
        self.seen = seen
    }
}

/// What the selected hex holds.
public enum SelectionKind: Hashable, Sendable {
    case unit, city
}

/// What a view point shows: a unit's token (its tile), a city (its id and tile), or the ground.
public enum MapHit: Hashable, Sendable {
    case unit(HexCoord)
    case city(id: Int, HexCoord)
    case ground(HexCoord)
}

/// Insets of the view in points, such as the area panels cover: `UIEdgeInsets` without UIKit,
/// since the renderer also builds for macOS (tests).
public struct MapInsets: Hashable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = MapInsets()
}

#if canImport(UIKit)
extension MapInsets {
    public init(_ insets: UIEdgeInsets) {
        self.init(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
    }
}
#endif

/// The inputs as last set (`MapRenderer.inputs`). Per-tile arrays are either empty (nothing to
/// show) or hold one entry per tile, in tile index order.
struct MapInputs {
    var cities: [CityMarker] = []
    /// Per tile: 0 none, else the owner's player index + 1.
    var territory: [UInt8] = []
    /// Per tile: the `Improvement` raw value, 0 none.
    var improvements: [UInt8] = []
    /// Per tile: the `Resource` raw value the viewer knows there, 0 none.
    var resources: [UInt8] = []
    var movementRange: [HexCoord] = []
    var attackTargets: [HexCoord] = []
    var selectionKind = SelectionKind.unit
    var workedTiles: [HexCoord] = []
    /// Per tile: the settler overlay's site score, 0 none.
    var tileScores: [UInt8] = []
    /// The settler overlay's best sites, ringed (from `tileScores`).
    var siteRings: [SiteRing] = []
    /// The selected Builder's job marks, one per tile, in tile order.
    var jobMarks: [JobMark] = []
    /// Own units ready to act with no moves left, not dimmed (`setReadyUnits`).
    var readyUnits: Set<UnitID> = []
    /// The tribal villages the viewer knows, one per tile, in tile order (`setTribalVillages`).
    var tribalVillages: [TribalVillageMarker] = []
    var viewportInsets = MapInsets.zero
}

extension MapRenderer {
    // MARK: Inputs

    /// The cities the viewer knows, sorted by id. Drawn as settlements on explored tiles
    /// (`MapRenderer+Cities.swift`); decorations hide on their center tiles.
    public func setCities(_ cities: [CityMarker]) {
        guard cities != inputs.cities else { return }
        inputs.cities = cities
        markCityCentres(Set(cities.compactMap { state.map.normalize($0.hex).flatMap(state.map.index(of:)) }))
        cityArt.version &+= 1
    }

    /// Territory as the viewer knows it: per tile 0 for none, else the owner's index + 1.
    /// Drawn as borders in the owner's colour and ring pattern, where the tiles on both sides
    /// are explored, with a soft tint of that colour inside (`MapRenderer+Territory.swift`).
    public func setTerritory(_ owners: [UInt8]) {
        assert(owners.isEmpty || owners.count == state.map.tileCount, "territory needs one entry per tile")
        guard owners != inputs.territory else { return }
        inputs.territory = owners
        writeTerritoryBits()
    }

    /// Improvements as the viewer knows them: per tile the `Improvement` raw value, 0 for none.
    /// Farms and pastures are painted on the ground, mines and herds stand as decorations, and
    /// other decorations clear or thin out on improved tiles.
    public func setImprovements(_ kinds: [UInt8]) {
        assert(kinds.isEmpty || kinds.count == state.map.tileCount, "improvements need one entry per tile")
        guard kinds != inputs.improvements else { return }
        inputs.improvements = kinds
        writeImprovementBits()
    }

    /// Resources as the viewer knows them (M2 §3.1, `PlayerView.resource(at:)`): per tile the
    /// `Resource` raw value, 0 for none or not yet revealed. Each known one shows its icon on
    /// the tile (an explored tile only); a resource never changes, so the icon drawn is the
    /// map's.
    public func setResources(_ kinds: [UInt8]) {
        assert(kinds.isEmpty || kinds.count == state.map.tileCount, "resources need one entry per tile")
        guard kinds != inputs.resources else { return }
        inputs.resources = kinds
        writeResourceBits()
    }

    /// The tiles the selected unit can reach this phase (empty: none): a soft cream wash with
    /// an outline around them (and the selected unit's tile).
    public func setMovementRange(_ tiles: [HexCoord]) {
        guard tiles != inputs.movementRange else { return }
        inputs.movementRange = tiles
        writeRangeBits()
    }

    /// The tiles the selected unit or city can attack this phase (empty: none): each gets a
    /// warm threat ring, never a player colour.
    public func setAttackTargets(_ tiles: [HexCoord]) {
        inputs.attackTargets = tiles
    }

    /// Selects a unit's or a city's hex, or clears the selection (nil). A city's ring is drawn
    /// around its whole settlement.
    public func setSelection(_ hex: HexCoord?, kind: SelectionKind) {
        let selection = hex.flatMap { state.map.normalize($0) }
        if selection != unitArt.selection || kind != inputs.selectionKind { territoryArt.rangeVersion += 1 }
        inputs.selectionKind = kind
        unitArt.selection = selection
    }

    /// The selected city's worked tiles (empty while no city is selected): a ring on each.
    public func setWorkedTiles(_ tiles: [HexCoord]) {
        inputs.workedTiles = tiles
    }

    /// The selected unit's tile overlay (empty: none). A Settler's: per tile a site score, 0
    /// for none. Scores fall into seven tiers, a wash on the ground from dimmed (poor) to gilt
    /// (best), kept over remembered land; the two best tiers also get a gilt ring over the
    /// decorations. A Builder's: its jobs, each an inked ring over the decorations with a glyph
    /// for what it could build, solid where it can start this phase and dashed where it needs
    /// more turns (`JobMark`, `MapRenderer+Guidance.swift`). Each call sets both.
    public func setTileScores(_ scores: [UInt8], jobs: [JobMark] = []) {
        assert(scores.isEmpty || scores.count == state.map.tileCount, "tile scores need one entry per tile")
        inputs.jobMarks = normalizedJobs(jobs)
        guard scores != inputs.tileScores else { return }
        inputs.tileScores = scores
        inputs.siteRings = siteRings(scores)
        writeScoreBits()
    }

    /// The tribal villages the viewer knows (M1 §7.7), as the App builds them from
    /// `PlayerView.knownTribalVillages` (seen on visible tiles, else remembered; in diagnostic
    /// mode the live ones, all seen). Kept one per tile (the first given wins), in tile order.
    /// Each on explored land is drawn as two round huts and a wood pile on a little trodden
    /// ground, with a thin column of smoke from its cooking fire while seen; remembered, in the
    /// explored-fog look without smoke; zoomed out, as a small ivory token
    /// (`MapRenderer+TribalVillages.swift`). The plants standing on their tiles hide
    /// (`TileBits.tribalVillage`: this setter touches only that bit). A tap on one picks the
    /// ground. A shown `tribalVillageTaken` fades the marker the renderer still holds (the App
    /// passes the new ones after `apply`) as its plants fade back in, from when the unit that
    /// took it reaches the tile, and is reported through `onEventShown` at the tile as the fade
    /// starts.
    public func setTribalVillages(_ villages: [TribalVillageMarker]) {
        let markers = normalizedTribalVillages(villages)
        guard markers != inputs.tribalVillages else { return }
        inputs.tribalVillages = markers
        writeTribalVillageBits()
    }

    /// Tribal village markers as drawn: on the map, one per tile (the first given wins), in tile
    /// order.
    func normalizedTribalVillages(_ villages: [TribalVillageMarker]) -> [TribalVillageMarker] {
        var byTile: [Int: TribalVillageMarker] = [:]
        for var village in villages {
            guard let hex = state.map.normalize(village.hex), let i = state.map.index(of: hex), byTile[i] == nil else { continue }
            village.hex = hex
            byTile[i] = village
        }
        return byTile.keys.sorted().compactMap { byTile[$0] }
    }

    /// The edges of the view that panels cover, in points: `centerCamera` centres hexes in
    /// the rest, sprites under the panels (beyond `insetCullMargin`) are not drawn, and the
    /// camera may bring the map's polar edges up to the top and bottom panels (the polar pack
    /// fills the band under them). The ground is always drawn whole.
    public func setViewportInsets(_ insets: MapInsets) {
        inputs.viewportInsets = insets
        widenCoveredBands(to: insets)
    }

    /// How far past the panels' edges sprites are still drawn (points), so nothing pops in at
    /// the edge of a panel sliding away.
    static let insetCullMargin: CGFloat = 24

    /// The part of the view (points, origin top-left) that panels leave uncovered, grown by
    /// `margin` and kept within the view (the whole view when the insets leave nothing).
    func uncoveredRect(margin: CGFloat = 0) -> CGRect {
        let w = CGFloat(camera.viewSize.x), h = CGFloat(camera.viewSize.y), i = inputs.viewportInsets
        let view = CGRect(x: 0, y: 0, width: w, height: h)
        guard w - i.left - i.right >= 1, h - i.top - i.bottom >= 1 else { return view }
        let open = CGRect(x: i.left, y: i.top, width: w - i.left - i.right, height: h - i.top - i.bottom)
        return open.insetBy(dx: -margin, dy: -margin).intersection(view)
    }

    #if canImport(UIKit)
    public func setViewportInsets(_ insets: UIEdgeInsets) {
        setViewportInsets(MapInsets(insets))
    }
    #endif

    // MARK: Picking and screen positions

    /// What a tap at a view point (points, origin top-left) selects: a unit where its token is
    /// drawn, a city where its buildings or token are (units standing in a city are drawn over
    /// it and win), else the ground (as `hex(atViewPoint:)` resolves them); nil off the map.
    public func hitTest(atViewPoint point: CGPoint) -> MapHit? {
        guard let tap = tap(atViewPoint: point) else { return nil }
        guard let hit = tap.hit else { return .ground(tap.hex) }
        if let city = hit.city { return .city(id: city, hit.hex) }
        return .unit(hit.hex)
    }

    /// Where a hex's center, raised `lift` tile sizes the way sprites stand, appears in the view
    /// (points, origin top-left; possibly off screen), or nil when the hex is off the map or the
    /// point is behind the camera.
    public func screenPoint(of hex: HexCoord, lift: Float = 0) -> CGPoint? {
        guard state.map.normalize(hex) != nil else { return nil }
        return viewPoint(ofGround: Self.vec(layout.center(of: hex)), lift: lift)
    }

    public func screenPoints(of hexes: [HexCoord], lift: Float) -> [CGPoint?] {
        hexes.map { screenPoint(of: $0, lift: lift) }
    }

    /// Where a unit is drawn, raised `lift` tile sizes: its figure's feet as the last frame drew
    /// them (walking, striking, or stepped aside for its escort; zoomed out, its medallion's
    /// middle), or nil when the viewer does not see it.
    public func screenPoint(ofUnit id: UnitID, lift: Float = 0) -> CGPoint? {
        guard let visual = unitVisuals[id] else { return nil }
        let p = unitArt.anchors[id] ?? visual.display(cameraX: camera.target.x, layout: layout)
        return viewPoint(ofGround: p, lift: lift)
    }

    /// Whether units and cities are drawn as strategic tokens (zoomed out; switched with
    /// hysteresis as the last frame was drawn: on from camera scale 2.1, off below 1.9, or at
    /// the widest zoom where the wrap stops zoom-out short of 2.1), so banners can switch their
    /// content in step with the tokens (M1 §16).
    public var showsStrategicTokens: Bool { unitArt.strategic }

    /// The top of a city's sprite (its tallest building, or its token zoomed out), where its
    /// banner hangs, or nil for a city not in `setCities` or off the map.
    public func bannerAnchor(city id: Int) -> CGPoint? {
        guard let city = inputs.cities.first(where: { $0.id == id }) else { return nil }
        return cityTop(city)
    }

    /// A ground point (world, any wrapped copy) in view points, raised `lift` tile sizes along
    /// the camera's up, as billboards stand.
    private func viewPoint(ofGround p: SIMD2<Float>, lift: Float) -> CGPoint? {
        let x = Float(layout.nearestCopy(of: CGFloat(p.x), to: CGFloat(camera.target.x)))
        return camera.viewPoint(of: SIMD3(x, p.y, 0) + camera.up * (lift * Float(layout.size)))
    }
}

/// The players' colors and emblems, so the App draws banners, cards and chips in the map's
/// heraldry (`PlayerPalette.swift`).
public enum Heraldry {
    public static func color(_ player: PlayerID) -> CGColor {
        Palette.player(player)
    }

    /// The player's emblem in its contrasting ink, as on their shields, standards and city
    /// tokens, on a clear background: `size` points square, drawn at three pixels per point
    /// (`UIImage(cgImage:scale: 3, orientation: .up)`).
    public static func emblemImage(_ player: PlayerID, size: CGFloat) -> CGImage? {
        let pixels = Int((size * emblemPixelsPerPoint).rounded(.up))
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Sprite cells are drawn into their rect inset by a twentieth (`SpriteSet`).
        let edge = CGFloat(pixels)
        UnitSprite.emblem(player: player.rawValue % Palette.playerStyles.count)
            .draw(in: CGRect(x: 0, y: 0, width: edge, height: edge).insetBy(dx: edge / 20, dy: edge / 20), ctx: ctx)
        return ctx.makeImage()
    }

    static let emblemPixelsPerPoint: CGFloat = 3
}
