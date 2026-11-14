import CoreGraphics
import Foundation
import Testing
import GameCore
import MapGen
import simd
@testable import MapRendering

/// Borders, improvements, overlays, unit markers and event animations (M1 §15).
@MainActor
@Suite struct MarksAnimationTests {
    /// A duel map (seed 7, fog on) with a row of four free land tiles near player 0's start:
    /// `w` empty, then player 0's archer at `a`, its warrior at `b` and player 1's warrior at
    /// `c`; a renderer from player 0's side, drawn once.
    @MainActor
    struct Field {
        var state: GameState
        var renderer: MapRenderer
        var w: HexCoord, a: HexCoord, b: HexCoord, c: HexCoord
        var archer: UnitID, warrior: UnitID, enemy: UnitID
        var map: HexMap { state.map }

        func center(_ hex: HexCoord) -> SIMD2<Float> { MapRenderer.vec(renderer.layout.center(of: hex)) }

        /// Where a unit's picture is drawn now (world, the copy nearest `hex`).
        func drawn(_ id: UnitID, near hex: HexCoord) -> SIMD2<Float>? {
            guard let visual = renderer.unitVisuals[id] else { return nil }
            let p = visual.display(cameraX: center(hex).x, layout: renderer.layout)
            return [Float(renderer.layout.nearestCopy(of: CGFloat(p.x), to: CGFloat(center(hex).x))), p.y]
        }
    }

