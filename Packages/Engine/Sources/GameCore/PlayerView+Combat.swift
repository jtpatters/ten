// PlayerView queries for combat, movement and danger (M1 §8.4, §12.6). Like every PlayerView
// query they use only what the viewing player knows: foreign units count only on tiles it
// sees now, cities only as it remembers them, terrain only where explored.

/// A target an own unit or city can attack this phase (M1 §8.4).
public struct AttackOption: Hashable, Sendable {
    /// The target's tile.
    public var target: HexCoord
    /// What would be hit: the enemy city on the tile, else its military unit.
    public var defender: Combatant
    /// The tile to attack from: the reachable tile next to (melee) or within range of (ranged)
    /// the target with the lowest path cost (ties: lower index); the unit's own tile when no
    /// move is needed, the city's centre for a bombard.
    public var from: HexCoord
    /// Movement points spent reaching `from` (0 when it is the unit's tile).
    public var moveCost: Int
}

/// What an attack would do, as the attacking player can tell (M1 §8.4).
public struct CombatPreview: Hashable, Sendable {
    public var attacker: Combatant
    public var defender: Combatant
    public var from: HexCoord
    public var target: HexCoord
    /// A ranged attack or a bombard: no retaliation.
    public var ranged: Bool
    /// Effective strengths with every modifier (M1 §8.1).
    public var attackerStrength: Strength
    public var defenderStrength: Strength
    /// Damage to the defender for the lowest and the highest roll (before it is capped at the
    /// HP it has).
    public var damageDealt: ClosedRange<Int>
    /// Damage to a melee attacker for the lowest and the highest roll (0...0 for ranged).
    public var damageTaken: ClosedRange<Int>
    /// Mean damage over the rolls, rounded.
    public var meanDealt: Int
    public var meanTaken: Int
    /// Roll pairs (of `rollPairs`, 31 × 31) in which the defender dies (units) or the city's
    /// HP reaches 0.
    public var killPairs: Int
    /// Roll pairs in which the attacker dies.
    public var deathPairs: Int
    public var rollPairs: Int
    /// The attack takes a city already at 0 HP, without combat.
    public var capturesCity: Bool
    /// The target tile holds enemy civilians the attacker captures if it kills the defender
    /// and moves in.
    public var capturesCivilians: Bool

    /// Kill chance in percent, rounded to the nearest.
    public var killChancePercent: Int { (killPairs * 200 + rollPairs) / (2 * rollPairs) }
    /// Death chance in percent, rounded to the nearest.
    public var deathChancePercent: Int { (deathPairs * 200 + rollPairs) / (2 * rollPairs) }

    /// Whether the kill chance is at least `percent` (exact, no rounding).
    public func killChance(atLeast percent: Int) -> Bool { killPairs * 100 >= percent * rollPairs }
    /// Whether the death chance is at least `percent` (exact, no rounding).
    public func deathChance(atLeast percent: Int) -> Bool { deathPairs * 100 >= percent * rollPairs }
}

extension PlayerView {
    // MARK: Attacks

    /// Every target an own unit can attack this phase (M1 §8.4), sorted by tile index: visible
    /// enemy military units and visible enemy cities (none for recon units), each with the
    /// tile to attack from. Empty outside this player's phase, for civilians, and for units
    /// with no moves left. A unit stopped by a zone of control attacks only from its tile.
    public func attackOptions(for id: UnitID) -> [AttackOption] {
        guard isMyPhase, let unit = state.unit(id), unit.owner == player, state.attackerProblem(unit) == nil,
              let start = index(of: unit.position) else { return [] }
        let def = rules.unit(unit.type)
        let k = MoveKnowledge(state: state, unit: unit)
        let field = Pathfinder.phaseField(k, from: start, movesLeft: unit.zocStopped ? 0 : unit.movesLeft)
        let reach = def.isRanged ? def.range : 1
        var options: [AttackOption] = []
        for (t, defender) in visibleTargets(attackingCities: def.unitClass != .recon) {
            var best: (cost: Int, tile: Int)?
            state.map.forEachIndex(within: reach, of: coord(at: t)) { f in
                guard f != t else { return }
                let left = f == start ? unit.movesLeft : Int(field.best[f])
                guard left >= 1, f == start || k.canEnd(f) else { return }
                if !def.isRanged, state.map.distance(index: f, t) != 1 { return }
                let cost = unit.movesLeft - left
                if let b = best, (b.cost, b.tile) <= (cost, f) { return }
                best = (cost, f)
            }
            if let best {
                options.append(AttackOption(target: coord(at: t), defender: defender, from: coord(at: best.tile), moveCost: best.cost))
            }
        }
        return options
    }

