import CoreGraphics
import Foundation
import Testing
import simd
import GameCore
@testable import MapRendering

/// The tribal villages' art (M1 §7.7, ART.md §11 "Tribal villages"; phase 3g, H3, in place of
/// H0's stub): two round huts and a wood pile on trodden ground with a cooking fire, the fogged
/// look when remembered, an ivory token zoomed out, the tile's plants cleared (its relief kept),
/// and the fade of a take. The scene is `TribalVillageFixture`'s, which stays as it is:
/// `build/m1/art-ab-3g` times it on both sides of the art A/B.
@MainActor
@Suite struct TribalVillageArtTests {
    static let width = UnitLayeringTests.width, height = UnitLayeringTests.height
    static let me = TribalVillageFixture.me

    /// A renderer showing the scene as the App passes it, with `markers` in place of the scene's,
    /// the camera on `hex` at `scale` (rendered once first: zoom is clamped for the view size).
    static func view(_ scene: TribalVillageFixture.Scene, _ markers: [TribalVillageMarker]? = nil, on hex: HexCoord, scale: CGFloat,
                     fog: Bool = true) throws -> MapRenderer {
        let r = MapRenderer(state: scene.state, viewer: me)
        r.fogEnabled = fog
        r.animationTime = 5
        r.setCities(scene.cities)
        r.setTerritory(scene.territory)
        r.setImprovements(scene.improvements)
        r.setTribalVillages(markers ?? scene.markers)
        _ = try #require(r.renderImage(width: width, height: height))
        r.setCameraScale(scale)
        r.centerCamera(on: hex, animated: false)
        _ = try #require(r.renderImage(width: width, height: height))
        return r
    }

    /// A tile size on screen, in pixels (2 per point).
    static func tilePixels(_ r: MapRenderer) -> Float { 2 * Float(r.layout.size) / Float(r.camera.scale) }

    /// How far pixel `i` lies from view point `c` (points), in tile sizes on screen.
    static func distance(_ i: Int, from c: CGPoint, in r: MapRenderer) -> Float {
        let dx = Float(i % width) - Float(c.x) * 2, dy = Float(i / width) - Float(c.y) * 2
        return (dx * dx + dy * dy).squareRoot() / tilePixels(r)
    }

    /// Where a world point on the ground, raised `lift` tile sizes the way sprites stand,
    /// appears in the view (points).
    static func viewPoint(_ r: MapRenderer, _ p: SIMD2<Float>, lift: Float) -> CGPoint? {
        r.camera.viewPoint(of: SIMD3(p.x, p.y, 0) + r.camera.up * (lift * Float(r.layout.size)))
    }

    static func luminance(_ pixels: [UInt8], _ i: Int) -> Float {
        0.3 * Float(pixels[i * 4]) + 0.59 * Float(pixels[i * 4 + 1]) + 0.11 * Float(pixels[i * 4 + 2])
    }