    static func field() throws -> Field {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: 7))
        var state = GameState.newGame(seed: 7, map: generated.map, startPositions: generated.startPositions)
        let map = state.map
        let start = try #require(state.units(of: PlayerID(0)).first).position
        func free(_ hex: HexCoord) -> Bool {
            state.units(at: hex).isEmpty && state.canEnd(.warrior, owner: PlayerID(0), at: hex)
                && state.canEnd(.warrior, owner: PlayerID(1), at: hex)
        }
        var row: [HexCoord]?
        for hex in map.coords(within: 4, of: start) where row == nil {
            let line = (0..<4).compactMap { k in map.normalize(HexCoord(q: hex.q + k, r: hex.r)) }
            if line.count == 4, line.allSatisfy(free) { row = line }
        }
        let tiles = try #require(row)
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: tiles[1])
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: tiles[2])
        let enemy = state.addUnit(.warrior, owner: PlayerID(1), at: tiles[3])
        DebugTools.refreshAllKnowledge(in: &state)
        let renderer = MapRenderer(state: state, viewer: PlayerID(0))
        renderer.animationTime = 10
        _ = renderer.renderImage(width: 480, height: 360)
        renderer.setCameraScale(0.8)
        renderer.centerCamera(on: tiles[2], animated: false)
        return Field(state: state, renderer: renderer, w: tiles[0], a: tiles[1], b: tiles[2], c: tiles[3],
                     archer: archer, warrior: warrior, enemy: enemy)
    }

    static func position(_ hex: HexCoord) -> [String: Any] { ["q": hex.q, "r": hex.r] }
    static func record(_ event: GameEvent) -> EventRecord { EventRecord(event, audience: EventRecord.everyone) }

    // MARK: Animations

    @Test func ownMoveWalksAndFinishes() throws {
        let f = try Self.field()
        let next = try SkirmishFixture.edit(f.state, [f.archer: ["position": Self.position(f.w), "movesLeft": 0]])
        var finished = 0
        f.renderer.onAnimationsFinished = { finished += 1 }
        f.renderer.apply(state: next, events: [Self.record(.unitMoved(unit: f.archer, from: f.a, path: [f.w]))])
        #expect(f.renderer.isAnimating)
        // It starts where it stood, walks, and rests on its new tile.
        let start = try #require(f.drawn(f.archer, near: f.a))
        #expect(simd_distance(start, f.center(f.a)) < 1)
        f.renderer.advanceAnimations(by: Float(MapRenderer.stepDuration / 2))
        let middle = try #require(f.drawn(f.archer, near: f.a))
        #expect(simd_distance(middle, (f.center(f.a) + f.center(f.w)) / 2) < 2)
        #expect(f.renderer.unitVisuals[f.archer]?.moving == true)
        // Dimmed (no moves left) only once it arrives.
        _ = f.renderer.unitFrame()
        f.renderer.advanceAnimations(by: 1)
        #expect(!f.renderer.isAnimating && finished == 1)
        let end = try #require(f.drawn(f.archer, near: f.w))
        #expect(simd_distance(end, f.center(f.w)) < 1)
        #expect(f.renderer.unitVisuals[f.archer]?.dimmed == true)
        // Nothing more to finish.
        f.renderer.advanceAnimations(by: 1)
        #expect(finished == 1)
    }

    @Test func meleeKillSequence() throws {
        let f = try Self.field()
        // The warrior strikes the enemy dead, takes 12 in return and moves in.
        let next = try SkirmishFixture.edit(f.state, [f.warrior: ["hp": 88, "position": Self.position(f.c), "movesLeft": 0]],
                                            removing: [f.enemy])
        let events: [GameEvent] = [
            .combat(attacker: .unit(f.warrior), defender: .unit(f.enemy), from: f.b, to: f.c, ranged: false, dealt: 100, taken: 12),
            .unitKilled(unit: f.enemy, type: .warrior, owner: PlayerID(1), at: f.c),
            .unitMoved(unit: f.warrior, from: f.b, path: [f.c]),
        ]
        var shown: [GameEvent] = []
        f.renderer.onEventShown = { record, _ in shown.append(record.event) }
        f.renderer.apply(state: next, events: events.map(Self.record))
        // Nothing lands at once: both still show full health, the fallen still stands.
        #expect(shown.isEmpty)
        #expect(f.renderer.unitVisuals[f.enemy]?.hp == 100 && f.renderer.unitVisuals[f.warrior]?.hp == 100)
        #expect(f.renderer.unitVisuals[f.enemy]?.ghost == true)
        _ = f.renderer.renderImage(width: 480, height: 360)
        // The blow lands partway through the lunge: the enemy flashes and its bar empties.
        let impact = MapRenderer.lungeDuration * Double(UnitStep.lungeStrike)
        f.renderer.advanceAnimations(by: Float(impact) + 0.001)
        #expect(shown.count == 1)
        if case .combat = shown.first {} else { Issue.record("the combat was not reported first") }
        #expect(f.renderer.unitVisuals[f.enemy]?.hp == 0)
        #expect((f.renderer.unitVisuals[f.enemy]?.flash ?? 0) > 0.5)
        #expect(f.renderer.animation.effects.contains { $0.kind == .burst })
        // The attacker is out on its lunge, then takes its retaliation.
        let lunge = try #require(f.drawn(f.warrior, near: f.b))
        #expect(simd_distance(lunge, f.center(f.b)) > 3)
        f.renderer.advanceAnimations(by: 0.1)
        #expect(f.renderer.unitVisuals[f.warrior]?.hp == 88)
        // The fallen fade on a ghost (reported as it begins), and the winner waits for it.
        var waited = 0.0
        while shown.count < 2, waited < 2 {
            f.renderer.advanceAnimations(by: 0.02)
            waited += 0.02
        }
        if case .unitKilled = shown.last {} else { Issue.record("the death was not reported") }
        #expect(f.renderer.unitVisuals[f.enemy] != nil)
        f.renderer.advanceAnimations(by: Float(MapRenderer.deathDuration * 0.5))
        let waiting = try #require(f.drawn(f.warrior, near: f.b))
        #expect(simd_distance(waiting, f.center(f.b)) < 1)
        #expect((f.renderer.unitVisuals[f.enemy]?.opacity ?? 0) < 0.8)
        // Then it advances, and the ghost is gone.
        f.renderer.advanceAnimations(by: 2)
        #expect(!f.renderer.isAnimating)
        #expect(f.renderer.unitVisuals[f.enemy] == nil)
        let advanced = try #require(f.drawn(f.warrior, near: f.c))
        #expect(simd_distance(advanced, f.center(f.c)) < 1)
        #expect(f.renderer.unitVisuals[f.warrior]?.hp == 88)
    }

    @Test func rangedAttackFliesAnArrow() throws {
        let f = try Self.field()
        let next = try SkirmishFixture.edit(f.state, [f.enemy: ["hp": 70], f.archer: ["movesLeft": 0]])
        var points: [CGPoint] = []
        f.renderer.onEventShown = { _, point in points.append(point) }
        f.renderer.apply(state: next, events: [Self.record(.combat(attacker: .unit(f.archer), defender: .unit(f.enemy), from: f.a, to: f.c,
                                                                     ranged: true, dealt: 30, taken: 0))])
        _ = f.renderer.renderImage(width: 480, height: 360)
        f.renderer.advanceAnimations(by: 0.15)
        // In flight: an arrow, the defender untouched, the archer standing.
        #expect(f.renderer.animation.effects.contains { $0.kind == .arrow })
        #expect(f.renderer.unitVisuals[f.enemy]?.hp == 100 && points.isEmpty)
        #expect(f.renderer.unitFrame().sprites.contains { $0.flags.y == UnitSpriteKind.arrow.rawValue })
        f.renderer.advanceAnimations(by: 0.3)
        #expect(f.renderer.unitVisuals[f.enemy]?.hp == 70 && points.count == 1)
        // Reported over the defender.
        let defender = try #require(f.renderer.screenPoint(of: f.c))
        #expect(abs(points[0].x - defender.x) < 40)
        #expect(f.renderer.unitFrame().sprites.contains { $0.flags.y == UnitSpriteKind.hpBar.rawValue })
        f.renderer.skipAnimations()
        #expect(!f.renderer.isAnimating && f.renderer.animation.effects.isEmpty)
    }

    @Test func foreignMovesAreTrimmedToWhatTheViewerSees() throws {
        let f = try Self.field()
        let map = f.map
        // Player 1's scout runs a straight line from far out of sight, past our units, and on
        // out of sight again.
        let visible = f.state.visibleTiles(for: PlayerID(0))
        func hidden(_ dq: Int) -> Bool { !visible[map.index(of: map.normalize(HexCoord(q: f.b.q + dq, r: f.b.r + 1))!)!] }
        // From three tiles beyond the first hidden one to the west to three beyond it to the east.
        let west = try #require((4...12).first { d in (0...3).allSatisfy { k in hidden(-d - k) } }) + 3
        let east = try #require((4...12).first { d in (0...3).allSatisfy { k in hidden(d + k) } }) + 3
        let start = map.normalize(HexCoord(q: f.b.q - west, r: f.b.r + 1))!
        let path = (1...(west + east)).map { map.normalize(HexCoord(q: start.q + $0, r: start.r))! }
        let goal = path.last!
        var state = f.state
        let scout = state.addUnit(.scout, owner: PlayerID(1), at: goal)
        DebugTools.refreshAllKnowledge(in: &state)
        let renderer = f.renderer
        renderer.apply(state: state, events: [])
        #expect(renderer.unitVisuals[scout] == nil)
        // The same state, with the event of the walk (the core moved it there).
        renderer.apply(state: state, events: [Self.record(.unitMoved(unit: scout, from: start, path: path))])
        let visual = try #require(renderer.unitVisuals[scout])
        #expect(visual.ghost && visual.opacity == 0)
        let seen = Set((0..<map.tileCount).filter { visible[$0] })
        let hexes = [start] + path
        let shownSteps = (1..<hexes.count).filter { seen.contains(map.index(of: hexes[$0 - 1])!) || seen.contains(map.index(of: hexes[$0])!) }
        let moves = visual.steps.filter { if case .move = $0.kind { true } else { false } }
        #expect(!shownSteps.isEmpty && moves.count == shownSteps.count)
        #expect(moves.count < path.count)
        // It fades in and out, and its picture goes when the walk is over.
        #expect(visual.steps.contains { if case .fade(1) = $0.kind { true } else { false } })
        #expect(visual.steps.contains { if case .fade(0) = $0.kind { true } else { false } })
        renderer.advanceAnimations(by: Float(MapRenderer.stepDuration) * Float(moves.count) / 2)
        #expect((renderer.unitVisuals[scout]?.opacity ?? 0) > 0.9)
        renderer.advanceAnimations(by: 5)
        #expect(renderer.unitVisuals[scout] == nil && !renderer.isAnimating)
    }

    @Test func capturedCivilianChangesColourOnArrival() throws {
        var f = try Self.field()
        // Player 1's settler in place of its warrior: our warrior walks in and takes it, and it
        // becomes our builder (a new id).
        var state = try SkirmishFixture.edit(f.state, [:], removing: [f.enemy])
        let settler = state.addUnit(.settler, owner: PlayerID(1), at: f.c)
        f.state = state
        f.renderer.apply(state: state, events: [])
        #expect(f.renderer.unitVisuals[settler]?.owner == PlayerID(1))
        state = try SkirmishFixture.edit(state, [f.warrior: ["position": Self.position(f.c), "movesLeft": 0]], removing: [settler])
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: f.c)
        f.renderer.apply(state: state, events: [
            Self.record(.unitMoved(unit: f.warrior, from: f.b, path: [f.c])),
            Self.record(.unitCaptured(old: settler, new: builder, type: .builder, from: PlayerID(1), to: PlayerID(0), at: f.c)),
        ])
        // The settler's picture carries on under the new id until the captor arrives.
        #expect(f.renderer.unitVisuals[settler] == nil)
        #expect(f.renderer.unitVisuals[builder]?.owner == PlayerID(1) && f.renderer.unitVisuals[builder]?.type == .settler)
        f.renderer.advanceAnimations(by: Float(MapRenderer.stepDuration) + 0.01)
        #expect(f.renderer.unitVisuals[builder]?.owner == PlayerID(1))
        f.renderer.advanceAnimations(by: Float(MapRenderer.recolorDuration) * 0.6)
        #expect(f.renderer.unitVisuals[builder]?.owner == PlayerID(0) && f.renderer.unitVisuals[builder]?.type == .builder)
        #expect((f.renderer.unitVisuals[builder]?.flash ?? 0) > 0)
        f.renderer.skipAnimations()
        #expect(!f.renderer.isAnimating)
    }

    @Test func withoutAnimationsEverythingLandsAtOnce() throws {
        let f = try Self.field()
        f.renderer.animatesEvents = false
        let next = try SkirmishFixture.edit(f.state, [f.enemy: ["hp": 60]])
        var shown = 0, finished = 0
        f.renderer.onEventShown = { _, _ in shown += 1 }
        f.renderer.onAnimationsFinished = { finished += 1 }
        f.renderer.apply(state: next, events: [Self.record(.combat(attacker: .unit(f.archer), defender: .unit(f.enemy), from: f.a,
                                                                     to: f.c, ranged: true, dealt: 40, taken: 0))])
        #expect(!f.renderer.isAnimating && shown == 1 && finished == 1)
        #expect(f.renderer.unitVisuals[f.enemy]?.hp == 60)
        // Events the viewer may not see are not shown at all.
        f.renderer.animatesEvents = true
        f.renderer.apply(state: next, events: [EventRecord(.combat(attacker: .unit(f.archer), defender: .unit(f.enemy), from: f.a,
                                                                    to: f.c, ranged: true, dealt: 40, taken: 0), audience: 1 << 1)])
        #expect(!f.renderer.isAnimating && shown == 1)
    }

    @Test func dimmingAndMarkersFollowTheUnits() throws {
        let f = try Self.field()
        let r = f.renderer
        func state(_ change: [String: Any]) throws -> GameState { try SkirmishFixture.edit(f.state, [f.warrior: change]) }
        for (change, dimmed) in [([:], false), (["movesLeft": 0], true), (["activity": "sleeping"], true),
                                 (["destination": Self.position(f.w)], true), (["activity": "fortified"], true)] as [([String: Any], Bool)] {
            r.apply(state: try state(change), events: [])
            #expect(r.unitVisuals[f.warrior]?.dimmed == dimmed, "\(change)")
        }
        // The fortified warrior wears the tower marker; a hurt enemy (never dimmed) its HP bar.
        r.apply(state: try SkirmishFixture.edit(f.state, [f.warrior: ["activity": "fortified"], f.enemy: ["hp": 40, "movesLeft": 0]]),
                events: [])
        #expect(r.unitVisuals[f.enemy]?.dimmed == false)
        _ = r.renderImage(width: 480, height: 360)
        let sprites = r.unitFrame().sprites
        #expect(sprites.filter { $0.flags.y == UnitSpriteKind.fortified.rawValue }.count == 1)
        let bars = sprites.filter { $0.flags.y == UnitSpriteKind.hpBar.rawValue }
        #expect(bars.count == 1 && abs(bars[0].flags.z - 0.4) < 1e-4)
    }

    @Test func screenPointOfUnitFollowsTheFigure() throws {
        let f = try Self.field()
        let r = f.renderer
        _ = r.renderImage(width: 480, height: 360)
        let a = try #require(r.screenPoint(of: f.a)), w = try #require(r.screenPoint(of: f.w))
        let resting = try #require(r.screenPoint(ofUnit: f.archer))
        // Figures stand a little south of their hex's centre.
        #expect(abs(resting.x - a.x) < 4 && resting.y > a.y)
        let next = try SkirmishFixture.edit(f.state, [f.archer: ["position": Self.position(f.w)]])
        r.apply(state: next, events: [Self.record(.unitMoved(unit: f.archer, from: f.a, path: [f.w]))])
        r.advanceAnimations(by: Float(MapRenderer.stepDuration / 2))
        _ = r.renderImage(width: 480, height: 360)
        let walking = try #require(r.screenPoint(ofUnit: f.archer))
        #expect(walking.x < max(a.x, w.x) - 4 && walking.x > min(a.x, w.x) + 4)
        // A stacked pair stands apart.
        let pair = f.state.units(of: PlayerID(0)).filter { $0.position == f.state.units(of: PlayerID(0))[0].position }
        if pair.count == 2 {
            let p = try #require(r.screenPoint(ofUnit: pair[0].id)), q = try #require(r.screenPoint(ofUnit: pair[1].id))
            #expect(hypot(p.x - q.x, p.y - q.y) > 3)
        }
    }

    @Test func insetsCenterTheUncoveredView() throws {
        let f = try Self.field()
        let r = f.renderer
        _ = r.renderImage(width: 1200, height: 900)
        let w = CGFloat(r.camera.viewSize.x), h = CGFloat(r.camera.viewSize.y)
        r.setViewportInsets(MapInsets(top: 0, left: 0, bottom: 0.3 * h, right: 0.25 * w))
        r.centerCamera(on: f.b, animated: false)
        let p = try #require(r.screenPoint(of: f.b))
        #expect(abs(p.x - 0.75 * w / 2) < 2 && abs(p.y - 0.7 * h / 2) < 2)
        // Sprites under the panels (past a margin) are not drawn.
        let open = r.uncoveredRect(margin: MapRenderer.insetCullMargin)
        #expect(open.maxX < w && open.maxY < h && open.minX == 0)
        r.setViewportInsets(.zero)
        r.centerCamera(on: f.b, animated: false)
        let q = try #require(r.screenPoint(of: f.b))
        #expect(abs(q.x - w / 2) < 2 && abs(q.y - h / 2) < 2)
    }

    // MARK: Borders, improvements and overlays

    @Test func bordersNeedBothTilesExplored() throws {
        let f = try Self.field()
        let r = f.renderer
        let map = f.map
        // Player 0 owns everything within 6 of its warrior, explored or not; player 1 a tile
        // beside it.
        var owners = [UInt8](repeating: 0, count: map.tileCount)
        for hex in map.coords(within: 6, of: f.b) { owners[map.index(of: hex)!] = 1 }
        owners[map.index(of: f.c)!] = 2
        r.setTerritory(owners)
        let explored = { (i: Int) in r.fogLevel(map.coord(at: i)) < 2 }
        let edges = r.borderEdges()
        #expect(!edges.isEmpty)
        for e in edges {
            let n = try #require(map.normalize(map.coord(at: e.tile).neighbor(HexDirection.allCases[e.direction])))
            #expect(explored(e.tile) && explored(map.index(of: n)!), "a border edge touches an unexplored tile")
            #expect(owners[e.tile] != owners[map.index(of: n)!])
        }
        // Both owners draw their side of the edge between them.
        let between = edges.filter { e in
            map.normalize(map.coord(at: e.tile).neighbor(HexDirection.allCases[e.direction])) == f.c || e.tile == map.index(of: f.c)
        }
        #expect(Set(between.map(\.group)) == [0, 1])
        // The territory runs into unexplored land: with the fog off its whole outline shows.
        let hidden = (0..<map.tileCount).contains { owners[$0] == 1 && !explored($0) }
        #expect(hidden)
        r.fogEnabled = false
        #expect(r.borderEdges().count > edges.count)
        // The tile texture carries the owners.
        #expect(r.tileBytes[map.index(of: f.c)! * 4] & TileBits.ownerMask == 2 << TileBits.ownerShift)
        #expect(!r.territoryGeometry().isEmpty)
    }

    @Test func improvementsAndOverlaysReachTheTileTexture() throws {
        let f = try Self.field()
        let r = f.renderer
        let map = f.map
        let i = map.index(of: f.w)!, j = map.index(of: f.a)!
        var kinds = [UInt8](repeating: 0, count: map.tileCount)
        kinds[i] = Improvement.farm.rawValue
        kinds[j] = Improvement.pasture.rawValue
        r.setImprovements(kinds)
        #expect(r.tileBytes[i * 4 + 1] & TileBits.improvementMask == 1 << TileBits.improvementShift)
        #expect(r.tileBytes[j * 4 + 1] & TileBits.improvementMask == 3 << TileBits.improvementShift)
        // Terrain bits are untouched.
        #expect(r.tileBytes[i * 4 + 1] & 0x1F == map[index: i].elevation.rawValue | map[index: i].feature.rawValue << 2)

        r.setMovementRange([f.w, f.a])
        #expect(r.tileBytes[i * 4 + 3] & TileBits.range != 0 && r.tileBytes[map.index(of: f.c)! * 4 + 3] & TileBits.range == 0)
        r.setSelection(f.b, kind: .unit)
        #expect(!r.territoryGeometry().isEmpty)
        var scores = [UInt8](repeating: 0, count: map.tileCount)
        scores[i] = 255
        scores[j] = 1
        r.setTileScores(scores)
        #expect(r.tileBytes[i * 4 + 3] & TileBits.scoreMask == 7 << TileBits.scoreShift)
        #expect(r.tileBytes[j * 4 + 3] & TileBits.scoreMask == 1 << TileBits.scoreShift)
        // Fog bits survive every input.
        #expect(r.tileBytes[i * 4 + 3] & 3 == r.fogLevel(f.w))

        // Attack targets get threat rings, a selected city a ring sized for its walls, worked
        // tiles gilt rings: all under the figures.
        r.setAttackTargets([f.c])
        r.setWorkedTiles([f.w, f.a])
        _ = r.renderImage(width: 480, height: 360)
        var frame = r.unitFrame()
        let threat = frame.sprites.indices.filter { frame.sprites[$0].flags.y == UnitSpriteKind.threat.rawValue }
        #expect(threat.count == 1 && frame.bands.contains(threat[0]))
        #expect(frame.sprites.filter { $0.flags.y == UnitSpriteKind.worked.rawValue }.count == 2)
        r.setCities([CityMarker(id: 1, hex: f.w, owner: PlayerID(0), population: 4, capital: true, walls: true, hp: 1, wallHP: 1)])
        r.setSelection(f.w, kind: .city)
        frame = r.unitFrame()
        let ring = try #require(frame.sprites.first { $0.flags.y == UnitSpriteKind.selection.rawValue })
        #expect(ring.flags.z > Float(r.layout.size))
        #expect(frame.bands.contains(try #require(frame.sprites.firstIndex { $0.flags.y == UnitSpriteKind.selection.rawValue })))
    }

    /// Resource icons (M2 §3.1) stand on every tile with a resource, placed once, and show only
    /// where the App says the viewer knows it (`setResources`, a bit of the tile texture).
    @Test func resourceIconsShowOnlyWhereKnown() throws {
        let f = try Self.field()
        var map = f.map
        let land = try #require((0..<map.tileCount).first { map[index: $0].isLand && map[index: $0].feature == .none })
        map[index: land].resource = .iron
        let decor = MapRenderer.makeDecorations(map: map, layout: f.renderer.layout, atlas: f.renderer.decorAtlas)
        let icons = decor.filter { UInt32($0.flags.w) & DecorFlags.resource != 0 }
        #expect(Set(icons.map { Int($0.position.w) }) == Set((0..<map.tileCount).filter { map[index: $0].resource != nil }))
        #expect(icons.allSatisfy { (UInt32($0.flags.w) >> 15) & 15 == 0 })
        let r = f.renderer
        #expect(r.tileBytes[land * 4 + 2] & TileBits.resourceKnown == 0)
        var known = [UInt8](repeating: 0, count: map.tileCount)
        known[land] = Resource.iron.rawValue
        r.setResources(known)
        #expect(r.tileBytes[land * 4 + 2] & TileBits.resourceKnown != 0)
        #expect(r.tileBytes[land * 4 + 2] & 0x3F == map[index: land].riverEdges)
        r.setResources([])
        #expect(r.tileBytes[land * 4 + 2] & TileBits.resourceKnown == 0)
        // An M2 improvement's raw value (8 for a Lumber Mill) spans both of its bytes.
        var kinds = [UInt8](repeating: 0, count: map.tileCount)
        kinds[land] = Improvement.lumberMill.rawValue
        r.setImprovements(kinds)
        #expect(r.tileBytes[land * 4 + 1] & TileBits.improvementMask == 0 && r.tileBytes[land * 4] & TileBits.improvementHigh != 0)
    }

    /// Roads (M2 §3.3): a band from each road tile's centre toward every explored road tile
    /// beside it, nothing on unexplored tiles; pillaged marks only from `setPillaged`.
    @Test func roadsAndPillagedMarksFollowTheInputs() throws {
        let f = try Self.field()
        let r = f.renderer
        r.fogEnabled = false
        let a = f.state.map.index(of: f.c)!
        let neighbours = HexDirection.allCases.compactMap { f.state.map.normalize(f.c.neighbor($0)).flatMap(f.state.map.index(of:)) }
        var roads = [Bool](repeating: false, count: f.state.map.tileCount)
        roads[a] = true
        roads[neighbours[0]] = true
        r.setRoads(roads)
        let bands = r.roadGeometry().filter { $0.position.w == OverlayStyle.road.rawValue }
        #expect(bands.count == 12, "two half bands meeting at the shared edge")
        roads[neighbours[0]] = false
        r.setRoads(roads)
        #expect(r.roadGeometry().count == 6, "a lone road: one short band")
        r.setRoads([])
        #expect(r.roadGeometry().isEmpty)
        r.setPillaged([f.c, f.c])
        #expect(r.inputs.pillaged == [f.c])
        #expect(r.unitAtlas.uv(.pillaged) != .zero)
    }

    /// Mine entrances (with their spoil) stand on every bare hill that could take a mine and
    /// herds on every open pasture site, placed once; each shows only while its tile has that
    /// improvement, and open-land scatter clears from farms. The decor atlas keeps its size.
    @Test func improvementDecorationsShowOnlyWhereBuilt() throws {
        #expect(SpriteSheet<DecorSprite>.width == 2048 && SpriteSheet<DecorSprite>.height == 1536)
        let f = try Self.field()
        let map = f.map
        let decor = MapRenderer.makeDecorations(map: map, layout: f.renderer.layout, atlas: f.renderer.decorAtlas)
        var mines: [Int: Int] = [:], herds: [Int: Int] = [:], props: [Int: Int] = [:], cluttered: [Int: Int] = [:]
        for d in decor {
            let bits = UInt32(d.flags.w), tile = Int(d.position.w)
            if bits & DecorFlags.clears != 0 { cluttered[tile, default: 0] += 1 }
            let needs = (bits >> 15) & 15
            guard needs != 0 else { continue }
            #expect(bits & (DecorFlags.relief | DecorFlags.clears | DecorFlags.shadow | DecorFlags.resource) == 0)
            #expect(needs != UInt32(Improvement.farm.rawValue))
            if needs > UInt32(Improvement.pasture.rawValue) {
                // M2 improvements' props: one, where its improvement could stand.
                props[tile, default: 0] += 1
                #expect(DecorPlacer.propImprovement(on: map[index: tile])?.rawValue == UInt8(needs))
                continue
            }
            if needs == UInt32(Improvement.mine.rawValue) { mines[tile, default: 0] += 1 } else { herds[tile, default: 0] += 1 }
        }
        for i in 0..<map.tileCount {
            let t = map[index: i]
            let bare = t.isLand && t.feature != .forest && t.feature != .jungle
            let mineable = bare && t.elevation == .hills && t.terrain != .snow
            let grazing = bare && t.elevation == .flat && t.feature != .marsh && t.feature != .oasis
                && [.grassland, .plains, .tundra].contains(t.terrain)
            #expect(mines[i].map { (2...3).contains($0) } ?? !mineable, "tile \(i): \(mines[i] ?? 0) mine sprites")
            #expect(herds[i].map { (3...4).contains($0) } ?? !grazing, "tile \(i): \(herds[i] ?? 0) animals")
            #expect(mines[i] == nil || mineable)
            #expect(herds[i] == nil || grazing)
            #expect(props[i] == (DecorPlacer.propImprovement(on: t) == nil ? nil : 1), "tile \(i): \(props[i] ?? 0) props")
        }

        // The decorations alone, fog off: each shows on its own improvement only.
        let r = MapRenderer(state: f.state, viewer: PlayerID(0))
        r.fogEnabled = false
        r.animationTime = 10
        r.passes = .decor
        _ = r.renderImage(width: 320, height: 240)
        r.setCameraScale(0.6)
        func image(_ kinds: [UInt8], at i: Int) throws -> [UInt8] {
            r.setImprovements(kinds)
            r.centerCamera(on: map.coord(at: i), animated: false)
            return UnitTapTests.bytes(try #require(r.renderImage(width: 320, height: 240)))
        }
        func worst(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 }
        let none = [UInt8](repeating: 0, count: map.tileCount)
        func with(_ kind: Improvement, at i: Int) -> [UInt8] {
            var kinds = none
            kinds[i] = kind.rawValue
            return kinds
        }
        let hill = try #require(mines.keys.min())
        let bareHill = try image(none, at: hill)
        #expect(worst(bareHill, try image(with(.mine, at: hill), at: hill)) > 60, "a built mine shows")
        #expect(worst(bareHill, try image(with(.pasture, at: hill), at: hill)) <= 2, "nothing but a mine shows a mine")
        let pasture = try #require(herds.keys.min())
        #expect(worst(try image(none, at: pasture), try image(with(.pasture, at: pasture), at: pasture)) > 60, "a pasture shows its herd")
        let open = try #require(cluttered.keys.filter { herds[$0] != nil }.min())
        #expect(worst(try image(none, at: open), try image(with(.farm, at: open), at: open)) > 30, "a farm clears the scatter")
        #expect(worst(try image(none, at: open), try image(none, at: open)) == 0)
    }

    /// The ground draws farm fields with its costly variant only around known farms (a stencil
    /// mask): the same picture as the fields variant everywhere, and the stencil is restored
    /// for the unit pass (figures still cover the decorations behind them).
    @Test func farmFieldsOnlyWhereFarmsAre() throws {
        let scene = try SkirmishFixture.scene()
        let r = SkirmishFixture.view(scene, center: scene.capital.hex, scale: 0.6, width: 480, height: 360)
        r.animationTime = 10
        #expect(r.knownFarmCenters().count > 0)
        let split = UnitTapTests.bytes(try #require(r.renderImage(width: 480, height: 360)))
        r.groundFieldsEverywhere = true
        let whole = UnitTapTests.bytes(try #require(r.renderImage(width: 480, height: 360)))
        #expect(split.count == whole.count)
        let worst = zip(split, whole).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 2, "worst channel difference \(worst)")
        // The view does show fields: without its farms it changes.
        r.groundFieldsEverywhere = false
        r.setImprovements(scene.improvements.map { $0 == Improvement.farm.rawValue ? 0 : $0 })
        #expect(r.knownFarmCenters().buffer == nil)
        let bare = UnitTapTests.bytes(try #require(r.renderImage(width: 480, height: 360)))
        #expect((zip(split, bare).map { abs(Int($0) - Int($1)) }.max() ?? 0) > 30)
    }

    /// Two states that differ only in what the viewer cannot see (a unit in the fog, a hidden
    /// unit's health) render the same, within 6/255 (M1 §15).
    @Test func hiddenDataDoesNotShow() throws {
        let f = try Self.field()
        let map = f.map
        let visible = f.state.visibleTiles(for: PlayerID(0))
        let hidden = try #require(map.coords(within: 9, of: f.b).first { hex in
            !visible[map.index(of: hex)!] && f.state.units(at: hex).isEmpty && f.state.canEnd(.archer, owner: PlayerID(1), at: hex)
        })
        var other = f.state
        let spy = other.addUnit(.archer, owner: PlayerID(1), at: hidden)
        other = try SkirmishFixture.edit(other, [spy: ["hp": 30]])
        let enemyElsewhere = f.state.units(of: PlayerID(1)).first { !visible[map.index(of: $0.position)!] }
        if let unit = enemyElsewhere { other = try SkirmishFixture.edit(other, [unit.id: ["hp": 55, "movesLeft": 0]]) }
        func render(_ state: GameState) throws -> [UInt8] {
            let r = MapRenderer(state: state, viewer: PlayerID(0))
            r.animationTime = 10
            _ = r.renderImage(width: 320, height: 240)
            r.setCameraScale(1.2)
            r.centerCamera(on: f.b, animated: false)
            return UnitTapTests.bytes(try #require(r.renderImage(width: 320, height: 240)))
        }
        let a = try render(f.state), b = try render(other)
        #expect(a.count == b.count)
        let worst = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 6, "worst channel difference \(worst)")
    }

    /// Renderer inputs on tiles the viewer has not explored never show (M1 §11, §15): a walled,
    /// burning capital, another owner's territory, improvements and settler scores placed there
    /// render the same as none, within 6/255, up close and at strategic zoom. The viewer's own
    /// territory runs up to the fog, and no border outlines the fog's edge.
    @Test func inputsOnUnexploredTilesDoNotShow() throws {
        let f = try Self.field()
        let map = f.map
        let unexplored = (0..<map.tileCount).filter { f.renderer.fogLevel(map.coord(at: $0)) == 2 }
        let near = unexplored.filter { map.distance(map.coord(at: $0), f.b) <= 9 }
        let explored = (0..<map.tileCount).filter { f.renderer.fogLevel(map.coord(at: $0)) < 2 }
        let site = try #require(near.filter { map[index: $0].isLand }.min {
            map.distance(map.coord(at: $0), f.b) < map.distance(map.coord(at: $1), f.b)
        })
        try #require(near.count > 12)
        func render(hidden: Bool, scale: CGFloat) throws -> [UInt8] {
            let r = MapRenderer(state: f.state, viewer: PlayerID(0))
            r.animationTime = 10
            var owners = [UInt8](repeating: 0, count: map.tileCount)
            var kinds = [UInt8](repeating: 0, count: map.tileCount)
            var scores = [UInt8](repeating: 0, count: map.tileCount)
            for i in explored where map.distance(map.coord(at: i), f.b) <= 9 { owners[i] = 1 }
            var cities: [CityMarker] = []
            if hidden {
                for (k, i) in near.enumerated() {
                    owners[i] = 2
                    kinds[i] = UInt8(1 + k % 3)
                    scores[i] = UInt8(40 + (k * 37) % 216)
                }
                cities = [CityMarker(id: 77, hex: map.coord(at: site), owner: PlayerID(1), population: 9, capital: true,
                                     walls: true, hp: 0.3, wallHP: 0)]
            }
            r.setTerritory(owners)
            r.setImprovements(kinds)
            r.setTileScores(scores)
            r.setCities(cities)
            if hidden {
                #expect(r.borderEdges().allSatisfy { e in
                    let n = map.normalize(map.coord(at: e.tile).neighbor(HexDirection.allCases[e.direction]))
                    return n.map { r.fogLevel($0) < 2 } ?? false
                }, "a border runs along the fog's edge")
            }
            _ = r.renderImage(width: 480, height: 360)
            r.setCameraScale(scale)
            r.centerCamera(on: map.coord(at: site), animated: false)
            return UnitTapTests.bytes(try #require(r.renderImage(width: 480, height: 360)))
        }
        for scale in [0.8, 2.6] as [CGFloat] {
            let a = try render(hidden: false, scale: scale), b = try render(hidden: true, scale: scale)
            #expect(a.count == b.count)
            let worst = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst <= 6, "worst channel difference \(worst) at scale \(scale)")
        }
    }
}
