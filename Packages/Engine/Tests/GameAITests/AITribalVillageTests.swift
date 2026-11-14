import Foundation
import Testing
@testable import GameAI
@testable import GameCore
import MapGen

// The AI explorer and tribal villages (p3g; M1 §7.7, §13 Exploring): a known tribal village
// within `tribalVillages.seekTurns` turns' moves comes first, before the rival hunt and the
// frontier; with no frontier left, or no target, an explorer goes to any known one it can reach
// before it retires. The AI knows them only from its memory (`knownTribalVillages`): worlds that
// differ in one it never saw play the same commands (G10), and no GameAI source names
// `DebugTools`. Tribal villages are placed with `DebugTools.placeTribalVillage` here (games with
// the rules' placement: AITribalVillageGameTests); the engine takes them, and the games count
// only the takes its events report, so that a take it missed shows (a unit standing on one
// breaks the invariants; a take with no event, the counts).

private let p0 = PlayerID(0), p1 = PlayerID(1)

/// Player 0's capital at (6,6) with a Warrior in it, player 1's at (20,6), on open land 24×12,
/// at turn 1 in player 0's phase (as `makeState`, with `rules`).
private func tribalVillageWorld(rules: Ruleset = .standard) -> GameState {
    let map = openMap(width: 24, height: 12)
    let players = (0..<2).map { Player(id: PlayerID($0), name: "P\($0)", isHuman: false, tileCount: map.tileCount, gold: 100) }
    var state = GameState(seed: 1, map: map, players: players, rules: rules, mapSizeName: "duel")
    addCity(&state, p0, at: hex(6, 6))
    addCity(&state, p1, at: hex(20, 6))
    state.addUnit(.warrior, owner: p0, at: hex(6, 6))
    return state
}

/// Places a tribal village on each of `villages`, then lets `player` see what stands around each
/// of `lookouts` (`reveal`: a Scout put there for a moment). Twins call it with the same
/// lookouts, so that they have the same units and knowledge but for the tribal villages.
private func place(_ state: inout GameState, _ villages: [HexCoord], lookouts: [HexCoord], for player: PlayerID = p0) throws {
    for village in villages { try #require(DebugTools.placeTribalVillage(at: village, in: &state), "\(village)") }
    for spot in lookouts { reveal(&state, to: player, from: spot) }
}

/// The tile where own unit `id` stops this phase on its way to `goal` (its path by `view`).
private func stop(_ view: PlayerView, _ id: UnitID, toward goal: HexCoord) throws -> HexCoord {
    try #require(view.path(for: id, to: goal)?.steps.last { $0.turn <= 1 }?.hex)
}

/// The rules with tribal villages, sought within `seekTurns` turns' moves.
private func rules(seekTurns: Int) throws -> Ruleset {
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Ruleset.standard.data)) as? [String: Any])
    var section = try #require(json["tribalVillages"] as? [String: Any])
    section["seekTurns"] = seekTurns
    json["tribalVillages"] = section
    return try Ruleset(jsonData: JSONSerialization.data(withJSONObject: json))
}

/// The takes and the gifts the events of `steps` report (`tribalVillageTaken`,
/// `tribalVillageGift`).
private func takesAndGifts(_ steps: [AIStep]) -> (takes: Int, gifts: Int) {
    var takes = 0, gifts = 0
    for record in steps.flatMap(\.events) {
        switch record.event {
        case .tribalVillageTaken: takes += 1
        case .tribalVillageGift: gifts += 1
        default: break
        }
    }
    return (takes, gifts)
}

/// Tribal villages for an AI game, nearer the starts than the rules' placement puts most (its
/// games: AITribalVillageGameTests): for each player, `perPlayer` tiles 4–9 tiles from its
/// Settler that `placeTribalVillage` accepts, at least 4 tiles from one another, drawn in tile
/// order from a stream seeded by the game. Returns them.
@discardableResult
func scatterTribalVillages(_ state: inout GameState, perPlayer: Int = 3) -> [HexCoord] {
    var rng = SplitMix64(seed: state.seed, salts: 0x7E57)
    var placed: [HexCoord] = []
    for player in state.players {
        guard let start = state.units.first(where: { $0.owner == player.id && state.rules.unit($0.type).foundsCity })?.position else {
            continue
        }
        var candidates = state.map.coords(within: 9, of: start).filter { state.map.distance($0, start) >= 4 }
        candidates.sort { state.map.index(of: $0)! < state.map.index(of: $1)! }
        var mine = 0
        while mine < perPlayer {
            let open = candidates.filter { c in placed.allSatisfy { state.map.distance($0, c) >= 4 } }
            guard let pick = open.isEmpty ? nil : open[rng.nextInt(below: open.count)] else { break }
            candidates.removeAll { $0 == pick }
            if DebugTools.placeTribalVillage(at: pick, in: &state) {
                placed.append(pick)
                mine += 1
            }
        }
    }
    return placed
}

