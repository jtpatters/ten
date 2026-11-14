import GameCore

// Military (M1 §13 Tactics, in order, then the rest): 1. capture 0-HP enemy cities; 2. cities
// bombard, then ranged units fire; 3. melee attacks; 4. the wounded retreat and heal; 5. cities
// under attack buy a defender, sortie and recall the army; 6. capture unescorted enemy
// civilians. Otherwise garrisons hold and fortify, escorts join waiting civilians, guards stand
// by threatened cities, and the army gathers at the rally city or marches on the target.
// Attacks are chosen only from previews (M1 §8.4).
//
// The march on the target (ai-2): the army first stages out of the target's bombard range
// (siegeStageRadius), then assaults together once enough of it stands there (`Plan.assault`):
// ranged units close to range 2 and fire, melee units wait within 2 of the city and close in
// next to it (flanking) once it is being hit, then attack when tactic 3 allows. Until the
// assault no unit steps onto a tile an enemy city can bombard to attack unless it kills, and a
// wounded unit (below retreatHP) only takes kills, so the army does not trickle into the city's
// guns one unit at a time. Ranged units fire from the safest tile in range they reach; melee
// units attack from the tile with the best preview (no river crossing).

extension AITurn {
    // MARK: Attacks

    /// Attacks with a unit from `from` (default: the option's `from` tile), moving there first
    /// if needed. The unit is done for the phase once it attacks or has no moves left; one whose
    /// move or attack failed with moves left stays free for the later tactics and orders (p3d
    /// ai-idle-tactics: a ranged unit whose firing tile another unit took meanwhile stood idle
    /// all phase, with all its moves).
    @discardableResult
    mutating func attack(_ id: UnitID, _ option: AttackOption, from spot: HexCoord? = nil) -> Bool {
        guard let unit = view.unit(id) else {
            acted.insert(id)
            return false
        }
        let from = spot ?? option.from
        if from != unit.position {
            guard move(id, to: from), let moved = view.unit(id), moved.position == from, moved.movesLeft > 0 else {
                if (view.unit(id)?.movesLeft ?? 0) == 0 { acted.insert(id) }
                return false
            }
        }
        forgetFields(id)
        let hit = issue(.attack(unit: id, target: option.target))
        if hit || (view.unit(id)?.movesLeft ?? 0) == 0 { acted.insert(id) }
        if hit, case let .city(city) = option.defender { cityHits[city, default: 0] += 1 }
        return hit
    }

    // MARK: Where to fight from

    /// Tiles (indices) of enemy cities the player knows (at war).
    mutating func enemyCityTiles() -> [Int] {
        if let cached = enemyCitiesCache { return cached }
        let v = view
        let tiles = v.knownCities.filter { v.isAtWar(with: $0.owner) }.compactMap { v.index(of: $0.position) }
        enemyCitiesCache = tiles
        return tiles
    }

    /// Whether an enemy city can bombard tile `t` (M1 §5: range bombardRange).
    mutating func exposed(_ t: Int) -> Bool {
        let v = view
        let range = rules.constants.city.bombardRange
        return enemyCityTiles().contains { v.aiDistance($0, t) <= range }
    }

    /// Tiles (indices) of visible enemy military units able to attack in melee (not ranged).
    func enemyMeleeTiles(_ v: PlayerView) -> [Int] {
        v.visibleForeignUnits.compactMap { u in
            guard !u.type.isCivilian, !isRanged(u.type), v.isAtWar(with: u.owner) else { return nil }
            return v.index(of: u.position)
        }
    }

    /// Tiles a unit may attack `target` from this phase (keeping a move for the attack), its
    /// own tile first when in reach: within range for a ranged unit, adjacent for a melee unit.
    /// A garrison, or a unit that may not fire after moving, attacks only from where it is.
    mutating func attackSpots(_ unit: Unit, target t: Int, garrison: Bool) -> [Int] {
        let v = view
        guard let here = v.index(of: unit.position) else { return [] }
        let reach = isRanged(unit.type) ? v.range(of: unit) : 1
        var spots: [Int] = []
        let d = v.aiDistance(here, t)
        if d <= reach, isRanged(unit.type) || d == 1 { spots.append(here) }
        guard !garrison, !unit.zocStopped, unit.movesLeft > 1, v.firesAfterMoving(unit) else { return spots }
        let f = reachField(unit.id)
        for r in v.aiTiles(within: reach, of: t) where r != here && r != t && f[r] > 0 && Int(f[r]) <= unit.movesLeft - 1 {
            if !isRanged(unit.type), v.aiDistance(r, t) != 1 { continue }
            spots.append(r)
        }
        return spots
    }

