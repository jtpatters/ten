// Read-only queries for the App's tile sheet (M1 §16 "Long-press: tile sheet"), built only from
// what the player knows: the tile as explored, the improvement and owner as last seen, and the
// city and tribal village the player knows on it.

/// An explored tile as a player knows it (M1 §4, §8.1): what it yields them, who owns it as last
/// seen, and what it does to movement and defence. The numbers follow the engine's rules: a city
/// centre counts as having no forest, jungle or marsh, for movement and defence too.
public struct TileFacts: Hashable, Sendable {
    public var hex: HexCoord
    /// The tile, with its improvement as last seen.
    public var tile: Tile
    /// Its yields for the player (with the city-centre rules where a known city stands).
    public var yields: Yields
    /// The owner as last seen (nil: none).
    public var owner: PlayerID?
    /// The known city centred on it (own, or as last seen).
    public var city: CitySighting?
    /// The player sees the tile now.
    public var isVisible: Bool
    /// Movement points a land unit spends entering it (1, plus its elevation and feature),
    /// before any river crossing; nil where land units cannot go (water, mountains, ice).
    public var moveCost: Int?
    /// Added to the move cost when entering it across one of its river edges (0 without rivers).
    public var riverCrossingCost: Int
    /// What a unit defending on it gains from the ground (elevation, then feature), by name.
    public var defense: [StrengthModifier]
    /// Added to a melee attacker's strength when it attacks across one of the tile's river edges
    /// (0 without rivers; negative in the M1 rules).
    public var riverAttackModifier: Int
    /// City Strength a city on this tile gets from the ground (hills).
    public var cityStrength: Int
    /// A tribal village the player knows of on it (M1 §7.7, from memory): in sight now, or
    /// remembered (it may be gone); nil when it knows of none.
    public var tribalVillage: TileTribalVillage?

    /// The sum of `defense`.
    public var totalDefense: Int { defense.reduce(0) { $0 + $1.value } }
}

/// A tribal village on a tile as the player knows it (`TileFacts.tribalVillage`).
public enum TileTribalVillage: Hashable, Sendable {
    /// The tile is in sight: it stands there now.
    case seen
    /// Remembered from when the tile was last seen: it may be gone.
    case remembered
}

extension PlayerView {
    /// The tile sheet's facts for an explored tile, from what this player knows; nil for an
    /// unexplored tile or a hex off the map.
    public func tileFacts(at hex: HexCoord) -> TileFacts? {
        guard let hex = normalize(hex), let tile = tile(at: hex), let yields = tileYields(at: hex) else { return nil }
        let city = knownCity(at: hex)
        let elevation = rules.elevation(tile.elevation)
        let feature = rules.feature(tile.feature)
        // A city centre counts as having no forest, jungle or marsh (M1 §4).
        let featureCounts = !(feature.removedByCity && city != nil)
        var moveCost: Int?
        if rules.isPassable(tile) {
            moveCost = 1 + elevation.moveCost + (featureCounts ? feature.moveCost : 0)
        }
        var defense: [StrengthModifier] = []
        if elevation.defense != 0 { defense.append(StrengthModifier(kind: .elevation(tile.elevation), value: elevation.defense)) }
        if featureCounts, feature.defense != 0 { defense.append(StrengthModifier(kind: .feature(tile.feature), value: feature.defense)) }
        let river = tile.riverEdges != 0
        let visible = isVisible(hex)
        let village: TileTribalVillage? = isKnownTribalVillage(hex) ? (visible ? .seen : .remembered) : nil
        return TileFacts(hex: hex, tile: tile, yields: yields, owner: knownOwner(at: hex), city: city, isVisible: visible,
                         moveCost: moveCost, riverCrossingCost: river ? rules.river.crossingMoveCost : 0, defense: defense,
                         riverAttackModifier: river ? rules.river.meleeAttackModifier : 0, cityStrength: elevation.cityStrength,
                         tribalVillage: village)
    }
}