/// What a run of AI phases with tribal villages did (as `playAI`).
private struct TribalVillageRun {
    var commands: [[Command]] = []
    var rejections: [AIRejection] = []
    var brokenInvariants: [String] = []
    var unfinishedPhases = 0
    /// Tribal villages taken and gifts given, as the engine's events report them.
    var taken = 0
    var gifts = 0
}

/// Plays AI phases until turn `turn` starts or the game ends, counting the takes and gifts.
private func playWithTribalVillages(_ state: inout GameState, until turn: Int, checkInvariants: Bool = false) -> TribalVillageRun {
    var run = TribalVillageRun()
    while state.outcome == nil, state.turn < turn {
        let player = state.currentPlayer
        let report = AIPlayer.playPhase(&state, player: player)
        let steps = report.result.steps
        run.commands.append(steps.map(\.command))
        run.rejections += report.rejections
        let (takes, gifts) = takesAndGifts(steps)
        run.taken += takes
        run.gifts += gifts
        if checkInvariants { run.brokenInvariants += state.checkInvariants().map { "turn \(state.turn) \(player): \($0)" } }
        if state.outcome == nil, state.currentPlayer == player {
            run.unfinishedPhases += 1
            break
        }
    }
    return run
}

@Suite struct AITribalVillageTests {
    // MARK: The first choice

    /// A known tribal village within three turns' moves comes before the frontier: the Scout
    /// walks toward it as far as it gets, where in the same world without it the Scout heads for
    /// the cheapest frontier tile.
    @Test func aKnownTribalVillageComesBeforeTheFrontier() throws {
        let village = hex(11, 9) // 6 tiles from the Scout
        var plain = tribalVillageWorld()
        let scout = plain.addUnit(.scout, owner: p0, at: hex(6, 7))
        var state = plain
        try place(&state, [village], lookouts: [hex(12, 9)])
        try place(&plain, [], lookouts: [hex(12, 9)])
        let v = state.view(for: p0)
        let cost = v.movementField(for: scout)[tile(state, village)]
        try #require(cost > 0 && cost <= state.rules.points(9) && v.isKnownTribalVillage(village))
        let end = try stop(v, scout, toward: village)
        playPhase(&state)
        playPhase(&plain)
        #expect(state.unit(scout)?.position == end)
        #expect(plain.unit(scout)?.position != end)
    }

    /// …and before the rival hunt: with a met rival none of whose cities is known, the Scout
    /// still walks to the tribal village first (without it, it hunts toward the rival's land).
    @Test func itComesBeforeTheRivalHunt() throws {
        let village = hex(2, 10) // 6 tiles west of the Scout; the rival's land lies east
        var plain = tribalVillageWorld()
        let scout = plain.addUnit(.scout, owner: p0, at: hex(6, 7))
        setRelation(&plain, p0, p1, war: false, since: nil)
        let anchor = tile(plain, hex(19, 6))
        try #require(!plain.players[0].visible[anchor])
        plain.players[0].memory.tileOwner[anchor] = UInt8(p1.rawValue + 1)
        var state = plain
        try place(&state, [village], lookouts: [hex(2, 11)])
        try place(&plain, [], lookouts: [hex(2, 11)])
        let end = try stop(state.view(for: p0), scout, toward: village)
        playPhase(&state)
        playPhase(&plain)
        #expect(state.unit(scout)?.position == end)
        let hunted = try #require(plain.unit(scout)?.position)
        #expect(plain.map.distance(hunted, hex(19, 6)) < plain.map.distance(hex(6, 7), hex(19, 6)))
    }