    /// The safest of `spots` for a ranged unit to shoot from: not next to an enemy melee unit,
    /// out of enemy cities' bombard range, least danger, cheapest, lowest index.
    mutating func safestSpot(_ unit: Unit, _ spots: [Int]) -> Int? {
        let v = view
        let melee = enemyMeleeTiles(v)
        let d = danger()
        let f = reachField(unit.id)
        let here = v.index(of: unit.position)
        var best: (adjacent: Int, exposed: Int, danger: Int32, cost: Int32, tile: Int)?
        for r in spots {
            let key = (melee.contains { v.aiDistance($0, r) == 1 } ? 1 : 0, exposed(r) ? 1 : 0, d[r], r == here ? 0 : f[r], r)
            if let b = best, (b.adjacent, b.exposed, b.danger, b.cost, b.tile) <= key { continue }
            best = key
        }
        return best?.tile
    }

    /// HP left on a defender as the player sees it (a city's wall HP included).
    func defenderHP(_ defender: Combatant, at target: HexCoord, _ v: PlayerView) -> Int {
        switch defender {
        case let .unit(id): v.unit(id)?.hp ?? 0
        case .city: v.knownCity(at: target).map { $0.hp + $0.wallHP } ?? 0
        }
    }

    /// Tactic 1: a melee or antiCavalry unit that can reach a 0-HP enemy city captures it
    /// (the cheapest move, then the lower id); then the captured city is kept or razed.
    mutating func captureCities() {
        // Units whose attack failed this time (they stay free for the other tactics, p3d).
        var failed: [UnitID] = []
        for _ in 0..<8 {
            let v = view
            guard live else { return }
            let open = v.knownCities.filter { $0.hp == 0 && v.isAtWar(with: $0.owner) && v.isVisible($0.position) }
            var captured = false
            for city in open {
                var best: (cost: Int, unit: UnitID, option: AttackOption)?
                for u in v.units where isLine(u.type) && u.movesLeft > 0 && !acted.contains(u.id) && !failed.contains(u.id) {
                    guard let option = v.attackOptions(for: u.id).first(where: { $0.target == city.position }),
                          v.combatPreview(attacker: .unit(u.id), target: option.target, from: option.from)?.capturesCity == true else { continue }
                    if let b = best, (b.cost, b.unit) <= (option.moveCost, u.id) { continue }
                    best = (option.moveCost, u.id, option)
                }
                guard let best else { continue }
                if attack(best.unit, best.option) {
                    if view.city(city.id) != nil { keepOrRaze(city.id) }
                } else {
                    failed.append(best.unit)
                }
                captured = true
                break
            }
            if !captured { return }
        }
    }

    /// M1 §13 Captured cities: keep; raze only population-1 non-capitals at least
    /// razeMinDistance tiles from every own city.
    mutating func keepOrRaze(_ id: CityID) {
        let v = view
        guard let city = v.city(id), v.canRaze(id), city.population <= ai.razeMaxPopulation else { return }
        if v.cities.allSatisfy({ $0.id == id || v.distance($0.position, city.position) >= ai.razeMinDistance }) {
            note("razes \(city.name) (population \(city.population), ≥ \(ai.razeMinDistance) tiles from its other cities)")
            issue(.razeCity(city: id))
        }
    }

