import GameCore

// City production (M1 §13 Cities): a priority list, re-derived every phase from the state —
// defence quota; an escort for a waiting Settler; a Warrior early for exploration (or a Scout to
// find a met rival's cities); Settlers; Builders; Monument; the army in prepare/war; then
// Granary, Library, Market. Never a military unit the treasury cannot keep. Purchases and focus.

/// Counts the production decisions of this phase build on (units alive plus items queued in
/// the cities decided so far).
struct ProductionCounts {
    var settlers = 0
    var builders = 0
    var scouts = 0
    /// Every military unit (recon included): upkeep.
    var military = 0
    /// Naval units.
    var ships = 0
    /// Non-garrison archers and melee/antiCavalry units: the army's mix.
    var armyRanged = 0
    var armyLine = 0
    /// Non-garrison, non-recon military units (alive and queued for the army).
    var army = 0
}

/// One candidate of a city's priority list.
private struct Candidate {
    var item: ProductionItem
    /// Defence: replaces whatever the city was making.
    var urgent: Bool
}

extension AITurn {
    // MARK: Cities

    /// Production, civilian purchases and focus for every own city, in id order.
    mutating func manageCities() {
        guard live else { return }
        var counts = baseCounts()
        let cityIDs = view.cities.map(\.id)
        for id in cityIDs {
            guard live, let city = view.city(id) else { continue }
            if city.focus != .balanced { issue(.setFocus(city: id, focus: .balanced)) }
            var queue = decideQueue(for: id, counts)
            // Settlers and Builders are bought only with twice their price in the treasury.
            if let head = queue.first, case let .unit(type) = head, type == .settler || type == .builder {
                let v = view
                let price = v.productionOptions(for: id).first { $0.item == head }?.buyPrice ?? .max
                if 100 * v.me.gold >= ai.buyCivilianGoldPct * price, v.aiCompletionProblem(head, in: id) == nil,
                   issue(.purchase(city: id, item: head)) {
                    note("buys \(type.displayName) in \(city.name) for \(price) gold (treasury \(v.me.gold))")
                    counts = recount(counts, bought: type)
                    queue = decideQueue(for: id, counts)
                }
            }
            if let current = view.city(id), queue != current.queuedItems {
                issue(.setQueue(city: id, items: queue))
            }
            if !buyEscort(queue.first, in: id, counts) { buyArmyUnit(queue.first, in: id, counts) }
            add(queue, to: &counts)
        }
    }

    /// In prepare or war posture, a city whose first item is an army unit buys one when the
    /// treasury holds buyArmyGoldPct of its price and the upkeep rule allows another unit
    /// (M1 §13 names only defender and civilian purchases; spending the surplus on the army is
    /// ai-2's addition, so the AIs do not sit on hundreds of gold while they prepare and fight).
    mutating func buyArmyUnit(_ head: ProductionItem?, in id: CityID, _ counts: ProductionCounts) {
        guard plan.posture == .prepare || plan.posture == .war, let head, case let .unit(type) = head, isFighter(type) else { return }
        let v = view
        let price = rules.cost(of: head) * rules.constants.production.purchaseCostMultiplier
        guard 100 * v.me.gold >= ai.buyArmyGoldPct * price, militaryAffordable(counts.military, atWar: !plan.enemies.isEmpty, v),
              v.aiCompletionProblem(head, in: id) == nil, let city = v.city(id) else { return }
        if issue(.purchase(city: id, item: head)) {
            note("buys \(type.displayName) in \(city.name) for \(price) gold (treasury \(v.me.gold), \(plan.posture.rawValue))")
        }
    }

    /// Units alive, by what production counts.
    func baseCounts() -> ProductionCounts {
        let v = view
        let f = forces(v)
        var c = ProductionCounts()
        for u in v.units {
            if u.type == .settler { c.settlers += 1 }
            if u.type == .builder { c.builders += 1 }
            if isRecon(u.type) { c.scouts += 1 }
            if !u.type.isCivilian { c.military += 1 }
            if u.type.isNaval { c.ships += 1 }
        }
        for u in f.army {
            c.army += 1
            if isRanged(u.type) { c.armyRanged += 1 } else if isLine(u.type) { c.armyLine += 1 }
        }
        return c
    }

