// Housing and Stability (M2 §5.1, §5.2).

/// A city's Stability state (M2 §5.2).
public enum StabilityState: Int, Comparable, Sendable {
    case revolt, unrest, restless, content, thriving

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A city's Housing by source (M2 §5.1).
public struct HousingBreakdown: Hashable, Sendable {
    /// From water at the centre: none, coast or lake, fresh water.
    public var base: Int
    public var buildings: Int
    /// From worked Farms, Pastures, Plantations and Camps.
    public var improvements: Int
    public var total: Int { base + buildings + improvements }
}

/// A city's Stability by source (M2 §5.2): supply minus need and penalties.
public struct StabilityBreakdown: Hashable, Sendable {
    public var buildings = 0
    public var luxuries = 0
    public var need = 0
    public var empireSize = 0
    public var overcrowding = 0
    public var occupied = 0

    public init() {}

    /// Supply − need − penalties (the penalties are negative or 0).
    public var total: Int { buildings + luxuries - need + empireSize + overcrowding + occupied }
}

extension Ruleset {
    public func stabilityState(_ value: Int) -> StabilityState {
        guard let s = stability else { return .content }
        if value >= s.thriving { return .thriving }
        if value >= 0 { return .content }
        if value <= s.revolt { return .revolt }
        if value <= s.unrest { return .unrest }
        return .restless
    }

    /// Percent added to every yield but Food in this state.
    public func stabilityYieldPct(_ state: StabilityState) -> Int {
        guard let s = stability else { return 0 }
        switch state {
        case .thriving: return s.thrivingPct
        case .content: return 0
        case .restless: return s.restlessPct
        case .unrest, .revolt: return s.unrestPct
        }
    }
}

extension GameState {
    /// A city's Housing (M2 §5.1).
    public func housing(of city: City) -> HousingBreakdown {
        guard let h = rules.housing else { return HousingBreakdown(base: 0, buildings: 0, improvements: 0) }
        let centre = map.index(of: city.position)!
        var fresh = map.tiles[centre].riverEdges != 0, coast = false
        map.forEachNeighbor(of: centre) { n, _ in
            let t = map.tiles[n]
            if t.terrain == .lake || t.elevation == .mountains { fresh = true }
            if t.terrain == .coast || t.terrain == .lake { coast = true }
        }
        let base = fresh ? h.freshWater : coast ? h.coast : h.base
        let buildings = city.buildings.reduce(0) { $0 + (rules.building($1)?.housing ?? 0) }
        var improved = 0
        for hex in city.workedTiles {
            let tile = map.tiles[map.index(of: hex)!]
            if let i = tile.improvement, !tile.isPillaged, h.improvements.contains(caseName(i)) { improved += 1 }
        }
        return HousingBreakdown(base: base, buildings: buildings, improvements: improved / max(1, h.improvedTilesPerHousing))
    }

    /// Percent of a positive food surplus that goes into the store (M2 §5.1, §5.2).
    public func growthPct(of city: City) -> Int {
        guard let h = rules.housing else { return 100 }
        let housing = housing(of: city).total, pop = city.population
        var pct = pop >= housing + h.noGrowthAbove ? 0 : pop >= housing ? h.atPct : pop == housing - 1 ? h.nearPct : h.belowPct
        switch rules.stabilityState(city.stability ?? 0) {
        case .restless: pct /= 2
        case .unrest, .revolt: pct = 0
        default: break
        }
        return pct
    }

    /// Stability of each of `player`'s cities, by city index (M2 §5.2). Luxuries go one at a
    /// time, each distinct improved luxury the player owns adding +1 to the `luxuryCities` cities
    /// with the least Stability so far (ties: lower city id).
    public func stabilityBreakdowns(for player: PlayerID) -> [Int: StabilityBreakdown] {
        guard let s = rules.stability else { return [:] }
        let own = cities.indices.filter { cities[$0].owner == player }
        let empire = own.count > s.freeCities ? -((own.count - s.freeCities) / max(1, s.citiesPerPenalty)) : 0
        var result: [Int: StabilityBreakdown] = [:]
        for i in own {
            let city = cities[i]
            var b = StabilityBreakdown()
            b.buildings = city.buildings.reduce(0) { $0 + (rules.building($1)?.stability ?? 0) }
            b.need = max(0, (city.population - 1) / max(1, s.needDivisor))
            b.empireSize = empire
            b.overcrowding = -max(0, city.population - housing(of: city).total)
            if let captured = city.capturedTurn, turn - captured <= s.occupiedTurns { b.occupied = s.occupied }
            result[i] = b
        }
        let sources = improvedSources(of: player)
        let luxuries = Resource.allCases.filter { rules.resource($0)?.kind == .luxury && sources[Int($0.rawValue) - 1] > 0 }.count
        for _ in 0..<luxuries {
            let lowest = own.sorted { a, b in
                let (x, y) = (result[a]!.total, result[b]!.total)
                return x != y ? x < y : cities[a].id.rawValue < cities[b].id.rawValue
            }
            for i in lowest.prefix(s.luxuryCities) { result[i]!.luxuries += 1 }
        }
        return result
    }

    /// Recomputes the Stability of `player`'s cities (the owner's phase start, before yields).
    mutating func updateStability(for player: PlayerID) {
        guard rules.stability != nil else { return }
        for (i, b) in stabilityBreakdowns(for: player) { cities[i].stability = b.total }
    }
}
