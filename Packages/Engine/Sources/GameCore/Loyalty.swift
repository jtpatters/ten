/// Loyalty and Free Cities (M2 §5.5, §12.5).
public struct LoyaltyRules: Codable, Hashable, Sendable {
    /// Pressure reaches cities within `range`; a city of population p at distance d exerts
    /// p × (`pressureBase` − d).
    public let range: Int
    public let pressureBase: Int
    /// The pressure difference is divided by this and clamped to ±`pressureCap`.
    public let divisor: Int
    public let pressureCap: Int
    public let capital: Int
    public let nearCapital: Int
    public let garrison: Int
    public let stabilityMax: Int
    public let stabilityMin: Int
    public let captured: Int
    public let capturedTurns: Int
    public let enemyUnit: Int
    public let enemyUnitsMax: Int
    /// The whole delta is clamped to ±`deltaCap`.
    public let deltaCap: Int
    public let founded: Int
    public let capturedStart: Int
    public let flipped: Int
    public let flipTurns: Int
    public let warningTurns: Int
    /// Every `defenderEvery` turns a Free City adds a defender while it has fewer than
    /// `defenderMax` in its territory: `defenders[world era]` (the last for later eras).
    public let defenderEvery: Int
    public let defenderMax: Int
    public let defenders: [UnitType]
}

/// Where a city's Loyalty change comes from (M2 §5.5).
public struct LoyaltyBreakdown: Hashable, Sendable {
    public var ownPressure = 0
    public var foreignPressure = 0
    /// The civ exerting the most foreign pressure, if any.
    public var topForeign: PlayerID?
    public var pressure = 0
    public var capital = 0
    public var garrison = 0
    public var stability = 0
    /// From the government and policies (M2 §7.2–7.3).
    public var government = 0
    public var captured = 0
    public var enemies = 0
    /// The clamped change per turn.
    public var total = 0
}

extension GameState {
    /// Pressure on `city` from each player's cities (major civs only), in player order.
    func loyaltyPressure(on city: City) -> [Int] {
        guard let l = rules.loyalty else { return [] }
        var pressure = [Int](repeating: 0, count: players.count)
        let centre = map.index(of: city.position)!
        for other in cities where players[other.owner.rawValue].isMajor {
            let d = map.distance(index: centre, map.index(of: other.position)!)
            guard d <= l.range else { continue }
            pressure[other.owner.rawValue] += other.population * (l.pressureBase - d)
        }
        return pressure
    }

    /// The Loyalty change `city` gets at its owner's next phase start; nil without Loyalty or
    /// for a Free City.
    public func loyaltyBreakdown(_ city: City) -> LoyaltyBreakdown? {
        guard let l = rules.loyalty, players[city.owner.rawValue].isMajor else { return nil }
        let owner = city.owner
        var b = LoyaltyBreakdown()
        let pressure = loyaltyPressure(on: city)
        b.ownPressure = pressure[owner.rawValue]
        for p in pressure.indices where p != owner.rawValue && pressure[p] > b.foreignPressure {
            b.foreignPressure = pressure[p]
            b.topForeign = PlayerID(p)
        }
        b.pressure = max(-l.pressureCap, min(l.pressureCap, (b.ownPressure - b.foreignPressure) / l.divisor))

        let centre = map.index(of: city.position)!
        if let capital = players[owner.rawValue].capital, let c = self.city(capital) {
            if c.id == city.id {
                b.capital = l.capital
            } else if map.distance(index: centre, map.index(of: c.position)!) <= l.range {
                b.capital = l.nearCapital
            }
        }
        if units.contains(where: { $0.position == city.position && $0.owner == owner && !$0.type.isCivilian }) {
            b.garrison = l.garrison
            b.government += bonus(\.garrisonLoyalty, for: owner)
        }
        if city.capturedTurn != nil { b.government += bonus(\.conqueredLoyalty, for: owner) }
        if let capital = players[owner.rawValue].capital, let c = self.city(capital) {
            for bonus in bonuses(of: owner) {
                guard let v = bonus.capitalLoyalty,
                      map.distance(index: centre, map.index(of: c.position)!) <= (bonus.capitalLoyaltyReach ?? 0) else { continue }
                b.government += v
            }
        }
        let stability = city.stability ?? 0
        b.stability = stability > 0 ? min(stability, l.stabilityMax) : max(stability, l.stabilityMin)
        if let captured = city.capturedTurn, turn - captured <= l.capturedTurns { b.captured = l.captured }
        let code = Int32(city.id.rawValue + 1)
        let enemies = units.filter { u in
            !u.type.isCivilian && u.owner != owner && isAtWar(u.owner, owner)
                && map.index(of: u.position).map { tileCity[$0] == code } == true
        }.count
        b.enemies = max(-l.enemyUnitsMax, min(0, enemies * l.enemyUnit))

        let sum = b.pressure + b.capital + b.garrison + b.stability + b.captured + b.enemies + b.government
        b.total = max(-l.deltaCap, min(l.deltaCap, sum))
        return b
    }

