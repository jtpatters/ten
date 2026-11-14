import Foundation
import GameAI
import GameCore
import MapGen

// Headless autoplay (M1 §17): generates a map and plays N turns phase by phase (one phase per
// living player, M1 §3), printing state hashes. Two runs with the same arguments must print
// identical hashes (the determinism check, `make determinism`).
//
//   --random (default)  stress mode: in each phase, two rounds of seeded random commands for
//                       the current player (`DebugTools.randomCommands`: moves, research and
//                       production, and now and then founding, attacks, bombards, war, peace
//                       and razing), then its `endTurn`
//   --scripted          each phase plays `DebugTools.scriptedCommands` (found cities, queue
//                       production, research, improve tiles, move), then `endTurn`
//   --ai                every player is an AI: `AIPlayer.playPhase` (= `playTurn` plus its
//                       report) for the current player, phase after phase; invariants are
//                       checked after every phase
//
// Every player is an AI (no human players), so games run to a victory or the turn limit. With
// `--extra-units`, every player gets 1,000,000 Gold so unit upkeep (M1 §7.1) never disbands the
// stress units. A single game prints the state hash once per full turn (never per phase) and at
// the end, then its statistics, query timings and, as its last line, `final hash …`; invariants
// (`GameState.checkInvariants()`) are checked every 10 turns and at the end (after every phase
// with `--check-every-phase`, and always in `--ai` mode), and a broken one exits non-zero.
//
// `--games N` plays seeds S, S+1, …, S+N−1 and prints one block per game, then (in `--ai` mode)
// the M1 balance targets met (M1 §17): every AI founds ≥ 3 cities by turn 60 (≥ 80% of games), a
// war starts by turn 80 (≥ 70%), a city is captured by turn 150 (≥ 30%). `--trace` (`--ai` only)
// prints one line per phase: posture, rival, commands, cities, military and AI time.
// `--narrate` (`--ai` only) prints one line per notable decision (posture changes, war with its
// rival, target and rally city, the army's advance, purchases, peace offers and answers, razing)
// and event (cities founded, captured or razed, units lost) and a status line every 10 turns;
// `--lint-detail` (implies `--narrate`) adds a line per idle unit, oscillation and 0-HP enemy city
// left uncaptured.
// `--profile` (`--ai` only) times each step of every AI phase (planning, each tactic, settlers,
// builders, exploring, the military, cities) and prints the totals per step and the slowest
// phases with their steps.
// Every `--ai` game also prints pathology counts (`Lint`: oscillating or idle units, empty
// queues, old or lost Settlers, unworked improvements, upkeep disbands, suicidal attacks, 0-HP
// cities left standing, peace proposals, …). `--p0 scripted|turtle|newbie|shadow` puts a
// scripted stand-in for a human in player 0's seat (`Opponents.swift`); the other players stay
// AIs. `--early` prints what player 0's seat lives through in the early game (`EarlyGame.swift`):
// early-game checks play against `--p0 newbie --early` (`shadow` for one that dogs the AI's
// Settlers).
// p3g (tribal villages, M1 §7.7, §17): `--random` and `--ai` games place tribal villages when the
// rules have the `tribalVillages` section (`--rules` without it plays without them, exactly as
// before them); `--scripted` games place none. Such games print a `tribal villages:` line per
// game and, per player, its takes by turn 25 and in all with its gifts by kind; `--games N`
// prints their sums (`TribalVillageStats.swift`). `--newbie-rush` makes the newbie's capital
// build a second Scout first (G13). `--placement-timing` times placement on `--games` maps of
// `--size` instead of playing (in release: the G9 gate, at most 5 ms on Large).
//
//   swift run -c release headless-sim --random --size large --seed 42 --turns 100 --extra-units 300
//   swift run -c release headless-sim --ai --size duel --seed 7 --turns 100
//   swift run -c release headless-sim --ai --games 20 --size duel --seed 1 --turns 150   (make balance)
//   swift run -c release headless-sim --ai --games 40 --size duel --seed 1 --turns 80 --p0 newbie --early

enum Mode: String { case random, scripted, ai }

struct Options {
    var mode = Mode.random
    var size = MapSize.standard
    var seed: UInt64 = 42
    var turns = 50
    var games = 1
    var extraUnits = 0
    var checkEveryPhase = false
    var trace = false
    var narrate = false
    var lintDetail = false
    /// `--trace` detail: every command and each own unit at the end of the phase, for turns in
    /// `--from`…`--until` (only those turns are traced then).
    var traceUnits = false
    var traceFrom = 0
    var traceUntil = Int.max
    /// Who plays player 0 in `--ai` mode.
    var p0 = Opponent.ai
    /// Time each step of every AI phase.
    var profile = false
    /// p3 early-game: early-game metrics from player 0's seat (`EarlyGame.swift`).
    var early = false
    /// p3 early-game: play by the rules in this JSON file instead of the bundled ones (tuning
    /// experiments without a rebuild; the rules' content hash still goes into every state hash).
    var rulesPath: String?
    /// p3b: measure the start positions of each map instead of playing (`StartQuality.swift`).
    var starts = false
    /// p3g: the newbie's capital builds a second Scout first (`--newbie-rush`, DESIGN §5.3, G13).
    var newbieRush = false
    /// p3g: time tribal village placement instead of playing (`--placement-timing`, G9).
    var placementTiming = false
}

