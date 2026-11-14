// Read-only queries for the App's Explore order (M1 §16; p3d app-explore-order, p3f
// app-explore-*, p3g tribal villages): where an own unit on that order goes next, when the order
// ends, the good city sites its walk brings into view, and the compass points its card names.
// Built only from what its player knows, as the pathfinder plans (M1 §8.6): the frontier is
// explored passable land next to an unexplored tile (`aiFrontier`); the tribal villages it seeks
// are those its player remembers (`knownTribalVillages`, M1 §7.7); costs come from the unit's
// movement field over explored ground, remembered borders and cities and foreign units in sight;
// enemy reach is that of enemy units in sight next phase (as `dangerMap` reckons it) and the
// bombard range of remembered enemy cities. The App turns each step into an ordinary `moveUnit`
// to where the unit gets this phase, so nothing here changes the rules, the AI or any hash.

/// What a unit on an Explore order does next (`PlayerView.exploreStep`).
public enum ExploreStep: Hashable, Sendable {
    /// Walk to `to`, as far as it gets this phase on its way to `goal`, the frontier tile or
    /// known tribal village it heads for (`to == goal` when it gets there this phase).
    /// `avoiding`: when the step leads no nearer the goal because the direct way would end in an
    /// enemy's reach, whose reach that is.
    case move(to: HexCoord, goal: HexCoord, avoiding: ExploreThreat?)
    /// Nothing more this phase (no moves left, a zone of control holds it, the way on opens only
    /// next turn, or foreign units in its sight stand on the only way on); `goal` is where it
    /// heads.
    case wait(goal: HexCoord)
    /// Wounded with no enemy in sight, where none could strike it: it stays where it is this
    /// phase, so that it heals at its next phase start (M1 §7.5), until it has `untilHP`; then
    /// on to `goal`.
    case rest(goal: HexCoord, untilHP: Int)
    /// The order ends, and why.
    case end(ExploreEnd)
}

/// Why an Explore order ends (`PlayerView.exploreStep`).
public enum ExploreEnd: Hashable, Sendable {
    /// No unexplored edge is left that the unit can reach, and no known tribal village it could
    /// go to. `closedLand`: the players (by id) whose land, closed to it at peace (M1 §9), stands
    /// at the unexplored edges it cannot reach.
    case explored(closedLand: [PlayerID])
    /// Enemy military units it was not told of came into its sight: their ids, nearest first.
    case enemyInSight([UnitID])
    /// It could go on only by stopping where an enemy could strike it next phase.
    case enemyReach
    /// No such unit of this player's.
    case unavailable
}

/// Whose reach an explorer keeps out of (`PlayerView.exploreThreats(for:)`).
public enum ExploreThreat: Hashable, Sendable {
    /// An enemy military unit in sight, by id.
    case unit(UnitID)
    /// A remembered enemy city (its bombard range, M1 §8.3), by id.
    case city(CityID)
}

/// How an explorer weighs frontier tiles and when it rests (tests compare variants; `standard`
/// is the App's).
struct ExploreTuning: Sendable {
    /// What a turn of walking is worth in unexplored tiles brought into sight: a goal's score is
    /// its cost in turns times this, less the unexplored tiles within the unit's sight of it.
    var tilesPerTurn: Int
    /// The goal it heads for is kept, while it is still frontier it can reach and stop on,
    /// unless another scores better by more than this many turns of walking (0: the best goal
    /// is chosen afresh at every step).
    var keepGoalTurns: Int = 1
    /// With no enemy in sight, a unit below this HP rests where it stands, and goes on resting
    /// until it has `resumeHP` (as the AI's wounded withdraw below `ai.retreatHP` and rejoin at
    /// `ai.rejoinHP`, M1 §13). 0: it never rests.
    var restBelowHP: Int = 50
    var resumeHP: Int = 80
    /// p3g (M1 §7.7): a known tribal village it can reach within this many turns of walking (a
    /// turn is the unit's full moves, as for the frontier) is its goal before any frontier tile.
    /// nil: the rules' `tribalVillages.seekTurns` (0 without the section); 0: it never seeks one.
    var tribalVillageTurns: Int?
    /// p3g review: with nothing left that it can reach but land (or a known tribal village) that
    /// only foreign units in its sight cut off (a Scout on a one-tile land bridge), it waits for
    /// them to move on where no enemy can strike it, while it last moved at most this many turns
    /// ago; then the order ends as explored. 0: it waits only in the turn it last moved.
    var waitForUnitsTurns = 2