    /// Turns until `city` revolts at its current trend (nil: it is not losing Loyalty).
    public func turnsUntilRevolt(_ city: City) -> Int? {
        guard let loyalty = city.loyalty, let b = loyaltyBreakdown(city), b.total < 0 else { return nil }
        return (loyalty + (-b.total) - 1) / -b.total
    }

    /// At `player`'s phase start, after Stability: every city's Loyalty changes by its delta
    /// (all computed before any applies); a city at 0 revolts.
    mutating func updateLoyalty(for player: PlayerID, _ fx: inout Effects) {
        guard let l = rules.loyalty, freeCities != nil, players[player.rawValue].isMajor else { return }
        let changes = cities.indices.compactMap { i -> (Int, Int)? in
            guard cities[i].owner == player, let b = loyaltyBreakdown(cities[i]) else { return nil }
            return (i, b.total)
        }
        var revolts: [Int] = []
        for (i, delta) in changes {
            let loyalty = max(0, min(100, (cities[i].loyalty ?? l.founded) + delta))
            cities[i].loyalty = loyalty
            if loyalty == 0 { revolts.append(i) }
        }
        for i in revolts { revolt(i, &fx) }
    }

    /// City `index` becomes a Free City: its owner's units leave the centre, its queue is
    /// cleared, its buildings (but the Palace) and quarters are kept.
    mutating func revolt(_ index: Int, _ fx: inout Effects) {
        guard let free = freeCities, let l = rules.loyalty else { return }
        let city = cities[index]
        let old = city.owner
        let centre = map.index(of: city.position)!
        for unit in units where unit.position == city.position && unit.owner == old {
            moveOut(unit.id, from: centre, &fx)
        }
        let palace = rules.palace.id
        cities[index].owner = free
        cities[index].buildings.removeAll { $0 == palace }
        cities[index].queue = []
        cities[index].capturedTurn = turn
        cities[index].loyalty = l.flipped
        cities[index].freeCityLeader = nil
        cities[index].freeCityTurns = nil
        transferTerritory(of: index, from: old, to: free, &fx)
        if players[old.rawValue].capital == city.id { players[old.rawValue].capital = nil }
        ensureCapital(of: old, &fx)
        remember(cities[index], by: old)
        fx.emit(.cityRevolted(city: city.id, name: city.name, from: old, to: free, at: city.position), .tiles([centre]))
    }

    /// The unit moves to the nearest tile other than `centre` it may stand on.
    mutating func moveOut(_ id: UnitID, from centre: Int, _ fx: inout Effects) {
        guard let unit = unit(id) else { return }
        let limit = max(map.width, map.height)
        for radius in 1...limit {
            var best: Int?
            map.forEachIndex(within: radius, of: unit.position) { t in
                guard map.distance(index: t, centre) == radius, best.map({ t < $0 }) ?? true, !holdsTribalVillage(t),
                      mayStand(t, unit) else { return }
                best = t
            }
            guard let target = best else { continue }
            let hex = map.coord(at: target)
            updateUnit(id) { u in
                u.position = hex
                u.activity = .none
                u.destination = nil
            }
            fx.emit(.unitMoved(unit: id, from: unit.position, path: [hex]), .tiles([centre, target]))
            fx.touchPlayer(unit.owner)
            return
        }
        killUnit(id, &fx)
    }

