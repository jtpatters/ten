import CoreGraphics
import Foundation
import Testing
import GameCore
import simd
@testable import MapRendering

/// Pictures of units the viewer no longer sees never resolve to hidden tiles (the fog review's
/// fog-1 and fog-5): a foreign unit walking out of sight is drawn as a ghost on the tiles the
/// viewer saw it cross, and a tap on that ghost must not select the hidden tile it is bound
/// for; switching the fog back on drops the pictures of units it hides at once.
@MainActor
@Suite struct GhostPickLeakTests {
    /// The field's row east of player 1's warrior (at `c`), normalized.
    static func row(_ f: MarksAnimationTests.Field, from k: Int) -> [HexCoord] {
        (k...24).compactMap { f.map.normalize(HexCoord(q: f.c.q + $0, r: f.c.r)) }
    }

    /// Player 0's run of a move along `path` from `start`: the steps with a seen end, as
    /// `Effects.moveRecords` gives it.
    static func run(_ f: MarksAnimationTests.Field, from start: HexCoord, path: [HexCoord], sees: (HexCoord) -> Bool) throws -> EventRecord {
        let hexes = [start] + path
        let lastSeen = try #require((1...path.count).last { sees(hexes[$0 - 1]) || sees(hexes[$0]) })
        return EventRecord(.unitMoved(unit: f.enemy, from: start, path: Array(path[0..<lastSeen])), audience: 1)
    }

    /// The warrior walks east from `c` across seen tiles into the fog, ending two hidden tiles
    /// in. Partway through its walk, a tap on its ghost (still on seen tiles, opaque enough to
    /// be drawn) once resolved to the warrior's live, hidden tile; any other result is fine.
    @Test func ghostWalkingIntoFogDoesNotPickItsHiddenDestination() throws {
        let f = try MarksAnimationTests.field()
        let map = f.state.map
        let visible = f.state.visibleTiles(for: PlayerID(0))
        func sees(_ hex: HexCoord) -> Bool { visible[map.index(of: hex)!] }
        #expect(sees(f.c))
        let row = Self.row(f, from: 1)
        let h = try #require(row.indices.first { i in i + 1 < row.count && !sees(row[i]) && !sees(row[i + 1]) })
        let path = Array(row[0...(h + 1)])
        let goal = path[path.count - 1]
        #expect(!sees(goal))
        let moved = try SkirmishFixture.edit(f.state, [f.enemy: ["position": MarksAnimationTests.position(goal)]])
        f.renderer.apply(state: moved, events: [try Self.run(f, from: f.c, path: path, sees: sees)])
        #expect(try #require(f.renderer.unitVisuals[f.enemy]).ghost)
        f.renderer.advanceAnimations(by: Float(MapRenderer.stepDuration) * 0.6)
        let now = try #require(f.renderer.unitVisuals[f.enemy])
        #expect(now.opacity > 0.5 && !now.steps.isEmpty, "still walking, drawn: opacity \(now.opacity)")
        _ = f.renderer.renderImage(width: 480, height: 360)
        let point = try #require(f.renderer.screenPoint(ofUnit: f.enemy, lift: 0.25))
        let hit = f.renderer.hitTest(atViewPoint: point)
        #expect(hit != .unit(goal), "a tap on the ghost resolves to its hidden destination")
        #expect(f.renderer.hex(atViewPoint: point) != goal)
    }