    /// Measured on 20 Duel games against the real AI (`ExploreOrderPlayTests.compareWeightings`):
    /// 16 explored the most reachable land by turns 20 and 30 (6: 3 points less, 1000 — the
    /// cheapest tile first — 2 less). Keeping the goal unless another is better by more than a
    /// turn (p3f) leaves that land as it was (34%/60%/75% at turns 10/20/30) and drops the
    /// Scout's switches away from a goal it could still reach from 6 to 0 (36 to 21 with a
    /// Warrior exploring too, whose walk spoils goals); the phases that turn back over its
    /// tracks stay as they were (15 and 14 in 600), returns from a corner it has seen. Charging
    /// a turn for a goal behind it cut those to 10 but saw 4 points less land by turn 20 (56%),
    /// so it is not done; leaving out goals that would show fewer than 4 or 7 unexplored tiles
    /// changed neither.
    static let standard = ExploreTuning(tilesPerTurn: 16)
}

extension PlayerView {
    // MARK: The order

    /// An explorer with no enemy in sight rests below `below` HP, and goes on resting until it
    /// has `until` (`exploreStep`).
    public static var exploreRestHP: (below: Int, until: Int) { (ExploreTuning.standard.restBelowHP, ExploreTuning.standard.resumeHP) }

    /// The next step of own unit `id`'s Explore order, from this player's knowledge only (M1
    /// §16). The order ends when enemy military units come into the unit's sight that are not in
    /// `knownEnemies` (those in sight when the player gave the order). Otherwise the unit heads
    /// for a known tribal village it can reach and stop on within the rules' `seekTurns` turns of
    /// walking (`exploreTribalVillage`, M1 §7.7: the cheapest, not a `claimed` one; `goal`, once
    /// one, is kept until it is taken or seen gone), else for the best frontier tile it can reach
    /// and stop on (`exploreGoal`), keeping `goal` (the one it headed for) unless another is
    /// better by more than a turn, else for any known tribal village it can reach; at war it
    /// walks a tile at a time and ends each phase only where no enemy can strike it next
    /// (`exploreThreats`). A frontier goal within its sight of a `claimed` tile (another
    /// explorer's goal) is taken only when no other is left. With no goal the order ends: all it
    /// can reach is explored (and no known tribal village is left to it), or the way on lies in
    /// enemy reach; where only foreign units in its sight cut it off from such a goal, it first
    /// waits for them to move on (`.wait`) where no enemy can strike it, while it last moved at
    /// most `waitForUnitsTurns` (2) turns ago (`lastActedTurn`). Below 50 HP with no enemy in
    /// sight it rests where it stands (when no enemy could strike it there), and goes on resting
    /// until 80 HP; `resting`: it rested last phase (nil: as the unit tells, it neither moved nor
    /// attacked in its owner's previous phase).
    public func exploreStep(for id: UnitID, knownEnemies: [UnitID] = [], claimed: [HexCoord] = [], goal: HexCoord? = nil,
                            resting: Bool? = false) -> ExploreStep {
        exploreStep(for: id, knownEnemies: knownEnemies, claimed: claimed, goal: goal, resting: resting, tuning: .standard)
    }

