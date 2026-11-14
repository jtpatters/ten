// Raiders (M2 §11): a non-player faction with camps, always at war with everyone, taking a
// phase after the civs. Its units come from camps placed out of every civ's sight and from
// cities in Revolt; they never capture cities, take tribal villages or leave land.

/// The data-driven raider tuning (M2 §11); nil in rules without raiders.
public struct RaiderRules: Codable, Hashable, Sendable {
    /// Camps appear from this turn, every `campInterval` turns, up to the map size's cap.
    public let firstCampTurn: Int
    public let campInterval: Int
    public let maxCamps: [MaxCamps]
    public let defaultMaxCamps: Int
    /// A new camp is at least this far from every city and from every other camp.
    public let campMinCityDistance: Int
    public let campMinCampDistance: Int
    /// A camp with fewer than `campUnits` living units spawns one every `spawnInterval` turns.
    public let spawnInterval: Int
    public let campUnits: Int
    /// Per era index: the unit types raiders of that world era are drawn from.
    public let eraUnits: [[UnitType]]
    /// Clearing a camp: `campGold` + `campGoldPerEra` × world era.
    public let campGold: Int
    public let campGoldPerEra: Int
    /// A raider attacking a city at 0 HP sacks it: −1 population and up to this much Gold.
    public let sackGold: Int
    /// A city in Revolt spawns a rebel every `rebelInterval` turns (at most `rebelsPerCity`
    /// alive) within `rebelRadius`.
    public let rebelInterval: Int
    public let rebelsPerCity: Int
    public let rebelRadius: Int
    /// RaiderAI: targets within `roamRange` of a camp; otherwise it stays within `homeRange`.
    public let roamRange: Int
    public let homeRange: Int

    public func maxCamps(mapSize: String) -> Int {
        maxCamps.first { $0.mapSize == mapSize }?.camps ?? defaultMaxCamps
    }

    public func units(era: Int) -> [UnitType] {
        eraUnits.isEmpty ? [] : eraUnits[max(0, min(era, eraUnits.count - 1))]
    }
}

public struct MaxCamps: Codable, Hashable, Sendable {
    public let mapSize: String
    public let camps: Int
}

/// A raider camp: its tile, the turn it appeared and the living units it spawned.
public struct RaiderCamp: Codable, Hashable, Sendable {
    public var tile: Int32
    public var spawnedTurn: Int
    public var units: [UnitID]
}

/// A rebel raised by a city in Revolt (M2 §5.2).
public struct Rebel: Codable, Hashable, Sendable {
    public var unit: UnitID
    public var city: CityID
}

/// The raiders' camps and rebels; nil in a game without raiders.
public struct RaiderState: Codable, Hashable, Sendable {
    /// Sorted by tile.
    public var camps: [RaiderCamp] = []
    public var rebels: [Rebel]?
    /// Camps cleared so far, for reports.
    public var cleared: Int?
}

extension GameState {
    /// The raider faction, if the game has one.
    public var raiderPlayer: PlayerID? {
        players.firstIndex { $0.kind == .raiders }.map { PlayerID($0) }
    }

    public func isRaider(_ player: PlayerID) -> Bool {
        players.indices.contains(player.rawValue) && players[player.rawValue].kind == .raiders
    }

    /// The camps standing now (internal truth; players see `PlayerView.knownRaiderCamps`).
    public var raiderCamps: [RaiderCamp] { raiders?.camps ?? [] }

    public func holdsRaiderCamp(_ t: Int) -> Bool {
        guard let camps = raiders?.camps else { return false }
        return camps.contains { Int($0.tile) == t }
    }

    /// The camp unit `id` belongs to, if any.
    public func raiderCamp(of id: UnitID) -> RaiderCamp? {
        raiders?.camps.first { $0.units.contains(id) }
    }

    /// The city rebel `id` was raised by, if it is a rebel.
    public func rebelCity(of id: UnitID) -> CityID? {
        raiders?.rebels?.first { $0.unit == id }?.city
    }

