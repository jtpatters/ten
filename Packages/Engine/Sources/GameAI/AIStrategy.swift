import GameCore

// The strategic picture of a phase (M1 §13 Power, Posture, War, Peace), derived from the
// player's knowledge every phase.

/// What an AI makes of its situation this phase.
struct Plan {
    var posture: AIPosture = .develop
    /// Players at war with this one, in player order.
    var enemies: [PlayerID] = []
    /// The rival prepared against (prepare) or fought (war).
    var rival: PlayerID?
    /// The rival's city the army marches on.
    var target: CitySighting?
    /// Terrain cost from the target to every tile (nil without a target).
    var targetField: [Int32]?
    /// The own city the army gathers at.
    var rally: City?
    /// Terrain cost from the rally city to every tile (nil without a rally city).
    var rallyField: [Int32]?
    /// p3f C (`AIPreparePosture.swift`): in prepare, the tile in the target's sight where the
    /// army unit nearest it stands watch (tile index), and the terrain cost from it (nil: off,
    /// or none).
    var stage: Int?
    var stageField: [Int32]?
    /// At war: the army marches on the target instead of gathering at the rally city.
    var advancing = false
    /// Advancing: enough of the army stands within siegeStageRadius of the target (at least
    /// warMinRanged ranged and warMinMelee melee/antiCavalry units), or the target is down to
    /// half its HP with some of the army there: it assaults the target this phase instead of
    /// staging out of its bombard range.
    var assault = false
    var stagedRanged = 0
    var stagedLine = 0
    /// The war test holds for `rival` (M1 §13), army included.
    var readyForWar = false
    /// Own cities with a visible foreign military unit (recon excluded) within the threat
    /// radius, by id.
    var threatened: [CityID] = []
    /// The good sites (M1 §13 Settling, cost from a Settler aside), by tile index.
    var sites: [Site] = []
    /// Own cities when `sites` was computed.
    var sitesCities = 0
    var goodSiteExists: Bool { !sites.isEmpty }
    /// Power of the AI's army and the estimate of the rival.
    var army = 0
    var estimate = 0
    /// Non-garrison ranged and melee/antiCavalry units near the rally city (prepare only).
    var nearRanged = 0
    var nearLine = 0
    /// The own city (first by id) from which a new unit could reach the frontier: the one city
    /// that builds an explorer (ai-3; computed only early on or while a met rival's cities are
    /// unknown, when an explorer may be wanted).
    var explorerCity: CityID?

    /// A one-line account of the plan, for traces.
    var summary: String {
        "army \(army) vs estimate \(estimate)"
            + (rally.map { " rally \($0.name) (ranged \(nearRanged), melee \(nearLine) near)" } ?? "")
            + (target.map { " target \($0.name)" } ?? "") + (stage.map { " stage #\($0)" } ?? "") + (advancing ? " advancing" : "")
            + (advancing ? " (staged \(stagedRanged) ranged, \(stagedLine) melee\(assault ? ", assault" : ""))" : "")
            + (threatened.isEmpty ? "" : " threatened \(threatened.count)") + " sites \(sites.count)"
    }

    func isThreatened(_ id: CityID) -> Bool { threatened.contains(id) }
}

/// The player's military as M1 §13 counts it.
struct Forces {
    /// Per own city (id order): its garrison, the lowest-id military unit on its tile.
    var garrisons: [(city: CityID, unit: UnitID)] = []
    var garrisonIDs = Set<UnitID>()
    /// Non-garrison, non-recon military units, by id.
    var army: [Unit] = []
    /// Σ power of `army`.
    var power = 0

    func isGarrison(_ id: UnitID) -> Bool { garrisonIDs.contains(id) }
}

/// A site a Settler may head for (M1 §13 Settling).
struct Site {
    var tile: Int
    var score: Int
}

extension AITurn {
    // MARK: Power

    /// Garrisons and the army (M1 §13 Power).
    func forces(_ v: PlayerView) -> Forces {
        var f = Forces()
        let units = v.units
        for city in v.cities {
            if let garrison = units.first(where: { $0.position == city.position && isGuard($0.type) }) {
                f.garrisons.append((city.id, garrison.id))
                f.garrisonIDs.insert(garrison.id)
            }
        }
        f.army = units.filter { isFighter($0.type) && !f.garrisonIDs.contains($0.id) }
        f.power = f.army.reduce(0) { $0 + v.power(of: $1) }
        return f
    }

