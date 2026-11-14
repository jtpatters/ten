import GameCore

extension AITurn {
    /// Spends envoy tokens (M2 §19): each goes to the minor where it completes a tier or takes
    /// or keeps the Patron, else to the best type for the AI (Science, then Gold).
    mutating func sendEnvoys() {
        guard let m = rules.minors else { return }
        while live, (view.me.envoyTokens ?? 0) > 0 {
            let v = view
            var best: (score: Int, minor: PlayerID)?
            for faction in v.knownMinors where v.envoyProblem(to: faction.player) == nil {
                let mine = faction.envoys(of: player), next = mine + 1
                let top = faction.envoys.indices.filter { $0 != player.rawValue }.map { faction.envoys[$0] }.max() ?? 0
                var score = 0
                if m.type(faction.type)?.tiers.contains(where: { $0.envoys == next }) == true { score += 3 }
                if faction.patron != player, next >= m.patronMinEnvoys, next > top { score += 4 }
                if faction.patron == player, top >= mine - 1 { score += 4 }
                switch faction.type {
                case .scientific: score += 2
                case .trade: score += 1
                default: break
                }
                if best == nil || score > best!.score { best = (score, faction.player) }
            }
            guard let target = best?.minor else { return }
            note("sends an envoy to \(target)")
            guard issue(.sendEnvoy(to: target)) else { return }
        }
    }
}
