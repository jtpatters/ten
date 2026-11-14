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
        guard rules.governance != nil else { return }
        players[p].freeChangeTurn = turn
        let open = Set(availablePolicies(for: player).map(\.id))
        if let slotted = players[p].policies, !slotted.allSatisfy(open.contains) {
            players[p].policies = slotted.filter(open.contains)
        }
    }
}

/// A civic in the civic tree (M2 §7.1), as the panel shows it.
public struct CivicOption: Hashable, Sendable {
    public var civic: CivicID
    public var name: String
    public var cost: Int
    public var requires: [CivicID]
    public var known: Bool
    public var studying: Bool
    public var isTarget: Bool
    /// Its prerequisites are known (and it is not).
    public var available: Bool
    /// Phases to complete it, missing prerequisites first, at the current Culture (nil when
    /// known or with no Culture).
    public var turns: Int?
    /// The governments and policies it unlocks, by name.
    public var unlocks: [String]
    /// Its era's index (0 without eras).
    public var era: Int
    /// Credit toward it from its Insight.
    public var credit: Int
    public var insight: String?
    public var insightGained: Bool
}

extension PlayerView {
    /// The civics in tree order with their state, phases to complete and unlocks.
    public func civicOptions() -> [CivicOption] {
        let culture = income().culture
        let progress = me.civicProgress ?? 0
        return rules.civics.indices.map { index in
            let civic = rules.civics[index]
            let known = me.knowsCivic(civic.id)
            var turns: Int?
            if !known, culture > 0 {
                var needed = [Bool](repeating: false, count: rules.civics.count)
                needed[index] = true
                for i in stride(from: index, through: 0, by: -1) where needed[i] {
                    for r in rules.civicRequires[i] { needed[r] = true }
                }
                var cost = 0
                for i in rules.civics.indices where needed[i] && !me.knowsCivic(rules.civics[i].id) {
                    cost += max(0, rules.civics[i].cost - state.civicCredit(i, for: player))
                }
                turns = max(1, (max(0, cost - progress) + culture - 1) / culture)
            }
            let era = civic.era.flatMap { e in rules.eras.firstIndex { $0.id == e } } ?? 0
            return CivicOption(civic: civic.id, name: civic.name, cost: civic.cost, requires: civic.requires, known: known,
                               studying: me.studying == civic.id, isTarget: me.civicTarget == civic.id,
                               available: !known && civic.requires.allSatisfy(me.knowsCivic),
                               turns: turns, unlocks: unlocks(of: civic.id), era: era,
                               credit: state.civicCredit(index, for: player), insight: civic.insight?.text,
                               insightGained: me.civicInsights?.contains(civic.id) == true)
        }
    }

    /// Names of the governments and policies a civic unlocks.
    public func unlocks(of civic: CivicID) -> [String] {
        let g = rules.governance
        return (g?.governments ?? []).filter { $0.civic == civic }.map(\.name)
            + (g?.policies ?? []).filter { $0.civic == civic }.map(\.name)
    }

    /// Influence per turn and toward the next envoy token (M2 §4.3).
    public var influenceIncome: Int { state.influenceIncome(of: player) }
    public var envoyThreshold: Int { state.envoyThreshold(for: player) }
}