    /// The scene has each kind: seen on hills, seen by the city, remembered in the fog.
    @Test func theSceneHasEachKind() throws {
        let scene = try TribalVillageFixture.scene()
        let view = scene.state.view(for: TribalVillageFixture.me)
        let map = scene.state.map
        #expect(Set(scene.markers) == [TribalVillageMarker(hex: scene.hills, seen: true), TribalVillageMarker(hex: scene.byCity, seen: true),
                                       TribalVillageMarker(hex: scene.remembered, seen: false)])
        #expect(map.tile(at: scene.hills)?.elevation == .hills && map.distance(scene.byCity, scene.capital) == 2)
        #expect(view.isExplored(scene.remembered) && !view.isVisible(scene.remembered))
        #expect(DebugTools.tribalVillages(in: scene.state).count == 3 && view.knownCities.count == 1)
    }

    /// Markers are kept on the map, one per tile (the first given wins), in tile order.
    @Test func markersAreNormalized() throws {
        let scene = try TribalVillageFixture.scene()
        let r = MapRenderer(state: scene.state, viewer: TribalVillageFixture.me)
        let map = scene.state.map
        let a = scene.remembered, b = scene.hills
        let wrapped = HexCoord(q: a.q + map.width, r: a.r)
        #expect(map.normalize(wrapped) == a)
        r.setTribalVillages([TribalVillageMarker(hex: b, seen: true), TribalVillageMarker(hex: wrapped, seen: false),
                             TribalVillageMarker(hex: a, seen: true), TribalVillageMarker(hex: HexCoord(q: 0, r: -40), seen: true)])
        let expected = [TribalVillageMarker(hex: a, seen: false), TribalVillageMarker(hex: b, seen: true)]
            .sorted { map.index(of: $0.hex)! < map.index(of: $1.hex)! }
        #expect(r.inputs.tribalVillages == expected)
        r.setTribalVillages([])
        #expect(r.inputs.tribalVillages.isEmpty)
    }

    /// Two round huts, one a little bigger, and a wood pile, about a third of a tile round a
    /// hearth a little south of the hex centre, inside the hex, back to front, the wood pile in
    /// front of the fire: the same for a tile every time, and varied from tile to tile. Fewer
    /// pieces on a smaller ground than a city of one.
    @Test func layoutsAreTwoRoundHutsAndAWoodPileRoundAHearth() throws {
        let city = MapRenderer.buildLayout(CityMarker(id: 1, hex: HexCoord(q: 0, r: 0), owner: PlayerID(0), population: 1, capital: false,
                                                      walls: false, hp: 1, wallHP: 1))
        #expect(MapRenderer.tribalVillageGroundSize < city.ground && city.pieces.count > 3)
        var plans = Set<[Int]>()
        let tiles = 0..<3000
        for tile in tiles {
            let a = MapRenderer.tribalVillageLayout(tile: tile), b = MapRenderer.tribalVillageLayout(tile: tile)
            #expect(a.pieces.count == b.pieces.count && a.hearth == b.hearth && a.seed == b.seed
                    && zip(a.pieces, b.pieces).allSatisfy { $0.piece == $1.piece && $0.at == $1.at && $0.scale == $1.scale })
            let huts = a.pieces.filter { $0.piece == .house5 }, piles = a.pieces.filter { $0.piece == .hay }
            guard a.pieces.count == 3, huts.count == 2, piles.count == 1 else {
                Issue.record("tile \(tile): \(a.pieces.map(\.piece))")
                continue
            }
            #expect(zip(a.pieces, a.pieces.dropFirst()).allSatisfy { $0.at.y >= $1.at.y }, "tile \(tile): back to front")
            #expect(a.pieces.allSatisfy { simd_length($0.at) < 0.45 }, "tile \(tile): inside the hex")
            #expect(abs(a.hearth.x) <= 0.04 && a.hearth.y < -0.02 && a.hearth.y > -0.08, "tile \(tile): the hearth")
            #expect(a.pieces.allSatisfy { simd_length($0.at - a.hearth) > 0.24 }, "tile \(tile): round the hearth")
            #expect(piles[0].at.y < a.hearth.y, "tile \(tile): the wood pile in front of the fire")
            #expect(abs(huts[0].scale - huts[1].scale) > 0.05 && huts.allSatisfy { $0.scale > 0.9 && $0.scale < 1.2 })
            #expect(a.seed >= 0 && a.seed < 1)
            plans.insert(a.pieces.flatMap { [Int(($0.at.x * 40).rounded()), Int(($0.at.y * 40).rounded())] })
        }
        #expect(plans.count > tiles.count * 3 / 4, "only \(plans.count) plans in \(tiles.count) tiles")
    }

    /// Each marker draws its huts and wood pile (settlement pieces with no team paint, tinted
    /// white: no player colour), its trodden ground (the procedural one, with no lanes) and, in
    /// sight, one thin column of smoke; a remembered one takes the fogged look and has no smoke.
    /// None of it is a tap target, and it stands as a figure group of its own for the layering.
    @Test func eachMarkerDrawsItsHutsGroundAndSmoke() throws {
        let scene = try TribalVillageFixture.scene()
        let r = try Self.view(scene, on: scene.byCity, scale: 0.6)
        let shown = r.shownTribalVillages(bounds: nil)
        #expect(Dictionary(uniqueKeysWithValues: shown.map { ($0.hex, $0.fogged) })
                == [scene.hills: false, scene.byCity: false, scene.remembered: true])
        #expect(shown.allSatisfy { $0.opacity == 1 && $0.layout.pieces.count == 3 })
        let table = r.townAtlasTable()
        for village in shown {
            let fogged: Float = village.fogged ? 1 : 0
            let pieces = r.tribalVillagePieces(village, table: table, opacity: 1)
            #expect(pieces.count == 3 && pieces.allSatisfy {
                $0.flags == [1, MapRenderer.CitySpriteKind.piece.rawValue, fogged, 0] && $0.tint == [1, 1, 1, 1] && $0.uv != .zero
            })
            let ground = r.tribalVillageGround(village, opacity: 1)
            #expect(ground.flags == [0, MapRenderer.CitySpriteKind.ground.rawValue, fogged, 1])
            #expect(ground.sizeAnchor.x < 1.3 * r.cityUnit() && ground.uv.x > 0.4 && ground.uv.x < 0.6 && ground.uv.y > 0.4 && ground.uv.y < 0.5)
            let smoke = r.tribalVillageSmoke(village, opacity: 1)
            #expect(smoke.count == (village.fogged ? 0 : 1)
                    && smoke.allSatisfy { $0.flags.y == MapRenderer.CitySpriteKind.smoke.rawValue && $0.flags.z == 1 && $0.tint.w <= 0.5 })
        }

        // In the frame: per tribal village in view one ground, three pieces owned by nothing,
        // one figure group and (in sight) one column of smoke.
        let with = r.unitFrame()
        r.setTribalVillages([])
        let without = r.unitFrame()
        func count(_ f: UnitFrame, _ test: (SpriteInstance) -> Bool) -> Int { f.sprites.filter(test).count }
        let ground = MapRenderer.CitySpriteKind.ground.rawValue, piece = MapRenderer.CitySpriteKind.piece.rawValue
        let grounds = count(with) { $0.flags.y == ground && $0.flags.w == 1 }
        #expect(grounds >= 1 && count(without) { $0.flags.y == ground && $0.flags.w == 1 } == 0)
        let unowned = with.sprites.indices.filter { with.sprites[$0].flags.y == piece && with.owners[$0] == nil }
        #expect(unowned.count == 3 * grounds)
        #expect(count(with) { $0.flags.y == piece } == count(without) { $0.flags.y == piece } + 3 * grounds)
        #expect(with.figures.count == without.figures.count + grounds)
        let smoke = count(with) { $0.flags.y == MapRenderer.CitySpriteKind.smoke.rawValue && $0.flags.z == 1 }
        #expect(smoke >= 1 && smoke <= grounds)
        #expect(count(with) { $0.flags.y == MapRenderer.TribalVillageSpriteKind.token.rawValue } == 0)
    }

    /// Offscreen, at a close, a standard and a strategic zoom, seen and remembered: each draws on
    /// its own tile (huts or the token in the unit pass, the trodden clearing in its ground
    /// layer), and taking its marker away changes nothing further off.
    @Test func rendersOnItsTileAtEveryZoom() throws {
        let scene = try TribalVillageFixture.scene()
        let views: [(HexCoord, CGFloat)] = [(scene.hills, 0.45), (scene.byCity, 0.6), (scene.remembered, 0.6), (scene.hills, 1),
                                            (scene.byCity, 2.6), (scene.remembered, 2.6)]
        for (hex, scale) in views {
            let r = try Self.view(scene, on: hex, scale: scale)
            let strategic = scale > 2
            let tokens = r.unitFrame().sprites.filter { $0.flags.y == MapRenderer.TribalVillageSpriteKind.token.rawValue }
            #expect(tokens.isEmpty != strategic)
            let units = try UnitLayeringTests.coverage(r, .units), ground = try UnitLayeringTests.coverage(r, .unitGround)
            r.setTribalVillages(scene.markers.filter { $0.hex != hex })
            let unitsWithout = try UnitLayeringTests.coverage(r, .units), groundWithout = try UnitLayeringTests.coverage(r, .unitGround)
            let c = try #require(r.screenPoint(of: hex, lift: 0.3)), foot = try #require(r.screenPoint(of: hex))
            var drawn = 0, clearing = 0, away = 0
            for i in units.indices {
                let added = units[i] - unitsWithout[i], cleared = ground[i] - groundWithout[i]
                if added > 0.5, Self.distance(i, from: c, in: r) < 0.7 { drawn += 1 }
                if cleared > 0.1, Self.distance(i, from: foot, in: r) < 0.7 { clearing += 1 }
                if abs(added) > 0.02 || abs(cleared) > 0.02, Self.distance(i, from: c, in: r) > 2.5 { away += 1 }
            }
            print("tribal village at \(hex) scale \(scale): \(drawn) pixels drawn, \(clearing) cleared, \(away) away")
            // (Measured: 2825 drawn and 11030 cleared at 0.45, about 1800 and 6700 at 0.6, 790 and
            // 3050 at 1, and about 670 and 500 for the token and its faint clearing at 2.6.)
            let area = Float(scale * scale)
            #expect(Float(drawn) > (strategic ? 400 : 400 / area), "\(hex) at \(scale): \(drawn) pixels drawn")
            #expect(Float(clearing) > (strategic ? 300 : 1500 / area), "\(hex) at \(scale): \(clearing) pixels of clearing")
            #expect(away == 0, "\(hex) at \(scale): \(away) pixels changed away from it")
        }
    }

    /// Zoomed out each tribal village is an ivory token on its hex: its own cell of the unit
    /// atlas, white-tinted (never a player's colour), fogged when remembered, smaller than a
    /// unit's medallion.
    @Test func zoomedOutEachIsAnIvoryToken() throws {
        let scene = try TribalVillageFixture.scene()
        let r = try Self.view(scene, on: scene.capital, scale: 2.6)
        let uv = try #require(r.unitAtlasTable().tribalVillage)
        #expect(uv != .zero && uv == r.unitAtlas.uv(.tribalVillage))
        let frame = r.unitFrame()
        let tokens = frame.sprites.indices.filter { frame.sprites[$0].flags.y == MapRenderer.TribalVillageSpriteKind.token.rawValue }
        let shown = r.shownTribalVillages(bounds: nil)
        #expect(tokens.count == shown.count && tokens.allSatisfy { frame.owners[$0] == nil })
        for i in tokens {
            let token = frame.sprites[i]
            let village = try #require(shown.first { simd_distance($0.center, SIMD2(token.position.x, token.position.y)) < 1e-3 })
            #expect(token.uv == uv && token.tint == [1, 1, 1, 1] && token.flags.z == (village.fogged ? 1 : 0))
            #expect(token.sizeAnchor.x * UnitSprite.badgeDisc < r.medallionSize())
        }
        // No huts, smoke or full ground at this zoom: the clearing under a token is faint.
        let piece = MapRenderer.CitySpriteKind.piece.rawValue
        #expect(!frame.sprites.indices.contains { frame.sprites[$0].flags.y == piece && frame.owners[$0] == nil })
        #expect(!frame.sprites.contains { $0.flags.y == MapRenderer.CitySpriteKind.smoke.rawValue && $0.flags.z == 1 })
        #expect(frame.sprites.filter { $0.flags.y == MapRenderer.CitySpriteKind.ground.rawValue && $0.flags.w == 1 }.allSatisfy { $0.tint.w < 0.35 })
    }

    /// Remembered, a tribal village takes the explored fog's look, darker and greyer, and has no
    /// smoke; in sight a pale column of smoke rises from its hearth.
    @Test func rememberedOnesTakeTheFogLook() throws {
        let scene = try TribalVillageFixture.scene()
        let r = try Self.view(scene, [], on: scene.hills, scale: 0.45)
        let none = try UnitLayeringTests.pixels(r), noneUnits = try UnitLayeringTests.coverage(r, .units)
        r.setTribalVillages([TribalVillageMarker(hex: scene.hills, seen: true)])
        let seen = try UnitLayeringTests.pixels(r), seenUnits = try UnitLayeringTests.coverage(r, .units)
        let village = try #require(r.shownTribalVillages(bounds: nil).first)
        r.setTribalVillages([TribalVillageMarker(hex: scene.hills, seen: false)])
        let remembered = try UnitLayeringTests.pixels(r)
        // The huts: pixels the village covers fully.
        let c = try #require(r.screenPoint(of: scene.hills, lift: 0.3))
        let huts = seenUnits.indices.filter { seenUnits[$0] > 0.95 && noneUnits[$0] < 0.05 && Self.distance($0, from: c, in: r) < 0.7 }
        try #require(huts.count > 1000)
        let bright = huts.reduce(Float(0)) { $0 + Self.luminance(seen, $1) }, dim = huts.reduce(Float(0)) { $0 + Self.luminance(remembered, $1) }
        print("tribal village huts: \(huts.count) pixels, mean luminance seen \(bright / Float(huts.count)), remembered \(dim / Float(huts.count))")
        #expect(dim < 0.8 * bright)
        // The smoke, high over the hearth: there in sight, gone when remembered.
        let hearth = village.center + village.layout.hearth * r.cityUnit()
        let top = try #require(Self.viewPoint(r, hearth, lift: 0.95))
        func changed(_ a: [UInt8], _ b: [UInt8]) -> Int {
            (0..<(Self.width * Self.height)).filter { i in
                Self.distance(i, from: top, in: r) < 0.18 && (0..<3).contains { abs(Int(a[i * 4 + $0]) - Int(b[i * 4 + $0])) > 3 }
            }.count
        }
        let smoke = changed(seen, none), fogged = changed(remembered, none)
        print("tribal village smoke: \(smoke) pixels changed over the hearth seen, \(fogged) remembered")
        #expect(smoke > 200 && fogged < smoke / 10)
    }

    /// Nothing of a tribal village is a tap target: a tap on its huts, its wood pile or (zoomed
    /// out) its token picks the ground.
    @Test func tapsPickTheGround() throws {
        let scene = try TribalVillageFixture.scene()
        for scale in [0.6, 2.6] as [CGFloat] {
            let r = try Self.view(scene, on: scene.remembered, scale: scale)
            let units = try UnitLayeringTests.coverage(r, .units)
            let village = try #require(r.shownTribalVillages(bounds: nil).first { $0.hex == scene.remembered })
            // Low on each piece, and the hex centre (the token's middle).
            let unit = r.cityUnit()
            var points: [CGPoint] = []
            for piece in village.layout.pieces { points.append(try #require(Self.viewPoint(r, village.center + piece.at * unit, lift: 0.08))) }
            points.append(try #require(r.screenPoint(of: scene.remembered)))
            var covered = 0
            for p in points {
                if units[Int(p.y * 2) * Self.width + Int(p.x * 2)] > 0.5 { covered += 1 }
                let ground = try #require(r.hex(atViewPoint: p))
                #expect(r.hitTest(atViewPoint: p) == .ground(ground), "scale \(scale) at \(p)")
            }
            #expect(covered >= (scale > 2 ? 1 : 3), "only \(covered) taps on the tribal village at scale \(scale)")
        }
    }

    /// The two setters keep their own bits of the tile texture: a tribal village's (0x08) on
    /// the markers' tiles, a city centre's (0x80) on the cities', and the fog's untouched.
    @Test func theTwoSettersKeepTheirOwnBits() throws {
        let scene = try TribalVillageFixture.scene()
        let map = scene.state.map
        let r = MapRenderer(state: scene.state, viewer: Self.me)
        let cityCentre: UInt8 = 0x80 // `MapRenderer.cityCentre`
        func byte(_ hex: HexCoord) -> UInt8 { r.tileBytes[map.index(of: hex)! * 4 + 3] }
        func marked() -> Set<Int> { Set((0..<map.tileCount).filter { r.tileBytes[$0 * 4 + 3] & TileBits.tribalVillage != 0 }) }
        func fogLevels() -> [UInt8] { (0..<map.tileCount).map { (i: Int) -> UInt8 in r.tileBytes[i * 4 + 3] & 3 } }
        let fog = fogLevels()
        let tiles = Set(scene.markers.map { map.index(of: $0.hex)! })
        let version = r.tileVersion
        r.setTribalVillages(scene.markers)
        #expect(marked() == tiles && r.tileVersion > version)
        r.setCities(scene.cities + [CityMarker(id: 5, hex: scene.byCity, owner: Self.me, population: 1, capital: false, walls: false, hp: 1, wallHP: 1)])
        #expect(marked() == tiles && byte(scene.byCity) & cityCentre != 0 && byte(scene.capital) & cityCentre != 0)
        #expect(byte(scene.hills) & cityCentre == 0 && byte(scene.capital) & TileBits.tribalVillage == 0)
        r.setCities(scene.cities)
        #expect(byte(scene.byCity) & cityCentre == 0 && byte(scene.byCity) & TileBits.tribalVillage != 0)
        r.setTribalVillages([TribalVillageMarker(hex: scene.hills, seen: true)])
        #expect(marked() == [map.index(of: scene.hills)!] && byte(scene.capital) & cityCentre != 0)
        r.setTribalVillages([])
        #expect(marked().isEmpty && byte(scene.capital) & cityCentre != 0)
        #expect(fogLevels() == fog)
    }

    /// On its tile a tribal village hides the plants standing there and their cast shadows, and
    /// keeps the tile's relief and rocks (a city centre clears those too); nothing changes off the
    /// tile. Taken, its plants fade back in with the ghost, and once the fade is over the tile is
    /// exactly as it was.
    @Test func plantsHideAndReliefStays() throws {
        let scene = try TribalVillageFixture.scene()
        let map = scene.state.map
        let probe = MapRenderer(state: scene.state, viewer: Self.me)
        let decorations = MapRenderer.makeDecorations(map: map, layout: probe.layout, atlas: probe.decorAtlas)
        func bits(_ d: SpriteInstance) -> UInt32 { UInt32(d.flags.w) }
        // Hills near the capital with plants and relief of their own.
        let hex = try #require(map.coords(within: 6, of: scene.capital).filter { hex in
            guard let t = map.index(of: hex), map.tile(at: hex)?.elevation == .hills, scene.state.tileCity[t] == 0 else { return false }
            let own = decorations.filter { Int($0.position.w) == t && $0.flags.y > 0.5 }
            return own.filter { bits($0) & 3 != 0 }.count >= 3 && own.contains { bits($0) & DecorFlags.relief != 0 && bits($0) & DecorFlags.shadow == 0 }
        }.min { (map.distance($0, scene.capital), map.index(of: $0)!) < (map.distance($1, scene.capital), map.index(of: $1)!) })
        let marker = TribalVillageMarker(hex: hex, seen: true)

        let r = try Self.view(scene, [], on: hex, scale: 0.6, fog: false)
        let plain = try UnitLayeringTests.coverage(r, .decor)
        r.setTribalVillages([marker])
        let village = try UnitLayeringTests.coverage(r, .decor)
        r.setTribalVillages([])
        r.setCities(scene.cities + [CityMarker(id: 99, hex: hex, owner: Self.me, population: 1, capital: false, walls: false, hp: 1, wallHP: 1)])
        let city = try UnitLayeringTests.coverage(r, .decor)
        r.setCities(scene.cities)
        r.setTribalVillages([marker])
        r.apply(state: scene.state, events: [EventRecord(.tribalVillageTaken(at: hex, player: Self.me, unit: nil, city: nil), audience: EventRecord.everyone)])
        r.setTribalVillages([])
        r.advanceAnimations(by: Float(MapRenderer.tribalVillageFadeDuration / 2))
        let half = try UnitLayeringTests.coverage(r, .decor)
        r.advanceAnimations(by: 1)
        let after = try UnitLayeringTests.coverage(r, .decor)

        // The tile, with room for its trees reaching up the screen and their shadows falling to
        // the lower right.
        let c = try #require(r.screenPoint(of: hex))
        let tile = Self.tilePixels(r)
        func onTile(_ i: Int) -> Bool {
            let dx = Float(i % Self.width) - Float(c.x) * 2, dy = Float(i / Self.width) - Float(c.y) * 2
            return dx > -1.1 * tile && dx < 1.5 * tile && dy > -2.2 * tile && dy < 1.6 * tile
        }
        let region = plain.indices.filter(onTile)
        func sum(_ v: [Float]) -> Float { region.reduce(0) { $0 + v[$1] } }
        let gone = sum(plain) - sum(village), kept = sum(village) - sum(city), back = sum(half) - sum(village)
        let away = plain.indices.filter { !onTile($0) && (abs(plain[$0] - village[$0]) > 0.02 || abs(plain[$0] - half[$0]) > 0.02) }.count
        print("tribal village on \(hex): plants hidden \(gone), relief and rocks kept \(kept), half back \(back), \(away) changed away")
        #expect(gone > 800, "the plants hid only \(gone)")
        #expect(kept > 800, "the tribal village kept only \(kept) more than a city")
        #expect(back > 0.25 * gone && back < 0.75 * gone, "half way through the fade \(back) of \(gone) is back")
        #expect(away == 0)
        #expect(zip(after, plain).allSatisfy { abs($0 - $1) < 0.004 }, "the tile is not as it was once the fade is over")
    }

    /// A take: the ghost of the marker the renderer still holds (the App passes the new markers
    /// after `apply`) stays until the unit that took it reaches the tile, then fades out while
    /// the tile's plants come back, and `onEventShown` reports the take at the tile, once, as the
    /// fade starts. A city's claim fades at once, and so does a take with no marker there (found
    /// and taken in one command: the ghost is the tile as the viewer sees it). With
    /// `animatesEvents` off it is all over at once.
    @Test func aTakeFadesOutAsItsTakerArrives() throws {
        let scene = try TribalVillageFixture.scene()
        let map = scene.state.map
        let tile = try #require(map.index(of: scene.hills))
        var state = scene.state
        func isTake(_ record: EventRecord) -> Bool { if case .tribalVillageTaken = record.event { true } else { false } }
        var records = try GameEngine.apply(.moveUnit(unit: scene.scout, to: scene.hills), by: Self.me, to: &state)
        try #require(records.contains { if case .unitMoved = $0.event { true } else { false } })
        // The engine's move takes it itself (phase 3g H1: `tribalVillageTaken` after `unitMoved`,
        // then the gift's records). Without the core rules, stand in for that take.
        if !records.contains(where: isTake) {
            records.append(EventRecord(.tribalVillageTaken(at: scene.hills, player: Self.me, unit: scene.scout, city: nil), audience: 0b01))
        }
        let take = try #require(records.last(where: isTake))
        let after = scene.markers.filter { $0.hex != scene.hills }
        func opacity(_ r: MapRenderer) -> Float? { r.shownTribalVillages(bounds: nil).first { $0.hex == scene.hills }?.opacity }
        func hides(_ r: MapRenderer) -> Bool { r.tileBytes[tile * 4 + 3] & TileBits.tribalVillage != 0 }
        let half = Float(MapRenderer.tribalVillageFadeDuration / 2), arrival = Float(MapRenderer.stepDuration)

        let r = try Self.view(scene, on: scene.hills, scale: 0.45)
        var reported: [(EventRecord, CGPoint)] = []
        r.onEventShown = { record, point in if isTake(record) { reported.append((record, point)) } }
        r.apply(state: state, events: records)
        r.setTribalVillages(after)
        #expect(r.isAnimating && opacity(r) == 1 && hides(r))
        // The scout on its way: the tribal village stands, the plants still hidden.
        r.advanceAnimations(by: arrival / 2)
        #expect(opacity(r) == 1 && r.tribalVillageFadeSlot() == -1 && reported.isEmpty)
        // Half way through the fade.
        r.advanceAnimations(by: arrival / 2 + half)
        let ghost = try #require(opacity(r))
        let slot = r.tribalVillageFadeSlot()
        #expect(abs(ghost - 0.5) < 0.02 && Int(slot) == tile && abs(slot - Float(tile) - 0.5) < 0.02 && hides(r))
        let pieces = r.unitFrame().sprites.filter { $0.flags.y == MapRenderer.CitySpriteKind.piece.rawValue && abs($0.tint.w - 0.5) < 0.02 }
        #expect(pieces.count == 3)
        #expect(reported.count == 1 && reported.first?.0 == take)
        if let point = reported.first?.1, let expected = r.screenPoint(of: scene.hills, lift: MapRenderer.reportLift) {
            #expect(abs(point.x - expected.x) < 0.5 && abs(point.y - expected.y) < 0.5)
        }
        // Over: the ghost gone, the plants back for good.
        r.advanceAnimations(by: 1)
        #expect(opacity(r) == nil && !hides(r) && !r.isAnimating && r.tribalVillageFadeSlot() == -1 && reported.count == 1)

        // A city's claim, with no marker there: the ghost fades at once, seen as the tile is.
        let claim = try Self.view(scene, after, on: scene.hills, scale: 0.45)
        claim.apply(state: scene.state, events: [EventRecord(.tribalVillageTaken(at: scene.hills, player: Self.me, unit: nil, city: CityID(1)),
                                                             audience: 0b01)])
        #expect(opacity(claim) == 1 && hides(claim) && claim.shownTribalVillages(bounds: nil).first { $0.hex == scene.hills }?.fogged == false)
        claim.advanceAnimations(by: half)
        #expect(abs((opacity(claim) ?? 0) - 0.5) < 0.02)
        claim.advanceAnimations(by: 1)
        #expect(opacity(claim) == nil && !hides(claim) && !claim.isAnimating)

        // Events not animated: over at once.
        let instant = try Self.view(scene, on: scene.hills, scale: 0.45)
        instant.animatesEvents = false
        var count = 0
        instant.onEventShown = { record, _ in if isTake(record) { count += 1 } }
        instant.apply(state: state, events: records)
        #expect(count == 1 && !instant.isAnimating)
        instant.setTribalVillages(after)
        #expect(opacity(instant) == nil && !hides(instant))
    }

    /// Markers on tiles the viewer has not explored draw nothing and hide nothing, at a standard
    /// and a strategic zoom (as the other inputs: `inputsOnUnexploredTilesDoNotShow`), and a take
    /// there fades nothing.
    @Test func nothingShowsOnUnexploredTiles() throws {
        let scene = try TribalVillageFixture.scene()
        let map = scene.state.map
        let probe = MapRenderer(state: scene.state, viewer: Self.me)
        let unexplored = map.coords(within: 11, of: scene.capital).filter { hex in
            guard let tile = map.tile(at: hex) else { return false }
            return probe.fogLevel(hex) == 2 && tile.isLand && scene.state.rules.isPassable(tile)
        }.sorted { (map.distance($0, scene.capital), map.index(of: $0)!) < (map.distance($1, scene.capital), map.index(of: $1)!) }
        try #require(unexplored.count > 12)
        let hidden = unexplored.prefix(16).enumerated().map { TribalVillageMarker(hex: $1, seen: $0 % 2 == 0) }
        let site = hidden[0].hex
        for scale in [0.8, 2.6] as [CGFloat] {
            let a = try Self.view(scene, on: site, scale: scale)
            let b = try Self.view(scene, scene.markers + hidden, on: site, scale: scale)
            #expect(b.shownTribalVillages(bounds: nil).count == scene.markers.count)
            let pa = try UnitLayeringTests.pixels(a), pb = try UnitLayeringTests.pixels(b)
            let worst = zip(pa, pb).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst <= 6, "worst channel difference \(worst) at scale \(scale)")
        }
        let r = try Self.view(scene, scene.markers + hidden, on: site, scale: 0.8)
        r.apply(state: scene.state, events: [EventRecord(.tribalVillageTaken(at: site, player: PlayerID(1), unit: nil, city: nil),
                                                         audience: EventRecord.everyone)])
        #expect(r.animation.tribalVillageFades.isEmpty && r.shownTribalVillages(bounds: nil).count == scene.markers.count)
    }

    /// The token takes a free cell of the unit atlas: no atlas grows, no page is added.
    @Test func noAtlasGrows() throws {
        #expect(SpriteSheet<UnitSprite>.width == 2048 && SpriteSheet<UnitSprite>.height == 1536)
        #expect(SpriteSheet<SettlementSprite>.width == 2048 && SpriteSheet<SettlementSprite>.height == 512)
        let scene = try TribalVillageFixture.scene()
        let r = MapRenderer(state: scene.state, viewer: Self.me)
        #expect(r.unitAtlas.width == 2048 && r.unitAtlas.height == 1536 && r.townAtlas.width == 2048 && r.townAtlas.height == 512)
        #expect(r.unitAtlas.uv(.tribalVillage) != .zero)
    }
}