/// Why a player could not found a city on a tile (M1 §5), as it knows the tile: the first rule
/// of `canFoundCity` that fails.
public enum FoundingProblem: Hashable, Sendable {
    case offMap
    case unexplored
    case water
    case mountains
    /// A feature no city stands on (ice, an oasis), by its rules name.
    case feature(String)
    /// Another player's land, as last seen.
    case owned(by: PlayerID)
    /// Closer than `minimum` tiles to a city the player knows (the nearest, ties: lower id).
    case tooClose(to: CityID, name: String, minimum: Int)
}

extension PlayerView {
    /// Why this player could not found a city on a tile, by its knowledge (the rules of
    /// `canFoundCity`, the first that fails), for the tile sheet; nil when it could.
    public func foundingProblem(at hex: HexCoord) -> FoundingProblem? {
        guard let hex = normalize(hex), let t = index(of: hex) else { return .offMap }
        guard me.explored[t] else { return .unexplored }
        let tile = state.map.tiles[t]
        if tile.terrain.isWater { return .water }
        if !rules.elevation(tile.elevation).passable { return .mountains }
        let feature = rules.feature(tile.feature)
        if !feature.passable || !feature.allowsCity { return .feature(feature.name) }
        if let owner = knownOwner(at: hex), owner != player { return .owned(by: owner) }
        let minimum = rules.constants.city.minDistance
        let near = me.memory.cities.filter { distance($0.position, hex) < minimum }
        if let city = near.min(by: { (distance($0.position, hex), $0.id.rawValue) < (distance($1.position, hex), $1.id.rawValue) }) {
            return .tooClose(to: city.id, name: city.name, minimum: minimum)
        }
        return nil
    }
}

/// A city site's quality, as the tile sheet names it and the settler overlay shades it.
public enum SiteQuality: String, Hashable, Sendable {
    case poor, fair, good
}

/// One place where a player could found a city, with its `settleScore`.
public struct SiteScore: Hashable, Sendable {
    public var tile: Int
    public var score: Int
}

/// The sites where a player could found a city around a centre (a Settler), ranked against each
/// other (M1 §16 settler overlay): good in the top quarter of them, poor in the bottom quarter,
/// fair between, equal scores sharing their rank. So the overlay picks out the best ground
/// nearby, wherever the Settler stands, instead of gilding every passable site.
public struct SiteRanking: Hashable, Sendable {
    /// The sites, in tile order.
    public let sites: [SiteScore]
    /// Their scores, ascending.
    private let ascending: [Int]

    public init(sites: [SiteScore]) {
        self.sites = sites
        ascending = sites.map(\.score).sorted()
    }

    /// Where `score` stands among the sites, per mille: the share of them below it, ties
    /// counting half (500 when it is the only one, or there are none).
    public func standing(of score: Int) -> Int {
        guard !ascending.isEmpty else { return 500 }
        let below = firstIndex { $0 >= score }
        let equal = firstIndex { $0 > score } - below
        return (2 * below + equal) * 1000 / (2 * ascending.count)
    }

    public func quality(of score: Int) -> SiteQuality {
        let q = standing(of: score)
        return q >= 750 ? .good : (q < 250 ? .poor : .fair)
    }

    /// The overlay's shade for `score`, 1 (dimmest) to 7 (brightest gilt): poor sites 1–3, fair
    /// ones 4–5, good ones 6–7, graded by their standing within the tier.
    public func shade(of score: Int) -> Int {
        let q = standing(of: score)
        if q < 250 { return 1 + q * 3 / 250 }
        if q < 750 { return 4 + (q - 250) * 2 / 500 }
        return q < 875 ? 6 : 7
    }

