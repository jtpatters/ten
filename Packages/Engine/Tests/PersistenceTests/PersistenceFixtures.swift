import Foundation
import MapGen
@testable import GameCore

// Game states for the save tests: one with every field and optional set (round trips and the
// schema fingerprint), and real games played by `DebugTools`' scripted and random players.

/// Offset coordinates (column, row) as a hex.
func at(_ col: Int, _ row: Int) -> HexCoord { OffsetCoord(col: col, row: row).hex }

enum PersistenceFixture {
    /// A 12×9 wrapping map holding every terrain, elevation, feature and improvement, with
    /// rivers and resources, around open grassland.
    static func map() -> HexMap {
        var map = HexMap(width: 12, height: 9, wrapsX: true, fill: Tile(terrain: .grassland))
        for (i, terrain) in Terrain.allCases.enumerated() { map[at(i, 8)] = Tile(terrain: terrain) }
        for (i, feature) in Feature.allCases.enumerated() {
            let terrain: Terrain = switch feature {
            case .reef: .coast
            case .ice: .snow
            case .oasis: .desert
            default: .plains
            }
            map[at(i + 2, 7)] = Tile(terrain: terrain, feature: feature)
        }
        map[at(10, 6)] = Tile(terrain: .tundra, elevation: .hills)
        map[at(11, 6)] = Tile(terrain: .tundra, elevation: .mountains)
        map[at(1, 1)] = Tile(terrain: .grassland, riverEdges: 0b0010_0101, improvement: .farm)
        map[at(2, 0)] = Tile(terrain: .plains, elevation: .hills, improvement: .mine)
        map[at(5, 1)] = Tile(terrain: .plains, riverEdges: 0b0000_1000, improvement: .pasture)
        // M2 resources and resource improvements (M2 §3.1, §4.1).
        map[at(0, 0)] = Tile(terrain: .grassland, improvement: .quarry, resource: .stone)
        map[at(8, 0)] = Tile(terrain: .plains, improvement: .plantation, resource: .wine)
        map[at(9, 3)] = Tile(terrain: .tundra, improvement: .camp, resource: .deer)
        map[at(0, 6)] = Tile(terrain: .coast, improvement: .fishingBoats, resource: .fish)
        map[at(11, 0)] = Tile(terrain: .plains, feature: .forest, improvement: .lumberMill)
        map[at(3, 3)] = Tile(terrain: .plains, resource: .iron)
        map[at(6, 4)] = Tile(terrain: .grassland, improvement: .pasture, resource: .horses)
        // Roads and a pillaged improvement (M2 §3.3), in player 0's sight so it remembers them.
        map[at(1, 1)].road = true
        map[at(1, 2)].road = true
        map[at(2, 1)] = Tile(terrain: .grassland, improvement: .farm)
        map[at(2, 1)].pillaged = true
        return map
    }

