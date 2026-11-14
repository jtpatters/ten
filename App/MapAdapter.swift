import GameCore
import MapRendering

/// Builds the renderer's world inputs from what the viewer knows (M1 §11, §15): cities,
/// territory, improvements, resources and tribal villages from the viewer's `PlayerView` (own cities live,
/// foreign ones and tribal villages out of sight as last seen), or from the live state in
/// diagnostic mode (fog off). Called after a state change, never per frame; the renderer ignores
/// inputs that did not change.
@MainActor
enum MapAdapter {
    static func syncWorld(_ renderer: MapRenderer, state: GameState, viewer: PlayerID, diagnostic: Bool) {
        let view = state.view(for: viewer)
        if diagnostic {
            renderer.setCities(state.cities.map { marker(for: $0, rules: state.rules) })
            renderer.setTerritory((0..<state.map.tileCount).map { t in state.tileOwner(t).map { UInt8($0.rawValue + 1) } ?? 0 })
            renderer.setImprovements(state.map.tiles.map { $0.improvement?.rawValue ?? 0 })
            renderer.setResources(state.map.tiles.map { $0.resource?.rawValue ?? 0 })
        } else {
            renderer.setCities(view.knownCities.map { marker(for: $0, rules: state.rules) })
            renderer.setTerritory(view.knownTerritory)
            renderer.setImprovements(view.knownImprovements)
            renderer.setResources(knownResources(view))
        }
        renderer.setTribalVillages(tribalVillageMarkers(state: state, view: view, diagnostic: diagnostic))
        renderer.setReadyUnits(readyUnits(view))
    }

    /// Per tile the `Resource` raw value the viewer knows there (M2 §3.1: explored and its
    /// reveal tech known), 0 none.
    static func knownResources(_ view: PlayerView) -> [UInt8] {
        (0..<view.tileCount).map { t in view.resource(at: view.coord(at: t))?.rawValue ?? 0 }
    }

    /// The tribal villages the viewer knows (M1 §7.7), seen where their tile is in sight and
    /// remembered elsewhere; in diagnostic mode every one standing, all seen.
    static func tribalVillageMarkers(state: GameState, view: PlayerView, diagnostic: Bool) -> [TribalVillageMarker] {
        if diagnostic {
            return DebugTools.tribalVillages(in: state).map { TribalVillageMarker(hex: $0, seen: true) }
        }
        return view.knownTribalVillages.map { t in
            let hex = view.coord(at: Int(t))
            return TribalVillageMarker(hex: hex, seen: view.isVisible(hex))
        }
    }

    /// The viewer's units ready to act although they may have no moves left, which the map
    /// does not dim as spent (M1 §15): Settlers with no standing order or activity on a tile
    /// where they may found a city (founding needs no moves).
    static func readyUnits(_ view: PlayerView) -> [UnitID] {
        view.units.filter { unit in
            view.rules.unit(unit.type).foundsCity && unit.destination == nil && unit.activity == .none
                && view.canFoundCity(at: unit.position)
        }.map(\.id)
    }

    /// A remembered (or own, current) city as the renderer draws it.
    static func marker(for city: CitySighting, rules: Ruleset) -> CityMarker {
        CityMarker(id: city.id.rawValue, hex: city.position, owner: city.owner, population: city.population, capital: city.capital,
                   walls: city.walls, hp: Float(city.hp) / Float(max(rules.constants.city.maxHP, 1)),
                   wallHP: Float(city.wallHP) / Float(max(maxWallHP(rules), 1)))
    }

    /// A live city (diagnostic mode).
    static func marker(for city: City, rules: Ruleset) -> CityMarker {
        let walls = city.buildings.contains { (rules.building($0)?.wallHP ?? 0) > 0 }
        return CityMarker(id: city.id.rawValue, hex: city.position, owner: city.owner, population: city.population,
                          capital: city.has(rules.palace.id), walls: walls,
                          hp: Float(city.hp) / Float(max(rules.constants.city.maxHP, 1)),
                          wallHP: Float(city.wallHP) / Float(max(maxWallHP(rules), 1)))
    }

    static func maxWallHP(_ rules: Ruleset) -> Int {
        rules.buildings.map(\.wallHP).max() ?? 100
    }

    /// How far around a Settler the overlay ranks and shades city sites (the tile sheet ranks a
    /// site against the same ones).
    static let siteRadius = 10

    /// The settler overlay around a hex: each explored tile within `radius` where the viewer
    /// could found a city gets a shade by its rank among those sites (`SiteRanking`): the best
    /// quarter glows gilt, the worst quarter dims; 0 elsewhere.
    static func settlerScores(_ view: PlayerView, around center: HexCoord, radius: Int) -> [UInt8] {
        var scores = [UInt8](repeating: 0, count: view.tileCount)
        let ranking = view.siteRanking(around: center, radius: radius)
        for site in ranking.sites {
            scores[site.tile] = overlayByte(shade: ranking.shade(of: site.score))
        }
        return scores
    }

    /// A site's shade (1–7) as the overlay's byte, in the middle of the renderer's tier for it
    /// (it bins a byte into tier 1 + byte · 7 / 256: dimmed 1–3, plain 4–5, gilt 6–7).
    static func overlayByte(shade: Int) -> UInt8 {
        UInt8(clamping: (min(max(shade, 1), 7) - 1) * 256 / 7 + 18)
    }
}