    /// estimate(R) (M1 §13): Σ power of R's sightings at most `sightingMaxAge` turns old plus
    /// `cityPowerEstimate` per remembered city of R.
    func estimate(of rival: PlayerID, _ v: PlayerView) -> Int {
        let turn = v.turn
        let units = v.sightings(of: rival).filter { turn - $0.turnSeen <= ai.sightingMaxAge }.reduce(0) { $0 + v.power(of: $1) }
        return units + ai.cityPowerEstimate * v.knownCities.filter { $0.owner == rival }.count
    }

    // MARK: Plan

    mutating func makePlan() -> Plan {
        let v = view
        var plan = Plan()
        let forces = forces(v)
        plan.army = forces.power
        let others = v.players.filter { $0.isAlive && $0.isMajor && $0.id != player }.map(\.id)
        plan.enemies = others.filter { v.isAtWar(with: $0) }
        plan.threatened = threatenedCities(v)
        // Good sites matter while the AI may still found cities: below its maximum, or with
        // a Settler alive.
        if v.cities.count < rules.aiMaxCities(mapSize: v.mapSizeName) || v.units.contains(where: { rules.unit($0.type).foundsCity }) {
            plan.sites = goodSites(v)
        }
        plan.sitesCities = v.cities.count
        if v.turn <= ai.earlyTurns || unlocatedRival(v) != nil {
            let cities = v.cities
            plan.explorerCity = v.aiFirstSourceReachingFrontier(cities.map(\.position), by: .scout).map { cities[$0].id }
        }

        if !plan.enemies.isEmpty {
            plan.rival = pickRival(plan.enemies, v)
            if let rival = plan.rival { aim(at: rival, &plan, v) }
        } else {
            // ai-3: a rival is prepared against only if the army can march on it — a target
            // city with a known way to it and an own city to gather at (on a map with islands
            // a rival may be out of reach); else the next best rival.
            var candidates = others.filter { warEligible($0, v) }
            while let rival = pickRival(candidates, v) {
                var trial = plan
                aim(at: rival, &trial, v)
                if trial.target != nil, trial.rally != nil {
                    plan = trial
                    plan.rival = rival
                    break
                }
                candidates.removeAll { $0 == rival }
            }
        }
        if let rival = plan.rival { plan.estimate = estimate(of: rival, v) }

        if !plan.enemies.isEmpty {
            plan.posture = .war
        } else if plan.rival != nil {
            plan.posture = .prepare
        } else if plan.goodSiteExists && v.cities.count < rules.aiMaxCities(mapSize: v.mapSizeName) {
            plan.posture = .expand
        } else {
            plan.posture = .develop
        }

        // p3f C: in prepare, one army unit stands watch at the stage (AIPreparePosture.swift).
        if plan.posture == .prepare { setStage(&plan, v) }

        if let rival = plan.rival, let rally = plan.rally, let targetField = plan.targetField {
            let near = forces.army.filter { v.distance($0.position, rally.position) <= ai.rallyRadius || atStage($0, plan, v) }
            if plan.posture == .prepare {
                // The war test (M1 §13): the rival is eligible; ≥ 2 ranged and ≥ 2 melee or
                // antiCavalry non-garrison units near the rally city; 100·army ≥ 130·estimate.
                let ranged = near.filter { isRanged($0.type) }.count
                let line = near.filter { isLine($0.type) }.count
                plan.nearRanged = ranged
                plan.nearLine = line
                plan.readyForWar = ranged >= ai.warMinRanged && line >= ai.warMinMelee
                    && 100 * plan.army >= ai.warRatioPct * plan.estimate
            } else {
                // The army advances once enough of it has gathered (M1 §13), or 8 turns after
                // the declaration. Stateless: units at least as far along as the rally city
                // (by terrain cost to the target) count as gathered, so the march goes on
                // once begun.
                let since = v.relation(with: rival)?.since ?? v.turn
                let rallyCost = v.index(of: rally.position).map { Int(targetField[$0]) } ?? -1
                let gathered = forces.army.filter { u in
                    if v.distance(u.position, rally.position) <= ai.rallyRadius { return true }
                    guard rallyCost >= 0, let t = v.index(of: u.position) else { return false }
                    return targetField[t] >= 0 && Int(targetField[t]) <= rallyCost
                }.count
                // Once some of the army stands at the target, the march goes on (losses there
                // must not send the rest back to the rally city).
                let staged = plan.target.map { target in forces.army.filter { v.distance($0.position, target.position) <= ai.siegeStageRadius } } ?? []
                plan.advancing = gathered >= ai.advanceArmyUnits || v.turn >= since + ai.advanceAfterTurns || !staged.isEmpty
                if plan.advancing, let target = plan.target {
                    plan.stagedRanged = staged.filter { isRanged($0.type) }.count
                    plan.stagedLine = staged.filter { isLine($0.type) }.count
                    let full = rules.constants.city.maxHP + (target.walls ? wallHP : 0)
                    plan.assault = (plan.stagedRanged >= ai.warMinRanged && plan.stagedLine >= ai.warMinMelee)
                        || (2 * (target.hp + target.wallHP) <= full && staged.count >= 2)
                }
            }
        }
        return plan
    }

