import GameAI
import GameCore

// `--narrate` (one line per notable decision and event) and the pathology counters printed
// for every AI game. Both only observe: they read the state, reports and events after each
// phase and never feed anything back into a game.

/// Per-player counts of play that looks wrong (ai-2's pathology hunt). All counted at the end
/// of the player's own phases unless noted.
struct Lint {
    /// A unit ended three consecutive own phases on tiles A, B, A (A ≠ B).
    var oscillations = 0
    /// A military unit ended a phase with all its moves, no activity and no orders.
    var idle = 0
    /// A city ended a phase with an empty queue; with only waiting items.
    var emptyQueues = 0, waitingQueues = 0
    var settlersMade = 0, settlersFounded = 0, settlersLost = 0
    /// The most turns a Settler lived before founding; Settler-phases older than 15 turns.
    var settlerMaxAge = 0, settlersOld = 0
    /// p3b (ai-settler-escort): Settler phases spent waiting for an escort (M1 §13 Safety, the
    /// AI's own escort requests); the most phases one Settler waited.
    var settlerWaits = 0, settlerMaxWait = 0
    /// An improvement built on a tile no own city works.
    var uselessImprovements = 0
    var improvements = 0
    var upkeepDisbands = 0
    /// Attacks in which the attacking unit died; melee attacks on units that took more damage
    /// than they dealt.
    var suicides = 0, badTrades = 0, attacks = 0
    /// Phases ending with a visible enemy city at 0 HP.
    var zeroHPCities = 0
    var peaceProposals = 0
    var purchases = 0
    /// Recon units alive and awake at the end of the game.
    var scoutsAwake = 0
    /// Cities captured and lost; own cities taken back.
    var retaken = 0
    /// A Settler or Builder ended a phase within civilianSafetyRadius of a visible foreign
    /// military unit with no own military unit on its tile, outside an own city (M1 §13 Safety;
    /// since p3d the rule at war is an enemy unit's reach instead, which may be nearer on rough
    /// ground, so this counts some safe civilians too: see `capturableSettlers`).
    var unsafeCivilians = 0
    /// p3d (ai-settlers-at-war): a Settler or Builder ended a phase where a military unit of a
    /// player at war with its owner could capture it in its next phase (that unit's own movement,
    /// full moves, by its owner's knowledge), outside an own city with no own military unit on its
    /// tile. Ground truth: whatever the civilian's owner saw.
    var capturableSettlers = 0, capturableBuilders = 0
    /// p3d: Settler phases spent waiting for an escort while at war with someone; Builders lost.
    var settlerWaitsAtWar = 0, buildersLost = 0

    mutating func merge(_ o: Lint) {
        oscillations += o.oscillations; idle += o.idle; emptyQueues += o.emptyQueues; waitingQueues += o.waitingQueues
        settlersMade += o.settlersMade; settlersFounded += o.settlersFounded; settlersLost += o.settlersLost
        settlerMaxAge = max(settlerMaxAge, o.settlerMaxAge); settlersOld += o.settlersOld
        settlerWaits += o.settlerWaits; settlerMaxWait = max(settlerMaxWait, o.settlerMaxWait)
        uselessImprovements += o.uselessImprovements; improvements += o.improvements; upkeepDisbands += o.upkeepDisbands
        suicides += o.suicides; badTrades += o.badTrades; attacks += o.attacks; zeroHPCities += o.zeroHPCities
        peaceProposals += o.peaceProposals; purchases += o.purchases; scoutsAwake += o.scoutsAwake; retaken += o.retaken
        unsafeCivilians += o.unsafeCivilians
        capturableSettlers += o.capturableSettlers; capturableBuilders += o.capturableBuilders
        settlerWaitsAtWar += o.settlerWaitsAtWar; buildersLost += o.buildersLost
    }

    var summary: String {
        "oscillations \(oscillations), idle \(idle), empty queues \(emptyQueues), waiting queues \(waitingQueues), "
            + "settlers \(settlersMade) made/\(settlersFounded) founded/\(settlersLost) lost (oldest \(settlerMaxAge) turns, "
            + "\(settlersOld) phases over 15, \(settlerWaits) phases waiting for an escort, longest wait \(settlerMaxWait)), improvements \(improvements) (\(uselessImprovements) unworked), "
            + "upkeep disbands \(upkeepDisbands), attacks \(attacks) (\(suicides) suicidal, \(badTrades) bad trades), "
            + "0-HP cities left \(zeroHPCities), peace proposals \(peaceProposals), purchases \(purchases), "
            + "scouts awake \(scoutsAwake), retaken \(retaken), unsafe civilians \(unsafeCivilians), "
            + "capturable next phase \(capturableSettlers) Settlers/\(capturableBuilders) Builders, "
            + "settler phases waiting at war \(settlerWaitsAtWar), builders lost \(buildersLost)"
    }
}