    /// Every target an own city can bombard this phase (M1 §5): visible enemy military units
    /// and cities within the bombard range, sorted by tile index. Empty outside this player's
    /// phase or once the city has bombarded.
    public func cityAttackOptions(for id: CityID) -> [AttackOption] {
        guard isMyPhase, let city = city(id), !city.bombarded, let centre = index(of: city.position) else { return [] }
        let range = rules.constants.city.bombardRange
        return visibleTargets(attackingCities: true)
            .filter { state.map.distance(index: $0.tile, centre) <= range }
            .map { AttackOption(target: coord(at: $0.tile), defender: $0.defender, from: city.position, moveCost: 0) }
    }

    /// Visible enemy cities and military units (not in cities), by tile index.
    private func visibleTargets(attackingCities: Bool) -> [(tile: Int, defender: Combatant)] {
        var targets: [(tile: Int, defender: Combatant)] = []
        for city in state.cities where attackingCities && city.owner != player && state.isAtWar(player, city.owner) {
            let t = index(of: city.position)!
            if me.visible[t] { targets.append((t, .city(city.id))) }
        }
        for unit in state.units where unit.owner != player && !unit.type.isCivilian && state.isAtWar(player, unit.owner) {
            let t = index(of: unit.position)!
            if me.visible[t], state.city(atTile: t) == nil { targets.append((t, .unit(unit.id))) }
        }
        return targets.sorted { $0.tile < $1.tile }
    }

    /// What an attack by an own unit or city on `target` from `from` would do (M1 §8.4), as
    /// this player can tell: strengths with every modifier, damage ranges, and kill and death
    /// chances counted exactly over all 31 × 31 roll pairs. Nil when no such attack is possible
    /// (no visible enemy there, out of reach from `from`, a civilian attacker, a recon unit and
    /// a city). `from` need not be the unit's tile: the preview assumes it moves there first.
    public func combatPreview(attacker: Combatant, target: HexCoord, from: HexCoord) -> CombatPreview? {
        guard let t = index(of: target), let f = index(of: from), me.visible[t],
              case let .target(defender) = state.attackTarget(at: t, by: player) else { return nil }
        let sees: (Int) -> Bool = { me.visible[$0] }
        let side: CombatSide
        let ranged: Bool
        var capturesCivilians = false
        switch attacker {
        case let .unit(id):
            guard var unit = state.unit(id), unit.owner == player, rules.unit(unit.type).isMilitary,
                  state.attackReachProblem(unit.type, from: f, at: t, against: defender) == nil else { return nil }
            unit.position = coord(at: f)
            side = .unit(unit)
            ranged = rules.unit(unit.type).isRanged
            // A garrison (attacking from an own city) stays put and captures nothing. Only an own
            // city counts: a hypothetical `from` on a hidden foreign city must not change the answer.
            if case .unit = defender, !ranged, state.city(atTile: f)?.owner != player {
                let hex = coord(at: t)
                capturesCivilians = state.units.contains { $0.position == hex && $0.owner == defender.owner && $0.type.isCivilian }
            }
            if case let .city(city) = defender, !ranged, city.hp == 0, state.capturesCities(unit.type) {
                return captureWithoutCombat(attacker: attacker, defender: defender, side: side, from: f, target: t)
            }
        case let .city(id):
            guard let city = city(id), index(of: city.position) == f,
                  state.map.distance(index: f, t) <= rules.constants.city.bombardRange else { return nil }
            side = .city(city)
            ranged = true
        }
        let clash = state.clash(attacker: side, defender: defender, from: f, target: t, ranged: ranged, sees: sees)
        let range = rules.constants.combat.rollRange
        let rolls = -range...range
        let dealt = rolls.map { CombatMath.damage(base: clash.baseDealt, roll: $0) }
        let taken = ranged ? rolls.map { _ in 0 } : rolls.map { CombatMath.damage(base: clash.baseTaken, roll: $0) }

        // Exactly over every pair of rolls (the attacker's, then the retaliation's).
        let defenderHP: Int, defenderIsCity: Bool
        switch defender {
        case let .unit(u): (defenderHP, defenderIsCity) = (u.hp, false)
        case let .city(c): (defenderHP, defenderIsCity) = (c.wallHP + c.hp, true)
        }
        let attackerHP: Int
        if case let .unit(u) = side { attackerHP = u.hp } else { attackerHP = .max }
        var kills = 0, deaths = 0, pairs = 0
        for d in dealt {
            let kill = d >= defenderHP
            for r in taken {
                pairs += 1
                if kill { kills += 1 }
                // A melee winner survives; a city's HP reaching 0 does not save the attacker.
                if !ranged, r >= attackerHP, !kill || defenderIsCity { deaths += 1 }
            }
        }
        let n = dealt.count
        return CombatPreview(attacker: attacker, defender: defender.combatant, from: from, target: target, ranged: ranged,
                             attackerStrength: clash.attack, defenderStrength: clash.defence,
                             damageDealt: dealt.min()!...dealt.max()!, damageTaken: taken.min()!...taken.max()!,
                             meanDealt: (dealt.reduce(0, +) * 2 + n) / (2 * n), meanTaken: (taken.reduce(0, +) * 2 + n) / (2 * n),
                             killPairs: kills, deathPairs: deaths, rollPairs: pairs,
                             capturesCity: false, capturesCivilians: capturesCivilians)
    }