    /// The raiders' phase start (M2 §11): forget dead units, place a camp when due, spawn camp
    /// units and rebels.
    mutating func runRaiders(_ fx: inout Effects) {
        guard rules.raiders != nil, raiders != nil, let me = raiderPlayer else { return }
        raiders!.camps = raiders!.camps.map { camp in
            var camp = camp
            camp.units = camp.units.filter { unit($0) != nil }
            return camp
        }
        if let rebels = raiders!.rebels {
            let alive = rebels.filter { unit($0.unit) != nil }
            raiders!.rebels = alive.isEmpty ? nil : alive
        }
        placeRaiderCampIfDue(&fx)
        spawnCampRaiders(me, &fx)
        spawnRebels(me, &fx)
    }

    /// Tiles some living civ sees now.
    private func seenByCivs() -> TileBitSet {
        var seen = TileBitSet(count: map.tileCount)
        for p in players where p.isAlive && p.isMajor && p.visible.count == map.tileCount {
            for t in 0..<map.tileCount where p.visible[t] { seen[t] = true }
        }
        return seen
    }

    private func raiderSiteAllowed(_ t: Int) -> Bool {
        let tile = map.tiles[t]
        return tile.isLand && rules.isPassable(tile) && city(atTile: t) == nil && !holdsTribalVillage(t)
            && !holdsRaiderCamp(t)
    }

    mutating func placeRaiderCampIfDue(_ fx: inout Effects) {
        guard let r = rules.raiders, raiders != nil, turn >= r.firstCampTurn, r.campInterval > 0,
              (turn - r.firstCampTurn) % r.campInterval == 0,
              raiders!.camps.count < r.maxCamps(mapSize: mapSizeName) else { return }
        let seen = seenByCivs()
        let cityTiles = cities.map { map.index(of: $0.position)! }
        let campTiles = raiders!.camps.map { Int($0.tile) }
        var sites: [Int] = []
        for t in 0..<map.tileCount where !seen[t] && tileCity[t] == 0 && raiderSiteAllowed(t) {
            guard !units.contains(where: { map.index(of: $0.position) == t }) else { continue }
            guard cityTiles.allSatisfy({ map.distance(index: $0, t) >= r.campMinCityDistance }),
                  campTiles.allSatisfy({ map.distance(index: $0, t) >= r.campMinCampDistance }) else { continue }
            sites.append(t)
        }
        var rng = SplitMix64(seed: seed, salts: UInt64(turn), 0x2A1D)
        guard let t = rng.pick(sites) else { return }
        var list = raiders!.camps
        list.append(RaiderCamp(tile: Int32(t), spawnedTurn: turn, units: []))
        raiders!.camps = list.sorted { $0.tile < $1.tile }
        fx.emit(.raiderCampAppeared(at: map.coord(at: t)), .tiles([t]))
        fx.touchTile(t)
    }

    /// The free tile nearest `t` (then lowest index) within `radius` where a raider may stand.
    private func raiderSpawnTile(near t: Int, radius: Int, type: UnitType, owner: PlayerID, allowCamp: Bool) -> Int? {
        var best: (d: Int, t: Int)?
        for d in 0...radius {
            map.forEachIndex(within: d, of: map.coord(at: t)) { n in
                guard map.distance(index: n, t) == d, best == nil || (d, n) < (best!.d, best!.t) else { return }
                let tile = map.tiles[n]
                guard tile.isLand, rules.isPassable(tile), city(atTile: n) == nil, !holdsTribalVillage(n),
                      allowCamp || !holdsRaiderCamp(n),
                      canEnd(type, owner: owner, at: map.coord(at: n)),
                      !units.contains(where: { $0.owner != owner && map.index(of: $0.position) == n }) else { return }
                best = (d, n)
            }
            if best != nil { break }
        }
        return best?.t
    }

    private mutating func spawnRaider(_ owner: PlayerID, near t: Int, radius: Int, allowCamp: Bool, salt: UInt64,
                                      _ fx: inout Effects) -> UnitID? {
        guard let r = rules.raiders else { return nil }
        var rng = SplitMix64(seed: seed, salts: UInt64(turn), 0x2A1E, salt)
        guard let type = rng.pick(r.units(era: worldEra ?? 0)),
              let spot = raiderSpawnTile(near: t, radius: radius, type: type, owner: owner, allowCamp: allowCamp) else { return nil }
        let hex = map.coord(at: spot)
        let id = insertUnit(type, owner: owner, at: hex)
        fx.emit(.unitCreated(unit: id, type: type, owner: owner, at: hex), .tiles([spot]))
        fx.touchPlayer(owner)
        return id
    }

