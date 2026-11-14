// Read-only queries for the App's city panel and attention queue (M1 §16), built only from what
// the player knows: its own cities and treasury in full, foreign units only where it sees them.

/// An own city's growth (M1 §5) as the city panel shows it.
public struct CityGrowth: Hashable, Sendable {
    public var population: Int
    /// Food in the store.
    public var foodStore: Int
    /// The store at which the city grows (`Ruleset.growthThreshold`).
    public var threshold: Int
    /// Food into (or, when negative, out of) the store per phase.
    public var surplus: Int
    /// Phases until it grows (nil when the store is not filling).
    public var turnsToGrow: Int?
    /// Phases until the store would go below 0 and the city lose a citizen (nil unless it is
    /// starving; a city of population 1 never shrinks).
    public var turnsToShrink: Int?
}

/// An own city's Housing and Stability (M2 §5.1, §5.2).
public struct CityWellbeing: Hashable, Sendable {
    public var housing: HousingBreakdown
    /// Percent of a positive food surplus that goes into the store.
    public var growthPct: Int
    /// The Stability its yields use (from its phase start) and its state.
    public var stability: Int
    public var state: StabilityState
    /// Its Stability by source as things stand now (the next phase start's value).
    public var breakdown: StabilityBreakdown
}

/// Why a queued item waits instead of taking production (M1 §5 "An item waits while it cannot").
public enum ProductionWait: Hashable, Sendable {
    /// A unit that needs this population to complete (a Settler in a city of population 1).
    case population(Int)
    /// A unit with no tile to appear on (M1 §5 Spawning).
    case noRoom
    /// A unit that needs `needed` of a strategic resource the stockpile has only `have` of
    /// (M2 §3.1).
    case resource(Resource, needed: Int, have: Int)
}

/// One entry of an own city's queue as the city panel shows it.
public struct QueueItemStatus: Hashable, Sendable {
    public var item: ProductionItem
    public var name: String
    public var cost: Int
    /// Production in the entry; the entry that takes the next production also counts the
    /// city's stored progress (M1 §5).
    public var progress: Int
    /// Why it waits (nil: it can complete): now, or once the entries before it have completed
    /// (a Settler after another Settler finds the city one smaller, M1 §5, unless the city has
    /// grown back by then at its current food surplus).
    public var wait: ProductionWait?
    /// Phases until it completes if the queue is built in order at the city's current
    /// production, one item per phase at most (nil while it waits, or with no production). An
    /// item that completes leaves its overflow, capped at the phase's production, to the next
    /// item that takes production (M1 §5), and the forecast counts it.
    public var turns: Int?
    /// This entry takes the next phase's production (the first entry that does not wait).
    public var receivesProduction: Bool
    /// The city's stored progress that `progress` counts (the entry taking the next production;
    /// 0 for the others).
    public var storedIncluded = 0
    /// `wait` is foreseen, not now: an earlier entry that costs population (a Settler) leaves
    /// the city too small for this one.
    public var waitIsForeseen = false
    /// The foreseen wait rests on the growth forecast: the city grows, only not enough by then
    /// at its current surplus, so a better surplus may spare the wait.
    public var waitIsUncertain = false
}

/// An own city's stored production (M1 §5) as the city panel shows it (`storedProduction`).
public struct StoredProduction: Hashable, Sendable {
    /// Production stored for the next item.
    public var amount: Int
    /// The queue entry it goes into at the next phase start (the one that takes production);
    /// nil while none does, an empty queue or only items that wait.
    public var receiver: Int?
    /// While no entry takes production, the most the store keeps: `storedProgressCapMultiplier`
    /// × the phase's production. Production beyond it is lost (progress already stored above it
    /// stays).
    public var cap: Int
    /// Production the next phase start loses to the cap (0 while an entry takes production).
    public var lostNextPhase: Int
}

/// What upkeep would do at the start of the player's next phase (M1 §7.1), from the current
/// income: the treasury after gold and upkeep, and how many military units would be disbanded
/// because the treasury cannot pay.
public struct UpkeepForecast: Hashable, Sendable {
    public var goldAfter: Int
    public var disbanded: Int
    /// Military units that complete at that phase start, before upkeep is paid (counted).
    public var completing: Int = 0
    /// Upkeep the treasury cannot pay even after disbanding; the phase's science falls by it (M2 §5.4).
    public var shortfall: Int = 0
}

