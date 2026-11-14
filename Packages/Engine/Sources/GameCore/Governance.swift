// M2 §7.2–7.3: governments, policy slots and their costs.

extension GameState {
    /// The player's government (the rules' default until one is adopted); nil without governance rules.
    public func government(of player: PlayerID) -> GovernmentDef? {
        guard let g = rules.governance else { return nil }
        return rules.government(players[player.rawValue].government ?? g.defaultGovernment)
    }

    public func availableGovernments(for player: PlayerID) -> [GovernmentDef] {
        let p = players[player.rawValue]
        return (rules.governance?.governments ?? []).filter { $0.civic.map(p.knowsCivic) ?? true }
    }

    /// Unlocked policies, minus those whose replacement is unlocked.
    public func availablePolicies(for player: PlayerID) -> [PolicyDef] {
        let p = players[player.rawValue]
        return (rules.governance?.policies ?? []).filter { policy in
            guard p.knowsCivic(policy.civic) else { return false }
            guard let r = policy.replacedBy, let replacement = rules.policy(r) else { return true }
            return !p.knowsCivic(replacement.civic)
        }
    }

    public func policies(of player: PlayerID) -> [PolicyDef] {
        (players[player.rawValue].policies ?? []).compactMap(rules.policy)
    }

    /// The government's and slotted policies' effects; none for Free Cities.
    public func bonuses(of player: PlayerID) -> [Bonuses] {
        guard players.indices.contains(player.rawValue), players[player.rawValue].isMajor else { return [] }
        return [government(of: player)?.bonuses].compactMap { $0 } + policies(of: player).map(\.bonuses)
    }

    public func bonus(_ field: KeyPath<Bonuses, Int?>, for player: PlayerID) -> Int {
        bonuses(of: player).reduce(0) { $0 + ($1[keyPath: field] ?? 0) }
    }

    public func isFreeChangeTurn(for player: PlayerID) -> Bool {
        players[player.rawValue].freeChangeTurn == turn
    }

    /// Free the first time each government is adopted and on a free-change turn; otherwise
    /// `govChangeTurnsOfGold` × Gold income, rounded to 10.
    public func governmentChangeCost(to id: String, for player: PlayerID) -> Int {
        guard let g = rules.governance else { return 0 }
        let adopted = (players[player.rawValue].governmentsAdopted ?? []) + [g.defaultGovernment]
        guard !isFreeChangeTurn(for: player), adopted.contains(id) else { return 0 }
        let turnGold = max(0, view(for: player).income().gold)
        return (turnGold * g.govChangeTurnsOfGold + 5) / 10 * 10
    }

    /// Each newly slotted policy costs `policySwapGold` + `policySwapGoldPerEra` × world era,
    /// except on a free-change turn. Unslotting is free.
    public func policyChangeCost(to ids: [String], for player: PlayerID) -> Int {
        guard let g = rules.governance, !isFreeChangeTurn(for: player) else { return 0 }
        let added = Set(ids).subtracting(players[player.rawValue].policies ?? []).count
        return added * (g.policySwapGold + g.policySwapGoldPerEra * (worldEra ?? 0))
    }

    public func policiesProblem(_ ids: [String], for player: PlayerID) -> String? {
        guard let gov = government(of: player) else { return "no governments" }
        guard Set(ids).count == ids.count else { return "duplicate policy" }
        let open = availablePolicies(for: player)
        var defs: [PolicyDef] = []
        for id in ids {
            guard let def = open.first(where: { $0.id == id }) else {
                return rules.policy(id) == nil ? "no such policy" : "policy not available"
            }
            defs.append(def)
        }
        return gov.fits(defs) ? nil : "not enough slots"
    }

    /// Charges the change cost; keeps the slotted policies that still fit, in order.
    mutating func setGovernment(_ id: String, for player: PlayerID) {
        guard let gov = rules.government(id) else { return }
        let p = player.rawValue
        players[p].gold -= governmentChangeCost(to: id, for: player)
        players[p].government = id
        let adopted = players[p].governmentsAdopted ?? []
        if !adopted.contains(id) { players[p].governmentsAdopted = (adopted + [id]).sorted() }
        var kept: [PolicyDef] = []
        for policy in policies(of: player) where gov.fits(kept + [policy]) { kept.append(policy) }
        if players[p].policies != nil { players[p].policies = kept.map(\.id) }
    }

    mutating func setPolicies(_ ids: [String], for player: PlayerID) {
        players[player.rawValue].gold -= policyChangeCost(to: ids, for: player)
        players[player.rawValue].policies = ids
    }
}

extension PlayerView {
    public var government: GovernmentDef? { state.government(of: player) }
    public var availableGovernments: [GovernmentDef] { state.availableGovernments(for: player) }
    public var availablePolicies: [PolicyDef] { state.availablePolicies(for: player) }
    public var policies: [PolicyDef] { state.policies(of: player) }
    public var isFreeChangeTurn: Bool { state.isFreeChangeTurn(for: player) }
    public func governmentChangeCost(to id: String) -> Int { state.governmentChangeCost(to: id, for: player) }
    public func policyChangeCost(to ids: [String]) -> Int { state.policyChangeCost(to: ids, for: player) }
    public func policiesProblem(_ ids: [String]) -> String? { state.policiesProblem(ids, for: player) }
}