    /// One beyond the horizon (or with `seekTurns` 0, any) changes nothing while there is
    /// frontier to explore: the same commands as in the world without it.
    @Test func beyondTheHorizonItChangesNothing() throws {
        for (seek, village, lookout) in [(3, hex(16, 6), hex(15, 6)), (0, hex(11, 9), hex(12, 9))] {
            var plain = tribalVillageWorld(rules: try rules(seekTurns: seek))
            plain.addUnit(.scout, owner: p0, at: hex(6, 7))
            var state = plain
            try place(&state, [village], lookouts: [lookout])
            try place(&plain, [], lookouts: [lookout])
            try #require(state.view(for: p0).isKnownTribalVillage(village) && !state.view(for: p0).aiFrontier().isEmpty)
            #expect(playPhase(&state).commands == playPhase(&plain).commands, "seekTurns \(seek), \(village)")
        }
    }

    /// Two Scouts reserve different ones: the first (by id) takes the cheaper for it (ties:
    /// lower index), the second the other.
    @Test func twoScoutsReserveDifferentOnes() throws {
        let north = hex(10, 2), east = hex(12, 7) // 6 tiles from the first Scout, 5 from the second
        var state = tribalVillageWorld()
        let first = state.addUnit(.scout, owner: p0, at: hex(6, 7))
        let second = state.addUnit(.scout, owner: p0, at: hex(7, 7))
        try place(&state, [north, east], lookouts: [hex(10, 1), hex(13, 7)])
        let v = state.view(for: p0)
        let f = v.movementField(for: first)
        try #require(f[tile(state, north)] == f[tile(state, east)] && tile(state, north) < tile(state, east))
        let firstEnd = try stop(v, first, toward: north)
        playPhase(&state)
        #expect(state.unit(first)?.position == firstEnd)
        // The second, as near the one as the other, walks its 3 moves toward the east one.
        try #require(state.map.distance(hex(7, 7), north) == 5 && state.map.distance(hex(7, 7), east) == 5)
        #expect(state.unit(second).map { state.map.distance($0.position, east) } == 2)
    }

    /// The early Warrior that explores in a Scout's place (no Scout, early, at peace) follows
    /// the same rule, within its own three turns' moves.
    @Test func theEarlyWarriorFollowsTheSameRule() throws {
        let village = hex(9, 10) // 4 tiles from the Warrior: 4 of its 6 points
        var plain = tribalVillageWorld()
        let warrior = plain.addUnit(.warrior, owner: p0, at: hex(6, 7))
        var state = plain
        try place(&state, [village], lookouts: [hex(9, 11)])
        try place(&plain, [], lookouts: [hex(9, 11)])
        try #require(state.view(for: p0).units.allSatisfy { state.rules.unit($0.type).unitClass != .recon })
        let end = try stop(state.view(for: p0), warrior, toward: village)
        playPhase(&state)
        playPhase(&plain)
        #expect(state.unit(warrior)?.position == end)
        #expect(plain.unit(warrior)?.position != end)
    }

    // MARK: The retire guard

    /// No frontier left: a Scout goes to a known tribal village it can reach, however far,
    /// where it would otherwise be disbanded (upkeep is paid); with none known it is.
    @Test func withNoFrontierAScoutGoesToOneBeforeRetiring() throws {
        func world(villages: [HexCoord]) throws -> (GameState, UnitID) {
            var state = makeState(map: openMap(width: 24, height: 12))
            addCity(&state, p0, at: hex(6, 6))
            addCity(&state, p1, at: hex(18, 6))
            state.addUnit(.warrior, owner: p0, at: hex(6, 6))
            for i in 0..<3 { state.addUnit(.warrior, owner: p0, at: hex(5 + i, 7)) }
            let scout = state.addUnit(.scout, owner: p0, at: hex(9, 6))
            for t in 0..<state.map.tileCount { state.players[0].explored[t] = true }
            try place(&state, villages, lookouts: [hex(17, 6), hex(21, 2)])
            return (state, scout)
        }
        let village = hex(21, 1) // 15 tiles from the Scout
        var (plain, scout) = try world(villages: [])
        try #require(plain.view(for: p0).income().upkeep > 0 && plain.view(for: p0).aiFrontier().isEmpty)
        #expect(playPhase(&plain).commands.contains(.disband(unit: scout)))
        var (state, _) = try world(villages: [village])
        try #require(state.view(for: p0).isKnownTribalVillage(village))
        let end = try stop(state.view(for: p0), scout, toward: village)
        let commands = playPhase(&state).commands
        #expect(!commands.contains(.disband(unit: scout)))
        #expect(state.unit(scout)?.position == end)
    }