var parsed = Options()
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--random": parsed.mode = .random
    case "--scripted": parsed.mode = .scripted
    case "--ai": parsed.mode = .ai
    case "--size": parsed.size = args.next().flatMap(MapSize.init(rawValue:)) ?? parsed.size
    case "--seed": parsed.seed = args.next().flatMap { UInt64($0) } ?? parsed.seed
    case "--turns": parsed.turns = args.next().flatMap { Int($0) } ?? parsed.turns
    case "--games": parsed.games = max(1, args.next().flatMap { Int($0) } ?? parsed.games)
    case "--extra-units": parsed.extraUnits = args.next().flatMap { Int($0) } ?? parsed.extraUnits
    case "--check-every-phase": parsed.checkEveryPhase = true
    case "--trace": parsed.trace = true
    case "--narrate": parsed.narrate = true
    case "--lint-detail": parsed.narrate = true; parsed.lintDetail = true
    case "--units": parsed.traceUnits = true
    case "--from": parsed.traceFrom = args.next().flatMap { Int($0) } ?? 0
    case "--until": parsed.traceUntil = args.next().flatMap { Int($0) } ?? Int.max
    case "--p0": parsed.p0 = args.next().flatMap(Opponent.init(rawValue:)) ?? parsed.p0
    case "--profile": parsed.profile = true
    case "--early": parsed.early = true
    case "--rules": parsed.rulesPath = args.next()
    case "--starts": parsed.starts = true
    case "--newbie-rush": parsed.newbieRush = true
    case "--placement-timing": parsed.placementTiming = true
    default:
        print("usage: headless-sim [--random | --scripted | --ai] [--games N] [--size duel|small|standard|large] [--seed N] "
            + "[--turns N] [--extra-units N] [--check-every-phase] [--trace] [--narrate] [--lint-detail] [--p0 ai|scripted|turtle|newbie|shadow] "
            + "[--profile] [--early] [--rules ruleset.json] [--starts] [--newbie-rush] [--placement-timing]")
        print("  early-game checks: --ai --games 40 --size duel --seed 1 --turns 80 --p0 newbie --early")
        exit(1)
    }
}
let options = parsed

