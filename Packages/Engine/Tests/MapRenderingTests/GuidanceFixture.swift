import CoreGraphics
import Foundation
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// The Builder and Settler guidance of the iPad play-test (Duel, seed 11), rebuilt on the same
/// map from its log: Rome at (16,9), Antium (11,12), Cumae (21,11) and Neapolis (15,6), the
/// Mongols' Karakorum (29,6), Avarga (34,6) and Shangdu (21,7), with the territory,
/// improvements, techs and units of the turns the play-test's screenshots show:
///
/// - `t08`: Mining just researched. Rome (population 1) holds its first Builder, selected:
///   four mine jobs on the hills round it, none this phase (each costs the Builder both its
///   moves), as in c-bg-compare.
/// - `t32`: Animal Husbandry just researched. Rome (population 3) has mines on (16,10), (15,9)
///   and (16,8), where Builder 15 stands, selected, as in c-pa-compare: four jobs, none this
///   phase.
/// - `t33`: the next turn, Builder 15 on the hill (16,7) it was sent to, with its moves: the
///   mine under it can start this phase, the other jobs cannot.
/// - `t39`: Antium's Settler at Antium, selected, with the settler overlay over the remembered
///   desert and coast west of it, as in t39-settler3-overlay.
/// - `t36`: a Settler whose march ended at (15,6) with no moves left, where it may found
///   Neapolis, next to a Builder that is spent.
///
/// The App's inputs are built the way `MapAdapter` and `GameSession.refreshSelection` build
/// them from the viewer's `PlayerView` (which the renderer's tests cannot import); what reaches
/// the renderer for the selected unit's guidance goes through `GuidanceOverlay`, so the base
/// engine's A/B copy can swap in what it took then.
@MainActor
enum GuidanceFixture {
    static let rome = HexCoord(q: 16, r: 9), antium = HexCoord(q: 11, r: 12), cumae = HexCoord(q: 21, r: 11)
    static let neapolis = HexCoord(q: 15, r: 6)
    static let karakorum = HexCoord(q: 29, r: 6), avarga = HexCoord(q: 34, r: 6), shangdu = HexCoord(q: 21, r: 7)
    /// How far round a Settler the App ranks sites (`MapAdapter.siteRadius`).
    static let siteRadius = 10

    struct Scene {
        var name: String
        var state: GameState
        /// The selected unit (nil: none) and where the camera looks.
        var selected: UnitID?
        var center: HexCoord
        // What the App passes: world inputs (`MapAdapter.syncWorld`), the selection's movement
        // range and guidance (`refreshSelection`), and the ready units.
        var cities: [CityMarker]
        var territory: [UInt8]
        var improvements: [UInt8]
        var range: [HexCoord]
        /// The settler overlay's scores (empty unless a Settler is selected).
        var siteScores: [UInt8]
        /// The selected Builder's jobs (empty unless a Builder is selected).
        var jobs: [BuilderJob]
        var ready: [UnitID]
    }

    // MARK: Scenes