    /// The wall HP of the Walls building (M1 §5).
    var wallHP: Int { rules.buildings.map(\.wallHP).max() ?? 0 }

    /// Whether the war test holds for `rival` except for the army (M1 §13 prepare): turn ≥
    /// warMinTurn; met; at peace for ≥ warMinPeaceTurns (or never at war) and allowed to
    /// declare war; a remembered city of the rival exists. (Not at war with anyone: the caller.)
    func warEligible(_ rival: PlayerID, _ v: PlayerView) -> Bool {
        guard v.turn >= ai.warMinTurn, v.hasMet(rival), let relation = v.relation(with: rival), relation.stance == .peace,
              v.warProblem(on: rival) == nil else { return false }
        if let since = relation.since, v.turn - since < ai.warMinPeaceTurns { return false }
        return v.knownCities.contains { $0.owner == rival }
    }

    /// The rival with the highest army / max(estimate, 1) (M1 §13): the lowest estimate, as the
    /// army is the AI's own; ties: the nearest remembered city, then the lower player.
    func pickRival(_ candidates: [PlayerID], _ v: PlayerView) -> PlayerID? {
        let own = v.cities.map(\.position)
        var best: (estimate: Int, distance: Int, player: PlayerID)?
        for r in candidates {
            let e = max(estimate(of: r, v), 1)
            var distance = Int.max
            for city in v.knownCities where city.owner == r {
                for mine in own { distance = min(distance, v.distance(mine, city.position)) }
            }
            if let b = best, (b.estimate, b.distance, b.player.rawValue) <= (e, distance, r.rawValue) { continue }
            best = (e, distance, r)
        }
        return best?.player
    }

    /// The target and the rally city against `rival` (M1 §13): the rival's remembered city with
    /// the lowest path cost from the AI's capital — within `targetCostTolerance` of the lowest,
    /// non-capitals first, then lower id; a city the rival took from the AI first while the army
    /// matches its estimate (p3f) — and the own city with the lowest path cost to it.
    func aim(at rival: PlayerID, _ plan: inout Plan, _ v: PlayerView) {
        let cities = v.cities
        guard !cities.isEmpty else { return }
        let capital = v.me.capital.flatMap { v.city($0) } ?? cities[0]
        let theirs = v.knownCities.filter { $0.owner == rival }
        guard !theirs.isEmpty else { return }
        let fromCapital = v.aiTerrainCostField(from: [capital.position])
        let costs = theirs.map { s in v.index(of: s.position).map { Int(fromCapital[$0]) } ?? -1 }
        guard let lowest = costs.filter({ $0 >= 0 }).min() else { return }
        var target: CitySighting?
        for (i, s) in theirs.enumerated() where costs[i] >= 0 && costs[i] <= lowest + ai.targetCostTolerance {
            if let t = target, (t.capital ? 1 : 0, t.id) <= (s.capital ? 1 : 0, s.id) { continue }
            target = s
        }
        // p3f ai-after-city-loss (AIAfterLoss.swift): a city the rival took comes first while the
        // army matches its estimate.
        if let lost = recaptureTarget(theirs, costs: costs, army: plan.army, v) { target = lost }
        guard let target else { return }
        let field = v.aiTerrainCostField(from: [target.position])
        plan.target = target
        plan.targetField = field
        var rally: (cost: Int, city: City)?
        for city in cities {
            guard let t = v.index(of: city.position), field[t] >= 0 else { continue }
            if let r = rally, r.cost <= Int(field[t]) { continue }
            rally = (Int(field[t]), city)
        }
        if let rally {
            plan.rally = rally.city
            plan.rallyField = v.aiTerrainCostField(from: [rally.city.position])
        }
    }

    // MARK: Threats

