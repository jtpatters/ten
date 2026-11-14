import GameCore

// Settling, Builders and civilian safety (M1 §13 Settling, Builders), and exploring (M1 §13
// Exploring).

extension AITurn {
    // MARK: First city

    /// M1 §13: the first city is founded on turn 1 where the Settler stands if valid, unless a
    /// neighbouring tile scores ≥ firstCityMovePct of it (then the Settler moves there and
    /// founds on turn 2). On a later turn with no city, a Settler on a valid tile founds there.
    mutating func foundFirstCity() {
        guard view.cities.isEmpty else { return }
        let settlers = view.units.filter { rules.unit($0.type).foundsCity }.map(\.id)
        for id in settlers {
            let v = view
            guard live, v.cities.isEmpty, let unit = v.unit(id), !acted.contains(id) else { break }
            let here = unit.position
            // Not where borders hint at an unseen city (moveSettlers looks for a site then).
            guard v.canFoundCity(at: here), let t = v.index(of: here), !hiddenCityRisk(v)[t] else { continue }
            if v.turn <= 1 {
                let score = v.settleScore(at: here)
                var best: (score: Int, tile: Int)?
                for n in v.neighbors(of: here) where v.canFoundCity(at: n) {
                    let s = v.settleScore(at: n)
                    guard let t = v.index(of: n), 100 * s >= ai.firstCityMovePct * score else { continue }
                    if let b = best, (b.score, -b.tile) >= (s, -t) { continue }
                    best = (s, t)
                }
                if let best, safe(best.tile, for: unit, v) || hasEscort(unit, v) != nil {
                    acted.insert(id)
                    if let escort = hasEscort(unit, v), let path = v.path(for: id, to: v.coord(at: best.tile)),
                       travelTogether(civilian: id, escort: escort, along: path) {
                    } else {
                        move(id, to: v.coord(at: best.tile))
                    }
                    continue
                }
            }
            acted.insert(id)
            note("founds its first city at \(here) (score \(v.settleScore(at: here)))")
            issue(.foundCity(unit: id))
        }
    }

    // MARK: Settlers