    /// Tactic 2: cities bombard, then ranged units fire (id order): kills first, else — when
    /// at least two ranged units can hit the target city — that city, else the target left
    /// with the lowest HP. A city at 0 HP draws at most one shot a phase (enough to stop its
    /// healing). Each hit may open a city to capture (tactic 1). A unit shoots from the safest
    /// tile in range it reaches; a garrison only from its city; outside an assault no unit moves
    /// into an enemy city's bombard range to shoot unless it kills.
    mutating func bombardAndShoot() {
        for id in view.cities.map(\.id) {
            let v = view
            guard live else { return }
            let options = v.cityAttackOptions(for: id).map { (option: $0, from: v.index(of: $0.from) ?? 0) }
            guard let pick = rangedPick(.city(id), options, focus: nil, v) else { continue }
            if issue(.cityAttack(city: id, target: pick.option.target)), case let .city(c) = pick.option.defender {
                cityHits[c, default: 0] += 1
                captureCities()
            }
        }
        let garrisons = forces(view).garrisonIDs
        let shooters = view.units.filter { isRanged($0.type) && $0.movesLeft > 0 && !acted.contains($0.id) }.map(\.id)
        let focus = focusCity(shooters)
        for id in shooters {
            let v = view
            guard live, let unit = v.unit(id), unit.movesLeft > 0, !acted.contains(id) else { continue }
            var options: [(option: AttackOption, from: Int)] = []
            for option in v.attackOptions(for: id) {
                guard let t = v.index(of: option.target),
                      let spot = safestSpot(unit, attackSpots(unit, target: t, garrison: garrisons.contains(id))) else { continue }
                options.append((option, spot))
            }
            guard let pick = rangedPick(.unit(id), options, focus: focus, v) else { continue }
            if attack(id, pick.option, from: v.coord(at: pick.from)), case .city = pick.option.defender { captureCities() }
        }
    }

    /// The enemy city at least `cityAttackFocusHits` of these ranged units can hit this phase:
    /// the war target if so, else the one most of them can hit (ties: lower id).
    func focusCity(_ shooters: [UnitID]) -> CityID? {
        let v = view
        var counts: [(city: CityID, n: Int)] = []
        for id in shooters {
            for option in v.attackOptions(for: id) {
                guard case let .city(c) = option.defender else { continue }
                if let i = counts.firstIndex(where: { $0.city == c }) { counts[i].n += 1 } else { counts.append((c, 1)) }
            }
        }
        let enough = counts.filter { $0.n >= ai.cityAttackFocusHits }
        if let target = plan.target, enough.contains(where: { $0.city == target.id }) { return target.id }
        return enough.min { ($1.n, $0.city) < ($0.n, $1.city) }?.city
    }

    /// The ranged target to take (tactic 2), from previews only. Outside an assault, a shot
    /// that needs a tile an enemy city can bombard is taken only if it kills.
    mutating func rangedPick(_ attacker: Combatant, _ options: [(option: AttackOption, from: Int)], focus: CityID?,
                             _ v: PlayerView) -> (option: AttackOption, from: Int)? {
        var kill: (pairs: Int, left: Int, tile: Int, pick: (option: AttackOption, from: Int))?
        var low: (left: Int, tile: Int, pick: (option: AttackOption, from: Int))?
        var focused: (option: AttackOption, from: Int)?
        let here: Int?
        if case let .unit(id) = attacker { here = v.unit(id).flatMap { v.index(of: $0.position) } } else { here = nil }
        for pick in options {
            let option = pick.option
            let hp = defenderHP(option.defender, at: option.target, v)
            if case let .city(c) = option.defender, hp == 0, cityHits[c, default: 0] > 0 { continue }
            guard let p = v.combatPreview(attacker: attacker, target: option.target, from: option.from) else { continue }
            let left = max(0, hp - p.meanDealt)
            let tile = v.index(of: option.target) ?? 0
            let kills = hp > 0 && p.killChance(atLeast: ai.attackKillChancePct)
            if kills {
                if kill == nil || (p.killPairs, -left, -tile) > (kill!.pairs, -kill!.left, -kill!.tile) {
                    kill = (p.killPairs, left, tile, pick)
                }
            }
            // Outside an assault, only kills justify stepping into an enemy city's guns; a
            // wounded unit (below retreatHP) outside an assault only takes kills, then retreats
            // (tactic 4).
            if !plan.assault, here != nil, pick.from != here, exposed(pick.from) { continue }
            if !plan.assault, case let .unit(id) = attacker, let u = v.unit(id), u.hp < ai.retreatHP { continue }
            if case let .city(c) = option.defender, c == focus, hp > 0 { focused = pick }
            if low == nil || (left, tile) < (low!.left, low!.tile) { low = (left, tile, pick) }
        }
        return kill?.pick ?? focused ?? low?.pick
    }