    /// No target: the only frontier is reserved by the first Scout, so the second goes to a
    /// known tribal village it can reach, beyond its horizon, before it would retire.
    @Test func withNoTargetAScoutGoesToOneBeforeRetiring() throws {
        func world(villages: [HexCoord]) throws -> (GameState, UnitID, UnitID) {
            var state = tribalVillageWorld()
            let first = state.addUnit(.scout, owner: p0, at: hex(6, 7))
            let second = state.addUnit(.scout, owner: p0, at: hex(14, 3))
            for t in 0..<state.map.tileCount { state.players[0].explored[t] = true }
            try place(&state, villages, lookouts: [hex(19, 3), hex(21, 10)])
            // One unexplored tile in a corner: its neighbours are the whole frontier.
            let pocket = tile(state, hex(1, 11))
            try #require(!state.players[0].visible[pocket])
            state.players[0].explored[pocket] = false
            return (state, first, second)
        }
        let village = hex(22, 10) // 11 tiles from the second Scout, 17 from the first
        var (plain, first, second) = try world(villages: [])
        let frontier = plain.view(for: p0).aiFrontier()
        try #require(!frontier.isEmpty && frontier.allSatisfy { plain.map.distance(plain.map.coord(at: $0), hex(1, 11)) == 1 })
        let plainCommands = playPhase(&plain).commands
        var (state, _, _) = try world(villages: [village])
        let v = state.view(for: p0)
        try #require(v.isKnownTribalVillage(village) && v.movementField(for: second)[tile(state, village)] > 9)
        let end = try stop(v, second, toward: village)
        let commands = playPhase(&state).commands
        #expect(state.unit(second)?.position == end)
        // The first Scout explores as before.
        func firstMove(_ list: [Command]) -> Command? { list.first { if case .moveUnit(first, _) = $0 { true } else { false } } }
        #expect(firstMove(commands) != nil && firstMove(commands) == firstMove(plainCommands))
        #expect(state.map.distance(try #require(state.unit(first)?.position), hex(1, 11)) < state.map.distance(hex(6, 7), hex(1, 11)))
    }

    /// p3g review: at war, the retire guard seeks one at any distance only as the Explore order
    /// would, ending the phase where no enemy it sees could strike it (nor a remembered enemy
    /// city's bombard): its plain path would stop within an enemy Warrior's reach, so it goes the
    /// safe way. One that lies within that reach is left: the Scout retires as before.
    @Test func atWarTheRetireGuardKeepsOutOfEnemyReach() throws {
        func world(villages: [HexCoord], lookouts: [HexCoord]) throws -> (GameState, UnitID) {
            var state = makeState(map: openMap(width: 24, height: 12))
            addCity(&state, p0, at: hex(6, 6))
            addCity(&state, p1, at: hex(18, 6))
            state.addUnit(.warrior, owner: p0, at: hex(6, 6))
            for i in 0..<3 { state.addUnit(.warrior, owner: p0, at: hex(5 + i, 7)) }
            let scout = state.addUnit(.scout, owner: p0, at: hex(9, 6))
            for t in 0..<state.map.tileCount { state.players[0].explored[t] = true }
            try place(&state, villages, lookouts: lookouts)
            setRelation(&state, p0, p1, war: true, since: 1)
            state.addUnit(.warrior, owner: p1, at: hex(12, 6))
            return (state, scout)
        }
        let far = hex(21, 1) // 15 tiles from the Scout
        var (state, scout) = try world(villages: [far], lookouts: [hex(17, 6), hex(21, 2)])
        let v = state.view(for: p0)
        let unit = try #require(state.unit(scout))
        let threats = v.exploreThreats(for: unit)
        try #require(v.isKnownTribalVillage(far) && v.aiFrontier().isEmpty && v.income().upkeep > 0)
        try #require(v.isAtWar(with: p1) && v.isVisible(hex(12, 6)) && threats[tile(state, far)] == nil)
        // By the plain path it would stop within the Warrior's reach.
        let plainEnd = try stop(v, scout, toward: far)
        try #require(threats[tile(state, plainEnd)] != nil)
        let safe = threats.map { $0 == nil }
        let safeEnd = try #require(v.aiPath(for: scout, to: far, mayStop: safe)?.steps.last { $0.turn <= 1 }?.hex)
        let commands = playPhase(&state).commands
        #expect(!commands.contains(.disband(unit: scout)))
        let after = try #require(state.unit(scout)?.position)
        #expect(after == safeEnd && after != plainEnd && threats[tile(state, after)] == nil)
        #expect(state.map.distance(after, far) < state.map.distance(hex(9, 6), far))

        // One within the Warrior's reach: none is left, so the Scout is disbanded (upkeep is paid).
        let near = hex(13, 7)
        var (inReach, scout2) = try world(villages: [near], lookouts: [hex(13, 8)])
        let w = inReach.view(for: p0)
        let second = try #require(inReach.unit(scout2))
        try #require(w.isKnownTribalVillage(near) && w.exploreThreats(for: second)[tile(inReach, near)] != nil)
        #expect(playPhase(&inReach).commands.contains(.disband(unit: scout2)))
    }