    private func recount(_ counts: ProductionCounts, bought type: UnitType) -> ProductionCounts {
        var c = counts
        if type == .settler { c.settlers += 1 }
        if type == .builder { c.builders += 1 }
        if type.isNaval { c.ships += 1 }
        return c
    }

    /// Adds a decided queue to the counts.
    private func add(_ queue: [ProductionItem], to c: inout ProductionCounts) {
        for item in queue {
            guard case let .unit(type) = item else { continue }
            if type == .settler { c.settlers += 1 }
            if type == .builder { c.builders += 1 }
            if isRecon(type) { c.scouts += 1 }
            if !type.isCivilian { c.military += 1 }
            if type.isNaval { c.ships += 1 }
            if isFighter(type) {
                c.army += 1
                if isRanged(type) { c.armyRanged += 1 } else if isLine(type) { c.armyLine += 1 }
            }
        }
    }

    /// The queue a city should have: its first choice (or the item it is making, if still
    /// wanted and far enough along), followed, when that item would wait (a Settler at
    /// population 1), by the next choice that would not.
    func decideQueue(for id: CityID, _ counts: ProductionCounts) -> [ProductionItem] {
        let v = view
        guard let city = v.city(id) else { return [] }
        let candidates = priorityList(for: city, counts, v)
        guard let top = candidates.first else { return [] }
        var primary = top
        if let current = city.queue.first, current.item != top.item, !top.urgent,
           let wanted = candidates.first(where: { $0.item == current.item }) {
            let cost = rules.cost(of: current.item)
            if 100 * current.progress >= ai.queueSwitchProgressPct * cost { primary = wanted }
        }
        var queue = [primary.item]
        if v.aiCompletionProblem(primary.item, in: id) != nil,
           let filler = candidates.first(where: { $0.item != primary.item && v.aiCompletionProblem($0.item, in: id) == nil }) {
            queue.append(filler.item)
        }
        return queue
    }

