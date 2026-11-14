// Roads and pillage (M2 §3.3).
//
// A road is a tile flag beside any improvement. A Builder lays one where it stands (The Wheel;
// all moves, no charge). A military unit at war pillages the foreign tile it stands on (all
// moves): an improvement there becomes pillaged (no yields, not a stockpile source) and gives
// it Gold, or heals it when wounded; with none left to pillage, the road goes. The owner's
// Builder repairs a pillaged improvement for one charge (`buildImprovement` of the same kind).

extension GameState {
    /// Why `unit` may not build a road where it stands (nil: it may).
    func roadProblem(_ unit: Unit) -> String? {
        guard let roads = rules.roads else { return "no roads" }
        guard rules.unit(unit.type).charges > 0 else { return "only Builders build roads" }
        guard unit.movesLeft > 0 else { return "no moves left" }
        let t = map.index(of: unit.position)!
        guard map.tiles[t].isLand, rules.isPassable(map.tiles[t]) else { return "no road here" }
        guard !map.tiles[t].hasRoad else { return "tile already has a road" }
        if let owner = tileOwner(t), owner != unit.owner { return "not in foreign territory" }
        guard players[unit.owner.rawValue].knows(roads.tech) else { return "needs \(techName(roads.tech))" }
        return nil
    }

    /// Builds a road (validated by the caller): all moves, no charge.
    mutating func buildRoad(by id: UnitID, _ fx: inout Effects) {
        guard let unit = unit(id) else { return }
        let t = map.index(of: unit.position)!
        layRoad(t)
        updateUnit(id) { u in
            u.movesLeft = 0
            u.activity = .none
            u.destination = nil
        }
        fx.touchTile(t)
        fx.emit(.roadBuilt(at: unit.position, owner: unit.owner), .tiles([t]))
    }

    /// Puts a road on land tile `t` (Builders, and later trade routes and Rome, M2 §13, §15).
    mutating func layRoad(_ t: Int) {
        guard map.tiles[t].isLand, !map.tiles[t].hasRoad else { return }
        map[index: t].road = true
    }

    /// Why `unit` may not pillage where it stands (nil: it may).
    func pillageProblem(_ unit: Unit) -> String? {
        guard rules.roads != nil else { return "no pillaging" }
        guard rules.unit(unit.type).isMilitary else { return "only military units pillage" }
        guard unit.movesLeft > 0 else { return "no moves left" }
        let t = map.index(of: unit.position)!
        guard let owner = tileOwner(t), owner != unit.owner, isAtWar(unit.owner, owner) else {
            return "only tiles of a player you are at war with"
        }
        guard city(atTile: t) == nil else { return "not on a city centre" }
        let tile = map.tiles[t]
        guard (tile.improvement != nil && !tile.isPillaged) || tile.hasRoad else { return "nothing to pillage" }
        return nil
    }

    /// Pillages (validated by the caller): the improvement if there is one standing (Gold, or
    /// HP when wounded), else the road. All moves.
    mutating func pillage(by id: UnitID, _ fx: inout Effects) {
        guard let unit = unit(id), let roads = rules.roads else { return }
        let t = map.index(of: unit.position)!
        let tile = map.tiles[t]
        let owner = tileOwner(t)
        var gold = 0, healed = 0
        var improvement: Improvement?
        if let i = tile.improvement, !tile.isPillaged {
            improvement = i
            map[index: t].pillaged = true
            let maxHP = rules.constants.healing.maxHP
            let pct = 100 + bonus(\.pillageBonusPct, for: unit.owner)
            if unit.hp < maxHP {
                healed = min(roads.pillageHeal * pct / 100, maxHP - unit.hp)
            } else {
                gold = roads.pillageGold * pct / 100
                players[unit.owner.rawValue].gold += gold
                fx.touchPlayer(unit.owner)
            }
        } else {
            map[index: t].road = nil
        }
        updateUnit(id) { u in
            u.hp += healed
            u.movesLeft = 0
            u.activity = .none
            u.destination = nil
        }
        fx.touchTile(t)
        fx.emit(.tilePillaged(at: unit.position, unit: id, by: unit.owner, owner: owner, improvement: improvement, gold: gold, healed: healed),
                .tiles([t]))
        if improvement != nil, let city = owningCity(ofTile: t), let index = cityIndex(city.id) { assignCitizens(index) }
    }
}