    func exploreStep(for id: UnitID, knownEnemies: [UnitID], claimed: [HexCoord], goal current: HexCoord? = nil,
                     resting: Bool? = false, tuning: ExploreTuning) -> ExploreStep {
        guard let unit = state.unit(id), unit.owner == player, let here = index(of: unit.position) else { return .end(.unavailable) }
        let inSight = enemiesInSight(of: id)
        let fresh = inSight.filter { !knownEnemies.contains($0) }
        guard fresh.isEmpty else { return .end(.enemyInSight(fresh)) }
        let threats = exploreThreats(for: unit)
        // At war with enemies about, the unit ends its phases only out of their reach.
        let safe: [Bool]? = threats.contains { $0 != nil } ? threats.map { $0 == nil } : nil
        let frontier = aiFrontier()
        let field = safe.map { aiMovementField(for: id, mayStop: $0) } ?? movementField(for: id)
        let kept = current.flatMap { index(of: $0) }
        // p3g (M1 §7.7): a known tribal village within the horizon (or the one it heads for)
        // comes first; with no frontier goal left, any it can reach. None known, or a horizon
        // of 0: the step is as before.
        let seek = tuning.tribalVillageTurns ?? rules.tribalVillages?.seekTurns ?? 0
        func tribalVillage(_ field: [Int32], current: Int?, turns: Int?) -> Int? {
            seek > 0 ? exploreTribalVillage(unit, field: field, claimed: claimed, current: current, turns: turns) : nil
        }
        guard let goal = tribalVillage(field, current: kept, turns: seek)
            ?? exploreGoal(unit, field: field, frontier: frontier, claimed: claimed, current: kept, tuning: tuning)
            ?? tribalVillage(field, current: nil, turns: nil) else {
            let free = safe == nil ? field : movementField(for: id)
            if safe != nil,
               exploreGoal(unit, field: free, frontier: frontier, claimed: [], tuning: tuning) != nil
                || tribalVillage(free, current: nil, turns: nil) != nil {
                return .end(.enemyReach)
            }
            // p3g review: only foreign units in its sight stand in the way (a Scout on the one
            // tile out of a pocket, say). Units move on, so it waits for them a while, heading
            // for what lies beyond, rather than end the order with land it could reach left;
            // only where no enemy can strike it (a wait ends its phase where it stands).
            if threats[here] == nil, turn - unit.lastActedTurn <= tuning.waitForUnitsTurns {
                let beyond = movementFieldPastUnits(of: unit)
                if let past = tribalVillage(beyond, current: kept, turns: seek)
                    ?? exploreGoal(unit, field: beyond, frontier: frontier, claimed: claimed, current: kept, tuning: tuning)
                    ?? tribalVillage(beyond, current: nil, turns: nil) {
                    return .wait(goal: coord(at: past))
                }
            }
            return .end(.explored(closedLand: closedLand(around: frontier, field: free, military: !unit.type.isCivilian)))
        }
        let hex = coord(at: goal)
        // Wounded, with no enemy in sight: it heals where it stands (M1 §7.5), if no enemy can
        // strike it there (else it walks on, out of reach, and rests next phase).
        let rested = resting ?? (unit.lastActedTurn < turn - 1)
        if inSight.isEmpty, threats[here] == nil, unit.hp < (rested ? tuning.resumeHP : tuning.restBelowHP) {
            return .rest(goal: hex, untilHP: tuning.resumeHP)
        }
        guard unit.movesLeft > 0, !unit.zocStopped else { return .wait(goal: hex) }
        let path = safe.map { aiPath(for: id, to: hex, mayStop: $0) } ?? self.path(for: id, to: hex)
        let thisPhase = path?.steps.filter { $0.turn <= 1 } ?? []
        // At war it walks a tile at a time (the first it may stop on), so that an enemy coming
        // into its sight (moves reveal, they do not stop, M1 §8.6) stops it with moves left.
        let atWar = state.players.contains { $0.id != player && isAtWar(with: $0.id) }
        func mayEnd(_ step: PathStep) -> Bool {
            guard let t = index(of: step.hex), safe?[t] ?? true else { return false }
            return !units.contains { $0.id != id && $0.position == step.hex && $0.type.isCivilian == unit.type.isCivilian }
        }
        guard let stop = (atWar ? thisPhase.first(where: mayEnd) : nil)?.hex ?? thisPhase.last?.hex else {
            // Nowhere to stop on the way this phase: if only enemy reach is in the way, the
            // order ends rather than wait there unseen.
            if safe != nil, self.path(for: id, to: hex)?.steps.contains(where: { $0.turn <= 1 }) == true {
                return .end(.enemyReach)
            }
            return .wait(goal: hex)
        }
        // A step that leads no nearer the goal, off the direct way (reach ignored): whose reach
        // it keeps out of, the first on the direct way (the card says so).
        var avoiding: ExploreThreat?
        if safe != nil, let s = index(of: stop), state.map.distance(index: s, goal) >= state.map.distance(index: here, goal),
           let direct = self.path(for: id, to: hex), direct.steps.first?.hex != stop {
            avoiding = direct.steps.lazy.compactMap { self.index(of: $0.hex).flatMap { threats[$0] } }.first
        }
        return .move(to: stop, goal: hex, avoiding: avoiding)
    }

