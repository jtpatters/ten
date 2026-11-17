// Units (M1 §7): upkeep, builders, activities, healing, disbanding.

extension GameState {
    // MARK: Upkeep

    /// Military units `player` keeps free of upkeep: freeBase + freePerCity × cities.
    public func freeUnitAllowance(of player: PlayerID) -> Int {
        let u = rules.constants.upkeep
        return u.freeBase + u.freePerCity * cities.reduce(0) { $0 + ($1.owner == player ? 1 : 0) }
    }

    public func militaryUnitCount(of player: PlayerID) -> Int {
        units.reduce(0) { $0 + ($1.owner == player && !$1.type.isCivilian ? 1 : 0) }
    }

    /// Gold `player` pays per turn for its military units beyond the free allowance.
    public func upkeep(of player: PlayerID) -> Int {
        guard !isRaider(player), !isMinor(player) else { return 0 }
        return max(0, militaryUnitCount(of: player) - freeUnitAllowance(of: player))
            * max(0, rules.constants.upkeep.goldPerUnit - bonus(\.unitUpkeepCut, for: player))
    }

    /// Gold `player` pays per turn for its buildings and quarters (M2 §5.4).
    public func buildingUpkeep(of player: PlayerID) -> Int {
        let perQuarter = rules.quarters?.upkeep ?? 0
        return cities.reduce(0) { sum, city in
            guard city.owner == player else { return sum }
            let buildings = city.buildings.reduce(0) { $0 + (rules.building($1)?.upkeep ?? 0) }
            return sum + buildings + perQuarter * (city.quarters?.count ?? 0)
        }
    }

    /// The gold step of a phase (M1 §3 step 3, §7.1, M2 §5.4): add the gold yield, then pay unit
    /// and building upkeep. While the treasury would be negative and the player has more
    /// military units than the free allowance, the cheapest (then highest id) is disbanded; a
    /// treasury still negative is set to 0 and the shortfall returned (the phase's science
    /// falls by it).
    @discardableResult
    mutating func runGold(for player: PlayerID, income: Int, _ fx: inout Effects) -> Int {
        let p = player.rawValue
        players[p].gold += income
        let buildings = buildingUpkeep(of: player)
        while players[p].gold - upkeep(of: player) - buildings < 0, militaryUnitCount(of: player) > freeUnitAllowance(of: player) {
            let victim = units.filter { $0.owner == player && !$0.type.isCivilian }.min { a, b in
                let ca = rules.unit(a.type).cost, cb = rules.unit(b.type).cost
                return ca != cb ? ca < cb : a.id > b.id
            }!
            disband(victim.id, upkeep: true, &fx)
        }
        let due = upkeep(of: player) + buildings
        let shortfall = max(0, due - players[p].gold)
        players[p].gold = max(0, players[p].gold - due)
        return shortfall
    }

    /// Removes a unit with an `unitDisbanded` event. A disband ordered by the owner is a tile
    /// event (the owner and the tile's viewers); one forced by unpaid upkeep is an upkeep event,
    /// which M1 §12.5 sends to the owner only, so its `upkeep` flag never tells another player
    /// about the owner's treasury (viewers still see the unit gone: their sightings are dropped).
    mutating func disband(_ id: UnitID, upkeep: Bool, _ fx: inout Effects) {
        guard let unit = unit(id) else { return }
        let t = map.index(of: unit.position)!
        forgetSightings(of: unit)
        removeUnit(id)
        fx.emit(.unitDisbanded(unit: id, type: unit.type, owner: unit.owner, at: unit.position, upkeep: upkeep),
                upkeep ? .owner(unit.owner) : .ownerAndTiles(unit.owner, [t]))
        fx.touchPlayer(unit.owner)
    }

    // MARK: Builders