/// The rules every game plays by: the bundled ones, or `--rules`.
let gameRules: Ruleset = {
    guard let path = options.rulesPath else { return .standard }
    do {
        return try Ruleset(jsonData: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        print("error: --rules \(path): \(error)")
        exit(1)
    }
}()

let clock = ContinuousClock()

func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

/// Timings of one kind of step.
struct Timings {
    var count = 0
    var total = 0.0
    var max = 0.0

    mutating func add(_ d: Duration) {
        add(ms: milliseconds(d))
    }

    mutating func add(ms: Double) {
        count += 1
        total += ms
        max = Swift.max(max, ms)
    }

    mutating func merge(_ other: Timings) {
        count += other.count
        total += other.total
        max = Swift.max(max, other.max)
    }

    var mean: Double { count == 0 ? 0 : total / Double(count) }

    var summary: String {
        count == 0 ? "none" : String(format: "%d, mean %.4f ms, max %.3f ms", count, mean, max)
    }
}

/// Where AI time goes (`--profile`): per step, and the slowest phases with their steps.
struct Profile {
    var steps: [String: Timings] = [:]
    /// Step names in the order first seen.
    var order: [String] = []
    var slowest: [(ms: Double, label: String, steps: [(step: String, time: Duration)])] = []

    mutating func add(_ times: [(step: String, time: Duration)], total: Duration, label: String) {
        for (step, time) in times {
            if steps[step] == nil { order.append(step) }
            steps[step, default: Timings()].add(time)
        }
        let ms = milliseconds(total)
        if slowest.count < 8 || ms > slowest[slowest.count - 1].ms {
            slowest.append((ms, label, times))
            slowest.sort { $0.ms > $1.ms }
            if slowest.count > 8 { slowest.removeLast() }
        }
    }

    mutating func merge(_ other: Profile) {
        for step in other.order {
            if steps[step] == nil { order.append(step) }
            steps[step, default: Timings()].merge(other.steps[step]!)
        }
        slowest = Array((slowest + other.slowest).sorted { $0.ms > $1.ms }.prefix(8))
    }

    func print() {
        let total = order.reduce(0.0) { $0 + steps[$1]!.total }
        Swift.print("AI profile (time per step over all AI phases):")
        for step in order {
            let t = steps[step]!
            Swift.print(String(format: "  %-20@ total %9.1f ms (%4.1f%%), mean %.4f ms, max %8.3f ms", step as NSString, t.total,
                               total > 0 ? 100 * t.total / total : 0, t.mean, t.max))
        }
        Swift.print("slowest AI phases:")
        for entry in slowest {
            let parts = entry.steps.filter { milliseconds($0.time) >= 0.05 * entry.ms }
                .map { String(format: "%@ %.1f", $0.step as NSString, milliseconds($0.time)) }
            Swift.print(String(format: "  %.3f ms %@: ", entry.ms, entry.label as NSString) + parts.joined(separator: ", "))
        }
    }
}

/// Counts of the events that show combat, capture and diplomacy happened.
struct EventCounts {
    var combats = 0, kills = 0, civiliansCaptured = 0, citiesCaptured = 0, citiesRazed = 0, citiesFounded = 0
    var wars = 0, peaces = 0, eliminations = 0

    mutating func add(_ records: [EventRecord]) {
        for record in records {
            switch record.event {
            case .combat: combats += 1
            case .unitKilled: kills += 1
            case .unitCaptured: civiliansCaptured += 1
            case .cityCaptured: citiesCaptured += 1
            case .cityRazed: citiesRazed += 1
            case .cityFounded: citiesFounded += 1
            case .warDeclared: wars += 1
            case .peaceSigned: peaces += 1
            case .playerEliminated: eliminations += 1
            default: break
            }
        }
    }

    var summary: String {
        "\(citiesFounded) cities founded, \(combats) combats, \(kills) units killed, \(civiliansCaptured) civilians captured, "
            + "\(citiesCaptured) cities captured, \(citiesRazed) razed, \(wars) wars declared, \(peaces) peace treaties, "
            + "\(eliminations) players eliminated"
    }
}

/// One player's tallies over a game (M1 §17).
struct PlayerTally {
    var founded = 0
    /// The turn of its third founded city.
    var thirdCityTurn: Int?
    var captured = 0, lost = 0, razed = 0, civilians = 0, unitsLost = 0
}

/// What one game did.
struct GameReport {
    var seed: UInt64
    var state: GameState
    var tallies: [PlayerTally]
    var counts = EventCounts()
    var events = 0
    var wars: [(turn: Int, by: PlayerID, on: PlayerID)] = []
    var peaces: [(turn: Int, a: PlayerID, b: PlayerID)] = []
    var firstCapture: Int?
    /// The turn the world entered each era after the first (M2 §2).
    var eraTurns: [(era: Int, turn: Int)] = []
    /// Insights fired, per player.
    var insights: [Int] = []
    var promotions = 0
    var upgrades = 0
    /// Turns that ended with some pair of players at war.
    var turnsAtWar = 0
    var commands = Timings(), phases = Timings(), ai = Timings()
    var profile = Profile()
    var commandCount = 0
    var rejected = 0
    var rejections: [String] = []
    var capHits = 0
    var phasesChecked = 0
    var simTime = Duration.zero
    var observer: Observer
    /// p3 early-game: what player 0's seat lives through (`--early`; observes only).
    var early: EarlyObserver
    /// p3g: the game's tribal villages (observes only; nothing in a game without them).
    var villages: TribalVillageStats

    /// `sites`: placement's tags for the game's tribal villages (nil: a game without them).
    init(seed: UInt64, state: GameState, narrate: Bool, p0: String = "ai", turns: Int = 0, sites: [TribalVillageSite]? = nil) {
        self.seed = seed
        self.state = state
        tallies = Array(repeating: PlayerTally(), count: state.players.count)
        observer = Observer(players: state.players.count, narrate: narrate)
        early = EarlyObserver(seed: seed, p0: p0, turns: turns)
        villages = TribalVillageStats(state: state, sites: sites)
        if let sites { early.startTribalVillages(sites, state: state) }
    }

    /// Tallies a phase's events (`turn`: the phase's turn).
    mutating func tally(_ records: [EventRecord], turn: Int) {
        events += records.count
        counts.add(records)
        villages.add(records)
        for record in records {
            switch record.event {
            case let .cityFounded(_, _, owner, _):
                tallies[owner.rawValue].founded += 1
                if tallies[owner.rawValue].founded == 3 { tallies[owner.rawValue].thirdCityTurn = turn }
            case let .cityCaptured(_, _, from, to, _):
                tallies[to.rawValue].captured += 1
                tallies[from.rawValue].lost += 1
                if firstCapture == nil { firstCapture = turn }
            case let .cityRazed(_, _, owner, _): tallies[owner.rawValue].razed += 1
            case let .unitCaptured(_, _, _, _, to, _): tallies[to.rawValue].civilians += 1
            case let .unitKilled(_, _, owner, _): tallies[owner.rawValue].unitsLost += 1
            case let .warDeclared(by, on): wars.append((turn, by, on))
            case let .peaceSigned(a, b): peaces.append((turn, a, b))
            case let .worldEraAdvanced(era): eraTurns.append((era, turn))
            case .unitPromoted: promotions += 1
            case .unitUpgraded: upgrades += 1
            case let .insightGained(player, _, _):
                if insights.count < state.players.count { insights = Array(repeating: 0, count: state.players.count) }
                insights[player.rawValue] += 1
            default: break
            }
        }
    }

    /// Players the AI plays (all, or all but player 0 with `--p0`).
    var aiPlayers: [Int] = []
    /// AI phase times from turn 140 on (M1 §12.7 budgets are for turn 150).
    var aiLate = Timings()

    var everyoneFoundedThreeBy60: Bool { aiPlayers.allSatisfy { (tallies[$0].thirdCityTurn ?? .max) <= 60 } }
    var warBy80: Bool { (wars.first?.turn ?? .max) <= 80 }
    var captureBy150: Bool { (firstCapture ?? .max) <= 150 }

    var outcomeLine: String {
        state.outcome.map { "\($0) in turn \(state.turn)" } ?? "none by turn \(state.turn)"
    }

    var warLine: String {
        /// At most 12 entries, then a count.
        func list(_ items: [String]) -> String {
            items.isEmpty ? "none" : items.prefix(12).joined(separator: ", ") + (items.count > 12 ? " (+\(items.count - 12) more)" : "")
        }
        return "wars declared: " + list(wars.map { "t\($0.turn) \($0.by)→\($0.on)" })
            + "; peace: " + list(peaces.map { "t\($0.turn) \($0.a)+\($0.b)" })
            + "; \(turnsAtWar) turns at war; first city captured: " + (firstCapture.map { "t\($0)" } ?? "none")
    }

    /// "world era: Classical t44, Medieval t88; insights p0 5, p1 4" (M2 §2, §6.2).
    var eraLine: String {
        let rules = state.rules
        let eras = eraTurns.map { "\(rules.eras.indices.contains($0.era) ? rules.eras[$0.era].name : "\($0.era)") t\($0.turn)" }
        let fired = insights.enumerated().map { "p\($0.offset) \($0.element)" }
        return "world era: " + (eras.isEmpty ? "unchanged" : eras.joined(separator: ", "))
            + "; insights " + (fired.isEmpty ? "none" : fired.joined(separator: ", "))
            + "; promotions \(promotions), upgrades \(upgrades)"
    }

    /// "resources: 52 bonus, 30 luxury, 24 strategic; improved 18; pasture 9, …; stock p0 horses 12/2 iron 0/0" (M2 §3.1).
    var resourceLine: String {
        let rules = state.rules
        var placed: [ResourceKind: Int] = [:]
        var built = [Int](repeating: 0, count: Improvement.allCases.count)
        var roads = 0, pillaged = 0
        for t in state.map.tiles.indices {
            let tile = state.map.tiles[t]
            if let r = tile.resource, let def = rules.resource(r) { placed[def.kind, default: 0] += 1 }
            if let i = tile.improvement { built[Int(i.rawValue) - 1] += 1 }
            if tile.hasRoad { roads += 1 }
            if tile.isPillaged { pillaged += 1 }
        }
        let improvements = Improvement.allCases.enumerated().filter { built[$0.offset] > 0 }
            .map { "\(String(describing: $0.element)) \(built[$0.offset])" }.joined(separator: ", ")
        let strategic = Resource.allCases.filter { rules.resource($0)?.kind == .strategic }
        let stocks = state.players.filter(\.isAlive).map { player in
            let sources = state.improvedSources(of: player.id)
            return "\(player.id) " + strategic.map { "\(String(describing: $0)) \(player.stock($0))/\(sources[Int($0.rawValue) - 1])" }
                .joined(separator: " ")
        }.joined(separator: ", ")
        return "resources: \(placed[.bonus, default: 0]) bonus, \(placed[.luxury, default: 0]) luxury, "
            + "\(placed[.strategic, default: 0]) strategic; improvements " + (improvements.isEmpty ? "none" : improvements)
            + "; roads \(roads), pillaged \(pillaged); stock/sources " + stocks
    }

    func playerLine(_ player: Player) -> String {
        let cities = state.cities.filter { $0.owner == player.id }
        let t = tallies[player.id.rawValue]
        return "  \(player.id) \(player.name): " + (player.isAlive ? "" : "eliminated, ")
            + "\(cities.count) cities (founded \(t.founded), 3rd " + (t.thirdCityTurn.map { "t\($0)" } ?? "never") + "), "
            + "population \(cities.reduce(0) { $0 + $1.population }), \(player.knownTechs.count) techs, "
            + "\(state.militaryUnitCount(of: player.id)) military, \(state.units(of: player.id).count) units, "
            + "captured \(t.captured), lost \(t.lost), razed \(t.razed), civilians \(t.civilians), units lost \(t.unitsLost), "
            + "\(player.gold) gold, score \(state.score(of: player.id))" + villages.playerSummary(player.id.rawValue)
    }

    /// p3g: the game's tribal village line (empty for a game without them).
    var villageLine: String { villages.gameLine(standing: DebugTools.tribalVillages(in: state).count) }
}

/// Attacks (melee, ranged and city bombardments) among a phase's commands.
func attacks(_ result: AITurnResult) -> Int {
    result.steps.filter { step in
        switch step.command {
        case .attack, .cityAttack: true
        default: false
        }
    }.count
}

func checkInvariants(_ state: GameState, _ label: String) {
    let problems = state.checkInvariants()
    guard !problems.isEmpty else { return }
    print("error: \(problems.count) broken invariants at \(label):")
    for problem in problems.prefix(30) { print("  \(problem)") }
    exit(1)
}

/// Generates and plays one game. `verbose`: print the map line and the per-turn hashes.
func playGame(seed: UInt64, _ o: Options, verbose: Bool) -> GameReport {
    var generated: GeneratedMap!
    let genTime = clock.measure {
        generated = MapGenerator.generate(MapGenSettings(size: o.size, seed: seed))
    }
    // p3g: `--random` and `--ai` games place tribal villages (none without the rules section).
    var state = GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions,
                                  humanPlayers: [], rules: gameRules, mapSizeName: o.size.rawValue,
                                  placeTribalVillages: o.mode != .scripted)
    // Their tags (the start whose own round placed each one, nil for a shared one) come from
    // placement run again on the same inputs (DESIGN §3.2), so they must name the very sites the
    // game placed.
    var villageSites: [TribalVillageSite]?
    if o.mode != .scripted, gameRules.tribalVillages != nil {
        let sites = DebugTools.tribalVillagePlacement(seed: seed, map: generated.map, startPositions: generated.startPositions,
                                                      rules: gameRules)
        let placed = DebugTools.tribalVillages(in: state)
        guard sites.map(\.hex) == placed else {
            print("error: seed \(seed): placement's tags name \(sites.map(\.hex)), the game placed \(placed)")
            exit(1)
        }
        villageSites = sites
    }
    if o.extraUnits > 0 {
        DebugTools.spawnUnits(count: o.extraUnits, seed: seed, in: &state)
        for i in state.players.indices { state.players[i].gold = 1_000_000 }
    }
    if verbose {
        let land = state.map.tiles.filter(\.isLand).count
        print("map \(o.size.rawValue) \(state.map.width)x\(state.map.height) seed=\(seed) land=\(land) "
            + "(\(land * 100 / state.map.tileCount)%) starts=\(generated.startPositions.count) units=\(state.units.count) "
            + "rules=\(state.rules) mode=\(o.mode.rawValue)")
        print("mapgen: \(genTime)")
        print(String(format: "turn %4d  hash %016llx", state.turn, state.stateHash()))
    }
    checkInvariants(state, "seed \(seed) start")

    var report = GameReport(seed: seed, state: state, narrate: o.narrate && o.mode == .ai, p0: o.p0.rawValue, turns: o.turns,
                            sites: villageSites)
    report.aiPlayers = state.players.indices.filter { $0 != 0 || o.p0 == .ai }
    report.observer.lintDetail = o.lintDetail
    var rng = SplitMix64(seed: seed, salts: 0x5133)
    let lastTurn = state.turn + o.turns - 1
    let checkEveryPhase = o.checkEveryPhase || o.mode == .ai

    report.simTime = clock.measure {
        while state.outcome == nil, state.turn <= lastTurn {
            let turn = state.turn
            let player = state.currentPlayer
            switch o.mode {
            case .random, .scripted:
                // Random mode plans twice, so a city captured in the first round may be razed.
                for _ in 0..<(o.mode == .random ? 2 : 1) {
                    guard state.outcome == nil, state.currentPlayer == player else { break }
                    let planned: [Command] = o.mode == .random
                        ? DebugTools.randomCommands(in: state, rng: &rng)
                        : DebugTools.scriptedCommands(in: state, rng: &rng)
                    for command in planned {
                        guard state.outcome == nil, state.currentPlayer == player else { break }
                        let start = clock.now
                        do {
                            report.tally(try GameEngine.apply(command, by: player, to: &state), turn: turn)
                        } catch {
                            report.rejected += 1
                        }
                        report.commands.add(clock.now - start)
                    }
                }
                guard state.outcome == nil, state.currentPlayer == player else { break }
                let start = clock.now
                do {
                    report.tally(try GameEngine.apply(.endTurn, by: player, to: &state), turn: turn)
                } catch {
                    print("error: seed \(seed): \(player)'s endTurn on turn \(turn) was rejected: \(error)")
                    exit(1)
                }
                report.phases.add(clock.now - start)

            case .ai where player.rawValue == 0 && o.p0 != .ai:
                // A scripted stand-in for a human (`--p0`), then its endTurn.
                var steps: [(command: Command, events: [EventRecord])] = []
                switch o.p0 {
                case .turtle:
                    var turtle = TurtlePlayer(state: state)
                    turtle.play()
                    steps = turtle.steps
                    state = turtle.state
                case .newbie, .shadow:
                    var newbie = NewPlayer(state: state, shadow: o.p0 == .shadow, rush: o.newbieRush)
                    newbie.play()
                    steps = newbie.steps
                    state = newbie.state
                default:
                    for command in DebugTools.scriptedCommands(in: state, rng: &rng) {
                        guard state.outcome == nil, state.currentPlayer == player,
                              let events = try? GameEngine.apply(command, by: player, to: &state) else { continue }
                        steps.append((command, events))
                    }
                }
                for step in steps {
                    report.tally(step.events, turn: turn)
                    report.observer.step(step.command, step.events, by: player, turn: turn, state: state)
                    report.early.step(step.command, step.events, by: player, turn: turn, state: state)
                }
                if o.trace, turn >= o.traceFrom, turn <= o.traceUntil {
                    let cities = state.cities.filter { $0.owner == player }
                    print("t\(turn) \(player) \(o.p0.rawValue): \(steps.count) cmds, \(cities.count) cities, gold \(state.players[0].gold), "
                        + "research \(state.players[0].researching.map { "\($0)" } ?? "-"); "
                        + cities.map { c in "\(c.name) pop \(c.population) " + c.queue.map { "\(state.itemName($0.item)) \($0.progress)" }.joined(separator: "+") }
                        .joined(separator: ", "))
                    if o.traceUnits {
                        for step in steps { print("    cmd \(step.command)") }
                        for u in state.units where u.owner == player {
                            print("    unit \(u.id) \(u.type.rawValue) at \(u.position) hp \(u.hp) \(u.activity.rawValue) dest \(u.destination.map { "\($0)" } ?? "-") charges \(u.charges)")
                        }
                    }
                }
                report.early.p0PhaseEnd(turn: turn, state: state)
                if state.outcome == nil, state.currentPlayer == player {
                    do {
                        let events = try GameEngine.apply(.endTurn, by: player, to: &state)
                        report.tally(events, turn: turn)
                        report.observer.step(.endTurn, events, by: player, turn: turn, state: state)
                        report.early.step(.endTurn, events, by: player, turn: turn, state: state)
                    } catch {
                        print("error: seed \(seed): \(player)'s endTurn on turn \(turn) was rejected: \(error)")
                        exit(1)
                    }
                }

            case .ai:
                var phase: AIPhaseReport?
                let elapsed = clock.measure {
                    phase = AIPlayer.playPhase(&state, player: player, narrate: o.narrate, profile: o.profile)
                }
                guard let phase else { break }
                report.ai.add(elapsed)
                if o.profile { report.profile.add(phase.stepTimes, total: elapsed, label: "seed \(seed) t\(turn) \(player)") }
                if turn >= 140 { report.aiLate.add(elapsed) }
                report.commandCount += phase.result.steps.count
                report.observer.plan(phase, player: player, turn: turn, state: state)
                report.early.plan(phase, player: player, turn: turn)
                for step in phase.result.steps {
                    report.tally(step.events, turn: turn)
                    report.observer.step(step.command, step.events, by: player, turn: turn, state: state)
                    report.early.step(step.command, step.events, by: player, turn: turn, state: state)
                }
                report.rejected += phase.rejections.count
                for rejection in phase.rejections where report.rejections.count < 20 {
                    report.rejections.append(rejection.description)
                }
                if phase.hitCommandCap { report.capHits += 1 }
                if state.outcome == nil, state.currentPlayer == player {
                    print("error: seed \(seed): \(player)'s AI phase on turn \(turn) did not end with endTurn "
                        + "(\(phase.result.steps.count) steps)")
                    exit(1)
                }
                if o.trace, turn >= o.traceFrom, turn <= o.traceUntil {
                    let cities = state.cities.filter { $0.owner == player }
                    let posture = phase.posture.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
                    print("t\(turn) \(player) \(posture) rival \(phase.rival?.description ?? "-")  "
                        + "\(phase.result.steps.count) cmds, \(attacks(phase.result)) attacks, \(cities.count) cities, "
                        + "pop \(cities.reduce(0) { $0 + $1.population }), "
                        + "\(state.militaryUnitCount(of: player)) military, \(state.players[player.rawValue].gold) gold, "
                        + String(format: "%.3f ms", milliseconds(elapsed)) + "; " + phase.planSummary + "; "
                        + cities.map { c in
                            "\(c.name) " + (c.queue.first.map { "\(state.itemName($0.item)) \($0.progress)" } ?? "idle")
                                + (c.queue.count > 1 ? "+\(c.queue.count - 1)" : "") + " +\(c.storedProgress)"
                        }.joined(separator: ", "))
                    if o.traceUnits {
                        for step in phase.result.steps {
                            switch step.command {
                            case .endTurn, .setQueue, .setFocus, .setResearch: continue
                            case let .moveUnit(id, to):
                                let ends = step.events.compactMap { r -> HexCoord? in
                                    if case let .unitMoved(u, _, path) = r.event, u == id { return path.last }
                                    return nil
                                }.last
                                print("    cmd move \(id) → \(to)" + (ends.map { $0 == to ? "" : " (stopped at \($0))" } ?? " (no move)"))
                            default: print("    cmd \(step.command)")
                            }
                        }
                        let view = state.view(for: player)
                        for u in view.units {
                            let near = view.visibleForeignUnits.filter { !$0.type.isCivilian && view.distance($0.position, u.position) <= 2 }
                            print("    unit \(u.id) \(u.type.rawValue) at \(u.position) hp \(u.hp) \(u.activity.rawValue) moves \(u.movesLeft)"
                                + (near.isEmpty ? "" : " foreign≤2: " + near.map { "\($0.type.rawValue)@\($0.position)" }.joined(separator: " ")))
                        }
                        for city in view.knownCities where city.owner != player {
                            if view.isVisible(city.position) { print("    sees city \(city.name) of \(city.owner) at \(city.position) hp \(city.hp)+\(city.wallHP) pop \(city.population)\(city.walls ? " walls" : "")") }
                        }
                    }
                    for step in phase.result.steps {
                        for record in step.events {
                            guard case let .combat(attacker, defender, from, to, ranged, dealt, taken) = record.event else { continue }
                            func name(_ c: Combatant) -> String {
                                switch c {
                                case let .unit(id): state.unit(id).map { "\($0.type) \(id) (\($0.hp) HP)" } ?? "\(id) (dead)"
                                case let .city(id): state.city(id).map { "city \($0.name) (\($0.hp)+\($0.wallHP) HP)" } ?? "city \(id)"
                                }
                            }
                            print("    \(ranged ? "ranged" : "melee") \(name(attacker)) \(from) → \(name(defender)) \(to): "
                                + "dealt \(dealt), took \(taken)")
                        }
                    }
                }
            }
            if checkEveryPhase {
                checkInvariants(state, "seed \(seed) turn \(turn) after \(player)'s phase")
                report.phasesChecked += 1
            }
            report.villages.phaseEnd(state)
            if o.mode == .ai {
                report.observer.endOfPhase(player, turn: turn, state: state)
                report.early.endOfPhase(player, turn: turn, state: state)
            }
            if state.turn != turn {
                if state.players.indices.contains(where: { a in
                    state.players.indices.contains { b in a < b && state.isAtWar(PlayerID(a), PlayerID(b)) }
                }) {
                    report.turnsAtWar += 1
                }
                if verbose && !o.narrate { print(String(format: "turn %4d  hash %016llx", state.turn, state.stateHash())) }
                if o.narrate && o.mode == .ai && state.turn % 10 == 0 {
                    for p in state.players where p.isAlive {
                        let cities = state.cities.filter { $0.owner == p.id }
                        let view = state.view(for: p.id)
                        let army = view.units.filter { u in
                            !u.type.isCivilian && state.rules.unit(u.type).unitClass != .recon
                                && !cities.contains { $0.position == u.position }
                        }
                        print("t\(state.turn) \(p.id) status: \(cities.count) cities, population \(cities.reduce(0) { $0 + $1.population }), "
                            + "\(state.militaryUnitCount(of: p.id)) military (\(army.count) outside cities), \(p.gold) gold "
                            + "(\(view.income().net >= 0 ? "+" : "")\(view.income().net)/turn), \(p.knownTechs.count) techs, score \(state.score(of: p.id)); "
                            + cities.map { c in
                                "\(c.name) \(c.population)" + (c.has("walls") ? "W" : "") + " "
                                    + (c.queue.first.map { state.itemName($0.item) } ?? "idle")
                            }.joined(separator: ", "))
                    }
                }
                if state.turn % 10 == 0 { checkInvariants(state, "seed \(seed) turn \(state.turn)") }
            }
        }
    }
    checkInvariants(state, "seed \(seed) the end")
    report.observer.finish(state)
    report.state = state
    return report
}

