import GameCore

// p3f ai-civilian-reach (M1 §13 Safety): a last look at the civilians once the military has moved.
//
// Civilians move before the military (`AITurn.play`), so two cases slipped through the Safety
// rule:
// - an enemy revealed during the phase, by the civilian's own move or by the units moving after
//   it, left the civilian where it stopped, inside that enemy's reach (p3d: 25 of 28 sampled
//   exposures);
// - a civilian with no safe tile in reach waited for an escort, and the escort, which moves later,
//   got only as far as its moves took it. In the iPhone side game (Duel seed 23, at war from T4)
//   Rome's Settler waited at (12,5) next to a Mongol Scout, its Warrior stopped 2 tiles short at
//   (11,4), and the Scout took the Settler on T20.
//
// So, after the military, each own civilian standing where a visible enemy military unit could
// move next phase (`PlayerView.aiEnemyReach`), with no own military unit on its tile and outside
// an own city:
// 1. with moves left, steps to the least-exposed tile it reaches: a safe one first (a tile an own
//    military unit holds counts, such as an escort that stopped short), else one out of every
//    enemy's known reach, else one out of the visible enemies' reach; ties the cheapest, then the
//    lower index. It moves only to a tile less exposed than its own.
// 2. Still inside the reach (no moves, or no better tile), the nearest own fighter that reaches
//    its tile this phase steps onto it and fortifies (cheapest, then lower id): not a city's
//    garrison, not a wounded unit (below retreatHP), not one standing by a threatened city.

extension AITurn {
    /// M1 §13 Safety, after the military moved (see the file comment).
    mutating func secureCivilians() {
        guard live else { return }
        let start = view
        let ids = start.units.filter { $0.type.isCivilian }.map(\.id)
        guard !ids.isEmpty else { return }
        var reach = start.aiEnemyReach()
        guard reach.contains(true) else { return }
        for id in ids {
            guard live else { return }
            var v = view
            guard let unit = v.unit(id), var at = v.index(of: unit.position), reach[at], !safe(at, v, danger: civilianDanger(v)) else {
                continue
            }
            if unit.movesLeft > 0, !unit.zocStopped, let to = leastExposedTile(for: unit, from: at, reach: reach, v) {
                let from = unit.position
                if move(id, to: v.coord(at: to)), let after = view.unit(id), let t = view.index(of: after.position) {
                    holdGuard(of: id)
                    at = t
                    note("\(unit.type.displayName) \(id) at \(from), in an enemy's reach after the military moved, steps to \(after.position)")
                    // Its move may have revealed more enemies.
                    v = view
                    reach = v.aiEnemyReach()
                }
            }
            guard reach[at], !safe(at, v, danger: civilianDanger(v)) else { continue }
            if coverCivilian(id, at: at) { reach = view.aiEnemyReach() }
        }
    }

    /// The tile (index) a civilian in an enemy's reach should step to with the moves it has left:
    /// the least exposed it reaches (safe; else out of every enemy's known reach, M1 §13 Safety
    /// enemies only; else out of the visible enemies' reach), ties the cheapest, then the lower
    /// index; nil when none is less exposed than its own tile `here`.
    mutating func leastExposedTile(for unit: Unit, from here: Int, reach: [Bool], _ v: PlayerView) -> Int? {
        forgetFields(unit.id) // other units moved since its field was computed
        let danger = civilianDanger(v)
        let enemies = civilianDanger(v, enemiesOnly: true)
        func exposure(_ t: Int) -> Int {
            if safe(t, v, danger: danger) { return 0 }
            if !enemies[t] { return 1 }
            return reach[t] ? 3 : 2
        }
        let f = reachField(unit.id)
        var best: (exposure: Int, cost: Int32, tile: Int)?
        for t in reachableThisPhase(unit) {
            let key = (exposure(t), f[t], t)
            if let b = best, (b.exposure, b.cost, b.tile) <= key { continue }
            best = key
        }
        guard let best, best.exposure < exposure(here) else { return nil }
        return best.tile
    }

    /// The nearest own fighter that reaches civilian `id`'s tile `t` this phase steps onto it and
    /// fortifies there (cheapest move, then lower id): not a city's garrison, not below retreatHP,
    /// not standing by a threatened city. Returns whether one came.
    @discardableResult
    mutating func coverCivilian(_ id: UnitID, at t: Int) -> Bool {
        let v = view
        let garrisons = forces(v).garrisonIDs
        let guarded = plan.threatened.compactMap { v.city($0).flatMap { v.index(of: $0.position) } }
        var best: (cost: Int32, unit: UnitID)?
        for u in v.units where isFighter(u.type) && u.movesLeft > 0 && !u.zocStopped && u.hp >= ai.retreatHP && !garrisons.contains(u.id) {
            guard let here = v.index(of: u.position), v.aiDistance(here, t) <= u.movesLeft,
                  !guarded.contains(where: { v.aiDistance($0, here) <= 1 }) else { continue }
            forgetFields(u.id)
            let f = reachField(u.id)
            guard f[t] > 0, Int(f[t]) <= u.movesLeft else { continue }
            if let b = best, (b.cost, b.unit) <= (f[t], u.id) { continue }
            best = (f[t], u.id)
        }
        guard let best, let civilian = v.unit(id), move(best.unit, to: v.coord(at: t)),
              let escort = view.unit(best.unit), escort.position == v.coord(at: t) else { return false }
        acted.insert(best.unit)
        fortify(escort)
        note("sends \(escort.type.displayName) \(best.unit) onto \(civilian.type.displayName) \(id)'s tile \(civilian.position): "
            + "it is in an enemy's reach and has no safer tile")
        return true
    }
}