    // MARK: Fairness (G10)

    /// Hand-made twins: a tribal village the AI never saw, nearer its Scout than the one it
    /// knows (the first choice), or the only one with no frontier left (the retire guard),
    /// changes no command.
    @Test func aTribalVillageNeverSeenChangesNoCommand() throws {
        // The first choice: one known 6 tiles off, a hidden one 4 tiles off.
        var a = tribalVillageWorld()
        a.addUnit(.scout, owner: p0, at: hex(6, 7))
        try place(&a, [hex(11, 9)], lookouts: [hex(12, 9)])
        var b = a
        try place(&b, [hex(9, 10)], lookouts: [])
        try #require(!b.view(for: p0).isKnownTribalVillage(hex(9, 10)))
        try #require(AIFairnessTests.sameKnowledge(a, b, p0) && a.stateHash() != b.stateHash())
        #expect(playPhase(&a).commands == playPhase(&b).commands)
        // The retire guard: nothing left to explore, none known.
        var c = makeState(map: openMap(width: 24, height: 12))
        addCity(&c, p0, at: hex(6, 6))
        addCity(&c, p1, at: hex(18, 6))
        for i in 0..<4 { c.addUnit(.warrior, owner: p0, at: hex(5 + i, 7)) }
        let scout = c.addUnit(.scout, owner: p0, at: hex(9, 6))
        for t in 0..<c.map.tileCount { c.players[0].explored[t] = true }
        reveal(&c, to: p0, from: hex(17, 6))
        var d = c
        try place(&d, [hex(13, 10)], lookouts: [])
        try #require(!d.players[0].visible[tile(d, hex(13, 10))] && AIFairnessTests.sameKnowledge(c, d, p0))
        let commands = playPhase(&c).commands
        #expect(commands == playPhase(&d).commands)
        #expect(commands.contains(.disband(unit: scout)))
    }

