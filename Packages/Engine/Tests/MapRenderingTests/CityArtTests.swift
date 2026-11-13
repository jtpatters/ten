import CoreGraphics
import Foundation
import Metal
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// Synthetic cities for the city art: every size tier, walls standing, damaged and breached,
/// capitals, burning cities and four owners, on a stretch of the Standard map (seed 7) with
/// forest, hills and coast. The renderer never reads cities from the game state; these markers
/// stand in for what the App passes in (`setCities`).
@MainActor
enum CityFixture {
    struct Spec {
        var population: Int
        var capital = false
        var walls = false
        var wallHP: Float = 1
        var hp: Float = 1
        var owner: Int
    }

    /// In site order, nearest the middle first.
    static let specs: [Spec] = [
        Spec(population: 8, capital: true, walls: true, owner: 0),
        Spec(population: 1, owner: 0),
        Spec(population: 4, walls: true, owner: 1),
        Spec(population: 7, walls: true, wallHP: 0, hp: 0.35, owner: 2),
        Spec(population: 2, hp: 0.8, owner: 1),
        Spec(population: 3, owner: 3),
        Spec(population: 6, capital: true, owner: 3),
        Spec(population: 5, walls: true, wallHP: 0.5, owner: 2),
        Spec(population: 2, walls: true, owner: 0),
    ]

    /// The Standard map (seed 7) with a few units standing in the cities (unless `garrisons` is
    /// false), the cities, and the middle of the stretch they stand on.
    static func scene(garrisons: Bool = true) throws -> (state: GameState, cities: [CityMarker], middle: HexCoord) {
        let generated = MapGenerator.generate(MapGenSettings(size: .standard, seed: 7))
        // The starts this scene was tuned on (MapGen's start scoring before p3b), so the cities
        // do not move when the scoring changes; the terrain is MapGen's.
        let tunedStarts: [HexCoord] = [.init(q: 17, r: 12), .init(q: 19, r: 34), .init(q: 4, r: 10), .init(q: 50, r: 18),
                                       .init(q: 34, r: 22), .init(q: 11, r: 27)]
        var state = GameState.newGame(seed: 7, map: generated.map, startPositions: tunedStarts)
        let map = state.map
        // Woods, hills and coast together, away from the starting units.
        let starts = state.units.map(\.position)
        let middle = ArtGallery.bestCenter(map) { t in
            (t.feature == .forest ? 2 : 0) + (t.elevation == .hills ? 2 : 0) + (t.terrain == .coast ? 1 : 0) + (t.isLand ? 1 : 0)
        }
        let sites = map.coords(within: 7, of: middle)
            .filter { hex in
                guard let t = map.tile(at: hex) else { return false }
                return t.isLand && t.elevation != .mountains && starts.allSatisfy { map.distance($0, hex) > 2 }
            }
            .sorted { (map.distance($0, middle), map.index(of: $0)!) < (map.distance($1, middle), map.index(of: $1)!) }
        var chosen: [HexCoord] = []
        for hex in sites where chosen.allSatisfy({ map.distance($0, hex) >= 3 }) {
            chosen.append(hex)
            if chosen.count == specs.count { break }
        }
        try #require(chosen.count == specs.count)
        let cities = zip(chosen, specs).enumerated().map { i, pair in
            let (hex, spec) = pair
            return CityMarker(id: 100 + i * 7, hex: hex, owner: PlayerID(spec.owner), population: spec.population, capital: spec.capital,
                              walls: spec.walls, hp: spec.hp, wallHP: spec.walls ? spec.wallHP : 0)
        }
        // Garrisons: units stand on the plaza in front of the hall.
        for (site, type) in [(0, UnitType.warrior), (2, .spearman), (3, .archer), (6, .builder)] where garrisons {
            _ = state.addUnit(type, owner: PlayerID(specs[site].owner), at: chosen[site])
        }
        return (state, cities, middle)
    }