    /// The city's priority list (M1 §13 Cities), wanted items only, best first.
    private func priorityList(for city: City, _ c: ProductionCounts, _ v: PlayerView) -> [Candidate] {
        var list: [Candidate] = []
        func offer(_ item: ProductionItem, urgent: Bool = false) {
            guard available(item, in: city, v), !list.contains(where: { $0.item == item }) else { return }
            list.append(Candidate(item: item, urgent: urgent))
        }
        // A quarter on its best site (M2 §5.3), unless one of the kind is already queued.
        func offerQuarter(_ kind: QuarterKind) {
            guard !city.queue.contains(where: { if case .quarter(kind, _) = $0.item { true } else { false } }),
                  let site = v.quarterSites(kind, in: city.id).first else { return }
            offer(.quarter(kind, at: site.tile))
        }
        let cities = v.cities.count
        let atWar = !plan.enemies.isEmpty
        let threatened = plan.isThreatened(city.id)
        let canKeepMilitary = militaryAffordable(c.military, atWar: atWar, v)

        // 0. p3f ai-after-city-loss (AIAfterLoss.swift): an AI left with one city after losing
        //    one, at peace, builds its Settler right after the city's garrison.
        if resettles(c, v) {
            if lacksGarrison(city, v), canKeepMilitary, let defender = cheapestFighter(v) { offer(.unit(defender), urgent: true) }
            offer(.unit(.settler))
        }

        // 1. Defence quota: a garrison; two defenders plus Walls when threatened.
        if needsDefender(city, v), canKeepMilitary, let defender = threatened ? bestDefender(v) : cheapestFighter(v) {
            offer(.unit(defender), urgent: true)
        }
        if threatened {
            offer(.building(wallsID), urgent: true)
            offer(.building(castleID), urgent: true)
        }

        // 1b. An escort for a waiting Settler no free fighter can come to, in its escort city
        //     (p3b ai-settler-escort, AIEscorts.swift).
        if canKeepMilitary, buildsEscort(city), let fighter = cheapestFighter(v) {
            offer(.unit(fighter), urgent: true)
        }

        // 2. Exploration: a Warrior early if there is no Scout; a Scout to find a met rival's
        //    cities. Only in a city from which a new unit could reach the frontier (ai-3): a
        //    rival met across the sea or behind a third player's closed borders is out of a
        //    Scout's reach, and a Scout built for it would be disbanded at once for want of
        //    anything to explore, then built again, phase after phase.
        if c.scouts == 0, canKeepMilitary, plan.explorerCity == city.id {
            if v.turn <= ai.earlyTurns, c.army == 0 { offer(.unit(.warrior)) }
            if unlocatedRival(v) != nil { offer(.unit(.scout)) }
        }

        // 1c. M2 §8: a city projected below Content queues its Monument first; one near its
        //     Housing, its Granary.
        if let w = v.wellbeing(of: city.id) {
            if w.breakdown.total < 0 { offer(.building(monumentID)) }
            if city.population >= w.housing.total - 1 {
                offer(.building(granaryID))
                offerQuarter("aqueduct")
            }
        }

        // 2a. A few ships in coastal cities after the early turns (M2 §8.4), ahead of Settlers
        //     and the army: the quota is small, and below the defence quota and the army a
        //     ship is never the first choice.
        if v.turn > ai.earlyTurns, canKeepMilitary, let ship = shipToBuild(for: city, c, v) { offer(.unit(ship)) }

        // 2b. In prepare/war with at least armyFirstCities cities, Builders (step 4) and then
        //     the army (step 6) come before Settlers. Otherwise an AI that keeps finding sites
        //     spends its production on Settlers through prepare and has almost no army before
        //     turn ~55; the Builders keep the army from starving its improvements (p3 early-game).
        //     p3f B (AIPreparePosture.swift): not in prepare while Settlers stay ahead of the army.
        let armyFirst = (plan.posture == .prepare || plan.posture == .war) && cities >= ai.armyFirstCities
            && !settlersAheadOfArmy(c, v)
        if armyFirst, c.builders < ceilPct(cities, ai.buildersPerCityPct), !improvableWorkedTiles(v).isEmpty {
            offer(.unit(.builder))
        }
        if armyFirst, canKeepMilitary, let unit = armyUnit(c, v) {
            offer(.unit(unit))
        }

        // 3. Settlers.
        let enemyNear = foreignMilitaryTiles(v, enemiesOnly: true, includeRecon: true).contains { t in
            v.index(of: city.position).map { v.aiDistance(t, $0) <= ai.threatRadius } ?? false
        }
        // "cities < max cities" counts the Settlers alive and queued as cities to be, so the
        // AI never founds more than its maximum (M1 §13 is silent; simplest reading). At war,
        // none in a front-line city either (p3d, `frontLine`).
        if plan.goodSiteExists, cities + c.settlers < rules.aiMaxCities(mapSize: v.mapSizeName),
           c.settlers < ceilPct(cities, ai.settlersPerCityPct), !enemyNear, !atWar || !frontLine(city, v) {
            offer(.unit(.settler))
        }

        // 4. Builders while worked tiles lack improvements (≤ 1 per 2 cities).
        if c.builders < ceilPct(cities, ai.buildersPerCityPct), !improvableWorkedTiles(v).isEmpty {
            offer(.unit(.builder))
        }

        // 5. Monument early: in the first earlyTurns turns (later it comes with the other
        //    buildings, below the army).
        if v.turn <= ai.earlyTurns { offer(.building(monumentID)) }

        // 6. The army in prepare/war: at least 1 Archer per 2 melee units once Archery is known.
        if plan.posture == .prepare || plan.posture == .war, canKeepMilitary, let unit = armyUnit(c, v) {
            offer(.unit(unit))
        }

        // 7. Granary, Library, Market (the Monument first if it is still missing).
        //    M2 §5.3: the Campus and Market quarters first, so the Library and Market can follow;
        //    then the Workshop and Harbor quarters and their buildings.
        offer(.building(monumentID))
        offer(.building(granaryID))
        offerQuarter("campus")
        offer(.building(libraryID))
        offerQuarter("market")
        for building in [marketID, waterMillID, "university", "bank"] { offer(.building(building)) }
        for kind: QuarterKind in ["workshop", "harbor"] { offerQuarter(kind) }
        for building: BuildingID in ["workshop", "lighthouse"] { offer(.building(building)) }

        // Nothing else wanted: Walls, then an army unit the treasury can keep.
        offer(.building(wallsID))
        if canKeepMilitary, let unit = armyUnit(c, v) { offer(.unit(unit)) }
        return list
    }