    /// Tactic 3: melee and antiCavalry units (garrisons aside: they only sortie; Scouts do
    /// not fight) attack a unit when the expected damage dealt beats the damage taken or the
    /// kill chance is at least attackKillChancePct; a city when their worst damage taken stays
    /// below their HP − cityAttackHPMargin and the city has at most cityAttackMaxCityHP (HP and
    /// wall HP) left or was hit cityAttackFocusHits times this phase. Captures first, then
    /// kills, then the best trade. Each attack comes from the reachable tile next to the target
    /// with the best preview (then the safest); outside an assault, from a tile an enemy city
    /// can bombard only to kill or capture.
    mutating func meleeAttacks() {
        let garrisons = forces(view).garrisonIDs
        let ids = view.units.filter { u in
            isLine(u.type) && u.movesLeft > 0 && !acted.contains(u.id) && !garrisons.contains(u.id)
        }.map(\.id)
        for id in ids {
            let v = view
            guard live, let unit = v.unit(id), unit.movesLeft > 0, !acted.contains(id) else { continue }
            let here = v.index(of: unit.position)
            var best: (rank: Int, kills: Int, net: Int, safe: Int, tile: Int, option: AttackOption, from: Int)?
            for option in v.attackOptions(for: id) {
                guard let t = v.index(of: option.target) else { continue }
                for spot in attackSpots(unit, target: t, garrison: false) {
                    let from = v.coord(at: spot)
                    guard let p = v.combatPreview(attacker: .unit(id), target: option.target, from: from) else { continue }
                    let rank: Int
                    switch option.defender {
                    case let .city(c):
                        if p.capturesCity {
                            rank = 3
                        } else {
                            let left = defenderHP(option.defender, at: option.target, v)
                            guard p.damageTaken.upperBound < unit.hp - ai.cityAttackHPMargin,
                                  left <= ai.cityAttackMaxCityHP || cityHits[c, default: 0] >= ai.cityAttackFocusHits else { continue }
                            rank = 1
                        }
                    case .unit:
                        let kills = p.killChance(atLeast: ai.attackKillChancePct)
                        guard kills || p.meanDealt > p.meanTaken else { continue }
                        rank = kills ? 2 : 1
                    }
                    let exposedSpot = spot != here && exposed(spot)
                    if !plan.assault, exposedSpot, rank == 1 { continue }
                    if unit.hp < ai.retreatHP, rank == 1 { continue }
                    let safe = exposedSpot ? 1 : 0
                    let key = (rank, p.killPairs, p.meanDealt - p.meanTaken, -safe, -t)
                    if let b = best, (b.rank, b.kills, b.net, -b.safe, -b.tile) >= key { continue }
                    best = (rank, p.killPairs, p.meanDealt - p.meanTaken, safe, t, option, spot)
                }
            }
            guard let best else { continue }
            let captures = best.rank == 3
            if attack(id, best.option, from: v.coord(at: best.from)) {
                if captures, case let .city(c) = best.option.defender, view.city(c) != nil { keepOrRaze(c) }
                captureCities()
            }
        }
    }

    // MARK: Healing

    /// Tactic 4 (at war and at peace): units below retreatHP go to the nearest own city whose
    /// tile is free, else the nearest own tile out of danger and not next to a visible enemy,
    /// and fortify there; units fortified (healing) below rejoinHP stay put unless an enemy can
    /// reach them there. Garrisons heal where they are.
    mutating func retreatWounded() {
        guard live else { return }
        let start = view
        let garrisons = forces(start).garrisonIDs
        let ids = start.units.filter { u in
            !u.type.isCivilian && u.hp < ai.rejoinHP && !acted.contains(u.id) && !garrisons.contains(u.id)
        }.map(\.id)
        guard !ids.isEmpty else { return }
        let mine = UInt8(player.rawValue + 1)
        let d = danger()
        for id in ids {
            let v = view
            guard live, let unit = v.unit(id), let here = v.index(of: unit.position) else { continue }
            if unit.hp >= ai.retreatHP {
                // Healing: stays fortified while nothing can reach it.
                if unit.activity == .fortified || unit.activity == .fortifying, d[here] == 0 { acted.insert(id) }
                if d[here] == 0 || unit.activity != .fortified && unit.activity != .fortifying { continue }
            }
            acted.insert(id)
            let enemies = foreignMilitaryTiles(v, enemiesOnly: true, includeRecon: true)
            func restful(_ t: Int) -> Bool {
                v.knownTerritory[t] == mine && d[t] == 0 && !enemies.contains { v.aiDistance($0, t) <= 1 }
            }
            if restful(here) {
                fortify(unit)
                continue
            }
            let f = field(id)
            var city: (cost: Int, tile: Int)?
            for c in v.cities {
                guard let t = v.index(of: c.position), f[t] > 0 else { continue }
                if let b = city, (b.cost, b.tile) <= (Int(f[t]), t) { continue }
                city = (Int(f[t]), t)
            }
            var goal = city?.tile
            // A city reached this phase is best; else an own tile out of danger this phase
            // when there is one; else keep heading for the city.
            if city == nil || Int(city!.cost) > unit.movesLeft {
                var spot: (cost: Int32, tile: Int)?
                for t in reachableThisPhase(unit) where restful(t) {
                    if let s = spot, (s.cost, s.tile) <= (f[t], t) { continue }
                    spot = (f[t], t)
                }
                if let spot { goal = spot.tile }
            }
            if goal == nil {
                var spot: (danger: Int32, cost: Int32, tile: Int)?
                for t in 0..<v.tileCount where f[t] > 0 && v.knownTerritory[t] == mine && !enemies.contains(where: { v.aiDistance($0, t) <= 1 }) {
                    if let s = spot, (s.danger, s.cost, s.tile) <= (d[t], f[t], t) { continue }
                    spot = (d[t], f[t], t)
                }
                goal = spot?.tile
            }
            guard let goal else {
                fortify(unit)
                continue
            }
            hop(id, toward: v.coord(at: goal))
            if let after = view.unit(id), after.position == v.coord(at: goal) || after.movesLeft > 0 { fortify(after) }
        }
    }

