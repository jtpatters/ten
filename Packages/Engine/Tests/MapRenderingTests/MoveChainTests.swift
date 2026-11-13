import CoreGraphics
import Foundation
import Testing
import GameCore
import simd
@testable import MapRendering

/// Several `unitMoved` records of one unit in one `apply` (M1 §12.5: an observer gets one record
/// per run of steps it sees; AI playback applies several moves at once) chain into one walk, and
/// the public strategic flag follows the tokens (M1 §16 banners).
@MainActor
@Suite struct MoveChainTests {
    typealias Field = MarksAnimationTests.Field

    static func record(_ event: GameEvent, audience: UInt16 = EventRecord.everyone) -> EventRecord {
        EventRecord(event, audience: audience)
    }

    static func moves(_ visual: UnitVisual) -> [UnitStep] {
        visual.steps.filter { if case .move = $0.kind { true } else { false } }
    }

    static func fades(_ visual: UnitVisual, to value: Float) -> [UnitStep] {
        visual.steps.filter { if case let .fade(to) = $0.kind { to == value } else { false } }
    }

    /// A foreign scout's move seen in two runs (out of our sight between them): it walks the
    /// first run and fades into the fog, then fades in where the second run starts, walks it and
    /// rests on its tile, in sight.
    @Test func runsOfOneMoveChainThroughTheFog() throws {
        let f = try MarksAnimationTests.field()
        var state = f.state
        let map = state.map
        // A second place we see: our scout far east along the row, so the tiles between are
        // out of sight.
        let row = (1...24).compactMap { map.normalize(HexCoord(q: f.c.q + $0, r: f.c.r)) }
        let visible = state.visibleTiles(for: PlayerID(0))
        func seen(_ hex: HexCoord) -> Bool { visible[map.index(of: hex)!] }
        // The first hidden stretch of at least five tiles, and a lookout just past it.
        let gapStart = try #require(row.indices.first { i in i + 8 < row.count && (i..<(i + 5)).allSatisfy { !seen(row[$0]) } })
        let lookout = row[gapStart + 7]
        state.addUnit(.scout, owner: PlayerID(0), at: lookout)
        DebugTools.refreshAllKnowledge(in: &state)
        let now = state.visibleTiles(for: PlayerID(0))
        func sees(_ hex: HexCoord) -> Bool { now[map.index(of: hex)!] }
        // Player 1's scout walks from beside its warrior along the row to the lookout's west.
        let start = row[0]
        let goal = row[gapStart + 6]
        let path = Array(row[1...(gapStart + 6)])
        #expect(sees(start) && sees(goal))
        #expect(path.contains { !sees($0) })
        var moved = state
        let scout = moved.addUnit(.scout, owner: PlayerID(1), at: goal)
        DebugTools.refreshAllKnowledge(in: &moved)
        // Before the move the scout stood at `start` (in sight).
        let before = try SkirmishFixture.edit(moved, [scout: ["position": MarksAnimationTests.position(start)]])
        f.renderer.apply(state: before, events: [])
        #expect(f.renderer.unitVisuals[scout] != nil)

        // The runs the viewer sees, as the engine splits them (Effects.moveRecords).
        let hexes = [start] + path
        var runs: [(first: Int, last: Int)] = []
        var runStart = 0
        for step in 1...path.count {
            let shown = sees(hexes[step - 1]) || sees(hexes[step])
            if shown, runStart == 0 { runStart = step }
            if !shown, runStart != 0 {
                runs.append((runStart, step - 1))
                runStart = 0
            }
        }
        if runStart != 0 { runs.append((runStart, path.count)) }
        #expect(runs.count == 2)
        let records = runs.map { run in
            Self.record(.unitMoved(unit: scout, from: run.first == 1 ? start : path[run.first - 2],
                                   path: Array(path[(run.first - 1)...(run.last - 1)])), audience: 1)
        }
        f.renderer.apply(state: moved, events: records)
        let visual = try #require(f.renderer.unitVisuals[scout])
        // Both runs walk, one after the other: a step per seen hex, a reappearance between.
        let walks = Self.moves(visual)
        let seenSteps = runs.reduce(0) { $0 + $1.last - $1.first + 1 }
        #expect(walks.filter { $0.duration > 0 }.count == seenSteps)
        #expect(walks.filter { $0.duration == 0 }.count == 1)
        #expect(zip(walks, walks.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(Self.fades(visual, to: 0).count == 1 && Self.fades(visual, to: 1).count == 1)
        #expect(!visual.ghost)
        let firstRunEnd = Double(runs[0].last - runs[0].first + 1) * MapRenderer.stepDuration
        // Into the fog at the end of the first run...
        f.renderer.advanceAnimations(by: Float(firstRunEnd) - 0.01)
        f.renderer.advanceAnimations(by: 0.02)
        #expect((f.renderer.unitVisuals[scout]?.opacity ?? 1) < 0.05)
        // ...out of it along the second, and at rest on its tile, in sight.
        f.renderer.advanceAnimations(by: 5)
        let rest = try #require(f.renderer.unitVisuals[scout])
        #expect(!f.renderer.isAnimating && rest.opacity > 0.99 && !rest.ghost)
        let drawn = rest.display(cameraX: Float(f.renderer.layout.center(of: goal).x), layout: f.renderer.layout)
        #expect(simd_distance(drawn, MapRenderer.vec(f.renderer.layout.center(of: goal))) < Float(f.renderer.layout.size))
    }