    /// Three players in turn 4, in player 1's phase: player 0 (human, Rome) at war with player 1
    /// (a peace proposal from player 1 pending, cool-downs running) and at peace with player 2
    /// since turn 2; four cities, one taken from player 2, every focus, both kinds of queue
    /// item, walls, damage; a unit of every type with every activity, a standing order and a
    /// zone-of-control stop; research with a target; memory of cities, units, territory and
    /// improvements; two tribal villages with gifts given, one remembered by players 0 and 1;
    /// and `outcome` as given.
    static func populated(outcome: GameOutcome? = .victory(player: PlayerID(0), kind: .domination)) -> GameState {
        let map = map()
        let civs: [CivID] = ["rome", "mongols", "mali"]
        let players = (0..<3).map { i in
            Player(id: PlayerID(i), name: "Player \(i)", isHuman: i == 0, tileCount: map.tileCount, civ: civs[i], gold: 40 + 7 * i)
        }
        var state = GameState(seed: 0x5EED_0F_5A7E, map: map, players: players, rules: .standard, mapSizeName: "duel")
        let rome = found(&state, PlayerID(0), at(2, 2))
        let karakorum = found(&state, PlayerID(1), at(7, 2))
        let niani = found(&state, PlayerID(2), at(4, 5))
        let avarga = found(&state, PlayerID(1), at(10, 4))

        let settler = state.addUnit(.settler, owner: PlayerID(0), at: at(1, 3))
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: at(2, 3))
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: at(5, 2))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: at(2, 2))
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: at(3, 1))
        let spearman = state.addUnit(.spearman, owner: PlayerID(0), at: at(4, 5))
        state.addUnit(.warrior, owner: PlayerID(1), at: at(6, 2))
        state.addUnit(.archer, owner: PlayerID(1), at: at(7, 2))
        state.addUnit(.scout, owner: PlayerID(2), at: at(4, 6))
        state.updateUnit(settler) { u in
            u.activity = .sleeping
            u.destination = at(0, 4)
        }
        state.updateUnit(builder) { u in
            u.activity = .skipped
            u.charges = 1
            u.movesLeft = 0
        }
        state.updateUnit(scout) { u in
            u.zocStopped = true
            u.xp = 3
            u.movesLeft = 2
            u.lastActedTurn = 4
            u.hp = 85
        }
        state.updateUnit(warrior) { u in
            u.activity = .fortified
            u.hp = 64
            u.xp = 8
            u.promotions = ["battlecry"]
            u.attacked = true
        }
        state.updateUnit(archer) { $0.activity = .fortifying }
        state.updateUnit(spearman) { u in
            u.lastActedTurn = 3
            u.xp = 3
        }

        city(&state, rome) { c in
            c.population = 4
            c.foodStore = 9
            c.queue = [QueueEntry(.unit(.archer), progress: 12), QueueEntry(.building("library"), progress: 0)]
            c.storedProgress = 3
            c.buildings = ["granary", "monument", "palace", "walls"]
            c.cultureStore = 5
            c.tilesGained = 2
            c.focus = .production
            c.hp = 150
            c.wallHP = 40
            c.lastAttackedPhase = 9
            c.bombarded = true
        }
        city(&state, karakorum) { c in
            c.focus = .food
            c.queue = [QueueEntry(.unit(.warrior), progress: 4)]
        }
        city(&state, niani) { c in
            // Founded by player 2, taken by player 0 in turn 3.
            c.owner = PlayerID(0)
            c.focus = .gold
            c.capturedTurn = 3
            c.buildings = ["monument"]
            c.hp = 60
        }
        city(&state, avarga) { $0.focus = .balanced }
        state.players[2].capital = nil
        state.players[0].knownTechs = ["animalHusbandry", "bronzeWorking", "mining", "pottery"]
        state.players[0].researching = TechID("writing")
        state.players[0].researchTarget = TechID("currency")
        state.players[0].researchProgress = 11
        // Insight credit and Insights fired (M2 §6.2, additive fields).
        state.players[0].techCredit = Array(repeating: 0, count: state.rules.techs.count)
        state.players[0].techCredit![state.rules.techIndex("writing")!] = 18
        state.players[0].insights = ["writing"]
        // Strategic stockpiles (M2 §3.1, an additive field).
        state.setStock(.iron, of: PlayerID(0), to: 12)
        state.setStock(.horses, of: PlayerID(0), to: 4)
        state.players[1].knownTechs = ["mining"]
        state.players[1].researching = TechID("masonry")
        state.players[0].citiesNamed = 2
        state.players[0].lastPhaseStart = 10
        state.players[1].lastPhaseStart = 11
        state.players[2].lastPhaseStart = 9
        state.updateRelation(PlayerID(0), PlayerID(1)) { r in
            r.met = true
            r.stance = .war
            r.since = 2
            r.proposalFrom = PlayerID(1)
            r.aCooldownEnds = 14
            r.bCooldownEnds = 12
        }
        state.updateRelation(PlayerID(0), PlayerID(2)) { r in
            r.met = true
            r.since = 2
        }
        state.turn = 4
        state.phaseCount = 11
        state.currentPlayer = PlayerID(1)
        for index in state.cities.indices { state.assignCitizens(index) }
        // Tribal villages (M1 §7.7): (4,1) in players 0's and 1's sight, (9,1) in no one's.
        for site in [at(4, 1), at(9, 1)] {
            let placed = DebugTools.placeTribalVillage(at: site, in: &state)
            precondition(placed, "PersistenceFixture: no tribal village at \(site.offset)")
        }
        state.tribalVillages?.gifts = [1, 3, 0]
        refreshEverything(&state)
        state.outcome = outcome
        return state
    }

    /// Recomputes every player's visibility and refreshes their memory of every visible tile
    /// (after the fixture changed owners directly).
    static func refreshEverything(_ state: inout GameState) {
        var fx = Effects()
        fx.touchAllPlayers(state.players.count)
        for t in 0..<state.map.tileCount { fx.touchTile(t) }
        state.updateKnowledge(&fx)
    }

    static let outcomes: [GameOutcome?] = [
        .victory(player: PlayerID(0), kind: .domination), .victory(player: PlayerID(1), kind: .lastStanding),
        .victory(player: PlayerID(2), kind: .score), .defeat, nil,
    ]

    @discardableResult
    static func found(_ state: inout GameState, _ player: PlayerID, _ hex: HexCoord) -> CityID {
        var fx = Effects()
        let id = state.foundCity(at: state.map.index(of: hex)!, by: player, &fx)
        state.updateKnowledge(&fx)
        return id
    }

    static func city(_ state: inout GameState, _ id: CityID, _ change: (inout City) -> Void) {
        change(&state.cities[state.cityIndex(id)!])
    }

    // MARK: Played games

    /// A new game on a generated map.
    static func newGame(size: MapSize = .duel, seed: UInt64 = 7) -> GameState {
        let generated = MapGenerator.generate(MapGenSettings(size: size, seed: seed))
        return GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions, mapSizeName: size.rawValue)
    }

    /// Plays phases with every player driven by `DebugTools` (scripted builders, or random
    /// commands with combat and diplomacy) until `turns` turns have started or the game ends.
    /// Each phase's commands depend only on the state and its turn and player, so a game
    /// saved, loaded and played on gives the same states as one played straight through.
    static func play(_ state: inout GameState, untilTurn turns: Int, random: Bool = false) {
        var phases = 0
        while state.outcome == nil, state.turn < turns, phases < 10_000 {
            playPhase(&state, random: random)
            phases += 1
        }
    }

    static func playPhase(_ state: inout GameState, random: Bool = false) {
        let player = state.currentPlayer
        var rng = SplitMix64(seed: state.seed, salts: UInt64(state.turn), UInt64(player.rawValue), 0x5A7E)
        let commands = random ? DebugTools.randomCommands(in: state, rng: &rng) : DebugTools.scriptedCommands(in: state, rng: &rng)
        for command in commands where state.outcome == nil && state.currentPlayer == player {
            _ = try? GameEngine.apply(command, by: player, to: &state)
        }
        if state.outcome == nil, state.currentPlayer == player { _ = try? GameEngine.apply(.endTurn, by: player, to: &state) }
    }
}
