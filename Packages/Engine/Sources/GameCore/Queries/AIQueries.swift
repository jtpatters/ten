// Read-only PlayerView queries for the AI (M1 §13; §12.6: "Phase 2 may add read-only query
// files under GameCore/Queries/"). Like every PlayerView query they use only what the viewing
// player knows: terrain only where explored, borders and improvements as remembered, its own
// cities and units in full. None of them changes anything.

extension PlayerView {
    // MARK: Tiles by index

    /// Wrap-aware distance between two tiles given by index.
    public func aiDistance(_ a: Int, _ b: Int) -> Int {
        state.map.distance(index: a, b)
    }

    /// The tiles within `radius` of tile `t`, by index, each once (in `coords(within:of:)` order).
    public func aiTiles(within radius: Int, of t: Int) -> [Int] {
        var result: [Int] = []
        let map = state.map
        let tooNarrow = map.wrapsX && map.width < 2 * radius + 1
        map.forEachIndex(within: radius, of: map.coord(at: t)) { n in
            if !tooNarrow || !result.contains(n) { result.append(n) }
        }
        return result
    }

    /// The neighbours of tile `t`, by index, in `HexDirection` order.
    public func aiNeighbors(of t: Int) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(6)
        state.map.forEachNeighbor(of: t) { n, _ in result.append(n) }
        return result
    }

    /// Whether this player knows tile `t` as passable land (explored and passable).
    public func aiKnownPassable(_ t: Int) -> Bool {
        me.explored[t] && rules.isPassable(state.map.tiles[t])
    }

    // MARK: Exploring

    /// The frontier (M1 §13): explored passable land tiles next to an unexplored tile, by
    /// increasing tile index.
    public func aiFrontier() -> [Int] {
        let map = state.map
        let explored = me.explored
        var result: [Int] = []
        for t in 0..<map.tileCount where explored[t] && rules.isPassable(map.tiles[t]) {
            var open = false
            map.forEachNeighbor(of: t) { n, _ in if !explored[n] { open = true } }
            if open { result.append(t) }
        }
        return result
    }

    /// The first of `sources` (by index) from which a new unit of `type` (a Scout leaving a
    /// city) could reach the frontier and stop there, by its movement field (`MoveKnowledge`:
    /// explored impassable tiles, visible foreign units and remembered foreign cities block;
    /// closed borders, M1 §9; zones of control; turns end only where the unit may stop); nil
    /// when none can. A breadth-first search first groups the sources into regions the unit
    /// could walk between; only the first source of each region holding frontier tiles gets a
    /// movement field (the others of a region are taken to fare alike), so a big map costs a
    /// field or two, not one per city.
    public func aiFirstSourceReachingFrontier(_ sources: [HexCoord], by type: UnitType) -> Int? {
        guard let first = sources.first else { return nil }
        let map = state.map
        let explored = me.explored
        let moves = rules.unit(type).moves * rules.movePoints
        let k = MoveKnowledge(state: state, unit: Unit(id: UnitID(-1), owner: player, type: type, position: first, movesLeft: moves))
        var region = [Int32](repeating: -1, count: tileCount)
        var regions: Int32 = 0
        var queue: [Int] = []
        for (i, source) in sources.enumerated() {
            guard let s = index(of: source), region[s] < 0 else { continue }
            region[s] = regions
            var frontier: [Int] = []
            queue.removeAll(keepingCapacity: true)
            queue.append(s)
            var head = 0
            while head < queue.count {
                let t = queue[head]
                head += 1
                var open = false
                map.forEachNeighbor(of: t) { n, _ in
                    guard explored[n] else {
                        open = true
                        return
                    }
                    // A tile in a zone of control ends the move, so one the unit may not stop
                    // on cannot be entered at all.
                    guard region[n] < 0, k.canEnter(n), !k.zoc[n] || k.canEnd(n) else { return }
                    region[n] = regions
                    queue.append(n)
                }
                if open, t != s, k.canEnd(t) { frontier.append(t) }
            }
            regions += 1
            guard !frontier.isEmpty else { continue }
            let field = Pathfinder.movementField(k, from: s, movesLeft: moves, maxMoves: moves)
            if frontier.contains(where: { field[$0] > 0 }) { return i }
        }
        return nil
    }

    // MARK: Itineraries

    /// Per tile: territory closed to this player's military (M1 §9: at peace, met or not), as
    /// the player remembers the borders.
    public func aiClosedToMilitary() -> [Bool] {
        let closedOwner = [false] + state.players.map { state.bordersClosed(to: player, by: $0.id) }
        return me.memory.tileOwner.map { closedOwner[Int($0)] }
    }

    /// The movement field of own unit `id` as `movementField(for:limit:)` computes it, except
    /// that the unit may end a phase only on tiles where `mayStop` is true (or where it stands):
    /// an itinerary with chosen stopping places (ai-3: a Settler's, M1 §13 Safety).
    public func aiMovementField(for id: UnitID, mayStop: [Bool], limit: Int = .max) -> [Int32] {
        guard let (k, start, unit) = aiKnowledge(id, mayStop: mayStop) else { return [] }
        return Pathfinder.movementField(k, from: start, movesLeft: unit.zocStopped ? 0 : unit.movesLeft,
                                        maxMoves: state.maxMoves(of: unit), limit: limit)
    }

    /// A path for own unit `id` by the rules of `aiMovementField(for:mayStop:limit:)`; nil when
    /// there is none.
    public func aiPath(for id: UnitID, to hex: HexCoord, mayStop: [Bool]) -> Path? {
        guard let (k, start, unit) = aiKnowledge(id, mayStop: mayStop), let goal = index(of: hex), goal != start,
              k.canEnd(goal) else { return nil }
        return Pathfinder.search(k, from: start, movesLeft: unit.zocStopped ? 0 : unit.movesLeft,
                                 maxMoves: state.maxMoves(of: unit), to: goal)
    }

    /// The movement knowledge behind `aiMovementField(for:mayStop:limit:)` and
    /// `aiPath(for:to:mayStop:)`, with the unit's tile index.
    private func aiKnowledge(_ id: UnitID, mayStop: [Bool]) -> (MoveKnowledge, Int, Unit)? {
        guard let unit = state.unit(id), unit.owner == player, let start = index(of: unit.position),
              mayStop.count == tileCount else { return nil }
        var noStop = TileBitSet(count: tileCount)
        for t in 0..<tileCount where !mayStop[t] { noStop[t] = true }
        return (MoveKnowledge(MoveKnowledge(state: state, unit: unit), noStop: noStop), start, unit)
    }

    // MARK: Strategic distance

    /// Movement points over terrain as this player knows it, from the nearest of `sources` to
    /// every tile (M1 §13 "path cost" between cities): Dijkstra with each step costing 1 plus
    /// the entered tile's elevation and feature costs (a known city centre has no forest,
    /// jungle or marsh) plus the river crossing cost; unexplored tiles cost 1 and count as
    /// passable land; explored impassable tiles block. Units, borders and zones of control are
    /// ignored. −1 where unreachable or beyond `limit`. With `blocked` (p3f), tiles marked true
    /// are never entered either (a source tile still counts).
    public func aiTerrainCostField(from sources: [HexCoord], limit: Int = Int(Int32.max), blocked: [Bool]? = nil) -> [Int32] {
        let map = state.map
        let count = map.tileCount
        var cost = [Int32](repeating: -1, count: count)
        var best = [Int32](repeating: .max, count: count)
        // Every step costs 1…(1 + max elevation + max feature + river), so that many + 1
        // buckets in a ring hold every pending cost (Dial's algorithm).
        let maxStep = 1 + (rules.elevations.map(\.moveCost).max() ?? 0) + (rules.features.map(\.moveCost).max() ?? 0)
            + rules.river.crossingMoveCost
        var ring = [[Int32]](repeating: [], count: maxStep + 1)
        var pending = 0
        let explored = me.explored
        var cities = TileBitSet(count: count)
        for city in me.memory.cities { if let t = index(of: city.position) { cities[t] = true } }
        for source in sources {
            guard let t = index(of: source), best[t] != 0 else { continue }
            best[t] = 0
            ring[0].append(Int32(t))
            pending += 1
        }
        var current = 0
        while pending > 0, current <= limit {
            let slot = current % ring.count
            let bucket = ring[slot]
            ring[slot] = []
            for packed in bucket {
                pending -= 1
                let t = Int(packed)
                guard Int(best[t]) == current, cost[t] < 0 else { continue }
                cost[t] = Int32(current)
                map.forEachNeighbor(of: t) { n, direction in
                    guard cost[n] < 0 else { return }
                    if explored[n], !rules.isPassable(map.tiles[n]) { return }
                    if let blocked, blocked[n] { return }
                    let c = current + aiStepCost(from: t, to: n, direction, explored: explored, cityCentres: cities)
                    guard c < Int(best[n]), c <= limit else { return }
                    best[n] = Int32(c)
                    ring[c % ring.count].append(Int32(n))
                    pending += 1
                }
            }
            current += 1
        }
        return cost
    }

    /// Movement cost of one step over terrain as this player knows it (unexplored: 1; a river
    /// known from either explored side).
    private func aiStepCost(from: Int, to: Int, _ direction: HexDirection, explored: TileBitSet, cityCentres: TileBitSet,
                            free: (elevations: [Bool], features: [Bool])? = nil) -> Int {
        let map = state.map
        var cost = 1
        if explored[to] {
            let tile = map.tiles[to]
            if free?.elevations[Int(tile.elevation.rawValue)] != true { cost += rules.elevation(tile.elevation).moveCost }
            if free?.features[Int(tile.feature.rawValue)] != true, !(cityCentres[to] && rules.feature(tile.feature).removedByCity) { cost += rules.feature(tile.feature).moveCost }
        }
        let river: Bool
        if explored[from] {
            river = map.tiles[from].riverEdges & (1 << UInt8(direction.rawValue)) != 0
        } else if explored[to] {
            river = map.tiles[to].riverEdges & (1 << UInt8(direction.opposite.rawValue)) != 0
        } else {
            river = false
        }
        if river { cost += rules.river.crossingMoveCost }
        return cost
    }

    // MARK: Civilian safety

    /// Per tile: whether a visible military unit of a player at war with this one could move onto
    /// it in its next phase (p3d, M1 §13 Safety: at war a Settler or Builder keeps out of that
    /// reach, where a unit moving in would capture it). Each unit is reckoned with full moves over
    /// terrain as this player knows it — unexplored tiles cost 1 and count as passable land,
    /// explored impassable tiles block, a remembered city centre has no forest, jungle or marsh —
    /// with units, borders and zones of control ignored, so the reach is never less than the
    /// unit's true one. A unit may always enter a passable tile while it has a move left (M1 §8.6),
    /// as `dangerMap()` reckons a melee unit's attacks. Its own tile counts.
    public func aiEnemyReach() -> [Bool] {
        let map = state.map
        var reach = [Bool](repeating: false, count: tileCount)
        var left = [Int8](repeating: -1, count: tileCount)
        var cities: TileBitSet?
        let explored = me.explored
        for enemy in state.units where enemy.owner != player && !enemy.type.isCivilian && state.isAtWar(player, enemy.owner) {
            guard let start = index(of: enemy.position), me.visible[start] else { continue }
            if cities == nil {
                var known = TileBitSet(count: tileCount)
                for city in me.memory.cities { if let t = index(of: city.position) { known[t] = true } }
                cities = known
            }
            let moves = max(1, min(Int(Int8.max), state.maxMoves(of: enemy))), free = state.freeMove(enemy)
            reach[start] = true
            var touched = [start]
            left[start] = Int8(moves)
            var buckets = [[Int]](repeating: [], count: moves + 1)
            buckets[moves] = [start]
            for m in stride(from: moves, through: 1, by: -1) {
                var i = 0
                while i < buckets[m].count {
                    let t = buckets[m][i]
                    i += 1
                    guard Int(left[t]) == m else { continue }
                    map.forEachNeighbor(of: t) { n, direction in
                        if explored[n], !rules.isPassable(map.tiles[n]) { return }
                        reach[n] = true
                        let after = m - min(m, aiStepCost(from: t, to: n, direction, explored: explored, cityCentres: cities!, free: free))
                        guard after > Int(left[n]) else { return }
                        if left[n] < 0 { touched.append(n) }
                        left[n] = Int8(after)
                        if after > 0 { buckets[after].append(n) }
                    }
                }
            }
            for t in touched { left[t] = -1 }
        }
        return reach
    }

    // MARK: Production

    /// Why an item would wait in an own city now (M1 §5): a Settler below its population, or
    /// no tile to place the unit on. Nil when it could complete; "not your city" for a city
    /// that is not this player's.
    public func aiCompletionProblem(_ item: ProductionItem, in id: CityID) -> String? {
        guard let city = city(id) else { return "not your city" }
        return state.completionProblem(item, in: city)
    }

    // MARK: Builders

    /// Whether an explored tile has fresh water: a river edge, or an explored lake next to it.
    public func aiHasFreshWater(at hex: HexCoord) -> Bool {
        guard let t = index(of: hex), me.explored[t] else { return false }
        if state.map.tiles[t].riverEdges != 0 { return true }
        var lake = false
        state.map.forEachNeighbor(of: t) { n, _ in if me.explored[n], state.map.tiles[n].terrain == .lake { lake = true } }
        return lake
    }

    /// Why this player's Builder could not build `improvement` on `hex` now (M1 §7.2), judged
    /// on its knowledge (own tiles are always visible, so this matches the engine there): the
    /// tile must be own territory, not a city centre, unimproved, allow the improvement, and
    /// its tech must be known. Nil when it could.
    /// Why this player cannot field a unit of `type` for want of its strategic resource.
    public func aiResourceProblem(_ type: UnitType) -> String? { state.resourceProblem(type, owner: player) }

    public func aiImprovementProblem(_ improvement: Improvement, at hex: HexCoord) -> String? {
        guard let t = index(of: hex), me.explored[t] else { return "unexplored" }
        guard Int(me.memory.tileOwner[t]) == player.rawValue + 1 else { return "tile not in your territory" }
        guard knownCity(at: hex) == nil else { return "not on a city centre" }
        guard me.memory.tileImprovement[t] == 0 else { return "tile already improved" }
        guard rules.allowsImprovement(improvement, on: state.map.tiles[t], resource: state.knownResource(at: t, for: player)) else {
            return "not allowed here"
        }
        if let tech = rules.improvement(improvement).tech, !me.knows(tech) { return "needs \(tech)" }
        return nil
    }
}

extension MoveKnowledge {
    /// `base` with the tiles of `noStop` added to those the unit may not end a move on (AI
    /// queries: `PlayerView.aiMovementField(for:mayStop:limit:)`).
    init(_ base: MoveKnowledge, noStop: TileBitSet) {
        map = base.map
        rules = base.rules
        player = base.player
        unit = base.unit
        military = base.military
        explored = base.explored
        memoryOwner = base.memoryOwner
        closed = base.closed
        blocked = base.blocked
        var occupied = base.occupied
        occupied.formUnion(noStop)
        self.occupied = occupied
        ownCities = base.ownCities
        zoc = base.zoc
        freeElevation = base.freeElevation
        freeFeature = base.freeFeature
        roads = base.roads
        bridges = base.bridges
    }
}
