/// Benchmark, test and debug helpers: HeadlessSim's stress modes, tests, and the App's
/// Developer menu (Spawn Units, Move All Units, the scripted and random AI stand-ins), which
/// the game menu reaches. They must keep the state's invariants: SaveStore refuses to save a
/// state that breaks them.
public enum DebugTools {
    /// Spawns warriors on random free land tiles for random living players (an eliminated
    /// player owns nothing, M1 §10), never on a tribal village (M1 §7.7: no unit stands on one;
    /// such a draw counts as a failed attempt).
    public static func spawnUnits(count: Int, seed: UInt64, in state: inout GameState) {
        let living = state.livingPlayers
        guard !living.isEmpty else { return }
        var rng = SplitMix64(seed: seed, salts: 0xDEB06)
        var placed = 0, attempts = 0
        var fx = Effects()
        while placed < count, attempts < count * 50 {
            attempts += 1
            let t = rng.nextInt(below: state.map.tileCount)
            let hex = state.map.coord(at: t)
            let owner = living[rng.nextInt(below: living.count)]
            guard !state.holdsTribalVillage(t), state.canEnd(.warrior, owner: owner, at: hex) else { continue }
            state.insertUnit(.warrior, owner: owner, at: hex)
            fx.touchPlayer(owner)
            placed += 1
        }
        state.updateKnowledge(&fx)
    }

    /// A random move command for every unit of the current player with moves left (for stress
    /// tests and determinism tests).
    public static func randomMoves(in state: GameState, rng: inout SplitMix64, radius: Int = 5) -> [(PlayerID, Command)] {
        state.units.compactMap { unit in
            guard unit.owner == state.currentPlayer, unit.movesLeft > 0 else { return nil }
            let candidates = state.map.coords(within: radius, of: unit.position)
            guard let target = rng.pick(candidates) else { return nil }
            return (unit.owner, .moveUnit(unit: unit.id, to: target))
        }
    }

    /// Random commands for the current player (HeadlessSim's stress mode, M1 §17): random
    /// moves, research and production, plus now and then founding a city, attacking a target
    /// from `attackOptions` (cities first, moving to its `from` tile when needed), heading for
    /// a remembered enemy city, bombarding, declaring war, proposing or answering peace, and
    /// razing a city captured this phase. Planned from `state` (later commands may be refused
    /// once earlier ones changed it); commands come in a fixed order (diplomacy, research,
    /// units by id, cities by id). Deterministic for a given state and rng.
    public static func randomCommands(in state: GameState, rng: inout SplitMix64, radius: Int = 5) -> [Command] {
        let me = state.currentPlayer
        guard state.outcome == nil, state.players.indices.contains(me.rawValue) else { return [] }
        let view = state.view(for: me)
        var commands: [Command] = []
        for other in state.players where other.id != me && other.isAlive {
            if view.warProblem(on: other.id) == nil {
                if rng.nextInt(below: 12) == 0 { commands.append(.declareWar(on: other.id)) }
            } else if view.peaceProblem(to: other.id) == nil, rng.nextInt(below: 6) == 0 {
                commands.append(.proposePeace(to: other.id))
            }
        }
        for proposer in view.peaceProposals {
            commands.append(.respondToPeace(from: proposer, accept: rng.nextInt(below: 2) == 0))
        }
        let player = state.players[me.rawValue]
        if player.researching == nil, let tech = rng.pick(state.rules.techs.filter({ !player.knows($0.id) })) {
            commands.append(.setResearch(tech: tech.id))
        }
        let enemyCities = view.knownCities.filter { $0.owner != me && state.isAtWar(me, $0.owner) }.map(\.position)
        for unit in state.units where unit.owner == me {
            let t = state.map.index(of: unit.position)!
            if state.rules.unit(unit.type).foundsCity, state.foundingProblem(at: t, by: me) == nil, rng.nextInt(below: 2) == 0 {
                commands.append(.foundCity(unit: unit.id))
                continue
            }
            guard unit.movesLeft > 0, !unit.zocStopped || !unit.type.isCivilian else { continue }
            let options = view.attackOptions(for: unit.id)
            let onCities = options.filter { if case .city = $0.defender { true } else { false } }
            if let option = rng.pick(onCities.isEmpty ? options : onCities), rng.nextInt(below: 4) != 0 {
                if option.from != unit.position { commands.append(.moveUnit(unit: unit.id, to: option.from)) }
                commands.append(.attack(unit: unit.id, target: option.target))
                continue
            }
            guard !unit.zocStopped else { continue }
            // Military units often head for a tile next to the nearest enemy city they know.
            if !unit.type.isCivilian, rng.nextInt(below: 2) == 0,
               let city = enemyCities.min(by: { state.map.distance($0, unit.position) < state.map.distance($1, unit.position) }),
               state.map.distance(city, unit.position) <= 12, let target = rng.pick(state.map.neighbors(of: city)) {
                commands.append(.moveUnit(unit: unit.id, to: target))
                continue
            }
            if let target = rng.pick(state.map.coords(within: radius, of: unit.position)) {
                commands.append(.moveUnit(unit: unit.id, to: target))
            }
        }
        for city in state.cities where city.owner == me {
            if city.queue.isEmpty {
                let items = (UnitType.allCases.map { ProductionItem.unit($0) } + state.rules.buildings.map { .building($0.id) })
                    .filter { state.itemProblem($0, in: city) == nil }
                if let item = rng.pick(items) { commands.append(.setQueue(city: city.id, items: [item])) }
            }
            if let option = rng.pick(view.cityAttackOptions(for: city.id)) {
                commands.append(.cityAttack(city: city.id, target: option.target))
            }
            if view.canRaze(city.id), rng.nextInt(below: 3) == 0 { commands.append(.razeCity(city: city.id)) }
        }
        return commands
    }