extension PlayerView {
    /// An own city's Housing and Stability (nil without the rules or for another's city).
    public func wellbeing(of id: CityID) -> CityWellbeing? {
        guard rules.stability != nil, let city = city(id), let index = state.cityIndex(id) else { return nil }
        let breakdown = state.stabilityBreakdowns(for: city.owner)[index] ?? StabilityBreakdown()
        let stability = city.stability ?? breakdown.total
        return CityWellbeing(housing: state.housing(of: city), growthPct: state.growthPct(of: city), stability: stability,
                             state: rules.stabilityState(stability), breakdown: breakdown)
    }

    /// An own city's food store, threshold, surplus and the phases until it grows or shrinks.
    public func growth(of id: CityID) -> CityGrowth? {
        guard let city = city(id) else { return nil }
        let surplus = state.cityYields(city).foodSurplus
        let threshold = rules.growthThreshold(population: city.population)
        var grow: Int?, shrink: Int?
        if surplus > 0 {
            grow = max(1, (threshold - city.foodStore + surplus - 1) / surplus)
        } else if surplus < 0, city.population > 1 {
            // The phase in which the store would go below 0 (M1 §5).
            shrink = city.foodStore / -surplus + 1
        }
        return CityGrowth(population: city.population, foodStore: city.foodStore, threshold: threshold, surplus: surplus,
                          turnsToGrow: grow, turnsToShrink: shrink)
    }

    /// Why an item of an own city would wait now (nil: it could complete): a unit needs the
    /// city's population and a tile to appear on (M1 §5). Buildings never wait.
    public func productionWait(_ item: ProductionItem, in id: CityID) -> ProductionWait? {
        guard let city = city(id) else { return nil }
        return productionWait(item, in: city)
    }

    func productionWait(_ item: ProductionItem, in city: City) -> ProductionWait? {
        guard case let .unit(type) = item else { return nil }
        let def = rules.unit(type)
        if city.population < def.minPopulation { return .population(def.minPopulation) }
        // Own tiles are always visible to their owner, so this reads nothing hidden.
        if state.spawnTile(for: type, in: city) == nil { return .noRoom }
        if let r = state.resourceNeeded(by: type), let s = rules.stockpile, me.stock(r) < s.unitCost {
            return .resource(r, needed: s.unitCost, have: me.stock(r))
        }
        return nil
    }

