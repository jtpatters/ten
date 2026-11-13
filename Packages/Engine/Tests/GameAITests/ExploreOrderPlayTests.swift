import Foundation
import Testing
@testable import GameAI
@testable import GameCore
import MapGen

// The App's Explore order (GameCore/Queries/UIExplore.swift, M1 §16) played on generated Duel
// maps against the real AI: player 0 founds its capital and leaves everything else alone while
// its Scout explores, driven as the App drives it (GameSession+Explore.swift: at each phase start,
// steps until the Scout's moves are spent, each step a `moveUnit` to where it gets this phase).
// The baseline is a player tapping the cheapest frontier tile whenever the last march ended
// (HeadlessSim's `frontierStep`, and what the 3c testers did by hand).
//
// p3g (M1 §7.7, §16, §17; DESIGN §8.4 G12): `playExplorer(…, tribalVillages: true)` plays the same
// games with the tribal villages the standard rules place (`placeTribalVillages`), which the Scout
// seeks within the rules' `seekTurns`; the order must still explore about as much land.

/// One Scout's run.
struct ExploreRun: CustomStringConvertible {
    var seed: UInt64
    /// Reachable land explored (percent) at turns 10, 20 and 30 (those reached).
    var coverage: [Int] = []
    /// How the order last ended, and in which turn (nil: still exploring).
    var ended: ExploreEnd?
    var endTurn: Int?
    /// Orders a player gave: for the baseline each new march (a tap on the tile and one to
    /// confirm, after Next), for the Explore order the first and each one given again after a stop.
    var orders = 0
    /// Phases that ended with the Scout back within a tile of where it stood two phases before,
    /// having moved in both (turning back over its tracks).
    var reversals = 0
    /// Back and forth: the Scout's last four phase ends alternated between two tiles.
    var oscillations = 0
    /// Steps whose goal replaced one still frontier the Scout could reach and stop on, and the
    /// farthest such jump between goals (tiles).
    var retargets = 0
    var farthestRetarget = 0
    /// Phases the Scout rested to heal.
    var restPhases = 0
    /// Phases the Explore order ended where an enemy it saw when it took its last step could
    /// strike the Scout next (there should be none).
    var exposedPhases = 0
    /// Phases it ended in the reach of enemies its last step brought into view (fog).
    var surprisedPhases = 0
    var warDeclared: Int?
    /// Moves the engine refused (there should be none).
    var refused = 0
    var scoutAlive = true
    /// Good city sites the explorers' walks announced (`exploreFinds`, as the App announces them:
    /// at most one per explorer per turn, none near one announced before), by turn.
    var finds: [(turn: Int, unit: UnitID, find: ExploreFind)] = []
    /// p3g: tribal villages placed (`tribalVillages: true`); every take, by any player (its turn,
    /// tile, taker, and the unit: nil for a city's land); at player 0's phase starts in turns 1–3,
    /// the tribal villages it knew that its Scout could reach within the rules' `seekTurns` turns
    /// of its full moves (turns with none left out).
    var tribalVillagesPlaced = 0
    var tribalVillageTakes: [(turn: Int, at: HexCoord, player: PlayerID, unit: UnitID?)] = []
    var inReach: [(turn: Int, villages: [HexCoord])] = []
    /// Player 0's Scout.
    var scout: UnitID?
    /// Player 0's takes.
    var ownTakes: [(turn: Int, at: HexCoord, player: PlayerID, unit: UnitID?)] { tribalVillageTakes.filter { $0.player == PlayerID(0) } }