    /// Own cities with a visible foreign military unit within the threat radius (M1 §13: "a
    /// visible enemy, or any foreign military unit"). Recon units are left out: they never
    /// attack cities (M1 §7), so a passing Scout does not make a city build Walls.
    func threatenedCities(_ v: PlayerView) -> [CityID] {
        let foreign = foreignMilitaryTiles(v, enemiesOnly: false, includeRecon: false)
        guard !foreign.isEmpty else { return [] }
        return v.cities.compactMap { city in
            guard let c = v.index(of: city.position) else { return nil }
            return foreign.contains { v.aiDistance($0, c) <= ai.threatRadius } ? city.id : nil
        }
    }

    // MARK: Sites

    /// Good sites without the Settler's cost (M1 §13): explored, foundable by the player's
    /// knowledge, settleScore ≥ minSettleScore, at most settleMaxCityDistance tiles from an own
    /// city; by tile index.
    func goodSites(_ v: PlayerView) -> [Site] {
        let cities = v.cities
        guard !cities.isEmpty else { return [] }
        var seen = [Bool](repeating: false, count: v.tileCount)
        var sites: [Site] = []
        let hidden = hiddenCityRisk(v)
        for city in cities {
            guard let c = v.index(of: city.position) else { continue }
            for t in v.aiTiles(within: ai.settleMaxCityDistance, of: c) where !seen[t] {
                seen[t] = true
                let hex = v.coord(at: t)
                guard !hidden[t], v.canFoundCity(at: hex) else { continue }
                let score = v.settleScore(at: hex)
                if score >= ai.minSettleScore { sites.append(Site(tile: t, score: score)) }
            }
        }
        return sites.sorted { $0.tile < $1.tile }
    }

    /// Per tile: the player's knowledge of borders hints at a city it has not seen closer
    /// than the minimum city distance (ai-3), so a Settler should not try to found there.
    /// Every owned tile lies within the border radius of the city that owns it (M1 §5), and a
    /// city at distance minDistance − 1 from a site owns a tile at distance minDistance −
    /// 1 − initialRadius of it (its first ring). So a foreign tile, as last seen, that no known
    /// city of its owner can have claimed betrays an unseen city near it, and sites that close
    /// to it are suspect. A Settler standing on its site sees every tile that close, so this
    /// keeps `foundCity` from being refused for a city hidden just beyond its sight (the
    /// refusal would reveal the city anyway).
    func hiddenCityRisk(_ v: PlayerView) -> [Bool] {
        let c = rules.constants
        var risk = [Bool](repeating: false, count: v.tileCount)
        let reach = c.city.minDistance - 1 - c.city.initialRadius
        guard reach >= 0 else { return risk }
        let territory = v.knownTerritory
        let mine = UInt8(player.rawValue + 1)
        var explained = [Bool](repeating: false, count: v.tileCount)
        for city in v.knownCities where city.owner != player {
            guard let t = v.index(of: city.position) else { continue }
            let code = UInt8(city.owner.rawValue + 1)
            for n in v.aiTiles(within: c.borders.radius, of: t) where territory[n] == code { explained[n] = true }
        }
        for t in 0..<territory.count where territory[t] != 0 && territory[t] != mine && !explained[t] {
            for n in v.aiTiles(within: reach, of: t) { risk[n] = true }
        }
        return risk
    }

    // MARK: Diplomacy

    /// Answers every pending peace proposal (M1 §13 Peace).
    mutating func respondToPeace() {
        for proposer in view.peaceProposals {
            let reason = peaceReason(with: proposer, view)
            note("\(reason == nil ? "refuses" : "accepts") peace from \(proposer)" + (reason.map { ": \($0)" } ?? ": \(warStanding(proposer))"))
            issue(.respondToPeace(from: proposer, accept: reason != nil))
        }
    }

    /// Proposes peace to enemies it wants peace with, where the rules allow a proposal.
    mutating func proposePeaceIfWanted() {
        for enemy in plan.enemies {
            let v = view
            guard v.isAtWar(with: enemy), v.peaceProblem(to: enemy) == nil, let reason = peaceReason(with: enemy, v) else { continue }
            note("proposes peace to \(enemy): \(reason)")
            issue(.proposePeace(to: enemy))
        }
    }

    /// Whether the AI wants peace with `rival` (M1 §13 Peace).
    func wantsPeace(with rival: PlayerID, _ v: PlayerView) -> Bool { peaceReason(with: rival, v) != nil }