    /// The frontier tile (by index) an explorer heads for: of the frontier tiles it can reach and
    /// stop on (`field` above 0), the one with the lowest score, its cost in turns times
    /// `tuning.tilesPerTurn` less the unexplored tiles within the unit's sight of it (ties: more
    /// such tiles, lower cost, lower index). A tile within the unit's sight of a `claimed` tile
    /// counts only when no other is left. `current` (the goal it heads for) is kept while it is
    /// such a tile, unless the best scores lower by more than `tuning.keepGoalTurns` turns of
    /// walking. Nil when there is none.
    func exploreGoal(_ unit: Unit, field: [Int32], frontier: [Int], claimed: [HexCoord], current: Int? = nil,
                     tuning: ExploreTuning) -> Int? {
        let def = rules.unit(unit.type)
        let sight = def.sight, maxMoves = max(1, def.moves)
        let taken = claimed.compactMap { index(of: $0) }
        typealias Key = (score: Int, gain: Int, cost: Int, tile: Int)
        func better(_ a: Key, than b: Key?) -> Bool {
            guard let b else { return true }
            return (a.score, -a.gain, a.cost, a.tile) < (b.score, -b.gain, b.cost, b.tile)
        }
        var free: Key?, spare: Key?, kept: Key?
        for t in frontier where field.indices.contains(t) && field[t] > 0 {
            let cost = Int(field[t])
            let gain = unexploredTiles(within: sight, of: t)
            // Movement points to stop there count unused points at turn ends, so a turn is
            // `maxMoves` of them: score = turns × tilesPerTurn − gain, in points.
            let key: Key = (cost * tuning.tilesPerTurn - gain * maxMoves, gain, cost, t)
            if taken.contains(where: { state.map.distance(index: $0, t) <= sight }) {
                if better(key, than: spare) { spare = key }
            } else {
                if t == current { kept = key }
                if better(key, than: free) { free = key }
            }
        }
        // A turn of walking is `maxMoves × tilesPerTurn` points.
        if let kept, let best = free, best.score + tuning.keepGoalTurns * maxMoves * tuning.tilesPerTurn >= kept.score {
            return kept.tile
        }
        return (free ?? spare)?.tile
    }

    /// The known tribal village (by index) an explorer heads for (p3g, M1 §7.7, §16), from this
    /// player's memory only (`knownTribalVillages`): `current` (the goal it heads for) while that
    /// is still a known tribal village it can reach and stop on (`field` above 0) and no other
    /// explorer claims, however far; else, of the known tribal villages it can reach and stop on
    /// within `turns` turns of walking (a turn is the unit's full moves; nil: any distance),
    /// leaving out the `claimed` tiles (other explorers' goals), the one with the lowest cost
    /// (ties: lower index). Nil when there is none.
    func exploreTribalVillage(_ unit: Unit, field: [Int32], claimed: [HexCoord], current: Int?, turns: Int?) -> Int? {
        let known = knownTribalVillages
        guard !known.isEmpty else { return nil }
        let taken = claimed.compactMap { index(of: $0) }
        func open(_ t: Int) -> Bool { field.indices.contains(t) && field[t] > 0 && !taken.contains(t) }
        if let current, SortedTiles.contains(known, current), open(current) { return current }
        let limit = turns.map { $0 * max(1, rules.unit(unit.type).moves) } ?? Int.max
        var best: (cost: Int32, tile: Int)?
        for village in known {
            let t = Int(village)
            guard open(t), Int(field[t]) <= limit else { continue }
            // In tile order: a tie keeps the lower index.
            if let best, best.cost <= field[t] { continue }
            best = (field[t], t)
        }
        return best?.tile
    }

    /// Own unit `unit`'s movement field (`movementField(for:)`) with the foreign units in its
    /// player's sight out of the way, as once they have moved on: remembered foreign cities,
    /// borders, terrain and zones of control stay as they are.
    func movementFieldPastUnits(of unit: Unit) -> [Int32] {
        guard unit.owner == player, let start = index(of: unit.position) else { return [] }
        let k = MoveKnowledge(MoveKnowledge(state: state, unit: unit), withoutUnitsIn: state)
        return Pathfinder.movementField(k, from: start, movesLeft: unit.zocStopped ? 0 : unit.movesLeft,
                                        maxMoves: state.maxMoves(of: unit))
    }