/// Watches a game phase by phase: pathology counts for every player and, when narrating, one
/// line per notable decision or event.
struct Observer {
    let narrate: Bool
    /// With narration: also one line per idle unit and per oscillation (`--lint-detail`).
    var lintDetail = false
    var lint: [Lint]
    /// Per unit: its tiles at the end of the last two own phases (oldest first).
    var trail: [UnitID: [HexCoord]] = [:]
    /// Per Settler: the turn it was made.
    var settlerBorn: [UnitID: Int] = [:]
    /// Per Settler: its phases spent waiting for an escort so far (lookups only).
    var settlerWaited: [UnitID: Int] = [:]
    /// p3d: each player's visible tiles at the end of the last phase, so at the start of the
    /// next one (`--lint-detail` tells a unit seen then from one revealed during the phase).
    var visibleBefore: [TileBitSet] = []
    /// Per player: the last posture, rival, target and advancing flag reported.
    var posture: [AIPosture?]
    var rival: [PlayerID?]
    var target: [CityID?]
    var advancing: [Bool]
    var lines: [String] = []

    init(players: Int, narrate: Bool) {
        self.narrate = narrate
        lint = Array(repeating: Lint(), count: players)
        posture = Array(repeating: nil, count: players)
        rival = Array(repeating: nil, count: players)
        target = Array(repeating: nil, count: players)
        advancing = Array(repeating: false, count: players)
    }

    mutating func say(_ turn: Int, _ player: PlayerID?, _ text: String) {
        guard narrate else { return }
        let line = "t\(turn) " + (player.map { "\($0) " } ?? "") + text
        print(line)
    }

    func cityName(_ id: CityID, _ state: GameState) -> String {
        state.city(id)?.name ?? "\(id)"
    }

    /// An AI phase's plan changes and notes.
    mutating func plan(_ report: AIPhaseReport, player: PlayerID, turn: Int, state: GameState) {
        let p = player.rawValue
        if posture[p] != report.posture || rival[p] != report.rival {
            say(turn, player, "posture \(posture[p]?.rawValue ?? "-") → \(report.posture.rawValue)"
                + (report.rival.map { ", rival \($0)" } ?? "") + "; " + report.planSummary)
        } else if report.target != target[p], let t = report.target {
            say(turn, player, "new target \(cityName(t, state)); " + report.planSummary)
        }
        if report.advancing && !advancing[p], let t = report.target {
            say(turn, player, "army advances on \(cityName(t, state)); " + report.planSummary)
        } else if !report.advancing && advancing[p] && report.posture == .war {
            say(turn, player, "army falls back to gather; " + report.planSummary)
        }
        posture[p] = report.posture
        rival[p] = report.rival
        target[p] = report.target
        advancing[p] = report.advancing
        for note in report.notes { say(turn, player, note) }
        let atWarNow = state.players.contains { $0.id != player && $0.isAlive && state.isAtWar(player, $0.id) }
        for id in report.escortRequests where settlerBorn[id] != nil {
            settlerWaited[id, default: 0] += 1
            lint[p].settlerWaits += 1
            if atWarNow { lint[p].settlerWaitsAtWar += 1 }
            if lintDetail, let unit = state.unit(id) {
                let view = state.view(for: player)
                let inCity = state.cities.contains { $0.position == unit.position }
                let closed = view.index(of: unit.position).map { view.aiClosedToMilitary()[$0] } ?? false
                let atWar = view.players.contains { $0.id != player && $0.isAlive && view.isAtWar(with: $0.id) }
                let foreign = view.visibleForeignUnits.filter { !$0.type.isCivilian }
                    .min { (view.distance($0.position, unit.position), $0.id) < (view.distance($1.position, unit.position), $1.id) }
                // Free fighters: non-recon military units that are no city's garrison (the
                // lowest-id military unit on a city tile).
                let garrisons = view.cities.compactMap { c in view.units.first { !$0.type.isCivilian && $0.position == c.position }?.id }
                let free = view.units.filter { !$0.type.isCivilian && state.rules.unit($0.type).unitClass != .recon && !garrisons.contains($0.id) }
                let nearest = free.map { view.distance($0.position, unit.position) }.min()
                say(turn, player, "Settler \(id) waits at \(unit.position)\(inCity ? " (in a city)" : "")"
                    + "\(closed ? " (on land closed to its military)" : "") for an escort "
                    + "(\(settlerWaited[id]!) phases so far; \(atWar ? "at war" : "at peace"); nearest foreign military "
                    + (foreign.map { "\($0.owner) \($0.type.rawValue) \(view.distance($0.position, unit.position)) tiles" } ?? "none seen")
                    + "; free fighters \(free.count)" + (nearest.map { ", nearest \($0) tiles" } ?? "")
                    + "; remembered within 4: " + view.sightings.filter { s in
                        state.rules.unit(s.type).unitClass != .recon && view.distance(s.position, unit.position) <= 4
                            && !view.isVisible(s.position)
                    }.map { "\($0.type.rawValue) \(view.distance($0.position, unit.position)) tiles, age \(turn - $0.turnSeen)" }.joined(separator: ", ") + ")")
            }
        }
        lint[p].peaceProposals += report.result.steps.filter { if case .proposePeace = $0.command { true } else { false } }.count
        lint[p].purchases += report.result.steps.filter { if case .purchase = $0.command { true } else { false } }.count
    }

