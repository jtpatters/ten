/// Quarters (M2 §5.3): placement, cap, adjacency.
extension GameState {
    /// The quarter on tile `t`: its city's index and its index in the city's quarters.
    func quarter(atTile t: Int) -> (city: Int, quarter: Int)? {
        let code = tileCity[t]
        guard code > 0, let i = cityIndex(CityID(Int(code) - 1)) else { return nil }
        let hex = map.coord(at: t)
        guard let q = cities[i].quarters?.firstIndex(where: { $0.tile == hex }) else { return nil }
        return (i, q)
    }

    public func isQuarterTile(_ t: Int) -> Bool { quarter(atTile: t) != nil }

    /// The city's quarter of `kind`, if built.
    public func quarter(_ kind: QuarterKind, of city: City) -> CityQuarter? {
        city.quarters?.first { $0.kind == kind }
    }

    /// At most this many quarters (cap-exempt kinds aside) in `city`.
    public func quarterCap(of city: City) -> Int {
        1 + city.population / max(1, rules.quarters?.populationPerQuarter ?? 3)
    }

    func countsTowardCap(_ kind: QuarterKind) -> Bool { rules.quarter(kind)?.capExempt != true }

    /// Built quarters counted in the cap.
    func cappedQuarterCount(_ city: City) -> Int {
        (city.quarters ?? []).filter { countsTowardCap($0.kind) }.count
    }

    /// A quarter's cost now: fixed at this when queued.
    public func quarterCost(_ kind: QuarterKind) -> Int { rules.quarterCost(kind, worldEra: worldEra ?? 0) }

    /// Why `city` may not have a quarter of `kind` (ignoring the tile): the rules, the tech, the
    /// civic, one per kind, the cap.
    func quarterKindProblem(_ kind: QuarterKind, in city: City) -> String? {
        guard let def = rules.quarter(kind) else { return "no such quarter" }
        if quarter(kind, of: city) != nil { return "already built" }
        if let tech = def.tech, !players[city.owner.rawValue].knows(tech) { return "needs \(techName(tech))" }
        if let civic = def.civic.map({ CivicID($0) }), !players[city.owner.rawValue].knowsCivic(civic) {
            return "needs \(rules.civic(civic)?.name ?? "a civic")"
        }
        if countsTowardCap(kind), cappedQuarterCount(city) >= quarterCap(of: city) {
            return "needs population \(quarterCap(of: city) * (rules.quarters?.populationPerQuarter ?? 3))"
        }
        return nil
    }

    /// Why a quarter of `kind` may not stand on `hex` for `city` (M2 §5.3).
    public func quarterSiteProblem(_ kind: QuarterKind, at hex: HexCoord, in city: City) -> String? {
        guard let q = rules.quarters, let def = rules.quarter(kind) else { return "no such quarter" }
        guard let t = map.index(of: hex) else { return "off the map" }
        let centre = map.index(of: city.position)!
        let code = Int32(city.id.rawValue + 1)
        if t == centre { return "not on the city centre" }
        if map.distance(index: t, centre) > q.radius { return "more than \(q.radius) tiles from the city" }
        if tileCity[t] != code { return "not in the city's territory" }
        if isQuarterTile(t) { return "a quarter stands there" }
        let tile = map.tiles[t]
        if tile.elevation == .mountains || tile.feature == .ice { return "not on mountains or ice" }
        if let r = knownResource(at: t, for: city.owner), rules.resource(r)?.kind != .bonus {
            return "not on a strategic or luxury resource"
        }
        if holdsTribalVillage(t) { return "not on a tribal village" }
        switch def.placement {
        case "water":
            guard tile.terrain == .coast || tile.terrain == .lake else { return "needs Coast or Lake" }
            var land = false
            map.forEachNeighbor(of: t) { n, _ in
                if !map.tiles[n].terrain.isWater, tileCity[n] == code { land = true }
            }
            if !land { return "needs the city's land next to it" }
            return nil
        case "centreFreshWater":
            if map.distance(index: t, centre) != 1 { return "must touch the city centre" }
            var mountain = false
            map.forEachNeighbor(of: t) { n, _ in if map.tiles[n].elevation == .mountains { mountain = true } }
            if !hasFreshWater(t), !mountain { return "needs a river, lake or mountain" }
        case "notNextToCentre":
            if map.distance(index: t, centre) <= 1 { return "not next to the city centre" }
        default: break
        }
        if tile.terrain.isWater { return "not on water" }
        return nil
    }

    /// A quarter's adjacency bonus on tile `t` for `owner`'s city with centre `centre`: the
    /// halves summed, then rounded down. `extra`: a tile counted as a quarter of that kind
    /// (a placement preview).
    public func quarterAdjacency(_ kind: QuarterKind, at t: Int, owner: PlayerID, centre: Int,
                                 extra: (tile: Int, kind: QuarterKind)? = nil) -> Int {
        guard let def = rules.quarter(kind) else { return 0 }
        func quarterKind(at n: Int) -> QuarterKind? {
            if let e = extra, e.tile == n { return e.kind }
            guard let (i, q) = quarter(atTile: n), cities[i].owner == owner else { return nil }
            return cities[i].quarters![q].kind
        }
        var halves = 0
        for a in def.adjacency {
            let targets = a.targets ?? []
            if a.kind == "river" {
                if map.tiles[t].riverEdges != 0 { halves += a.halves }
                continue
            }
            map.forEachNeighbor(of: t) { n, _ in
                let tile = map.tiles[n]
                let match: Bool = switch a.kind {
                case "mountain": tile.elevation == .mountains
                case "feature": targets.contains(caseName(tile.feature))
                case "improvement": tile.improvement.map { !tile.isPillaged && targets.contains(caseName($0)) } ?? false
                case "quarter": quarterKind(at: n) != nil
                case "quarterKind": quarterKind(at: n).map { targets.contains($0.rawValue) } ?? false
                case "seaResource": tile.terrain.isWater && knownResource(at: n, for: owner) != nil
                case "cityCentre": n == centre
                default: false
                }
                if match { halves += a.halves }
            }
        }
        let doubled = bonuses(of: owner).contains { $0.adjacencyDouble?.contains(kind.rawValue) == true }
        return halves / 2 * (doubled ? 2 : 1)
    }