    /// Peace (M1 §13): only after ≥ peaceMinWarTurns of war, and only when 100·army <
    /// peaceRatioPct·estimate(R) or no city has changed hands for peaceStaleTurns. A stateless
    /// AI knows when it took a city (its cities' `capturedTurn`); when it lost one it cannot
    /// fairly tell, so "changed hands" counts the war's start and its own captures. Returns why
    /// it wants peace, or nil when it does not.
    func peaceReason(with rival: PlayerID, _ v: PlayerView) -> String? {
        guard let relation = v.relation(with: rival), relation.stance == .war else { return nil }
        let since = relation.since ?? 0
        guard v.turn - since >= ai.peaceMinWarTurns else { return nil }
        let army = forces(v).power, estimate = estimate(of: rival, v)
        if 100 * army < ai.peaceRatioPct * estimate { return "army \(army) < \(ai.peaceRatioPct)% of estimate \(estimate)" }
        let lastCapture = v.cities.compactMap(\.capturedTurn).max() ?? 0
        let quiet = v.turn - max(since, lastCapture)
        return quiet >= ai.peaceStaleTurns ? "no city changed hands for \(quiet) turns" : nil
    }

    /// The army against the estimate of a rival, for notes.
    func warStanding(_ rival: PlayerID) -> String {
        let v = view
        return "army \(forces(v).power) vs estimate \(estimate(of: rival, v))"
    }

    /// Declares war on the rival when the war test holds (M1 §13); at most one war at a time.
    mutating func declareWarIfReady() -> Bool {
        guard plan.posture == .prepare, plan.readyForWar, let rival = plan.rival, plan.enemies.isEmpty,
              view.warProblem(on: rival) == nil else { return false }
        note("declares war on \(rival): army \(plan.army) vs estimate \(plan.estimate), \(plan.nearRanged) ranged + "
            + "\(plan.nearLine) melee at rally \(plan.rally?.name ?? "-"); target \(plan.target?.name ?? "-")")
        return issue(.declareWar(on: rival))
    }

    // MARK: Research

    /// Research orders (M1 §13): the first unknown tech of the posture's order.
    mutating func chooseResearch() {
        let v = view
        let warlike = plan.posture == .prepare || plan.posture == .war || !plan.threatened.isEmpty
        let order = warlike ? ai.researchOrderWar : ai.researchOrderPeace
        guard let next = order.first(where: { !v.me.knows($0) }) else { return }
        if v.me.researchTarget != next || v.me.researching == nil {
            issue(.setResearch(tech: next))
        }
    }

    /// Civic orders (M2 §17.2): the cheapest civic whose prerequisites are done, tree order on ties.
    /// The government with the most slots (later in the list on ties), when free or cheap.
    mutating func chooseGovernment() {
        let v = view
        guard let current = v.government, let all = v.rules.governance?.governments else { return }
        func score(_ g: GovernmentDef) -> Int { g.slots.reduce(0, +) * 100 + (all.firstIndex(of: g) ?? 0) }
        guard let best = v.availableGovernments.max(by: { score($0) < score($1) }),
              score(best) > score(current) else { return }
        let cost = v.governmentChangeCost(to: best.id)
        guard cost == 0 || cost * 2 <= v.me.gold else { return }
        issue(.setGovernment(government: best.id))
    }

    /// Fills slots by `aiWeight`; outside a free-change turn only fills empty slots.
    mutating func choosePolicies() {
        let v = view
        guard let gov = v.government else { return }
        // M2 §17.2: a bonus against raiders weighs more while a raider camp is known.
        let raiderBonus = v.knownRaiderCamps.isEmpty ? 0 : Self.raiderPolicyWeight
        func weight(_ p: PolicyDef) -> Int { (p.aiWeight ?? 0) + (p.bonuses.raiderStrength ?? 0 > 0 ? raiderBonus : 0) }
        let ranked = v.availablePolicies.sorted { (weight($0), $1.id) > (weight($1), $0.id) }
        let current = v.policies
        var pick: [PolicyDef] = []
        if v.isFreeChangeTurn {
            for p in ranked where gov.fits(pick + [p]) { pick.append(p) }
            guard Set(pick.map(\.id)) != Set(current.map(\.id)) else { return }
        } else {
            pick = current
            for p in ranked where !pick.contains(p) && gov.fits(pick + [p]) { pick.append(p) }
            guard pick.count > current.count else { return }
        }
        let cost = v.policyChangeCost(to: pick.map(\.id))
        guard cost == 0 || cost * 3 <= v.me.gold else { return }
        issue(.setPolicies(policies: pick.map(\.id)))
    }

    mutating func chooseCivic() {
        let v = view
        guard v.me.studying == nil else { return }
        let open = v.rules.civics.filter { c in !v.me.knowsCivic(c.id) && c.requires.allSatisfy(v.me.knowsCivic) }
        guard let next = open.min(by: { $0.cost < $1.cost }) else { return }
        issue(.setCivic(civic: next.id))
    }
}
