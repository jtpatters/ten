import GameCore

// p3f ai-prepare-posture (M1 §13 Cities, Settling, War). From turn 30 an AI that remembers a city
// of a rival it may declare war on prepares against it (posture prepare), and with
// `armyFirstCities` (3) or more cities builds Builders and its army before Settlers until the war
// test holds. Its army gathers by the rally city, as far from the rival's cities as it can. In
// 3d's newbie games that was about 29 turns in which the AI founded no city and showed nothing
// (AI cities at t50 3.38; visible AI military within 4 tiles of a newbie city by t50 in 6 of 40
// games), which both play-testers saw as an AI that "never presses". Two rules, each off while
// its ruleset value is missing or 0 (`AIRules`):
// - B (`prepareSettlersRivalPct`, 125): in prepare, while a good site exists and 100 × (cities
//   + Settlers alive and queued) < pct × the rival's remembered cities, Settlers stay ahead of
//   the army (`armyFirstCities` does not apply); and in prepare a Settler values a site
//   `prepareSiteRivalWeight` (2) points less per tile from the rival's nearest remembered city,
//   so the AI expands toward the rival and contests the land between them. At 100 (the item's
//   "fewer cities than the rival") AI cities at t50 rose only from 3.38 to 3.40 in the 40 newbie
//   games; 125 lets it found while it has fewer than 1.25 × the rival's cities (one city more
//   than a rival with 3 or 4) and gives 3.58.
// - C (`prepareStageRadius`, 2; `prepareStageUnits`, 1): in prepare, the army unit nearest the
//   stage stands within that many tiles of it instead of by the rally city: the stage is a tile
//   it may stand on within the target's sight (a city sees 2 tiles), on the side facing the
//   rally city, so the rival sees it (the App's 'troops near' notice). The war test counts the
//   units there as well as those near the rally city; the rest of the army gathers by the
//   rally city as before, and at war it all goes on as before.
//   - Beyond the AI's own borders: its own border tiles nearest the target lie within 4 tiles
//     of a newbie city in 14 of 40 newbie games (T30–T50), and the newbie sees one of them in 12
//     (staged there, 8 of 40 games showed AI troops near a newbie city by t50).
//   - One unit, not the army: with the whole army staged in sight, its first strike took 7
//     newbie cities by t80 (base 1) and lost 2–3 of the 40 newbie games; one unit shows itself
//     as often (28 of 40 games) at base danger.
//   - Showing itself, a unit also sees the rival's defenders, so the war test (130% of the
//     estimate) holds later: AI wars on the newbie by t60 fell from 20 to 10 of 40.
// Stateless like the rest of the AI: both read only this phase's knowledge.

/// B: how much a site is worth less for each tile it lies from the rival (`rivalSitePreference`).
struct RivalSites {
    var weight: Int
    /// Tiles of the rival's remembered cities.
    var cities: [Int]

    /// weight × the distance from tile `t` to the rival's nearest remembered city.
    func penalty(_ t: Int, _ v: PlayerView) -> Int {
        guard let d = cities.map({ v.aiDistance($0, t) }).min() else { return 0 }
        return weight * d
    }
}

extension AITurn {
    // MARK: B, Settlers ahead of the army

    /// B: whether, in prepare, Settlers come before the army in the priority list this phase: the
    /// rule is on, a good site exists, and 100 × (own cities + Settlers alive and queued so far
    /// this phase, `c`) < prepareSettlersRivalPct × the rival's remembered cities.
    func settlersAheadOfArmy(_ c: ProductionCounts, _ v: PlayerView) -> Bool {
        guard let pct = ai.prepareSettlersRivalPct, pct > 0, plan.posture == .prepare, let rival = plan.rival,
              plan.goodSiteExists else { return false }
        let theirs = v.knownCities.filter { $0.owner == rival }.count
        return 100 * (v.cities.count + c.settlers) < pct * theirs
    }