    // MARK: Cities under attack

    /// Tactic 5: an own city with at most defendCityHP HP and a visible enemy next to it buys
    /// its best defender if affordable (an emergency: the upkeep rule does not apply) and
    /// recalls army units within defendRecallRadius. Every garrison next to an enemy attacks
    /// out only with a kill chance of at least sortieKillChancePct.
    mutating func defendCities() {
        for id in view.cities.map(\.id) {
            let v = view
            guard live, let city = v.city(id), let c = v.index(of: city.position) else { continue }
            let enemies = foreignMilitaryTiles(v, enemiesOnly: true, includeRecon: true)
            guard enemies.contains(where: { v.aiDistance($0, c) == 1 }) else { continue }
            sortie(from: city)
            guard city.hp <= ai.defendCityHP else { continue }
            if let defender = bestDefender(view) {
                let item = ProductionItem.unit(defender)
                let price = rules.cost(of: item) * rules.constants.production.purchaseCostMultiplier
                if view.me.gold >= price, view.aiCompletionProblem(item, in: id) == nil, issue(.purchase(city: id, item: item)) {
                    note("buys \(defender.displayName) in besieged \(city.name) (\(city.hp) HP) for \(price) gold")
                }
            }
            let army = forces(view).army.filter { !acted.contains($0.id) && view.distance($0.position, city.position) <= ai.defendRecallRadius }
            for unit in army {
                acted.insert(unit.id)
                standBy(unit.id, city: city)
            }
        }
    }

    /// A garrison attacks out of its city only with a good kill chance (M1 §13 tactic 5).
    mutating func sortie(from city: City) {
        let v = view
        guard let garrison = v.units(at: city.position).first(where: { $0.owner == player && !$0.type.isCivilian }),
              garrison.movesLeft > 0, !acted.contains(garrison.id) else { return }
        var best: (pairs: Int, tile: Int, option: AttackOption)?
        for option in v.attackOptions(for: garrison.id) where option.from == city.position {
            guard case .unit = option.defender,
                  let p = v.combatPreview(attacker: .unit(garrison.id), target: option.target, from: option.from),
                  p.killChance(atLeast: ai.sortieKillChancePct) else { continue }
            let tile = v.index(of: option.target) ?? 0
            if let b = best, (b.pairs, -b.tile) >= (p.killPairs, -tile) { continue }
            best = (p.killPairs, tile, option)
        }
        if let best { attack(garrison.id, best.option) }
    }

