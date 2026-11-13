// Read-only queries for the App's info cards (M1 §16), built only from what the player knows.

extension PlayerView {
    /// City Strength (M1 §5) of the known city on a tile, as the player can judge it (the
    /// foreign city's info card, M1 §16): an own city live; a foreign city from its sighting
    /// (population and walls as last seen), with the hills from the map and a garrison only
    /// when the player sees the tile now. Nil where the player knows no city.
    public func knownCityStrength(at hex: HexCoord) -> Strength? {
        guard let sighting = knownCity(at: hex), let t = index(of: sighting.position) else { return nil }
        if let city = state.city(sighting.id), city.owner == player {
            return state.cityStrength(city, sees: { _ in true })
        }
        let c = rules.constants.city
        var s = Strength(base: c.strengthBase)
        s.add(.population, c.strengthPerPopulation * sighting.population)
        if sighting.walls, sighting.wallHP > 0 {
            s.add(.walls, rules.buildings.filter { $0.wallHP > 0 }.map(\.cityStrength).max() ?? 0)
        }
        s.add(.hills, rules.elevation(state.map.tiles[t].elevation).cityStrength)
        if me.visible[t],
           state.units.contains(where: { $0.position == sighting.position && $0.owner == sighting.owner && !$0.type.isCivilian }) {
            s.add(.garrison, c.garrisonStrength)
        }
        return s
    }

    /// The Strength a unit defending on a tile gains from it (elevation and feature, M1 §8.1);
    /// nil for an unexplored tile.
    public func tileDefenseModifier(at hex: HexCoord) -> Int? {
        guard let tile = tile(at: hex) else { return nil }
        return rules.elevation(tile.elevation).defense + rules.feature(tile.feature).defense
    }

    /// The owner of a tile as last seen (nil: none, or unexplored).
    public func knownOwner(at hex: HexCoord) -> PlayerID? {
        guard let t = index(of: hex), me.explored[t] else { return nil }
        let owner = me.memory.tileOwner[t]
        return owner == 0 ? nil : PlayerID(Int(owner) - 1)
    }
}
