// Resources and strategic stockpiles (M2 §3.1).

extension GameState {
    /// The resource on tile `t` as `player` knows it: nil until its reveal tech.
    public func knownResource(at t: Int, for player: PlayerID) -> Resource? {
        guard let r = map.tiles[t].resource, let def = rules.resource(r) else { return nil }
        if let tech = def.revealedBy, !players[player.rawValue].knows(tech) { return nil }
        return r
    }

    /// The strategic resource a unit type needs, if any.
    public func resourceNeeded(by type: UnitType) -> Resource? {
        rules.unit(type).resource.flatMap { name in Resource.allCases.first { caseName($0) == name } }
    }

    /// The stockpile cap now: higher from the cap-bonus world era on.
    public var stockpileCap: Int {
        guard let s = rules.stockpile else { return 0 }
        return s.cap + ((worldEra ?? 0) >= s.capBonusEra ? s.capBonus : 0)
    }

    /// Whether tile `t` is an improved source of its resource for its owner.
    func isImprovedSource(_ t: Int) -> Bool {
        let tile = map.tiles[t]
        guard let owner = tileOwner(t), let r = knownResource(at: t, for: owner), let def = rules.resource(r),
              let improvement = tile.improvement, !tile.isPillaged else { return false }
        return caseName(improvement) == def.improvement
    }

    /// Improved sources `player` owns of each resource, in `Resource.allCases` order.
    public func improvedSources(of player: PlayerID) -> [Int] {
        var counts = [Int](repeating: 0, count: Resource.allCases.count)
        guard !rules.resources.isEmpty else { return counts }
        for t in map.tiles.indices where map.tiles[t].resource != nil && tileOwner(t) == player && isImprovedSource(t) {
            counts[Int(map.tiles[t].resource!.rawValue) - 1] += 1
        }
        return counts
    }

    /// Why `player` cannot field a unit of `type` now for want of its resource.
    func resourceProblem(_ type: UnitType, owner player: PlayerID) -> String? {
        guard let r = resourceNeeded(by: type), let s = rules.stockpile else { return nil }
        let have = players[player.rawValue].stock(r)
        return have >= s.unitCost ? nil : "needs \(s.unitCost) \(rules.resource(r)!.displayName) (have \(have))"
    }

    /// Takes a unit's resource cost from the stockpile (validated by the caller).
    mutating func spendResource(for type: UnitType, owner player: PlayerID) {
        guard let r = resourceNeeded(by: type), let s = rules.stockpile else { return }
        setStock(r, of: player, to: max(0, players[player.rawValue].stock(r) - s.unitCost))
    }

    mutating func setStock(_ r: Resource, of player: PlayerID, to value: Int) {
        if players[player.rawValue].stockpile == nil {
            guard value != 0 else { return }
            players[player.rawValue].stockpile = [Int](repeating: 0, count: Resource.allCases.count)
        }
        players[player.rawValue].stockpile![Int(r.rawValue) - 1] = value
    }

    /// Whether `player` is at war with any living civ (the Free Cities' standing war is not one).
    func isAtWarWithAnyone(_ player: PlayerID) -> Bool {
        players.contains { $0.isAlive && $0.isMajor && isAtWar(player, $0.id) }
    }

    /// Phase start (M2 §3.1): +`perSource` per improved source up to the cap, then at war each
    /// unit that needs the resource uses `warUsePerUnit`.
    mutating func runStockpiles(for player: PlayerID) {
        guard let s = rules.stockpile else { return }
        let sources = improvedSources(of: player)
        let atWar = isAtWarWithAnyone(player)
        for r in Resource.allCases where rules.resource(r)?.kind == .strategic {
            var stock = players[player.rawValue].stock(r)
            stock = max(stock, min(stockpileCap, stock + s.perSource * sources[Int(r.rawValue) - 1]))
            if atWar {
                let users = units.filter { $0.owner == player && resourceNeeded(by: $0.type) == r }.count
                stock = max(0, stock - s.warUsePerUnit * users)
            }
            setStock(r, of: player, to: stock)
        }
    }

    /// The resource a unit is short of: it needs one, its owner is at war and the stock is empty.
    public func shortage(of unit: Unit) -> Resource? {
        guard let r = resourceNeeded(by: unit.type), rules.stockpile != nil, !isRaider(unit.owner),
              players[unit.owner.rawValue].stock(r) == 0, isAtWarWithAnyone(unit.owner) else { return nil }
        return r
    }

    func shortagePenalty(_ unit: Unit) -> Int {
        shortage(of: unit) == nil ? 0 : rules.stockpile!.shortageStrength
    }
}
