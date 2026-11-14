// Fog and knowledge (M1 §11): what each player sees now, has explored and remembers.
//
// After every command the engine recomputes `Player.visible` for the players whose units,
// cities or territory changed, then updates every player's memory for the tiles that became
// visible and for visible tiles whose owner, improvement, city or tribal village changed;
// city and unit sightings and "met" follow from what is visible.

/// A city as a player last saw it.
public struct CitySighting: Codable, Hashable, Sendable {
    public var id: CityID
    public var name: String
    public var owner: PlayerID
    public var position: HexCoord
    public var population: Int
    public var walls: Bool
    public var capital: Bool
    public var hp: Int
    public var wallHP: Int
    public var turnSeen: Int
}

/// A foreign military unit as a player last saw it.
public struct UnitSighting: Codable, Hashable, Sendable {
    public var id: UnitID
    public var owner: PlayerID
    public var type: UnitType
    public var position: HexCoord
    public var hp: Int
    public var turnSeen: Int
}

/// What a player remembers (M1 §11).
public struct PlayerMemory: Codable, Hashable, Sendable {
    /// Per tile: the owner last seen (0 = none, else player + 1).
    public internal(set) var tileOwner: [UInt8]
    /// Per tile: the improvement last seen (`Improvement` raw value, 0 = none).
    public internal(set) var tileImprovement: [UInt8]
    /// Every city ever seen and not seen gone since, own cities included; sorted by id.
    public internal(set) var cities: [CitySighting]
    /// Foreign military units seen in the last `sightingMaxAge` turns and not seen killed;
    /// sorted by id.
    public internal(set) var units: [UnitSighting]
    /// Tribal villages seen and not seen gone since (M1 §7.7): tile indices, sorted and unique;
    /// nil when there are none (never empty), so the key is absent from saves without them.
    public internal(set) var tribalVillages: [Int32]?
    /// Raider camps remembered (M2 §11): sorted tile indices; nil rather than empty.
    public internal(set) var raiderCamps: [Int32]?
    /// Roads last seen (M2 §3.4); nil when none (never empty), so the key is absent from saves
    /// without them.
    public internal(set) var tileRoad: TileBitSet?

    public init(tileCount: Int) {
        tileOwner = Array(repeating: 0, count: tileCount)
        tileImprovement = Array(repeating: 0, count: tileCount)
        cities = []
        units = []
        tribalVillages = nil
    }

    public func remembersRoad(_ t: Int) -> Bool { tileRoad?[t] ?? false }

    mutating func rememberRoad(at t: Int, _ road: Bool) {
        if road {
            if tileRoad == nil { tileRoad = TileBitSet(count: tileOwner.count) }
            tileRoad![t] = true
        } else if tileRoad?[t] == true {
            tileRoad![t] = false
            if tileRoad!.isEmpty { tileRoad = nil }
        }
    }

    public func city(_ id: CityID) -> CitySighting? {
        cities.first { $0.id == id }
    }

    /// The sighting of foreign unit `id`, if remembered.
    public func unit(_ id: UnitID) -> UnitSighting? {
        if case let .found(i) = Self.search(units, id.rawValue, \.id.rawValue) { return units[i] }
        return nil
    }

    /// The remembered city at `hex`.
    public func city(at hex: HexCoord) -> CitySighting? {
        cities.first { $0.position == hex }
    }

    mutating func upsert(_ sighting: CitySighting) {
        switch Self.search(cities, sighting.id.rawValue, \.id.rawValue) {
        case let .found(i): if cities[i] != sighting { cities[i] = sighting }
        case let .insert(i): cities.insert(sighting, at: i)
        }
    }

    mutating func upsert(_ sighting: UnitSighting) {
        switch Self.search(units, sighting.id.rawValue, \.id.rawValue) {
        case let .found(i): if units[i] != sighting { units[i] = sighting }
        case let .insert(i): units.insert(sighting, at: i)
        }
    }

    mutating func forgetUnit(_ id: UnitID) {
        if case let .found(i) = Self.search(units, id.rawValue, \.id.rawValue) { units.remove(at: i) }
    }

    private enum SearchResult { case found(Int), insert(Int) }

    private static func search<T>(_ items: [T], _ key: Int, _ id: (T) -> Int) -> SearchResult {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let k = id(items[mid])
            if k == key { return .found(mid) }
            if k < key { lo = mid + 1 } else { hi = mid }
        }
        return .insert(lo)
    }
}

extension GameState {
    /// The visibility of each player in `mask` (others: empty sets). Visible = within each own
    /// unit's sight, within the city sight of each own city centre, and every owned tile.
    func computeVisibility(for mask: UInt64) -> [TileBitSet] {
        let count = map.tileCount
        var result = players.indices.map { mask & (1 << UInt64($0)) != 0 ? TileBitSet(count: count) : TileBitSet(count: 0) }
        func wanted(_ p: PlayerID) -> Bool { mask & (1 << UInt64(p.rawValue)) != 0 }
        for unit in units where wanted(unit.owner) {
            let o = unit.owner.rawValue
            map.forEachIndex(within: sight(of: unit), of: unit.position) { result[o][$0] = true }
        }
        let citySight = rules.constants.city.sight
        for city in cities where wanted(city.owner) {
            let o = city.owner.rawValue
            map.forEachIndex(within: citySight, of: city.position) { result[o][$0] = true }
        }
        if !cities.isEmpty {
            let owners = cityOwnerTable()
            for t in 0..<count {
                let code = tileCity[t]
                guard code != 0 else { continue }
                let o = owners[Int(code) - 1]
                if o >= 0, mask & (1 << UInt64(o)) != 0 { result[o][t] = true }
            }
        }
        return result
    }