    /// G10 over whole games: Duel games with tribal villages (`scatterTribalVillages`), at
    /// several turns, for each player whose phase comes up: a twin with one more tribal village
    /// the player never saw (at least 7 tiles from all it has, within an explorer's horizon of a
    /// Scout where it can be) plays the same commands. Some comparisons must have the AI seeking
    /// (a known one within its Scout's horizon).
    @Test func hiddenTribalVillagesChangeNoCommandInGames() async throws {
        @Sendable func compare(seed: UInt64, stops: [Int]) -> (compared: Int, seeking: Int, failures: [String]) {
            var state = aiGame(seed: seed)
            scatterTribalVillages(&state)
            var compared = 0, seeking = 0
            var failures: [String] = []
            for stop in stops {
                _ = playWithTribalVillages(&state, until: stop)
                guard state.outcome == nil else { break }
                for _ in 0..<state.players.count {
                    let viewer = state.currentPlayer
                    let a = state
                    let far = AIFairnessTests.farFromViewer(a, viewer)
                    let v = a.view(for: viewer)
                    let scouts = v.units.filter { a.rules.unit($0.type).unitClass == .recon }.map(\.position)
                    func rank(_ t: Int) -> Int {
                        let d = scouts.map { a.map.distance($0, a.map.coord(at: t)) }.min() ?? 99
                        return d <= 9 ? d : 99 + t
                    }
                    var b = a
                    let spots = (0..<a.map.tileCount).filter(far).sorted { (rank($0), $0) < (rank($1), $1) }
                    guard let hidden = spots.first(where: { DebugTools.placeTribalVillage(at: a.map.coord(at: $0), in: &b) }) else { continue }
                    guard !b.players[viewer.rawValue].visible[hidden], AIFairnessTests.sameKnowledge(a, b, viewer) else {
                        failures.append("seed \(seed) turn \(state.turn): the twin leaks to \(viewer)")
                        continue
                    }
                    if v.units.contains(where: { u in
                        a.rules.unit(u.type).unitClass == .recon
                            && v.knownTribalVillages.contains { a.map.distance(u.position, a.map.coord(at: Int($0))) <= 9 }
                    }) { seeking += 1 }
                    var x = a, y = b
                    let commandsA = playPhase(&x).commands
                    let commandsB = playPhase(&y).commands
                    if commandsA != commandsB {
                        let first = zip(commandsA, commandsB).first { $0 != $1 }.map { "\($0.0) vs \($0.1)" } ?? "lengths differ"
                        failures.append("seed \(seed) turn \(state.turn) \(viewer): a hidden tribal village changed the commands; first difference: \(first)")
                    }
                    compared += 1
                    // On with world A.
                    state = x
                    guard state.outcome == nil else { break }
                }
            }
            return (compared, seeking, failures)
        }
        async let one = compare(seed: 1, stops: [2, 4, 7, 11])
        async let two = compare(seed: 2, stops: [3, 5, 8, 14])
        async let three = compare(seed: 3, stops: [2, 4, 6, 20])
        let all = [await one, await two, await three]
        for failure in all.flatMap(\.failures) { Issue.record(Comment(rawValue: failure)) }
        let compared = all.reduce(0) { $0 + $1.compared }
        #expect(compared >= 12, "only \(compared) phases compared")
        #expect(all.reduce(0) { $0 + $1.seeking } >= 2, "too few comparisons with the AI seeking a known tribal village")
    }

    // MARK: Knowledge only