    /// The city's territory changes owner with it; the loser knows it lost it.
    mutating func transferTerritory(of index: Int, from old: PlayerID, to new: PlayerID, _ fx: inout Effects) {
        let code = Int32(cities[index].id.rawValue + 1)
        let newCode = UInt8(new.rawValue + 1)
        for t in tileCity.indices where tileCity[t] == code {
            fx.touchTile(t)
            if players[old.rawValue].memory.tileOwner[t] != newCode { players[old.rawValue].memory.tileOwner[t] = newCode }
        }
        fx.touchPlayer(old)
        fx.touchPlayer(new)
        assignCitizens(index)
    }

    /// At the start of each turn: each Free City tracks the civ with the most positive pressure
    /// and joins it after `flipTurns` consecutive turns; every `defenderEvery` turns it adds a
    /// defender while it has fewer than `defenderMax` units in its territory.
    mutating func runFreeCities(_ fx: inout Effects) {
        guard let l = rules.loyalty, let free = freeCities else { return }
        for index in cities.indices where cities[index].owner == free {
            let pressure = loyaltyPressure(on: cities[index])
            var leader: PlayerID?, best = 0
            for p in pressure.indices where players[p].isAlive && pressure[p] > best {
                best = pressure[p]
                leader = PlayerID(p)
            }
            if leader != nil, leader == cities[index].freeCityLeader {
                cities[index].freeCityTurns = (cities[index].freeCityTurns ?? 0) + 1
            } else {
                cities[index].freeCityLeader = leader
                cities[index].freeCityTurns = leader == nil ? nil : 1
            }
            if let leader, (cities[index].freeCityTurns ?? 0) >= l.flipTurns {
                join(index, to: leader, &fx)
            }
        }
        guard l.defenderEvery > 0, turn % l.defenderEvery == 0, let type = freeCityDefender(l) else { return }
        for index in cities.indices where cities[index].owner == free {
            let code = Int32(cities[index].id.rawValue + 1)
            let defenders = units.filter { u in
                u.owner == free && map.index(of: u.position).map { tileCity[$0] == code } == true
            }.count
            guard defenders < l.defenderMax else { continue }
            let centre = cities[index].position
            var site: HexCoord?
            if canEnd(type, owner: free, at: centre) {
                site = centre
            } else {
                var best: Int?
                map.forEachIndex(within: 1, of: centre) { t in
                    guard tileCity[t] == code, best.map({ t < $0 }) ?? true, !holdsTribalVillage(t),
                          canEnd(type, owner: free, at: map.coord(at: t)) else { return }
                    best = t
                }
                site = best.map { map.coord(at: $0) }
            }
            guard let site else { continue }
            let id = insertUnit(type, owner: free, at: site)
            let t = map.index(of: site)!
            fx.emit(.unitCreated(unit: id, type: type, owner: free, at: site), .tiles([t]))
            fx.touchPlayer(free)
        }
    }

    func freeCityDefender(_ l: LoyaltyRules) -> UnitType? {
        guard !l.defenders.isEmpty else { return nil }
        return l.defenders[min(worldEra ?? 0, l.defenders.count - 1)]
    }

    /// Free City `index` joins `new`: the Free Cities' units in its territory disband.
    mutating func join(_ index: Int, to new: PlayerID, _ fx: inout Effects) {
        guard let free = freeCities, let l = rules.loyalty else { return }
        let city = cities[index]
        let centre = map.index(of: city.position)!
        let code = Int32(city.id.rawValue + 1)
        for unit in units where unit.owner == free && map.index(of: unit.position).map({ tileCity[$0] == code }) == true {
            killUnit(unit.id, &fx)
        }
        for unit in units where unit.position == city.position && unit.owner != new {
            moveOut(unit.id, from: centre, &fx)
        }
        cities[index].owner = new
        cities[index].capturedTurn = turn
        cities[index].loyalty = l.flipped
        cities[index].freeCityLeader = nil
        cities[index].freeCityTurns = nil
        transferTerritory(of: index, from: free, to: new, &fx)
        if players[new.rawValue].originalCapital == city.id { movePalace(of: new, to: city.id, &fx) }
        ensureCapital(of: new, &fx)
        fx.emit(.cityJoined(city: city.id, name: city.name, from: free, to: new, at: city.position), .tiles([centre]))
    }
}