    var description: String {
        "seed \(seed): coverage \(coverage.map { "\($0)%" }.joined(separator: "/")), orders \(orders), reversals \(reversals)"
            + ", retargets \(retargets)" + (retargets > 0 ? " (farthest \(farthestRetarget))" : "")
            + (restPhases > 0 ? ", rested \(restPhases)" : "")
            + (oscillations > 0 ? ", oscillations \(oscillations)" : "") + (exposedPhases > 0 ? ", exposed \(exposedPhases)" : "")
            + (surprisedPhases > 0 ? ", surprised \(surprisedPhases)" : "")
            + (warDeclared.map { ", war T\($0)" } ?? "") + (ended.map { ", ended \($0) T\(endTurn ?? 0)" } ?? "")
            + (refused > 0 ? ", refused \(refused)" : "")
            + (scoutAlive ? "" : ", scout lost")
            + (finds.isEmpty ? "" : ", finds " + finds.map { "T\($0.turn) \($0.find.distance) from \($0.find.cityName)" }.joined(separator: ", "))
            + (tribalVillagesPlaced == 0 ? "" : ", tribal villages \(tribalVillagesPlaced) placed, player 0 took "
                + (ownTakes.isEmpty ? "none" : "at " + ownTakes.map { "T\($0.turn)" }.joined(separator: " "))
                + (inReach.first.map { " (\($0.villages.count) in reach on T\($0.turn))" } ?? "")
                + ", the rival \(tribalVillageTakes.count - ownTakes.count)")
    }
}

enum ExplorePolicy {
    case order(ExploreTuning)
    case cheapestTap
}

/// Land tiles a land unit could walk to from `start` over passable land (borders and units
/// aside): the land a Scout could ever see from inside.
func reachableLand(_ state: GameState, from start: HexCoord) -> [Bool] {
    let map = state.map
    var seen = [Bool](repeating: false, count: map.tileCount)
    guard let s = map.index(of: start) else { return seen }
    var queue = [s]
    seen[s] = true
    var head = 0
    while head < queue.count {
        let t = queue[head]
        head += 1
        map.forEachNeighbor(of: t) { n, _ in
            guard !seen[n], state.rules.isPassable(map.tiles[n]) else { return }
            seen[n] = true
            queue.append(n)
        }
    }
    return seen
}

/// An explorer as GameSession+Explore.swift keeps it.
private struct Explorer {
    var id: UnitID
    var exploring = true
    var known: [UnitID] = []
    var goal: HexCoord?
    var resting: Bool? = false
    var ended: ExploreEnd?
}

