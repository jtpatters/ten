// Tiles, yields and citizens (M1 §4).

/// Where a city's yields come from (`CityYields.breakdown`).
public enum YieldSource: Hashable, Sendable {
    /// The city centre tile, with its minimums and the centre bonus.
    case centre
    /// The tiles the citizens work.
    case workedTiles
    /// Citizens with no tile to work.
    case unemployed
    /// +1 Science per `populationPerScience` citizens.
    case population
    case building(BuildingID)
    /// The city's Stability state (M2 §5.2): a percentage of every yield but Food.
    case stability
    /// A quarter's adjacency bonus (M2 §5.3).
    case quarter(QuarterKind)
}

/// A city's yields this phase with their sources (M1 §12.6).
public struct CityYields: Hashable, Sendable {
    public var total: Yields
    /// Non-zero sources, in a fixed order: centre, worked tiles, unemployed, population,
    /// buildings by id.
    public var breakdown: [(source: YieldSource, yields: Yields)]
    /// Food the citizens eat.
    public var foodEaten: Int
    /// Percent of a positive surplus that goes into the store (Housing and Stability, M2 §5.1).
    public var growthPct = 100
    /// Food left after the citizens eat.
    public var rawFoodSurplus: Int { total.food - foodEaten }
    /// Food into (or out of) the store: a positive surplus scaled by `growthPct`.
    public var foodSurplus: Int { rawFoodSurplus > 0 ? rawFoodSurplus * growthPct / 100 : rawFoodSurplus }

    public static func == (a: CityYields, b: CityYields) -> Bool {
        a.total == b.total && a.foodEaten == b.foodEaten && a.growthPct == b.growthPct && a.breakdown.count == b.breakdown.count
            && zip(a.breakdown, b.breakdown).allSatisfy { $0.source == $1.source && $0.yields == $1.yields }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(total)
        hasher.combine(foodEaten)
    }
}

extension Ruleset {
    /// The yields of a tile for a player who knows `techs` (M1 §4). `isCityCentre`: the centre
    /// yields the tile "without feature" (M1 §4 City centre: no forest, jungle or marsh, and no
    /// Floodplain Food either; Oasis, Reef and Ice never carry a city), has no improvement, and
    /// gets the centre minimums and bonus. `touchesLake`: a lake is next to it (fresh water).
    public func tileYields(_ tile: Tile, knows techs: (TechID) -> Bool, isCityCentre: Bool = false,
                           touchesLake: Bool = false) -> Yields {
        let t = terrain(tile.terrain), e = elevation(tile.elevation), f = feature(tile.feature)
        var y = Yields(food: t.food + e.food, production: t.production + e.production, gold: t.gold + e.gold)
        for bonus in t.techBonuses where techs(bonus.tech) {
            y.food += bonus.food
            y.production += bonus.production
            y.gold += bonus.gold
        }
        // M1 §4: "City centre: the tile's yields (without feature)" — every feature's yields are
        // dropped on the centre, not only those of the features a city removes (§4 also says the
        // centre counts as having no forest, jungle or marsh, which this includes).
        if !isCityCentre {
            y.food += f.food
            y.production += f.production
            y.gold += f.gold
        }
        if tile.riverEdges != 0 { y.gold += river.gold }
        if !isCityCentre, !tile.isPillaged, let improvement = tile.improvement {
            let def = self.improvement(improvement)
            y.food += def.food
            y.production += def.production
            y.gold += def.gold
            if def.freshWaterFood > 0, def.freshWaterTech.map(techs) ?? true, tile.riverEdges != 0 || touchesLake {
                y.food += def.freshWaterFood
            }
            for bonus in def.techBonuses ?? [] where techs(bonus.tech) {
                y.food += bonus.food
                y.production += bonus.production
                y.gold += bonus.gold
            }
        }
        // M2 §3.1: a resource yields once revealed, improved or not.
        if let r = tile.resource, let def = resource(r), def.revealedBy.map(techs) ?? true {
            y.food += def.food
            y.production += def.production
            y.gold += def.gold
            y.culture += def.culture
        }
        if isCityCentre {
            let c = constants.city
            y.food = max(y.food, c.centreMinFood)
            y.production = max(y.production, c.centreMinProduction) + c.centreProduction
            y.science += c.centreScience
            y.culture += c.centreCulture
        }
        return y
    }
}

extension GameState {
    /// Whether tile `index` is next to a lake.
    func touchesLake(_ index: Int) -> Bool {
        var found = false
        map.forEachNeighbor(of: index) { n, _ in if map.tiles[n].terrain == .lake { found = true } }
        return found
    }

    /// Whether tile `index` has fresh water: a river edge, or a lake next to it.
    func hasFreshWater(_ index: Int) -> Bool {
        map.tiles[index].riverEdges != 0 || touchesLake(index)
    }

    /// The yields of tile `index` for its player `player` (live state: real improvement).
    func tileYields(_ index: Int, for player: PlayerID, isCityCentre: Bool = false) -> Yields {
        let known = players[player.rawValue].knownTechs
        return rules.tileYields(map.tiles[index], knows: { known.contains($0) }, isCityCentre: isCityCentre,
                                touchesLake: touchesLake(index))
    }