    /// Unexplored tiles within `radius` of tile `t` (what a unit with that sight would bring into
    /// view there).
    func unexploredTiles(within radius: Int, of t: Int) -> Int {
        var count = 0
        let explored = me.explored
        state.map.forEachIndex(within: radius, of: coord(at: t)) { if !explored[$0] { count += 1 } }
        return count
    }

    /// The players (by id) whose remembered land, closed to this player's military at peace,
    /// stands at frontier tiles the unit cannot reach (`field` below 0): on them or next to them.
    private func closedLand(around frontier: [Int], field: [Int32], military: Bool) -> [PlayerID] {
        guard military else { return [] }
        let map = state.map
        let owners = me.memory.tileOwner
        var closed: [PlayerID] = []
        func note(_ t: Int) {
            let code = Int(owners[t])
            guard code > 0, me.explored[t] else { return }
            let owner = PlayerID(code - 1)
            if state.bordersClosed(to: player, by: owner), !closed.contains(owner) { closed.append(owner) }
        }
        for t in frontier where !(field.indices.contains(t) && field[t] >= 0) {
            note(t)
            map.forEachNeighbor(of: t) { n, _ in note(n) }
        }
        return closed.sorted()
    }

    // MARK: Danger

    /// Enemy military units (of players at war with this one) on tiles this player sees, within
    /// own unit `id`'s sight of it: nearest first (ties: lower id). Empty for another player's
    /// unit.
    public func enemiesInSight(of id: UnitID) -> [UnitID] {
        guard let unit = state.unit(id), unit.owner == player else { return [] }
        let sight = state.sight(of: unit)
        var near: [(id: UnitID, distance: Int)] = []
        for other in visibleForeignUnits where !other.type.isCivilian && isAtWar(with: other.owner) {
            let d = distance(other.position, unit.position)
            if d <= sight { near.append((other.id, d)) }
        }
        return near.sorted { ($0.distance, $0.id) < ($1.distance, $1.id) }.map(\.id)
    }

    /// Per tile: whether an own unit ending its phase there could be struck in an enemy's next
    /// phase, as this player can tell: within reach of an enemy unit in sight (`dangerMap`), or
    /// within bombard range of a remembered enemy city (M1 §8.3). All false at peace.
    public func enemyReach() -> [Bool] {
        var reach = dangerMap().map { $0 > 0 }
        let range = rules.constants.city.bombardRange
        for city in me.memory.cities where city.owner != player && isAtWar(with: city.owner) {
            state.map.forEachIndex(within: range, of: city.position) { reach[$0] = true }
        }
        return reach
    }

    /// Per tile: whose reach own unit `explorer` keeps out of there (nil: none), as `enemyReach`
    /// reckons it: an enemy unit in sight that could strike the tile in its next phase (the
    /// lowest id of them), else a remembered enemy city whose bombard range holds it. The reach
    /// of an enemy recon unit (a Strength 10 Scout) counts only against a recon explorer: a
    /// Warrior does not turn aside for a Scout. All nil at peace.
    public func exploreThreats(for explorer: Unit) -> [ExploreThreat?] {
        var threat = [ExploreThreat?](repeating: nil, count: tileCount)
        let map = state.map
        let explored = me.explored, visible = me.visible
        let reconExplorer = rules.unit(explorer.type).unitClass == .recon
        var left = [Int8](repeating: -1, count: tileCount)
        // As `dangerMap`: each enemy (in id order) with full moves over terrain as this player
        // knows it, units, borders and zones of control ignored; melee units strike the tiles
        // next to where they can get with a move left, ranged units those within range of them.
        for enemy in state.units where enemy.owner != player && !enemy.type.isCivilian && state.isAtWar(player, enemy.owner) {
            guard let start = index(of: enemy.position), visible[start], power(of: enemy) > 0 else { continue }
            let def = rules.unit(enemy.type)
            if def.unitClass == .recon, !reconExplorer { continue }
            let reach = def.isRanged ? state.range(of: enemy) : 1
            var touched = [start]
            left[start] = Int8(def.moves)
            var buckets = [[Int]](repeating: [], count: def.moves + 1)
            buckets[def.moves] = [start]
            for moves in stride(from: def.moves, through: 1, by: -1) {
                var i = 0
                while i < buckets[moves].count {
                    let t = buckets[moves][i]
                    i += 1
                    guard Int(left[t]) == moves else { continue }
                    map.forEachIndex(within: reach, of: coord(at: t)) { a in
                        if a != t, threat[a] == nil { threat[a] = .unit(enemy.id) }
                    }
                    map.forEachNeighbor(of: t) { n, direction in
                        if explored[n], !rules.isPassable(map.tiles[n]) { return }
                        let after = moves - min(moves, exploreStepCost(from: t, to: n, direction, explored: explored))
                        guard after > Int(left[n]) else { return }
                        if left[n] < 0 { touched.append(n) }
                        left[n] = Int8(after)
                        if after > 0 { buckets[after].append(n) }
                    }
                }
            }
            for t in touched { left[t] = -1 }
        }
        let range = rules.constants.city.bombardRange
        for city in me.memory.cities where city.owner != player && isAtWar(with: city.owner) {
            map.forEachIndex(within: range, of: city.position) { if threat[$0] == nil { threat[$0] = .city(city.id) } }
        }
        return threat
    }