    /// One command's events (in any phase), with the state after the command.
    mutating func step(_ command: Command, _ records: [EventRecord], by player: PlayerID, turn: Int, state: GameState) {
        var lastCombat: (attacker: Combatant, from: HexCoord, dealt: Int, taken: Int, ranged: Bool)?
        for record in records {
            switch record.event {
            case let .combat(attacker, defender, from, _, ranged, dealt, taken):
                lastCombat = (attacker, from, dealt, taken, ranged)
                if case .unit = attacker {
                    lint[player.rawValue].attacks += 1
                    if !ranged, taken > dealt, case .unit = defender { lint[player.rawValue].badTrades += 1 }
                }
            case let .unitKilled(unit, type, owner, at):
                if let c = lastCombat, case let .unit(attacker) = c.attacker, attacker == unit {
                    lint[owner.rawValue].suicides += 1
                }
                if type == .settler { lint[owner.rawValue].settlersLost += 1; settlerBorn[unit] = nil; endWait(unit, owner) }
                let by = lastCombat.map { c -> String in
                    switch c.attacker {
                    case let .unit(id): return " by \(state.unit(id).map { "\($0.owner) \($0.type.displayName)" } ?? "a unit that died")"
                        + (c.ranged ? " (ranged)" : "")
                    case let .city(id): return " by \(cityName(id, state)) (city)"
                    }
                } ?? (command == .endTurn ? " (phase start)" : "")
                say(turn, owner, "loses \(type.displayName) \(unit) at \(at)\(by)")
            case let .unitCaptured(old, _, type, from, to, at):
                // `type` is what the captor gets: a captured Settler arrives as a Builder (p3f: it was
                // counted as a Builder lost, and no Settler was ever lost).
                let settler = type == .settler || settlerBorn[old] != nil
                if settler { lint[from.rawValue].settlersLost += 1; settlerBorn[old] = nil; endWait(old, from) }
                if type == .builder, !settler { lint[from.rawValue].buildersLost += 1 }
                say(turn, from, "loses \(settler ? UnitType.settler.displayName : type.displayName) \(old) at \(at): captured by \(to)")
            case let .unitDisbanded(unit, type, owner, at, upkeep):
                if upkeep { lint[owner.rawValue].upkeepDisbands += 1 }
                if type == .settler { settlerBorn[unit] = nil; endWait(unit, owner) }
                if upkeep { say(turn, owner, "disbands \(type.displayName) \(unit) at \(at): upkeep unpaid") }
            case let .unitCreated(unit, type, owner, at):
                if type == .settler {
                    settlerBorn[unit] = turn
                    lint[owner.rawValue].settlersMade += 1
                    if lintDetail { say(turn, owner, "makes Settler \(unit) at \(at): " + settlerContext(owner, at, state)) }
                }
            case let .cityFounded(_, name, owner, at):
                if case let .foundCity(id) = command, let born = settlerBorn[id] {
                    lint[owner.rawValue].settlersFounded += 1
                    lint[owner.rawValue].settlerMaxAge = max(lint[owner.rawValue].settlerMaxAge, turn - born)
                    settlerBorn[id] = nil
                    endWait(id, owner)
                    say(turn, owner, "founds \(name) at \(at) (Settler made t\(born))")
                } else {
                    say(turn, owner, "founds \(name) at \(at)")
                }
            case let .cityCaptured(city, name, from, to, at):
                let pop = state.city(city)?.population ?? 0
                if state.city(city)?.originalOwner == to { lint[to.rawValue].retaken += 1 }
                say(turn, to, "captures \(name) (population \(pop)) from \(from) at \(at)")
            case let .cityRazed(_, name, owner, _):
                say(turn, owner, "razes \(name)")
            case let .improvementBuilt(_, at, owner):
                lint[owner.rawValue].improvements += 1
                if !state.cities.contains(where: { $0.owner == owner && $0.workedTiles.contains(at) }) {
                    lint[owner.rawValue].uselessImprovements += 1
                }
            case let .peaceSigned(a, b):
                say(turn, nil, "peace between \(a) and \(b)")
            case let .peaceDeclined(proposer, by):
                say(turn, nil, "\(by) declines (or lets expire) \(proposer)'s peace proposal")
            case let .playerEliminated(p):
                say(turn, p, "is eliminated")
            case let .gameOver(outcome):
                say(turn, nil, "game over: \(outcome)")
            default:
                break
            }
        }
    }