// MARK: - Effects (M2 §4.3, §7.2–7.3)

extension GameState {
    /// The % cut `player`'s government and policies give the production cost of `item` (max 90).
    public func costCutPct(_ item: ProductionItem, for player: PlayerID) -> Int {
        let pct = bonuses(of: player).reduce(0) { sum, b in
            sum + (b.costCuts ?? []).reduce(0) { $0 + (cutApplies($1, to: item) ? $1.pct : 0) }
        }
        return min(90, pct)
    }

    func cutApplies(_ cut: CostCut, to item: ProductionItem) -> Bool {
        switch item {
        case let .unit(type):
            if let units = cut.units { return units.contains(type) }
            let def = rules.unit(type)
            guard let classes = cut.classes, classes.contains(def.unitClass) else { return false }
            guard let maxEra = cut.maxEra else { return true }
            func era(_ id: String?) -> Int { id.flatMap { e in rules.eras.firstIndex { $0.id == e } } ?? 0 }
            return era(def.tech.flatMap { rules.tech($0)?.era }) <= era(maxEra)
        case let .building(id):
            if let buildings = cut.buildings { return buildings.contains(id.rawValue) }
            return cut.centre == true && cut.units == nil && cut.classes == nil && rules.building(id)?.quarter == nil
        case .quarter:
            return false
        }
    }

    /// The production `item` costs `player`, after cost cuts.
    public func productionCost(of item: ProductionItem, for player: PlayerID) -> Int {
        let cost = rules.cost(of: item)
        return cost - cost * costCutPct(item, for: player) / 100
    }

    /// Yields a city gets from its owner's government and policies.
    func governmentYields(_ city: City) -> Yields {
        let bonuses = bonuses(of: city.owner)
        guard !bonuses.isEmpty else { return .zero }
        let quarters = (city.quarters ?? []).filter { !$0.isPillaged }.count
        var y = Yields(production: bonuses.reduce(0) { $0 + ($1.cityProduction ?? 0) },
                       culture: quarters * bonuses.reduce(0) { $0 + ($1.quarterCulture ?? 0) })
        if players[city.owner.rawValue].capital == city.id {
            for b in bonuses { if let c = b.capitalYields { y += c } }
        }
        return y
    }

    func hasGarrison(_ city: City) -> Bool {
        units.contains { $0.position == city.position && $0.owner == city.owner && !$0.type.isCivilian }
    }

    /// Strength from the owner's government and policies: class bonuses, in enemy territory, and
    /// against raiders.
    func governmentStrength(of unit: Unit, against other: CombatSide) -> Int {
        let bonuses = bonuses(of: unit.owner)
        guard !bonuses.isEmpty else { return 0 }
        let cls = rules.unit(unit.type).unitClass
        var s = bonuses.reduce(0) { sum, b in
            sum + (b.strength ?? []).reduce(0) { $0 + ($1.classes.contains(cls) ? $1.amount : 0) }
        }
        let territory = bonuses.reduce(0) { $0 + ($1.enemyTerritoryStrength ?? 0) }
        if territory != 0, let t = map.index(of: unit.position), let owner = tileOwner(t),
           owner != unit.owner, isAtWar(owner, unit.owner) {
            s += territory
        }
        let otherOwner = switch other { case let .unit(o): o.owner; case let .city(c): c.owner }
        if isRaider(otherOwner) { s += bonuses.reduce(0) { $0 + ($1.raiderStrength ?? 0) } }
        return s
    }

    /// Influence per turn (M2 §4.3): the Palace, the government and policies.
    public func influenceIncome(of player: PlayerID) -> Int {
        guard let g = rules.governance, players[player.rawValue].isMajor else { return 0 }
        let palace = players[player.rawValue].capital != nil ? g.palaceInfluence : 0
        let cities = cities.reduce(0) { $0 + ($1.owner == player ? 1 : 0) }
        return palace + bonus(\.influence, for: player) + bonus(\.influencePerFourCities, for: player) * (cities / 4)
    }

    /// Influence needed for `player`'s next envoy token.
    public func envoyThreshold(for player: PlayerID) -> Int {
        guard let g = rules.governance else { return 0 }
        return min(g.envoyMax, g.envoyBase + g.envoyStep * (players[player.rawValue].envoysEarned ?? 0))
    }

    /// At the end of a major civ's phase: adds the turn's Influence and turns it into envoy tokens.
    mutating func runInfluence(for player: PlayerID, _ fx: inout Effects) {
        guard rules.governance != nil else { return }
        let p = player.rawValue
        var influence = (players[p].influence ?? 0) + influenceIncome(of: player)
        while influence >= envoyThreshold(for: player), envoyThreshold(for: player) > 0 {
            influence -= envoyThreshold(for: player)
            players[p].envoysEarned = (players[p].envoysEarned ?? 0) + 1
            players[p].envoyTokens = (players[p].envoyTokens ?? 0) + 1
            fx.emit(.envoyEarned(player: player, tokens: players[p].envoyTokens!), .owner(player))
        }
        players[p].influence = influence
        fx.touchPlayer(player)
    }
}