    /// Moves a unit next to a city (the cheapest free neighbour, ties lower index), or toward it.
    /// p3d (ai-idle-tactics): with no neighbour of the city free, a unit within 2 of the city
    /// fortifies where it stands, and one farther away goes to the cheapest free own tile within
    /// 2 of it (ties lower index); a unit that cannot move there fortifies where it stands. Before,
    /// such units stood idle with all their moves while their city was besieged.
    mutating func standBy(_ id: UnitID, city: City) {
        let v = view
        guard let unit = v.unit(id), let c = v.index(of: city.position), let here = v.index(of: unit.position) else { return }
        if v.aiDistance(here, c) <= 1 {
            fortify(unit)
            return
        }
        let f = field(id)
        var spots = v.aiNeighbors(of: c).filter { f[$0] > 0 }.sorted { (f[$0], $0) < (f[$1], $1) }
        if spots.isEmpty {
            if v.aiDistance(here, c) <= 2 {
                fortify(unit)
                return
            }
            let mine = UInt8(player.rawValue + 1)
            let territory = v.knownTerritory
            spots = v.aiTiles(within: 2, of: c).filter { f[$0] > 0 && territory[$0] == mine }.sorted { (f[$0], $0) < (f[$1], $1) }
        }
        guard let spot = spots.first else {
            fortify(unit)
            return
        }
        if Int(f[spot]) <= unit.movesLeft {
            if moveToFirst(id, of: spots) != nil, let after = view.unit(id) { fortify(after) } else { fortify(unit) }
        } else if !hop(id, toward: v.coord(at: spot)) {
            fortify(unit)
        }
    }

    // MARK: Civilians

    /// Tactic 6: at war, a military unit (not a garrison) that reaches an unescorted enemy
    /// civilian this phase captures it, unless the civilian has more than
    /// civilianCaptureMaxAdjacentEnemies visible enemies next to it. The cheapest move, then the
    /// lower id.
    mutating func captureCivilians() {
        let v = view
        let enemies = foreignMilitaryTiles(v, enemiesOnly: true, includeRecon: true)
        var targets: [Int] = []
        for u in v.visibleForeignUnits where u.type.isCivilian && v.isAtWar(with: u.owner) {
            guard let t = v.index(of: u.position), !enemies.contains(t), !targets.contains(t) else { continue }
            guard enemies.filter({ v.aiDistance($0, t) == 1 }).count <= ai.civilianCaptureMaxAdjacentEnemies else { continue }
            targets.append(t)
        }
        guard !targets.isEmpty else { return }
        let garrisons = forces(v).garrisonIDs
        for t in targets.sorted() {
            guard live else { return }
            var best: (cost: Int, unit: UnitID)?
            for u in view.units where !u.type.isCivilian && u.movesLeft > 0 && !u.zocStopped && !acted.contains(u.id)
                && !garrisons.contains(u.id) {
                let f = reachField(u.id)
                guard f[t] > 0, Int(f[t]) <= u.movesLeft else { continue }
                if let b = best, (b.cost, b.unit) <= (Int(f[t]), u.id) { continue }
                best = (Int(f[t]), u.id)
            }
            guard let best else { continue }
            acted.insert(best.unit)
            move(best.unit, to: view.coord(at: t))
        }
    }

    // MARK: Everything else

    /// M1 §13 "Otherwise army units move toward the rally city or target; garrisons fortify",
    /// with the defence quota's garrisons and guards and the escorts civilians asked for.
    mutating func moveMilitary() {
        guard live else { return }
        timed("  sendGarrisons") { $0.sendGarrisons() }
        timed("  escortCivilians") { $0.escortCivilians() }
        timed("  guardThreatened") { $0.guardThreatenedCities() }
        timed("  moveArmy") { $0.moveArmy() }
        timed("  fortifyGarrisons") { $0.fortifyGarrisons() }
    }

    /// Fighters free to take a duty: not garrisons, not done this phase, able to move.
    func freeFighters(_ v: PlayerView) -> [Unit] {
        let garrisons = forces(v).garrisonIDs
        return v.units.filter { u in
            isFighter(u.type) && u.movesLeft > 0 && !u.zocStopped && !acted.contains(u.id) && !garrisons.contains(u.id)
        }
    }

    /// Cities without a non-recon military unit on their tile (threatened ones first, then by
    /// id) get the nearest free fighter within garrisonMaxMoveCost.
    mutating func sendGarrisons() {
        let order = view.cities.sorted { a, b in
            (plan.isThreatened(a.id) ? 0 : 1, a.id) < (plan.isThreatened(b.id) ? 0 : 1, b.id)
        }
        for city in order {
            let v = view
            guard live, let c = v.index(of: city.position) else { continue }
            if v.units(at: city.position).contains(where: { $0.owner == player && !$0.type.isCivilian }) { continue }
            var best: (cost: Int32, unit: UnitID)?
            for u in freeFighters(v) {
                let f = field(u.id, within: rules.points(ai.garrisonMaxMoveCost))
                guard f[c] > 0, Int(f[c]) <= rules.points(ai.garrisonMaxMoveCost) else { continue }
                if let b = best, (b.cost, b.unit) <= (f[c], u.id) { continue }
                best = (f[c], u.id)
            }
            guard let best else { continue }
            acted.insert(best.unit)
            garrisonSent[city.id] = best.unit
            hop(best.unit, toward: city.position)
            if let after = view.unit(best.unit), after.position == city.position { fortify(after) }
        }
    }

