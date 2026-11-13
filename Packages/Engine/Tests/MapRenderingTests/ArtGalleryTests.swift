import CoreGraphics
import Foundation
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// The standard views used to judge the map art, plus atlas dumps and GPU timings.
/// Runs only when RENDER_OUT is set:
///
///     RENDER_OUT=/some/dir swift test --filter ArtGallery
///
/// Writes g01…g13 PNGs, the city views g14… (`CityGallery`), the skirmish, overlay, combat
/// and border views g15… and g16… (`SkirmishGallery`), the portrait views at the widest zoom
/// g17… (`PortraitGallery`, with portrait.txt), the routes into the fog g18… (`RouteGallery`),
/// the play-test's guidance views g19… (`GuidanceGallery`, with guidance.txt), the tribal
/// villages g20… (`TribalVillageGallery`), atlas-decor.png, atlas-units.png,
/// atlas-settlements.png and timing.txt to that directory.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_OUT"] != nil))
struct ArtGallery {
    static let width = 1600, height = 1100

    static func world(_ size: MapSize, seed: UInt64) -> GameState {
        let generated = MapGenerator.generate(MapGenSettings(size: size, seed: seed))
        return GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions)
    }

    /// The tile whose radius-2 neighborhood scores highest (ties: lowest index).
    static func bestCenter(_ map: HexMap, score: (Tile) -> Int) -> HexCoord {
        var best = (score: Int.min, hex: map.coord(at: 0))
        for i in 0..<map.tileCount {
            let hex = map.coord(at: i)
            let total = map.coords(within: 2, of: hex).reduce(0) { $0 + score(map[$1]) }
            if total > best.score { best = (total, hex) }
        }
        return best.hex
    }

    static func render(_ renderer: MapRenderer, _ name: String) throws -> CGImage {
        let image = try #require(renderer.renderImage(width: width, height: height))
        MapRendererTests.save(image, name)
        return image
    }

    static func view(_ state: GameState, center: HexCoord, scale: CGFloat, fog: Bool = false, tilted: Bool = true) -> MapRenderer {
        let renderer = MapRenderer(state: state, viewer: PlayerID(0))
        renderer.fogEnabled = fog
        renderer.tilted = tilted
        renderer.setCameraScale(scale)
        renderer.centerCamera(on: center, animated: false)
        return renderer
    }

    static func medianGPU(_ renderer: MapRenderer) -> Double {
        _ = renderer.renderImage(width: width, height: height) // warm-up
        var samples: [Double] = []
        for _ in 0..<7 {
            _ = renderer.renderImage(width: width, height: height)
            samples.append(renderer.lastOffscreenGPUMilliseconds)
        }
        return samples.sorted()[samples.count / 2]
    }

    @Test func gallery() throws {
        var timing: [String] = []
        func time(_ name: String, _ renderer: MapRenderer) {
            let ms = Self.medianGPU(renderer)
            timing.append(String(format: "%@ gpu %.2f ms", name, ms))
        }

        // World views (Standard map, everything revealed).
        let standard = Self.world(.standard, seed: 7)
        let start = try #require(standard.units(of: PlayerID(0)).first).position
        let world = Self.view(standard, center: start, scale: 1.6)
        #expect(MapRendererTests.distinctColors(try Self.render(world, "g01-world-tilted.png")) > 200)
        time("g01-world-tilted", world)
        timing.append(String(format: "renderer setup %.0f ms, textures %.1f MB", world.setupMilliseconds,
                             Double(world.textureMemoryBytes) / 1_048_576))
        world.tilted = false
        _ = try Self.render(world, "g02-world-topdown.png")
        world.tilted = true
        world.setCameraScale(1000) // clamps to the widest zoom
        _ = try Self.render(world, "g03-strategic.png")
        time("g03-strategic", world)

        // Start of a game with fog: a revealed ring around the start that is explored but not in sight.
        var fogged = Self.world(.small, seed: 42)
        let home = try #require(fogged.units(of: PlayerID(0)).first).position
        for hex in fogged.map.coords(within: 6, of: home) { fogged.players[0].explored[fogged.map.index(of: hex)!] = true }
        let second = Self.view(fogged, center: home, scale: 1, fog: true)
        timing.append(String(format: "second renderer setup %.0f ms (Small map, atlases cached)", second.setupMilliseconds))
        _ = try Self.render(second, "g04-start-fog.png")

        // Units of four players around the start, a selected warrior with a path preview.
        var crowd = Self.world(.small, seed: 42)
        let ring = crowd.map.coords(within: 3, of: home).filter { crowd.map.distance($0, home) >= 2 }
        var spots = ring.makeIterator()
        for (player, type) in [(1, UnitType.warrior), (1, .scout), (2, .settler), (2, .warrior), (3, .scout), (3, .warrior), (0, .scout)] {
            while let hex = spots.next() {
                guard crowd.canEnd(type, owner: PlayerID(player), at: hex), crowd.units(at: hex).isEmpty else { continue }
                crowd.addUnit(type, owner: PlayerID(player), at: hex)
                break
            }
        }
        let units = Self.view(crowd, center: home, scale: 0.4)
        let warrior = try #require(crowd.units(of: PlayerID(0)).first { $0.type == .warrior })
        if let target = crowd.map.coords(within: 4, of: warrior.position).first(where: { hex in
            crowd.map.tile(at: hex)?.landMovementCost != nil && crowd.map.distance(hex, warrior.position) == 4 && crowd.units(at: hex).isEmpty
        }), let path = Pathfinder.findPath(for: warrior, to: target, in: crowd) {
            units.setSelection(warrior.position)
            units.showPath(path, from: warrior.position)
        }
        _ = try Self.render(units, "g05-units.png")
        time("g05-units", units)

        _ = try Self.render(Self.view(crowd, center: home, scale: 0.65), "g06-closeup.png")

        // Biome close-ups on the Standard map.
        let map = standard.map
        let coast = Self.bestCenter(map) { t in
            (t.terrain == .coast ? 2 : 0) + (t.isLand && t.elevation == .flat ? 2 : 0) + (t.feature == .reef ? 3 : 0)
        }
        _ = try Self.render(Self.view(standard, center: coast, scale: 0.55), "g07-coast.png")
        let mountains = Self.bestCenter(map) { t in t.elevation == .mountains ? 3 : (t.elevation == .hills ? 1 : 0) }
        _ = try Self.render(Self.view(standard, center: mountains, scale: 0.6), "g08-mountains.png")
        let desert = Self.bestCenter(map) { t in
            (t.terrain == .desert ? 2 : 0) + (t.feature == .oasis || t.feature == .floodplain ? 3 : 0)
        }
        _ = try Self.render(Self.view(standard, center: desert, scale: 0.6), "g09-desert.png")
        let cold = Self.bestCenter(map) { t in (t.terrain == .snow ? 2 : 0) + (t.terrain == .tundra ? 2 : 0) + (t.isLand ? 1 : 0) }
        _ = try Self.render(Self.view(standard, center: cold, scale: 0.6), "g09b-snow-tundra.png")
        let river = Self.bestCenter(map) { t in t.riverEdges.nonzeroBitCount }
        _ = try Self.render(Self.view(standard, center: river, scale: 0.5), "g10-river.png")
        let wet = Self.bestCenter(map) { t in (t.feature == .jungle ? 2 : 0) + (t.feature == .marsh ? 3 : 0) }
        _ = try Self.render(Self.view(standard, center: wet, scale: 0.6), "g11-jungle-marsh.png")
        let woods = Self.bestCenter(map) { t in (t.feature == .forest ? 2 : 0) + (t.elevation == .hills ? 2 : 0) }
        _ = try Self.render(Self.view(standard, center: woods, scale: 0.6), "g12-forest-hills.png")
        _ = try Self.render(Self.view(standard, center: woods, scale: 0.6, tilted: false), "g13-forest-hills-topdown.png")

        // Cities: every size tier, walls, capitals, damage and four owners (g14…).
        try CityGallery.render(timing: &timing)
        // Borders, improvements, overlays, unit markers and combat (g15…, g16…).
        try SkirmishGallery.render(timing: &timing)
        // Upright iPads and iPhones at the widest zoom, past the poles (g17…).
        try PortraitGallery.render(timing: &timing)
        // A route whose planned steps bend through the fog, and later turns' dots (g18…).
        try RouteGallery.render(timing: &timing)
        // Builder job marks, settler sites and a ready Settler on the play-test's turns (g19…).
        try GuidanceGallery.render(timing: &timing)
        // Tribal villages: seen on hills, remembered, by a city, and at the widest zoom (g20…).
        try TribalVillageGallery.render(timing: &timing)

        // Atlases.
        if let image = world.decorAtlas.makeImage() { MapRendererTests.save(image, "atlas-decor.png") }
        if let image = world.unitAtlas.makeImage() { MapRendererTests.save(image, "atlas-units.png") }

        let report = timing.joined(separator: "\n") + "\n"
        print(report)
        if let dir = ProcessInfo.processInfo.environment["RENDER_OUT"] {
            try report.write(toFile: (dir as NSString).appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
        }
    }
}
