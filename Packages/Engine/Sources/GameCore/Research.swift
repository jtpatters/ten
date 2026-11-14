// Research (M1 §6).

extension GameState {
    /// The first tech `player` lacks on the way to `target`, in tree order: the earliest missing
    /// (transitive) prerequisite, else the target itself; nil when the target is known.
    func nextResearch(toward target: TechID, for player: PlayerID) -> TechID? {
        guard let goal = rules.techIndex(target) else { return nil }
        let known = players[player.rawValue].knownTechs
        guard !known.contains(target) else { return nil }
        // Every tech the goal needs, transitively (prerequisites come earlier in tree order).
        var needed = [Bool](repeating: false, count: rules.techs.count)
        needed[goal] = true
        for i in stride(from: goal, through: 0, by: -1) where needed[i] {
            for r in rules.techRequires[i] { needed[r] = true }
        }
        for i in rules.techs.indices where needed[i] && !known.contains(rules.techs[i].id) {
            return rules.techs[i].id
        }
        return nil
    }

    /// `setResearch` (validated by the caller): aim at `target` through its missing prerequisites.
    mutating func setResearch(_ target: TechID, for player: PlayerID) {
        players[player.rawValue].researchTarget = target
        players[player.rawValue].researching = nextResearch(toward: target, for: player)
    }

    /// The science step of a phase (M1 §6): science goes into the current tech; at its cost the
    /// tech is learned and the overflow carries on (at most one tech per phase); research then
    /// moves to the next missing prerequisite of the target, or the target. With nothing to
    /// research, science accumulates.
    /// Credit from Insights and the world era (M2 §6.2) lowers what the tech needs.
    mutating func runResearch(for player: PlayerID, science: Int, _ fx: inout Effects) {
        let p = player.rawValue
        players[p].researchProgress += science
        guard let current = players[p].researching, let index = rules.techIndex(current) else { return }
        let needed = max(0, rules.techs[index].cost - players[p].credit(techIndex: index))
        guard players[p].researchProgress >= needed else { return }
        players[p].researchProgress -= needed
        learn(current, player: player)
        fx.emit(.techResearched(player: player, tech: current), .owner(player))
        if let target = players[p].researchTarget, let next = nextResearch(toward: target, for: player) {
            players[p].researching = next
        } else {
            players[p].researching = nil
            players[p].researchTarget = nil
        }
    }

    mutating func learn(_ tech: TechID, player: PlayerID) {
        guard !players[player.rawValue].knownTechs.contains(tech) else { return }
        players[player.rawValue].knownTechs.append(tech)
        players[player.rawValue].knownTechs.sort()
        if let index = rules.techIndex(tech), players[player.rawValue].credit(techIndex: index) > 0 {
            players[player.rawValue].techCredit![index] = 0
        }
    }

    /// Adds credit toward an unknown tech (M2 §6.2), capped at its cost − 1 so the tech is
    /// still learnt by research.
    mutating func addTechCredit(_ amount: Int, techIndex index: Int, player: PlayerID) {
        let p = player.rawValue
        guard amount > 0, !players[p].knows(rules.techs[index].id) else { return }
        if players[p].techCredit == nil { players[p].techCredit = Array(repeating: 0, count: rules.techs.count) }
        let cap = max(0, rules.techs[index].cost - 1)
        players[p].techCredit![index] = min(cap, players[p].techCredit![index] + amount)
    }
}
