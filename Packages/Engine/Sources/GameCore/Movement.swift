// Movement (M1 §4, §7.3, §8.5, §8.6, §9).
//
// Move cost: 1, plus the elevation's and the feature's extra cost (a city centre has no
// forest, jungle or marsh), plus the river's crossing cost when the step crosses a river edge.
// A unit may always enter a passable tile if it has any moves left. Units never pass through or
// stop on tiles with foreign units, except that a military unit moves onto a tile holding only
// civilians of a player it is at war with, capturing them (M1 §7.3); units never enter a
// foreign city tile (a city is taken by attacking it); military units never enter territory of
// a player they are at peace with (closed borders). One military and one civilian unit per
// tile.
//
// Zone of control (M1 §8.5): a unit that enters a tile next to a military unit or city of a
// player it is at war with stops there for the phase (`zocStopped`; it keeps its moves for an
// attack). Paths are planned with the moving player's knowledge (`MoveKnowledge`), where such
// tiles end the turn; moves execute step by step against the real world and stop (clearing the
// order, `moveInterrupted`) at the first tile that turns out to be impassable or occupied, or
// at a zone of control the plan did not expect. Tribal villages (M1 §7.7) neither block nor
// stop a move: a unit takes the ones on the tiles it enters, passing through included.

/// What a player knows that matters for moving one of its units (M1 §8.6): explored terrain,
/// remembered borders and cities, units on visible tiles. Unexplored tiles count as passable
/// land with cost 1; hidden units and cities are ignored, including at the goal.
struct MoveKnowledge {
    let map: HexMap
    let rules: Ruleset
    let player: PlayerID
    let unit: UnitID
    let military: Bool
    let explored: TileBitSet
    let memoryOwner: [UInt8]
    /// Per owner code (player + 1): closed to this unit (military at peace).
    let closed: [Bool]
    /// Visible foreign units (except enemy civilians alone, which a military unit captures by
    /// moving in) and remembered foreign cities.
    let blocked: TileBitSet
    /// Own units of the same kind (military or civilian), the moving unit excluded.
    let occupied: TileBitSet
    /// Own city centres (no forest, jungle or marsh for movement).
    let ownCities: TileBitSet
    /// Zone of control (M1 §8.5): tiles next to a visible enemy military unit or a remembered
    /// enemy city. Entering one ends the unit's movement for the phase.
    let zoc: TileBitSet
    /// Per elevation / feature raw value: no extra move cost for this unit (promotions).
    let freeElevation: [Bool]
    let freeFeature: [Bool]
    /// Remembered roads (M2 §3.3) and whether road steps ignore rivers for this player.
    let roads: TileBitSet
    let bridges: Bool
    /// Water and naval movement (M2 §8.4).
    let mobility: Mobility
    let maxMoves: Int

    init(state: GameState, unit: Unit) {
        let me = state.players[unit.owner.rawValue]
        let count = state.map.tileCount
        let isMilitary = !unit.type.isCivilian
        let map = state.map
        self.map = map
        rules = state.rules
        player = unit.owner
        self.unit = unit.id
        military = isMilitary
        explored = me.explored
        memoryOwner = me.memory.tileOwner
        closed = [false] + state.players.map { other in isMilitary && state.bordersClosed(to: unit.owner, by: other.id) }
        let atWar = state.players.map { state.isAtWar(unit.owner, $0.id) }
        let ignoresZOC = state.ignoresZOC(unit)
        var blocked = TileBitSet(count: count)
        var occupied = TileBitSet(count: count)
        var ownCities = TileBitSet(count: count)
        var zoc = TileBitSet(count: count)
        for other in state.units {
            let t = map.index(of: other.position)!
            if other.owner != unit.owner {
                guard me.visible[t] else { continue }
                if other.type.isCivilian {
                    if !(isMilitary && atWar[other.owner.rawValue]) { blocked[t] = true }
                } else {
                    blocked[t] = true
                    if atWar[other.owner.rawValue], !ignoresZOC || state.holdsZOC(other) {
                        map.forEachNeighbor(of: t) { n, _ in if state.zocReaches(other, from: t, to: n) { zoc[n] = true } }
                    }
                }
            } else if other.id != unit.id, other.type.isCivilian == unit.type.isCivilian {
                occupied[t] = true
            }
        }
        for sighting in me.memory.cities where sighting.owner != unit.owner {
            let t = map.index(of: sighting.position)!
            blocked[t] = true
            if atWar[sighting.owner.rawValue], !ignoresZOC { map.forEachNeighbor(of: t) { n, _ in zoc[n] = true } }
        }
        for city in state.cities where city.owner == unit.owner {
            ownCities[map.index(of: city.position)!] = true
        }
        self.blocked = blocked
        self.occupied = occupied
        self.ownCities = ownCities
        self.zoc = zoc
        (freeElevation, freeFeature) = state.freeMove(unit)
        roads = me.memory.tileRoad ?? TileBitSet(count: count)
        bridges = state.rules.roads.map { me.knows($0.riverTech) } ?? false
        mobility = state.mobility(unit.type, owner: unit.owner)
        maxMoves = state.maxMoves(of: unit)
    }

