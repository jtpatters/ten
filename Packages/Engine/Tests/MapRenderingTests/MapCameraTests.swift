import CoreGraphics
import Testing
import GameCore
import MapGen
@testable import MapRendering

@Suite struct MapCameraTests {
    let layout = HexLayout(size: 32, mapWidth: 80, mapHeight: 50, wrapsX: true)

    func camera(pitch: Float) -> MapCamera {
        MapCamera(target: [1000, 800], scale: 1, pitch: pitch, viewSize: [1024, 768])
    }

    @Test(arguments: [Float(0), 0.6])
    func viewCenterLooksAtTarget(pitch: Float) throws {
        let cam = camera(pitch: pitch)
        let g = try #require(cam.groundPoint(atViewPoint: CGPoint(x: 512, y: 384)))
        #expect(abs(g.x - 1000) < 0.01 && abs(g.y - 800) < 0.01)
    }

    @Test(arguments: [Float(0), 0.6])
    func projectAndUnprojectRoundTrip(pitch: Float) throws {
        let cam = camera(pitch: pitch)
        for p in [CGPoint(x: 10, y: 20), CGPoint(x: 900, y: 700), CGPoint(x: 512, y: 100)] {
            let g = try #require(cam.groundPoint(atViewPoint: p))
            let back = try #require(cam.viewPoint(of: SIMD3(g.x, g.y, 0)))
            #expect(abs(back.x - p.x) < 0.05 && abs(back.y - p.y) < 0.05)
        }
    }

    @Test func scaleOneIsOneWorldUnitPerPointAtTarget() throws {
        let cam = camera(pitch: 0.6)
        let a = try #require(cam.groundPoint(atViewPoint: CGPoint(x: 462, y: 384)))
        let b = try #require(cam.groundPoint(atViewPoint: CGPoint(x: 562, y: 384)))
        #expect(abs((b.x - a.x) - 100) < 0.5)
    }

    @Test func tiltedViewSeesFartherNorthThanSouth() throws {
        let cam = camera(pitch: 0.6)
        let top = try #require(cam.groundPoint(atViewPoint: CGPoint(x: 512, y: 0)))
        let bottom = try #require(cam.groundPoint(atViewPoint: CGPoint(x: 512, y: 768)))
        #expect(top.y - 800 > 800 - bottom.y)
    }

    @Test func panKeepsGroundPointUnderFinger() throws {
        var cam = camera(pitch: 0.6)
        let from = CGPoint(x: 300, y: 500), to = CGPoint(x: 420, y: 380)
        let grabbed = try #require(cam.groundPoint(atViewPoint: from))
        cam.pan(from: from, to: to, layout: layout)
        let now = try #require(cam.groundPoint(atViewPoint: to))
        #expect(abs(now.x - grabbed.x) < 0.5 && abs(now.y - grabbed.y) < 0.5)
    }

    @Test func zoomKeepsAnchorFixed() throws {
        var cam = camera(pitch: 0.6)
        let anchor = CGPoint(x: 200, y: 600)
        let before = try #require(cam.groundPoint(atViewPoint: anchor))
        cam.zoom(by: 1.5, around: anchor, layout: layout)
        let after = try #require(cam.groundPoint(atViewPoint: anchor))
        #expect(abs(cam.scale - 1 / 1.5) < 0.001)
        #expect(abs(after.x - before.x) < 0.5 && abs(after.y - before.y) < 0.5)
    }

    /// A view of a map: the landscape view of the Standard map the other tests use, an upright
    /// iPhone and iPad on the Duel map, which zoom out past the map's height, and an iPad on its
    /// side on the Duel map, which the wrap stops at 1.56.
    struct View: Sendable, CustomTestStringConvertible {
        var name: String
        var layout: HexLayout
        var size: SIMD2<Float>
        var testDescription: String { name }

        static let duel = HexLayout(size: 32, mapWidth: 44, mapHeight: 26, wrapsX: true)
        static let all = [
            View(name: "landscape, Standard", layout: HexLayout(size: 32, mapWidth: 80, mapHeight: 50, wrapsX: true), size: [1024, 768]),
            View(name: "iPhone upright, Duel", layout: duel, size: [402, 874]),
            View(name: "iPad upright, Duel", layout: duel, size: [834, 1210]),
            View(name: "iPad on its side, Duel", layout: duel, size: [1210, 834]),
        ]
    }