    // Building ids M1 names (rules data ids).
    var monumentID: BuildingID { "monument" }
    var granaryID: BuildingID { "granary" }
    var libraryID: BuildingID { "library" }
    var castleID: BuildingID { "castle" }
    var marketID: BuildingID { "market" }
    var waterMillID: BuildingID { "waterMill" }
    var wallsID: BuildingID { rules.buildings.first { $0.wallHP > 0 }?.id ?? "walls" }

    /// ⌈n · pct / 100⌉.
    func ceilPct(_ n: Int, _ pct: Int) -> Int { (n * pct + 99) / 100 }

    /// Whether a city may queue `item` now: its tech is known, a building is buildable and not
    /// built (M1 §5).
    func available(_ item: ProductionItem, in city: City, _ v: PlayerView) -> Bool {
        switch item {
        case let .unit(type):
            return fieldable(type, v)
        case let .building(id):
            guard let def = rules.building(id), def.buildable, !city.has(id) else { return false }
            if def.requiresRiver == true, (v.tile(at: city.position)?.riverEdges ?? 0) == 0 { return false }
            if let kind = def.quarter, city.quarters?.contains(where: { $0.kind == kind && !$0.isPillaged }) != true { return false }
            if let other = def.requires, !city.has(other) { return false }
            if let other = def.excludes, city.has(other) { return false }
            return def.tech.map(v.me.knows) ?? true
        case let .quarter(kind, at):
            return v.quarterSites(kind, in: city.id).contains { $0.tile == at }
        }
    }

    /// M1 §13: never start a military unit if net gold after its upkeep would be < 0, unless at
    /// war and gold ≥ warGoldDeficitMultiplier × the deficit. `military` counts the units
    /// alive and already queued this phase.
    func militaryAffordable(_ military: Int, atWar: Bool, _ v: PlayerView) -> Bool {
        let income = v.income()
        let perUnit = rules.constants.upkeep.goldPerUnit
        let net = income.gold - max(0, military + 1 - income.freeUnits) * perUnit
        if net >= 0 { return true }
        return atWar && v.me.gold >= ai.warGoldDeficitMultiplier * -net
    }

    /// The best defender the player can build (M1 §13 leaves "best" open): a ranged unit once
    /// known, since a city is attacked as a whole (any garrison adds the same City Strength)
    /// and a ranged garrison shoots attackers every turn without retaliation; otherwise the
    /// highest Strength (ties: cheaper).
    func bestDefender(_ v: PlayerView) -> UnitType? {
        var best: UnitType?
        for type in UnitType.allCases where isFighter(type) && fieldable(type, v) {
            let def = rules.unit(type)
            if let b = best {
                let bd = rules.unit(b)
                if (bd.isRanged ? 1 : 0, bd.strength, -bd.cost) >= (def.isRanged ? 1 : 0, def.strength, -def.cost) { continue }
            }
            best = type
        }
        return best
    }

    /// The cheapest fighter the player can build (ties: stronger): the garrison of a city that
    /// is not threatened, which only adds City Strength.
    func cheapestFighter(_ v: PlayerView) -> UnitType? {
        var best: UnitType?
        for type in UnitType.allCases where isFighter(type) && fieldable(type, v) {
            let def = rules.unit(type)
            if let b = best {
                let bd = rules.unit(b)
                if (-bd.cost, bd.strength) >= (-def.cost, def.strength) { continue }
            }
            best = type
        }
        return best
    }