    /// The unit may enter (and pass through) tile `t`, as far as its player knows.
    @inline(__always)
    func canEnter(_ t: Int) -> Bool {
        if explored[t], !mobility.allows(map.tiles[t], ownCity: ownCities[t], rules: rules) { return false }
        return !blocked[t] && !closed[Int(memoryOwner[t])]
    }

    /// The unit may end its move on tile `t`, as far as its player knows.
    @inline(__always)
    func canEnd(_ t: Int) -> Bool {
        canEnter(t) && !occupied[t]
    }

    /// Movement points to step from `from` to its neighbor `to` (unexplored: 1, rivers known
    /// from either explored side).
    @inline(__always)
    func cost(from: Int, to: Int, _ direction: HexDirection) -> Int {
        if let step = GameState.embarkStep(naval: mobility.naval, fromWater: explored[from] && map.tiles[from].terrain.isWater,
                                           toWater: explored[to] && map.tiles[to].terrain.isWater, maxMoves: maxMoves, rules: rules) {
            return step
        }
        var cost = 1
        if explored[to] {
            let tile = map.tiles[to]
            if !freeElevation[Int(tile.elevation.rawValue)] { cost += rules.elevation(tile.elevation).moveCost }
            if !freeFeature[Int(tile.feature.rawValue)], !(ownCities[to] && rules.feature(tile.feature).removedByCity) { cost += rules.feature(tile.feature).moveCost }
        }
        let river: Bool
        if explored[from] {
            river = map.tiles[from].riverEdges & (1 << UInt8(direction.rawValue)) != 0
        } else if explored[to] {
            river = map.tiles[to].riverEdges & (1 << UInt8(direction.opposite.rawValue)) != 0
        } else {
            river = false
        }
        return rules.stepPoints(cost, crossesRiver: river, road: roads[from] && roads[to], bridges: bridges)
    }
}

extension Ruleset {
    /// Move points for one step (M2 §3.3): the M1 cost `terrain` (plus the river crossing) ×
    /// `movePoints`; from a road tile to a road tile `roadCost`, plus the crossing unless
    /// `bridges`.
    @inline(__always)
    func stepPoints(_ terrain: Int, crossesRiver: Bool, road: Bool, bridges: Bool) -> Int {
        let crossing = crossesRiver ? river.crossingMoveCost * movePoints : 0
        if road, let roads { return roads.roadCost + (bridges ? 0 : crossing) }
        return terrain * movePoints + crossing
    }

    /// `moves` M1 moves in move points: what movement fields and `movesLeft` count.
    public func points(_ moves: Int) -> Int { moves * movePoints }

    /// Move points as moves for display (M2 §3.3): "2", "1⅓", "⅔".
    public func movesText(_ points: Int) -> String {
        let whole = points / movePoints, part = points % movePoints
        let fraction = part == 0 ? "" : movePoints == 3 ? (part == 1 ? "⅓" : "⅔") : "+\(part)/\(movePoints)"
        return whole == 0 && !fraction.isEmpty ? fraction : "\(whole)" + fraction
    }
}

extension GameState {
    // MARK: The real world

    /// Movement points for a land unit to step from tile `from` to its neighbor `to`.
    func moveCost(from: Int, to: Int, _ direction: HexDirection, owner: PlayerID? = nil,
                  free: (elevations: [Bool], features: [Bool])? = nil) -> Int {
        let tile = map.tiles[to]
        var cost = 1
        if free?.elevations[Int(tile.elevation.rawValue)] != true { cost += rules.elevation(tile.elevation).moveCost }
        if free?.features[Int(tile.feature.rawValue)] != true, !(rules.feature(tile.feature).removedByCity && city(atTile: to) != nil) { cost += rules.feature(tile.feature).moveCost }
        let river = map.tiles[from].riverEdges & (1 << UInt8(direction.rawValue)) != 0
        let bridges = rules.roads.flatMap { r in owner.map { players[$0.rawValue].knows(r.riverTech) } } ?? false
        return rules.stepPoints(cost, crossesRiver: river, road: map.tiles[from].hasRoad && tile.hasRoad, bridges: bridges)
    }