    /// Moves every unit with moves left, of every player, toward a random tile nearby, whoever's
    /// phase it is (the App's stress button). Moves follow the normal rules otherwise; refused
    /// ones are skipped. Returns the events.
    @discardableResult
    public static func moveAllUnchecked(in state: inout GameState, rng: inout SplitMix64, radius: Int = 5) -> [EventRecord] {
        var events: [EventRecord] = []
        for unit in state.units where unit.movesLeft > 0 {
            guard state.unit(unit.id) != nil, state.outcome == nil else { continue }
            let candidates = state.map.coords(within: radius, of: unit.position)
            guard let target = rng.pick(candidates) else { continue }
            if let produced = try? GameEngine.perform(.moveUnit(unit: unit.id, to: target), by: unit.owner, on: &state) {
                events += produced
            }
        }
        return events
    }

    /// Recomputes every player's visibility and memory from scratch (benchmarks: the worst case
    /// of the per-command knowledge update).
    public static func refreshAllKnowledge(in state: inout GameState) {
        var fx = Effects()
        fx.touchAllPlayers(state.players.count)
        state.updateKnowledge(&fx)
    }

    /// Recomputes one player's visibility, then every player's memory and sightings: the usual
    /// knowledge update after a command that changed one player's units (benchmarks).
    public static func refreshKnowledge(of player: PlayerID, in state: inout GameState) {
        var fx = Effects()
        fx.touchPlayer(player)
        state.updateKnowledge(&fx)
    }

    // MARK: Tribal villages (M1 §7.7)

    /// The tribal villages still standing, in tile order: the live state, for diagnostic mode,
    /// HeadlessSim's statistics and tests. Players know them only from memory
    /// (`PlayerView.knownTribalVillages`); the AI must not call this (a GameAITests lint checks).
    public static func tribalVillages(in state: GameState) -> [HexCoord] {
        (state.tribalVillages?.sites ?? []).map { state.map.coord(at: Int($0)) }
    }