    /// A specialist's yields in a quarter of `kind` (M2 §5.3): +2 of the quarter's yield;
    /// Barracks +1 Production +1 Gold, Arena +1 Culture +1 Gold.
    public func specialistYields(_ kind: QuarterKind) -> Yields {
        switch rules.quarter(kind)?.yield {
        case "science": Yields(science: 2)
        case "gold": Yields(gold: 2)
        case "production": Yields(production: 2)
        case "culture": Yields(culture: 2)
        case "food": Yields(food: 2)
        default:
            switch kind.rawValue {
            case "barracks": Yields(production: 1, gold: 1)
            case "arena": Yields(gold: 1, culture: 1)
            default: .zero
            }
        }
    }

    /// The city's specialist slots (M2 §5.3): one per building in each unpillaged quarter, in
    /// build order.
    public func specialistSlots(_ city: City) -> [QuarterKind] {
        guard let quarters = city.quarters else { return [] }
        return quarters.flatMap { q -> [QuarterKind] in
            guard !q.isPillaged else { return [] }
            let n = city.buildings.count { rules.building($0)?.quarter == q.kind }
            return [QuarterKind](repeating: q.kind, count: n)
        }
    }

    /// The city's specialists that still have a slot (a slot lost since citizens were last
    /// assigned yields nothing).
    func activeSpecialists(_ city: City) -> [QuarterKind] {
        var slots = specialistSlots(city)
        return (city.specialists ?? []).filter { kind in
            guard let i = slots.firstIndex(of: kind) else { return false }
            slots.remove(at: i)
            return true
        }
    }

    /// The adjacency yields of a city's quarters (pillaged ones give none).
    func quarterYields(_ city: City) -> [(QuarterKind, Yields)] {
        guard let quarters = city.quarters else { return [] }
        let centre = map.index(of: city.position)!
        return quarters.compactMap { q in
            guard !q.isPillaged, let def = rules.quarter(q.kind), let y = def.yield else { return nil }
            let n = quarterAdjacency(q.kind, at: map.index(of: q.tile)!, owner: city.owner, centre: centre)
            guard n > 0 else { return nil }
            let yields: Yields = switch y {
            case "science": Yields(science: n)
            case "gold": Yields(gold: n)
            case "production": Yields(production: n)
            case "culture": Yields(culture: n)
            case "food": Yields(food: n)
            default: .zero
            }
            return yields.isZero ? nil : (q.kind, yields)
        }
    }

    /// Where `city` may place a quarter of `kind`, best first: highest adjacency, then the least
    /// tile yield lost, then nearest the centre, then lower tile index. Tiles queued for another
    /// quarter in the city are left out. Empty when the city may not have the kind.
    public func quarterSites(_ kind: QuarterKind, in city: City) -> [(tile: HexCoord, adjacency: Int)] {
        guard quarterKindProblem(kind, in: city) == nil, let q = rules.quarters else { return [] }
        let centre = map.index(of: city.position)!
        let queued = Set(city.queue.compactMap { e -> HexCoord? in
            if case let .quarter(_, at) = e.item { return at }
            return nil
        })
        var seen = Set<Int>()
        var sites: [(tile: Int, adjacency: Int, lost: Int, distance: Int)] = []
        map.forEachIndex(within: q.radius, of: city.position) { t in
            guard seen.insert(t).inserted else { return }
            let hex = map.coord(at: t)
            guard !queued.contains(hex), quarterSiteProblem(kind, at: hex, in: city) == nil else { return }
            let y = tileYields(t, for: city.owner)
            sites.append((t, quarterAdjacency(kind, at: t, owner: city.owner, centre: centre),
                          y.food + y.production + y.gold + y.science + y.culture, map.distance(index: t, centre)))
        }
        sites.sort { a, b in
            if a.adjacency != b.adjacency { return a.adjacency > b.adjacency }
            if a.lost != b.lost { return a.lost < b.lost }
            if a.distance != b.distance { return a.distance < b.distance }
            return a.tile < b.tile
        }
        return sites.map { (map.coord(at: $0.tile), $0.adjacency) }
    }

    /// Builds a quarter (validated by the caller): the tile loses its improvement and its worker.
    mutating func buildQuarter(_ kind: QuarterKind, at hex: HexCoord, inCity index: Int, _ fx: inout Effects) {
        let t = map.index(of: hex)!
        cities[index].quarters = (cities[index].quarters ?? []) + [CityQuarter(kind: kind, tile: hex)]
        map[index: t].improvement = nil
        map[index: t].pillaged = map.tiles[t].hasRoad ? map.tiles[t].pillaged : nil
        fx.touchTile(t)
        fx.touchTile(map.index(of: cities[index].position)!)
        assignCitizens(index)
    }
}
