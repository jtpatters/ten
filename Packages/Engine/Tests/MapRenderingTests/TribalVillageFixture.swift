import CoreGraphics
import Foundation
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// The tribal villages' gallery scene (`g20…`, phase 3g; M1 §7.7), built through GameCore's
/// public API only: Duel seed 11 on turn 1, player 0's capital founded where its Settler stood,
/// and three tribal villages placed with `DebugTools.placeTribalVillage`:
/// - `hills`: on hills 3–5 tiles out, in sight of a Scout of player 0 next to it (seen);
/// - `byCity`: 2 tiles from the capital, in its sight (seen);
/// - `remembered`: 6 tiles out, seen by a second Scout that was then disbanded, so it is
///   remembered in the fog.
///
/// Player 0 has also explored 7 tiles round its capital, so the strategic view shows land. The
/// renderer gets what the App passes (`MapAdapter.syncWorld`): the known cities, territory and
/// improvements, and markers from `PlayerView.knownTribalVillages`, seen where visible. The art
/// (phase 3g, H3) is tested on it in `TribalVillageStubTests.swift` (`TribalVillageArtTests`).
/// `build/m1/art-ab-3g` times these views against this baseline, so keep the enum as it is: the
/// A/B's setup refuses two sides whose `enum TribalVillageFixture` differ.
@MainActor
enum TribalVillageFixture {
    struct Scene {
        var state: GameState
        var capital: HexCoord
        var hills: HexCoord
        var byCity: HexCoord
        var remembered: HexCoord
        /// The Scout standing next to `hills`.
        var scout: UnitID
        var cities: [CityMarker]
        var territory: [UInt8]
        var improvements: [UInt8]
        var markers: [TribalVillageMarker]
    }

    static let me = PlayerID(0)