    /// The end of `player`'s phase.
    mutating func endOfPhase(_ player: PlayerID, turn: Int, state: GameState) {
        let p = player.rawValue
        let view = state.view(for: player)
        for unit in state.units where unit.owner == player {
            var t = trail[unit.id] ?? []
            if t.count == 2, t[0] == unit.position, t[1] != unit.position {
                lint[p].oscillations += 1
                if lintDetail {
                    say(turn, player, "oscillates \(unit.type.rawValue) \(unit.id) \(t[1]) ↔ \(unit.position) \(unit.hp) HP \(unit.activity)")
                }
            }
            t.append(unit.position)
            if t.count > 2 { t.removeFirst() }
            trail[unit.id] = t
            if !unit.type.isCivilian, unit.activity == .none, unit.destination == nil, !unit.zocStopped,
               unit.movesLeft == state.rules.unit(unit.type).moves * state.rules.movePoints {
                lint[p].idle += 1
                if lintDetail {
                    say(turn, player, "idle \(unit.type.rawValue) \(unit.id) at \(unit.position) \(unit.hp) HP")
                }
            }
            if unit.type == .settler, let born = settlerBorn[unit.id], turn - born > 15 { lint[p].settlersOld += 1 }
        }
        // Civilian safety (M1 §13): the foreign military units visible at the end of the phase.
        let foreign = view.visibleForeignUnits.filter { !$0.type.isCivilian }
        let radius = state.rules.ai.civilianSafetyRadius
        for unit in view.units where unit.type.isCivilian {
            let near = foreign.filter { view.distance($0.position, unit.position) <= radius }
            guard !near.isEmpty, !view.cities.contains(where: { $0.position == unit.position }),
                  !view.units.contains(where: { !$0.type.isCivilian && $0.position == unit.position }) else { continue }
            lint[p].unsafeCivilians += 1
            if lintDetail {
                say(turn, player, "leaves \(unit.type.rawValue) \(unit.id) at \(unit.position) (\(unit.activity), \(unit.movesLeft) moves) "
                    + "near foreign " + near.map { "\($0.owner) \($0.type.rawValue)@\($0.position)" }.joined(separator: " "))
            }
        }
        countCapturable(player, turn: turn, state: state)
        if lintDetail { visibleBefore = state.players.map(\.visible) }
        for city in state.cities where city.owner == player {
            if city.queue.isEmpty {
                lint[p].emptyQueues += 1
            } else if city.queue.allSatisfy({ view.aiCompletionProblem($0.item, in: city.id) != nil }) {
                lint[p].waitingQueues += 1
            }
        }
        for city in view.knownCities where city.hp == 0 && view.isAtWar(with: city.owner) && view.isVisible(city.position) {
            lint[p].zeroHPCities += 1
            guard lintDetail else { continue }
            let near = view.units.filter { $0.owner == player && !$0.type.isCivilian && view.distance($0.position, city.position) <= 2 }
                .map { "\($0.type.rawValue) \($0.id) at \($0.position) \($0.hp) HP" }
            say(turn, player, "leaves \(city.name) at 0 HP uncaptured; own units within 2: " + (near.isEmpty ? "none" : near.joined(separator: ", ")))
        }
    }