    @Test(arguments: View.all)
    func clampWrapsXAndLimitsZoom(view: View) throws {
        var cam = MapCamera(target: [1000, 800], scale: 1, pitch: 0.6, viewSize: view.size)
        let w = Float(view.layout.worldWidth)
        cam.target.x = w + 50
        cam.scale = 100
        cam.clamp(layout: view.layout)
        #expect(abs(cam.target.x - 50) < 0.01)
        // At max zoom-out, the far (widest) edge of the view is still narrower than the world.
        let tl = try #require(cam.groundPoint(atViewPoint: CGPoint(x: 0, y: 0)))
        let tr = try #require(cam.groundPoint(atViewPoint: CGPoint(x: CGFloat(view.size.x), y: 0)))
        #expect(tr.x - tl.x <= w * 0.93)
    }

    /// Wherever the camera is pushed, at any zoom and tilt, the view never shows more than the
    /// polar margin past the map's north and south edges, unless it is taller than the map plus
    /// those margins (zoomed out past the map's height): then it centres the map, and the polar
    /// bands it shows beyond them are as tall in the north as in the south.
    @Test(arguments: View.all, [Float(0), 0.6])
    func clampKeepsTheViewOnTheMapVertically(view: View, pitch: Float) throws {
        let margin = Float(view.layout.rowHeight) * MapCamera.edgeMarginRows
        let worldH = Float(view.layout.worldHeight)
        var centred = 0
        for scale: Float in [0.35, 1, 2, 3, 1000] {
            for y: Float in [-5000, 0, worldH / 2, worldH, worldH + 5000] {
                var cam = MapCamera(target: [100, y], scale: scale, pitch: pitch, viewSize: view.size)
                cam.clamp(layout: view.layout)
                let midX = CGFloat(view.size.x) / 2
                let near = try #require(cam.groundPoint(atViewPoint: CGPoint(x: midX, y: CGFloat(view.size.y))))
                let far = try #require(cam.groundPoint(atViewPoint: CGPoint(x: midX, y: 0)))
                if far.y - near.y <= worldH + 2 * margin + 0.5 {
                    #expect(near.y >= -margin - 0.5, "scale \(scale) y \(y): near edge \(near.y)")
                    #expect(far.y <= worldH + margin + 0.5, "scale \(scale) y \(y): far edge \(far.y)")
                } else {
                    centred += 1
                    let south = -margin - near.y, north = far.y - worldH - margin
                    #expect(abs(south - north) < 0.5, "scale \(scale) y \(y): \(south) past the south margin, \(north) past the north")
                }
            }
        }
        // Upright on the Duel map, the widest zooms show more than the map's height.
        #expect((centred > 0) == (view.layout.mapHeight == 26), "\(centred) views centred")
    }

    /// Upright phones and iPads on the smallest map zoom out to the strategic level (the
    /// play-tests stopped at 1.22 and 0.88): the map's height no longer limits zoom-out below
    /// `zoomOutFloor`, while the wrap still does (the far edge stays within 0.92 of a period).
    @MainActor @Test func uprightViewsZoomOutToTheStrategicLevel() throws {
        let duel = View.duel
        let phone = MapCamera(target: [1000, 600], pitch: 0.6, viewSize: [402, 874]).maxScale(layout: duel)
        let pad = MapCamera(target: [1000, 600], pitch: 0.6, viewSize: [834, 1210]).maxScale(layout: duel)
        #expect(phone == MapCamera.zoomOutFloor)
        #expect(pad >= MapRenderer.strategicEnter && pad < MapCamera.zoomOutFloor, "iPad: \(pad)")
        // The iPad's limit is the wrap's: at it, the far edge spans 0.92 of a world period.
        let cam = MapCamera(target: [1000, 600], scale: pad, pitch: 0.6, viewSize: [834, 1210])
        let tl = try #require(cam.groundPoint(atViewPoint: CGPoint(x: 0, y: 0)))
        let tr = try #require(cam.groundPoint(atViewPoint: CGPoint(x: 834, y: 0)))
        #expect(abs((tr.x - tl.x) / Float(duel.worldWidth) - 0.92) < 0.002)
        // A view the map's height already let zoom out past the floor keeps its limit: there it
        // shows the map plus its polar margins exactly.
        var landscape = camera(pitch: 0.6)
        landscape.scale = landscape.maxScale(layout: layout)
        #expect(landscape.scale > MapCamera.zoomOutFloor)
        let span = try #require(landscape.groundSpanY)
        let margins = 2 * Float(layout.rowHeight) * MapCamera.edgeMarginRows
        #expect(abs(span.north - span.south - Float(layout.worldHeight) - margins) < 0.5)
    }