    /// A warrior on the last seen tile (or one further back) walks one tile into the fog and
    /// one more. While its ghost is drawn, no tap anywhere on it, from its feet to a tile size
    /// above them, resolves to the hidden tile it ends on.
    @Test(arguments: [0, 1]) func edgeWarriorStepsIntoFog(extra: Int) throws {
        let f = try MarksAnimationTests.field()
        let map = f.state.map
        let visible = f.state.visibleTiles(for: PlayerID(0))
        func sees(_ hex: HexCoord) -> Bool { visible[map.index(of: hex)!] }
        let row = Self.row(f, from: 0)
        let h = try #require(row.indices.first { i in i >= 1 && i + 2 < row.count && !sees(row[i]) && !sees(row[i + 1]) })
        // extra 0: the walk starts on the last seen tile; 1: one tile further back (two seen steps).
        let edge = row[h - 1 - extra], goal = row[h + 1]
        let path = Array(row[(h - extra)...(h + 1)])
        #expect(sees(edge) && !sees(goal))
        // A fresh renderer with the warrior standing on its start tile.
        let atEdge = try SkirmishFixture.edit(f.state, [f.enemy: ["position": MarksAnimationTests.position(edge)]])
        let renderer = MapRenderer(state: atEdge, viewer: PlayerID(0))
        renderer.animationTime = 10
        _ = renderer.renderImage(width: 480, height: 360)
        renderer.setCameraScale(0.8)
        renderer.centerCamera(on: edge, animated: false)
        _ = renderer.renderImage(width: 480, height: 360)
        #expect(renderer.unitVisuals[f.enemy] != nil)
        let moved = try SkirmishFixture.edit(atEdge, [f.enemy: ["position": MarksAnimationTests.position(goal)]])
        renderer.apply(state: moved, events: [try Self.run(f, from: edge, path: path, sees: sees)])
        var drawn = 0, probes = 0
        var leaks: [String] = []
        var t: Float = 0
        while t < 0.5 {
            _ = renderer.renderImage(width: 480, height: 360)
            if let v = renderer.unitVisuals[f.enemy], v.opacity > 0.003 {
                drawn += 1
                for k in 0...10 {
                    let lift = Float(k) * 0.1
                    guard let point = renderer.screenPoint(ofUnit: f.enemy, lift: lift) else { continue }
                    for dx: CGFloat in [-6, 0, 6] {
                        let probe = CGPoint(x: point.x + dx, y: point.y)
                        probes += 1
                        if renderer.hitTest(atViewPoint: probe) == .unit(goal) || renderer.hex(atViewPoint: probe) == goal {
                            leaks.append(String(format: "t %.2f lift %.1f dx %.0f", t, lift, dx))
                        }
                    }
                }
            }
            renderer.advanceAnimations(by: 0.02)
            t += 0.02
        }
        #expect(drawn > 2 && probes > 0, "the ghost was drawn for \(drawn) samples")
        #expect(leaks.isEmpty, "\(leaks.count) of \(probes) probes picked the hidden goal: \(leaks.prefix(4))")
    }

    /// Switching the fog back on (Diagnostic Mode off) without an `apply` drops the pictures of
    /// foreign units on tiles the viewer does not see; they used to stay drawn and pickable at
    /// full opacity until the next command.
    @Test func fogBackOnDropsHiddenForeignUnits() throws {
        let f = try MarksAnimationTests.field()
        let map = f.state.map
        let visible = f.state.visibleTiles(for: PlayerID(0))
        let hidden = f.state.units.filter { $0.owner != PlayerID(0) && !visible[map.index(of: $0.position)!] }
        let seen = f.state.units.filter { $0.owner == PlayerID(0) || visible[map.index(of: $0.position)!] }
        #expect(!hidden.isEmpty)
        #expect(hidden.allSatisfy { f.renderer.unitVisuals[$0.id] == nil })
        f.renderer.fogEnabled = false
        #expect(hidden.allSatisfy { f.renderer.unitVisuals[$0.id] != nil })
        f.renderer.fogEnabled = true
        let stale = hidden.filter { f.renderer.unitVisuals[$0.id] != nil }
        #expect(stale.isEmpty, "\(stale.count) of \(hidden.count) hidden units keep their pictures")
        #expect(seen.allSatisfy { f.renderer.unitVisuals[$0.id] != nil }, "units the viewer sees keep theirs")
        // Nothing claims a hidden unit's tile, even with the camera on it.
        let u = hidden[0]
        f.renderer.centerCamera(on: u.position, animated: false)
        _ = f.renderer.renderImage(width: 480, height: 360)
        #expect(f.renderer.fogLevel(u.position) != 0)
        #expect(!f.renderer.unitFrame().owners.contains { $0?.hex == u.position })
        #expect(f.renderer.screenPoint(ofUnit: u.id) == nil)
        // The next apply keeps them gone.
        f.renderer.apply(state: f.state, events: [])
        #expect(hidden.allSatisfy { f.renderer.unitVisuals[$0.id] == nil })
    }
}
