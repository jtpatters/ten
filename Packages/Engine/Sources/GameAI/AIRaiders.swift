import GameCore

extension AITurn {
    static let raiderCampMoves = 16
    static let raiderCampCityRange = 16
    static let raiderCampOdds = 125
    static let raiderCampHunters = 3
    static let raiderPolicyWeight = 5

    /// M2 §11, at war or at peace: free line units attack raiders on good odds; then, for each
    /// remembered camp within `raiderCampCityRange` of an own city, the nearest healthy free line
    /// unit within `raiderCampMoves` moves walks onto it (clearing it) or, when it is guarded by
    /// a weaker unit, next to it.
    mutating func fightRaiders() {
        guard live, let raiders = view.players.first(where: { $0.isRaiders })?.id else { return }
        let garrisons = forces(view).garrisonIDs
        let ids = view.units.filter { u in
            isLine(u.type) && u.movesLeft > 0 && !acted.contains(u.id) && !garrisons.contains(u.id)
        }.map(\.id)
        for id in ids {
            let v = view
            guard live, let unit = v.unit(id), unit.movesLeft > 0, unit.hp >= ai.retreatHP else { continue }
            var best: (kills: Int, net: Int, option: AttackOption)?
            for option in v.attackOptions(for: id) {
                guard case .unit = option.defender, v.units(at: option.target).contains(where: { $0.owner == raiders }),
                      let p = v.combatPreview(attacker: .unit(id), target: option.target, from: option.from),
                      p.killChance(atLeast: ai.attackKillChancePct) || p.meanDealt > p.meanTaken else { continue }
                let key = (p.killPairs, p.meanDealt - p.meanTaken)
                if let b = best, (b.kills, b.net) >= key { continue }
                best = (key.0, key.1, option)
            }
            if let best, attack(id, best.option, from: best.option.from) { acted.insert(id) }
        }

        for camp in view.knownRaiderCamps.map(Int.init) where live { clearCamp(camp) }
    }

    func power(_ type: UnitType) -> Int {
        let def = rules.unit(type)
        return max(def.strength, def.rangedStrength)
    }

    /// The `clearCamp` operation (M2 §17.3) for a remembered camp within `raiderCampCityRange`
    /// of an own city: the nearest healthy free line units within `raiderCampMoves` moves (by
    /// cost, then id) until their power is `raiderCampOdds`% of the visible raiders within 2 of
    /// the camp and they outnumber them; none go when that many are not at hand. They gather
    /// within 3 of the camp until those near enough suffice, then close in; an unguarded camp
    /// is walked onto by whoever reaches it.
    mutating func clearCamp(_ camp: Int) {
        let v = view
        guard v.cities.contains(where: { v.index(of: $0.position).map { v.aiDistance($0, camp) <= Self.raiderCampCityRange } ?? false })
        else { return }
        let hex = v.coord(at: camp)
        let raiders = v.players.filter(\.isRaiders).map(\.id)
        let guards = v.visibleForeignUnits.filter { u in
            raiders.contains(u.owner) && v.index(of: u.position).map { v.aiDistance($0, camp) <= 2 } ?? false
        }
        let limit = rules.points(Self.raiderCampMoves)
        var candidates: [(cost: Int32, unit: Unit)] = []
        for u in freeFighters(v) where isLine(u.type) && u.hp >= ai.retreatHP {
            let f = field(u.id, within: limit)
            guard let t = v.index(of: u.position) else { continue }
            let cost = t == camp || v.aiDistance(t, camp) <= 1 ? 0
                : v.neighbors(of: hex).compactMap { v.index(of: $0) }
                    .map { f[$0] }.filter { $0 > 0 && Int($0) <= limit }.min() ?? -1
            if cost >= 0 { candidates.append((cost, u)) }
        }
        candidates.sort { ($0.cost, $0.unit.id) < ($1.cost, $1.unit.id) }
        // An unseen camp is taken to hold one of the strongest raiders of the world era.
        let seenEmpty = v.isVisible(hex) && guards.isEmpty
        let assumed = seenEmpty ? 0 : (rules.raiders?.units(era: v.worldEra).map(power).max() ?? 0)
        let guardCount = seenEmpty ? 0 : max(guards.count, 1)
        let need = max(guards.reduce(0) { $0 + power($1.type) }, assumed) * Self.raiderCampOdds / 100
        var squad: [Unit] = []
        var squadPower = 0
        for c in candidates where squadPower < need || squad.count <= guardCount {
            squad.append(c.unit)
            squadPower += power(c.unit.type)
        }
        guard !squad.isEmpty, squadPower >= need, squad.count > guardCount else { return }
        let near = squad.filter { u in v.index(of: u.position).map { v.aiDistance($0, camp) <= 3 } ?? false }
        let gathered = near.reduce(0) { $0 + power($1.type) } >= need && near.count > guardCount
        note("squad \(squad.map(\.id)) for the raider camp at \(hex) (power \(squadPower) vs \(need), \(gathered ? "closing in" : "gathering"))")
        for u in squad where live {
            acted.insert(u.id)
            let w = view
            guard let unit = w.unit(u.id), unit.movesLeft > 0, let t = w.index(of: unit.position) else { continue }
            if !w.units(at: hex).contains(where: { $0.owner != player }) {
                if hop(u.id, toward: hex) { continue }
            }
            if gathered || w.aiDistance(t, camp) <= 1 {
                if let option = w.attackOptions(for: u.id).filter({ o in
                    w.units(at: o.target).contains { raiders.contains($0.owner) }
                }).min(by: { (w.distance($0.target, hex), w.index(of: $0.target) ?? 0) < (w.distance($1.target, hex), w.index(of: $1.target) ?? 0) }),
                   attack(u.id, option, from: option.from) { continue }
            }
            guard w.aiDistance(t, camp) > (gathered ? 1 : 3) else { continue }
            let goals = w.neighbors(of: hex).compactMap { w.index(of: $0) }
            let f = field(u.id, within: limit)
            if let goal = goals.filter({ f[$0] > 0 }).min(by: { (f[$0], $0) < (f[$1], $1) }) {
                hop(u.id, toward: w.coord(at: goal))
            }
        }
    }
}