    static func scene() throws -> Scene {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: 11))
        var state = GameState.newGame(seed: 11, map: generated.map, startPositions: generated.startPositions, mapSizeName: "duel")
        let map = state.map
        let settler = try #require(state.units(of: me).first { $0.type == .settler })
        _ = try GameEngine.apply(.foundCity(unit: settler.id), by: me, to: &state)
        let capital = settler.position

        /// Unowned passable land with no unit on it, nearest the capital first (ties: tile order).
        func candidates(_ distances: ClosedRange<Int>, _ accept: (HexCoord, Tile) -> Bool = { _, _ in true }) -> [HexCoord] {
            map.coords(within: distances.upperBound, of: capital).compactMap { hex -> (Int, Int, HexCoord)? in
                guard let t = map.index(of: hex), let tile = map.tile(at: hex), distances.contains(map.distance(hex, capital)),
                      state.tileCity[t] == 0, state.rules.isPassable(tile), state.units(at: hex).isEmpty, accept(hex, tile) else { return nil }
                return (map.distance(hex, capital), t, hex)
            }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        }
        /// Whether a Scout of player 0 may stand on `hex`: free, and no tribal village there.
        func open(_ hex: HexCoord) -> Bool {
            state.canEnd(.scout, owner: me, at: hex) && state.units(at: hex).isEmpty && !DebugTools.tribalVillages(in: state).contains(hex)
        }
        /// A tile next to `hex` where a Scout of player 0 may stand.
        func post(by hex: HexCoord) throws -> HexCoord {
            try #require(map.neighbors(of: hex).first(where: open))
        }

        let byCity = try #require(candidates(2...2) { _, tile in tile.elevation == .flat }.first)
        #expect(DebugTools.placeTribalVillage(at: byCity, in: &state))

        let hills = try #require(candidates(3...5) { _, tile in tile.elevation == .hills }.first)
        let scout = state.addUnit(.scout, owner: me, at: try post(by: hills))
        #expect(DebugTools.placeTribalVillage(at: hills, in: &state))

        // Out of everything's sight but the lookout's, so it is remembered once the lookout goes.
        let remembered = try #require(candidates(6...6) { hex, tile in
            tile.elevation == .flat && !state.players[me.rawValue].visible[map.index(of: hex)!] && map.neighbors(of: hex).contains(where: open)
        }.first)
        let lookout = state.addUnit(.scout, owner: me, at: try post(by: remembered))
        #expect(DebugTools.placeTribalVillage(at: remembered, in: &state))
        _ = try GameEngine.apply(.disband(unit: lookout), by: me, to: &state)

        for hex in map.coords(within: 7, of: capital) { state.players[me.rawValue].explored[map.index(of: hex)!] = true }

        let view = state.view(for: me)
        let rules = state.rules
        let maxWall = max(rules.buildings.map(\.wallHP).max() ?? 100, 1), maxHP = max(rules.constants.city.maxHP, 1)
        let cities = view.knownCities.map { c in
            CityMarker(id: c.id.rawValue, hex: c.position, owner: c.owner, population: c.population, capital: c.capital, walls: c.walls,
                       hp: Float(c.hp) / Float(maxHP), wallHP: Float(c.wallHP) / Float(maxWall))
        }
        return Scene(state: state, capital: capital, hills: hills, byCity: byCity, remembered: remembered, scout: scout, cities: cities,
                     territory: view.knownTerritory, improvements: view.knownImprovements, markers: markers(view))
    }

    /// The markers the App passes: the tribal villages the viewer knows, seen where visible.
    static func markers(_ view: PlayerView) -> [TribalVillageMarker] {
        view.knownTribalVillages.map { t in
            let hex = view.coord(at: Int(t))
            return TribalVillageMarker(hex: hex, seen: view.isVisible(hex))
        }
    }

    /// A renderer showing the scene from player 0's side on `device`, the fog on, with the App's
    /// inputs and the camera on `center` at `scale`.
    static func view(_ scene: Scene, center: HexCoord, scale: CGFloat, device: PortraitGallery.Device = PortraitGallery.iPad) -> MapRenderer {
        let r = MapRenderer(state: scene.state, viewer: me)
        r.animationTime = 100
        r.fogEnabled = true
        r.setViewportInsets(device.insets)
        r.setCities(scene.cities)
        r.setTerritory(scene.territory)
        r.setImprovements(scene.improvements)
        r.setTribalVillages(scene.markers)
        _ = PortraitGallery.render(r, on: device)
        r.setCameraScale(scale)
        r.centerCamera(on: center, animated: false)
        return r
    }

    /// The gallery's views: the one on hills close up, the remembered one in the fog, the one by
    /// the capital, and all of them at the widest zoom.
    static func views(_ scene: Scene) -> [(name: String, center: HexCoord, scale: CGFloat)] {
        [("g20-tribal-village-hills", scene.hills, 0.45), ("g20b-tribal-village-remembered", scene.remembered, 0.6),
         ("g20c-tribal-village-by-city", scene.byCity, 0.6), ("g20d-tribal-villages-strategic", scene.capital, 1000)]
    }
}

/// The tribal villages' gallery views (`g20…`) on an upright iPad (834×1210 points at 2x).
/// Runs only with RENDER_OUT (the ArtGallery run renders them too):
///
///     RENDER_OUT=/some/dir swift test --filter TribalVillageGallery
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_OUT"] != nil))
struct TribalVillageGallery {
    static func render(timing: inout [String]) throws {
        let pad = PortraitGallery.iPad
        let scene = try TribalVillageFixture.scene()
        for (name, center, scale) in TribalVillageFixture.views(scene) {
            let renderer = TribalVillageFixture.view(scene, center: center, scale: scale, device: pad)
            let image = try #require(PortraitGallery.render(renderer, on: pad))
            MapRendererTests.save(image, name + ".png")
            var samples: [Double] = []
            for _ in 0..<7 {
                _ = PortraitGallery.render(renderer, on: pad)
                samples.append(renderer.lastOffscreenGPUMilliseconds)
            }
            timing.append(String(format: "%@ scale %.2f gpu %.2f ms", name, renderer.camera.scale, samples.sorted()[3]))
        }
    }

    @Test func tribalVillageGallery() throws {
        var lines: [String] = []
        try Self.render(timing: &lines)
        print(lines.joined(separator: "\n"))
    }
}