    /// The number of sorted scores before the first that satisfies `isAfter` (a binary search).
    private func firstIndex(_ isAfter: (Int) -> Bool) -> Int {
        var low = 0, high = ascending.count
        while low < high {
            let mid = (low + high) / 2
            if isAfter(ascending[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

/// What `settleScore` counts for a site (M1 §16 tile sheet, "Within 2: 14 Food, 9 Production"):
/// the yields of the explored tiles within the settle radius that are unowned or own as last
/// seen and workable, and the bonuses it adds.
public struct SiteFacts: Hashable, Sendable {
    public var yields: Yields
    /// The settle radius the yields are counted within.
    public var radius: Int
    /// Tiles within the radius not explored yet (they count nothing).
    public var unexplored: Int
    public var freshWater: Bool
    public var coast: Bool
    public var hills: Bool
}

extension PlayerView {
    /// The sites within `radius` of `center` where this player could found a city, by their
    /// `settleScore`, for the settler overlay and the tile sheet.
    public func siteRanking(around center: HexCoord, radius: Int) -> SiteRanking {
        var sites: [SiteScore] = []
        for hex in coords(within: radius, of: center) {
            guard let t = index(of: hex) else { continue }
            let score = settleScore(at: hex)
            if score > 0 { sites.append(SiteScore(tile: t, score: score)) }
        }
        sites.sort { $0.tile < $1.tile }
        return SiteRanking(sites: sites)
    }

    /// What `settleScore` counts at a site where this player could found a city (nil
    /// elsewhere): the same tiles, yields and bonuses.
    public func siteFacts(at hex: HexCoord) -> SiteFacts? {
        guard canFoundCity(at: hex), let centre = index(of: hex) else { return nil }
        let s = rules.constants.settle
        let known = me.knownTechs
        let knows: (TechID) -> Bool = { known.contains($0) }
        let mine = UInt8(player.rawValue + 1)
        var total = Yields()
        var unexplored = 0
        state.map.forEachIndex(within: s.radius, of: coord(at: centre)) { t in
            guard me.explored[t] else {
                unexplored += 1
                return
            }
            let owner = me.memory.tileOwner[t]
            guard owner == 0 || owner == mine else { return }
            var tile = state.map.tiles[t]
            guard rules.isWorkable(tile) else { return }
            tile.improvement = Improvement(rawValue: me.memory.tileImprovement[t])
            let y = rules.tileYields(tile, knows: knows, isCityCentre: t == centre)
            total.food += y.food
            total.production += y.production
            total.gold += y.gold
        }
        let tile = state.map.tiles[centre]
        var lake = false, coast = false
        state.map.forEachNeighbor(of: centre) { n, _ in
            guard me.explored[n] else { return }
            if state.map.tiles[n].terrain == .lake { lake = true }
            if state.map.tiles[n].terrain == .coast { coast = true }
        }
        return SiteFacts(yields: total, radius: s.radius, unexplored: unexplored, freshWater: tile.riverEdges != 0 || lake,
                         coast: coast, hills: tile.elevation == .hills)
    }
}

// MARK: - Builders' work (M1 §7.2, §16)

/// Where an improvement could go near a player's cities, as it knows the tiles: for the tech
/// panel ("Pasture: 2 on your land, 13 more as borders grow"). Tiles the improvement's sites in
/// the rules allow, explored, with no improvement as last seen. On own land (no city centre):
/// where the player's Builders may work (`builderJobs`, reach and tech aside), by the city whose
/// land it is. Unclaimed (nobody's as last seen) within an own city's work radius: sites once
/// borders grow, each counted once; another player's land never counts.
public struct ImprovementSites: Hashable, Sendable {
    public struct CityCount: Hashable, Sendable {
        public var city: CityID
        public var name: String
        public var count: Int
    }

    public var improvement: Improvement
    /// Own cities with such tiles on their land, the most first (ties: the lower id).
    public var cities: [CityCount]
    /// Unclaimed tiles within an own city's work radius where it could go once borders grow.
    public var unclaimed: Int
    /// Every site of the improvement is on hills (the tech panel says "hills", not "sites").
    public var onHillsOnly: Bool

    /// The sites on own land.
    public var ownLand: Int { cities.reduce(0) { $0 + $1.count } }
}

/// A tile where an own Builder could work now (M1 §7.2): its owner's land, explored, with no
/// improvement as last seen and no city centre, where an improvement whose tech is known could
/// go, and that the Builder can reach and stop on (by its owner's knowledge).
public struct BuilderJob: Hashable, Sendable {
    public var hex: HexCoord
    public var tile: Int
    /// What it could build there, in rules order.
    public var improvements: [Improvement]
    /// Movement points to get there and stop (0 where it stands), the points left unused at the
    /// ends of turns on the way included.
    public var cost: Int
    /// It could start the job this phase: there with moves left, or reaching it with a move to
    /// spare (building needs one).
    public var thisPhase: Bool
}

extension PlayerView {
    /// The tiles near this player's cities where `improvement` could go: on own land by city,
    /// and unclaimed (`ImprovementSites`). The tech it needs is not asked for.
    public func improvementSites(_ improvement: Improvement) -> ImprovementSites {
        let own = cities.sorted { $0.id.rawValue < $1.id.rawValue }
        let radius = rules.constants.city.workRadius
        func allowed(_ t: Int) -> Bool {
            me.explored[t] && me.memory.tileImprovement[t] == 0 && rules.allowsImprovement(improvement, on: state.map.tiles[t])
        }
        // Own land (always in sight), wherever its city's borders reach, never a city centre.
        var slot = [Int](repeating: -1, count: (own.last?.id.rawValue ?? -1) + 1)
        for (i, city) in own.enumerated() { slot[city.id.rawValue] = i }
        var counts = [Int](repeating: 0, count: own.count)
        for t in 0..<tileCount {
            let code = Int(state.tileCity[t]) - 1
            guard code >= 0, code < slot.count, slot[code] >= 0, allowed(t), state.city(atTile: t) == nil else { continue }
            counts[slot[code]] += 1
        }
        // Unclaimed as last seen, within an own city's work radius: counted once.
        var unclaimed = [Bool](repeating: false, count: tileCount)
        for city in own {
            state.map.forEachIndex(within: radius, of: city.position) { t in
                if me.memory.tileOwner[t] == 0, allowed(t) { unclaimed[t] = true }
            }
        }
        let found = own.indices.filter { counts[$0] > 0 }
            .map { ImprovementSites.CityCount(city: own[$0].id, name: own[$0].name, count: counts[$0]) }
            .sorted { ($1.count, $0.city.rawValue) < ($0.count, $1.city.rawValue) }
        let hillsOnly = rules.improvement(improvement).sites.allSatisfy { $0.elevations == ["hills"] }
        return ImprovementSites(improvement: improvement, cities: found, unclaimed: unclaimed.reduce(0) { $0 + ($1 ? 1 : 0) },
                                onHillsOnly: hillsOnly)
    }

    /// `improvementSites` for each improvement `tech` unlocks (in rules order).
    public func improvementSites(unlockedBy tech: TechID) -> [ImprovementSites] {
        Improvement.allCases.filter { rules.improvement($0).tech == tech }.map { improvementSites($0) }
    }

    /// Where an own Builder could work now (`BuilderJob`), in tile order; empty for any other
    /// unit.
    public func builderJobs(for id: UnitID) -> [BuilderJob] {
        guard let unit = state.unit(id), unit.owner == player, unit.charges > 0, let start = index(of: unit.position) else { return [] }
        let known = Improvement.allCases.filter { rules.improvement($0).tech.map(me.knows) ?? true }
        guard !known.isEmpty else { return [] }
        let movesLeft = unit.zocStopped ? 0 : unit.movesLeft
        let field = Pathfinder.movementField(MoveKnowledge(state: state, unit: unit), from: start, movesLeft: movesLeft,
                                             maxMoves: rules.unit(unit.type).moves)
        var jobs: [BuilderJob] = []
        for t in 0..<tileCount where field[t] >= 0 {
            guard state.owningCity(ofTile: t)?.owner == player, me.explored[t], me.memory.tileImprovement[t] == 0,
                  state.city(atTile: t) == nil else { continue }
            let tile = state.map.tiles[t]
            let kinds = known.filter { rules.allowsImprovement($0, on: tile) }
            guard !kinds.isEmpty else { continue }
            let cost = Int(field[t])
            jobs.append(BuilderJob(hex: coord(at: t), tile: t, improvements: kinds, cost: cost, thisPhase: cost < movesLeft))
        }
        return jobs
    }
}