    /// What each site stands on, for the log.
    static func describe(_ state: GameState, _ cities: [CityMarker]) -> String {
        cities.map { city in
            let t = state.map.tile(at: city.hex)!
            let water = HexDirection.allCases.contains { state.map.tile(at: city.hex.neighbor($0))?.isLand == false }
            let woods = HexDirection.allCases.filter { state.map.tile(at: city.hex.neighbor($0))?.feature == .forest }.count
            return "city \(city.id) pop \(city.population) at \(city.hex): \(t.terrain) \(t.elevation) \(t.feature)"
                + "\(water ? " coastal" : "") woods around \(woods)"
        }.joined(separator: "\n")
    }
}

/// The city views of the art gallery (g14), also on their own for working on the city art:
///
///     RENDER_OUT=/some/dir swift test --filter CityGallery
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_OUT"] != nil))
struct CityGallery {
    @Test func cities() throws {
        var timing: [String] = []
        try Self.render(timing: &timing)
        print(timing.joined(separator: "\n"))
    }

    /// Renders g14…: cities and their borders (every city owns the tiles within two of it,
    /// `SkirmishFixture.territory`) at standard zoom and close up (tilted), zoomed out to their
    /// tokens, top-down and in the fog, and the settlement atlas; GPU timings into `timing`.
    static func render(timing: inout [String]) throws {
        let (state, cities, middle) = try CityFixture.scene()
        print(CityFixture.describe(state, cities))
        let territory = SkirmishFixture.territory(state.map, cities)
        func view(_ center: HexCoord, scale: CGFloat, tilted: Bool = true, width: Int = ArtGallery.width,
                  height: Int = ArtGallery.height) -> MapRenderer {
            let r = MapRenderer(state: state, viewer: PlayerID(0))
            r.fogEnabled = false
            r.tilted = tilted
            r.setCities(cities)
            r.setTerritory(territory)
            _ = r.renderImage(width: width, height: height) // zoom is clamped for the view size
            r.setCameraScale(scale)
            r.centerCamera(on: center, animated: false)
            return r
        }
        func time(_ name: String, _ r: MapRenderer) {
            timing.append(String(format: "%@ gpu %.2f ms", name, ArtGallery.medianGPU(r)))
        }

        let standard = view(middle, scale: 1)
        _ = try ArtGallery.render(standard, "g14-cities.png")
        time("g14-cities", standard)

        // Close up on the walled capital with its garrison, selected.
        let close = view(cities[0].hex, scale: 0.45)
        close.setSelection(cities[0].hex, kind: .city)
        _ = try ArtGallery.render(close, "g14b-cities-close.png")
        time("g14b-cities-close", close)
        // The burning city with its walls breached, and the village.
        _ = try ArtGallery.render(view(cities[3].hex, scale: 0.45), "g14c-cities-close-burning.png")
        _ = try ArtGallery.render(view(cities[1].hex, scale: 0.45), "g14d-cities-close-village.png")

        let strategic = view(middle, scale: 2.6)
        _ = try ArtGallery.render(strategic, "g14e-cities-strategic.png")
        _ = try ArtGallery.render(view(middle, scale: 1, tilted: false), "g14f-cities-topdown.png")

        // In the fog: player 0 has explored the middle of the stretch but sees only around its
        // capital; cities beyond are drawn as last seen, dimmed, and none on unexplored tiles.
        var fogged = state
        for hex in fogged.map.coords(within: 5, of: middle) { fogged.players[0].explored[fogged.map.index(of: hex)!] = true }
        let fog = MapRenderer(state: fogged, viewer: PlayerID(0))
        fog.setCities(cities)
        fog.setTerritory(territory)
        _ = fog.renderImage(width: ArtGallery.width, height: ArtGallery.height)
        fog.setCameraScale(1.3)
        fog.centerCamera(on: middle, animated: false)
        _ = try ArtGallery.render(fog, "g14g-cities-fog.png")

        if let image = standard.townAtlas.makeImage() { MapRendererTests.save(image, "atlas-settlements.png") }
    }
}

/// Cities (M1 §15): settlements drawn from the markers the App passes in, picked by taps
/// (units standing in them win), with decorations cleared from their centres and nothing shown
/// on tiles the viewer has not explored.
@MainActor
@Suite struct CityArtTests {
    static let width = UnitLayeringTests.width, height = UnitLayeringTests.height