    /// Whether `unit` may enter (or pass through) tile `t`: passable, no foreign unit (except
    /// civilians alone of a player a military unit is at war with: it captures them), no
    /// foreign city, and not territory closed to it.
    func mayEnter(_ t: Int, _ unit: Unit) -> Bool {
        guard terrainAllows(t, unit.type, owner: unit.owner) else { return false }
        let hex = map.coord(at: t)
        let military = !unit.type.isCivilian
        for other in units where other.position == hex && other.owner != unit.owner {
            guard military, other.type.isCivilian, isAtWar(unit.owner, other.owner) else { return false }
        }
        if let city = owningCity(ofTile: t) {
            if city.owner != unit.owner {
                if map.index(of: city.position) == t { return false }
                if military, bordersClosed(to: unit.owner, by: city.owner) { return false }
            }
        }
        return true
    }

    /// Whether `unit` may stop on tile `t`: it may enter it and the tile has no other own unit
    /// of the same kind.
    func mayStop(_ t: Int, _ unit: Unit) -> Bool {
        guard mayEnter(t, unit) else { return false }
        let hex = map.coord(at: t)
        return !units.contains { $0.position == hex && $0.id != unit.id && $0.type.isCivilian == unit.type.isCivilian }
    }

    /// Whether `unit` may be put on tile `t` (spawning, eviction): it may stop there and no
    /// foreign unit stands there (nothing is captured this way).
    func mayStand(_ t: Int, _ unit: Unit) -> Bool {
        guard mayStop(t, unit) else { return false }
        let hex = map.coord(at: t)
        return !units.contains { $0.position == hex && $0.owner != unit.owner }
    }

    /// Whether a new unit of `type` for `owner` may be placed on tile `t`.
    func mayPlace(_ type: UnitType, owner: PlayerID, at t: Int) -> Bool {
        let probe = Unit(id: UnitID(-1), owner: owner, type: type, position: map.coord(at: t), movesLeft: 0)
        return mayStand(t, probe)
    }

    /// Tiles next to a military unit or city of a player at war with `player` (M1 §8.5):
    /// entering one ends a unit's movement for the phase. Nil when `player` is at war with no
    /// one.
    /// A unit that ignores zones of control (promotions) is held only by units that hold it.
    func zoneOfControl(for unit: Unit) -> TileBitSet? {
        let player = unit.owner
        let ignores = ignoresZOC(unit)
        guard relations.contains(where: { $0.stance == .war && $0.involves(player) }) else { return nil }
        var zoc = TileBitSet(count: map.tileCount)
        let map = self.map
        for u in units where !u.type.isCivilian && isAtWar(player, u.owner) && (!ignores || holdsZOC(u)) {
            let t = map.index(of: u.position)!
            map.forEachNeighbor(of: t) { n, _ in if zocReaches(u, from: t, to: n) { zoc[n] = true } }
        }
        for c in cities where !ignores && isAtWar(player, c.owner) {
            map.forEachNeighbor(of: map.index(of: c.position)!) { n, _ in zoc[n] = true }
        }
        return zoc
    }

    // MARK: Executing moves

