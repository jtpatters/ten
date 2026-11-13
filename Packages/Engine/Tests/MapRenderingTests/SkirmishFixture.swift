import CoreGraphics
import Foundation
import Testing
import GameCore
import MapGen
@testable import MapRendering

/// A skirmish on the city fixture's stretch of the Standard map (seed 7): every city owns the
/// tiles within two of it (the nearest city wins), farms, pastures and mines around them, and
/// between the walled capital (player 0) and the nearest city of player 1 all six unit types
/// face each other: some hurt, two fortified, one with no moves left, and a selected warrior
/// with its movement range and attack targets. Like the city markers, territory and
/// improvements stand in for what the App passes in.
@MainActor
enum SkirmishFixture {
    struct Scene {
        var state: GameState
        var cities: [CityMarker]
        var territory: [UInt8]
        var improvements: [UInt8]
        /// The tile between the two sides.
        var front: HexCoord
        var capital: CityMarker
        var selected: GameCore.Unit
        var range: [HexCoord]
        var targets: [HexCoord]
        /// The units placed for the skirmish, own first.
        var units: [UnitID]
    }

    /// Territory: tiles within `radius` of a city belong to the nearest one (ties: the first).
    static func territory(_ map: HexMap, _ cities: [CityMarker], radius: Int = 2) -> [UInt8] {
        var owners = [UInt8](repeating: 0, count: map.tileCount)
        for i in 0..<map.tileCount {
            let hex = map.coord(at: i)
            let nearest = cities.enumerated().min { a, b in
                (map.distance(a.element.hex, hex), a.offset) < (map.distance(b.element.hex, hex), b.offset)
            }
            if let city = nearest?.element, map.distance(city.hex, hex) <= radius { owners[i] = UInt8(city.owner.rawValue + 1) }
        }
        return owners
    }

    /// Improvements on owned land around the cities, as builders would make them: farms and
    /// pastures on open flat land, mines on bare hills (M1's terrain rules), never on a city.
    static func improvements(_ map: HexMap, _ cities: [CityMarker], territory: [UInt8]) -> [UInt8] {
        let centres = Set(cities.compactMap { map.index(of: $0.hex) })
        var kinds = [UInt8](repeating: 0, count: map.tileCount)
        for i in 0..<map.tileCount where territory[i] != 0 && !centres.contains(i) {
            let t = map[index: i]
            guard t.isLand, t.feature != .forest, t.feature != .jungle, t.feature != .marsh else { continue }
            let roll = Float((i &* 2_654_435_761) % 1000) / 1000
            if t.elevation == .hills, t.terrain != .snow {
                if roll < 0.7 { kinds[i] = Improvement.mine.rawValue }
            } else if t.elevation == .flat, [.grassland, .plains, .tundra].contains(t.terrain) || t.feature == .floodplain {
                if roll < 0.5 {
                    kinds[i] = Improvement.farm.rawValue
                } else if roll < 0.75, t.terrain != .desert {
                    kinds[i] = Improvement.pasture.rawValue
                }
            }
        }
        return kinds
    }