    /// An own city's queue in order: each entry's progress, why it waits, the phases until it
    /// completes, and which entry takes the next production. The city's population is carried
    /// down the queue: it grows (or starves) phase by phase at the current food surplus, and a
    /// unit that costs population (a Settler) leaves the city smaller for the entries after it,
    /// so a later Settler may wait for the city to grow back. So is the production: an item's
    /// overflow, capped at the phase's production, goes into the next item that takes it, as the
    /// engine stores it (M1 §5).
    public func queueStatus(of id: CityID) -> [QueueItemStatus] {
        guard let city = city(id) else { return [] }
        let yields = state.cityYields(city)
        let production = yields.total.production
        var stored = city.storedProgress
        var elapsed = 0
        var receiverFound = false
        // What the item forecast to complete last leaves for the next one (stored progress).
        var carried = 0
        var people = PopulationForecast(rules: rules, surplus: yields.foodSurplus, population: city.population,
                                        store: city.foodStore)
        // A unit first in the queue that waits for population takes the production meanwhile
        // (M1 §5, `waitingHeadFillLimit`), up to its limit, the store keeping the rest: it is the
        // entry taking the next production, and it completes in the first phase the city has the
        // population (food comes first) and the production has reached its cost.
        let fillLimit = state.waitingHeadFillLimit(city)
        return city.queue.enumerated().map { index, entry in
            let cost = state.cost(of: entry)
            var wait = productionWait(entry.item, in: city)
            if index == 0, let limit = fillLimit, case let .unit(type) = entry.item {
                let def = rules.unit(type)
                receiverFound = true
                // The store it takes at the next phase: what fits under its limit beside the
                // phase's production (the engine pools them and keeps the rest stored).
                let included = max(0, stored - max(0, entry.progress + production + stored - limit))
                let pooled = entry.progress + stored
                stored = 0
                var turns: Int?
                if production > 0 {
                    let filled = max(1, (max(0, min(cost, limit) - pooled) + production - 1) / production)
                    var growth = people
                    while growth.population < def.minPopulation, growth.phase < 500 { growth.advance(to: growth.phase + 1) }
                    if growth.population >= def.minPopulation {
                        let done = max(filled, max(growth.phase, 1), (max(0, cost - pooled) + production - 1) / production)
                        turns = done
                        elapsed = done
                        carried = min(max(0, pooled + done * production - cost), production)
                        people.advance(to: done)
                        people.population = max(1, people.population - def.populationCost)
                    } else {
                        // It never completes at this surplus: once it is full, the entries after
                        // it take the production.
                        elapsed = filled
                    }
                }
                return QueueItemStatus(item: entry.item, name: state.itemName(entry.item), cost: cost,
                                       progress: min(entry.progress + included, cost), wait: wait, turns: turns,
                                       receivesProduction: true, storedIncluded: included)
            }
            var foreseen = false, uncertain = false
            if wait == nil, case let .unit(type) = entry.item {
                let def = rules.unit(type)
                // An entry after the one taking production now starts once those before it
                // are done: the city as it will be then, its food step coming first (M1 §5).
                if receiverFound { people.advance(to: elapsed + 1) }
                if people.population < def.minPopulation {
                    wait = .population(def.minPopulation)
                    foreseen = true
                    uncertain = yields.foodSurplus > 0
                }
            }
            var progress = entry.progress
            var turns: Int?
            var receives = false
            var included = 0
            if wait == nil {
                // Where the forecast starts it: the stored progress for the entry that takes the
                // next production, else what the item before it left over.
                var start = entry.progress + carried
                if !receiverFound {
                    receives = true
                    receiverFound = true
                    progress += stored
                    included = stored
                    start = progress
                    stored = 0
                }
                if production > 0 {
                    let phases = max(1, (max(0, cost - start) + production - 1) / production)
                    elapsed += phases
                    turns = elapsed
                    carried = min(max(0, start + phases * production - cost), production)
                }
                // It completes after the food step of its last phase, costing its population.
                if case let .unit(type) = entry.item, rules.unit(type).populationCost > 0 {
                    people.advance(to: elapsed)
                    people.population = max(1, people.population - rules.unit(type).populationCost)
                }
            }
            return QueueItemStatus(item: entry.item, name: state.itemName(entry.item), cost: cost, progress: min(progress, cost),
                                   wait: wait, turns: turns, receivesProduction: receives, storedIncluded: included,
                                   waitIsForeseen: foreseen, waitIsUncertain: uncertain)
        }
    }

    /// An own city's stored production (M1 §5) and where it goes: into the entry that takes the
    /// next production, or, while none does (an empty queue, or only items that wait), it stays
    /// in the store, which keeps at most `cap`.
    public func storedProduction(of id: CityID) -> StoredProduction? {
        guard let city = city(id) else { return nil }
        let production = state.cityYields(city).total.production
        let cap = rules.constants.production.storedProgressCapMultiplier * production
        let receiver = queueStatus(of: id).firstIndex(where: \.receivesProduction)
        // As `runProduction` keeps it: up to the cap, never less than what is stored already.
        let kept = max(city.storedProgress, min(city.storedProgress + production, cap))
        return StoredProduction(amount: city.storedProgress, receiver: receiver, cap: cap,
                                lostNextPhase: receiver == nil ? city.storedProgress + production - kept : 0)
    }

    /// The treasury and forced disbanding at the player's next phase start (M1 §3 step 3,
    /// §7.1), from the cities' current gold and the current upkeep, counting the military units
    /// that complete at that phase start (production comes before the gold step).
    public func upkeepForecast() -> UpkeepForecast {
        let income = income()
        let perUnit = rules.constants.upkeep.goldPerUnit
        let free = income.freeUnits
        let completing = militaryUnitsCompleting()
        var military = income.militaryUnits + completing
        let gold = me.gold + income.gold
        func upkeep(_ units: Int) -> Int { max(0, units - free) * perUnit + income.buildings }
        var disbanded = 0
        while gold - upkeep(military) < 0, military > free {
            military -= 1
            disbanded += 1
        }
        return UpkeepForecast(goldAfter: max(0, gold - upkeep(military)), disbanded: disbanded, completing: completing,
                              shortfall: max(0, upkeep(military) - gold))
    }