    /// Moves `unit` along the steps of `path` it can take this phase, checking the real world
    /// at each step. Stops, clearing the order (`moveInterrupted`), at the first tile it may not
    /// enter, or where it would run out of moves on a tile it may not stop on; a unit never
    /// stops on a tile it may only pass through. Entering a zone of control ends the move for
    /// the phase (`zocStopped`, moves kept for an attack); the order is cleared (with
    /// `moveInterrupted`) only if the plan meant to go further this phase. The rest of the
    /// path stays as a standing order. A military unit captures the enemy civilians on the
    /// tiles it enters (M1 §7.3), after its `unitMoved`; then any unit takes the tribal villages
    /// on the tiles it entered, in path order (M1 §7.7; a move cut short takes only those).
    mutating func executeMove(_ id: UnitID, along path: Path, _ fx: inout Effects) {
        guard let start = unit(id), var here = map.index(of: start.position) else { return }
        let zoc = zoneOfControl(for: start)
        let free = freeMove(start)
        let full = maxMoves(of: start)
        var movesLeft = start.movesLeft
        var moved: [HexCoord] = []
        var stop = (steps: 0, moves: movesLeft) // the last tile it may stop on
        var interrupted = false
        var zocStop = false
        let steps = path.steps.prefix { $0.turn == 1 }
        for (i, step) in steps.enumerated() {
            guard movesLeft > 0 else { break }
            guard let next = map.index(of: step.hex), let direction = map.direction(from: here, to: next),
                  mayEnter(next, start) else {
                interrupted = true
                break
            }
            let cost = Self.embarkStep(naval: start.type.isNaval, fromWater: map.tiles[here].terrain.isWater,
                                       toWater: map.tiles[next].terrain.isWater, maxMoves: full, rules: rules)
                ?? moveCost(from: here, to: next, direction, owner: start.owner, free: free)
            let after = movesLeft - min(movesLeft, cost)
            let stoppable = mayStop(next, start)
            let inZOC = zoc?[next] ?? false
            if after == 0 || inZOC, !stoppable {
                interrupted = true
                break
            }
            here = next
            movesLeft = after
            moved.append(step.hex)
            if stoppable { stop = (moved.count, movesLeft) }
            if inZOC {
                zocStop = true
                if i + 1 < steps.count { interrupted = true } // the plan meant to go on this phase
                break
            }
        }
        if moved.count != stop.steps {
            // Never stop on a pass-through tile; a tile with captured civilians is not one, so
            // this never undoes a capture.
            moved.removeLast(moved.count - stop.steps)
            movesLeft = stop.moves
            interrupted = true
        }
        let final = moved.last ?? start.position
        let reached = final == path.destination
        let turn = self.turn
        updateUnit(id) { unit in
            unit.position = final
            unit.movesLeft = movesLeft
            unit.destination = reached || interrupted ? nil : path.destination
            if zocStop { unit.zocStopped = true }
            if !moved.isEmpty {
                unit.activity = .none
                unit.lastActedTurn = turn
            }
        }
        if !moved.isEmpty {
            let tiles = ([start.position] + moved).map { map.index(of: $0)! }
            fx.emit(.unitMoved(unit: id, from: start.position, path: moved), .move(owner: start.owner, tiles: tiles))
            fx.touchPlayer(start.owner)
            if !start.type.isCivilian {
                for t in tiles.dropFirst() { captureCivilians(at: t, by: start.owner, &fx) }
            }
            if tribalVillages != nil {
                for t in tiles.dropFirst() where holdsTribalVillage(t) {
                    takeTribalVillage(at: t, by: start.owner, unit: id, city: nil, &fx)
                }
            }
        }
        if interrupted {
            fx.emit(.moveInterrupted(unit: id, at: final), .tiles([map.index(of: final)!]))
        }
    }

    /// Continues a unit's standing order (phase start): re-plans with its player's knowledge;
    /// with no path left the order is cleared (`moveInterrupted`).
    mutating func continueOrders(_ id: UnitID, _ fx: inout Effects) {
        guard let unit = unit(id), let destination = unit.destination else { return }
        guard let path = Pathfinder.findPath(for: unit, to: destination, in: self) else {
            updateUnit(id) { $0.destination = nil }
            fx.emit(.moveInterrupted(unit: id, at: unit.position), .tiles([map.index(of: unit.position)!]))
            return
        }
        executeMove(id, along: path, &fx)
    }

    /// Moves a military unit standing in territory closed to it to the nearest tile it may
    /// stand on outside it that holds no tribal village (ties: lower index), at its owner's phase
    /// start (M1 §9). Eviction is a relocation, not a move: it takes nothing (M1 §7.7). The real
    /// world decides the tile, as it decides where a move stops (M1 §8.6): a tribal village or a
    /// unit its player cannot see moves it on to the next tile, so fog twins differ here (an
    /// exception to the G10 twins the p3g review accepted; TribalVillageOtherPathTests).
    mutating func evictIfInClosedTerritory(_ id: UnitID, _ fx: inout Effects) {
        guard let unit = unit(id), !unit.type.isCivilian, let here = map.index(of: unit.position),
              let owner = tileOwner(here), bordersClosed(to: unit.owner, by: owner) else { return }
        let limit = max(map.width, map.height)
        for radius in 1...limit {
            var best: Int?
            map.forEachIndex(within: radius, of: unit.position) { t in
                guard map.distance(index: t, here) == radius, best.map({ t < $0 }) ?? true, !holdsTribalVillage(t),
                      mayStand(t, unit) else { return }
                best = t
            }
            guard let target = best else { continue }
            let hex = map.coord(at: target)
            updateUnit(id) { u in
                u.position = hex
                u.activity = .none
            }
            fx.emit(.unitMoved(unit: id, from: unit.position, path: [hex]), .tiles([here, target]))
            fx.touchPlayer(unit.owner)
            return
        }
    }
}