    private mutating func spawnCampRaiders(_ me: PlayerID, _ fx: inout Effects) {
        guard let r = rules.raiders, r.spawnInterval > 0 else { return }
        for i in raiders!.camps.indices {
            let camp = raiders!.camps[i]
            let age = turn - camp.spawnedTurn
            guard age > 0, age % r.spawnInterval == 0, camp.units.count < r.campUnits else { continue }
            if let id = spawnRaider(me, near: Int(camp.tile), radius: 1, allowCamp: true, salt: UInt64(camp.tile), &fx) {
                raiders!.camps[i].units.append(id)
            }
        }
    }

    private mutating func spawnRebels(_ me: PlayerID, _ fx: inout Effects) {
        guard let r = rules.raiders, rules.stability != nil, r.rebelInterval > 0, turn % r.rebelInterval == 0 else { return }
        for city in cities where players[city.owner.rawValue].isMajor
            && rules.stabilityState(city.stability ?? 0) == .revolt {
            let alive = (raiders!.rebels ?? []).count { $0.city == city.id }
            guard alive < r.rebelsPerCity else { continue }
            let centre = map.index(of: city.position)!
            if let id = spawnRaider(me, near: centre, radius: r.rebelRadius, allowCamp: false,
                                    salt: UInt64(city.id.rawValue) &+ 0x10000, &fx) {
                raiders!.rebels = (raiders!.rebels ?? []) + [Rebel(unit: id, city: city.id)]
                fx.emit(.rebelsRose(city: city.id, unit: id, at: map.coord(at: centre)), .owner(city.owner))
            }
        }
    }

    /// A civ's unit entered camp tile `t` (M2 §11): the camp is gone and `player` gets Gold.
    mutating func clearRaiderCamp(at t: Int, by player: PlayerID, _ fx: inout Effects) {
        guard let r = rules.raiders, let i = raiders?.camps.firstIndex(where: { Int($0.tile) == t }) else { return }
        raiders!.camps.remove(at: i)
        raiders!.cleared = (raiders!.cleared ?? 0) + 1
        let gold = r.campGold + r.campGoldPerEra * (worldEra ?? 0)
        players[player.rawValue].gold += gold
        fx.emit(.raiderCampCleared(player: player, at: map.coord(at: t), gold: gold), .ownerAndTiles(player, [t]))
        fx.touchTile(t)
        fx.touchPlayer(player)
    }

    /// A raider attacked city `index` at 0 HP (M2 §11): it loses a citizen (never below 1) and
    /// Gold; the city recovers its captured HP as the raiders withdraw.
    mutating func sackCity(_ index: Int, by id: UnitID, _ fx: inout Effects) {
        guard let r = rules.raiders, let raider = unit(id) else { return }
        let city = cities[index]
        let centre = map.index(of: city.position)!
        let gold = min(players[city.owner.rawValue].gold, r.sackGold)
        players[city.owner.rawValue].gold -= gold
        if city.population > 1 {
            cities[index].population -= 1
            assignCitizens(index)
            fx.emit(.cityShrank(city: city.id, population: city.population - 1, at: city.position), .tiles([centre]))
        }
        cities[index].hp = rules.constants.city.maxHP
        cities[index].lastAttackedPhase = phaseCount
        let turn = self.turn
        updateUnit(id) { u in
            u.movesLeft = 0
            u.lastActedTurn = turn
        }
        fx.emit(.citySacked(city: city.id, by: raider.owner, gold: gold, at: city.position), .ownerAndTiles(city.owner, [centre]))
        fx.touchPlayer(city.owner)
    }
}

extension PlayerMemory {
    mutating func rememberRaiderCamp(at t: Int, standing: Bool) {
        if standing {
            var list = raiderCamps ?? []
            if SortedTiles.insert(t, into: &list) { raiderCamps = list }
        } else if var list = raiderCamps, SortedTiles.remove(t, from: &list) {
            raiderCamps = list.isEmpty ? nil : list
        }
    }
}