    /// A renderer showing `cities`, zoomed to `scale` on `hex` (rendered once first: zoom is
    /// clamped for the view size).
    static func view(_ state: GameState, _ cities: [CityMarker], on hex: HexCoord, scale: CGFloat, fog: Bool = false) throws -> MapRenderer {
        let r = MapRenderer(state: state, viewer: PlayerID(0))
        r.fogEnabled = fog
        r.animationTime = 5
        r.setCities(cities)
        _ = try #require(r.renderImage(width: width, height: height))
        r.setCameraScale(scale)
        r.centerCamera(on: hex, animated: false)
        _ = try #require(r.renderImage(width: width, height: height))
        return r
    }

    /// Pixels at least half covered within `radius` tile sizes (on screen) of a hex's center
    /// raised `lift` tile sizes.
    static func covered(_ coverage: [Float], around hex: HexCoord, in r: MapRenderer, radius: Float, lift: Float = 0.3) throws -> Int {
        let c = try #require(r.screenPoint(of: hex, lift: lift))
        let pixels = 2 * radius * Float(r.layout.size) / Float(r.camera.scale) // 2 pixels per point
        var count = 0
        for y in 0..<height {
            for x in 0..<width where coverage[y * width + x] > 0.5 {
                let dx = Float(x) - Float(c.x) * 2, dy = Float(y) - Float(c.y) * 2
                if dx * dx + dy * dy < pixels * pixels { count += 1 }
            }
        }
        return count
    }

    @Test func citiesDrawOnTheirTiles() throws {
        let (state, cities, _) = try CityFixture.scene()
        let village = cities[1] // no units in it
        let r = try Self.view(state, cities, on: village.hex, scale: 0.6)
        let units = try UnitLayeringTests.coverage(r, .units)
        let ground = try UnitLayeringTests.coverage(r, .unitGround)
        #expect(try Self.covered(units, around: village.hex, in: r, radius: 0.8) > 3000)
        #expect(try Self.covered(ground, around: village.hex, in: r, radius: 0.6, lift: 0) > 3000)
        r.setCities([])
        #expect(try Self.covered(UnitLayeringTests.coverage(r, .units), around: village.hex, in: r, radius: 0.8) == 0)
        #expect(try Self.covered(UnitLayeringTests.coverage(r, .unitGround), around: village.hex, in: r, radius: 0.6, lift: 0) == 0)
    }

    @Test func tapsPickCitiesAndTheUnitsInThem() throws {
        let (state, cities, _) = try CityFixture.scene()
        let village = cities[1], capital = cities[0]
        let r = try Self.view(state, cities, on: village.hex, scale: 0.6)
        // The hall at the back of the village, and the ground two tiles away.
        let hall = try #require(r.screenPoint(of: village.hex, lift: 0.55))
        #expect(r.hitTest(atViewPoint: hall) == .city(id: village.id, village.hex))
        #expect(r.hex(atViewPoint: hall) == village.hex)
        let away = try #require(state.map.normalize(HexCoord(q: village.hex.q, r: village.hex.r + 2)))
        if let p = r.screenPoint(of: away), cities.allSatisfy({ state.map.distance($0.hex, away) > 1 }), state.units(at: away).isEmpty {
            #expect(r.hitTest(atViewPoint: p) == .ground(away))
        }
        // A unit standing in a city is drawn over it and wins the tap.
        r.centerCamera(on: capital.hex, animated: false)
        _ = try #require(r.renderImage(width: Self.width, height: Self.height))
        let garrison = try #require(state.units(at: capital.hex).first)
        let figure = try #require(r.screenPoint(ofUnit: garrison.id, lift: 0.3))
        #expect(r.hitTest(atViewPoint: figure) == .unit(capital.hex))
        // Zoomed out, the city's token: its top stands clear of a garrison's medallion.
        r.setCameraScale(2.6)
        r.centerCamera(on: village.hex, animated: false)
        _ = try #require(r.renderImage(width: Self.width, height: Self.height))
        let token = r.medallionSize() * MapRenderer.cityTokenSize
        let top = try #require(r.screenPoint(of: village.hex, lift: token * (MapRenderer.cityTokenLift + 0.25) / Float(r.layout.size)))
        #expect(r.hitTest(atViewPoint: top) == .city(id: village.id, village.hex))
    }