    /// Threatened cities keep threatenedDefenders fighters on or next to their tile: those
    /// already there stay and fortify; the nearest free ones within garrisonMaxMoveCost come.
    mutating func guardThreatenedCities() {
        for id in plan.threatened {
            let v = view
            guard live, let city = v.city(id), let c = v.index(of: city.position) else { continue }
            var near = 0
            for u in v.units where isFighter(u.type) && v.distance(u.position, city.position) <= 1 {
                near += 1
                if u.position != city.position, !acted.contains(u.id) {
                    acted.insert(u.id)
                    fortify(u)
                }
            }
            while near < ai.threatenedDefenders, live {
                let v = view
                var best: (cost: Int32, unit: UnitID)?
                for u in freeFighters(v) {
                    let f = field(u.id, within: rules.points(ai.garrisonMaxMoveCost))
                    let cost = v.aiNeighbors(of: c).compactMap { f[$0] > 0 ? f[$0] : nil }.min() ?? -1
                    guard cost > 0, Int(cost) <= rules.points(ai.garrisonMaxMoveCost) else { continue }
                    if let b = best, (b.cost, b.unit) <= (cost, u.id) { continue }
                    best = (cost, u.id)
                }
                guard let best else { break }
                acted.insert(best.unit)
                standBy(best.unit, city: city)
                near += 1
            }
        }
    }

    /// The army: at war and advancing, on the target — staging out of its bombard range until
    /// the assault, then ranged units within range and melee units next to it; in prepare, or
    /// at war while gathering, to within rallyRadius of the rally city; otherwise it holds own
    /// ground, fortified.
    mutating func moveArmy() {
        let ids = forces(view).army.filter { !acted.contains($0.id) }.map(\.id)
        let staging = stageUnits(ids, view) // p3f C (AIPreparePosture.swift)
        for id in ids {
            guard live, let unit = view.unit(id) else { continue }
            acted.insert(id)
            if plan.posture == .war, plan.advancing, let target = plan.target, let field = plan.targetField,
               let t = view.index(of: target.position) {
                // Staging: out of the target's bombard range (bombardRange+1 … siegeStageRadius).
                // In the assault, ranged units stand within their range (at 2 when they can) to
                // fire next phase; melee units stay within 2 of the city, and close in next to it
                // once it is being hit (cityAttackFocusHits hits this phase, or down to
                // cityAttackMaxCityHP) — for flanking, and to attack or capture next phase.
                let bombard = rules.constants.city.bombardRange
                let stage = (bombard + 1)...max(bombard + 1, ai.siegeStageRadius)
                let low = target.hp + target.wallHP <= ai.cityAttackMaxCityHP || cityHits[target.id, default: 0] >= ai.cityAttackFocusHits
                if !plan.assault {
                    place(unit, around: t, band: stage, goal: field)
                } else if isRanged(unit.type) {
                    let range = view.range(of: unit)
                    place(unit, around: t, band: min(2, range)...range, goal: field)
                } else {
                    place(unit, around: t, band: low ? 1...1 : 1...2, goal: field)
                }
            } else if plan.posture == .prepare, let stage = plan.stage, let field = plan.stageField, staging.contains(id) {
                // p3f C (AIPreparePosture.swift): the watch, at the stage in the target's sight.
                place(unit, around: stage, band: 0...stageRadius, goal: field)
            } else if plan.posture == .war || plan.posture == .prepare, let rally = plan.rally, let field = plan.rallyField,
                      let r = view.index(of: rally.position) {
                place(unit, around: r, band: 0...ai.rallyRadius, goal: field, awayFrom: plan.rival)
            } else {
                holdGround(unit)
            }
        }
    }

