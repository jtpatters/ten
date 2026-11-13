import CoreGraphics
import GameCore
import simd

// The selected unit's guidance on the map (M1 §16), drawn by the unit pass in its bands layer
// (`unitFrame`), over the decorations and under the figures, as the selection ring is: a
// Builder's job marks, inked rings with a glyph for what it could build, and gilt rings round a
// Settler's best sites. The settler overlay's tiers themselves are a wash on the ground
// (`markScore` in `ShaderMarks.swift`). Also which own units are ready to act although they have
// no moves left, so they are not dimmed as spent (`setReadyUnits`).

/// A tile a selected Builder could work, as the App passes it (`setTileScores(_:jobs:)`).
public struct JobMark: Hashable, Sendable {
    public var hex: HexCoord
    /// What it could build there, in rules order. The mark shows a glyph for each of the first
    /// two: a sheaf for a farm, a pick for a mine, a paw for a pasture.
    public var improvements: [Improvement]
    /// It could start the job this phase (there with moves left, or reaching it with a move to
    /// spare): a solid ring; else a dashed one.
    public var thisPhase: Bool

    public init(hex: HexCoord, improvements: [Improvement], thisPhase: Bool) {
        self.hex = hex
        self.improvements = improvements
        self.thisPhase = thisPhase
    }
}

/// A settler site in one of the overlay's two best tiers (6 and 7), ringed over the
/// decorations.
struct SiteRing: Hashable {
    var hex: HexCoord
    var tier: Int
}

extension MapRenderer {
    /// The tier (1–7, 0 for none) a settler score falls into: 1 + byte · 7 / 256, as the ground
    /// shader reads it (`writeScoreBits`).
    static func scoreTier(_ byte: UInt8) -> Int { byte == 0 ? 0 : 1 + Int(byte) * 7 / 256 }

    /// The tiers that get a ring over the decorations.
    static let ringedTiers = 6...7

    /// The ringed sites of a settler overlay, in tile order.
    func siteRings(_ scores: [UInt8]) -> [SiteRing] {
        let n = min(scores.count, state.map.tileCount)
        return (0..<n).compactMap { i in
            let tier = Self.scoreTier(scores[i])
            return Self.ringedTiers.contains(tier) ? SiteRing(hex: state.map.coord(at: i), tier: tier) : nil
        }
    }

    /// Job marks as drawn: on the map, one per tile (the first given wins), in tile order.
    func normalizedJobs(_ jobs: [JobMark]) -> [JobMark] {
        var byTile: [Int: JobMark] = [:]
        for var job in jobs {
            guard let hex = state.map.normalize(job.hex), let i = state.map.index(of: hex), byTile[i] == nil else { continue }
            job.hex = hex
            byTile[i] = job
        }
        return byTile.keys.sorted().compactMap { byTile[$0] }
    }

    // MARK: Ready units

    /// Own units that can act this phase although they have no moves left, which the map
    /// therefore does not dim as spent (M1 §15): a Settler that may found a city where it
    /// stands, which needs no moves. The App passes them after every state change (empty:
    /// none).
    public func setReadyUnits(_ ids: [UnitID]) {
        let ready = Set(ids)
        guard ready != inputs.readyUnits else { return }
        inputs.readyUnits = ready
        for unit in state.units where unit.owner == viewer {
            unitVisuals[unit.id]?.dimmed = isDimmed(unit)
        }
    }

    /// Own units with no moves left, an activity or a standing order are dimmed (M1 §15), but
    /// not one that is ready to act (`setReadyUnits`).
    func isDimmed(_ unit: GameCore.Unit) -> Bool {
        unit.owner == viewer && !inputs.readyUnits.contains(unit.id)
            && (unit.movesLeft == 0 || unit.activity != .none || unit.destination != nil)
    }

    // MARK: Drawing (the unit pass's bands layer)

    /// A job ring's ink line and a site ring's gilt band (world units): about 2.4 points at
    /// any zoom, but no more than a tenth of a tile size zoomed far out.
    func guidanceRingWidth() -> Float {
        min(max(2.4 * camera.scale, 1.5), 0.1 * Float(layout.size))
    }

    /// The selection ring's band width (world units), as the unit pass draws it (`unitFrame`):
    /// about 3.2 points, but no less than 1.9 world units zoomed in.
    static func selectionRingWidth(scale: Float) -> Float { max(3.2 * scale, 1.9) }

    /// How far a job ring's line lies inside its tile's edge (world units): 2.4 line widths, at
    /// most 0.24 of a tile size.
    static func jobRingInset(width: Float, size: Float) -> Float { min(width * 2.4, size * 0.24) }

