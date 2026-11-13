// Read-only queries for the App's war warnings (M1 §16): foreign troops the player sees near its
// cities, what it remembers of another player's army, and the capital whose loss would end the
// game. Built only from what the player knows: foreign units on tiles it sees now, its sightings
// (M1 §11), its own cities, and public facts (how many players there are).

/// Foreign military units the player sees near one of its cities.
public struct TroopsNear: Hashable, Sendable {
    public var city: CityID
    /// Visible foreign military units (not recon) within the radius, each counted only at the
    /// own city nearest to it (ties: the lower city id); nearest first, then by id.
    public var units: [Unit]
}

/// What the player remembers of another player's army: its unit sightings (M1 §11: foreign
/// military units seen in the last `sightingMaxAge` turns and not seen killed), recon left out.
public struct RememberedArmy: Hashable, Sendable {
    public var owner: PlayerID
    /// Military units seen (not recon).
    public var units: Int
    /// The own city nearest to any of them (ties: the lower city id), and how many tiles from
    /// it the nearest stood when last seen; nil with no sighting or no own city.
    public var nearestCity: CityID?
    public var distance: Int?
    /// The turn the latest of them was seen; nil with no sighting.
    public var lastSeen: Int?
}

extension PlayerView {
    /// Visible foreign military units (recon left out: a passing Scout is no threat) within
    /// `radius` tiles of own cities, at any relation (an army gathers before war is declared),
    /// grouped by the own city nearest to each unit; cities with none are left out. Sorted by
    /// city id.
    public func foreignMilitaryNear(radius: Int = 4) -> [TroopsNear] {
        let mine = cities
        guard !mine.isEmpty else { return [] }
        var near: [[(unit: Unit, distance: Int)]] = Array(repeating: [], count: mine.count)
        for unit in visibleForeignUnits {
            let def = rules.unit(unit.type)
            guard def.isMilitary, def.unitClass != .recon else { continue }
            var best: (index: Int, distance: Int)?
            for (i, city) in mine.enumerated() {
                let d = distance(unit.position, city.position)
                if d <= radius, best.map({ d < $0.distance }) ?? true { best = (i, d) }
            }
            if let best { near[best.index].append((unit, best.distance)) }
        }
        return mine.indices.compactMap { i in
            guard !near[i].isEmpty else { return nil }
            let units = near[i].sorted { ($0.distance, $0.unit.id.rawValue) < ($1.distance, $1.unit.id.rawValue) }.map(\.unit)
            return TroopsNear(city: mine[i].id, units: units)
        }
    }

    /// What this player remembers of `other`'s army (M1 §11 sightings, recon left out): how
    /// many units, the own city nearest to any of them and how far, the latest turn seen.
    public func rememberedArmy(of other: PlayerID) -> RememberedArmy {
        let seen = sightings(of: other).filter { rules.unit($0.type).isMilitary && rules.unit($0.type).unitClass != .recon }
        var nearest: (city: CityID, distance: Int)?
        for sighting in seen {
            for city in cities {
                let d = distance(sighting.position, city.position)
                if nearest.map({ (d, city.id.rawValue) < ($0.distance, $0.city.rawValue) }) ?? true { nearest = (city.id, d) }
            }
        }
        return RememberedArmy(owner: other, units: seen.count, nearestCity: nearest?.city, distance: nearest?.distance,
                              lastSeen: seen.map(\.turnSeen).max())
    }

    /// The player's original capital when losing it would lose the game: in a two-player game
    /// the other player wins by domination the moment it owns that city (M1 §10). Nil in larger
    /// games (who holds the other capitals may be hidden), before the player has founded a city,
    /// and once the game is over.
    public var capitalAtStake: CityID? {
        guard state.players.count == 2, state.outcome == nil, let capital = me.originalCapital, city(capital) != nil else {
            return nil
        }
        return capital
    }
}