    /// A melee or antiCavalry unit attacking a city at 0 HP takes it without combat.
    private func captureWithoutCombat(attacker: Combatant, defender: CombatSide, side: CombatSide, from f: Int,
                                      target t: Int) -> CombatPreview {
        let sees: (Int) -> Bool = { me.visible[$0] }
        let clash = state.clash(attacker: side, defender: defender, from: f, target: t, ranged: false, sees: sees)
        let range = rules.constants.combat.rollRange
        let pairs = (2 * range + 1) * (2 * range + 1)
        return CombatPreview(attacker: attacker, defender: defender.combatant, from: coord(at: f), target: coord(at: t),
                             ranged: false, attackerStrength: clash.attack, defenderStrength: clash.defence,
                             damageDealt: 0...0, damageTaken: 0...0, meanDealt: 0, meanTaken: 0,
                             killPairs: pairs, deathPairs: 0, rollPairs: pairs, capturesCity: true, capturesCivilians: false)
    }

    // MARK: Movement and distance

    /// Movement points an own unit needs to reach each tile and stop there (M1 §12.6),
    /// counting points left unused at turn ends; −1 where it cannot. By this player's knowledge,
    /// with zones of control from visible enemies ending the turn. Costs above `limit` are
    /// left at −1 (the search stops there). Empty for another player's unit.
    public func movementField(for id: UnitID, limit: Int = .max) -> [Int32] {
        guard let unit = state.unit(id), unit.owner == player, let start = index(of: unit.position) else { return [] }
        let k = MoveKnowledge(state: state, unit: unit)
        return Pathfinder.movementField(k, from: start, movesLeft: unit.zocStopped ? 0 : unit.movesLeft,
                                        maxMoves: rules.unit(unit.type).moves, limit: limit)
    }

    /// Steps from the nearest of `sources` to each tile over land as this player knows it
    /// (explored impassable tiles block; unexplored tiles count as passable land), ignoring
    /// units and borders; −1 where unreachable or beyond `limit`.
    public func distanceField(from sources: [HexCoord], limit: Int = Int(Int16.max)) -> [Int16] {
        var field = [Int16](repeating: -1, count: tileCount)
        var queue: [Int] = []
        for source in sources {
            guard let t = index(of: source), field[t] < 0 else { continue }
            field[t] = 0
            queue.append(t)
        }
        let cap = min(limit, Int(Int16.max))
        var head = 0
        while head < queue.count {
            let t = queue[head]
            head += 1
            let d = Int(field[t])
            guard d < cap else { continue }
            state.map.forEachNeighbor(of: t) { n, _ in
                guard field[n] < 0, !me.explored[n] || rules.isPassable(state.map.tiles[n]) else { return }
                field[n] = Int16(d + 1)
                queue.append(n)
            }
        }
        return field
    }

    /// `distanceField(from:)` from one tile.
    public func distanceField(from source: HexCoord, limit: Int = Int(Int16.max)) -> [Int16] {
        distanceField(from: [source], limit: limit)
    }

    // MARK: Danger and power