    @Test func bannersHangAboveTheCity() throws {
        let (state, cities, _) = try CityFixture.scene()
        let village = cities[1]
        let r = try Self.view(state, cities, on: village.hex, scale: 0.6)
        let anchor = try #require(r.bannerAnchor(city: village.id))
        let center = try #require(r.screenPoint(of: village.hex))
        let tile = CGFloat(r.layout.size) / CGFloat(r.camera.scale)
        #expect(anchor.y < center.y - 0.4 * tile && anchor.y > center.y - 1.6 * tile && abs(anchor.x - center.x) < 0.5 * tile)
        #expect(r.bannerAnchor(city: 12345) == nil)
    }

    /// Plants standing in front of a city's wall ring are drawn over it, as over a figure's legs,
    /// and redrawing them changes nothing but city pixels. (Few do: decorations reaching into a
    /// city's tile hide, which leaves a clearing around its walls.)
    @Test func plantsInFrontCoverCityWalls() throws {
        var (state, cities, _) = try CityFixture.scene(garrisons: false)
        let city = cities[2] // walled
        // Woods around it, so trees stand right in front of its walls.
        for direction in [HexDirection.southWest, .southEast, .west, .east] {
            let hex = try #require(state.map.normalize(city.hex.neighbor(direction)))
            var tile = state.map[hex]
            tile.terrain = .grassland
            tile.elevation = .flat
            tile.feature = .forest
            state.map[hex] = tile
        }
        let r = try Self.view(state, [city], on: city.hex, scale: 0.6)
        let units = try UnitLayeringTests.coverage(r, .units)
        let lifted = try UnitLayeringTests.pixels(r)
        r.liftDecorations = false
        let flat = try UnitLayeringTests.pixels(r)
        var inside = 0, outside = 0
        for i in 0..<(Self.width * Self.height) {
            let d = (0..<3).map { abs(Int(lifted[i * 4 + $0]) - Int(flat[i * 4 + $0])) }.max()!
            guard d > 1 else { continue }
            if units[i] > 0.001 { inside += 1 } else { outside += 1 }
        }
        #expect(outside == 0, "\(outside) pixels changed away from the city")
        #expect(inside > 10, "trees in front changed only \(inside) city pixels")
    }

    /// Trees and other plants hide on a city's centre tile (relief stays); nothing changes
    /// away from it.
    /// A city centre clears its tile of decorations: the woods of a forest city, and the mounds
    /// of a hill city (which would otherwise stand over its buildings), with their shadows.
    @Test func decorationsHideOnCityCentres() throws {
        let (state, cities, _) = try CityFixture.scene()
        #expect(state.map.tile(at: cities[0].hex)?.feature == .forest)
        #expect(state.map.tile(at: cities[4].hex)?.elevation == .hills && state.map.tile(at: cities[4].hex)?.feature == Feature.none)
        for city in [cities[0], cities[4]] {
            let r = try Self.view(state, [city], on: city.hex, scale: 0.6)
            let with = try UnitLayeringTests.coverage(r, .decor)
            r.setCities([])
            let without = try UnitLayeringTests.coverage(r, .decor)
            let c = try #require(r.screenPoint(of: city.hex))
            let tile = 2 * Float(r.layout.size) / Float(r.camera.scale) // pixels
            var cleared = 0, far = 0
            for y in 0..<Self.height {
                for x in 0..<Self.width {
                    let i = y * Self.width + x
                    guard abs(with[i] - without[i]) > 0.1 else { continue }
                    let dx = Float(x) - Float(c.x) * 2, dy = Float(y) - Float(c.y) * 2
                    // Trees on the tile reach up the screen past its top edge, and their shadows
                    // fall to the lower right.
                    if dx > -1.1 * tile, dx < 1.5 * tile, dy > -2.2 * tile, dy < 1.6 * tile { cleared += 1 } else { far += 1 }
                }
            }
            // (The hill city clears about 6,900 pixels; keeping its mounds, it cleared about 800.)
            #expect(cleared > 3000, "only \(cleared) pixels of decorations cleared around city \(city.id)")
            #expect(far == 0, "\(far) pixels changed away from the tile of city \(city.id)")
        }
    }

