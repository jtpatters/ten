import Foundation
import Testing
@testable import GameAI
@testable import GameCore
import MapGen

// Shared helpers for the GameAI tests.

/// Offset coordinates (column, row) as a hex.
func hex(_ col: Int, _ row: Int) -> HexCoord { OffsetCoord(col: col, row: row).hex }

/// A generated game in which every player is an AI.
func aiGame(_ size: MapSize = .duel, seed: UInt64) -> GameState {
    let generated = MapGenerator.generate(MapGenSettings(size: size, seed: seed))
    return GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions, humanPlayers: [],
                             mapSizeName: size.rawValue)
}

/// What a run of AI phases did.
struct AIRun {
    /// Commands of every phase, in order.
    var commands: [[Command]] = []
    var rejections: [AIRejection] = []
    var capHits = 0
    /// Phases that ended without an `endTurn` while the game went on.
    var unfinishedPhases = 0
    /// Invariant problems found after a phase (when checked).
    var brokenInvariants: [String] = []
    /// Cities founded, per player.
    var founded: [Int]
    var warTurns: [Int] = []
    var captureTurns: [Int] = []
    var maxCommandsInAPhase = 0

    init(players: Int) {
        founded = Array(repeating: 0, count: players)
    }
}

/// Plays AI phases until turn `turn` starts or the game ends.
@discardableResult
func playAI(_ state: inout GameState, until turn: Int, checkInvariants: Bool = false) -> AIRun {
    var run = AIRun(players: state.players.count)
    while state.outcome == nil, state.turn < turn {
        let player = state.currentPlayer
        let phaseTurn = state.turn
        let report = AIPlayer.playPhase(&state, player: player)
        run.commands.append(report.result.steps.map(\.command))
        run.rejections += report.rejections
        run.maxCommandsInAPhase = max(run.maxCommandsInAPhase, report.result.steps.count)
        if report.hitCommandCap { run.capHits += 1 }
        if state.outcome == nil, state.currentPlayer == player { run.unfinishedPhases += 1 }
        for step in report.result.steps {
            for record in step.events {
                switch record.event {
                case let .cityFounded(_, _, owner, _): run.founded[owner.rawValue] += 1
                case .warDeclared: run.warTurns.append(phaseTurn)
                case .cityCaptured: run.captureTurns.append(phaseTurn)
                default: break
                }
            }
        }
        if checkInvariants {
            run.brokenInvariants += state.checkInvariants().map { "turn \(phaseTurn) \(player): \($0)" }
        }
        if run.unfinishedPhases > 0 { break }
    }
    return run
}

/// A JSON round trip of a state (decoded with the standard rules).
func roundTrip(_ state: GameState) throws -> GameState {
    let data = try JSONEncoder().encode(state)
    let decoder = JSONDecoder()
    decoder.userInfo[.ruleset] = Ruleset.standard
    return try decoder.decode(GameState.self, from: data)
}

// MARK: Hand-made situations

/// Open grassland (no mountains, water or features), not wrapping.
func openMap(width: Int = 20, height: Int = 12, fill: Tile = Tile(terrain: .grassland)) -> HexMap {
    HexMap(width: width, height: height, wrapsX: false, fill: fill)
}

/// A game on `map` with `players` AI players at turn 1, player 0's phase, each with `gold`,
/// no units and no cities (the test adds them).
func makeState(map: HexMap = openMap(), players: Int = 2, gold: Int = 100, seed: UInt64 = 1) -> GameState {
    let list = (0..<players).map {
        Player(id: PlayerID($0), name: "P\($0)", isHuman: false, tileCount: map.tileCount, gold: gold)
    }
    return GameState(seed: seed, map: map, players: list, rules: .standard, mapSizeName: "duel")
}

/// Founds a city for `player` at `hex` directly, updating knowledge.
@discardableResult
func addCity(_ state: inout GameState, _ player: PlayerID, at hex: HexCoord) -> CityID {
    var fx = Effects()
    let id = state.foundCity(at: state.map.index(of: hex)!, by: player, &fx)
    state.updateKnowledge(&fx)
    return id
}

/// Changes a city in place.
func updateCity(_ state: inout GameState, _ id: CityID, _ change: (inout City) -> Void) {
    let index = state.cityIndex(id)!
    change(&state.cities[index])
}

/// Sets a relation directly (met, stance, since).
func setRelation(_ state: inout GameState, _ a: PlayerID, _ b: PlayerID, war: Bool, since: Int?) {
    state.updateRelation(a, b) { relation in
        relation.met = true
        relation.stance = war ? .war : .peace
        relation.since = since
    }
}

/// Lets `player` see (and so remember) what stands around `spot`: a Scout is put there,
/// knowledge refreshed, and the Scout removed again.
func reveal(_ state: inout GameState, to player: PlayerID, from spot: HexCoord) {
    let id = state.insertUnit(.scout, owner: player, at: spot)
    DebugTools.refreshAllKnowledge(in: &state)
    state.removeUnit(id)
    DebugTools.refreshAllKnowledge(in: &state)
}

/// Recomputes every player's knowledge.
func refreshKnowledge(_ state: inout GameState) {
    DebugTools.refreshAllKnowledge(in: &state)
}

/// Plays one AI phase for the current player and returns its commands.
@discardableResult
func playPhase(_ state: inout GameState) -> (commands: [Command], report: AIPhaseReport) {
    let report = AIPlayer.playPhase(&state, player: state.currentPlayer)
    return (report.result.steps.map(\.command), report)
}

/// The tile index of `hex`.
func tile(_ state: GameState, _ hex: HexCoord) -> Int { state.map.index(of: hex)! }