if options.starts {
    StartQuality.run(options, rules: gameRules)
    exit(0)
}

// p3g G9 (`--placement-timing`): tribal village placement's cost on `--games` maps of `--size`
// from `--seed`: `newGame` with and without placement, interleaved, the best of 5 each; the
// difference is what placement adds to a new game (release: at most 5 ms on Large).
if options.placementTiming {
    guard gameRules.tribalVillages != nil else {
        print("error: --placement-timing: the rules have no tribalVillages section")
        exit(1)
    }
    var costs: [Double] = []
    for g in 0..<options.games {
        let seed = options.seed &+ UInt64(g)
        let generated = MapGenerator.generate(MapGenSettings(size: options.size, seed: seed))
        var best = [Double.infinity, Double.infinity]
        var placed = 0
        for _ in 0..<5 {
            for place in [false, true] {
                var state: GameState?
                let elapsed = clock.measure {
                    state = GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions, humanPlayers: [],
                                              rules: gameRules, mapSizeName: options.size.rawValue, placeTribalVillages: place)
                }
                best[place ? 1 : 0] = min(best[place ? 1 : 0], milliseconds(elapsed))
                if place, let state { placed = DebugTools.tribalVillages(in: state).count }
            }
        }
        let cost = max(0, best[1] - best[0])
        costs.append(cost)
        print(String(format: "seed %llu: newGame %.3f ms, with placement %.3f ms: placement %.3f ms, %d placed", seed, best[0], best[1],
                     cost, placed))
    }
    print(String(format: "placement on %@, %d maps (best of 5 each): mean %.3f ms, max %.3f ms [G9: max ≤ 5 ms in release]",
                 options.size.rawValue as NSString, costs.count, costs.reduce(0, +) / Double(max(1, costs.count)), costs.max() ?? 0))
    exit(0)
}