    /// Own cities whose next production completes a military unit at the player's next phase
    /// start: the entry that receives production (the first that does not wait) is one, and
    /// its progress, the stored progress and the city's production reach its cost (M1 §5).
    func militaryUnitsCompleting() -> Int {
        cities.reduce(0) { count, city in
            // A unit filling while it waits for population takes the production (M1 §5), and
            // completes only once the city has grown: no unit completes there next phase.
            guard state.waitingHeadFillLimit(city) == nil,
                  let entry = city.queue.first(where: { productionWait($0.item, in: city) == nil }),
                  case let .unit(type) = entry.item, !type.isCivilian else { return count }
            let production = state.cityYields(city).total.production
            return entry.progress + city.storedProgress + production >= state.cost(of: entry) ? count + 1 : count
        }
    }

    /// Own cities with a visible military unit of a player at war with this one next to them,
    /// sorted by id (the attention queue's "city under attack", M1 §16).
    public func threatenedCities() -> [CityID] {
        cities.filter { city in
            neighbors(of: city.position).contains { hex in
                units(at: hex).contains { $0.owner != player && !$0.type.isCivilian && isAtWar(with: $0.owner) }
            }
        }.map(\.id)
    }
}

extension PlayerView {
    /// Why an own city may not be razed now (nil: it may): only in the phase it was captured,
    /// and never an original capital (M1 §5). For the Keep/Raze card.
    public func razeProblem(_ id: CityID) -> String? {
        guard let index = state.cityIndex(id), state.cities[index].owner == player else { return "not your city" }
        guard state.outcome == nil else { return "the game is over" }
        guard isMyPhase else { return "not your turn" }
        return state.razeProblem(index)
    }
}

/// An own city's population as its queue finds it (`queueStatus`): phase by phase, the food
/// step at a fixed surplus, as `runGrowth` does it (M1 §5): the store fills to the threshold and
/// the city grows, or it runs dry and the city loses a citizen.
private struct PopulationForecast {
    let rules: Ruleset
    let surplus: Int
    var population: Int
    var store: Int
    /// The phases forecast so far (0: now).
    var phase = 0

    /// Runs the food steps up to and including phase `n`'s.
    mutating func advance(to n: Int) {
        while phase < n {
            phase += 1
            store += surplus
            if store < 0 {
                store = 0
                if population > 1 { population -= 1 }
            } else {
                let threshold = rules.growthThreshold(population: population)
                if store >= threshold {
                    store -= threshold
                    population += 1
                }
            }
        }
    }
}

// MARK: Quarters

/// A legal site for a quarter, with the adjacency bonus it would have there (M2 §18.2).
public struct QuarterSite: Hashable, Sendable {
    public var tile: HexCoord
    public var adjacency: Int
}

/// A quarter kind as the city panel lists it (M2 §18.2): its cost now, phases at the city's
/// production, its legal sites best first, and why it may not be placed now (nil: it may).
public struct QuarterOption: Hashable, Sendable {
    public var kind: QuarterKind
    public var name: String
    /// The yield its adjacency gives ("science", "gold", ...); nil: none.
    public var yield: String?
    public var cost: Int
    public var turns: Int?
    public var sites: [QuarterSite]
    public var problem: String?
}