    static func t08() throws -> Scene {
        var state = ArtGallery.world(.duel, seed: 11)
        try found([rome], mongol: [karakorum], in: &state)
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: rome)
        let units = try own(state)
        state = try SkirmishFixture.edit(state, [
            units.warrior: ["position": ["q": 13, "r": 12], "movesLeft": 0],
            units.scout: ["position": ["q": 22, "r": 6], "movesLeft": 0],
        ])
        state = try edit(state, techs: ["mining"], populations: [rome: 1], claims: [:], improvements: [:])
        state = try survey(state, explored: disc(state.map, rome, 6) + disc(state.map, HexCoord(q: 13, r: 12), 3)
                           + disc(state.map, HexCoord(q: 22, r: 6), 4))
        return inputs(state, name: "t08", selected: builder, center: rome)
    }

    static func t33() throws -> Scene { try t32(builderAt: HexCoord(q: 16, r: 7), name: "t33") }

    static func t32(builderAt spot: HexCoord = HexCoord(q: 16, r: 8), name: String = "t32") throws -> Scene {
        var state = ArtGallery.world(.duel, seed: 11)
        try found([rome, antium, cumae], mongol: [karakorum, avarga, shangdu], in: &state)
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: spot)
        let other = state.addUnit(.builder, owner: PlayerID(0), at: HexCoord(q: 19, r: 11))
        let units = try own(state)
        state = try SkirmishFixture.edit(state, [
            units.warrior: ["position": ["q": 21, "r": 11], "activity": "fortified"],
            units.scout: ["position": ["q": 26, "r": 9], "movesLeft": 0],
            other: ["movesLeft": 0, "destination": ["q": 16, "r": 9]],
        ])
        state = try edit(state, techs: ["mining", "pottery", "writing", "bronzeWorking", "animalHusbandry"],
                         populations: [rome: 3, antium: 2, cumae: 1], claims: [rome: [HexCoord(q: 16, r: 7)]],
                         improvements: [HexCoord(q: 16, r: 10): .mine, HexCoord(q: 15, r: 9): .mine, HexCoord(q: 16, r: 8): .mine,
                                        HexCoord(q: 11, r: 13): .mine])
        state = try survey(state, explored: reachable(state.map))
        return inputs(state, name: name, selected: builder, center: HexCoord(q: 16, r: 8))
    }

    static func t39() throws -> Scene {
        var state = try late(neapolis: true)
        let settler = state.addUnit(.settler, owner: PlayerID(0), at: antium)
        return inputs(state, name: "t39", selected: settler, center: antium)
    }

    static func t36() throws -> Scene {
        var state = try late(neapolis: false)
        let settler = state.addUnit(.settler, owner: PlayerID(0), at: neapolis)
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: HexCoord(q: 16, r: 7))
        state = try SkirmishFixture.edit(state, [settler: ["movesLeft": 0], builder: ["movesLeft": 0]])
        return inputs(state, name: "t36", selected: nil, center: neapolis)
    }

    /// Four cities of player 0 (Neapolis only with `neapolis`) and three Mongol ones, the land
    /// both empires reach explored, mines and pastures round the cities, and the units of the
    /// late 30s: a fortified Warrior in Cumae and in Neapolis, a Scout back home, a spent
    /// Builder by Neapolis.
    static func late(neapolis withNeapolis: Bool) throws -> GameState {
        var state = ArtGallery.world(.duel, seed: 11)
        try found([rome, antium, cumae] + (withNeapolis ? [neapolis] : []), mongol: [karakorum, avarga, shangdu], in: &state)
        let units = try own(state)
        var changes: [UnitID: [String: Any]] = [
            units.warrior: ["position": ["q": 21, "r": 11], "activity": "fortified"],
            units.scout: ["position": ["q": 20, "r": 10], "movesLeft": 0],
        ]
        if withNeapolis {
            let guardID = state.addUnit(.warrior, owner: PlayerID(0), at: neapolis)
            changes[guardID] = ["activity": "fortified"]
        }
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: HexCoord(q: 14, r: 7))
        changes[builder] = ["movesLeft": 0]
        state = try SkirmishFixture.edit(state, changes)
        var improvements: [HexCoord: Improvement] = [:]
        for (q, r) in [(16, 10), (15, 9), (16, 8), (16, 7), (11, 13), (11, 11), (15, 10)] { improvements[HexCoord(q: q, r: r)] = .mine }
        improvements[HexCoord(q: 12, r: 11)] = .pasture
        if withNeapolis {
            for (q, r) in [(15, 7), (14, 7)] { improvements[HexCoord(q: q, r: r)] = .pasture }
        }
        state = try edit(state, techs: ["mining", "pottery", "writing", "bronzeWorking", "animalHusbandry", "archery"],
                         populations: [rome: 3, antium: 3, cumae: 2, neapolis: 1], claims: [rome: [HexCoord(q: 16, r: 7)]],
                         improvements: improvements)
        return try survey(state, explored: reachable(state.map))
    }

    // MARK: Building the state

    /// The tiles within `radius` of `hex`.
    static func disc(_ map: HexMap, _ hex: HexCoord, _ radius: Int) -> [HexCoord] { map.coords(within: radius, of: hex) }

    /// What the play-test had explored by T25, "all land I can reach": the land joined to
    /// Rome's within 14 tiles of it (mountains included, which units see but cannot cross),
    /// and what lies within 2 of that land.
    static func reachable(_ map: HexMap) -> [HexCoord] {
        var land: Set<HexCoord> = [rome], frontier = [rome]
        while let hex = frontier.popLast() {
            for next in map.neighbors(of: hex) where !land.contains(next) && map.distance(next, rome) <= 14 && map[next].isLand {
                land.insert(next)
                frontier.append(next)
            }
        }
        var seen = Set<HexCoord>()
        for hex in land { seen.formUnion(map.coords(within: 2, of: hex)) }
        return seen.sorted { map.index(of: $0)! < map.index(of: $1)! }
    }

    /// Player 0's first Warrior and Scout.
    static func own(_ state: GameState) throws -> (warrior: UnitID, scout: UnitID) {
        let units = state.units(of: PlayerID(0))
        return (try #require(units.first { $0.type == .warrior }).id, try #require(units.first { $0.type == .scout }).id)
    }

    /// Founds the cities: player 0's in its phase (the first with its start Settler), then
    /// player 1's in theirs, and back to player 0's phase. Player 1's start Settler founds its
    /// first city where it stands, if that is the first given; otherwise it is disbanded.
    static func found(_ own: [HexCoord], mongol: [HexCoord], in state: inout GameState) throws {
        for (owner, sites) in [(PlayerID(0), own), (PlayerID(1), mongol)] {
            let start = try #require(state.units(of: owner).first { $0.type == .settler })
            for (i, site) in sites.enumerated() {
                let id = i == 0 && start.position == site ? start.id : state.addUnit(.settler, owner: owner, at: site)
                _ = try GameEngine.apply(.foundCity(unit: id), by: owner, to: &state)
            }
            if state.unit(start.id) != nil { _ = try GameEngine.apply(.disband(unit: start.id), by: owner, to: &state) }
            _ = try GameEngine.apply(.endTurn, by: owner, to: &state)
        }
    }

    /// The state through its JSON: player 0 knows `techs`, cities have the populations given
    /// (by tile), the cities given also own the unowned tiles given (their first ring is
    /// theirs from founding), and the improvements given stand.
    static func edit(_ state: GameState, techs: [String], populations: [HexCoord: Int], claims: [HexCoord: [HexCoord]],
                     improvements: [HexCoord: Improvement]) throws -> GameState {
        let map = state.map
        let data = try JSONEncoder().encode(state)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var players = try #require(json["players"] as? [[String: Any]])
        players[0]["knownTechs"] = techs
        json["players"] = players
        var cities = try #require(json["cities"] as? [[String: Any]])
        var tileCity = try #require(json["tileCity"] as? [Int])
        for k in cities.indices {
            let position = try #require(cities[k]["position"] as? [String: Int])
            let hex = HexCoord(q: try #require(position["q"]), r: try #require(position["r"]))
            if let population = populations[hex] { cities[k]["population"] = population }
            let code = try #require((cities[k]["id"] as? [String: Int])?["rawValue"]) + 1
            for t in claims[hex] ?? [] {
                let i = try #require(map.index(of: t))
                if tileCity[i] == 0 { tileCity[i] = code }
            }
        }
        json["cities"] = cities
        json["tileCity"] = tileCity
        var mapJSON = try #require(json["map"] as? [String: Any])
        var tiles = try #require(mapJSON["tiles"] as? [[String: Any]])
        for (hex, improvement) in improvements { tiles[try #require(map.index(of: hex))]["improvement"] = Int(improvement.rawValue) }
        mapJSON["tiles"] = tiles
        json["map"] = mapJSON
        var edited = try JSONDecoder().decode(GameState.self, from: JSONSerialization.data(withJSONObject: json))
        DebugTools.refreshAllKnowledge(in: &edited)
        return edited
    }

    /// Player 0 explores `explored` and remembers it as it is now: Scouts sent over all its land
    /// for one look (so memory holds its cities and met players), then gone again, and its
    /// owners and improvements as they are. Only the tiles given (and what the units and cities
    /// see) stay explored.
    static func survey(_ state: GameState, explored: [HexCoord]) throws -> GameState {
        var state = state
        let map = state.map
        var region = Set<Int>()
        for hex in explored { if let i = map.index(of: hex) { region.insert(i) } }
        var scouts: [UnitID] = [], posts: [HexCoord] = []
        for i in region.sorted() {
            let hex = map.coord(at: i)
            guard map[index: i].isLand, posts.allSatisfy({ map.distance($0, hex) > 2 }),
                  state.canEnd(.scout, owner: PlayerID(0), at: hex), state.units(at: hex).isEmpty else { continue }
            scouts.append(state.addUnit(.scout, owner: PlayerID(0), at: hex))
            posts.append(hex)
        }
        state = try SkirmishFixture.edit(state, [:], removing: Set(scouts))
        var bits = TileBitSet(count: map.tileCount)
        for i in region { bits[i] = true }
        state.players[0].explored = bits
        DebugTools.refreshAllKnowledge(in: &state)
        // Owners and improvements the edits made where player 0 already looked (memory follows
        // changes the engine makes, not edits).
        let data = try JSONEncoder().encode(state)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var players = try #require(json["players"] as? [[String: Any]])
        var memory = try #require(players[0]["memory"] as? [String: Any])
        var owners = try #require(memory["tileOwner"] as? [Int]), kinds = try #require(memory["tileImprovement"] as? [Int])
        for i in 0..<map.tileCount where state.players[0].explored[i] {
            owners[i] = state.tileOwner(i).map { $0.rawValue + 1 } ?? 0
            kinds[i] = Int(map[index: i].improvement?.rawValue ?? 0)
        }
        memory["tileOwner"] = owners
        memory["tileImprovement"] = kinds
        players[0]["memory"] = memory
        json["players"] = players
        return try JSONDecoder().decode(GameState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: The App's inputs

    /// What the App passes for the state with `selected` selected (`MapAdapter.syncWorld`,
    /// `GameSession.refreshSelection`, `MapAdapter.readyUnits`).
    static func inputs(_ state: GameState, name: String, selected: UnitID?, center: HexCoord) -> Scene {
        let view = state.view(for: PlayerID(0))
        let rules = state.rules
        let maxWall = max(rules.buildings.map(\.wallHP).max() ?? 100, 1), maxHP = max(rules.constants.city.maxHP, 1)
        let cities = view.knownCities.map { c in
            CityMarker(id: c.id.rawValue, hex: c.position, owner: c.owner, population: c.population, capital: c.capital, walls: c.walls,
                       hp: Float(c.hp) / Float(maxHP), wallHP: Float(c.wallHP) / Float(maxWall))
        }
        var range: [HexCoord] = [], scores: [UInt8] = [], jobs: [BuilderJob] = []
        if let id = selected, let unit = view.unit(id) {
            if unit.movesLeft > 0 { range = view.reachableTiles(for: id) }
            if rules.unit(unit.type).foundsCity {
                scores = settlerScores(view, around: unit.position)
            } else {
                jobs = view.builderJobs(for: id)
            }
        }
        let ready = view.units.filter { unit in
            rules.unit(unit.type).foundsCity && unit.destination == nil && unit.activity == .none && view.canFoundCity(at: unit.position)
        }.map(\.id)
        return Scene(name: name, state: state, selected: selected, center: center, cities: cities, territory: view.knownTerritory,
                     improvements: view.knownImprovements, range: range, siteScores: scores, jobs: jobs, ready: ready)
    }

    /// The settler overlay round a hex, as `MapAdapter.settlerScores` builds it.
    static func settlerScores(_ view: PlayerView, around center: HexCoord) -> [UInt8] {
        var scores = [UInt8](repeating: 0, count: view.tileCount)
        let ranking = view.siteRanking(around: center, radius: siteRadius)
        for site in ranking.sites { scores[site.tile] = overlayByte(shade: ranking.shade(of: site.score)) }
        return scores
    }

    /// A shade (1–7) as the overlay's byte (`MapAdapter.overlayByte`).
    static func overlayByte(shade: Int) -> UInt8 {
        UInt8(clamping: (min(max(shade, 1), 7) - 1) * 256 / 7 + 18)
    }

    // MARK: Views

    /// A renderer showing the scene from player 0's side on `device`, with the fog, every App
    /// input set and the camera on `center` (the scene's own by default) at `scale`.
    static func view(_ scene: Scene, center: HexCoord? = nil, scale: CGFloat, device: PortraitGallery.Device = PortraitGallery.iPad,
                     selection: Bool = true) -> MapRenderer {
        let r = MapRenderer(state: scene.state, viewer: PlayerID(0))
        r.animationTime = 100
        r.fogEnabled = true
        r.setViewportInsets(device.insets)
        r.setCities(scene.cities)
        r.setTerritory(scene.territory)
        r.setImprovements(scene.improvements)
        if selection, let id = scene.selected, let unit = scene.state.unit(id) {
            r.setSelection(unit.position, kind: .unit)
            r.setMovementRange(scene.range)
            GuidanceOverlay.apply(scene, to: r)
        } else {
            GuidanceOverlay.apply(Scene(name: scene.name, state: scene.state, selected: nil, center: scene.center, cities: [],
                                        territory: [], improvements: [], range: [], siteScores: [], jobs: [], ready: scene.ready), to: r)
        }
        _ = PortraitGallery.render(r, on: device)
        r.setCameraScale(scale)
        r.centerCamera(on: center ?? scene.center, animated: false)
        return r
    }
}

/// The play-test's guidance views (`g19…`), on an upright iPad (834×1210 points at 2x): the T8
/// Builder in Rome (close, standard zoom, unselected for reference, and the widest zoom), the
/// T32 Builder by Rome and (T33, close and at standard zoom) on the hill it was sent to, the
/// T39 settler overlay round Antium, and the T36 Settler ready to found Neapolis. Writes
/// `guidance.txt` with each scene's jobs, tiers and ready units. Runs only with RENDER_OUT (the
/// ArtGallery run renders them too):
///
///     RENDER_OUT=/some/dir swift test --filter GuidanceGallery
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_OUT"] != nil))
struct GuidanceGallery {
    static func render(timing: inout [String]) throws {
        let pad = PortraitGallery.iPad
        let t08 = try GuidanceFixture.t08(), t32 = try GuidanceFixture.t32(), t33 = try GuidanceFixture.t33()
        let t39 = try GuidanceFixture.t39(), t36 = try GuidanceFixture.t36()
        var facts: [String] = ["engine \(GuidanceOverlay.engine)"]
        for scene in [t08, t32, t33, t39, t36] {
            let jobs = scene.jobs.map { "\($0.hex) \($0.improvements.map { "\($0)" }.joined(separator: "+"))\($0.thisPhase ? " now" : "")" }
            var tiers = [Int](repeating: 0, count: 8)
            for byte in scene.siteScores where byte != 0 { tiers[1 + Int(byte) * 7 / 256] += 1 }
            facts.append("\(scene.name): selected \(scene.selected.map { "\($0.rawValue)" } ?? "none"), jobs [\(jobs.joined(separator: ", "))], "
                         + "site tiers 1-7 \(tiers[1...].map(String.init).joined(separator: "/")), ready \(scene.ready.map(\.rawValue))")
        }
        let views: [(String, GuidanceFixture.Scene, CGFloat, Bool)] = [
            ("g19-t08-builder", t08, 0.45, true), ("g19b-t08-builder-standard", t08, 1, true), ("g19c-t08-unselected", t08, 0.45, false),
            ("g19d-t08-builder-widest", t08, 1000, true),
            ("g19e-t32-builder", t32, 0.45, true), ("g19f-t32-builder-standard", t32, 1, true),
            ("g19j-t33-builder-on-hill", t33, 0.45, true), ("g19k-t33-builder-standard", t33, 1, true),
            ("g19g-t39-settler", t39, 1, true), ("g19h-t39-settler-close", t39, 0.6, true),
            ("g19i-t36-ready", t36, 0.45, false),
        ]
        var lines: [String] = []
        for (name, scene, scale, selection) in views {
            let renderer = GuidanceFixture.view(scene, scale: scale, device: pad, selection: selection)
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
        if let dir = ProcessInfo.processInfo.environment["RENDER_OUT"] {
            try (facts.joined(separator: "\n") + "\n").write(toFile: (dir as NSString).appendingPathComponent("guidance.txt"),
                                                            atomically: true, encoding: .utf8)
        }
    }

    @Test func guidanceGallery() throws {
        var lines: [String] = []
        try Self.render(timing: &lines)
        print(lines.joined(separator: "\n"))
    }
}