if options.games == 1 {
    let report = playGame(seed: options.seed, options, verbose: true)
    let state = report.state
    print("simulated \(options.turns) turns, ended in turn \(state.turn) after \(state.phaseCount) phases, in \(report.simTime); "
        + "\(report.events) events, \(report.rejected) commands rejected"
        + (options.checkEveryPhase || options.mode == .ai ? "; invariants held after all \(report.phasesChecked) phases" : ""))
    switch options.mode {
    case .random, .scripted:
        print("commands: \(report.commands.summary)")
        print("endTurn + next phase start: \(report.phases.summary)")
    case .ai:
        print("AI phases: \(report.ai.summary); \(report.commandCount) commands, \(report.capHits) phases hit the command cap")
        for rejection in report.rejections { print("  rejected: \(rejection)") }
    }
    print("events: \(report.counts.summary)")
    print(report.warLine)
    if !report.state.rules.eras.isEmpty { print(report.eraLine) }
    if !report.state.rules.resources.isEmpty { print(report.resourceLine) }
    if report.villages.enabled { print(report.villageLine) }
    print("outcome: " + report.outcomeLine)
    for player in state.players { print(report.playerLine(player)) }
    if options.mode == .ai {
        if options.early {
            if let data = try? JSONEncoder().encode(report.early.record), let json = String(data: data, encoding: .utf8) {
                print("EARLY " + json)
            }
            EarlySummary.print([report.early.record])
        }
        if options.profile { report.profile.print() }
        print("AI ms per phase from turn 140: \(report.aiLate.summary)")
        for player in state.players { print("  \(player.id) pathologies: \(report.observer.lint[player.id.rawValue].summary)") }
    }

    // Knowledge cost on the final state (M1 §12.7 budget: visibility + memory ≤ 0.2 ms per
    // command on Large): one player's visibility plus everyone's memory, and the worst case.
    var probe = state
    let reps = 200
    let one = clock.measure { for _ in 0..<reps { DebugTools.refreshKnowledge(of: probe.currentPlayer, in: &probe) } }
    let all = clock.measure { for _ in 0..<reps { DebugTools.refreshAllKnowledge(in: &probe) } }
    print(String(format: "knowledge update: one player %.4f ms, all %d players %.4f ms",
                 milliseconds(one) / Double(reps), probe.players.count, milliseconds(all) / Double(reps)))

    // Pathfinding cost on the final state: each unit (up to 200) to a random tile at most 5,
    // then 15, tiles away, with its owner's knowledge.
    var pathRNG = SplitMix64(seed: options.seed, salts: 0x9A7)
    for radius in [5, 15] {
        var searches = 0, found = 0
        let elapsed = clock.measure {
            for unit in state.units.prefix(200) {
                let dq = pathRNG.nextInt(below: 2 * radius + 1) - radius
                let low = max(-radius, -dq - radius), high = min(radius, -dq + radius)
                let dr = low + pathRNG.nextInt(below: high - low + 1)
                guard let target = state.map.normalize(HexCoord(q: unit.position.q + dq, r: unit.position.r + dr)) else { continue }
                searches += 1
                if Pathfinder.findPath(for: unit, to: target, in: state) != nil { found += 1 }
            }
        }
        print(String(format: "pathfinding within %d: %d searches (%d found), mean %.4f ms", radius, searches, found,
                     milliseconds(elapsed) / Double(max(searches, 1))))
    }
    // PlayerView query costs on the final state (M1 §12.6): movement fields of up to 100 units,
    // settle scores of every tile for each living player, danger maps.
    do {
        var fields = 0
        let fieldTime = clock.measure {
            for unit in state.units.prefix(100) {
                fields += state.view(for: unit.owner).movementField(for: unit.id).isEmpty ? 0 : 1
            }
        }
        let living = state.players.filter(\.isAlive)
        var best = 0
        let settleTime = clock.measure {
            for player in living {
                let view = state.view(for: player.id)
                for t in 0..<view.tileCount { best = max(best, view.settleScore(at: view.coord(at: t))) }
            }
        }
        var threatened = 0
        let dangerTime = clock.measure {
            for player in living { threatened += state.view(for: player.id).dangerMap().filter { $0 > 0 }.count }
        }
        print(String(format: "movementField: %d fields, mean %.4f ms; settleScore over all %d tiles: mean %.3f ms per player "
                     + "(best %d); dangerMap: mean %.3f ms per player", fields, milliseconds(fieldTime) / Double(max(fields, 1)),
                     state.map.tileCount, milliseconds(settleTime) / Double(max(living.count, 1)), best,
                     milliseconds(dangerTime) / Double(max(living.count, 1))))
    }
    var finalHash: UInt64 = 0
    let hashReps = 20
    let hashTime = clock.measure { for _ in 0..<hashReps { finalHash = state.stateHash() } }
    print(String(format: "stateHash: %.3f ms", milliseconds(hashTime) / Double(hashReps)))
    print(String(format: "final hash %016llx", finalHash))
} else {
    var ai = Timings(), aiLate = Timings()
    var profile = Profile()
    var threeCities = 0, warBy80 = 0, captureBy150 = 0, rejected = 0, capHits = 0
    var lint = Lint()
    // Against a stand-in in player 0's seat (`--p0`): games the AIs won, player 0 won or nobody
    // won; cities AIs took from player 0 and player 0 took from AIs; wars on player 0.
    var aiWins = 0, p0Wins = 0, p0Eliminated = 0, takenFromP0 = 0, takenByP0 = 0, warsOnP0 = 0, gamesWithWarOnP0 = 0
    var combined = SplitMix64(seed: options.seed, salts: UInt64(options.games))
    var hashes: UInt64 = 0
    var earlyRecords: [EarlyRecord] = []
    var villages = TribalVillageTotals()
    let total = clock.measure {
        for g in 0..<options.games {
            let seed = options.seed &+ UInt64(g)
            let report = playGame(seed: seed, options, verbose: false)
            let hash = report.state.stateHash()
            print("game \(g + 1)/\(options.games) seed \(seed): outcome \(report.outcomeLine); \(report.state.phaseCount) phases; "
                + String(format: "AI ms per phase mean %.3f, max %.3f; ", report.ai.mean, report.ai.max)
                + "\(report.commandCount) commands, \(report.rejected) rejected, \(report.capHits) command-cap phases; "
                + String(format: "final hash %016llx", hash))
            print("  " + report.warLine)
            if !report.state.rules.eras.isEmpty { print("  " + report.eraLine) }
            if !report.state.rules.resources.isEmpty { print("  " + report.resourceLine) }
            if report.villages.enabled {
                print("  " + report.villageLine)
                villages.add(report.villages, standing: DebugTools.tribalVillages(in: report.state).count)
            }
            for player in report.state.players { print(report.playerLine(player)) }
            for rejection in report.rejections.prefix(5) { print("  rejected: \(rejection)") }
            if options.mode == .ai {
                for player in report.state.players { print("  \(player.id) pathologies: \(report.observer.lint[player.id.rawValue].summary)") }
                for p in report.aiPlayers { lint.merge(report.observer.lint[p]) }
            }
            if options.mode == .ai, options.p0 != .ai {
                switch report.state.outcome {
                case let .victory(winner, _)? where winner == PlayerID(0): p0Wins += 1
                case .victory?: aiWins += 1
                default: break
                }
                if !report.state.players[0].isAlive { p0Eliminated += 1 }
                takenFromP0 += report.tallies[0].lost
                takenByP0 += report.tallies[0].captured
                let wars = report.wars.filter { $0.on == PlayerID(0) }.count
                warsOnP0 += wars
                if wars > 0 { gamesWithWarOnP0 += 1 }
            }
            if options.early {
                earlyRecords.append(report.early.record)
                if let data = try? JSONEncoder().encode(report.early.record), let json = String(data: data, encoding: .utf8) {
                    print("EARLY " + json)
                }
            }
            ai.merge(report.ai)
            aiLate.merge(report.aiLate)
            if options.profile { profile.merge(report.profile) }
            if report.everyoneFoundedThreeBy60 { threeCities += 1 }
            if report.warBy80 { warBy80 += 1 }
            if report.captureBy150 { captureBy150 += 1 }
            rejected += report.rejected
            capHits += report.capHits
            hashes ^= hash &* (combined.next() | 1)
        }
    }
    let n = options.games
    func pct(_ k: Int) -> String { "\(k)/\(n) (\(k * 100 / n)%)" }
    print("played \(n) games (\(options.size.rawValue), \(options.turns) turns, seeds \(options.seed)–\(options.seed &+ UInt64(n - 1))) "
        + "in \(total)")
    if options.mode == .ai {
        print(String(format: "AI phases: %d, mean %.3f ms, max %.3f ms; %d commands rejected; %d phases hit the command cap",
                     ai.count, ai.mean, ai.max, rejected, capHits))
        print(String(format: "AI phases from turn 140: %d, mean %.3f ms, max %.3f ms", aiLate.count, aiLate.mean, aiLate.max))
        print("pathologies (all AI players): \(lint.summary)")
        if options.profile { profile.print() }
        if options.p0 != .ai {
            print("against \(options.p0.rawValue) p0: AIs won \(aiWins), p0 won \(p0Wins), p0 eliminated \(p0Eliminated); "
                + "wars on p0 \(warsOnP0) (in \(gamesWithWarOnP0) games); cities taken from p0 \(takenFromP0), taken by p0 \(takenByP0)")
        }
        print("balance: every AI founds ≥ 3 cities by turn 60: \(pct(threeCities)) [target ≥ 80%]; "
            + "war by turn 80: \(pct(warBy80)) [≥ 70%]; city captured by turn 150: \(pct(captureBy150)) [≥ 30%]")
    }
    villages.print()
    if options.early { EarlySummary.print(earlyRecords) }
    print(String(format: "games hash %016llx", hashes))
}
