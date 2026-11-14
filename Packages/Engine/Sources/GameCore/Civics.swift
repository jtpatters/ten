// Civics (M2 §7.1): Culture studies civics the way Science researches techs.

extension Player {
    public func knowsCivic(_ civic: CivicID) -> Bool { knownCivics?.contains(civic) ?? false }
}

extension GameState {
    /// The first civic `player` lacks on the way to `target`, in tree order; nil when known.
    func nextCivic(toward target: CivicID, for player: PlayerID) -> CivicID? {
        guard let goal = rules.civicIndex(target) else { return nil }
        let p = players[player.rawValue]
        guard !p.knowsCivic(target) else { return nil }
        var needed = [Bool](repeating: false, count: rules.civics.count)
        needed[goal] = true
        for i in stride(from: goal, through: 0, by: -1) where needed[i] {
            for r in rules.civicRequires[i] { needed[r] = true }
        }
        return rules.civics.indices.first { needed[$0] && !p.knowsCivic(rules.civics[$0].id) }.map { rules.civics[$0].id }
    }

    /// `setCivic` (validated by the caller).
    mutating func setCivic(_ target: CivicID, for player: PlayerID) {
        players[player.rawValue].civicTarget = target
        players[player.rawValue].studying = nextCivic(toward: target, for: player)
    }

    /// The culture step of a phase: the player's Culture goes into the current civic; at its cost
    /// the civic completes (at most one per phase) and the overflow carries on.
    mutating func runCivics(for player: PlayerID, culture: Int, _ fx: inout Effects) {
        let p = player.rawValue
        guard !rules.civics.isEmpty else { return }
        let progress = (players[p].civicProgress ?? 0) + culture
        players[p].civicProgress = progress == 0 ? nil : progress
        guard let current = players[p].studying, let index = rules.civicIndex(current) else { return }
        let needed = max(0, rules.civics[index].cost - civicCredit(index, for: player))
        guard progress >= needed else { return }
        let rest = progress - needed
        players[p].civicProgress = rest == 0 ? nil : rest
        learnCivic(current, player: player)
        fx.emit(.civicCompleted(player: player, civic: current), .owner(player))
        if let target = players[p].civicTarget, let next = nextCivic(toward: target, for: player) {
            players[p].studying = next
        } else {
            players[p].studying = nil
            players[p].civicTarget = nil
        }
    }

    /// An Insight's credit toward a civic (M2 §6.2 applied to civics): its share of the cost.
    func civicCredit(_ index: Int, for player: PlayerID) -> Int {
        let civic = rules.civics[index]
        guard players[player.rawValue].civicInsights?.contains(civic.id) == true else { return 0 }
        return civic.cost * (rules.progression?.insightPct ?? 0) / 100
    }

    mutating func learnCivic(_ civic: CivicID, player: PlayerID) {
        let p = player.rawValue
        guard !players[p].knowsCivic(civic) else { return }
        players[p].knownCivics = ((players[p].knownCivics ?? []) + [civic]).sorted()
    }
}