    /// Placement again, with its tags (M1 §7.7): the tribal villages `newGame(seed:map:
    /// startPositions:rules:placeTribalVillages: true)` places on these inputs, in tile order,
    /// each with the start whose own round placed it (`start`, the player index) or nil for a
    /// shared one. A site's side cannot be told from its steps alone, so the placement property
    /// test and HeadlessSim's statistics read these tags. It builds the game without them and
    /// runs the same routine, so the start units stand where they do in the real game. Empty
    /// for rules without the section.
    public static func tribalVillagePlacement(seed: UInt64, map: HexMap, startPositions: [HexCoord],
                                              rules: Ruleset = .standard) -> [TribalVillageSite] {
        guard let villageRules = rules.tribalVillages else { return [] }
        let state = GameState.newGame(seed: seed, map: map, startPositions: startPositions, rules: rules)
        var placer = TribalVillagePlacer(state: state, startPositions: startPositions, rules: villageRules)
        return placer.place().map { TribalVillageSite(hex: map.coord(at: $0.tile), start: $0.start) }
    }

    /// Gives `player` the tech outright (scenarios: no research, Insight or event). False,
    /// with nothing changed, for an unknown player or tech, or one already known.
    @discardableResult
    public static func learnTech(_ tech: TechID, player: PlayerID, in state: inout GameState) -> Bool {
        guard state.players.indices.contains(player.rawValue), state.rules.tech(tech) != nil,
              !state.players[player.rawValue].knows(tech) else { return false }
        state.players[player.rawValue].knownTechs.append(tech)
        return true
    }

    /// Sets unit `id`'s experience (scenarios: a veteran with a promotion due). False for an
    /// unknown unit.
    @discardableResult
    public static func setExperience(_ xp: Int, of id: UnitID, in state: inout GameState) -> Bool {
        guard state.unit(id) != nil else { return false }
        state.updateUnit(id) { $0.xp = max(0, xp) }
        return true
    }

    /// Places a tribal village on `hex` (scenarios and tests). Refused, with nothing changed,
    /// when the rules have none (`Ruleset.tribalVillages == nil`), or on a tile that is owned,
    /// holds a unit, is not passable land or already holds one. Otherwise the site goes in in
    /// tile order (the first one creates the state, with no gifts given yet), and every player
    /// who sees the tile remembers it.
    @discardableResult
    public static func placeTribalVillage(at hex: HexCoord, in state: inout GameState) -> Bool {
        guard state.rules.tribalVillages != nil, let t = state.map.index(of: hex) else { return false }
        let coord = state.map.coord(at: t)
        guard state.tileCity[t] == 0, state.rules.isPassable(state.map.tiles[t]), !state.units.contains(where: { $0.position == coord }),
              !state.holdsTribalVillage(t) else { return false }
        var villages = state.tribalVillages ?? TribalVillageState(players: state.players.count)
        villages.insert(t)
        state.tribalVillages = villages
        var fx = Effects()
        fx.touchTile(t)
        state.updateKnowledge(&fx)
        return true
    }

    /// Sets city `id`'s population and adds buildings it lacks, then reassigns its citizens
    /// (scenarios: a city past its Housing). False, with nothing changed, for an unknown city or
    /// a population below 1.
    @discardableResult
    public static func setCity(_ id: CityID, population: Int, adding buildings: [BuildingID] = [], in state: inout GameState) -> Bool {
        guard population >= 1, let index = state.cityIndex(id) else { return false }
        state.cities[index].population = population
        for b in buildings where !state.cities[index].has(b) { state.cities[index].buildings.append(b) }
        state.assignCitizens(index)
        return true
    }

    /// Sets city `id`'s Loyalty (scenarios), clamped to 0–100. False without Loyalty.
    @discardableResult
    public static func setLoyalty(_ id: CityID, _ loyalty: Int, in state: inout GameState) -> Bool {
        guard state.rules.loyalty != nil, let index = state.cityIndex(id) else { return false }
        state.cities[index].loyalty = max(0, min(100, loyalty))
        return true
    }