    /// B: in prepare, with the rule on and a positive prepareSiteRivalWeight, the rival's
    /// remembered cities a Settler's sites are measured from; nil otherwise.
    func rivalSitePreference(_ v: PlayerView) -> RivalSites? {
        guard let pct = ai.prepareSettlersRivalPct, pct > 0, let weight = ai.prepareSiteRivalWeight, weight > 0,
              plan.posture == .prepare, let rival = plan.rival else { return nil }
        let cities = v.knownCities.filter { $0.owner == rival }.compactMap { v.index(of: $0.position) }
        return cities.isEmpty ? nil : RivalSites(weight: weight, cities: cities)
    }

    // MARK: C, the army at the stage

    /// C: the radius around the stage within which the watch stands (0: the rule is off).
    var stageRadius: Int { max(0, ai.prepareStageRadius ?? 0) }

    /// C: with the rule on, in prepare with a target and a rally city, sets the stage and the
    /// terrain cost from it to every tile, both around territory closed to the player's
    /// military (M1 §9). The stage is the tile, among those its army may stand on (known
    /// passable land, no city, not closed to it), within the target's sight (a city sees
    /// `city.sight` tiles, so the rival sees the army there) that is nearest the rally city;
    /// with none there, the one nearest the target (ties: nearer the rally city). Ties: the
    /// lower index.
    func setStage(_ plan: inout Plan, _ v: PlayerView) {
        guard stageRadius > 0, plan.posture == .prepare, let target = plan.target, let toTarget = plan.targetField,
              let rally = plan.rally, let t0 = v.index(of: target.position) else { return }
        let closed = v.aiClosedToMilitary()
        let fromRally = v.aiTerrainCostField(from: [rally.position], blocked: closed)
        var city = [Bool](repeating: false, count: v.tileCount)
        for c in v.knownCities { if let t = v.index(of: c.position) { city[t] = true } }
        func standable(_ t: Int) -> Bool { !closed[t] && !city[t] && fromRally[t] >= 0 && v.aiKnownPassable(t) }
        var best: (key: (Int32, Int32, Int), tile: Int)?
        for t in v.aiTiles(within: rules.constants.city.sight, of: t0) where standable(t) {
            let key = (Int32(0), fromRally[t], t)
            if let b = best, b.key <= key { continue }
            best = (key, t)
        }
        if best == nil {
            for t in 0..<v.tileCount where toTarget[t] >= 0 && standable(t) {
                let key = (toTarget[t], fromRally[t], t)
                if let b = best, b.key <= key { continue }
                best = (key, t)
            }
        }
        guard let best else { return }
        plan.stage = best.tile
        plan.stageField = v.aiTerrainCostField(from: [v.coord(at: best.tile)], blocked: closed)
    }

    /// C: the army units (of `ids`) that gather at the stage: with `prepareStageUnits` n > 0, the
    /// n nearest it by terrain cost (ties: the lower id), else all; none without a stage.
    func stageUnits(_ ids: [UnitID], _ v: PlayerView) -> [UnitID] {
        guard plan.posture == .prepare, plan.stage != nil, let field = plan.stageField else { return [] }
        let n = ai.prepareStageUnits ?? 0
        guard n > 0, ids.count > n else { return ids }
        let ranked = ids.map { id -> (cost: Int32, id: UnitID) in
            let c = v.unit(id).flatMap { v.index(of: $0.position) }.map { field[$0] } ?? -1
            return (c >= 0 ? c : .max, id)
        }.sorted { ($0.cost, $0.id) < ($1.cost, $1.id) }
        return ranked.prefix(n).map(\.id)
    }

    /// C: whether a unit stands within stageRadius of the plan's stage (false without one).
    func atStage(_ unit: Unit, _ plan: Plan, _ v: PlayerView) -> Bool {
        guard let stage = plan.stage, let t = v.index(of: unit.position) else { return false }
        return v.aiDistance(t, stage) <= stageRadius
    }
}