    /// Brings visibility, explored tiles, memory, sightings and "met" up to date (M1 §11):
    /// visibility is recomputed for `fx.dirtyPlayers`; memory refreshes for newly visible tiles
    /// and for `fx.dirtyTiles` that are visible. Emits `playersMet`.
    mutating func updateKnowledge(_ fx: inout Effects) {
        let recompute = fx.dirtyPlayers
        fx.dirtyPlayers = 0
        let territory = (recompute != 0 || !fx.dirtyTiles.isEmpty) ? territoryCodes() : []

        if recompute != 0 {
            let fresh = computeVisibility(for: recompute)
            for p in players.indices where recompute & (1 << UInt64(p)) != 0 {
                let newly = fresh[p].subtracting(players[p].visible)
                players[p].visible = fresh[p]
                players[p].explored.formUnion(fresh[p])
                newly.forEachIndex { refreshTileMemory(PlayerID(p), $0, territory: territory, &fx) }
            }
        }
        if !fx.dirtyTiles.isEmpty {
            for p in players.indices where players[p].isAlive {
                for t in fx.dirtyTiles where players[p].visible[t] {
                    refreshTileMemory(PlayerID(p), t, territory: territory, &fx)
                }
            }
            fx.dirtyTiles.removeAll()
        }
        refreshSightings(&fx)
    }

    /// Tile `t` is visible to `p`: remember its owner, its improvement and whether a tribal
    /// village stands there (one taken out of sight stays remembered until the tile is seen
    /// again).
    private mutating func refreshTileMemory(_ p: PlayerID, _ t: Int, territory: [UInt8], _ fx: inout Effects) {
        let owner = territory[t]
        let improvement = map.tiles[t].improvement?.rawValue ?? 0
        if players[p.rawValue].memory.tileOwner[t] != owner { players[p.rawValue].memory.tileOwner[t] = owner }
        if players[p.rawValue].memory.tileImprovement[t] != improvement {
            players[p.rawValue].memory.tileImprovement[t] = improvement
        }
        if map.tiles[t].hasRoad != players[p.rawValue].memory.remembersRoad(t) {
            players[p.rawValue].memory.rememberRoad(at: t, map.tiles[t].hasRoad)
        }
        if tribalVillages != nil || players[p.rawValue].memory.tribalVillages != nil {
            players[p.rawValue].memory.rememberTribalVillage(at: t, standing: holdsTribalVillage(t))
        }
        if raiders != nil || players[p.rawValue].memory.raiderCamps != nil {
            players[p.rawValue].memory.rememberRaiderCamp(at: t, standing: holdsRaiderCamp(t))
        }
        if owner != 0, Int(owner) - 1 != p.rawValue { meet(p, PlayerID(Int(owner) - 1), &fx) }
    }

    /// Cities and units on visible tiles refresh each player's sightings (and "met"); cities
    /// seen gone are forgotten; unit sightings older than `sightingMaxAge` turns are dropped.
    private mutating func refreshSightings(_ fx: inout Effects) {
        let cityTiles = cities.map { map.index(of: $0.position)! }
        let unitTiles = units.map { map.index(of: $0.position)! }
        let maxAge = rules.constants.knowledge.sightingMaxAge
        let palace = rules.palace.id
        let wallBuildings = rules.buildings.filter { $0.wallHP > 0 }.map(\.id)

        for p in players.indices where players[p].isAlive {
            let me = PlayerID(p)
            for (c, city) in cities.enumerated() where players[p].visible[cityTiles[c]] {
                if city.owner != me { meet(me, city.owner, &fx) }
                let sighting = CitySighting(id: city.id, name: city.name, owner: city.owner, position: city.position,
                                            population: city.population,
                                            walls: wallBuildings.contains { city.has($0) }, capital: city.has(palace),
                                            hp: city.hp, wallHP: city.wallHP, turnSeen: turn)
                players[p].memory.upsert(sighting)
            }
            // A remembered city whose tile is visible but holds no such city is gone.
            let visible = players[p].visible
            let gone = players[p].memory.cities.filter { s in
                visible[map.index(of: s.position)!] && city(s.id)?.position != s.position
            }.map(\.id)
            if !gone.isEmpty { players[p].memory.cities.removeAll { gone.contains($0.id) } }
            for (u, unit) in units.enumerated() where unit.owner != me && players[p].visible[unitTiles[u]] {
                meet(me, unit.owner, &fx)
                guard !unit.type.isCivilian else { continue }
                players[p].memory.upsert(UnitSighting(id: unit.id, owner: unit.owner, type: unit.type,
                                                      position: unit.position, hp: unit.hp, turnSeen: turn))
            }
            if players[p].memory.units.contains(where: { turn - $0.turnSeen > maxAge }) {
                players[p].memory.units.removeAll { turn - $0.turnSeen > maxAge }
            }
        }
    }

    /// A unit is about to vanish (killed, disbanded): players who see its tile forget their
    /// sighting of it ("seen killed").
    mutating func forgetSightings(of unit: Unit) {
        guard let t = map.index(of: unit.position) else { return }
        for p in players.indices where players[p].visible[t] {
            players[p].memory.forgetUnit(unit.id)
        }
    }

    /// Writes a city into a player's memory (a rejected `foundCity` reveals the city in the
    /// way, M1 §5).
    mutating func remember(_ city: City, by player: PlayerID) {
        let palace = rules.palace.id
        let walls = rules.buildings.filter { $0.wallHP > 0 }.contains { city.has($0.id) }
        players[player.rawValue].memory.upsert(CitySighting(
            id: city.id, name: city.name, owner: city.owner, position: city.position, population: city.population,
            walls: walls, capital: city.has(palace), hp: city.hp, wallHP: city.wallHP, turnSeen: turn))
    }
}
