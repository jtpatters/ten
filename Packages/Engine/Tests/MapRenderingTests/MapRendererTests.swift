import CoreGraphics
import Foundation
import ImageIO
import Testing
import GameCore
import MapGen
import simd
@testable import MapRendering

/// Renders real frames offscreen: compiles the shaders, builds every pipeline and the atlas,
/// and checks the output isn't blank. Set RENDER_OUT=/some/dir to also write PNGs.
@MainActor
@Suite struct MapRendererTests {
    static func makeRenderer(size: MapSize = .small, seed: UInt64 = 42) -> MapRenderer {
        let generated = MapGenerator.generate(MapGenSettings(size: size, seed: seed))
        let state = GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions)
        return MapRenderer(state: state, viewer: PlayerID(0))
    }

    static func distinctColors(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        var seen = Set<UInt32>()
        data.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt32.self)
            for i in stride(from: 0, to: pixels.count, by: 97) { seen.insert(pixels[i]) }
        }
        return seen.count
    }

    static func save(_ image: CGImage, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_OUT"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// The atlases are map-independent: a second renderer reuses the first one's textures
    /// instead of painting them again, and the atlas still reads back for inspection.
    @Test func atlasesAreBuiltOncePerProcess() throws {
        let a = Self.makeRenderer(seed: 1), b = Self.makeRenderer(size: .duel, seed: 2)
        #expect(a.decorAtlas.texture === b.decorAtlas.texture)
        #expect(a.unitAtlas.texture === b.unitAtlas.texture)
        let image = try #require(a.unitAtlas.makeImage())
        #expect(image.width == a.unitAtlas.width && Self.distinctColors(image) > 50)
    }

    /// Drawing only the decorations near the view changes no pixel: same frame, same clock,
    /// culled and unculled, tilted and top-down, near the poles and mid-map.
    @Test(arguments: [(true, Float(0.5)), (true, 1.0), (false, 0.8), (true, 2.5)])
    func decorationCullingIsInvisible(tilted: Bool, scale: Float) throws {
        let renderer = Self.makeRenderer(size: .standard, seed: 7)
        renderer.fogEnabled = false
        renderer.tilted = tilted
        renderer.animationTime = 100
        renderer.setCameraScale(CGFloat(scale))
        for y in [0.1, 0.5, 0.95] {
            renderer.setCameraPosition(CGPoint(x: renderer.layout.worldWidth * 0.3, y: renderer.layout.worldHeight * y))
            renderer.cullDecorations = false
            let full = try #require(renderer.renderImage(width: 480, height: 360))
            let all = renderer.spritesDrawn
            renderer.cullDecorations = true
            let culled = try #require(renderer.renderImage(width: 480, height: 360))
            #expect(Self.maxChannelDifference(full, culled) <= 1, "y \(y): culling changed pixels")
            if scale <= 1 { #expect(renderer.spritesDrawn * 2 < all, "y \(y): \(renderer.spritesDrawn) of \(all) drawn") }
        }
    }

    static func maxChannelDifference(_ a: CGImage, _ b: CGImage) -> Int {
        guard let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data?, da.count == db.count else { return 255 }
        return zip(da, db).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    @Test func rendersFoggedStart() throws {
        let renderer = Self.makeRenderer()
        let image = try #require(renderer.renderImage(width: 1600, height: 1100))
        #expect(Self.distinctColors(image) > 50)
        Self.save(image, "fog.png")
    }

    @Test func rendersRevealedWorldTiltedAndTopDown() throws {
        let renderer = Self.makeRenderer(size: .standard, seed: 7)
        renderer.fogEnabled = false
        renderer.setCameraScale(1.6)
        let tilted = try #require(renderer.renderImage(width: 1600, height: 1100))
        #expect(Self.distinctColors(tilted) > 200)
        Self.save(tilted, "world-tilted.png")

        renderer.tilted = false
        let flat = try #require(renderer.renderImage(width: 1600, height: 1100))
        Self.save(flat, "world-topdown.png")

        renderer.tilted = true
        renderer.setCameraScale(0.5)
        Self.save(try #require(renderer.renderImage(width: 1600, height: 1100)), "closeup.png")
    }

    @Test func wrapSeamRenders() throws {
        let renderer = Self.makeRenderer()
        renderer.fogEnabled = false
        renderer.setCameraPosition(CGPoint(x: 0, y: renderer.layout.worldHeight / 2))
        let image = try #require(renderer.renderImage(width: 1600, height: 1100))
        #expect(Self.distinctColors(image) > 200)
        Self.save(image, "seam.png")
    }

    @Test func pathPreviewAndUnitHitTest() throws {
        let renderer = Self.makeRenderer()
        let state = renderer.state
        let unit = try #require(state.units(of: PlayerID(0)).first { $0.type == .warrior })
        let target = try #require(state.map.coords(within: 4, of: unit.position).first { hex in
            state.map.tile(at: hex)?.landMovementCost != nil && state.map.distance(hex, unit.position) == 4
        })
        let path = try #require(Pathfinder.findPath(for: unit, to: target, in: state))
        renderer.setSelection(unit.position)
        renderer.showPath(path, from: unit.position)
        renderer.setCameraScale(0.7)
        renderer.centerCamera(on: unit.position, animated: false)
        let image = try #require(renderer.renderImage(width: 1600, height: 1100))
        Self.save(image, "path.png")

        // Tapping the view center (the unit's tile) resolves to the unit's hex.
        let hex = renderer.hex(atViewPoint: CGPoint(x: 400, y: 275))
        #expect(hex == unit.position)
    }

    /// The play-test's T42 Scout: a route whose planned steps bend through the fog around a bay
    /// was drawn on from its last explored step as one straight dotted line across the water.
    /// Now the rest follows the planned steps, as faint rings with no turn markers: it passes
    /// through every planned step's center and stays on the planned tiles, so it never crosses
    /// the explored water the plan goes around.
    @Test func routeThroughTheFogFollowsItsPlan() throws {
        let scene = try RouteFogFixture.scene()
        let renderer = RouteFogFixture.view(scene, scale: 1, width: 800, height: 600, pixelScale: 2)
        let layout = renderer.layout, map = scene.state.map
        let s = Float(layout.size)
        var points = [MapRenderer.vec(layout.center(of: scene.scout.position))]
        for step in scene.path.steps {
            let c = MapRenderer.vec(layout.center(of: step.hex))
            points.append([Float(layout.nearestCopy(of: CGFloat(c.x), to: CGFloat(points[points.count - 1].x))), c.y])
        }
        let plan = Array(points[scene.known...])
        let art = renderer.unitArt
        // The drawn route ends on the last explored step, where the rest begins; the rest ends
        // on the goal.
        #expect(simd_distance(try #require(art.route.last), plan[0]) < 0.01)
        #expect(simd_distance(try #require(art.unknownRoute.first), plan[0]) < 0.01)
        #expect(simd_distance(try #require(art.unknownRoute.last), plan[plan.count - 1]) < 0.01)
        // Through every planned center, only over the planned tiles.
        for p in plan { #expect(RouteFogFixture.distance(p, toPolyline: art.unknownRoute) < 0.05 * s) }
        let tiles = Set(scene.path.steps[max(scene.known - 1, 0)...].map(\.hex))
        let strays = art.unknownRoute.filter { p in
            map.normalize(layout.hex(at: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))).map { !tiles.contains($0) } ?? true
        }
        #expect(strays.isEmpty, "\(strays.count) of \(art.unknownRoute.count) samples leave the planned tiles")
        // The rings drawn this frame lie along it and bend well away from the straight line.
        let rings = renderer.overlayGeometry().filter { $0.position.w == OverlayStyle.unknown.rawValue }
        try #require(!rings.isEmpty)
        let ground = rings.map { SIMD2<Float>($0.position.x, $0.position.y) }
        let off = ground.map { RouteFogFixture.distance($0, toPolyline: plan) }.max() ?? 0
        #expect(off < 0.5 * s, "a ring vertex lies \(off / s) tile sizes off the plan")
        let bend = ground.map { RouteFogFixture.distance($0, toSegment: plan[0], plan[plan.count - 1]) }.max() ?? 0
        #expect(bend > 1.5 * s, "the rings stray only \(bend / s) tile sizes from the straight line")
        // No turn markers in the fog: one on each explored turn end, none after.
        let ends = (0..<scene.known).filter { i in scene.path.steps[i + 1].turn != scene.path.steps[i].turn }
        #expect(art.markers.map(\.hex).sorted { map.index(of: $0)! < map.index(of: $1)! }
                == ends.map { scene.path.steps[$0].hex }.sorted { map.index(of: $0)! < map.index(of: $1)! })
        Self.save(try #require(renderer.renderImage(width: 800, height: 600)), "route-fog.png")
    }

    /// The play-test's T40 complaint: a route's later turns were translucent dots about 3
    /// points across, which nearly vanished zoomed in and over remembered land. Measured in the
    /// frame (`RouteFogFixture.remembered`), zoomed in (0.35) and at standard zoom: they are
    /// about 6 points across or more, and over remembered land opaque cream, well clear of the
    /// darkened ground.
    @Test(arguments: [CGFloat(0.35), 1.0])
    func laterTurnDotsStayLegible(scale: CGFloat) throws {
        let scene = try RouteFogFixture.remembered(try RouteFogFixture.scene())
        try #require(scene.path.steps.allSatisfy { $0.turn >= 2 })
        let dots = try RouteFogFixture.dots(scene, scale: scale)
        print(RouteFogFixture.summary(dots, scale: scale))
        let remembered = dots.filter(\.remembered)
        #expect(remembered.count >= 4 && dots.count - remembered.count >= 4, "\(remembered.count) of \(dots.count) dots over remembered land")
        // About 6 points across or more; measured by what it brightens, a translucent dot over
        // bright ground loses up to half a point.
        #expect(dots.allSatisfy { $0.width >= 5.5 }, "a dot \(dots.map(\.width).min() ?? 0) points wide")
        #expect(remembered.allSatisfy { $0.width >= 6 })
        // Over remembered land opaque: its center as bright as cream, well above the ground.
        for dot in remembered {
            #expect(dot.ground + dot.lift >= 0.85 && dot.lift >= 0.4, "a dot over remembered land lifts a \(dot.ground) ground by only \(dot.lift)")
        }
    }

    /// The rest of a route through the fog shows nothing hidden: in a world whose unexplored
    /// tiles are all different (land turned to sea and sea to forest), the viewer's plan is the
    /// same, the route's geometry is the same and the frame renders within 6/255 (ART.md §8).
    @Test func routeThroughTheFogShowsNothingHidden() throws {
        let scene = try RouteFogFixture.scene()
        var other = scene.state
        let explored = other.players[0].explored
        for i in 0..<other.map.tileCount where !explored[i] {
            other.map[index: i] = other.map[index: i].isLand ? Tile(terrain: .ocean) : Tile(terrain: .grassland, feature: .forest)
        }
        let path = try #require(other.view(for: PlayerID(0)).path(for: scene.scout.id, to: scene.goal))
        #expect(path == scene.path)
        var flipped = scene
        flipped.state = other
        let a = RouteFogFixture.view(scene, scale: 1, width: 640, height: 480, pixelScale: 2)
        let b = RouteFogFixture.view(flipped, scale: 1, width: 640, height: 480, pixelScale: 2)
        let ga = a.overlayGeometry(), gb = b.overlayGeometry()
        #expect(ga.count == gb.count && zip(ga, gb).allSatisfy { $0.position == $1.position && $0.color == $1.color })
        let ia = UnitTapTests.bytes(try #require(a.renderImage(width: 640, height: 480)))
        let ib = UnitTapTests.bytes(try #require(b.renderImage(width: 640, height: 480)))
        #expect(ia.count == ib.count)
        let worst = zip(ia, ib).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 6, "worst channel difference \(worst)")
    }
}