    /// The state with some units' fields changed (`hp`, `activity`, `movesLeft`, `destination`,
    /// `position` ...) and some units removed, through its JSON: the renderer's tests may not
    /// mutate units directly.
    static func edit(_ state: GameState, _ changes: [UnitID: [String: Any]], removing: Set<UnitID> = []) throws -> GameState {
        let data = try JSONEncoder().encode(state)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var units = try #require(json["units"] as? [[String: Any]])
        func id(_ unit: [String: Any]) -> UnitID? { ((unit["id"] as? [String: Any])?["rawValue"] as? Int).map { UnitID($0) } }
        units.removeAll { id($0).map(removing.contains) ?? false }
        for k in units.indices {
            guard let id = id(units[k]), let change = changes[id] else { continue }
            for (key, value) in change { units[k][key] = value }
        }
        json["units"] = units
        return try JSONDecoder().decode(GameState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Hexes on the straight line from `a` to `b` (cube rounding), `a` and `b` included.
    static func line(_ map: HexMap, from a: HexCoord, to b: HexCoord) -> [HexCoord] {
        let n = max(map.distance(a, b), 1)
        return (0...n).compactMap { k in
            let t = Double(k) / Double(n)
            let q = Double(a.q) + Double(b.q - a.q) * t, r = Double(a.r) + Double(b.r - a.r) * t, s = -q - r
            var rq = q.rounded(), rr = r.rounded()
            let rs = s.rounded()
            if abs(rq - q) > abs(rr - r), abs(rq - q) > abs(rs - s) { rq = -rr - rs } else if abs(rr - r) > abs(rs - s) { rr = -rq - rs }
            return map.normalize(HexCoord(q: Int(rq), r: Int(rr)))
        }
    }

    /// The free tile nearest `anchor` (ties: lowest index) where `type` may stand, off the
    /// cities.
    static func spot(_ state: GameState, _ type: UnitType, _ owner: Int, near anchor: HexCoord, avoiding cityTiles: Set<HexCoord>) -> HexCoord? {
        let map = state.map
        var best: (distance: Int, index: Int, hex: HexCoord)?
        for hex in map.coords(within: 4, of: anchor) {
            guard !cityTiles.contains(hex), state.units(at: hex).isEmpty, state.canEnd(type, owner: PlayerID(owner), at: hex),
                  let index = map.index(of: hex) else { continue }
            let distance = map.distance(hex, anchor)
            if let b = best, (b.distance, b.index) <= (distance, index) { continue }
            best = (distance, index, hex)
        }
        return best?.hex
    }

    static func scene() throws -> Scene {
        // (No nested function or closure here captures the mutable state: the release build's
        // data-race checks reject that.)
        let base = try CityFixture.scene(garrisons: false)
        var state = base.state
        let cities = base.cities
        let map = state.map
        let capital = cities[0]
        let rival = try #require(cities.filter { $0.owner == PlayerID(1) }.min { map.distance($0.hex, capital.hex) < map.distance($1.hex, capital.hex) })
        let path = line(map, from: capital.hex, to: rival.hex)
        let front = path[path.count / 2]
        let territory = territory(map, cities)
        let improvements = improvements(map, cities, territory: territory)
        let cityTiles = Set(cities.map(\.hex))
        let ownSide = path[max(path.count / 2 - 1, 0)], enemySide = path[min(path.count / 2 + 1, path.count - 1)]
        let farm = map.coords(within: 3, of: capital.hex).first { map.index(of: $0).map { improvements[$0] == Improvement.farm.rawValue } ?? false }

        // Own side: the selected warrior at the front, an archer and a fortified spearman beside
        // it, a scout, a settler and a builder with no moves left on a farm behind them. The
        // other side: a fortified spearman and a badly hurt archer (and a hurt warrior next to
        // ours, below).
        let roster: [(UnitType, Int, HexCoord, [String: Any])] = [
            (.warrior, 0, ownSide, [:]),
            (.archer, 0, ownSide, ["hp": 60]),
            (.spearman, 0, ownSide, ["activity": "fortified"]),
            (.scout, 0, ownSide, ["hp": 70, "movesLeft": 0]),
            (.settler, 0, capital.hex, [:]),
            (.builder, 0, farm ?? capital.hex, ["movesLeft": 0]),
        ]
        var placed: [UnitID] = []
        var changes: [UnitID: [String: Any]] = [:]
        for (type, owner, anchor, change) in roster {
            let hex = try #require(spot(state, type, owner, near: anchor, avoiding: cityTiles))
            let id = state.addUnit(type, owner: PlayerID(owner), at: hex)
            placed.append(id)
            if !change.isEmpty { changes[id] = change }
        }
        let warrior = placed[0]
        let warriorHex = try #require(state.unit(warrior)).position
        var free: [HexCoord] = []
        for hex in map.neighbors(of: warriorHex) where !cityTiles.contains(hex) && state.units(at: hex).isEmpty
            && state.canEnd(.warrior, owner: PlayerID(1), at: hex) { free.append(hex) }
        let enemy = try #require(free.min { map.distance($0, enemySide) < map.distance($1, enemySide) })
        let enemyWarrior = state.addUnit(.warrior, owner: PlayerID(1), at: enemy)
        placed.append(enemyWarrior)
        changes[enemyWarrior] = ["hp": 45]
        for (type, change) in [(UnitType.spearman, ["hp": 80, "activity": "fortified"] as [String: Any]), (.archer, ["hp": 25])] {
            let hex = try #require(spot(state, type, 1, near: enemySide, avoiding: cityTiles))
            let id = state.addUnit(type, owner: PlayerID(1), at: hex)
            placed.append(id)
            changes[id] = change
        }
        state = try edit(state, changes)

        let selected = try #require(state.unit(warrior))
        var range: [HexCoord] = [], targets: [HexCoord] = []
        for hex in map.coords(within: 2, of: selected.position) where hex != selected.position {
            let hostile = state.units(at: hex).contains { $0.owner != PlayerID(0) }
            if !hostile, state.canEnd(.warrior, owner: PlayerID(0), at: hex) { range.append(hex) }
            if hostile, map.distance(hex, selected.position) == 1 { targets.append(hex) }
        }
        return Scene(state: state, cities: cities, territory: territory, improvements: improvements, front: front, capital: capital,
                     selected: selected, range: range, targets: targets, units: placed)
    }

    /// A renderer showing the scene from player 0's side with every input set (fog off unless
    /// `fog`), rendered once at the gallery's size so the zoom clamps for it.
    static func view(_ scene: Scene, center: HexCoord, scale: CGFloat, fog: Bool = false, tilted: Bool = true,
                     width: Int = ArtGallery.width, height: Int = ArtGallery.height, overlays: Bool = true) -> MapRenderer {
        let r = MapRenderer(state: scene.state, viewer: PlayerID(0))
        r.fogEnabled = fog
        r.tilted = tilted
        r.setCities(scene.cities)
        r.setTerritory(scene.territory)
        r.setImprovements(scene.improvements)
        if overlays {
            r.setSelection(scene.selected.position, kind: .unit)
            r.setMovementRange(scene.range)
            r.setAttackTargets(scene.targets)
        }
        _ = r.renderImage(width: width, height: height)
        r.setCameraScale(scale)
        r.centerCamera(on: center, animated: false)
        return r
    }
}

/// The skirmish and strategic views of the art gallery (g15, g16), also on their own:
///
///     RENDER_OUT=/some/dir swift test --filter SkirmishGallery
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_OUT"] != nil))
struct SkirmishGallery {
    @Test func skirmish() throws {
        var timing: [String] = []
        try Self.render(timing: &timing)
        print(timing.joined(separator: "\n"))
    }

    /// g15: the skirmish with its overlays beside the capital, its borders and improvements;
    /// g15b close up on the front; g15c the settler overlay; g15d a selected city with its
    /// worked tiles; g15e and g15f combat frames (an arrow in flight; a blow landing, with the
    /// lunge, the flash, the burst and the bar dropping); g16 strategic zoom over every city's
    /// borders with the units' medallions; g16b the borders at the standard zoom.
    static func render(timing: inout [String]) throws {
        let scene = try SkirmishFixture.scene()
        func time(_ name: String, _ r: MapRenderer) {
            timing.append(String(format: "%@ gpu %.2f ms", name, ArtGallery.medianGPU(r)))
        }
        let map = scene.state.map
        let mid = SkirmishFixture.line(map, from: scene.front, to: scene.capital.hex)
        let skirmish = SkirmishFixture.view(scene, center: mid[mid.count / 2], scale: 0.8)
        _ = try ArtGallery.render(skirmish, "g15-skirmish.png")
        time("g15-skirmish", skirmish)
        let close = SkirmishFixture.view(scene, center: scene.selected.position, scale: 0.45)
        _ = try ArtGallery.render(close, "g15b-skirmish-close.png")
        time("g15b-skirmish-close", close)

        // The settler overlay, and the capital selected with its worked tiles.
        let sites = SkirmishFixture.view(scene, center: scene.capital.hex, scale: 0.8, overlays: false)
        var scores = [UInt8](repeating: 0, count: map.tileCount)
        for hex in map.coords(within: 4, of: scene.capital.hex) {
            guard let i = map.index(of: hex), map[index: i].isLand else { continue }
            scores[i] = UInt8(truncatingIfNeeded: (i &* 2_654_435_761) >> 7 % 255 + 1)
        }
        sites.setTileScores(scores)
        _ = try ArtGallery.render(sites, "g15c-settler-scores.png")
        sites.setTileScores([])
        sites.setSelection(scene.capital.hex, kind: .city)
        sites.setWorkedTiles(Array(map.coords(within: 2, of: scene.capital.hex).filter { $0 != scene.capital.hex }.prefix(6)))
        _ = try ArtGallery.render(sites, "g15d-city-selected.png")

        // Combat, frozen mid-animation (offscreen renders never advance the clock).
        let combat = SkirmishFixture.view(scene, center: scene.selected.position, scale: 0.45, overlays: false)
        let state = scene.state
        let archer = try #require(state.unit(scene.units[1])), warrior = try #require(state.unit(scene.units[0]))
        let enemy = try #require(state.unit(scene.units[6]))
        let shot = try #require(scene.units[6...].compactMap { state.unit($0) }.min { a, b in
            (map.distance(a.position, archer.position), a.id) < (map.distance(b.position, archer.position), b.id)
        })
        let afterShot = try SkirmishFixture.edit(state, [shot.id: ["hp": max(shot.hp - 20, 5)], archer.id: ["movesLeft": 0]])
        combat.apply(state: afterShot, events: [EventRecord(.combat(attacker: .unit(archer.id), defender: .unit(shot.id),
                                                                     from: archer.position, to: shot.position, ranged: true,
                                                                     dealt: 20, taken: 0), audience: EventRecord.everyone)])
        combat.advanceAnimations(by: 0.14)
        _ = try ArtGallery.render(combat, "g15e-combat-arrow.png")
        combat.skipAnimations()
        let afterBlow = try SkirmishFixture.edit(afterShot, [enemy.id: ["hp": max(enemy.hp - 30, 5)],
                                                             warrior.id: ["hp": 88, "movesLeft": 0]])
        combat.apply(state: afterBlow, events: [EventRecord(.combat(attacker: .unit(warrior.id), defender: .unit(enemy.id),
                                                                     from: warrior.position, to: enemy.position, ranged: false,
                                                                     dealt: 30, taken: 12), audience: EventRecord.everyone)])
        combat.advanceAnimations(by: Float(MapRenderer.lungeDuration) * UnitStep.lungeStrike + 0.03)
        _ = try ArtGallery.render(combat, "g15f-combat-melee.png")
        combat.skipAnimations()

        let strategic = SkirmishFixture.view(scene, center: scene.front, scale: 3, overlays: false)
        _ = try ArtGallery.render(strategic, "g16-strategic-borders.png")
        time("g16-strategic-borders", strategic)
        let standard = SkirmishFixture.view(scene, center: scene.front, scale: 1.4, overlays: false)
        _ = try ArtGallery.render(standard, "g16b-borders.png")
    }
}