    /// A job ring's inset on the selected unit's own tile: inside the selection ring's band (its
    /// line 1.3 band widths in, half a width each side and a keyline of 0.34, `unitSelectionHex`)
    /// with a gap, so the band does not hide whether the ring is solid or dashed. At most 0.38 of
    /// a tile size: zoomed far out, where the band takes much of the tile, the ring runs partly
    /// under it.
    static func nestedJobRingInset(width: Float, size: Float, selectionWidth: Float) -> Float {
        let clear = selectionWidth * (1.3 + 0.5 + 0.34) + width * (0.5 + 0.42 + 0.4)
        return max(jobRingInset(width: width, size: size), min(clear, size * 0.38))
    }

    /// How far a site ring's band lies inside its tile's edge (world units).
    static func siteRingInset(width: Float, size: Float) -> Float { min(width * 1.6, size * 0.16) }

    /// Rings round the best settler sites and the Builder's job tiles, on explored tiles only.
    /// Drawn with the worked tiles and attack targets, under the bases and the selection ring; on
    /// the selected unit's own tile, the job ring nests inside the selection ring.
    func appendGuidanceRings(into sprites: inout [SpriteInstance]) {
        let sites = inputs.siteRings, jobs = inputs.jobMarks
        guard !sites.isEmpty || !jobs.isEmpty else { return }
        let s = Float(layout.size), width = guidanceRingWidth(), camX = CGFloat(camera.target.x)
        let quad = s * 2.05
        let siteInset = Self.siteRingInset(width: width, size: s), jobInset = Self.jobRingInset(width: width, size: s)
        let selected = inputs.selectionKind == .unit ? unitArt.selection : nil
        let nestedInset = Self.nestedJobRingInset(width: width, size: s, selectionWidth: Self.selectionRingWidth(scale: camera.scale))
        func ring(_ hex: HexCoord, _ kind: UnitSpriteKind, tint: SIMD4<Float>) {
            let c = layout.center(of: hex)
            let x = Float(layout.nearestCopy(of: c.x, to: camX))
            sprites.append(SpriteInstance(position: [x, Float(c.y), 0, -1], sizeAnchor: [quad, quad, 0.5, 0.5], uv: .zero,
                                          tint: tint, flags: [0, kind.rawValue, s, width]))
        }
        for site in sites where fogLevel(site.hex) < 2 {
            ring(site.hex, .site, tint: [site.tier >= 7 ? 1 : 0.55, siteInset, 0, 1])
        }
        for job in jobs where fogLevel(job.hex) < 2 {
            ring(job.hex, .job, tint: [job.thisPhase ? 1 : 0, job.hex == selected ? nestedInset : jobInset, 0, 1])
        }
    }

    /// The width of a job mark's glyph badge on screen (points): 0.36 of a tile's width, kept
    /// between 13 and 26 points so it stays legible zoomed out and modest up close.
    static func jobBadgePoints(tileWidthPoints: Float) -> Float { min(max(0.36 * tileWidthPoints, 13), 26) }

    /// The job marks' glyph badges, flat on the ground on each ring's south corner (two side by
    /// side where the tile allows two improvements), over the bases and the selection ring: a
    /// unit standing on the tile covers only the ring's far side. On the selected unit's own
    /// tile, whose ring nests inside the selection ring, the badge stays at the same place, on
    /// the selection ring's south corner.
    func appendJobBadges(into sprites: inout [SpriteInstance], table: UnitAtlasTable) {
        let jobs = inputs.jobMarks
        guard !jobs.isEmpty, !table.jobs.isEmpty else { return }
        let s = Float(layout.size), scale = camera.scale, camX = CGFloat(camera.target.x)
        let disc = Self.jobBadgePoints(tileWidthPoints: s * 1.7320508 / max(scale, 1e-3)) * scale
        let edge = disc / UnitSprite.badgeDisc
        // The ring's south apex: its line runs `inset` inside the edge, round corners of 0.16
        // of a tile size (`unitHexRing` in `ShaderUnits.swift`).
        let width = guidanceRingWidth(), inset = Self.jobRingInset(width: width, size: s)
        let rc = s * 0.16, inner = s * 0.8660254 - inset - rc
        let apex = inner / 0.8660254 + rc
        for job in jobs where fogLevel(job.hex) < 2 {
            let kinds = Array(job.improvements.prefix(2))
            let c = layout.center(of: job.hex)
            let x = Float(layout.nearestCopy(of: c.x, to: camX)), y = Float(c.y) - apex
            for (k, kind) in kinds.enumerated() {
                guard let uv = table.job(kind) else { continue }
                let dx = kinds.count == 1 ? 0 : (Float(k) - 0.5) * disc * 0.92
                sprites.append(SpriteInstance(position: [x + dx, y, 0, -1], sizeAnchor: [edge, edge, 0.5, 0.5], uv: uv,
                                              tint: [1, 1, 1, 1], flags: [0, UnitSpriteKind.sprite.rawValue, 0, 0]))
            }
        }
    }
}