    /// The AI learns of tribal villages only from its memory: no GameAI source, nor the
    /// HeadlessSim newbie (`NewPlayer.swift`), names `DebugTools` (DESIGN §3.7).
    @Test func theAIReadsTribalVillagesOnlyFromMemory() throws {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ai = engine.appendingPathComponent("Sources/GameAI")
        let names = try FileManager.default.contentsOfDirectory(atPath: ai.path).filter { $0.hasSuffix(".swift") }.sorted()
        let files = names.map { ai.appendingPathComponent($0) } + [engine.appendingPathComponent("Sources/HeadlessSim/NewPlayer.swift")]
        try #require(names.contains("AICivilians.swift") && files.count >= 8)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("DebugTools"), "\(file.lastPathComponent) names DebugTools")
        }
        let explorer = try String(contentsOf: ai.appendingPathComponent("AICivilians.swift"), encoding: .utf8)
        #expect(explorer.contains("knownTribalVillages"))
    }

    // MARK: Games

    /// AI against AI on a Duel map with tribal villages, to turn 60, twice: every phase ends,
    /// no command is refused, the invariants hold, both runs play the same commands and end with
    /// the same hash; the explorers take most of them, each take (an event) gives one gift, and
    /// every one placed was taken or still stands. Saved at turn 30 and loaded, the game goes on
    /// to turn 45 exactly as the uninterrupted one.
    @Test func aiGamesWithTribalVillages() async throws {
        @Sendable func game(until turn: Int, checkInvariants: Bool) -> (GameState, TribalVillageRun, Int) {
            var state = aiGame(seed: 7)
            let placed = scatterTribalVillages(&state).count
            let run = playWithTribalVillages(&state, until: turn, checkInvariants: checkInvariants)
            return (state, run, placed)
        }
        async let first = game(until: 61, checkInvariants: true)
        async let second = game(until: 61, checkInvariants: false)
        var saved = aiGame(seed: 7)
        scatterTribalVillages(&saved)
        _ = playWithTribalVillages(&saved, until: 30)
        var loaded = try roundTrip(saved)
        #expect(loaded == saved)
        var straight = saved
        _ = playWithTribalVillages(&straight, until: 45)
        _ = playWithTribalVillages(&loaded, until: 45)
        #expect(loaded.turn == 45 && loaded.stateHash() == straight.stateHash())
        let (state, run, placed) = await first
        let (again, rerun, _) = await second
        #expect(run.unfinishedPhases == 0)
        #expect(run.rejections.isEmpty, "\(run.rejections.prefix(5))")
        #expect(run.brokenInvariants.isEmpty, "\(run.brokenInvariants.prefix(5))")
        #expect(state.outcome != nil || state.turn == 61)
        #expect(run.commands == rerun.commands && state.stateHash() == again.stateHash())
        try #require(placed >= 4, "only \(placed) placed")
        #expect(2 * run.taken >= placed, "\(run.taken) of \(placed) taken by turn 60")
        let standing = DebugTools.tribalVillages(in: state).count
        #expect(run.gifts == run.taken && run.taken + standing == placed,
                "\(placed) placed, \(run.taken) taken, \(run.gifts) gifts, \(standing) standing")
    }

    // MARK: Cost (run by hand)

    /// The AI phase's cost with tribal villages (DESIGN §9 G9): Duel AI games, seeds 1–10 to
    /// turn 60 (`AI_TIMING_SEEDS`, `AI_TIMING_TURNS`), under C0 (the standard rules without the
    /// section), under the standard rules with none placed (the AI seeks nothing: as C0, but for
    /// the checks), and under the standard rules with `scatterTribalVillages` (the engine takes
    /// them); the three interleaved game by game, their order turning. Prints each one's mean AI ms per phase, its slowest
    /// phase and its explore step's mean. In release:
    /// `AI_TIMING=1 swift test -c release -Xswiftc -enable-testing --filter aiPhaseCost`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AI_TIMING"] != nil))
    func aiPhaseCost() throws {
        let env = ProcessInfo.processInfo.environment
        let seeds = UInt64(env["AI_TIMING_SEEDS"] ?? "") ?? 10
        let turns = Int(env["AI_TIMING_TURNS"] ?? "") ?? 60
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Ruleset.standard.data)) as? [String: Any])
        json.removeValue(forKey: "tribalVillages")
        let c0 = try Ruleset(jsonData: JSONSerialization.data(withJSONObject: json))
        struct Tally {
            var name: String
            var phases = 0, taken = 0
            var total = Duration.zero, explore = Duration.zero, slowest = Duration.zero
        }
        func play(seed: UInt64, arm: Int, into tally: inout Tally) {
            let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: seed))
            var state = GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions, humanPlayers: [],
                                          rules: arm == 0 ? c0 : .standard, mapSizeName: MapSize.duel.rawValue)
            if arm == 2 { scatterTribalVillages(&state) }
            let clock = ContinuousClock()
            while state.outcome == nil, state.turn <= turns {
                let player = state.currentPlayer
                let start = clock.now
                let report = AIPlayer.playPhase(&state, player: player, profile: true)
                let time = clock.now - start
                tally.phases += 1
                tally.total += time
                tally.slowest = max(tally.slowest, time)
                for (step, t) in report.stepTimes where step == "explore" { tally.explore += t }
                if arm == 2 { tally.taken += takesAndGifts(report.result.steps).takes }
                if state.outcome == nil, state.currentPlayer == player { break }
            }
        }
        var tallies = [Tally(name: "C0 (no section)"), Tally(name: "standard, none placed"), Tally(name: "standard, scattered")]
        for seed in 1...seeds {
            // Interleaved, the order turning, so that the machine's load falls on all alike.
            for k in 0..<3 {
                let arm = (k + Int(seed % 3)) % 3
                play(seed: seed, arm: arm, into: &tallies[arm])
            }
        }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        func mean(_ d: Duration, _ n: Int) -> Double { ms(d) / Double(max(1, n)) }
        print("AI phase cost, Duel seeds 1–\(seeds) to turn \(turns):")
        for t in tallies {
            print("  \(t.name): \(t.phases) phases, AI mean \(String(format: "%.4f", mean(t.total, t.phases))) ms, "
                + "max \(String(format: "%.3f", ms(t.slowest))) ms; explore step mean "
                + "\(String(format: "%.4f", mean(t.explore, t.phases))) ms; \(t.taken) tribal villages taken")
        }
        let base = mean(tallies[0].total, tallies[0].phases)
        print("  ratio to C0: none placed \(String(format: "%.3f", mean(tallies[1].total, tallies[1].phases) / base)), "
            + "scattered \(String(format: "%.3f", mean(tallies[2].total, tallies[2].phases) / base))")
        #expect(tallies[2].taken > 0)
    }
}
