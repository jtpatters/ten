// Embarking and naval units (M2 §8.4).
//
// A land unit on a water tile is embarked (derived, not stored): with the coast tech it may
// enter Coast and Lake, with the ocean tech Ocean too. Stepping from land onto water costs all
// remaining moves, a step on water a third of its full moves (3 per phase), stepping back onto
// land one move. Embarked units cannot attack, defend with a fixed strength, exert no zone of
// control and see `embark.sight`. Naval units move only on water (Ocean needs the ocean tech)
// and through own city centres, one move per step; they exert zones of control on water only,
// land units on land only. Naval melee never takes cities; land melee never attacks water.

/// Which tiles a unit of some type may be on, for one player (M2 §8.4).
struct Mobility: Hashable, Sendable {
    let naval: Bool
    let coast: Bool
    let ocean: Bool

    /// On `tile` (`ownCity`: an own city centre stands there).
    @inline(__always)
    func allows(_ tile: Tile, ownCity: Bool, rules: Ruleset) -> Bool {
        if tile.terrain.isWater { return tile.terrain == .ocean ? ocean : coast }
        return naval ? ownCity : rules.isPassable(tile)
    }
}

extension GameState {
    func mobility(_ type: UnitType, owner: PlayerID) -> Mobility {
        let naval = type.isNaval
        guard let e = rules.embark else { return Mobility(naval: naval, coast: naval, ocean: false) }
        let player = players[owner.rawValue]
        return Mobility(naval: naval, coast: naval || player.knows(e.coastTech), ocean: player.knows(e.oceanTech))
    }

    /// Whether a unit of `type` for `owner` may be on tile `t` at all (terrain only).
    func terrainAllows(_ t: Int, _ type: UnitType, owner: PlayerID) -> Bool {
        let ownCity = type.isNaval && city(atTile: t)?.owner == owner
        return mobility(type, owner: owner).allows(map.tiles[t], ownCity: ownCity, rules: rules)
    }

    /// A land unit on water.
    public func isEmbarked(_ unit: Unit) -> Bool {
        !unit.type.isNaval && map.index(of: unit.position).map { map.tiles[$0].terrain.isWater } ?? false
    }

    /// Whether military unit `u` standing on `from` holds neighbour `to` in its zone of control.
    func zocReaches(_ u: Unit, from: Int, to: Int) -> Bool {
        Self.zocReaches(naval: u.type.isNaval, fromWater: map.tiles[from].terrain.isWater, toWater: map.tiles[to].terrain.isWater)
    }

    @inline(__always)
    static func zocReaches(naval: Bool, fromWater: Bool, toWater: Bool) -> Bool {
        naval ? toWater : !fromWater && !toWater
    }

    /// Move points for a step of a unit (`naval`, full moves `maxMoves`) between neighbouring
    /// tiles by water kind, or nil for an ordinary land step.
    @inline(__always)
    static func embarkStep(naval: Bool, fromWater: Bool, toWater: Bool, maxMoves: Int, rules: Ruleset) -> Int? {
        if naval { return rules.movePoints }
        guard fromWater || toWater, let e = rules.embark else { return nil }
        if !fromWater { return max(maxMoves, 1) * 4 } // all remaining moves
        if !toWater { return rules.movePoints }
        return max(1, maxMoves / max(1, e.moves))
    }

    /// Whether `city` may build naval units: it is next to Coast or Lake.
    func isCoastal(_ city: City) -> Bool {
        guard let t = map.index(of: city.position) else { return false }
        var coastal = false
        map.forEachNeighbor(of: t) { n, _ in
            let terrain = map.tiles[n].terrain
            if terrain == .coast || terrain == .lake { coastal = true }
        }
        return coastal
    }
}
