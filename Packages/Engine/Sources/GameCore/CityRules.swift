// Cities (M1 §5): founding, growth, production, buying, spawning, borders, healing.

extension GameState {
    // MARK: Founding

    /// Why `player` may not found a city on tile `t` (nil: it may), judged on the real world.
    /// The reason never names a city (M1 §5): every site problem reads "site not valid".
    func foundingProblem(at t: Int, by player: PlayerID) -> String? {
        let tile = map.tiles[t]
        guard rules.isPassable(tile), rules.feature(tile.feature).allowsCity else { return "site not valid" }
        if let owner = tileOwner(t), owner != player { return "site not valid" }
        if cityTooClose(to: t) != nil { return "site not valid" }
        return nil
    }

    /// A city whose centre is closer to tile `t` than the minimum distance.
    func cityTooClose(to t: Int) -> City? {
        let hex = map.coord(at: t)
        let minimum = rules.constants.city.minDistance
        return cities.first { map.distance($0.position, hex) < minimum }
    }

    /// The name of `player`'s next city: the civ's list, then "New <first>", "New <second>", …
    func nextCityName(for player: PlayerID) -> String {
        let names = rules.civ(players[player.rawValue].civ)?.cityNames ?? []
        let n = players[player.rawValue].citiesNamed
        guard !names.isEmpty else { return "City \(n + 1)" }
        if n < names.count { return names[n] }
        return rules.constants.city.newNamePrefix + names[(n - names.count) % names.count]
    }

    /// Founds a city for `player` on tile `t` (validated by the caller): population 1, owning its
    /// centre and the unowned tiles around it, with `foundingProduction` stored progress; the
    /// player's first city is their original capital and gets the Palace. The tribal villages on
    /// the tiles it claims go to the founder, in tile order, after `cityFounded` (M1 §7.7).
    @discardableResult
    mutating func foundCity(at t: Int, by player: PlayerID, _ fx: inout Effects) -> CityID {
        let id = CityID(nextCityID)
        nextCityID += 1
        let hex = map.coord(at: t)
        var city = City(id: id, name: nextCityName(for: player), owner: player, position: hex, turn: turn,
                        hp: rules.constants.city.maxHP)
        city.storedProgress = rules.constants.city.foundingProduction
        players[player.rawValue].citiesNamed += 1
        if players[player.rawValue].originalCapital == nil {
            players[player.rawValue].originalCapital = id
        }
        if players[player.rawValue].capital == nil {
            players[player.rawValue].capital = id
            city.buildings = [rules.palace.id]
        }
        cities.append(city) // ids grow, so the array stays sorted
        if map.tiles[t].improvement != nil { // improvements never stand on city centres
            map[index: t].improvement = nil
        }
        let code = Int32(id.rawValue + 1)
        let villages = tribalVillages != nil
        var claimed: [Int] = []
        map.forEachIndex(within: rules.constants.city.initialRadius, of: hex) { n in
            if n == t || tileCity[n] == 0 {
                tileCity[n] = code
                fx.touchTile(n)
                if villages { claimed.append(n) }
            }
        }
        fx.touchTile(t)
        fx.touchPlayer(player)
        assignCitizens(cities.count - 1)
        fx.emit(.cityFounded(city: id, name: city.name, owner: player, at: hex), .tiles([t]))
        // Collected first: a take changes the state, which forEachIndex's closure may not.
        for n in claimed.sorted() where holdsTribalVillage(n) {
            takeTribalVillage(at: n, by: player, unit: nil, city: id, &fx)
        }
        return id
    }

    // MARK: Production

    /// Why `city` may not queue (or buy) `item` now, ignoring the queue's length and the gold.
    func itemProblem(_ item: ProductionItem, in city: City) -> String? {
        let player = players[city.owner.rawValue]
        switch item {
        case let .unit(type):
            if let tech = rules.unit(type).tech, !player.knows(tech) { return "needs \(techName(tech))" }
        case let .building(id):
            guard let def = rules.building(id), def.buildable else { return "cannot be built" }
            if city.has(id) { return "already built" }
            if let tech = def.tech, !player.knows(tech) { return "needs \(techName(tech))" }
        }
        return nil
    }

