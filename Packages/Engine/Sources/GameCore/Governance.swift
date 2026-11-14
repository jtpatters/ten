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