    /// Moves a unit to where it should end the phase, among the tiles it reaches (its own
    /// included): never nearer `center` than the band unless already there; next, for a ranged
    /// unit, not next to a visible enemy melee unit; then inside the band (outside it, the
    /// lowest `goal`, the terrain cost to the centre); then the least danger; then, inside the
    /// band, the farthest from the cities of `awayFrom` (while gathering, out of their threat
    /// radius if possible) or else the lowest `goal`; then the cheapest move, then the lowest
    /// index. It fortifies where it ends.
    mutating func place(_ unit: Unit, around center: Int, band: ClosedRange<Int>, goal: [Int32], awayFrom rival: PlayerID? = nil) {
        let v = view
        guard let here = v.index(of: unit.position) else { return }
        let d = danger()
        let melee = isRanged(unit.type) ? enemyMeleeTiles(v) : []
        let rivalCities = rival.map { r in v.knownCities.filter { $0.owner == r }.compactMap { v.index(of: $0.position) } } ?? []
        let f = reachField(unit.id)
        func key(_ r: Int) -> [Int] {
            let dist = v.aiDistance(r, center)
            let g = goal[r] >= 0 ? Int(goal[r]) : Int(Int32.max)
            let tooClose = dist < band.lowerBound ? band.lowerBound - dist : 0
            let adjacent = melee.contains { v.aiDistance($0, r) == 1 } ? 1 : 0
            let outside = dist > band.upperBound ? g : 0
            var inside = g
            if !rivalCities.isEmpty {
                let away = rivalCities.map { v.aiDistance($0, r) }.min() ?? 0
                inside = -min(away, ai.threatRadius + 1)
            }
            return [tooClose, adjacent, outside, Int(d[r]), inside, r == here ? 0 : Int(f[r]), r]
        }
        var options = reachableThisPhase(unit)
        options.append(here)
        let keys = options.map(key)
        options = options.indices.sorted { keys[$0].lexicographicallyPrecedes(keys[$1]) }.map { options[$0] }
        for r in options.prefix(4) {
            if r == here { break }
            if move(unit.id, to: v.coord(at: r)) { break }
        }
        if let now = view.unit(unit.id) { fortify(now) }
    }

    /// Moves a unit to the tile it reaches this phase with the lowest `goal` value (ties: lower
    /// movement cost, then lower index), if better than where it stands; otherwise it
    /// fortifies. `avoidEnemies` skips tiles next to visible enemy military units;
    /// `keepAway` (tile, distance) skips tiles nearer than that.
    mutating func approach(_ unit: Unit, _ goal: [Int32], avoidEnemies: Bool, keepAway: (Int, Int)? = nil) {
        let v = view
        guard let here = v.index(of: unit.position) else { return }
        let enemies = avoidEnemies ? foreignMilitaryTiles(v, enemiesOnly: true, includeRecon: false) : []
        let f = reachField(unit.id)
        let options = reachableThisPhase(unit).filter { t in
            guard goal[t] >= 0 else { return false }
            if let (k, d) = keepAway, v.aiDistance(t, k) < d { return false }
            return !enemies.contains { v.aiDistance($0, t) <= 1 }
        }.sorted { (goal[$0], f[$0], $0) < (goal[$1], f[$1], $1) }
        let current = goal[here] >= 0 ? goal[here] : .max
        let better = options.filter { goal[$0] < current }
        if better.isEmpty || moveToFirst(unit.id, of: better) == nil {
            if let now = view.unit(unit.id) { fortify(now) }
        }
    }

    /// A unit with no task: fortified where it stands in own territory, else back toward the
    /// nearest own city.
    mutating func holdGround(_ unit: Unit) {
        let v = view
        guard let here = v.index(of: unit.position) else { return }
        if v.knownTerritory[here] == UInt8(player.rawValue + 1) || v.cities.isEmpty {
            fortify(unit)
            return
        }
        approach(unit, homeField(v), avoidEnemies: false)
    }

    /// Terrain cost to the nearest own city (cached while the cities stay the same).
    mutating func homeField(_ v: PlayerView) -> [Int32] {
        let cities = v.cities
        let ids = cities.map(\.id)
        if let cached = homeFieldCache, cached.cities == ids { return cached.field }
        let field = v.aiTerrainCostField(from: cities.map(\.position))
        homeFieldCache = (ids, field)
        return field
    }

    /// Garrisons fortify.
    mutating func fortifyGarrisons() {
        for city in view.cities {
            guard live, let garrison = view.units(at: city.position).first(where: { $0.owner == player && !$0.type.isCivilian }) else {
                continue
            }
            fortify(garrison)
        }
    }
}
