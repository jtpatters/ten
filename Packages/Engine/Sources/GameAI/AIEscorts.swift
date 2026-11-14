import GameCore

// Escorts for waiting civilians (M1 §13 Safety; p3b ai-settler-escort).
//
// A civilian with no safe way on waits for an escort (`travel`, `seekSafety`). The nearest free
// fighter within escortMaxMoveCost comes to it (`escortCivilians`): to its tile or, where an own
// military unit already holds that tile (a garrisoned city: one military unit per tile, M1 §5),
// to a neighbouring tile on its way, onto which the civilian steps the next phase. When no free
// fighter can come to a waiting Settler, its escort city (the own city whose garrison reaches it
// cheapest within escortMaxMoveCost) sends a free fighter standing by it, or builds the cheapest
// fighter first (AIEconomy step 1b), bought when the treasury holds its price plus
// buyDefenderGoldReserve; the next phase that fighter stands by the city and comes. A Settler
// with no escort city either (it went where closed borders keep its military out) goes on alone
// (`travel`). A civilian that ends a move on a tile made safe only by an own military unit keeps
// that unit there, fortified, for the phase (`holdGuard`). Stateless: requests, spots and orders
// are derived afresh every phase, so a city builds an escort only while a Settler it could reach
// waits with no free fighter to come.
//
// Before this, a one-city AI whose only fighter was its garrison left its Settler waiting as long
// as a foreign Scout stood near its way (an iPhone play-test: T21–T35, one city all game), and a
// Settler waiting in its garrisoned city never got an escort, as none could stand on its tile
// (HeadlessSim, newbie seed 20: 45 turns in its city).

extension AITurn {
    /// Where an escort may join civilian `unit` on its way to `goal` (tile indices, best first):
    /// its tile or, where an own military unit holds that tile, the known-passable neighbours
    /// nearer the goal (none without a goal).
    func escortSpots(for unit: Unit, toward goal: HexCoord?, _ v: PlayerView) -> [Int] {
        guard let here = v.index(of: unit.position) else { return [] }
        guard v.units(at: unit.position).contains(where: { $0.owner == player && isGuard($0.type) }) else { return [here] }
        guard let goal else { return [] }
        let toGoal = v.distanceField(from: goal)
        guard toGoal[here] > 0 else { return [] }
        return v.aiNeighbors(of: here).filter { v.aiKnownPassable($0) && toGoal[$0] >= 0 && toGoal[$0] < toGoal[here] }
            .sorted { (toGoal[$0], $0) < (toGoal[$1], $1) }
    }

    /// The civilian `id` waits for an escort this phase at `spots` (`escortSpots`).
    mutating func waitForEscort(_ id: UnitID, at spots: [Int]) {
        escortWanted.append(id)
        escortSpots[id] = spots
    }

    /// The civilian `id` waits for an escort this phase: it found no safe way toward `goal`.
    mutating func waitForEscort(_ id: UnitID, toward goal: HexCoord?) {
        guard let unit = view.unit(id) else { return }
        waitForEscort(id, at: escortSpots(for: unit, toward: goal, view))
    }

    /// The one of `units` that reaches one of `spots` cheapest (the first spot it reaches; cost
    /// 0: there already), ties lower id, within `limit` (nil: any cost).
    mutating func nearestEscort(among units: [Unit], to spots: [Int], within limit: Int?) -> (cost: Int32, unit: UnitID, spot: Int)? {
        var best: (cost: Int32, unit: UnitID, spot: Int)?
        for u in units {
            let f = limit.map { field(u.id, within: $0) } ?? field(u.id)
            guard let s = spots.first(where: { t in f[t] >= 0 && limit.map { Int(f[t]) <= $0 } ?? true }) else { continue }
            if let b = best, (b.cost, b.unit) <= (f[s], u.id) { continue }
            best = (f[s], u.id, s)
        }
        return best
    }

    /// A waiting Settler's escort city: the own city whose garrison reaches one of its `spots`
    /// cheapest within escortMaxMoveCost (ties lower id); nil when none does.
    mutating func escortCity(for spots: [Int]) -> CityID? {
        guard !spots.isEmpty else { return nil }
        let v = view
        var best: (cost: Int32, city: CityID)?
        for g in forces(v).garrisons {
            guard let unit = v.unit(g.unit), let found = nearestEscort(among: [unit], to: spots, within: rules.points(ai.escortMaxMoveCost)) else { continue }
            if let b = best, (b.cost, b.city) <= (found.cost, g.city) { continue }
            best = (found.cost, g.city)
        }
        return best?.city
    }