    /// Movement cost of a step over terrain as this player knows it (unexplored: 1), as
    /// `dangerMap` reckons an enemy's moves.
    private func exploreStepCost(from: Int, to: Int, _ direction: HexDirection, explored: TileBitSet) -> Int {
        var cost = 1
        if explored[to] {
            let tile = state.map.tiles[to]
            cost += rules.elevation(tile.elevation).moveCost
            if !(rules.feature(tile.feature).removedByCity && knownCity(at: coord(at: to)) != nil) {
                cost += rules.feature(tile.feature).moveCost
            }
        }
        if explored[from], state.map.tiles[from].riverEdges & (1 << UInt8(direction.rawValue)) != 0 {
            cost += rules.river.crossingMoveCost
        }
        return cost
    }

    // MARK: Finds

    /// Good city sites (M1 §16): explored tiles where this player could found a city, within
    /// `ai.settleMaxCityDistance` of an own city, that rank in the top quarter (`SiteQuality.good`)
    /// of the sites within that distance of such a city (`siteRanking`, as the settler overlay
    /// ranks the sites around a Settler). By tile; none before the first city.
    public func goodCitySites() -> [SiteScore] {
        let radius = rules.ai.settleMaxCityDistance
        var score = [Int](repeating: 0, count: tileCount)
        for city in cities.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let ranking = siteRanking(around: city.position, radius: radius)
            for site in ranking.sites where ranking.quality(of: site.score) == .good { score[site.tile] = site.score }
        }
        return score.indices.filter { score[$0] > 0 }.map { SiteScore(tile: $0, score: score[$0]) }
    }

    /// What a walk found (M1 §16 Explore finds): the good city sites (`goodCitySites`) this player
    /// knows now that were not good in `before` (its own view before the walk) and whose settle
    /// radius holds a tile explored since, leaving out any within `minDistance − 1` tiles of an
    /// `announced` site (a city there would stand on the same ground) and any on a known tribal
    /// village's tile (p3g: its sighting already points there, M1 §7.7). Best first: higher
    /// score, then nearer an own city, then lower tile.
    public func exploreFinds(since before: PlayerView, announced: [HexCoord] = []) -> [ExploreFind] {
        guard before.player == player, before.tileCount == tileCount else { return [] }
        var wasGood = [Bool](repeating: false, count: tileCount)
        for site in before.goodCitySites() { wasGood[site.tile] = true }
        let now = me.explored, then = before.me.explored
        let radius = rules.constants.settle.radius
        let spacing = rules.constants.city.minDistance - 1
        let own = cities.sorted { $0.id.rawValue < $1.id.rawValue }
        let villages = knownTribalVillages
        var finds: [ExploreFind] = []
        for site in goodCitySites() where !wasGood[site.tile] && !SortedTiles.contains(villages, site.tile) {
            let hex = coord(at: site.tile)
            var seen = false
            state.map.forEachIndex(within: radius, of: hex) { t in if now[t], !then[t] { seen = true } }
            guard seen, !announced.contains(where: { distance($0, hex) <= spacing }),
                  let city = own.min(by: { (distance($0.position, hex), $0.id.rawValue) < (distance($1.position, hex), $1.id.rawValue) })
            else { continue }
            finds.append(ExploreFind(hex: hex, score: site.score, city: city.id, cityName: city.name,
                                     distance: distance(city.position, hex)))
        }
        return finds.sorted { a, b in
            (b.score, a.distance, index(of: a.hex) ?? 0) < (a.score, b.distance, index(of: b.hex) ?? 0)
        }
    }
}