    /// Why `unit` may not build `improvement` where it stands (nil: it may), M1 §7.2.
    func improvementProblem(_ improvement: Improvement, by unit: Unit) -> String? {
        let def = rules.improvement(improvement)
        guard unit.charges > 0 else { return "only Builders improve tiles" }
        guard unit.movesLeft > 0 else { return "no moves left" }
        let t = map.index(of: unit.position)!
        guard tileOwner(t) == unit.owner else { return "tile not in your territory" }
        guard city(atTile: t) == nil else { return "not on a city centre" }
        guard !isQuarterTile(t) else { return "not on a quarter" }
        let repair = map.tiles[t].isPillaged && map.tiles[t].improvement == improvement
        guard map.tiles[t].improvement == nil || repair else { return "tile already improved" }
        guard rules.allowsImprovement(improvement, on: map.tiles[t], resource: knownResource(at: t, for: unit.owner)) else { return "\(def.displayName) not allowed here" }
        if let tech = def.tech, !players[unit.owner.rawValue].knows(tech) { return "needs \(techName(tech))" }
        if def.spaced == true {
            var near = false
            map.forEachNeighbor(of: t) { n, _ in
                if map.tiles[n].improvement == improvement, tileOwner(n) == unit.owner { near = true }
            }
            if near { return "not next to another \(def.displayName)" }
        }
        return nil
    }

    /// Builds an improvement (validated by the caller): it completes at once and uses one
    /// charge and all remaining moves; at 0 charges the builder is removed.
    mutating func buildImprovement(_ improvement: Improvement, by id: UnitID, _ fx: inout Effects) {
        guard let unit = unit(id) else { return }
        let t = map.index(of: unit.position)!
        map[index: t].improvement = improvement
        map[index: t].pillaged = nil
        fx.touchTile(t)
        if unit.charges <= 1 {
            removeUnit(id)
            fx.touchPlayer(unit.owner)
        } else {
            updateUnit(id) { u in
                u.charges -= 1
                u.movesLeft = 0
                u.activity = .none
                u.destination = nil
            }
        }
        fx.emit(.improvementBuilt(improvement: improvement, at: unit.position, owner: unit.owner), .tiles([t]))
        if let city = owningCity(ofTile: t), let index = cityIndex(city.id) { assignCitizens(index) }
    }

    // MARK: Healing

    /// HP a unit regains at its owner's phase start (M1 §7.5) if it neither moved nor attacked
    /// during its owner's previous phase: by where it stands.
    func healing(for unit: Unit) -> Int {
        guard unit.lastActedTurn < turn - 1 else { return 0 }
        let h = rules.constants.healing
        let t = map.index(of: unit.position)!
        if let e = rules.embark, unit.type.isNaval || map.tiles[t].terrain.isWater {
            // M2 §8.4: ships heal only in an own city, nothing heals at sea.
            return unit.type.isNaval && city(atTile: t)?.owner == unit.owner ? e.navalHealInCity : 0
        }
        if let city = city(atTile: t), city.owner == unit.owner { return h.ownCity }
        guard let owner = tileOwner(t) else { return h.neutral }
        let fort = fortDefense(unit, at: t) != nil ? (map.tiles[t].improvement.flatMap { rules.improvement($0).heal } ?? 0) : 0
        return (owner == unit.owner ? h.ownTerritory : h.foreign) + fort
    }

    /// The defence an own, unpillaged Fort-like improvement gives `unit` standing on tile `t`
    /// (M3a §4); nil when there is none. It also counts as fortified.
    func fortDefense(_ unit: Unit, at t: Int) -> Int? {
        let tile = map.tiles[t]
        guard let improvement = tile.improvement, !tile.isPillaged, let d = rules.improvement(improvement).defense,
              tileOwner(t) == unit.owner, !unit.type.isNaval, !tile.terrain.isWater else { return nil }
        return d
    }

    /// Phase start step 5 for one unit (M1 §3), before standing orders: clear `zocStopped`;
    /// `fortifying` becomes `fortified`; clear `skipped`; wake sleepers with an enemy within 2;
    /// heal; restore moves.
    mutating func startPhase(ofUnit id: UnitID) {
        guard let unit = unit(id) else { return }
        let heal = healing(for: unit)
        let wake = unit.activity == .sleeping && enemyNear(unit, within: 2)
        let moves = maxMoves(of: unit)
        let maxHP = rules.constants.healing.maxHP
        updateUnit(id) { u in
            u.zocStopped = false
            u.attacked = nil
            if u.activity == .fortifying { u.activity = .fortified }
            if u.activity == .skipped || wake { u.activity = .none }
            u.hp = min(maxHP, u.hp + heal)
            u.movesLeft = moves
        }
    }

    /// Whether a military unit of a player `unit`'s owner is at war with stands within `radius`
    /// on a tile the owner can see.
    func enemyNear(_ unit: Unit, within radius: Int) -> Bool {
        guard relations.contains(where: { $0.stance == .war && $0.involves(unit.owner) }) else { return false }
        let visible = players[unit.owner.rawValue].visible
        return units.contains { other in
            !other.type.isCivilian && isAtWar(unit.owner, other.owner) && map.distance(other.position, unit.position) <= radius
                && map.index(of: other.position).map { visible[$0] } == true && !isHidden(other, from: unit.owner)
        }
    }

