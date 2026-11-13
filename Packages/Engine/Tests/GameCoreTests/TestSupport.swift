import Foundation
import Testing
@testable import GameCore

// Shared helpers for the GameCore tests.

/// Offset coordinates (column, row) as a hex.
func hex(_ col: Int, _ row: Int) -> HexCoord { OffsetCoord(col: col, row: row).hex }

/// A small map built by hand: flat grassland, with mountains at (5,2), (5,3), (5,4), a forest
/// at (3,6) and a lake at (8,6) (offset coordinates). It does not wrap.
func makeTestMap(width: Int = 12, height: Int = 8) -> HexMap {
    var map = HexMap(width: width, height: height, wrapsX: false, fill: Tile(terrain: .grassland))
    map[hex(5, 2)] = Tile(terrain: .grassland, elevation: .mountains)
    map[hex(5, 3)] = Tile(terrain: .grassland, elevation: .mountains)
    map[hex(5, 4)] = Tile(terrain: .grassland, elevation: .mountains)
    map[hex(3, 6)] = Tile(terrain: .grassland, feature: .forest)
    map[hex(8, 6)] = Tile(terrain: .lake)
    return map
}

/// Where `makeTestState` parks player `i`'s Settler: the map's corners, right column first.
func parkingSpot(_ i: Int, in map: HexMap) -> HexCoord {
    [hex(map.width - 1, map.height - 1), hex(map.width - 1, 0), hex(0, map.height - 1), hex(0, 0)][i % 4]
}

/// A game on `map` (default: the test map) with `players` players, player 0 human, at turn 1 in
/// player 0's phase. Each player gets a Settler parked in a corner (`parkingSpot`), so no one is
/// eliminated for having no cities and no Settlers (M1 §10), and `gold`, so upkeep (M1 §7.1)
/// does not disband the units a test adds.
func makeTestState(width: Int = 12, height: Int = 8, players: Int = 2, map: HexMap? = nil,
                   parkSettlers: Bool = true, gold: Int = 1000, seed: UInt64 = 1,
                   rules: Ruleset = .standard) -> GameState {
    let map = map ?? makeTestMap(width: width, height: height)
    let list = (0..<players).map {
        Player(id: PlayerID($0), name: "P\($0)", isHuman: $0 == 0, tileCount: map.tileCount, gold: gold)
    }
    var state = GameState(seed: seed, map: map, players: list, rules: rules)
    if parkSettlers {
        for i in 0..<players { state.addUnit(.settler, owner: PlayerID(i), at: parkingSpot(i, in: map)) }
    }
    return state
}

/// The id of the Settler `makeTestState` parked for `player`.
func parkedSettler(of player: PlayerID) -> UnitID { UnitID(player.rawValue + 1) }

/// Ends the current phase, then further phases until `player`'s phase has started.
func endPhases(until player: PlayerID, _ state: inout GameState) throws {
    var phases = 0
    repeat {
        try GameEngine.apply(.endTurn, by: state.currentPlayer, to: &state)
        phases += 1
    } while state.currentPlayer != player && state.outcome == nil && phases < 64
}

/// Ends phases until player 0's next phase (the next turn).
func nextTurn(_ state: inout GameState) throws {
    try endPhases(until: PlayerID(0), &state)
}

/// Applies a command as the current player.
@discardableResult
func apply(_ command: Command, _ state: inout GameState) throws -> [EventRecord] {
    try GameEngine.apply(command, by: state.currentPlayer, to: &state)
}

/// Founds a city for `player` at `hex` directly (no Settler, any phase), updating knowledge.
@discardableResult
func addCity(_ state: inout GameState, _ player: PlayerID, at hex: HexCoord) -> CityID {
    var fx = Effects()
    let id = state.foundCity(at: state.map.index(of: hex)!, by: player, &fx)
    state.updateKnowledge(&fx)
    return id
}

/// Changes a city in place (tests set up situations the rules reach only slowly).
func updateCity(_ state: inout GameState, _ id: CityID, _ change: (inout City) -> Void) {
    let index = state.cityIndex(id)!
    change(&state.cities[index])
}

/// Puts two players at war (met) directly, without `declareWar`'s checks.
func setWar(_ state: inout GameState, _ a: PlayerID, _ b: PlayerID) {
    let turn = state.turn
    state.updateRelation(a, b) { relation in
        relation.met = true
        relation.stance = .war
        relation.since = turn
    }
}

/// Recomputes every player's knowledge (after a test changed the state directly).
func refreshKnowledge(_ state: inout GameState) {
    DebugTools.refreshAllKnowledge(in: &state)
}

/// The events of a list, without their audiences.
func events(_ records: [EventRecord]) -> [GameEvent] { records.map(\.event) }

/// Expects the state to keep every invariant.
func expectSound(_ state: GameState, sourceLocation: SourceLocation = #_sourceLocation) {
    let problems = state.checkInvariants()
    #expect(problems.isEmpty, "\(problems)", sourceLocation: sourceLocation)
}

/// Open grassland (no mountains, water or features), not wrapping.
func openMap(width: Int = 12, height: Int = 8) -> HexMap {
    HexMap(width: width, height: height, wrapsX: false, fill: Tile(terrain: .grassland))
}

/// A game on an open map (`openMap`) with players 0 and 1 at war, in player 0's phase of turn 1.
func makeWarState(width: Int = 12, height: Int = 8, players: Int = 2, seed: UInt64 = 1,
                  rules: Ruleset = .standard) -> GameState {
    var state = makeTestState(players: players, map: openMap(width: width, height: height), seed: seed, rules: rules)
    setWar(&state, PlayerID(0), PlayerID(1))
    return state
}

/// The tile index of `hex` in `state`'s map.
func tile(_ state: GameState, _ hex: HexCoord) -> Int { state.map.index(of: hex)! }

/// The single `combat` event of a list of records (nil when there is none or several).
func combatEvent(_ records: [EventRecord]) -> (attacker: Combatant, defender: Combatant, ranged: Bool, dealt: Int, taken: Int)? {
    let all = records.compactMap { record -> (Combatant, Combatant, Bool, Int, Int)? in
        if case let .combat(a, d, _, _, ranged, dealt, taken) = record.event { return (a, d, ranged, dealt, taken) }
        return nil
    }
    guard all.count == 1 else { return nil }
    return (all[0].0, all[0].1, all[0].2, all[0].3, all[0].4)
}

/// Gives tile `hex` to city `id` directly (as border growth would), updating knowledge.
func claimTile(_ state: inout GameState, _ hex: HexCoord, for id: CityID) {
    let t = state.map.index(of: hex)!
    state.tileCity[t] = Int32(id.rawValue + 1)
    var fx = Effects()
    fx.touchTile(t)
    fx.touchAllPlayers(state.players.count)
    state.updateKnowledge(&fx)
}
