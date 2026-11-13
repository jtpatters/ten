import CoreGraphics
import Foundation
import Testing
import GameCore
import MapGen
import simd
@testable import MapRendering

/// A route into the fog, as in the play-test's T42 Scout (seed 11, an 11-turn route to a goal
/// four tiles away across a bay): a Scout of player 0 on a coast, everything within a few
/// tiles of it explored, and a goal in the fog across explored water. The plan (the viewer's
/// own, `PlayerView.path`) leaves the explored land and bends through the fog around the
/// water, so a straight line from where the explored part ends to the goal would cross
/// explored water.
@MainActor
enum RouteFogFixture {
    struct Scene {
        var state: GameState
        var scout: GameCore.Unit
        var goal: HexCoord
        var path: Path
        /// The steps before the first unexplored one.
        var known: Int
        /// How far the planned steps through the fog stray from the straight line between the
        /// last explored step and the goal (tile sizes), and how much explored water that line
        /// crosses (samples a quarter tile size apart).
        var bend: Float
        var wetSamples: Int
    }

    /// Searches the coasts near player 0's start, nearest first, for a Scout spot and a goal 5
    /// to 7 tiles away whose route (at least 4 turns) leaves explored land, stays in the fog
    /// for 3 steps or more, strays at least 2 tile sizes from the straight line and has that
    /// line cross explored water. The first spot with any such goal wins, with its most bent
    /// route.
    static func scene(size: MapSize = .duel, seed: UInt64 = 11, explored radius: Int = 4) throws -> Scene {
        let generated = MapGenerator.generate(MapGenSettings(size: size, seed: seed))
        let base = GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions)
        let map = base.map
        let layout = HexLayout(size: 32, map: map)
        let start = try #require(base.units(of: PlayerID(0)).first).position
        func water(_ hex: HexCoord) -> Bool { map.tile(at: hex).map { !$0.isLand } ?? false }
        let coasts = map.coords(within: 8, of: start).filter { hex in
            map.tile(at: hex)?.isLand == true && base.canEnd(.scout, owner: PlayerID(0), at: hex)
                && map.neighbors(of: hex).filter(water).count >= 2
        }.sorted { (map.distance($0, start), map.index(of: $0)!) < (map.distance($1, start), map.index(of: $1)!) }
        for spot in coasts {
            var state = base
            let id = state.addUnit(.scout, owner: PlayerID(0), at: spot)
            for hex in map.coords(within: radius, of: spot) { state.players[0].explored[map.index(of: hex)!] = true }
            let scout = try #require(state.unit(id))
            let explored = state.players[0].explored
            var best: Scene?
            let goals = map.coords(within: 7, of: spot).filter { map.distance($0, spot) >= 5 && !explored[map.index(of: $0)!] }
            for goal in goals.sorted(by: { map.index(of: $0)! < map.index(of: $1)! }) {
                guard let path = state.view(for: PlayerID(0)).path(for: id, to: goal), path.turns >= 4 else { continue }
                guard let known = path.steps.firstIndex(where: { !explored[map.index(of: $0.hex)!] }),
                      known >= 1, path.steps.count - known >= 3 else { continue }
                // Centers along the plan, each on the copy nearest the one before.
                var points = [MapRenderer.vec(layout.center(of: spot))]
                for step in path.steps {
                    let c = MapRenderer.vec(layout.center(of: step.hex))
                    points.append([Float(layout.nearestCopy(of: CGFloat(c.x), to: CGFloat(points[points.count - 1].x))), c.y])
                }
                let a = points[known], b = points[points.count - 1]
                let bend = points[known...].map { distance($0, toSegment: a, b) }.max() ?? 0
                var wet = 0
                let samples = Int(simd_distance(a, b) / (Float(layout.size) * 0.25))
                for k in 0...max(samples, 1) {
                    let p = a + (b - a) * Float(k) / Float(max(samples, 1))
                    guard let hex = map.normalize(layout.hex(at: CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))),
                          explored[map.index(of: hex)!], water(hex) else { continue }
                    wet += 1
                }
                let scene = Scene(state: state, scout: scout, goal: goal, path: path, known: known,
                                  bend: bend / Float(layout.size), wetSamples: wet)
                guard scene.bend >= 2, wet >= 2 else { continue }
                if best.map({ scene.bend > $0.bend }) ?? true { best = scene }
            }
            if let best { return best }
        }
        throw RouteFogError.noScene
    }

    enum RouteFogError: Error { case noScene }

    /// The play-test's T40 complaint: zoomed in, a route's later turns, small translucent dots,
    /// nearly vanished over remembered land. The scene's Scout with its moves spent and every
    /// tile within 7 of it explored, sent 5 or 6 tiles away over explored land: its route is
    /// all later turns' dots, over land in sight near the Scout and over remembered land further
    /// on. Of the goals whose route stays on explored tiles, the one whose route crosses the
    /// most remembered tiles wins (the first in tile order of those).
    static func remembered(_ scene: Scene) throws -> Scene {
        var state = try SkirmishFixture.edit(scene.state, [scene.scout.id: ["movesLeft": 0]])
        let map = state.map, spot = scene.scout.position
        for hex in map.coords(within: 7, of: spot) { state.players[0].explored[map.index(of: hex)!] = true }
        let view = state.view(for: PlayerID(0)), explored = state.players[0].explored
        let visible = state.visibleTiles(for: PlayerID(0))
        var best: (path: Path, goal: HexCoord, remembered: Int)?
        let goals = map.coords(within: 6, of: spot).filter { map.distance($0, spot) >= 5 }
        for goal in goals.sorted(by: { map.index(of: $0)! < map.index(of: $1)! }) {
            guard let path = view.path(for: scene.scout.id, to: goal),
                  path.steps.allSatisfy({ explored[map.index(of: $0.hex)!] }) else { continue }
            let remembered = path.steps.filter { !visible[map.index(of: $0.hex)!] }.count
            if best.map({ remembered > $0.remembered }) ?? true { best = (path, goal, remembered) }
        }
        let route = try #require(best)
        return Scene(state: state, scout: try #require(state.unit(scene.scout.id)), goal: route.goal, path: route.path,
                     known: route.path.steps.count, bend: 0, wetSamples: 0)
    }

    /// One line on the dots of a frame: how many over remembered land and in sight, their
    /// widths (points) and how much they brighten the ground under them (luminance).
    static func summary(_ dots: [Dot], scale: CGFloat) -> String {
        func median(_ v: [Float]) -> Float { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        let remembered = dots.filter(\.remembered), inSight = dots.filter { !$0.remembered }
        return String(format: "route dots at %.2f: %d over remembered land, %.1f to %.1f pt wide (median %.1f), lifting a %.2f ground by %.2f; %d in sight, %.1f to %.1f pt wide (median %.1f), lifting a %.2f ground by %.2f",
                      scale, remembered.count, remembered.map(\.width).min() ?? 0, remembered.map(\.width).max() ?? 0,
                      median(remembered.map(\.width)), median(remembered.map(\.ground)), median(remembered.map(\.lift)),
                      inSight.count, inSight.map(\.width).min() ?? 0, inSight.map(\.width).max() ?? 0, median(inSight.map(\.width)),
                      median(inSight.map(\.ground)), median(inSight.map(\.lift)))
    }

    /// A later turn's dot as drawn: its width and height on screen (points), how much it
    /// brightens the frame at its brightest (luminance, 0–1), the luminance of the ground there
    /// without the route, and whether it lies over remembered land.
    struct Dot {
        var width: Float, height: Float, lift: Float, ground: Float, remembered: Bool
    }

    /// The route's dots in a frame of `scene` at `scale` (`view`), without the turn markers:
    /// rendered with and without the route, a dot is a patch the route brightens (its cream
    /// fill; its ink edge, line and shadow only darken), off the destination ring and the
    /// frame's edges. Over land in sight, the dots of a turn after this one are translucent, so
    /// their brightening patches can come out a little smaller than they are.
    static func dots(_ scene: Scene, scale: CGFloat, width: Int = 800, height: Int = 600) throws -> [Dot] {
        let pixelScale = 2
        let renderer = view(scene, scale: scale, width: width * pixelScale, height: height * pixelScale,
                            pixelScale: CGFloat(pixelScale))
        renderer.unitArt.markers = []
        let w = width * pixelScale, h = height * pixelScale
        func luminance(_ image: CGImage) throws -> [Float] {
            let bytes = UnitTapTests.bytes(image) // BGRA
            try #require(bytes.count == w * h * 4)
            return (0..<(w * h)).map { i in
                (0.0722 * Float(bytes[i * 4]) + 0.7152 * Float(bytes[i * 4 + 1]) + 0.2126 * Float(bytes[i * 4 + 2])) / 255
            }
        }
        let with = try luminance(try #require(renderer.renderImage(width: w, height: h, scale: CGFloat(pixelScale))))
        renderer.showPath(nil, from: scene.scout.position)
        let without = try luminance(try #require(renderer.renderImage(width: w, height: h, scale: CGFloat(pixelScale))))
        var seen = [Bool](repeating: false, count: w * h)
        var dots: [Dot] = []
        for start in 0..<(w * h) where !seen[start] && with[start] - without[start] > 0.04 {
            var stack = [start], patch: [Int] = []
            seen[start] = true
            while let i = stack.popLast() {
                patch.append(i)
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                    let j = ny * w + nx
                    if !seen[j] && with[j] - without[j] > 0.04 { seen[j] = true; stack.append(j) }
                }
            }
            let xs = patch.map { $0 % w }, ys = patch.map { $0 / w }
            let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
            guard patch.count >= 4, x0 > 0, y0 > 0, x1 < w - 1, y1 < h - 1 else { continue }
            let center = CGPoint(x: CGFloat(x0 + x1 + 1) / CGFloat(2 * pixelScale), y: CGFloat(y0 + y1 + 1) / CGFloat(2 * pixelScale))
            guard let hex = renderer.hex(atViewPoint: center), hex != scene.goal else { continue }
            let top = patch.max { with[$0] - without[$0] < with[$1] - without[$1] }!
            dots.append(Dot(width: Float(x1 - x0 + 1) / Float(pixelScale), height: Float(y1 - y0 + 1) / Float(pixelScale),
                            lift: with[top] - without[top], ground: without[top], remembered: renderer.fogLevel(hex) == 1))
        }
        return dots
    }

    /// Distance from `p` to the segment `a`–`b`.
    static func distance(_ p: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a, l = simd_length_squared(ab)
        let t = l > 1e-6 ? min(max(simd_dot(p - a, ab) / l, 0), 1) : 0
        return simd_distance(p, a + ab * t)
    }

    /// Distance from `p` to a polyline.
    static func distance(_ p: SIMD2<Float>, toPolyline pts: [SIMD2<Float>]) -> Float {
        guard pts.count > 1 else { return pts.first.map { simd_distance(p, $0) } ?? .infinity }
        return (1..<pts.count).map { distance(p, toSegment: pts[$0 - 1], pts[$0]) }.min()!
    }

    /// A renderer showing the scene's route, the Scout selected, the camera on the middle of
    /// the route's bounding box at `scale`.
    static func view(_ scene: Scene, scale: CGFloat, width: Int, height: Int, pixelScale: CGFloat, fog: Bool = true,
                     insets: MapInsets = MapInsets(top: 0, bottom: 0)) -> MapRenderer {
        let renderer = MapRenderer(state: scene.state, viewer: PlayerID(0))
        renderer.animationTime = 100
        renderer.fogEnabled = fog
        renderer.setViewportInsets(insets)
        _ = renderer.renderImage(width: width, height: height, scale: pixelScale)
        renderer.setSelection(scene.scout.position)
        renderer.showPath(scene.path, from: scene.scout.position)
        renderer.setCameraScale(scale)
        let layout = renderer.layout
        let a = MapRenderer.vec(layout.center(of: scene.scout.position))
        var lo = a, hi = a
        for step in scene.path.steps {
            let c = MapRenderer.vec(layout.center(of: step.hex))
            let p = SIMD2<Float>(Float(layout.nearestCopy(of: CGFloat(c.x), to: CGFloat(a.x))), c.y)
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let mid = (lo + hi) / 2
        let hex = layout.hex(at: CGPoint(x: CGFloat(mid.x), y: CGFloat(mid.y)))
        renderer.centerCamera(on: scene.state.map.normalize(hex) ?? scene.scout.position, animated: false)
        return renderer
    }
}

/// Routes into the fog (`g18…`), on an upright iPad (834×1210 points at 2x): the play-test's
/// case, a Scout's route whose planned steps bend through the fog around a bay, at standard
/// zoom, close up, at the widest zoom and with the fog off; and a route of later turns' dots
/// over land in sight and remembered land (`RouteFogFixture.remembered`) at standard zoom and
/// zoomed in all the way. Runs only with RENDER_OUT (the ArtGallery run renders them too):
///
///     RENDER_OUT=/some/dir swift test --filter RouteGallery
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_OUT"] != nil))
struct RouteGallery {
    static func render(timing: inout [String]) throws {
        let scene = try RouteFogFixture.scene()
        let pad = PortraitGallery.iPad
        var lines = [String(format: "g18 scout %@ goal %@: %d steps, %d turns, %d explored, bend %.1f tile sizes, %d wet samples",
                            "\(scene.scout.position)", "\(scene.goal)", scene.path.steps.count, scene.path.turns, scene.known,
                            scene.bend, scene.wetSamples)]
        let remembered = try RouteFogFixture.remembered(scene)
        lines.append(String(format: "g18e scout %@ goal %@: %d steps, all after this turn",
                            "\(remembered.scout.position)", "\(remembered.goal)", remembered.path.steps.count))
        for (name, scale, fog, scene) in [("g18-route-fog", CGFloat(1), true, scene), ("g18b-route-fog-close", 0.6, true, scene),
                                          ("g18c-route-fog-widest", 1000, true, scene), ("g18d-route-nofog", 1, false, scene),
                                          ("g18e-route-remembered", 1, true, remembered),
                                          ("g18f-route-remembered-close", 0.35, true, remembered)] {
            let renderer = RouteFogFixture.view(scene, scale: scale, width: pad.points.x * pad.pixelScale,
                                                height: pad.points.y * pad.pixelScale, pixelScale: CGFloat(pad.pixelScale), fog: fog,
                                                insets: pad.insets)
            let image = try #require(PortraitGallery.render(renderer, on: pad))
            MapRendererTests.save(image, name + ".png")
            var samples: [Double] = []
            for _ in 0..<7 {
                _ = PortraitGallery.render(renderer, on: pad)
                samples.append(renderer.lastOffscreenGPUMilliseconds)
            }
            lines.append(String(format: "%@ scale %.2f gpu %.2f ms", name, renderer.camera.scale, samples.sorted()[3]))
        }
        timing += lines
    }

    @Test func routeGallery() throws {
        var lines: [String] = []
        try Self.render(timing: &lines)
        print(lines.joined(separator: "\n"))
    }
}