    /// Whether an escort could come to a Settler waiting at `spots`: a free fighter within
    /// escortMaxMoveCost, or an escort city to send or build one.
    mutating func escortCanCome(to spots: [Int]) -> Bool {
        nearestEscort(among: freeFighters(view), to: spots, within: rules.points(ai.escortMaxMoveCost)) != nil || escortCity(for: spots) != nil
    }

    /// Civilians waiting for an escort get the nearest free fighter within escortMaxMoveCost of
    /// where it is to join them (their tile, else the first of `escortSpots` it reaches; one
    /// already there counts, at cost 0), ties lower id. A Settler none can come to gets a free
    /// fighter standing within spawnRadius of its escort city (the one the city built for it),
    /// whatever its cost; else it is left `unescorted` and the city builds one.
    mutating func escortCivilians() {
        for id in escortWanted {
            let v = view
            guard live, let civilian = v.unit(id), let t = v.index(of: civilian.position) else { continue }
            let spots = escortSpots[id] ?? [t]
            var best = nearestEscort(among: freeFighters(v), to: spots, within: rules.points(ai.escortMaxMoveCost))
            if best == nil, rules.unit(civilian.type).foundsCity, let city = escortCity(for: spots),
               let c = v.city(city), let ct = v.index(of: c.position) {
                let radius = rules.constants.production.spawnRadius
                let standing = freeFighters(v).filter { u in v.index(of: u.position).map { v.aiDistance($0, ct) <= radius } ?? false }
                best = nearestEscort(among: standing, to: spots, within: nil)
                if best == nil { unescorted.append((id, city)) }
            }
            guard let best else { continue }
            acted.insert(best.unit)
            note("sends \(v.unit(best.unit)?.type.displayName ?? "") \(best.unit) to escort \(civilian.type.displayName) \(id) at "
                + "\(civilian.position) (joins at \(v.coord(at: best.spot)), cost \(best.cost))")
            if !hop(best.unit, toward: v.coord(at: best.spot)), let escort = view.unit(best.unit) { fortify(escort) }
        }
    }

    /// Whether `city` is the escort city of a Settler left `unescorted` this phase: it builds an
    /// escort first (AIEconomy step 1b).
    func buildsEscort(_ city: City) -> Bool {
        unescorted.contains { $0.city == city.id }
    }

    /// An escort a city builds for a waiting Settler (step 1b) is bought when the treasury holds
    /// its price plus buyDefenderGoldReserve and the upkeep rule allows another unit. Returns
    /// whether it was bought.
    mutating func buyEscort(_ head: ProductionItem?, in id: CityID, _ counts: ProductionCounts) -> Bool {
        let v = view
        guard let head, case let .unit(type) = head, isFighter(type), let city = v.city(id), buildsEscort(city) else { return false }
        let price = rules.cost(of: head) * rules.constants.production.purchaseCostMultiplier
        guard v.me.gold >= price + ai.buyDefenderGoldReserve, militaryAffordable(counts.military, atWar: !plan.enemies.isEmpty, v),
              v.aiCompletionProblem(head, in: id) == nil, issue(.purchase(city: id, item: head)) else { return false }
        note("buys \(type.displayName) in \(city.name) for \(price) gold (treasury \(v.me.gold)): an escort for a waiting Settler")
        return true
    }

    /// The civilian `id` ended a move where only an own military unit makes it safe (M1 §13
    /// Safety): that unit stays with it, fortified, for the rest of the phase.
    mutating func holdGuard(of id: UnitID) {
        let v = view
        guard let unit = v.unit(id), unit.type.isCivilian, let t = v.index(of: unit.position), civilianDanger(v)[t],
              !v.cities.contains(where: { $0.position == unit.position }),
              let guardian = v.units(at: unit.position).first(where: { $0.owner == player && isGuard($0.type) }) else { return }
        acted.insert(guardian.id)
        fortify(guardian)
    }
}