    /// The next army unit (M1 §13): an Archer while there are fewer than warMinRanged or fewer
    /// than archersPerMeleePct of the melee units, once Archery is known; otherwise the
    /// strongest melee or antiCavalry unit available.
    func armyUnit(_ c: ProductionCounts, _ v: PlayerView) -> UnitType? {
        let archer = UnitType.allCases.first { isRanged($0) && isFighter($0) && fieldable($0, v) }
        if let archer, c.armyRanged < ai.warMinRanged || 100 * c.armyRanged < ai.archersPerMeleePct * c.armyLine {
            return archer
        }
        var best: UnitType?
        for type in UnitType.allCases where isLine(type) && fieldable(type, v) {
            if let b = best, rules.unit(b).strength >= rules.unit(type).strength { continue }
            best = type
        }
        return best ?? archer
    }

    /// The strongest naval unit `city` can build while the player has fewer ships (alive and
    /// queued) than shipsPerCoastalCityPct of its coastal cities, rounded up.
    func shipToBuild(for city: City, _ c: ProductionCounts, _ v: PlayerView) -> UnitType? {
        guard let pct = ai.shipsPerCoastalCityPct, pct > 0, v.isCoastal(city) else { return nil }
        let coastal = v.cities.filter { v.isCoastal($0) }.count
        guard c.ships < ceilPct(coastal, pct) else { return nil }
        var best: UnitType?
        for type in UnitType.allCases where type.isNaval && fieldable(type, v) {
            if let b = best, (rules.unit(b).strength, -rules.unit(b).cost) >= (rules.unit(type).strength, -rules.unit(type).cost) { continue }
            best = type
        }
        return best
    }

    /// The defence quota (M1 §13): a city needs a garrison (a non-recon military unit on its
    /// tile, or one sent this phase); a threatened city needs `threatenedDefenders` such units
    /// on or next to its tile.
    func needsDefender(_ city: City, _ v: PlayerView) -> Bool {
        let units = v.units.filter { isFighter($0.type) }
        if plan.isThreatened(city.id) {
            let near = units.filter { v.distance($0.position, city.position) <= 1 }.count
            return near < ai.threatenedDefenders
        }
        let quota = ai.defendersPerCity
        guard quota > 0 else { return false }
        let onTile = units.contains { $0.position == city.position }
        if quota == 1 { return !onTile && garrisonSent[city.id] == nil }
        return units.filter { v.distance($0.position, city.position) <= 1 }.count < quota
    }

    /// p3d (ai-settlers-at-war): at war, whether an enemy military unit has `city` within reach —
    /// its tile or a neighbouring one lies where a Settler keeps out (M1 §13 Safety: a visible
    /// enemy's next-phase reach, a remembered one's radius; `civilianDanger`, enemies only). A
    /// Settler built there would only wait in the city for an escort the front keeps busy
    /// (HeadlessSim: 12–28 phases). A visible enemy within threatRadius stops Settlers anyway.
    func frontLine(_ city: City, _ v: PlayerView) -> Bool {
        guard let c = v.index(of: city.position) else { return false }
        let danger = civilianDanger(v, enemiesOnly: true)
        return danger[c] || v.aiNeighbors(of: c).contains { danger[$0] }
    }

    /// A met rival none of whose cities the player remembers (M1 §13 Exploring), lowest first.
    func unlocatedRival(_ v: PlayerView) -> PlayerID? {
        v.players.first { p in
            p.id != player && p.isAlive && v.hasMet(p.id) && !v.knownCities.contains { $0.owner == p.id }
        }?.id
    }

    // MARK: Builders' work

    /// Worked, unimproved own tiles a Builder could improve now, with the improvement and its
    /// rank (M1 §13 Builders: Farm by fresh water first, Mines on hills, then Pastures; then a
    /// Farm anywhere else), by tile index.
    func improvableWorkedTiles(_ v: PlayerView) -> [(tile: Int, improvement: Improvement, rank: Int)] {
        var result: [(tile: Int, improvement: Improvement, rank: Int)] = []
        var worked: [Int] = []
        for city in v.cities {
            for hex in city.workedTiles { if let t = v.index(of: hex) { worked.append(t) } }
        }
        for t in worked.sorted() {
            if let (improvement, rank) = bestImprovement(at: t, v) { result.append((t, improvement, rank)) }
        }
        return result
    }