    // MARK: Upgrades (M2 §8.2)

    /// Gold to upgrade a unit of `type`: (target cost − own cost) × 2, at least 10; nil when it
    /// has no upgrade.
    public func upgradeCost(of type: UnitType, for player: PlayerID? = nil) -> Int? {
        guard let target = rules.unit(type).upgradesTo else { return nil }
        let cost = max(10, (rules.unit(target).cost - rules.unit(type).cost) * 2)
        guard let player else { return cost }
        return cost - cost * min(90, bonus(\.upgradePct, for: player)) / 100
    }

    /// Why `unit` may not upgrade now (nil: it may): it stands in own territory with moves left,
    /// its owner knows the target's tech and has the Gold.
    func upgradeProblem(_ unit: Unit) -> String? {
        guard let target = rules.unit(unit.type).upgradesTo, let cost = upgradeCost(of: unit.type, for: unit.owner) else {
            return "\(unit.type.displayName)s have no upgrade"
        }
        guard unit.movesLeft > 0 else { return "no moves left" }
        let t = map.index(of: unit.position)!
        guard tileOwner(t) == unit.owner else { return "only in your territory" }
        if let tech = rules.unit(target).tech, !players[unit.owner.rawValue].knows(tech) { return "needs \(techName(tech))" }
        guard players[unit.owner.rawValue].gold >= cost else { return "needs \(cost) Gold" }
        return resourceProblem(target, owner: unit.owner)
    }

    /// Upgrades a unit (validated by the caller): same id, XP, HP and position; its moves end.
    mutating func upgrade(_ id: UnitID, _ fx: inout Effects) {
        guard let unit = unit(id), let target = rules.unit(unit.type).upgradesTo, let cost = upgradeCost(of: unit.type, for: unit.owner) else { return }
        players[unit.owner.rawValue].gold -= cost
        spendResource(for: target, owner: unit.owner)
        updateUnit(id) { u in
            u.type = target
            u.movesLeft = 0
            u.activity = .none
            u.destination = nil
        }
        let t = map.index(of: unit.position)!
        fx.emit(.unitUpgraded(unit: id, from: unit.type, to: target, owner: unit.owner, at: unit.position), .ownerAndTiles(unit.owner, [t]))
        fx.touchPlayer(unit.owner)
    }

    // MARK: Promotions (M2 §8.3)

    /// The promotions `unit` may take now: those of its class at the next tier, once its XP
    /// reaches that tier's threshold.
    public func promotionsOffered(to unit: Unit) -> [PromotionDef] {
        let taken = unit.promotions?.count ?? 0
        guard taken < rules.promotionXP.count, unit.xp >= rules.promotionXP[taken] else { return [] }
        let cls = rules.unit(unit.type).unitClass
        return rules.promotions.filter { $0.tier == taken + 1 && $0.classes.contains(cls) }
    }

    func promotionMoves(_ unit: Unit) -> Int {
        guard let taken = unit.promotions else { return 0 }
        return rules.promotions.reduce(0) { $0 + (taken.contains($1.id) ? $1.moves ?? 0 : 0) }
    }

    /// The promotions `unit` has taken.
    func promotionDefs(_ unit: Unit) -> [PromotionDef] {
        guard let taken = unit.promotions, !taken.isEmpty else { return [] }
        return rules.promotions.filter { taken.contains($0.id) }
    }

    /// Its moves per phase, promotions included.
    public func maxMoves(of unit: Unit) -> Int {
        (rules.unit(unit.type).moves + promotionMoves(unit) + reconBonus(unit, \.reconMoves) + navalBonus(unit, \.navalMoves))
            * rules.movePoints
    }

    /// A bonus that applies to naval units (M3a §6.1: Navigation, Square Rigging).
    func navalBonus(_ unit: Unit, _ field: KeyPath<Bonuses, Int?>) -> Int {
        unit.type.isNaval ? bonus(field, for: unit.owner) : 0
    }

    /// A government or policy bonus that applies to recon units (M2 §7.3).
    func reconBonus(_ unit: Unit, _ field: KeyPath<Bonuses, Int?>) -> Int {
        rules.unit(unit.type).unitClass == .recon ? bonus(field, for: unit.owner) : 0
    }