    /// A city's yields this phase, with their sources (M1 §4).
    public func cityYields(_ city: City) -> CityYields {
        let centreIndex = map.index(of: city.position)!
        var breakdown: [(YieldSource, Yields)] = []
        var centre = tileYields(centreIndex, for: city.owner, isCityCentre: true)
        // p3f experiment (core-young-city-production): a young city's extra Production, 0 by default.
        if city.population < rules.constants.city.youngCityPopulation { centre.production += rules.constants.city.youngCityProduction }
        breakdown.append((.centre, centre))
        var tiles = Yields.zero
        for hex in city.workedTiles { tiles += tileYields(map.index(of: hex)!, for: city.owner) }
        if !tiles.isZero { breakdown.append((.workedTiles, tiles)) }
        let c = rules.constants.city
        let unemployed = max(0, city.population - city.workedTiles.count)
        if unemployed > 0 { breakdown.append((.unemployed, Yields(production: unemployed * c.unemployedProduction))) }
        let science = city.population / c.populationPerScience
        if science > 0 { breakdown.append((.population, Yields(science: science))) }
        for id in city.buildings {
            if let def = rules.building(id), !def.yields.isZero { breakdown.append((.building(id), def.yields)) }
        }
        for (kind, yields) in quarterYields(city) { breakdown.append((.quarter(kind), yields)) }
        var total = breakdown.reduce(Yields.zero) { $0 + $1.1 }
        let pct = rules.stabilityYieldPct(rules.stabilityState(city.stability ?? 0))
        if pct != 0 {
            func scaled(_ v: Int) -> Int { max(0, v) * (100 + pct) / 100 - max(0, v) }
            let delta = Yields(production: scaled(total.production), gold: scaled(total.gold),
                               science: scaled(total.science), culture: scaled(total.culture))
            if !delta.isZero {
                breakdown.append((.stability, delta))
                total += delta
            }
        }
        return CityYields(total: total, breakdown: breakdown.map { (source: $0.0, yields: $0.1) },
                          foodEaten: city.population * rules.constants.growth.foodPerCitizen, growthPct: growthPct(of: city))
    }

    /// Food from the city's buildings.
    func buildingFood(_ city: City) -> Int {
        city.buildings.reduce(0) { $0 + (rules.building($1)?.food ?? 0) }
    }

    /// Assigns the city's citizens to tiles (M1 §4), one at a time. Each takes the free tile
    /// with the highest focus-weighted value among those that keep the food surplus (centre +
    /// tiles chosen so far + buildings − food eaten by the citizens so far, this one included)
    /// at or above the focus floor; when none does, the tile with the most Food (ties: weighted
    /// value, then distance, then tile index). Other ties: closer to the centre, then lower
    /// tile index. Free tiles: owned by this city within the work radius, workable, not the
    /// centre, no enemy unit on them, not worked by another city. Citizens without a tile are
    /// unemployed.
    mutating func assignCitizens(_ cityIndex: Int) {
        let city = cities[cityIndex]
        let focus = rules.focus(city.focus)
        let centreIndex = map.index(of: city.position)!
        let code = Int32(city.id.rawValue + 1)
        let eats = rules.constants.growth.foodPerCitizen
        let enemies = enemyUnitTiles(of: city.owner)

        struct Candidate { let tile: Int; let yields: Yields; let value: Int; let distance: Int }
        var candidates: [Candidate] = []
        map.forEachIndex(within: rules.constants.city.workRadius, of: city.position) { t in
            // A city works only tiles it owns, so no other city works these.
            guard t != centreIndex, tileCity[t] == code, rules.isWorkable(map.tiles[t]), !isQuarterTile(t), !enemies.contains(t),
                  !candidates.contains(where: { $0.tile == t }) else { return }
            let y = tileYields(t, for: city.owner)
            candidates.append(Candidate(tile: t, yields: y, value: focus.value(y), distance: map.distance(index: t, centreIndex)))
        }
        // Best first: value, then closer, then lower index.
        candidates.sort { a, b in
            if a.value != b.value { return a.value > b.value }
            if a.distance != b.distance { return a.distance < b.distance }
            return a.tile < b.tile
        }

        var food = tileYields(centreIndex, for: city.owner, isCityCentre: true).food + buildingFood(city)
        var chosen: [Int] = []
        var taken = [Bool](repeating: false, count: candidates.count)
        for citizen in stride(from: 1, through: city.population, by: 1) {
            var pick: Int?
            for (i, c) in candidates.enumerated() where !taken[i] && food + c.yields.food - eats * citizen >= focus.foodFloor {
                pick = i
                break
            }
            if pick == nil {
                // Most food; ties: weighted value, then distance, then index (the sort order).
                for (i, c) in candidates.enumerated() where !taken[i] {
                    if let p = pick, candidates[p].yields.food >= c.yields.food { continue }
                    pick = i
                }
            }
            guard let i = pick else { break } // no free tile: the rest are unemployed
            taken[i] = true
            chosen.append(candidates[i].tile)
            food += candidates[i].yields.food
        }
        cities[cityIndex].workedTiles = chosen.sorted().map { map.coord(at: $0) }
    }

    /// Tiles with a unit of a player `player` is at war with.
    func enemyUnitTiles(of player: PlayerID) -> [Int] {
        guard relations.contains(where: { $0.involves(player) && $0.stance == .war }) else { return [] }
        return units.compactMap { isAtWar(player, $0.owner) ? map.index(of: $0.position) : nil }
    }
}