    func techName(_ tech: TechID) -> String { rules.tech(tech)?.name ?? tech.rawValue }

    /// Why a finished `item` could not appear now (nil: it can): a unit needs the city's
    /// population and a tile to stand on. Such an item waits.
    func completionProblem(_ item: ProductionItem, in city: City) -> String? {
        guard case let .unit(type) = item else { return nil }
        let def = rules.unit(type)
        if city.population < def.minPopulation { return "needs population \(def.minPopulation)" }
        if spawnTile(for: type, in: city) == nil { return "no room to place the unit" }
        return nil
    }

    /// Where a new unit of `type` appears (M1 §5): the city centre if its slot is free, else the
    /// nearest tile the owner owns within the spawn radius where it may stand (ties: lower index).
    func spawnTile(for type: UnitType, in city: City) -> Int? {
        let centre = map.index(of: city.position)!
        if mayPlace(type, owner: city.owner, at: centre) { return centre }
        var best: (distance: Int, tile: Int)?
        map.forEachIndex(within: rules.constants.production.spawnRadius, of: city.position) { t in
            guard t != centre, tileOwner(t) == city.owner else { return }
            let d = map.distance(index: t, centre)
            if let b = best, (b.distance, b.tile) <= (d, t) { return }
            guard mayPlace(type, owner: city.owner, at: t) else { return }
            best = (d, t)
        }
        return best?.tile
    }

    /// Completes `item` in `city` (production or purchase): a unit appears (a Settler costs
    /// population), a building is added.
    mutating func complete(_ item: ProductionItem, inCity index: Int, _ fx: inout Effects) {
        let city = cities[index]
        switch item {
        case let .unit(type):
            guard let t = spawnTile(for: type, in: city) else { return }
            let def = rules.unit(type)
            let id = insertUnit(type, owner: city.owner, at: map.coord(at: t))
            if def.populationCost > 0 {
                cities[index].population = max(1, cities[index].population - def.populationCost)
                fx.touchTile(map.index(of: city.position)!)
                fx.emit(.cityShrank(city: city.id, population: cities[index].population, at: city.position),
                        .tiles([map.index(of: city.position)!]))
                assignCitizens(index)
            }
            fx.emit(.productionCompleted(city: city.id, item: item, at: city.position), .owner(city.owner))
            fx.emit(.unitCreated(unit: id, type: type, owner: city.owner, at: map.coord(at: t)), .tiles([t]))
            fx.touchPlayer(city.owner)
        case let .building(id):
            guard let def = rules.building(id), !cities[index].has(id) else { return }
            cities[index].buildings.append(id)
            cities[index].buildings.sort()
            if def.wallHP > 0 { cities[index].wallHP = max(cities[index].wallHP, def.wallHP) }
            fx.touchTile(map.index(of: city.position)!)
            fx.emit(.productionCompleted(city: city.id, item: item, at: city.position), .owner(city.owner))
            if def.food != 0 { assignCitizens(index) }
        }
    }

    /// The production step of a city's phase (M1 §5). The phase's production (plus stored
    /// progress) goes to the first item that can complete; at most one item completes per
    /// phase, its overflow — capped at the phase's production — becomes stored progress, which
    /// goes into the next item that receives production. With an empty queue or only waiting
    /// items, production goes to stored progress, capped at `storedProgressCapMultiplier` ×
    /// the phase's production; the cap never takes away progress already stored (the founding
    /// production, a removed entry's progress). Before all that, a unit at the head of the
    /// queue that waits for population may take the production (`fillWaitingHead`).
    mutating func runProduction(inCity index: Int, production: Int, _ fx: inout Effects) {
        if fillWaitingHead(inCity: index, production: production) { return }
        let city = cities[index]
        guard let slot = city.queue.indices.first(where: { completionProblem(city.queue[$0].item, in: city) == nil }) else {
            let cap = rules.constants.production.storedProgressCapMultiplier * production
            cities[index].storedProgress = max(city.storedProgress, min(city.storedProgress + production, cap))
            return
        }
        let item = city.queue[slot].item
        let cost = rules.cost(of: item)
        let progress = city.queue[slot].progress + production + city.storedProgress
        cities[index].storedProgress = 0
        guard progress >= cost else {
            cities[index].queue[slot].progress = progress
            return
        }
        cities[index].queue.remove(at: slot)
        cities[index].storedProgress = min(progress - cost, production)
        complete(item, inCity: index, &fx)
    }