extension PlayerView {
    /// Every quarter kind for an own city, in rules order, but the ones it has built.
    public func quarterOptions(for id: CityID) -> [QuarterOption] {
        guard let city = city(id), let kinds = rules.quarters?.kinds else { return [] }
        let production = state.cityYields(city).total.production
        let queued = city.queue.compactMap { entry -> QuarterKind? in
            if case let .quarter(kind, _) = entry.item { return kind }
            return nil
        }
        let cappedQueued = queued.filter { state.countsTowardCap($0) }.count
        let cap = state.quarterCap(of: city)
        return kinds.filter { state.quarter($0.id, of: city) == nil }.map { def in
            let cost = state.quarterCost(def.id)
            var problem = state.quarterKindProblem(def.id, in: city)
            if problem == nil {
                if queued.contains(def.id) { problem = "already queued" }
                else if city.queue.count >= rules.constants.production.maxQueue { problem = "queue full" }
                else if state.countsTowardCap(def.id), state.cappedQuarterCount(city) + cappedQueued >= cap {
                    problem = "at most \(cap) quarters at population \(city.population)"
                }
            }
            let sites = problem == nil ? state.quarterSites(def.id, in: city).map { QuarterSite(tile: $0.tile, adjacency: $0.adjacency) } : []
            if problem == nil, sites.isEmpty { problem = "no tile for it" }
            return QuarterOption(kind: def.id, name: def.name, yield: def.yield, cost: cost,
                                 turns: production > 0 ? max(1, (cost + production - 1) / production) : nil,
                                 sites: sites, problem: problem)
        }
    }

    /// How many quarters an own city may have (cap-exempt kinds aside), at its population.
    public func quarterCap(of id: CityID) -> Int? {
        city(id).map { state.quarterCap(of: $0) }
    }

    /// A built quarter's adjacency bonus where it stands, for its own city (0 when pillaged).
    public func quarterAdjacency(_ quarter: CityQuarter, of id: CityID) -> Int {
        guard let city = city(id), !quarter.isPillaged, let t = state.map.index(of: quarter.tile),
              let centre = state.map.index(of: city.position) else { return 0 }
        return state.quarterAdjacency(quarter.kind, at: t, owner: player, centre: centre)
    }
}

// MARK: Loyalty

extension PlayerView {
    /// An own city's Loyalty change and where it comes from (M2 §5.5); nil without Loyalty, and
    /// in a game from before it (no Free Cities), where Loyalty never changes.
    public func loyaltyBreakdown(of id: CityID) -> LoyaltyBreakdown? {
        guard state.freeCities != nil else { return nil }
        return city(id).flatMap { state.loyaltyBreakdown($0) }
    }

    /// Turns until an own city revolts at its current trend; nil when it is not losing Loyalty
    /// or cannot revolt (no Free Cities).
    public func turnsUntilRevolt(of id: CityID) -> Int? {
        guard state.freeCities != nil else { return nil }
        return city(id).flatMap { state.turnsUntilRevolt($0) }
    }

    /// The Free Cities faction, when the game has one (M2 §12.5).
    public var freeCities: PlayerID? { state.freeCities }
}

/// A city's specialists (M2 §5.3): its slots (one per building in each unpillaged quarter),
/// the citizens filling them, and what those yield.
public struct CitySpecialists: Hashable, Sendable {
    public var slots: [QuarterKind]
    public var filled: [QuarterKind]
    public var yields: Yields
}

/// A city's next tile (M2 §7.4): its price, the tiles it could buy, and why it cannot buy one
/// now (nil: it can).
public struct TilePurchase: Hashable, Sendable {
    public var price: Int
    public var tiles: [HexCoord]
    public var problem: String?
}

extension PlayerView {
    /// An own city's specialists; nil when it has no slot and no specialist.
    public func specialists(of id: CityID) -> CitySpecialists? {
        guard let city = city(id), city.owner == player else { return nil }
        let slots = state.specialistSlots(city)
        let filled = state.activeSpecialists(city)
        guard !slots.isEmpty || !filled.isEmpty else { return nil }
        return CitySpecialists(slots: slots, filled: filled,
                               yields: filled.reduce(Yields.zero) { $0 + state.specialistYields($1) })
    }

    /// An own city's tile buying; nil without the rules or for another's city.
    public func tilePurchase(of id: CityID) -> TilePurchase? {
        guard let city = city(id), city.owner == player, let price = state.tilePrice(for: city) else { return nil }
        let tiles = state.purchasableTiles(for: city)
        let gold = me.gold
        let problem: String? = tiles.isEmpty ? "no tile to buy" : gold < price ? "needs \(price) Gold (have \(gold))" : nil
        return TilePurchase(price: price, tiles: tiles, problem: problem)
    }
}