    /// Where the wrap stops zoom-out short of the strategic level (2.1), the widest zoom shows
    /// the strategic medallions all the same: they come in at 98% of the widest zoom when that
    /// is below 2.1, and go below 1.9/2.1 of that. On the Duel map that is an iPad on its side
    /// (1.56, the merge review's case), a 13-inch iPad either way (1.38 on its side, 1.83
    /// upright) and a large iPhone on its side (1.98); a view that zooms out to 2.15 or more
    /// keeps 2.1 and 1.9.
    @MainActor @Test func theWidestZoomShowsTheMedallionsWhereTheWrapStopsShortOfThem() throws {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: 11))
        let state = GameState.newGame(seed: 11, map: generated.map, startPositions: generated.startPositions)
        let views: [(name: String, size: SIMD2<Int>, widest: Float)] = [
            ("iPad 11-inch on its side", [1210, 834], 1.564), ("iPad 13-inch on its side", [1376, 1032], 1.375),
            ("iPad 13-inch upright", [1032, 1376], 1.834), ("iPhone Pro Max on its side", [956, 440], 1.979),
            ("iPad 11-inch upright", [834, 1210], 2.269), ("iPhone on its side", [874, 402], 2.165),
        ]
        for view in views {
            let renderer = MapRenderer(state: state, viewer: PlayerID(0))
            func zoom(_ scale: Float) -> Bool {
                renderer.setCameraScale(CGFloat(scale))
                _ = renderer.unitFrame()
                return renderer.showsStrategicTokens
            }
            _ = renderer.renderImage(width: view.size.x, height: view.size.y, scale: 1)
            #expect(!zoom(1), "\(view.name): strategic at 1")
            #expect(zoom(1000), "\(view.name): not strategic at the widest zoom")
            let widest = renderer.camera.scale
            #expect(abs(widest - view.widest) < 0.002, "\(view.name): widest \(widest)")
            let flip = renderer.strategicSwitch()
            if widest * MapRenderer.strategicWidestShare < MapRenderer.strategicEnter {
                #expect(abs(flip.enter - widest * MapRenderer.strategicWidestShare) < 1e-4, "\(view.name): enters at \(flip.enter)")
                #expect(abs(flip.leave / flip.enter - MapRenderer.strategicLeave / MapRenderer.strategicEnter) < 1e-4)
            } else {
                #expect(flip.enter == MapRenderer.strategicEnter && flip.leave == MapRenderer.strategicLeave, "\(view.name)")
            }
            #expect(zoom(flip.leave * 1.02), "\(view.name): hysteresis")
            #expect(!zoom(flip.leave * 0.98), "\(view.name): still strategic below \(flip.leave)")
            #expect(!zoom(flip.enter * 0.99), "\(view.name): strategic short of \(flip.enter)")
            #expect(zoom(flip.enter), "\(view.name): not strategic at \(flip.enter)")
        }
    }

    /// With panels over the view's top and bottom, the clamp holds the uncovered part's edges
    /// (not the view's) to the map plus its polar margins, and lets them reach those limits:
    /// a hex in the first or last row can be brought out from under a panel.
    @Test(arguments: [Float(0), 0.6])
    func coveredBandsMoveTheLimitsToTheUncoveredPart(pitch: Float) throws {
        let margin = Float(layout.rowHeight) * MapCamera.edgeMarginRows
        let worldH = Float(layout.worldHeight)
        for y: Float in [-5000, worldH + 5000] {
            var cam = camera(pitch: pitch)
            cam.coveredTop = 120
            cam.coveredBottom = 240
            cam.target = [100, y]
            cam.clamp(layout: layout)
            let near = try #require(cam.groundPoint(atViewPoint: CGPoint(x: 512, y: 768 - 240)))
            let far = try #require(cam.groundPoint(atViewPoint: CGPoint(x: 512, y: 120)))
            #expect(near.y >= -margin - 0.5, "y \(y): near edge \(near.y)")
            #expect(far.y <= worldH + margin + 0.5, "y \(y): far edge \(far.y)")
            if y < 0 {
                #expect(abs(near.y + margin) < 0.5, "pushed south, the uncovered part ends at the margin: \(near.y)")
            } else {
                #expect(abs(far.y - worldH - margin) < 0.5, "pushed north, the uncovered part ends at the margin: \(far.y)")
            }
        }
    }
}