    /// The improvement a Builder should build on tile `t`, with its rank, if any.
    /// M2 §3.1: a known resource's own improvement first (strategic and luxury before bonus).
    func bestImprovement(at hex: HexCoord, _ v: PlayerView) -> (Improvement, Int)? {
        if let r = v.resource(at: hex), let def = rules.resource(r),
           let improvement = Improvement.allCases.first(where: { String(describing: $0) == def.improvement }),
           v.aiImprovementProblem(improvement, at: hex) == nil {
            return (improvement, 0)
        }
        let farm = v.aiImprovementProblem(.farm, at: hex) == nil
        if farm, v.aiHasFreshWater(at: hex) { return (.farm, 0) }
        if v.aiImprovementProblem(.mine, at: hex) == nil { return (.mine, 1) }
        if v.aiImprovementProblem(.pasture, at: hex) == nil { return (.pasture, 2) }
        if farm { return (.farm, 3) }
        if v.aiImprovementProblem(.lumberMill, at: hex) == nil { return (.lumberMill, 4) }
        return nil
    }

    func bestImprovement(at t: Int, _ v: PlayerView) -> (Improvement, Int)? {
        bestImprovement(at: v.coord(at: t), v)
    }

    /// M2 §3.3: the tiles a road between each own city (after the first, id order) and the nearest
    /// earlier one (within roadMaxDistance tiles) still needs, along the cheapest known-terrain
    /// route: explored land, own or unowned, without a remembered road and not a city centre.
    /// Empty without the road tech.
    func roadWork(_ v: PlayerView) -> [Int] {
        guard let roads = rules.roads, v.me.knows(roads.tech) else { return [] }
        let cities = v.cities.sorted { $0.id.rawValue < $1.id.rawValue }
        let centres = Set(cities.compactMap { v.index(of: $0.position) })
        let mine = UInt8(player.rawValue + 1)
        var result: [Int] = []
        for (i, city) in cities.enumerated() where i > 0 {
            guard let target = cities[..<i].min(by: { a, b in
                (v.distance(a.position, city.position), a.id.rawValue) < (v.distance(b.position, city.position), b.id.rawValue)
            }), v.distance(target.position, city.position) <= Self.roadMaxDistance else { continue }
            let field = v.aiTerrainCostField(from: [target.position], limit: Self.roadMaxDistance * 4)
            guard var t = v.index(of: city.position), field[t] > 0 else { continue }
            while field[t] > 0 {
                var next: Int?
                for n in v.neighbors(of: v.coord(at: t)).compactMap({ v.index(of: $0) }) where field[n] >= 0 && field[n] < field[t] {
                    if let b = next, (field[b], b) <= (field[n], n) { continue }
                    next = n
                }
                guard let n = next else { break }
                t = n
                guard !centres.contains(t), v.me.explored[t], !v.me.memory.remembersRoad(t) else { continue }
                let owner = v.me.memory.tileOwner[t]
                guard owner == 0 || owner == mine, let tile = v.tile(at: v.coord(at: t)), tile.isLand, rules.isPassable(tile) else { continue }
                if !result.contains(t) { result.append(t) }
            }
        }
        return result
    }

    static let roadMaxDistance = 8

    // MARK: Purchases

    /// Defenders bought for threatened cities short of their quota (M1 §13: gold ≥ price +
    /// buyDefenderGoldReserve), under the same upkeep rule as production.
    mutating func buyThreatDefenders() {
        for id in plan.threatened {
            let v = view
            guard live, let city = v.city(id), needsDefender(city, v), let defender = bestDefender(v),
                  militaryAffordable(baseCounts().military, atWar: !plan.enemies.isEmpty, v) else { continue }
            let item = ProductionItem.unit(defender)
            guard let option = v.productionOptions(for: id).first(where: { $0.item == item }),
                  v.me.gold >= option.buyPrice + ai.buyDefenderGoldReserve, v.aiCompletionProblem(item, in: id) == nil else { continue }
            if issue(.purchase(city: id, item: item)) {
                note("buys \(defender.displayName) in threatened \(city.name) for \(option.buyPrice) gold (treasury \(v.me.gold))")
            }
        }
    }
}
