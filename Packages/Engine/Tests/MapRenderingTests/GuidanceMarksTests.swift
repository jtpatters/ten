import CoreGraphics
import Foundation
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// The selected unit's guidance on the map (M1 §16, `MapRenderer+Guidance.swift`), on the Duel
/// seed 11 play-test's turns (`GuidanceFixture`): a Builder's job marks, a Settler's best sites
/// ringed over the decorations, and Settlers ready to found a city left undimmed.
@MainActor
@Suite struct GuidanceMarksTests {
    /// The instance of `kind` in the frame's bands layer centered on `hex` (its copy nearest
    /// the camera), if any.
    static func instance(_ r: MapRenderer, _ f: UnitFrame, _ kind: UnitSpriteKind, on hex: HexCoord) -> Int? {
        let c = r.layout.center(of: hex)
        let x = Float(r.layout.nearestCopy(of: c.x, to: CGFloat(r.camera.target.x)))
        return f.bands.first { i in
            f.sprites[i].flags.y == kind.rawValue && abs(f.sprites[i].position.x - x) < 0.01
                && abs(f.sprites[i].position.y - Float(c.y)) < 0.01
        }
    }

    static func count(_ f: UnitFrame, _ kind: UnitSpriteKind) -> Int {
        f.bands.filter { f.sprites[$0].flags.y == kind.rawValue }.count
    }

    /// The T33 Builder on the hill it was sent to: an inked ring on each of its job tiles, solid
    /// where it can start this phase (the mine under it) and dashed where it needs more turns,
    /// under the bases; a glyph badge for each of a job's first two improvements, over the
    /// selection ring. None of them takes a tap.
    @Test func builderJobsAreInkedRingsWithGlyphs() throws {
        let scene = try GuidanceFixture.t33()
        try #require(scene.jobs.contains(where: \.thisPhase) && scene.jobs.contains { !$0.thisPhase })
        try #require(scene.jobs.contains { $0.improvements.count >= 2 })
        let r = GuidanceFixture.view(scene, scale: 0.45)
        let f = r.unitFrame()
        #expect(Self.count(f, .job) == scene.jobs.count)
        let bases = f.bands.filter { f.sprites[$0].flags.y == UnitSpriteKind.base.rawValue }
        for job in scene.jobs {
            let i = try #require(Self.instance(r, f, .job, on: job.hex), "no ring on \(job.hex)")
            #expect(f.sprites[i].tint.x == (job.thisPhase ? 1 : 0), "\(job.hex)")
            #expect(f.owners[i] == nil && bases.allSatisfy { i < $0 })
        }
        let table = r.unitAtlasTable()
        let selection = try #require(f.bands.last { f.sprites[$0].flags.y == UnitSpriteKind.selection.rawValue })
        for kind in Improvement.allCases {
            let uv = try #require(table.job(kind))
            let badges = f.bands.filter { f.sprites[$0].flags.y == UnitSpriteKind.sprite.rawValue && f.sprites[$0].uv == uv }
            #expect(badges.count == scene.jobs.filter { $0.improvements.prefix(2).contains(kind) }.count, "\(kind)")
            #expect(badges.allSatisfy { $0 > selection && f.owners[$0] == nil })
        }
    }

    /// On the T33 Builder's own tile, the solid ring of the mine it can start this phase nests
    /// inside the selection ring's band, clear of it from fully zoomed in to well past standard
    /// zoom (with a gap up to standard zoom), so the band never hides whether it is solid or
    /// dashed; the other job rings keep their inset, and every badge sits at the same place on
    /// its tile.
    @Test(arguments: [Float(0.35), 0.45, 0.6, 1, 1.3])
    func jobRingOnTheSelectedTileClearsTheSelectionRing(scale: Float) throws {
        let scene = try GuidanceFixture.t33()
        let unit = try #require(scene.selected.flatMap { scene.state.unit($0) })
        try #require(scene.jobs.contains { $0.hex == unit.position && $0.thisPhase })
        let r = GuidanceFixture.view(scene, scale: CGFloat(scale))
        let f = r.unitFrame()
        let selection = try #require(Self.instance(r, f, .selection, on: unit.position))
        let own = try #require(Self.instance(r, f, .job, on: unit.position))
        #expect(f.sprites[own].tint.x == 1)
        // A ring's flags.w is its line width and tint.y its inset (world units); the selection
        // band's inner keyline ends 1.3 + 0.5 + 0.34 widths in, the job ring's outer keyline
        // starts 0.5 + 0.42 widths outside its line.
        let band = f.sprites[selection].flags.w, line = f.sprites[own].flags.w, inset = f.sprites[own].tint.y
        let gap: Float = scale <= 1 ? 0.25 * line : 0
        #expect(inset - line * 0.92 >= band * 2.14 + gap, "scale \(scale): ring at \(inset), band to \(band * 2.14)")
        let s = Float(r.layout.size)
        for job in scene.jobs where job.hex != unit.position {
            let i = try #require(Self.instance(r, f, .job, on: job.hex))
            #expect(f.sprites[i].tint.y == MapRenderer.jobRingInset(width: line, size: s))
            #expect(f.sprites[i].tint.y < inset)
        }
        // Each tile's badge lies the same distance south of its center.
        let table = r.unitAtlasTable()
        let mine = try #require(table.job(.mine))
        let offsets = scene.jobs.filter { $0.improvements == [.mine] }.compactMap { job -> Float? in
            let c = r.layout.center(of: job.hex)
            let x = Float(r.layout.nearestCopy(of: c.x, to: CGFloat(r.camera.target.x)))
            return f.bands.first { i in
                f.sprites[i].uv == mine && abs(f.sprites[i].position.x - x) < 0.01 && abs(Float(c.y) - f.sprites[i].position.y) < s
            }.map { Float(c.y) - f.sprites[$0].position.y }
        }
        #expect(offsets.count == scene.jobs.filter { $0.improvements == [.mine] }.count && offsets.count >= 2)
        #expect(offsets.allSatisfy { abs($0 - offsets[0]) < 1e-3 })
    }