    /// p3d (ai-settlers-at-war): `player`'s Settlers and Builders that a military unit of a
    /// player at war with it could capture in its next phase (`Lint.capturableSettlers`).
    mutating func countCapturable(_ player: PlayerID, turn: Int, state: GameState) {
        let enemies = state.units.filter { !$0.type.isCivilian && $0.owner != player && state.isAtWar(player, $0.owner) }
        guard !enemies.isEmpty else { return }
        for unit in state.units where unit.owner == player && (unit.type == .settler || unit.type == .builder) {
            guard !state.cities.contains(where: { $0.position == unit.position }),
                  !state.units.contains(where: { $0.owner == player && !$0.type.isCivilian && $0.position == unit.position }) else { continue }
            for enemy in enemies where state.map.distance(enemy.position, unit.position) <= state.rules.unit(enemy.type).moves {
                var fresh = enemy
                fresh.movesLeft = state.rules.unit(enemy.type).moves * state.rules.movePoints
                fresh.zocStopped = false
                guard Pathfinder.reachableTiles(for: fresh, in: state).contains(unit.position) else { continue }
                if unit.type == .settler { lint[player.rawValue].capturableSettlers += 1 } else { lint[player.rawValue].capturableBuilders += 1 }
                if lintDetail {
                    let view = state.view(for: player)
                    let marked = view.index(of: unit.position).map { view.aiEnemyReach()[$0] } ?? false
                    let e = state.map.index(of: enemy.position)!
                    let seenBefore = visibleBefore.indices.contains(player.rawValue) && visibleBefore[player.rawValue][e]
                    let t = trail[unit.id] ?? []
                    let moved = t.count == 2 && t[0] != t[1]
                    say(turn, player, "leaves \(unit.type.rawValue) \(unit.id) at \(unit.position) capturable by \(enemy.owner) "
                        + "\(enemy.type.rawValue) \(enemy.id) at \(enemy.position) (\(state.map.distance(enemy.position, unit.position)) tiles"
                        + (state.players[player.rawValue].visible[e] ? ", visible" : ", unseen")
                        + (seenBefore ? " since the phase began" : " only now")
                        + (marked ? ", in its known reach" : ", outside its known reach")
                        + "; \(unit.activity.rawValue), \(unit.movesLeft) moves, " + (moved ? "moved" : "stayed") + ")")
                }
                break
            }
        }
    }

    /// p3d: what a new Settler's owner knows about the war around it (`--lint-detail`).
    func settlerContext(_ owner: PlayerID, _ at: HexCoord, _ state: GameState) -> String {
        let view = state.view(for: owner)
        let atWar = view.players.contains { $0.id != owner && $0.isAlive && view.isAtWar(with: $0.id) }
        let city = view.cities.first { $0.position == at }
        let visible = view.visibleForeignUnits.filter { !$0.type.isCivilian && view.isAtWar(with: $0.owner) }
            .map { view.distance($0.position, at) }.min()
        let remembered = view.sightings.filter { s in
            view.isAtWar(with: s.owner) && state.rules.unit(s.type).unitClass != .recon && !view.isVisible(s.position)
        }.map { view.distance($0.position, at) }.min()
        let enemyCity = view.knownCities.filter { view.isAtWar(with: $0.owner) }.map { view.distance($0.position, at) }.min()
        let foreignCity = view.knownCities.filter { $0.owner != owner }.map { view.distance($0.position, at) }.min()
        func d(_ x: Int?) -> String { x.map { "\($0)" } ?? "-" }
        return "\(city?.name ?? "?"), \(atWar ? "at war" : "at peace"); nearest enemy military visible \(d(visible)), remembered \(d(remembered)); "
            + "nearest enemy city \(d(enemyCity)), foreign city \(d(foreignCity))"
    }

    /// A Settler's waiting ends (it founded a city or is gone): its count goes into the longest
    /// wait.
    mutating func endWait(_ id: UnitID, _ owner: PlayerID) {
        guard let waited = settlerWaited.removeValue(forKey: id) else { return }
        lint[owner.rawValue].settlerMaxWait = max(lint[owner.rawValue].settlerMaxWait, waited)
    }

    /// The end of the game.
    mutating func finish(_ state: GameState) {
        // Settlers still alive: their waiting so far counts (in id order).
        for unit in state.units where unit.type == .settler { endWait(unit.id, unit.owner) }
        for unit in state.units where state.rules.unit(unit.type).unitClass == .recon && unit.activity != .sleeping {
            lint[unit.owner.rawValue].scoutsAwake += 1
        }
    }
}