    /// Its range (0 for non-ranged units), promotions included.
    public func range(of unit: Unit) -> Int {
        let def = rules.unit(unit.type)
        guard def.isRanged else { return 0 }
        return def.range + promotionDefs(unit).reduce(0) { $0 + ($1.range ?? 0) }
    }

    /// Its sight, promotions included.
    public func sight(of unit: Unit) -> Int {
        if let e = rules.embark, isEmbarked(unit) { return e.sight }
        return rules.unit(unit.type).sight + promotionDefs(unit).reduce(0) { $0 + ($1.sight ?? 0) } + reconBonus(unit, \.reconSight)
            + navalBonus(unit, \.navalSight)
    }

    /// Whether it may fire after moving in the phase (siege may not, M2 §8.1, unless promoted).
    func firesAfterMoving(_ unit: Unit) -> Bool {
        rules.unit(unit.type).rangedAfterMove != false || promotionDefs(unit).contains { $0.rangedAfterMove == true }
    }

    func ignoresZOC(_ unit: Unit) -> Bool { promotionDefs(unit).contains { $0.ignoresZOC == true } }
    func holdsZOC(_ unit: Unit) -> Bool { promotionDefs(unit).contains { $0.holdsZOC == true } }

    /// Per elevation and per feature (by raw value): whether `unit` skips its extra move cost.
    func freeMove(_ unit: Unit) -> (elevations: [Bool], features: [Bool]) {
        let names = Set(promotionDefs(unit).flatMap { $0.freeMoveOn ?? [] })
        return (rules.elevations.map { names.contains($0.name) }, rules.features.map { names.contains($0.name) })
    }

    func promoteProblem(_ unit: Unit, _ promotion: String) -> String? {
        let offered = promotionsOffered(to: unit)
        guard !offered.isEmpty else { return "no promotion due" }
        guard offered.contains(where: { $0.id == promotion }) else { return "not offered to this unit" }
        guard unit.movesLeft > 0 else { return "no moves left" }
        return nil
    }

    /// Takes a promotion (validated by the caller): heals 50 HP and ends its moves.
    mutating func promote(_ id: UnitID, _ promotion: String, _ fx: inout Effects) {
        guard let unit = unit(id) else { return }
        let maxHP = rules.constants.healing.maxHP
        updateUnit(id) { u in
            u.promotions = (u.promotions ?? []) + [promotion]
            u.hp = min(maxHP, u.hp + 50)
            u.movesLeft = 0
            u.activity = .none
            u.destination = nil
        }
        if rules.promotions.first(where: { $0.id == promotion })?.sight != nil { fx.touchPlayer(unit.owner) }
        let t = map.index(of: unit.position)!
        fx.emit(.unitPromoted(unit: id, promotion: promotion, owner: unit.owner, at: unit.position), .ownerAndTiles(unit.owner, [t]))
    }
}

// MARK: - Hidden ships (M3a §9.4)

extension GameState {
    /// Whether `viewer` sees `unit` now: its own, or on a tile `viewer` sees, except a hidden
    /// ship (`navalRaider`) that no unit or city of `viewer` stands next to and that has not
    /// revealed itself by attacking this turn or the last.
    public func sees(_ viewer: PlayerID, _ unit: Unit) -> Bool {
        if unit.owner == viewer { return true }
        guard players.indices.contains(viewer.rawValue), let t = map.index(of: unit.position),
              players[viewer.rawValue].visible[t] else { return false }
        return !isHidden(unit, from: viewer)
    }

    /// A hidden ship `viewer` has not found (whether or not it sees the tile).
    func isHidden(_ unit: Unit, from viewer: PlayerID) -> Bool {
        guard unit.owner != viewer, rules.unit(unit.type).unitClass == .navalRaider else { return false }
        if let r = unit.revealedUntil, turn <= r { return false }
        if units.contains(where: { $0.owner == viewer && map.distance($0.position, unit.position) <= 1 }) { return false }
        if cities.contains(where: { $0.owner == viewer && map.distance($0.position, unit.position) <= 1 }) { return false }
        return true
    }

    /// Whether any unit could be hidden (skip per-unit checks in rules without the class).
    var hasHiddenUnits: Bool { units.contains { rules.unit($0.type).unitClass == .navalRaider } }
}
