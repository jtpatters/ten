import CoreGraphics
import Foundation
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// Portrait views at the widest zoom (`g17…`): an iPad (834×1210 points at 2x) and an iPhone
/// (402×874 points at 3x) upright, on the Duel, Small and Standard maps, with the bands the
/// App's HUD covers at the top and bottom. Two empires with cities, territory, improvements and
/// units, once in the fog of a mid game and once with the fog off. They show what lies beyond
/// the poles when the view is taller than the map, and the strategic tokens; `g17-…-landscape`
/// adds both devices on their side for the Duel map, and `g17-duel-ipad13…` a 13-inch iPad
/// (1032×1376 points) both ways, where the wrap stops zoom-out short of 2.1 and the widest zoom
/// shows the medallions all the same. Runs only with RENDER_OUT:
///
///     RENDER_OUT=/some/dir swift test --filter PortraitGallery
///
/// (the ArtGallery run renders them too) and writes `portrait.txt` with each view's zoom.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_OUT"] != nil))
struct PortraitGallery {
    struct Device {
        var name: String
        var points: SIMD2<Int>
        var pixelScale: Int
        /// What the HUD covers at the top (status bar, top bar) and bottom (Next or End Turn).
        var insets: MapInsets
    }

    static let iPad = Device(name: "ipad", points: [834, 1210], pixelScale: 2, insets: MapInsets(top: 85, bottom: 75))
    static let iPhone = Device(name: "iphone", points: [402, 874], pixelScale: 3, insets: MapInsets(top: 166, bottom: 90))
    static let iPadLandscape = Device(name: "ipad-landscape", points: [1210, 834], pixelScale: 2, insets: MapInsets(top: 85, bottom: 75))
    static let iPhoneLandscape = Device(name: "iphone-landscape", points: [874, 402], pixelScale: 3, insets: MapInsets(top: 52, bottom: 60))
    /// A 13-inch iPad, whose width the wrap limits most on the Duel map (1.38 on its side).
    static let iPad13 = Device(name: "ipad13", points: [1032, 1376], pixelScale: 2, insets: MapInsets(top: 85, bottom: 75))
    static let iPad13Landscape = Device(name: "ipad13-landscape", points: [1376, 1032], pixelScale: 2, insets: MapInsets(top: 85, bottom: 75))

    /// A game some fifty turns in: each player's capital on its start tile and a second city
    /// five tiles away, units of every kind around them, territory and improvements, and (for
    /// the fog) player 0 has explored eight tiles around its cities and four around the other
    /// empire's capital.
    struct Scene {
        var state: GameState
        var cities: [CityMarker]
        var capital: HexCoord
    }

    static func scene(_ size: MapSize, seed: UInt64) throws -> Scene {
        var state = ArtGallery.world(size, seed: seed)
        let map = state.map
        var cities: [CityMarker] = []
        for player in state.players.indices.prefix(2) {
            let owner = PlayerID(player)
            let start = try #require(state.units(of: owner).first { $0.type == .settler }).position
            cities.append(CityMarker(id: cities.count, hex: start, owner: owner, population: 5, capital: true, walls: true, hp: 1, wallHP: 1))
            let second = map.coords(within: 5, of: start).first { hex in
                guard map.distance(hex, start) == 5, let tile = map.tile(at: hex) else { return false }
                return tile.isLand && tile.elevation != .mountains
            }
            if let second {
                cities.append(CityMarker(id: cities.count, hex: second, owner: owner, population: 2, capital: false, walls: false, hp: 1, wallHP: 1))
            }
            // Units around the cities: the start's own, plus an army and workers.
            var spots = map.coords(within: 3, of: start).filter { map.distance($0, start) >= 1 }.makeIterator()
            for type in [UnitType.warrior, .archer, .spearman, .builder, .scout] {
                while let hex = spots.next() {
                    guard state.canEnd(type, owner: owner, at: hex), state.units(at: hex).isEmpty else { continue }
                    state.addUnit(type, owner: owner, at: hex)
                    break
                }
            }
            if let second, state.canEnd(.warrior, owner: owner, at: second) { state.addUnit(.warrior, owner: owner, at: second) }
        }
        // A foreign patrol in sight of player 0's capital.
        let capital = cities[0].hex
        if let hex = map.coords(within: 2, of: capital).first(where: { hex in
            map.distance(hex, capital) == 2 && state.canEnd(.warrior, owner: PlayerID(1), at: hex) && state.units(at: hex).isEmpty
        }) {
            state.addUnit(.warrior, owner: PlayerID(1), at: hex)
        }
        for city in cities {
            let radius = city.owner == PlayerID(0) ? 8 : (city.capital ? 4 : 0)
            for hex in map.coords(within: radius, of: city.hex) { state.players[0].explored[map.index(of: hex)!] = true }
        }
        return Scene(state: state, cities: cities, capital: capital)
    }

