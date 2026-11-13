import CoreGraphics
import Foundation
import MetalKit
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// The renderer's M1 interface to the App (docs/M1.md §15): every input, callback and query
/// exists with its labels and types, inputs are kept, and the screen queries agree with the
/// camera.
@MainActor
@Suite struct RendererContractTests {
    /// `onFrame` fires after every frame drawn into a view (and `onFirstFrame` once, at the
    /// tenth), and `presentsWithTransaction` reaches the view (M1 §15: text in step with the map).
    @Test func drawnFramesCallBack() throws {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: 7))
        let state = GameState.newGame(seed: 7, map: generated.map, startPositions: generated.startPositions)
        let renderer = MapRenderer(state: state, viewer: PlayerID(0))
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), device: renderer.device)
        renderer.configure(view)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 640, height: 480)
        var frames = 0, first = 0
        renderer.onFrame = { frames += 1 }
        renderer.onFirstFrame = { first += 1 }
        renderer.presentsWithTransaction = true
        for _ in 0..<12 { renderer.draw(in: view) }
        #expect(frames == 12 && first == 1)
        #expect(view.presentsWithTransaction)
    }

    @Test func rendererContract() throws {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: 7))
        let state = GameState.newGame(seed: 7, map: generated.map, startPositions: generated.startPositions)
        let renderer = MapRenderer(state: state, viewer: PlayerID(0))
        let unit = try #require(state.units(of: PlayerID(0)).first)
        let home = unit.position
        let tiles = state.map.tileCount

        // Inputs, as the App builds them from the viewer's knowledge.
        let city = CityMarker(id: 1, hex: home, owner: PlayerID(0), population: 3, capital: true, walls: true, hp: 1, wallHP: 0.5)
        renderer.setCities([city])
        renderer.setTerritory([UInt8](repeating: 0, count: tiles))
        renderer.setImprovements([UInt8](repeating: 0, count: tiles))
        renderer.setMovementRange(state.map.neighbors(of: home))
        renderer.setAttackTargets([])
        renderer.setSelection(home, kind: .city)
        renderer.setWorkedTiles([home])
        renderer.setTileScores([UInt8](repeating: 0, count: tiles), jobs: [JobMark(hex: home, improvements: [.mine], thisPhase: true)])
        renderer.setReadyUnits([unit.id])
        #expect(renderer.inputs.jobMarks.map(\.hex) == [home] && renderer.inputs.readyUnits == [unit.id])
        let village = try #require(state.map.neighbors(of: home).first)
        renderer.setTribalVillages([TribalVillageMarker(hex: village, seen: true)])
        #expect(renderer.inputs.tribalVillages == [TribalVillageMarker(hex: village, seen: true)])
        renderer.setTileScores([UInt8](repeating: 0, count: tiles))
        renderer.setViewportInsets(MapInsets(top: 0, left: 0, bottom: 120, right: 0))
        #expect(renderer.inputs.cities == [city] && renderer.inputs.selectionKind == .city)
        #expect(renderer.inputs.territory.count == tiles && renderer.inputs.viewportInsets.bottom == 120)
        renderer.setSelection(home)
        #expect(renderer.inputs.selectionKind == .unit)

        // Callbacks and event records.
        renderer.onFrame = {}
        renderer.onEventShown = { (_: EventRecord, _: CGPoint) in }
        renderer.onAnimationsFinished = {}
        renderer.apply(state: state, events: [EventRecord(.turnStarted(turn: 1), audience: EventRecord.everyone)])
        #expect(!renderer.isAnimating)

        // Screen queries follow the camera: the ground under a hex's screen point is that hex.
        _ = try #require(renderer.renderImage(width: 800, height: 600))
        renderer.centerCamera(on: home, animated: false)
        let point = try #require(renderer.screenPoint(of: home))
        let ground = try #require(renderer.camera.groundPoint(atViewPoint: point))
        #expect(state.map.normalize(renderer.layout.hex(at: CGPoint(x: CGFloat(ground.x), y: CGFloat(ground.y)))) == home)
        let raised = try #require(renderer.screenPoint(of: home, lift: 1))
        #expect(raised.y < point.y)
        #expect(renderer.screenPoints(of: [home, home], lift: 0).count == 2)
        #expect(renderer.screenPoint(ofUnit: unit.id) != nil)
        #expect(renderer.screenPoint(ofUnit: UnitID(9999)) == nil)
        #expect(renderer.bannerAnchor(city: city.id) != nil && renderer.bannerAnchor(city: 99) == nil)

        // Picking: the city's hex center shows its unit (drawn over the city, so it wins) or the
        // city itself (`CityArtTests`), never bare ground.
        let hit: MapHit? = renderer.hitTest(atViewPoint: point)
        switch try #require(hit) {
        case let .unit(hex): #expect(hex == home)
        case let .city(id, hex): #expect(id == city.id && hex == home)
        case .ground: Issue.record("the city's centre picked the ground")
        }

        // Heraldry: the emblem at three pixels per point, with paint on it.
        let _: CGColor = Heraldry.color(PlayerID(0))
        let emblem: CGImage? = Heraldry.emblemImage(PlayerID(0), size: 32)
        #expect(emblem?.width == 96 && emblem?.height == 96)
        if let data = emblem?.dataProvider?.data as Data? {
            #expect(stride(from: 3, to: data.count, by: 4).contains { data[$0] > 200 })
        }
    }
}
