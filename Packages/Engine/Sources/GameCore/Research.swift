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
    mutating func runResearch(for player: PlayerID, science: Int, _ fx: inout Effects) {
        let p = player.rawValue
        players[p].researchProgress += science
        guard let current = players[p].researching, let def = rules.tech(current),
              players[p].researchProgress >= def.cost else { return }
        players[p].researchProgress -= def.cost
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
    }
}