/// Plays a Duel game to `turns` with player 0's Scout exploring by `policy` and player 1 the
/// real AI. `war`: player 0 declares war on player 1 as soon as it may (once met); `reorder`:
/// after the order ends because of enemies, it is given again in the next phase (the enemies
/// then in sight known). `warriorToo`: the starting Warrior explores too (as both play-testers
/// did), else it fortifies in the capital. `tribalVillages` (p3g): the standard rules place
/// tribal villages in the game (`placeTribalVillages`); without, the same game has none.
func playExplorer(seed: UInt64, turns: Int = 30, policy: ExplorePolicy, war: Bool = false,
                  reorder: Bool = false, warriorToo: Bool = false, tribalVillages: Bool = false) throws -> ExploreRun {
    let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: seed))
    var state = GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions, humanPlayers: [0],
                                  mapSizeName: "duel", placeTribalVillages: tribalVillages)
    let me = PlayerID(0), them = PlayerID(1)
    var run = ExploreRun(seed: seed)
    run.tribalVillagesPlaced = DebugTools.tribalVillages(in: state).count
    /// p3g: the takes among `events`, which began in turn `turn` (read before the command; a take
    /// after a `turnStarted` counts in the turn that started).
    func noteTakes(from turn: Int, _ events: [EventRecord]) {
        var turn = turn
        for record in events {
            switch record.event {
            case let .turnStarted(t): turn = t
            case let .tribalVillageTaken(at, player, unit, _): run.tribalVillageTakes.append((turn, at, player, unit))
            default: break
            }
        }
    }
    let units = state.view(for: me).units
    guard let scout = units.first(where: { $0.type == .scout })?.id,
          let settler = units.first(where: { $0.type == .settler })?.id else { return run }
    run.scout = scout
    let land = reachableLand(state, from: state.unit(scout)!.position)
    let landCount = land.filter { $0 }.count
    noteTakes(from: state.turn, try GameEngine.apply(.foundCity(unit: settler), by: me, to: &state))
    if let city = state.view(for: me).cities.first?.id {
        try GameEngine.apply(.setQueue(city: city, items: [.building("monument"), .unit(.warrior)]), by: me, to: &state)
    }
    var explorers = [Explorer(id: scout)]
    if let warrior = state.view(for: me).units.first(where: { $0.type == .warrior })?.id {
        if warriorToo, case .order = policy {
            explorers.append(Explorer(id: warrior))
            explorers.sort { $0.id < $1.id }
        } else {
            try GameEngine.apply(.fortify(unit: warrior), by: me, to: &state)
        }
    }
    var history: [HexCoord] = []
    if case .order = policy { run.orders = 1 }
    var cheapestTapping = true
    while state.outcome == nil, state.turn <= turns {
        if state.currentPlayer != me {
            let turn = state.turn
            let report = AIPlayer.playPhase(&state, player: state.currentPlayer)
            noteTakes(from: turn, report.result.steps.flatMap(\.events))
            continue
        }
        if war, run.warDeclared == nil, state.relation(me, them).met, state.relation(me, them).stance == .peace {
            try GameEngine.apply(.declareWar(on: them), by: me, to: &state)
            run.warDeclared = state.turn
        }
        if state.view(for: me).unit(scout) == nil { run.scoutAlive = false }
        // p3g: the known tribal villages within the Scout's horizon (the rules' `seekTurns` turns
        // of its full moves) at this phase start.
        if state.turn <= 3, state.unit(scout) != nil {
            let view = state.view(for: me)
            let field = view.movementField(for: scout)
            let horizon = (state.rules.tribalVillages?.seekTurns ?? 0) * state.rules.unit(.scout).moves
            let villages = view.knownTribalVillages.map(Int.init).filter { field[$0] > 0 && Int(field[$0]) <= horizon }
            if !villages.isEmpty { run.inReach.append((state.turn, villages.map { view.coord(at: $0) })) }
        }
        let start = state.unit(scout)?.position
        switch policy {
        case let .order(tuning):
            for e in explorers.indices {
                let id = explorers[e].id
                let isScout = id == scout
                guard explorers[e].exploring || reorder, state.unit(id) != nil else { continue }
                let claimed = explorers.indices.filter { $0 != e && explorers[$0].exploring }.compactMap { explorers[$0].goal }
                let before = state.view(for: me)
                // As GameSession+Explore.swift: steps until it waits, rests or the order ends
                // (asked once more after the last leg, so an enemy that leg revealed ends it).
                // With `reorder`, an order ended by enemies is given again at once (the player
                // taps Explore on the unit the attention queue shows), once per phase.
                var again = reorder
                var reachBefore: [ExploreThreat?] = []
                for _ in 0..<8 {
                    if !explorers[e].exploring, again, state.unit(id) != nil {
                        switch explorers[e].ended {
                        case .enemyInSight?, .enemyReach?:
                            again = false
                            explorers[e] = Explorer(id: id, known: state.view(for: me).enemiesInSight(of: id))
                            if isScout { run.orders += 1 }
                        default: break
                        }
                    }
                    guard explorers[e].exploring else { break }
                    let view = state.view(for: me)
                    guard let unit = view.unit(id) else { break }
                    let order = explorers[e]
                    let step = view.exploreStep(for: id, knownEnemies: order.known, claimed: claimed, goal: order.goal,
                                                resting: order.resting, tuning: tuning)
                    explorers[e].known = order.known.filter { view.enemiesInSight(of: id).contains($0) }
                    let goal: HexCoord?
                    switch step {
                    case let .move(_, g, _), let .wait(g), let .rest(g, _): goal = g
                    case .end: goal = nil
                    }
                    if isScout, let old = order.goal, let goal, goal != old, old != unit.position,
                       let t = view.index(of: old), view.aiFrontier().contains(t) {
                        let field = view.movementField(for: id)
                        if field[t] > 0 {
                            run.retargets += 1
                            run.farthestRetarget = max(run.farthestRetarget, state.map.distance(old, goal))
                        }
                    }
                    guard case let .move(to, g, _) = step else {
                        switch step {
                        case let .end(why):
                            explorers[e].ended = why
                            explorers[e].exploring = false
                            explorers[e].goal = nil
                            if isScout {
                                run.ended = why
                                run.endTurn = state.turn
                            }
                            continue
                        case let .wait(g):
                            explorers[e].goal = g
                            explorers[e].resting = false
                        case let .rest(g, _):
                            explorers[e].goal = g
                            explorers[e].resting = true
                            if isScout { run.restPhases += 1 }
                        case .move: break
                        }
                        break
                    }
                    explorers[e].goal = g
                    explorers[e].resting = false
                    reachBefore = view.exploreThreats(for: unit)
                    do {
                        noteTakes(from: state.turn, try GameEngine.apply(.moveUnit(unit: id, to: to), by: me, to: &state))
                    } catch {
                        run.refused += 1
                        break
                    }
                    guard let after = state.unit(id), after.position != unit.position else { break }
                }
                if isScout, explorers[e].exploring, let unit = state.unit(id), unit.position != start,
                   let t = state.map.index(of: unit.position), state.view(for: me).exploreThreats(for: unit)[t] != nil {
                    if reachBefore.indices.contains(t), reachBefore[t] != nil { run.exposedPhases += 1 } else { run.surprisedPhases += 1 }
                }
                // What the walk found, as GameSession+Explore.swift announces it.
                if !run.finds.contains(where: { $0.unit == id && $0.turn == state.turn }),
                   let find = state.view(for: me).exploreFinds(since: before, announced: run.finds.map(\.find.hex)).first {
                    run.finds.append((state.turn, id, find))
                }
            }
        case .cheapestTap:
            let view = state.view(for: me)
            if cheapestTapping, let unit = view.unit(scout) {
                let frontier = view.aiFrontier()
                let going = unit.destination.flatMap { view.index(of: $0) }.map { frontier.contains($0) } ?? false
                if !going, unit.movesLeft > 0, !unit.zocStopped {
                    let field = view.movementField(for: scout)
                    if let goal = frontier.filter({ field[$0] > 0 }).min(by: { (field[$0], $0) < (field[$1], $1) }) {
                        run.orders += 1
                        noteTakes(from: state.turn, try GameEngine.apply(.moveUnit(unit: scout, to: view.coord(at: goal)), by: me, to: &state))
                    } else {
                        run.ended = .explored(closedLand: [])
                        run.endTurn = state.turn
                        cheapestTapping = false
                    }
                }
            }
        }
        if let unit = state.unit(scout) {
            let n = history.count
            if n >= 2, history[n - 1] != history[n - 2], unit.position != history[n - 1],
               state.map.distance(unit.position, history[n - 2]) <= 1 {
                run.reversals += 1
            }
            if n >= 3, unit.position == history[n - 2], history[n - 1] == history[n - 3], unit.position != history[n - 1] {
                run.oscillations += 1
            }
            history.append(unit.position)
        }
        if [10, 20, 30].contains(state.turn) {
            let explored = state.players[0].explored
            let seen = (0..<state.map.tileCount).filter { land[$0] && explored[$0] }.count
            run.coverage.append(seen * 100 / max(1, landCount))
        }
        noteTakes(from: state.turn, try GameEngine.apply(.endTurn, by: me, to: &state))
    }
    return run
}