    /// M1 §13 Settling: Settlers in id order head for the best good site they reach within
    /// settleMaxMoveCost (value: settleScore − settleCostPenalty × cost; ties lower cost, then
    /// lower index); a chosen site removes candidates within settleSiteSpacing. A Settler on its
    /// site founds the city. With no site left it sleeps in the nearest own city. With no city
    /// at all (the first one could not be founded where it stood) any foundable site counts.
    mutating func moveSettlers() {
        let ids = view.units.filter { rules.unit($0.type).foundsCity && !acted.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        // The plan's good sites (this phase's knowledge), recomputed after a founding.
        var sites = !view.cities.isEmpty && view.cities.count == plan.sitesCities ? plan.sites : settlerSites(view)
        var chosen: [Int] = []
        // p3f B (AIPreparePosture.swift): in prepare, sites nearer the rival are worth more.
        let towardRival = rivalSitePreference(view)
        for id in ids {
            guard live, let unit = view.unit(id) else { continue }
            let v = view
            acted.insert(id)
            // Good sites lie within settleMaxMoveCost: a movement field cut off there is exact
            // for them (and much cheaper than a whole one on a big map).
            let near = field(id, within: rules.points(ai.settleMaxMoveCost))
            var best: (value: Int, cost: Int, tile: Int)?
            for site in sites {
                let cost = Int(near[site.tile])
                guard cost >= 0, cost <= rules.points(ai.settleMaxMoveCost),
                      !chosen.contains(where: { v.aiDistance($0, site.tile) <= ai.settleSiteSpacing }) else { continue }
                // Scores count per move; `cost` is in move points (M2 §3.3).
                let value = (site.score - (towardRival.map { $0.penalty(site.tile, v) } ?? 0)) * rules.movePoints - ai.settleCostPenalty * cost
                if let b = best, (b.value, -b.cost, -b.tile) >= (value, -cost, -site.tile) { continue }
                best = (value, cost, site.tile)
            }
            // ai-2: a Settler with no good site within settleMaxMoveCost heads for the nearest
            // good site beyond it (the cities built it for one) rather than sleeping in a city;
            // it sleeps only when no good site is left at all.
            if best == nil {
                let f = field(id)
                for site in sites {
                    let cost = Int(f[site.tile])
                    guard cost > rules.points(ai.settleMaxMoveCost),
                          !chosen.contains(where: { v.aiDistance($0, site.tile) <= ai.settleSiteSpacing }) else { continue }
                    if let b = best, (b.cost, b.tile) <= (cost, site.tile) { continue }
                    best = (site.score * rules.movePoints - ai.settleCostPenalty * cost, cost, site.tile)
                }
            }
            guard let best else {
                parkInNearestCity(unit)
                continue
            }
            chosen.append(best.tile)
            if v.index(of: unit.position) == best.tile {
                note("Settler \(id) founds a city at \(unit.position) (score \(v.settleScore(at: unit.position)))")
                if issue(.foundCity(unit: id)) {
                    sites = settlerSites(view) // the new city rules out sites near it
                }
                continue
            }
            travel(id, to: v.coord(at: best.tile))
        }
    }

    /// Sites Settlers may choose: good sites (M1 §13); with no own city, every foundable
    /// explored site with a positive score.
    func settlerSites(_ v: PlayerView) -> [Site] {
        if !v.cities.isEmpty { return goodSites(v) }
        var sites: [Site] = []
        var seen = [Bool](repeating: false, count: v.tileCount)
        let hidden = hiddenCityRisk(v)
        for unit in v.units where rules.unit(unit.type).foundsCity {
            guard let c = v.index(of: unit.position) else { continue }
            for t in v.aiTiles(within: ai.settleMaxMoveCost, of: c) where !seen[t] && !hidden[t] {
                seen[t] = true
                let score = v.settleScore(at: v.coord(at: t))
                if score > 0 { sites.append(Site(tile: t, score: score)) }
            }
        }
        return sites.sorted { $0.tile < $1.tile }
    }

    /// Takes a civilian to the nearest own city and puts it to sleep there.
    mutating func parkInNearestCity(_ unit: Unit) {
        let v = view
        guard !v.cities.isEmpty else {
            sleep(unit)
            return
        }
        if v.cities.contains(where: { $0.position == unit.position }) {
            sleep(unit)
            return
        }
        let f = field(unit.id)
        var best: (cost: Int, tile: Int)?
        for city in v.cities {
            guard let t = v.index(of: city.position), f[t] >= 0 else { continue }
            if let b = best, (b.cost, b.tile) <= (Int(f[t]), t) { continue }
            best = (Int(f[t]), t)
        }
        guard let best else {
            sleep(unit)
            return
        }
        if best.cost == 0 {
            sleep(unit)
        } else {
            travel(unit.id, to: v.coord(at: best.tile))
            if let after = view.unit(unit.id), after.position == v.coord(at: best.tile) { sleep(after) }
        }
    }

    // MARK: Builders

    /// M1 §13 Builders: each Builder (id order) improves the best worked unimproved tile of its
    /// territory — Farm by fresh water first, Mines on hills, then Pastures (then plain
    /// Farms) — nearest first; Builders reserve their tiles. A Builder with nothing to do sleeps
    /// in the nearest own city.
    mutating func moveBuilders() {
        let ids = view.units.filter { $0.type == .builder && $0.charges > 0 && !acted.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        let work = improvableWorkedTiles(view)
        var reserved: [Int] = []
        var roads: [Int]?
        for id in ids {
            guard live, let unit = view.unit(id) else { continue }
            let v = view
            acted.insert(id)
            guard !work.isEmpty else {
                if roads == nil { roads = roadWork(v) }
                if !layRoad(unit, roads!, &reserved) { parkInNearestCity(unit) }
                continue
            }
            // ai-3: tiles a Builder may stand on safely come first (M1 §13 Safety), so Builders
            // improve the tiles away from foreign troops instead of waiting by the others. Work
            // within builderMaxMoveCost comes first (a cut-off movement field, cheap on big
            // maps); only with none there does a Builder look further.
            let danger = civilianDanger(v)
            func pick(_ f: [Int32]) -> (unsafe: Int, rank: Int, cost: Int, tile: Int, improvement: Improvement)? {
                var best: (unsafe: Int, rank: Int, cost: Int, tile: Int, improvement: Improvement)?
                for w in work where !reserved.contains(w.tile) && f[w.tile] >= 0 {
                    let cost = Int(f[w.tile])
                    let unsafe = safe(w.tile, v, danger: danger) ? 0 : 1
                    if let b = best, (b.unsafe, b.rank, b.cost, b.tile) <= (unsafe, w.rank, cost, w.tile) { continue }
                    best = (unsafe, w.rank, cost, w.tile, w.improvement)
                }
                return best
            }
            var choice = pick(field(id, within: rules.points(ai.builderMaxMoveCost)))
            if choice == nil { choice = pick(field(id)) }
            guard let best = choice else {
                if roads == nil { roads = roadWork(v) }
                if !layRoad(unit, roads!, &reserved) { parkInNearestCity(unit) }
                continue
            }
            reserved.append(best.tile)
            if let here = v.index(of: unit.position), here == best.tile {
                guard unit.movesLeft > 0 else { continue }
                // Building uses every move, so it would end the phase here: only where safe.
                if safe(here, v, danger: danger) {
                    issue(.buildImprovement(unit: id, improvement: best.improvement))
                } else {
                    seekSafety(unit, danger)
                }
                continue
            }
            travel(id, to: v.coord(at: best.tile))
        }
    }

    /// M2 §3.3: a Builder with nothing to improve lays the nearest road tile within
    /// builderMaxMoveCost (safe tiles first), as for improvements. Returns whether it had one.
    mutating func layRoad(_ unit: Unit, _ roads: [Int], _ reserved: inout [Int]) -> Bool {
        guard !roads.isEmpty else { return false }
        let v = view
        let danger = civilianDanger(v)
        let f = field(unit.id, within: rules.points(ai.builderMaxMoveCost))
        var best: (unsafe: Int, cost: Int32, tile: Int)?
        for t in roads where !reserved.contains(t) && f[t] >= 0 {
            let key = (safe(t, v, danger: danger) ? 0 : 1, f[t], t)
            if let b = best, (b.unsafe, b.cost, b.tile) <= key { continue }
            best = key
        }
        guard let best else { return false }
        reserved.append(best.tile)
        if v.index(of: unit.position) == best.tile {
            guard unit.movesLeft > 0 else { return true }
            if safe(best.tile, v, danger: danger) { issue(.buildRoad(unit: unit.id)) } else { seekSafety(unit, danger) }
            return true
        }
        travel(unit.id, to: v.coord(at: best.tile))
        return true
    }

    // MARK: Civilian safety

    /// M1 §13 Safety: a Settler or Builder never ends a phase in the danger zone
    /// (`civilianDanger`: within civilianSafetyRadius of a visible foreign military unit, at war
    /// an enemy unit's next-phase reach) unless an own military unit shares its tile.
    func safe(_ t: Int, for unit: Unit, _ v: PlayerView) -> Bool {
        safe(t, v, danger: civilianDanger(v))
    }

    /// `safe(_:for:_:)` with the danger zone given (`civilianDanger`). An own city's tile is
    /// safe too (ai-3): no foreign unit may enter it without taking the city, and civilians
    /// inside are lost with the city anyway.
    func safe(_ t: Int, _ v: PlayerView, danger: [Bool]) -> Bool {
        if !danger[t] { return true }
        let hex = v.coord(at: t)
        if v.cities.contains(where: { $0.position == hex }) { return true }
        return v.units(at: hex).contains { $0.owner == player && isGuard($0.type) }
    }

    /// Per tile: where civilians keep clear of foreign military units (M1 §13 Safety). Within
    /// civilianSafetyRadius of every one visible now whose player is at peace with this one; for
    /// a visible unit of a player at war with this one, every tile it could move onto in its next
    /// phase instead (p3d `PlayerView.aiEnemyReach`: a Scout 3 tiles away captured a lone Settler
    /// in the iPhone play-test, which the flat radius had judged safe); plus (ai-3) within the
    /// radius of the non-recon ones remembered from sightings on tiles not visible now. Judged on
    /// visible units alone, a Settler between two foreign garrisons it sees in turn steps back and
    /// forth for ever (each step reveals one garrison and hides the other); the sighting keeps the
    /// hidden one in mind. Recon units roam too fast for an old sighting of one to mean anything.
    /// With `enemiesOnly`, only the units of players at war with this one count.
    func civilianDanger(_ v: PlayerView, enemiesOnly: Bool = false) -> [Bool] {
        var danger = v.aiEnemyReach()
        var tiles: [Int] = []
        if !enemiesOnly {
            for u in v.visibleForeignUnits where !u.type.isCivilian && !v.isAtWar(with: u.owner) {
                if let t = v.index(of: u.position) { tiles.append(t) }
            }
        }
        let visible = v.visible
        for s in v.sightings where !isRecon(s.type) && (!enemiesOnly || v.isAtWar(with: s.owner)) {
            guard let t = v.index(of: s.position), !visible[t] else { continue }
            tiles.append(t)
        }
        for t in tiles {
            for n in v.aiTiles(within: ai.civilianSafetyRadius, of: t) { danger[n] = true }
        }
        return danger
    }

    /// A civilian whose tile is unsafe and that will not move on this phase (it is where it
    /// wants to be): it steps to the cheapest safe tile it reaches (ties lower index); with
    /// none, it stays and asks for an escort. Returns whether it left.
    @discardableResult
    mutating func seekSafety(_ unit: Unit, _ danger: [Bool]) -> Bool {
        let v = view
        let f = reachField(unit.id)
        var best: (cost: Int32, tile: Int)?
        for t in reachableThisPhase(unit) where safe(t, v, danger: danger) {
            if let b = best, (b.cost, b.tile) <= (f[t], t) { continue }
            best = (f[t], t)
        }
        if let best, move(unit.id, to: v.coord(at: best.tile)) {
            holdGuard(of: unit.id)
            return true
        }
        waitForEscort(unit.id, toward: nil)
        return false
    }

    /// The own military unit travelling with a civilian: a non-recon military unit on its tile
    /// that is not a city's garrison, with moves left and free this phase.
    func hasEscort(_ unit: Unit, _ v: PlayerView) -> UnitID? {
        if v.cities.contains(where: { $0.position == unit.position }) { return nil }
        return v.units(at: unit.position).first { u in
            u.owner == player && isFighter(u.type) && u.movesLeft > 0 && !acted.contains(u.id)
        }?.id
    }

    /// Moves a civilian toward `goal` for this phase without breaking the safety rule: with an
    /// escort on its tile, the two travel together (p3b: even where it could go on alone, so a
    /// foreign Scout that follows it cannot part them); else along its path if the tile it would
    /// stop on is safe (an own military unit standing there makes it safe); else to the safe
    /// reachable tile nearest the goal if that is progress; else it stays (or steps to safety)
    /// and asks for an escort — except a Settler no escort could come to (p3b: no free fighter
    /// within escortMaxMoveCost and no escort city, `escortCanCome`) or join (ai-3: on an unsafe
    /// tile closed to the player's military), which goes on to where its path stops this phase
    /// (p3b: unless an enemy unit could reach it there, `civilianDanger` enemies only).
    mutating func travel(_ id: UnitID, to goal: HexCoord) {
        let v = view
        guard let unit = v.unit(id), unit.movesLeft > 0, !unit.zocStopped, unit.position != goal else { return }
        let danger = civilianDanger(v)
        let path = self.path(id, to: goal, v)
        if let escort = hasEscort(unit, v), let path, travelTogether(civilian: id, escort: escort, along: path) {
            return
        }
        if let path, let end = path.steps.last(where: { $0.turn <= 1 })?.hex,
           let e = v.index(of: end), safe(e, v, danger: danger) {
            if move(id, to: end) { holdGuard(of: id) }
            return
        }
        // Unsafe (or no path): the safe reachable tile nearest the goal.
        guard let here = v.index(of: unit.position) else { return }
        let toGoal = v.distanceField(from: goal)
        let options = reachableThisPhase(unit).filter { toGoal[$0] >= 0 && safe($0, v, danger: danger) }
        let f = field(id)
        let best = options.min { a, b in (toGoal[a], f[a], a) < (toGoal[b], f[b], b) }
        let hereSafe = safe(here, v, danger: danger)
        let progress = best.map { toGoal[here] < 0 || toGoal[$0] < toGoal[here] } ?? false
        // p3b: a Settler no escort could come to would wait for ever (one that went where closed
        // borders keep the player's military out, with a foreign Scout at its side): it goes on
        // alone, away from enemies, and asks for an escort where it stops if one could come.
        if !progress, rules.unit(unit.type).foundsCity, let path, let end = path.steps.last(where: { $0.turn <= 1 })?.hex,
           let e = v.index(of: end), !civilianDanger(v, enemiesOnly: true)[e],
           !escortCanCome(to: escortSpots(for: unit, toward: goal, v)), move(id, to: end) {
            holdGuard(of: id)
            if let after = view.unit(id), !safe(e, view, danger: civilianDanger(view)) {
                let spots = escortSpots(for: after, toward: goal, view)
                if escortCanCome(to: spots) { waitForEscort(id, at: spots) }
            }
            return
        }
        if let best, progress || !hereSafe {
            if move(id, to: v.coord(at: best)) { holdGuard(of: id) }
            if toGoal[here] >= 0, toGoal[best] >= toGoal[here] { waitForEscort(id, toward: goal) }
            return
        }
        // ai-3: a Settler on an unsafe tile where no escort could join it (`settlerStops`)
        // would wait for ever: it goes on to where its path stops this phase (where an escort
        // could join it, or a safe tile) and waits there.
        if !hereSafe, let stops = settlerStops(id, v), !stops[here], let path,
           let end = path.steps.last(where: { $0.turn <= 1 })?.hex, move(id, to: end) {
            holdGuard(of: id)
            waitForEscort(id, toward: goal)
            return
        }
        waitForEscort(id, toward: goal)
    }

    /// A civilian and its escort move together: the escort first, to the farthest tile of the
    /// civilian's path this phase that it reaches and may stand on, then the civilian onto it.
    /// Returns whether they moved.
    mutating func travelTogether(civilian id: UnitID, escort: UnitID, along path: Path) -> Bool {
        let v = view
        guard let guardUnit = v.unit(escort) else { return false }
        let f = field(escort)
        let steps = path.steps.filter { $0.turn <= 1 }
        for step in steps.reversed() {
            guard let t = v.index(of: step.hex), f[t] > 0, Int(f[t]) <= guardUnit.movesLeft else { continue }
            guard move(escort, to: step.hex), view.unit(escort)?.position == step.hex else { continue }
            acted.insert(escort)
            move(id, to: step.hex)
            return true
        }
        return false
    }

    // MARK: Exploring

    /// M1 §13 Exploring: Scouts (id order) go to the frontier tile with the lowest movement
    /// cost (ties lower index), reserving targets within scoutTargetSpacing of each other.
    /// While a met rival has no remembered city, one Scout explores toward its remembered
    /// territory or latest sighting. With no frontier left: Scouts are disbanded while upkeep
    /// is paid, otherwise they sleep next to the own city nearest the rival. With no Scout,
    /// early on, a non-garrison melee unit explores in its place. p3g (M1 §7.7): a known tribal
    /// village within `tribalVillages.seekTurns` turns' moves comes first, before the rival hunt
    /// and the frontier, and an explorer with no frontier left or no target goes to any known
    /// tribal village it can reach (at war, only ending phases out of enemy reach) before it
    /// retires (`seekTribalVillage`); with `seekTurns` 0 or none known, all is as before.
    mutating func explore() {
        guard live else { return }
        var v = view
        var explorers = v.units.filter { isRecon($0.type) && !acted.contains($0.id) }.map(\.id)
        if explorers.isEmpty, v.turn <= ai.earlyTurns, plan.enemies.isEmpty,
           let warrior = forces(v).army.first(where: { isLine($0.type) && !acted.contains($0.id) }) {
            explorers = [warrior.id]
        }
        guard !explorers.isEmpty else { return }
        let frontier = v.aiFrontier()
        var reserved: [Int] = []
        var hunter = unlocatedRival(v)
        for id in explorers {
            v = view
            guard live, let unit = v.unit(id) else { continue }
            acted.insert(id)
            guard !frontier.isEmpty else {
                if !seekTribalVillage(unit, anyDistance: true, reserved: &reserved) { retire(unit) }
                continue
            }
            // (The hunt needs the whole field anyway; else the frontier's cut-off one serves.)
            if seekTribalVillage(unit, anyDistance: false, reserved: &reserved, wholeField: hunter != nil) { continue }
            func goals(_ f: [Int32]) -> [Int] {
                frontier.filter { g in f[g] > 0 && !reserved.contains(where: { r in v.aiDistance(r, g) <= ai.scoutTargetSpacing }) }
            }
            var target: Int?
            if let rival = hunter, case let f = field(id), let near = huntGoal(rival, among: goals(f), f, v) {
                target = near
                hunter = nil
            } else {
                // The cheapest frontier tile: when one lies within a few turns' moves, a field
                // cut off there finds the same tile as a whole one, for much less.
                let horizon = 3 * rules.unit(unit.type).moves * rules.movePoints
                let near = field(id, within: horizon)
                target = goals(near).filter { near[$0] <= horizon }.min { (near[$0], $0) < (near[$1], $1) }
                if target == nil {
                    let f = field(id)
                    target = goals(f).min { (f[$0], $0) < (f[$1], $1) }
                }
            }
            guard let target else {
                if !seekTribalVillage(unit, anyDistance: true, reserved: &reserved) { retire(unit) }
                continue
            }
            reserved.append(target)
            hop(id, toward: v.coord(at: target))
        }
    }

    /// p3g (M1 §7.7, §13 Exploring): explorer `unit` heads for the known tribal village with the
    /// lowest movement cost that it can reach and stop on (ties: lower index) and no explorer
    /// reserved this phase: within the rules' `seekTurns` turns' moves (the first choice), or
    /// with `anyDistance` at any distance by its whole field (before it retires; at war with an
    /// enemy's reach about, by the field that ends phases only out of that reach). The tile is
    /// reserved like a frontier target, and the unit walks toward it. Returns whether one was
    /// chosen. Nothing happens while `seekTurns` is 0 (or the rules have no such section) or the
    /// player knows none: the AI reads them only from its memory (`knownTribalVillages`).
    /// `wholeField`: measure by the unit's whole field even within the horizon (one the rival
    /// hunt computes anyway).
    mutating func seekTribalVillage(_ unit: Unit, anyDistance: Bool, reserved: inout [Int], wholeField: Bool = false) -> Bool {
        let seek = rules.tribalVillages?.seekTurns ?? 0
        guard seek > 0 else { return false }
        let v = view
        let known = v.knownTribalVillages
        guard !known.isEmpty, let here = v.index(of: unit.position) else { return false }
        let moves = rules.unit(unit.type).moves * rules.movePoints
        let limit: Int? = anyDistance ? nil : seek * moves
        // A step costs at least a move point: one more than `limit` tiles away is beyond it,
        // and with none nearer no field is needed.
        let candidates = known.map(Int.init).filter { t in
            !reserved.contains(t) && limit.map { v.aiDistance(here, t) <= $0 } ?? true
        }
        guard !candidates.isEmpty else { return false }
        // p3g review: at war, one at any distance (those left late often lie toward the enemy)
        // is sought only through the safe field, as the Explore order seeks it: the unit ends its
        // phases only where no enemy it sees could strike it and out of remembered enemy cities'
        // bombard range (`PlayerView.exploreThreats`). With none reached that way, it retires.
        var stops: [Bool]?
        if anyDistance, !plan.enemies.isEmpty {
            let threats = v.exploreThreats(for: unit)
            if threats.contains(where: { $0 != nil }) { stops = threats.map { $0 == nil } }
        }
        // The frontier search's cut-off field (3 turns' moves), wider only for a longer horizon,
        // so that search reuses it.
        let f = stops.map { v.aiMovementField(for: unit.id, mayStop: $0) }
            ?? (limit == nil || wholeField ? field(unit.id) : field(unit.id, within: max(3, seek) * moves))
        var best: (cost: Int32, tile: Int)?
        for t in candidates where f[t] > 0 && limit.map({ Int(f[t]) <= $0 }) ?? true {
            // In tile order: a tie keeps the lower index.
            if let best, best.cost <= f[t] { continue }
            best = (f[t], t)
        }
        guard let best else { return false }
        reserved.append(best.tile)
        note("\(unit.type.displayName) \(unit.id) heads for the tribal village at \(v.coord(at: best.tile)) (cost \(best.cost))")
        let goal = v.coord(at: best.tile)
        if let stops {
            // Where its safe way ends this phase (none: it waits where it stands).
            if let end = v.aiPath(for: unit.id, to: goal, mayStop: stops)?.steps.last(where: { $0.turn <= 1 })?.hex {
                move(unit.id, to: end)
            }
        } else {
            hop(unit.id, toward: goal)
        }
        return true
    }

    /// The frontier tile to explore toward a rival none of whose cities is known: nearest to
    /// its remembered territory or, without any, its latest sighting (ties: lower cost, then
    /// lower index).
    func huntGoal(_ rival: PlayerID, among goals: [Int], _ f: [Int32], _ v: PlayerView) -> Int? {
        let code = UInt8(rival.rawValue + 1)
        var anchors: [Int] = []
        let territory = v.knownTerritory
        for t in 0..<territory.count where territory[t] == code { anchors.append(t) }
        if anchors.isEmpty, let seen = v.sightings(of: rival).max(by: { ($0.turnSeen, -$0.id.rawValue) < ($1.turnSeen, -$1.id.rawValue) }),
           let t = v.index(of: seen.position) {
            anchors = [t]
        }
        guard !anchors.isEmpty else { return nil }
        var best: (distance: Int, cost: Int32, tile: Int)?
        for g in goals {
            var d = Int.max
            for a in anchors { d = min(d, v.aiDistance(a, g)) }
            if let b = best, (b.distance, b.cost, b.tile) <= (d, f[g], g) { continue }
            best = (d, f[g], g)
        }
        return best?.tile
    }

    /// A Scout with nothing left to explore: disbanded while upkeep is paid, otherwise asleep
    /// next to the own city nearest the rival (not on it: the city's tile is its garrison's).
    mutating func retire(_ unit: Unit) {
        let v = view
        if isRecon(unit.type), v.income().upkeep > 0 {
            note("disbands \(unit.type.displayName) \(unit.id): nothing left to explore and upkeep is paid")
            issue(.disband(unit: unit.id))
            return
        }
        guard let city = cityNearestRival(v), let c = v.index(of: city.position) else {
            sleep(unit)
            return
        }
        guard let here = v.index(of: unit.position) else { return }
        if v.aiDistance(here, c) == 1, v.knownTerritory[here] == UInt8(player.rawValue + 1) {
            sleep(unit)
            return
        }
        let f = field(unit.id)
        let spots = v.aiNeighbors(of: c).filter { f[$0] >= 0 && v.knownTerritory[$0] == UInt8(player.rawValue + 1) }
            .sorted { (f[$0], $0) < (f[$1], $1) }
        if let spot = spots.first {
            hop(unit.id, toward: v.coord(at: spot))
            if let after = view.unit(unit.id), after.position == v.coord(at: spot) { sleep(after) }
        } else {
            sleep(unit)
        }
    }

    /// The own city nearest a rival's remembered city (else its remembered territory); the
    /// capital when no rival is known.
    func cityNearestRival(_ v: PlayerView) -> City? {
        let cities = v.cities
        guard !cities.isEmpty else { return nil }
        var anchors = v.knownCities.filter { $0.owner != player }.compactMap { v.index(of: $0.position) }
        if anchors.isEmpty {
            let territory = v.knownTerritory
            let mine = UInt8(player.rawValue + 1)
            for t in 0..<territory.count where territory[t] != 0 && territory[t] != mine { anchors.append(t) }
        }
        guard !anchors.isEmpty else { return v.me.capital.flatMap { v.city($0) } ?? cities[0] }
        var best: (distance: Int, city: City)?
        for city in cities {
            guard let c = v.index(of: city.position) else { continue }
            var d = Int.max
            for a in anchors { d = min(d, v.aiDistance(a, c)) }
            if let b = best, b.distance <= d { continue }
            best = (d, city)
        }
        return best?.city
    }
}