    /// Per tile: the summed power of the visible enemy military units that could attack it in
    /// their next phase (M1 §12.6), each with full moves over terrain as this player knows it
    /// (units, borders and zones of control ignored): melee units the tiles next to where they
    /// can get with a move left, ranged units the tiles within range of those.
    public func dangerMap() -> [Int32] {
        var danger = [Int32](repeating: 0, count: tileCount)
        var mark = [Int32](repeating: -1, count: tileCount)
        var left = [Int8](repeating: -1, count: tileCount)
        var stamp: Int32 = 0
        for enemy in state.units where enemy.owner != player && !enemy.type.isCivilian && state.isAtWar(player, enemy.owner) {
            guard let start = index(of: enemy.position), me.visible[start] else { continue }
            let def = rules.unit(enemy.type)
            let power = Int32(power(of: enemy))
            let reach = def.isRanged ? def.range : 1
            stamp += 1
            // Where it can stand with a move left next phase (most moves left first).
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
                    state.map.forEachIndex(within: reach, of: coord(at: t)) { a in
                        if a != t, mark[a] != stamp {
                            mark[a] = stamp
                            danger[a] += power
                        }
                    }
                    state.map.forEachNeighbor(of: t) { n, direction in
                        if me.explored[n], !rules.isPassable(state.map.tiles[n]) { return }
                        let after = moves - min(moves, knownCost(from: t, to: n, direction))
                        guard after > Int(left[n]) else { return }
                        if left[n] < 0 { touched.append(n) }
                        left[n] = Int8(after)
                        if after > 0 { buckets[after].append(n) }
                    }
                }
            }
            for t in touched { left[t] = -1 }
        }
        return danger
    }

    /// Movement cost of a step over terrain as this player knows it (unexplored: 1).
    private func knownCost(from: Int, to: Int, _ direction: HexDirection) -> Int {
        var cost = 1
        if me.explored[to] {
            let tile = state.map.tiles[to]
            cost += rules.elevation(tile.elevation).moveCost
            if !(rules.feature(tile.feature).removedByCity && knownCity(at: coord(at: to)) != nil) {
                cost += rules.feature(tile.feature).moveCost
            }
        }
        if me.explored[from], state.map.tiles[from].riverEdges & (1 << UInt8(direction.rawValue)) != 0 {
            cost += rules.river.crossingMoveCost
        }
        return cost
    }

    /// A city's garrison (M1 §13): its lowest-id military unit on the city tile. For an own
    /// city, or a foreign city on a tile this player sees; nil otherwise.
    public func garrison(of id: CityID) -> Unit? {
        guard let city = state.city(id), let t = index(of: city.position), city.owner == player || me.visible[t] else { return nil }
        return state.units.first { $0.position == city.position && $0.owner == city.owner && !$0.type.isCivilian }
    }

    /// A unit's power (M1 §13): (Ranged Strength if it has one, else Strength) × HP / 100.
    public func power(of unit: Unit) -> Int {
        power(of: unit.type, hp: unit.hp)
    }

    /// A sighting's power, from its type and the HP last seen.
    public func power(of sighting: UnitSighting) -> Int {
        power(of: sighting.type, hp: sighting.hp)
    }

    public func power(of type: UnitType, hp: Int) -> Int {
        let def = rules.unit(type)
        return (def.isRanged ? def.rangedStrength : def.strength) * hp / 100
    }

    /// Sightings of one player's units, sorted by id.
    public func sightings(of owner: PlayerID) -> [UnitSighting] {
        me.memory.units.filter { $0.owner == owner }
    }

    // MARK: Cities and diplomacy

    /// Whether an own city may be razed now (captured this phase, not an original capital).
    public func canRaze(_ id: CityID) -> Bool {
        guard isMyPhase, let index = state.cityIndex(id), state.cities[index].owner == player else { return false }
        return state.razeProblem(index) == nil
    }

    /// Why this player may not declare war on `other` now (nil: it may).
    public func warProblem(on other: PlayerID) -> String? {
        if !isMyPhase { return "not your turn" }
        return state.warProblem(player, on: other)
    }

    /// Why this player may not propose peace to `other` now (nil: it may).
    public func peaceProblem(to other: PlayerID) -> String? {
        if !isMyPhase { return "not your turn" }
        return state.proposalProblem(player, to: other)
    }

    /// Players whose peace proposal to this player awaits an answer, in player order.
    public var peaceProposals: [PlayerID] {
        state.relations.compactMap { r in
            guard r.involves(player), let from = r.proposalFrom, from != player else { return nil }
            return from
        }.sorted()
    }
}