@Suite struct ExploreOrderPlayTests {
    static let seeds: [UInt64] = Array(1...16) + [23, 42, 77, 101]

    /// One Explore order sees more reachable land by turn 20 than tapping the cheapest frontier
    /// tile after every march (summed over a few Duel games), without turning back and forth,
    /// and the Scout lives.
    @Test func oneOrderExploresMoreThanTapping() throws {
        var order = 0, taps = 0
        for seed: UInt64 in [1, 4, 7, 11] {
            let explore = try playExplorer(seed: seed, turns: 20, policy: .order(.standard))
            let tapping = try playExplorer(seed: seed, turns: 20, policy: .cheapestTap)
            order += explore.coverage.last ?? 0
            taps += tapping.coverage.last ?? 0
            #expect(explore.oscillations == 0 && explore.exposedPhases == 0 && explore.scoutAlive, "\(explore)")
            #expect(explore.orders == 1 && tapping.orders > 10, "\(explore) / \(tapping)")
        }
        #expect(order > taps, "Explore \(order) against tapping \(taps)")
    }

    /// At war from the first meeting: the order ends when enemy units come into the Scout's sight
    /// and never ends a phase within the reach of the enemies it sees; given again after each
    /// stop, the Scout lives and goes on exploring.
    @Test func atWarItStopsForEnemiesAndKeepsOutOfReach() throws {
        var stops = 0
        for seed: UInt64 in [2, 5] {
            let run = try playExplorer(seed: seed, turns: 25, policy: .order(.standard), war: true, reorder: true)
            #expect(run.warDeclared != nil, "\(run)")
            #expect(run.exposedPhases == 0 && run.oscillations == 0 && run.scoutAlive, "\(run)")
            stops += run.orders - 1
        }
        #expect(stops > 0)
    }

