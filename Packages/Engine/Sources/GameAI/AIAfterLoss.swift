import GameCore

// p3f ai-after-city-loss (M1 §13 War, Cities): what an AI does after losing a city. In the
// iPhone play-test the Mongols took Antium at T35 (war from T32, peace at T47) and Rome, left
// with its capital, never tried to take it back and founded no city to T50, beside an empty
// north. Two rules:
// - Recapture: a city the rival took from the AI is its target first, whichever city the
//   lowest-cost rule names, while the AI's army is at least that city's estimate
//   (`cityEstimate`). In HeadlessSim the lost city was already the target in 87 of 114 first
//   losses to t130; the rule keeps the army on it.
// - Resettle: an AI left with one city after losing one, at peace, builds its Settler (when
//   the Settler rule wants one) right after the city's garrison: before a threatened city's
//   second defender and Walls (a peace treaty holds 10 turns, M1 §9), exploration and the army.
//   HeadlessSim's stand-ins never take an AI city early, so this one is for the human.
// Stateless, like the rest of the AI: a lost city is a remembered city of another player that
// bears one of this player's civ's city names (a captured city keeps its name), which its player
// knows as well.

extension AITurn {
    /// Remembered cities of other players (of `owner` only, when given) that bear one of this
    /// player's civ's city names, by id: cities it founded and lost.
    func lostCities(_ v: PlayerView, of owner: PlayerID? = nil) -> [CitySighting] {
        guard let names = rules.civ(v.me.civ)?.cityNames, !names.isEmpty else { return [] }
        let prefix = rules.constants.city.newNamePrefix
        func ours(_ name: String) -> Bool {
            names.contains(name) || (!prefix.isEmpty && name.hasPrefix(prefix) && names.contains(String(name.dropFirst(prefix.count))))
        }
        return v.knownCities.filter { $0.owner != player && (owner == nil || $0.owner == owner) && ours($0.name) }
    }

    /// One city's estimate (M1 §13 `estimate`, for a city): cityPowerEstimate plus the power of
    /// its owner's units sighted within siegeStageRadius of it at most sightingMaxAge turns ago.
    func cityEstimate(_ city: CitySighting, _ v: PlayerView) -> Int {
        let turn = v.turn
        let near = v.sightings(of: city.owner).filter {
            turn - $0.turnSeen <= ai.sightingMaxAge && v.distance($0.position, city.position) <= ai.siegeStageRadius
        }
        return ai.cityPowerEstimate + near.reduce(0) { $0 + v.power(of: $1) }
    }

    /// Recapture: of the rival's remembered cities `theirs` (path costs `costs` from the capital,
    /// −1 where there is no way), the lost one with the lowest cost (then lower id) whose estimate
    /// `army` matches; nil if none.
    func recaptureTarget(_ theirs: [CitySighting], costs: [Int], army: Int, _ v: PlayerView) -> CitySighting? {
        let lost = lostCities(v)
        guard !lost.isEmpty else { return nil }
        var best: (cost: Int, city: CitySighting)?
        for (i, s) in theirs.enumerated() where costs[i] >= 0 && lost.contains(where: { $0.id == s.id }) {
            guard army >= cityEstimate(s, v) else { continue }
            if let b = best, (b.cost, b.city.id) <= (costs[i], s.id) { continue }
            best = (costs[i], s)
        }
        return best?.city
    }

    /// Resettle: the player has lost a city and has one left, at war with no one, and the
    /// Settler rule (M1 §13 Cities; at peace no enemy is near) wants a Settler.
    func resettles(_ c: ProductionCounts, _ v: PlayerView) -> Bool {
        let cities = v.cities.count
        guard cities == 1, plan.enemies.isEmpty, plan.goodSiteExists, cities + c.settlers < rules.aiMaxCities(mapSize: v.mapSizeName),
              c.settlers < ceilPct(cities, ai.settlersPerCityPct) else { return false }
        return !lostCities(v).isEmpty
    }

    /// Whether a city lacks its garrison: no own fighter on its tile and none sent this phase.
    func lacksGarrison(_ city: City, _ v: PlayerView) -> Bool {
        !v.units.contains { isFighter($0.type) && $0.position == city.position } && garrisonSent[city.id] == nil
    }
}