    /// p3f (core-opening-tempo, M1 §5): a unit at the head of the queue that waits for its
    /// city's population (a Settler at population 1) takes the phase's production and the stored
    /// progress, up to `waitingHeadFillPct` of its cost; what it does not take stays stored
    /// progress. It then waits as before, and completes in the first phase the city has the
    /// population (the food step comes first). Returns whether it took the production.
    mutating func fillWaitingHead(inCity index: Int, production: Int) -> Bool {
        let city = cities[index]
        guard let limit = waitingHeadFillLimit(city) else { return false }
        let total = city.queue[0].progress + production + city.storedProgress
        cities[index].queue[0].progress = min(total, limit)
        cities[index].storedProgress = total - min(total, limit)
        return true
    }

    /// The progress up to which the head of `city`'s queue takes production while it waits for
    /// population (`fillWaitingHead`), or nil when it takes none now: it is not a unit waiting
    /// for population, or it already holds that much. For the queries that show where the next
    /// production goes.
    func waitingHeadFillLimit(_ city: City) -> Int? {
        let pct = rules.constants.production.waitingHeadFillPct
        guard pct > 0, let head = city.queue.first, case let .unit(type) = head.item,
              city.population < rules.unit(type).minPopulation else { return nil }
        let limit = rules.cost(of: head.item) * pct / 100
        return head.progress < limit ? limit : nil
    }

    /// Replaces a city's queue (validated by the caller). Entries kept keep their progress
    /// (matched in order); the progress of entries removed goes to stored progress.
    mutating func setQueue(ofCity index: Int, to items: [ProductionItem]) {
        var old = cities[index].queue
        var queue: [QueueEntry] = []
        for item in items {
            if let i = old.firstIndex(where: { $0.item == item }) {
                queue.append(old.remove(at: i))
            } else {
                queue.append(QueueEntry(item))
            }
        }
        cities[index].storedProgress += old.reduce(0) { $0 + $1.progress }
        cities[index].queue = queue
    }

    /// Buys `item` (validated by the caller): pays, completes it at once (not the phase's
    /// completion); a bought building leaves the queue and its progress becomes stored progress.
    mutating func purchase(_ item: ProductionItem, inCity index: Int, price: Int, _ fx: inout Effects) {
        let owner = cities[index].owner
        players[owner.rawValue].gold -= price
        if case .building = item, let slot = cities[index].queue.firstIndex(where: { $0.item == item }) {
            cities[index].storedProgress += cities[index].queue[slot].progress
            cities[index].queue.remove(at: slot)
        }
        complete(item, inCity: index, &fx)
    }

    /// The gold price of an item (M1 §5).
    public func purchasePrice(of item: ProductionItem) -> Int {
        rules.cost(of: item) * rules.constants.production.purchaseCostMultiplier
    }

    // MARK: Growth

    /// The food step of a city's phase (M1 §5).
    mutating func runGrowth(inCity index: Int, surplus: Int, _ fx: inout Effects) {
        let city = cities[index]
        var store = city.foodStore + surplus
        if store < 0 {
            store = 0
            if city.population > 1 {
                cities[index].population -= 1
                fx.emit(.cityShrank(city: city.id, population: city.population - 1, at: city.position),
                        .tiles([map.index(of: city.position)!]))
                fx.touchTile(map.index(of: city.position)!)
            }
        } else {
            let threshold = rules.growthThreshold(population: city.population)
            if store >= threshold {
                store -= threshold
                cities[index].population += 1
                fx.emit(.cityGrew(city: city.id, population: city.population + 1, at: city.position),
                        .tiles([map.index(of: city.position)!]))
                fx.touchTile(map.index(of: city.position)!)
            }
        }
        cities[index].foodStore = store
    }