extension MoveKnowledge {
    /// `base` with no foreign unit in the way (`PlayerView.movementFieldPastUnits(of:)`): only
    /// the foreign cities its player remembers still block; everything else is `base`'s.
    init(_ base: MoveKnowledge, withoutUnitsIn state: GameState) {
        map = base.map
        rules = base.rules
        player = base.player
        unit = base.unit
        military = base.military
        explored = base.explored
        memoryOwner = base.memoryOwner
        closed = base.closed
        var blocked = TileBitSet(count: base.map.tileCount)
        if state.players.indices.contains(base.player.rawValue) {
            for city in state.players[base.player.rawValue].memory.cities where city.owner != base.player {
                if let t = base.map.index(of: city.position) { blocked[t] = true }
            }
        }
        self.blocked = blocked
        occupied = base.occupied
        ownCities = base.ownCities
        zoc = base.zoc
        freeElevation = base.freeElevation
        freeFeature = base.freeFeature
    }
}

/// A good city site an Explore walk brought into view (`PlayerView.exploreFinds(since:announced:)`).
public struct ExploreFind: Hashable, Sendable {
    public var hex: HexCoord
    /// Its `settleScore`.
    public var score: Int
    /// The own city nearest it (ties: the lower id), and how many tiles away.
    public var city: CityID
    public var cityName: String
    public var distance: Int
}

// MARK: - Compass

/// The eight compass points, as the map is drawn: north up.
public enum CompassPoint: Int, CaseIterable, Hashable, Sendable {
    case east, northEast, north, northWest, west, southWest, south, southEast

    /// "north-east".
    public var name: String {
        switch self {
        case .east: "east"
        case .northEast: "north-east"
        case .north: "north"
        case .northWest: "north-west"
        case .west: "west"
        case .southWest: "south-west"
        case .south: "south"
        case .southEast: "south-east"
        }
    }
}

extension HexMap {
    /// The compass point from tile `a` to tile `b` as the map shows them: the nearest of the
    /// eight to the line between their centres, the short way round a wrapping map. Rows grow
    /// northward and are drawn upward (`HexCoord`, `HexLayout`), so a tile of a lower row is to
    /// the south. Nil for the same place. Integer arithmetic: the same answer everywhere.
    public func compassPoint(from a: HexCoord, to b: HexCoord) -> CompassPoint? {
        // Centres in half tile widths east (2q + r) and rows north (r): the line between them
        // runs along (√3/2 · dx, 3/2 · dy), that is along (dx, √3 · dy).
        var dx = (2 * b.q + b.r) - (2 * a.q + a.r)
        let dy = b.r - a.r
        if wrapsX, width > 0 {
            let period = 2 * width
            dx = ((dx % period) + period) % period
            if dx > width { dx -= period }
        }
        guard dx != 0 || dy != 0 else { return nil }
        // Within 22.5° of the east–west line when 3·dy² < tan²(22.5°)·dx², and of the
        // north–south line when 3·dy² > tan²(67.5°)·dx²; tan² of those is 3 ∓ 2√2 (here × 10⁹).
        let x2 = Int64(dx) * Int64(dx), y2 = 3 * Int64(dy) * Int64(dy) * 1_000_000_000
        if y2 < 171_572_875 * x2 { return dx > 0 ? .east : .west }
        if y2 > 5_828_427_125 * x2 { return dy > 0 ? .north : .south }
        switch (dx > 0, dy > 0) {
        case (true, true): return .northEast
        case (false, true): return .northWest
        case (false, false): return .southWest
        case (true, false): return .southEast
        }
    }
}