/// Renders of the tribal villages beside the gallery's (`TribalVillageGallery`): every zoom,
/// the fog, and a fade half run. Runs only with RENDER_OUT:
///
///     RENDER_OUT=/some/dir swift test --filter TribalVillageLooks
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_OUT"] != nil))
struct TribalVillageLooks {
    @Test func renderTheLooks() throws {
        let pad = PortraitGallery.iPad
        let scene = try TribalVillageFixture.scene()
        let views: [(String, HexCoord, CGFloat)] = [
            ("g20e-hills-standard", scene.hills, 1), ("g20f-by-city-standard", scene.byCity, 1),
            ("g20g-by-city-close", scene.byCity, 0.35), ("g20h-remembered-close", scene.remembered, 0.35),
            ("g20i-hills-closest", scene.hills, 0.3), ("g20j-capital-zoomed-out", scene.capital, 1.8),
        ]
        for (name, center, scale) in views {
            let r = TribalVillageFixture.view(scene, center: center, scale: scale, device: pad)
            MapRendererTests.save(try #require(PortraitGallery.render(r, on: pad)), name + ".png")
        }
        // A take half faded: the scout's tile's village, its plants half back.
        let r = TribalVillageFixture.view(scene, center: scene.hills, scale: 0.45, device: pad)
        let take = EventRecord(.tribalVillageTaken(at: scene.hills, player: TribalVillageFixture.me, unit: nil, city: nil), audience: 0b01)
        r.apply(state: scene.state, events: [take])
        r.setTribalVillages(scene.markers.filter { $0.hex != scene.hills })
        r.advanceAnimations(by: Float(MapRenderer.tribalVillageFadeDuration / 2))
        MapRendererTests.save(try #require(PortraitGallery.render(r, on: pad)), "g20k-hills-taken-half-faded.png")
        r.advanceAnimations(by: 10)
        MapRendererTests.save(try #require(PortraitGallery.render(r, on: pad)), "g20l-hills-taken.png")
    }

    /// Many layouts on every kind of land at once, the fog off: tribal villages on every third
    /// tile of passable land within six of the capital.
    @Test func renderTheVariety() throws {
        let pad = PortraitGallery.iPad
        let scene = try TribalVillageFixture.scene()
        let map = scene.state.map
        var markers: [TribalVillageMarker] = []
        for hex in map.coords(within: 6, of: scene.capital) {
            guard let t = map.index(of: hex), let tile = map.tile(at: hex), scene.state.rules.isPassable(tile), tile.isLand,
                  scene.state.tileCity[t] == 0, t % 3 == 0 else { continue }
            markers.append(TribalVillageMarker(hex: hex, seen: true))
        }
        for (name, scale) in [("g20m-variety", 0.6), ("g20n-variety-standard", 1.0)] as [(String, CGFloat)] {
            let r = TribalVillageFixture.view(scene, center: scene.capital, scale: scale, device: pad)
            r.fogEnabled = false
            r.setTribalVillages(markers)
            _ = PortraitGallery.render(r, on: pad)
            MapRendererTests.save(try #require(PortraitGallery.render(r, on: pad)), name + ".png")
        }
    }
}