    // MARK: Borders

    /// The culture step of a city's phase (M1 §5): at `borderThreshold` the city claims one
    /// tile and keeps the overflow. Candidates: unowned tiles within the border radius that
    /// touch the city's territory, by score 3·Food + 2·Prod + 2·Gold (+2 with a river);
    /// unworkable tiles score 0 and are taken only when nothing else is left. Ties: smaller
    /// distance, then lower index. A tribal village on the claimed tile goes to the city's owner,
    /// after `borderGrew` (M1 §7.7); this is the phase start's cities step, so its gift comes
    /// before that phase start's gold, science and unit steps.
    mutating func runBorders(inCity index: Int, culture: Int, _ fx: inout Effects) {
        cities[index].cultureStore += culture
        let city = cities[index]
        let threshold = rules.borderThreshold(tilesGained: city.tilesGained)
        guard city.cultureStore >= threshold, let t = borderCandidate(for: city) else { return }
        cities[index].cultureStore -= threshold
        cities[index].tilesGained += 1
        tileCity[t] = Int32(city.id.rawValue + 1)
        fx.touchTile(t)
        fx.touchPlayer(city.owner)
        fx.emit(.borderGrew(city: city.id, tile: map.coord(at: t)), .tiles([t]))
        if holdsTribalVillage(t) { takeTribalVillage(at: t, by: city.owner, unit: nil, city: city.id, &fx) }
    }

    /// The tile a city's borders would grow to next.
    func borderCandidate(for city: City) -> Int? {
        let centre = map.index(of: city.position)!
        let code = Int32(city.id.rawValue + 1)
        let b = rules.constants.borders
        var best: (rank: Int, score: Int, distance: Int, tile: Int)?
        map.forEachIndex(within: b.radius, of: city.position) { t in
            guard tileCity[t] == 0 else { return }
            var touches = false
            map.forEachNeighbor(of: t) { n, _ in if tileCity[n] == code { touches = true } }
            guard touches else { return }
            let tile = map.tiles[t]
            let workable = rules.isWorkable(tile)
            var score = 0
            if workable {
                let y = tileYields(t, for: city.owner)
                score = b.foodWeight * y.food + b.productionWeight * y.production + b.goldWeight * y.gold
                if tile.riverEdges != 0 { score += rules.river.borderScore }
            }
            let candidate = (rank: workable ? 1 : 0, score: score, distance: map.distance(index: t, centre), tile: t)
            if let c = best {
                if (c.rank, c.score) > (candidate.rank, candidate.score) { return }
                if (c.rank, c.score) == (candidate.rank, candidate.score), (c.distance, c.tile) <= (candidate.distance, candidate.tile) { return }
            }
            best = candidate
        }
        return best?.tile
    }

    // MARK: Healing

    /// A city not attacked since its owner's previous phase start heals and repairs its walls
    /// (M1 §5); walls at 0 wall HP still exist and recover.
    mutating func healCity(_ index: Int, _ fx: inout Effects) {
        let city = cities[index]
        guard city.lastAttackedPhase < players[city.owner.rawValue].lastPhaseStart else { return }
        let c = rules.constants.city
        let maxWall = city.buildings.compactMap { rules.building($0)?.wallHP }.max() ?? 0
        let hp = min(c.maxHP, city.hp + c.healPerPhase)
        let wall = min(maxWall, city.wallHP + c.wallRepairPerPhase)
        if hp != city.hp || wall != city.wallHP {
            cities[index].hp = hp
            cities[index].wallHP = wall
            fx.touchTile(map.index(of: city.position)!)
        }
    }
}
