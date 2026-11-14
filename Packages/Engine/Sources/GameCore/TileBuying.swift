// Buying tiles (M2 §7.4).

extension GameState {
    /// What `city`'s next tile costs; nil when the rules have no tile buying.
    public func tilePrice(for city: City) -> Int? {
        guard let t = rules.tileBuying else { return nil }
        return t.base + t.perTile * (city.tilesBought ?? 0)
    }

    /// Why `city` cannot buy `tile` (nil: it can, given the Gold): the tile must be unowned,
    /// within the radius of the centre and touch the city's territory.
    public func tilePurchaseProblem(_ tile: HexCoord, for city: City) -> String? {
        guard let rules = rules.tileBuying else { return "tiles cannot be bought" }
        guard let t = map.index(of: tile) else { return "off the map" }
        guard tileCity[t] == 0 else { return "already owned" }
        guard map.distance(index: t, map.index(of: city.position)!) <= rules.radius else { return "too far from \(city.name)" }
        let code = Int32(city.id.rawValue + 1)
        var touches = false
        map.forEachNeighbor(of: t) { n, _ in if tileCity[n] == code { touches = true } }
        return touches ? nil : "not next to \(city.name)'s territory"
    }

    /// The tiles `city` could buy, in index order.
    public func purchasableTiles(for city: City) -> [HexCoord] {
        guard let rules = rules.tileBuying else { return [] }
        var tiles: [Int] = []
        map.forEachIndex(within: rules.radius, of: city.position) { t in
            if tilePurchaseProblem(map.coord(at: t), for: city) == nil { tiles.append(t) }
        }
        return tiles.sorted().map { map.coord(at: $0) }
    }

    /// Buys `tile` for `cities[index]` (validated by the caller), as a border claim: a tribal
    /// village on it goes to the owner.
    mutating func purchaseTile(_ tile: HexCoord, inCity index: Int, _ fx: inout Effects) {
        let city = cities[index]
        let t = map.index(of: tile)!
        players[city.owner.rawValue].gold -= tilePrice(for: city)!
        cities[index].tilesBought = (city.tilesBought ?? 0) + 1
        tileCity[t] = Int32(city.id.rawValue + 1)
        fx.touchTile(t)
        fx.touchPlayer(city.owner)
        fx.emit(.borderGrew(city: city.id, tile: tile), .tiles([t]))
        if holdsTribalVillage(t) { takeTribalVillage(at: t, by: city.owner, unit: nil, city: city.id, &fx) }
        assignCitizens(index)
    }
}