    // MARK: Tribal villages (p3g)

    /// Plays `game` on each of `seeds` concurrently (debug builds play slowly); the runs in seed
    /// order.
    static func play(_ seeds: [UInt64], _ game: @escaping @Sendable (UInt64) throws -> ExploreRun) async throws -> [ExploreRun] {
        try await withThrowingTaskGroup(of: (Int, ExploreRun).self) { group in
            for (i, seed) in seeds.enumerated() { group.addTask { (i, try game(seed)) } }
            var runs = [ExploreRun?](repeating: nil, count: seeds.count)
            for try await (i, run) in group { runs[i] = run }
            return runs.compactMap { $0 }
        }
    }

    /// DESIGN §9: the order reaches a seeded tribal village by turn 5 (the standard rules'
    /// placement). On each of `seeds` where player 0 knows at its phase start in turn 1 or 2 a
    /// tribal village its Scout can reach within the rules' `seekTurns` turns of its moves, the
    /// Scout has taken one by the end of turn 5, unless the rival took every such one first (some
    /// seeds qualify: 6 of 20 under the standard rules); and over all of them, the Scout has
    /// taken one by turn 5 in at least half the games (18 of 20).
    @Test func theOrderReachesASeededTribalVillageByTurn5() async throws {
        let runs = try await Self.play(Self.seeds) { try playExplorer(seed: $0, turns: 5, policy: .order(.standard), tribalVillages: true) }
        func scoutTook(_ run: ExploreRun) -> Bool { run.ownTakes.contains { $0.turn <= 5 && $0.unit == run.scout } }
        let qualifying = runs.filter { $0.inReach.contains { $0.turn <= 2 } }
        try #require(!qualifying.isEmpty, "no seed of \(runs.count) has one in reach by turn 2")
        for run in qualifying {
            let rivalTookThem = run.inReach.filter { $0.turn <= 2 }.flatMap(\.villages).allSatisfy { hex in
                run.tribalVillageTakes.contains { $0.at == hex && $0.player != PlayerID(0) }
            }
            #expect(scoutTook(run) || rivalTookThem, "\(run)")
        }
        for run in runs { #expect(run.oscillations == 0 && run.exposedPhases == 0 && run.refused == 0 && run.scoutAlive, "\(run)") }
        let reached = runs.filter(scoutTook).count
        print("the Scout took a tribal village by turn 5 in \(reached) of \(runs.count) games; one in reach by turn 2 in "
            + "\(qualifying.count) (by its Scout in \(qualifying.filter(scoutTook).count))")
        #expect(2 * reached >= runs.count, "the Scout took one by turn 5 in \(reached) of \(runs.count) games")
    }

    /// G12 (DESIGN §8.4): over `seeds`, the mean reachable land explored by turn 20 under the
    /// Explore order with the standard rules' tribal villages is at least the mean in the same
    /// games without them, less 5 points; with them the Scout lives, never oscillates and never
    /// ends a phase exposed, and player 0 takes some.
    @Test func tribalVillagesCostTheOrderLittleCoverage() async throws {
        async let withVillages = Self.play(Self.seeds) { try playExplorer(seed: $0, turns: 20, policy: .order(.standard), tribalVillages: true) }
        async let without = Self.play(Self.seeds) { try playExplorer(seed: $0, turns: 20, policy: .order(.standard)) }
        let (runs, plain) = try await (withVillages, without)
        let covered = runs.map { $0.coverage.last ?? 0 }.reduce(0, +), plainCovered = plain.map { $0.coverage.last ?? 0 }.reduce(0, +)
        let n = runs.count
        print("G12: reachable land explored by turn 20, mean of \(n) Duel games: with tribal villages "
            + "\(Double(covered) / Double(n))%, without \(Double(plainCovered) / Double(n))% "
            + "(player 0 took \(runs.map(\.ownTakes.count).reduce(0, +)) of \(runs.map(\.tribalVillagesPlaced).reduce(0, +)) placed)")
        for (run, base) in zip(runs, plain) where run.coverage.last != base.coverage.last {
            print("    \(run)\n      without: \(base.coverage.map { "\($0)%" }.joined(separator: "/"))")
        }
        #expect(covered >= plainCovered - 5 * n, "with \(covered), without \(plainCovered), over \(n) games")
        #expect(plain.allSatisfy { $0.tribalVillagesPlaced == 0 } && runs.allSatisfy { $0.tribalVillagesPlaced > 0 })
        #expect(runs.map(\.ownTakes.count).reduce(0, +) > 0)
        for run in runs { #expect(run.oscillations == 0 && run.exposedPhases == 0 && run.refused == 0 && run.scoutAlive, "\(run)") }
    }

    /// Tuning aid: `EXPLORE_TUNING=6,16` prints the coverage of the baseline and of each
    /// weighting (tiles per turn) on `seeds`, with the reversals and retargets; `EXPLORE_KEEP=0,1`
    /// plays each weighting with each goal-keeping margin (turns; default 1, the App's);
    /// `EXPLORE_WAR=1` plays them at war; `EXPLORE_WARRIOR=1` lets the Warrior explore too.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EXPLORE_TUNING"] != nil))
    func compareWeightings() throws {
        let env = ProcessInfo.processInfo.environment
        let weights = env["EXPLORE_TUNING"]?.split(separator: ",").compactMap { Int($0) } ?? []
        let keeps = env["EXPLORE_KEEP"]?.split(separator: ",").compactMap { Int($0) } ?? [1]
        let war = env["EXPLORE_WAR"] != nil, warriorToo = env["EXPLORE_WARRIOR"] != nil
        var lines: [String] = []
        let variants = weights.flatMap { w in keeps.map { k in ("order \(w)/turn keep \(k)", ExplorePolicy.order(ExploreTuning(tilesPerTurn: w, keepGoalTurns: k))) } }
        for (name, policy) in [("cheapest tap", ExplorePolicy.cheapestTap)] + variants {
            let runs = try Self.seeds.map { try playExplorer(seed: $0, policy: policy, war: war, reorder: war, warriorToo: warriorToo) }
            let mean = (0..<3).map { i in runs.map { $0.coverage.count > i ? $0.coverage[i] : 0 }.reduce(0, +) / runs.count }
            lines.append("\(name): mean \(mean.map { "\($0)%" }.joined(separator: "/")), orders \(runs.map(\.orders).reduce(0, +)), "
                         + "reversals \(runs.map(\.reversals).reduce(0, +)), retargets \(runs.map(\.retargets).reduce(0, +)) "
                         + "(farthest \(runs.map(\.farthestRetarget).max() ?? 0)), oscillations \(runs.map(\.oscillations).reduce(0, +)), "
                         + "exposed \(runs.map(\.exposedPhases).reduce(0, +)), surprised \(runs.map(\.surprisedPhases).reduce(0, +)), "
                         + "rested \(runs.map(\.restPhases).reduce(0, +)), lost \(runs.filter { !$0.scoutAlive }.count), "
                         + "finds \(runs.map(\.finds.count).reduce(0, +)) (T3-T16 \(runs.map { $0.finds.filter { (3...16).contains($0.turn) }.count }.reduce(0, +)))")
            for run in runs { lines.append("    \(run)") }
        }
        print(lines.joined(separator: "\n"))
    }
}