    /// A neighbour's relief reaching onto a city centre stays: mountains beside a city keep
    /// their peaks (only the city's own tile is cleared).
    @Test func neighbouringPeaksStayBesideCities() throws {
        let (state, cities, _) = try CityFixture.scene()
        var peaks = 0
        for city in cities {
            let mountains = state.map.neighbors(of: city.hex).filter { state.map.tile(at: $0)?.elevation == .mountains }
            guard !mountains.isEmpty else { continue }
            let r = try Self.view(state, [city], on: city.hex, scale: 0.6)
            let with = try UnitLayeringTests.coverage(r, .decor)
            r.setCities([])
            let without = try UnitLayeringTests.coverage(r, .decor)
            let radius = 0.25 * 2 * Float(r.layout.size) / Float(r.camera.scale) // pixels
            for hex in mountains {
                // The body of the neighbour's peaks, well clear of the city's own mounds and trees.
                guard let p = r.screenPoint(of: hex, lift: 0.6) else { continue }
                var changed = 0, inside = 0
                for y in 0..<Self.height {
                    for x in 0..<Self.width {
                        let dx = Float(x) - Float(p.x) * 2, dy = Float(y) - Float(p.y) * 2
                        guard dx * dx + dy * dy < radius * radius else { continue }
                        inside += 1
                        let i = y * Self.width + x
                        if abs(with[i] - without[i]) > 0.1 { changed += 1 }
                    }
                }
                guard inside > 100 else { continue }
                peaks += 1
                #expect(changed == 0, "\(changed) pixels of the mountains at \(hex) beside city \(city.id) changed")
            }
        }
        #expect(peaks > 0)
    }