    /// City `id` revolts at once and becomes a Free City (scenarios), as at Loyalty 0. False
    /// without the Free Cities or for one of theirs.
    @discardableResult
    public static func revolt(_ id: CityID, in state: inout GameState) -> Bool {
        guard let free = state.freeCities, let index = state.cityIndex(id), state.cities[index].owner != free else { return false }
        var fx = Effects()
        state.revolt(index, &fx)
        state.updateKnowledge(&fx)
        return true
    }

    /// Builds a quarter of `kind` on `hex` for city `id` at once (scenarios), as finishing it
    /// would. False, with nothing changed, when the city may not have it there.
    @discardableResult
    public static func addQuarter(_ kind: QuarterKind, at hex: HexCoord, to id: CityID, in state: inout GameState) -> Bool {
        guard let index = state.cityIndex(id) else { return false }
        let city = state.cities[index]
        guard state.quarterKindProblem(kind, in: city) == nil, state.quarterSiteProblem(kind, at: hex, in: city) == nil else { return false }
        var fx = Effects()
        state.buildQuarter(kind, at: hex, inCity: index, &fx)
        state.updateKnowledge(&fx)
        return true
    }

    /// Fills city `id`'s culture store to one phase short of its next border tile, so its
    /// owner's next phase start grows its borders (M1 §5), and returns the tile they will take:
    /// the one `borderCandidate` picks now, unless the map or the territory around it changes
    /// first. Nil, with nothing changed, for an unknown city, one with no culture, or one with
    /// no tile left to take. For scenarios and tests (a tribal village on that tile is then
    /// taken in by the city's land).
    @discardableResult
    public static func primeBorderGrowth(of id: CityID, in state: inout GameState) -> HexCoord? {
        guard let index = state.cityIndex(id) else { return nil }
        let city = state.cities[index]
        let culture = state.cityYields(city).total.culture
        guard culture > 0, let t = state.borderCandidate(for: city) else { return nil }
        state.cities[index].cultureStore = max(0, state.rules.borderThreshold(tilesGained: city.tilesGained) - culture)
        return state.map.coord(at: t)
    }

    /// A simple scripted player for tests and benchmarks: the current player founds cities with
    /// Settlers where it may, researches the cheapest unknown tech, keeps every city's queue
    /// full (Warrior, Settler, Builder, Monument, then whatever is available), builds the first
    /// allowed improvement with Builders, and sends other units with moves left to random tiles
    /// nearby. The phase is not ended. Commands come in a fixed order (units, then cities, by id).
    public static func scriptedCommands(in state: GameState, rng: inout SplitMix64, radius: Int = 4) -> [Command] {
        let me = state.currentPlayer
        var commands: [Command] = []
        let player = state.players[me.rawValue]
        if player.researching == nil, let tech = state.rules.techs.first(where: { !player.knows($0.id) }) {
            commands.append(.setResearch(tech: tech.id))
        }
        for unit in state.units where unit.owner == me {
            let t = state.map.index(of: unit.position)!
            if state.rules.unit(unit.type).foundsCity, state.foundingProblem(at: t, by: me) == nil {
                commands.append(.foundCity(unit: unit.id))
                continue
            }
            if unit.charges > 0, let kind = Improvement.allCases.first(where: { state.improvementProblem($0, by: unit) == nil }) {
                commands.append(.buildImprovement(unit: unit.id, improvement: kind))
                continue
            }
            guard unit.movesLeft > 0, unit.destination == nil else { continue }
            if let target = rng.pick(state.map.coords(within: radius, of: unit.position)) {
                commands.append(.moveUnit(unit: unit.id, to: target))
            }
        }
        for city in state.cities where city.owner == me && city.queue.count < 2 {
            let wanted: [ProductionItem] = [.unit(.warrior), .unit(.settler), .unit(.builder), .building("monument")]
                + state.rules.buildings.map { .building($0.id) } + UnitType.allCases.map { .unit($0) }
            var items = city.queuedItems
            for item in wanted where items.count < 3 && state.itemProblem(item, in: city) == nil {
                if case .building = item, items.contains(item) { continue }
                items.append(item)
            }
            if items != city.queuedItems { commands.append(.setQueue(city: city.id, items: items)) }
        }
        return commands
    }
}