    /// A renderer for the scene on a device, zoomed all the way out and centred on player 0's
    /// capital (`MapCamera.clamp` then centres the map when the view is taller than it).
    static func view(_ scene: Scene, on device: Device, fog: Bool, scale: CGFloat = 1000) -> MapRenderer {
        let renderer = MapRenderer(state: scene.state, viewer: PlayerID(0))
        renderer.animationTime = 100
        renderer.fogEnabled = fog
        renderer.setCities(scene.cities)
        let territory = SkirmishFixture.territory(scene.state.map, scene.cities)
        renderer.setTerritory(territory)
        renderer.setImprovements(SkirmishFixture.improvements(scene.state.map, scene.cities, territory: territory))
        renderer.setViewportInsets(device.insets)
        // The first frame sets the view's size, which the zoom limits depend on.
        _ = render(renderer, on: device)
        renderer.setCameraScale(scale)
        renderer.centerCamera(on: scene.capital, animated: false)
        return renderer
    }

    static func render(_ renderer: MapRenderer, on device: Device) -> CGImage? {
        renderer.renderImage(width: device.points.x * device.pixelScale, height: device.points.y * device.pixelScale,
                             scale: CGFloat(device.pixelScale))
    }

    static func render(timing: inout [String]) throws {
        var lines: [String] = []
        let maps: [(MapSize, UInt64)] = [(.duel, 11), (.small, 42), (.standard, 7)]
        for (size, seed) in maps {
            let scene = try scene(size, seed: seed)
            var devices = [iPad, iPhone]
            if size == .duel { devices += [iPadLandscape, iPhoneLandscape, iPad13, iPad13Landscape] }
            for device in devices {
                for fog in [true, false] where fog || device.points.x < device.points.y {
                    let renderer = view(scene, on: device, fog: fog)
                    let image = try #require(render(renderer, on: device))
                    #expect(MapRendererTests.distinctColors(image) > 100)
                    let name = "g17-\(size.rawValue)-\(device.name)\(fog ? "" : "-nofog").png"
                    MapRendererTests.save(image, name)
                    let maxScale = renderer.camera.maxScale(layout: renderer.layout)
                    lines.append(String(format: "%@ scale %.3f (max %.3f) strategic %@ sprites %d", name, renderer.camera.scale, maxScale,
                                        renderer.showsStrategicTokens ? "yes" : "no", renderer.spritesDrawn))
                }
            }
        }
        timing += lines
        if let dir = ProcessInfo.processInfo.environment["RENDER_OUT"] {
            try (lines.joined(separator: "\n") + "\n").write(toFile: (dir as NSString).appendingPathComponent("portrait.txt"),
                                                             atomically: true, encoding: .utf8)
        }
    }

    @Test func portraitGallery() throws {
        var lines: [String] = []
        try Self.render(timing: &lines)
        print(lines.joined(separator: "\n"))
    }
}