    /// Cities are drawn only on tiles the viewer has explored; out of sight, as last seen.
    @Test func unexploredCitiesStayHidden() throws {
        var (state, cities, _) = try CityFixture.scene()
        // The city farthest from the viewer's units, so it is out of their sight.
        let own = state.units(of: PlayerID(0)).map(\.position)
        let city = try #require(cities.max { a, b in
            own.map { state.map.distance($0, a.hex) }.min()! < own.map { state.map.distance($0, b.hex) }.min()!
        })
        let tile = try #require(state.map.index(of: city.hex))
        state.players[0].explored[tile] = false
        let hidden = try Self.view(state, [city], on: city.hex, scale: 0.6, fog: true)
        try #require(hidden.fogLevel(city.hex) == 2)
        #expect(try Self.covered(UnitLayeringTests.coverage(hidden, .units), around: city.hex, in: hidden, radius: 0.8) == 0)
        let hall = try #require(hidden.screenPoint(of: city.hex, lift: 0.55))
        if case .city = hidden.hitTest(atViewPoint: hall) { Issue.record("an unexplored city was picked") }

        for hex in state.map.coords(within: 1, of: city.hex) { state.players[0].explored[state.map.index(of: hex)!] = true }
        let remembered = try Self.view(state, [city], on: city.hex, scale: 0.6, fog: true)
        try #require(remembered.fogLevel(city.hex) == 1)
        #expect(try Self.covered(UnitLayeringTests.coverage(remembered, .units), around: city.hex, in: remembered, radius: 0.8) > 3000)
        #expect(remembered.hitTest(atViewPoint: hall) == .city(id: city.id, city.hex))
    }

    /// Size tiers, capital keep, walls standing or breached, and seeded variety.
    @Test func settlementsFollowTheirMarkers() {
        let base = CityMarker(id: 5, hex: HexCoord(q: 3, r: 4), owner: PlayerID(1), population: 1, capital: false, walls: false, hp: 1, wallHP: 0)
        func pieces(_ change: (inout CityMarker) -> Void) -> [SettlementPiece] {
            var m = base
            change(&m)
            return MapRenderer.buildLayout(m).pieces.map(\.piece)
        }
        let counts = [1, 2, 3, 5, 6, 12].map { p in pieces { $0.population = p }.count }
        #expect(counts[0] == counts[1] && counts[1] < counts[2] && counts[2] == counts[3] && counts[3] < counts[4] && counts[4] == counts[5])
        #expect(pieces { _ in }.contains(.hall) && !pieces { _ in }.contains(.keep))
        #expect(pieces { $0.capital = true }.contains(.keep) && !pieces { $0.capital = true }.contains(.hall))
        let walls: [SettlementPiece] = [.wallBackLeft, .wallBackRight, .wallFrontLeft, .wallFrontRight, .wallBreach, .tower, .gatehouse]
        #expect(!pieces { _ in }.contains(where: walls.contains))
        let standing = pieces { $0.walls = true; $0.wallHP = 0.3 }
        #expect(standing.contains(.wallFrontLeft) && !standing.contains(.wallBreach) && standing.contains(.gatehouse))
        let breached = pieces { $0.walls = true; $0.wallHP = 0 }
        #expect(breached.contains(.wallBreach) && !breached.contains(.wallFrontLeft))
        // The same city always looks the same; different cities differ.
        let look = { (id: Int) -> [Float] in
            var m = base
            m.id = id
            m.population = 4
            return MapRenderer.buildLayout(m).pieces.flatMap { [Float($0.piece.rawValue), $0.at.x, $0.at.y] }
        }
        #expect(look(9) == look(9))
        #expect(Set((0..<12).map(look)).count == 12)
    }

    /// The trodden ground under a settlement: earth with lanes, its square and main lane paved
    /// inside walls, mirrored with the plan (its lanes lead to the houses).
    @Test func settlementGroundFollowsThePlan() throws {
        let (state, cities, _) = try CityFixture.scene()
        let r = try Self.view(state, cities, on: cities[1].hex, scale: 0.6)
        let table = r.townAtlasTable()
        #expect(table.ground != table.pavedGround && table.ground.z > 0 && table.pavedGround.z > 0)
        var mirrored = Set<Bool>()
        for (id, walls) in (0..<12).flatMap({ id in [false, true].map { (id, $0) } }) {
            let m = CityMarker(id: id, hex: cities[1].hex, owner: PlayerID(1), population: 1, capital: false, walls: walls, hp: 1,
                               wallHP: 1)
            let layout = r.cityLayout(m)
            let ground = r.cityGround(ShownCity(marker: m, center: .zero, fogged: false, layout: layout), table: table, opacity: 1)
            #expect(ground.uv == (walls ? table.pavedGround : table.ground))
            #expect((ground.sizeAnchor.x < 0) == layout.mirrored)
            // The village's well stands east of the hall, or west in a mirrored plan.
            let well = try #require(layout.pieces.first { $0.piece == .well })
            #expect((well.at.x < 0) == layout.mirrored)
            mirrored.insert(layout.mirrored)
        }
        #expect(mirrored.count == 2)
    }

    /// Smoke rises over a damaged city: a column per third of its hit points lost, none when
    /// it is out of sight (its damage then is as last seen, and a still picture).
    @Test func damagedCitiesSmoke() throws {
        let (state, cities, _) = try CityFixture.scene()
        let r = try Self.view(state, cities, on: cities[1].hex, scale: 0.6)
        func columns(_ hp: Float, fogged: Bool = false) -> Int {
            var m = cities[1]
            m.hp = hp
            return r.citySmoke(ShownCity(marker: m, center: .zero, fogged: fogged, layout: r.cityLayout(m)), opacity: 1).count
        }
        #expect(columns(1) == 0 && columns(0.9) == 1 && columns(0.5) == 2 && columns(0.1) == 3 && columns(0) == 3)
        #expect(columns(0.2, fogged: true) == 0)
    }

    /// Atlas sizes (M1 §15) and the texture budget on a Large map (ART.md §10: 48 MB target,
    /// 50 MB cap).
    @Test func atlasesAndTexturesFitTheirBudgets() throws {
        #expect(SpriteSheet<UnitSprite>.width <= 2048 && SpriteSheet<UnitSprite>.height <= 1536)
        #expect(SpriteSheet<SettlementSprite>.width <= 2048 && SpriteSheet<SettlementSprite>.height <= 512)
        let generated = MapGenerator.generate(MapGenSettings(size: .large, seed: 3))
        let state = GameState.newGame(seed: 3, map: generated.map, startPositions: generated.startPositions)
        let r = MapRenderer(state: state, viewer: PlayerID(0))
        _ = try #require(r.renderImage(width: 800, height: 600))
        let megabytes = Double(r.textureMemoryBytes) / 1_048_576
        print(String(format: "Large map textures: %.1f MB", megabytes))
        #expect(megabytes <= 50)
    }
}