    /// Job marks lie on their tile's canonical copy, one per tile (the first given wins), and
    /// never on unexplored tiles; every `setTileScores` call replaces them, so a city's
    /// selection or none (`setTileScores([])`) clears them.
    @Test func jobMarksFollowTheirInput() throws {
        let scene = try GuidanceFixture.t08()
        let map = scene.state.map
        try #require(map.wrapsX)
        let r = GuidanceFixture.view(scene, scale: 0.45)
        let job = try #require(scene.jobs.first).hex
        let hidden = try #require((0..<map.tileCount).map { map.coord(at: $0) }.first { r.fogLevel($0) == 2 })
        let copy = map.coord(at: map.index(of: job)!)
        r.setTileScores([], jobs: [JobMark(hex: HexCoord(q: copy.q + map.width, r: copy.r), improvements: [.mine], thisPhase: true),
                                   JobMark(hex: job, improvements: [.farm], thisPhase: false),
                                   JobMark(hex: hidden, improvements: [.farm], thisPhase: true)])
        #expect(r.inputs.jobMarks.count == 2)
        #expect(r.inputs.jobMarks.first { $0.hex == copy } == JobMark(hex: copy, improvements: [.mine], thisPhase: true))
        let f = r.unitFrame()
        #expect(Self.count(f, .job) == 1 && Self.instance(r, f, .job, on: copy) != nil)
        r.setTileScores([])
        #expect(r.inputs.jobMarks.isEmpty && Self.count(r.unitFrame(), .job) == 0)
    }

    /// The T39 settler overlay round Antium: over the decorations, a gilt ring round each
    /// explored site of the best two tiers (the best tier's stronger), none round the others;
    /// the App's shades fall in the tiers they name.
    @Test func bestSettlerSitesAreRinged() throws {
        for shade in 1...7 { #expect(MapRenderer.scoreTier(GuidanceFixture.overlayByte(shade: shade)) == shade) }
        #expect(MapRenderer.scoreTier(0) == 0 && MapRenderer.scoreTier(1) == 1 && MapRenderer.scoreTier(255) == 7)
        let scene = try GuidanceFixture.t39()
        let map = scene.state.map
        let r = GuidanceFixture.view(scene, scale: 0.6)
        let best = (0..<map.tileCount).filter { MapRenderer.scoreTier(scene.siteScores[$0]) >= 6 && r.fogLevel(map.coord(at: $0)) < 2 }
        try #require(best.count >= 4)
        let f = r.unitFrame()
        #expect(Self.count(f, .site) == best.count)
        for t in best {
            let i = try #require(Self.instance(r, f, .site, on: map.coord(at: t)))
            #expect(f.sprites[i].tint.x == (MapRenderer.scoreTier(scene.siteScores[t]) == 7 ? 1 : 0.55))
            #expect(f.owners[i] == nil)
        }
        r.setTileScores([])
        #expect(Self.count(r.unitFrame(), .site) == 0)
    }

    /// The T36 Settler on Neapolis's site with no moves left may still found a city there, so
    /// the App marks it ready and the map does not dim it; the spent Builder beside it is
    /// dimmed, and so is the Settler once it is no longer ready. A state change keeps it.
    @Test func readySettlerIsNotDimmed() throws {
        let scene = try GuidanceFixture.t36()
        let settler = try #require(scene.ready.first)
        #expect(scene.state.unit(settler)?.movesLeft == 0)
        let builder = try #require(scene.state.units(of: PlayerID(0)).first { $0.type == .builder && $0.movesLeft == 0 })
        let r = GuidanceFixture.view(scene, scale: 0.45, selection: false)
        #expect(r.unitVisuals[settler]?.dimmed == false && r.unitVisuals[builder.id]?.dimmed == true)
        r.setReadyUnits([])
        #expect(r.unitVisuals[settler]?.dimmed == true)
        r.setReadyUnits([settler])
        #expect(r.unitVisuals[settler]?.dimmed == false)
        r.apply(state: scene.state, events: [])
        #expect(r.unitVisuals[settler]?.dimmed == false && r.unitVisuals[builder.id]?.dimmed == true)
    }
}