    /// Two moves of one own unit applied together walk on from one to the next without fading.
    @Test func consecutiveMovesWalkOn() throws {
        let f = try MarksAnimationTests.field()
        let mid = f.w
        let end = try #require(f.map.neighbors(of: mid).first { hex in
            hex != f.a && f.state.units(at: hex).isEmpty && f.state.canEnd(.archer, owner: PlayerID(0), at: hex)
        })
        let next = try SkirmishFixture.edit(f.state, [f.archer: ["position": MarksAnimationTests.position(end), "movesLeft": 0]])
        f.renderer.apply(state: next, events: [
            Self.record(.unitMoved(unit: f.archer, from: f.a, path: [mid])),
            Self.record(.unitMoved(unit: f.archer, from: mid, path: [end])),
        ])
        let visual = try #require(f.renderer.unitVisuals[f.archer])
        let walks = Self.moves(visual)
        #expect(walks.count == 2 && walks[1].start >= walks[0].end - 1e-9)
        #expect(visual.steps.allSatisfy { if case .fade = $0.kind { false } else { true } })
        f.renderer.advanceAnimations(by: Float(MapRenderer.stepDuration) * 1.5)
        let halfway = try #require(f.drawn(f.archer, near: mid))
        #expect(simd_distance(halfway, (f.center(mid) + f.center(end)) / 2) < 3)
        f.renderer.advanceAnimations(by: 2)
        let rest = try #require(f.drawn(f.archer, near: end))
        #expect(simd_distance(rest, f.center(end)) < 1 && f.renderer.unitVisuals[f.archer]?.ghost == false)
    }

    /// With the fog off (diagnostic mode) every record is shown, but a move's per-observer runs
    /// repeat its owner's record: the unit walks its path once.
    @Test func withTheFogOffAMoveWalksOnce() throws {
        let f = try MarksAnimationTests.field()
        f.renderer.fogEnabled = false
        let next = try SkirmishFixture.edit(f.state, [f.enemy: ["position": MarksAnimationTests.position(f.w)]])
        // The enemy warrior walks around our line: the owner's record (player 1) and the part
        // player 0 saw.
        let around = try #require(f.map.neighbors(of: f.c).first { $0 != f.b && f.state.units(at: $0).isEmpty })
        let path = [around, f.w]
        f.renderer.apply(state: next, events: [
            Self.record(.unitMoved(unit: f.enemy, from: f.c, path: path), audience: 1 << 1),
            Self.record(.unitMoved(unit: f.enemy, from: around, path: [f.w]), audience: 1 << 0),
        ])
        let visual = try #require(f.renderer.unitVisuals[f.enemy])
        #expect(Self.moves(visual).count == path.count)
        #expect(Self.fades(visual, to: 0).isEmpty && !visual.ghost)
        f.renderer.skipAnimations()
        #expect(f.renderer.unitVisuals[f.enemy] != nil)
    }

    /// `showsStrategicTokens` switches with the tokens: on from scale 2.1, off below 1.9.
    @Test func strategicFlagFollowsTheTokens() throws {
        let f = try MarksAnimationTests.field()
        let r = f.renderer
        _ = r.renderImage(width: 160, height: 120)
        r.setCameraScale(1)
        _ = r.unitFrame()
        #expect(!r.showsStrategicTokens)
        r.setCameraScale(2.4)
        try #require(r.camera.scale >= 2.1, "the test view cannot zoom out far enough (\(r.camera.scale))")
        _ = r.unitFrame()
        #expect(r.showsStrategicTokens)
        r.setCameraScale(2.0)
        _ = r.unitFrame()
        #expect(r.showsStrategicTokens) // hysteresis
        r.setCameraScale(1.8)
        _ = r.unitFrame()
        #expect(!r.showsStrategicTokens)
    }
}
