import Testing
@testable import GameCore

// M2 §11 raiders, on an open 30×10 map: two civs and the raiders (player 2). Player 0's
// city is at (2, 5) and player 1's at (8, 5), so the east of the map is out of everyone's sight.

@Suite struct RaiderTests {
    let p0 = PlayerID(0), p1 = PlayerID(1), raider = PlayerID(2)

    func world() -> (GameState, CityID) {
        let map = openMap(width: 30, height: 10)
        let players = [
            Player(id: p0, name: "P0", isHuman: true, tileCount: map.tileCount, gold: 100),
            Player(id: p1, name: "P1", isHuman: false, tileCount: map.tileCount, gold: 100),
            Player(id: raider, name: "Raiders", isHuman: false, tileCount: map.tileCount, kind: .raiders),
        ]
        var state = GameState(seed: 7, map: map, players: players, rules: .standard)
        state.raiders = RaiderState()
        let city = addCity(&state, p0, at: hex(2, 5))
        _ = addCity(&state, p1, at: hex(8, 5))
        refreshKnowledge(&state)
        return (state, city)
    }

    func placeCamp(_ state: inout GameState, at h: HexCoord, turn: Int = 1) -> Int {
        let t = tile(state, h)
        state.raiders!.camps = [RaiderCamp(tile: Int32(t), spawnedTurn: turn, units: [])]
        var fx = Effects()
        fx.touchTile(t)
        state.updateKnowledge(&fx)
        return t
    }

    @Test func theRaidersTakePhasesAndAreAtWarWithEveryone() {
        let (state, _) = world()
        #expect(state.raiderPlayer == raider && state.livingPlayers == [p0, p1])
        #expect(state.players[2].takesPhases && !state.players[2].isMajor)
        #expect(state.isAtWar(p0, raider) && state.isAtWar(p1, raider) && !state.isAtWar(p0, p1))
        #expect(state.upkeep(of: raider) == 0)
        expectSound(state)
    }

    @Test func aCampAppearsOnTurn50OutOfSightAndFarFromCities() throws {
        var (state, _) = world()
        state.turn = 49
        var fx = Effects()
        state.placeRaiderCampIfDue(&fx)
        #expect(state.raiderCamps.isEmpty)
        state.turn = 50
        var again = state
        state.placeRaiderCampIfDue(&fx)
        let camp = try #require(state.raiderCamps.first)
        let t = Int(camp.tile)
        #expect(state.raiderCamps.count == 1 && camp.spawnedTurn == 50)
        #expect(!state.players[0].visible[t] && !state.players[1].visible[t])
        #expect(state.cities.allSatisfy { state.map.distance(index: state.map.index(of: $0.position)!, t) >= 7 })
        var fx2 = Effects()
        again.placeRaiderCampIfDue(&fx2)
        #expect(again.raiderCamps == state.raiderCamps, "placement is deterministic")
        // Not again until the interval passes.
        state.turn = 55
        state.placeRaiderCampIfDue(&fx)
        #expect(state.raiderCamps.count == 1)
        state.turn = 60
        state.placeRaiderCampIfDue(&fx)
        #expect(state.raiderCamps.count == 2)
        let tiles = state.raiderCamps.map { Int($0.tile) }
        #expect(state.map.distance(index: tiles[0], tiles[1]) >= state.rules.raiders!.campMinCampDistance)
        expectSound(state)
    }

    @Test func aCampSpawnsAnAncientRaiderEvery8TurnsUpTo3() throws {
        var (state, _) = world()
        let t = placeCamp(&state, at: hex(24, 5), turn: 50)
        var fx = Effects()
        for turn in 51...90 {
            state.turn = turn
            state.runRaiders(&fx)
        }
        refreshKnowledge(&state)
        // More camps appeared on turns 60–90 meanwhile, each with its own raiders.
        #expect(state.raiderCamps.count > 1 && state.raiderCamps.allSatisfy { !$0.units.isEmpty })
        let camp = try #require(state.raiderCamps.first { Int($0.tile) == t })
        #expect(camp.units.count == 3)
        for id in camp.units {
            let unit = try #require(state.unit(id))
            #expect(unit.owner == raider && [.warrior, .archer].contains(unit.type))
            #expect(state.map.distance(index: t, state.map.index(of: unit.position)!) <= 1)
        }
        expectSound(state)
    }

    @Test func enteringACampClearsItForGold() throws {
        var (state, _) = world()
        let warrior = state.insertUnit(.warrior, owner: p0, at: hex(4, 2))
        refreshKnowledge(&state)
        let t = placeCamp(&state, at: hex(5, 2))
        #expect(state.view(for: p0).knownRaiderCamps == [Int32(t)])
        #expect(state.view(for: p1).knownRaiderCamps.isEmpty, "unseen camps are not known")
        let records = try apply(.moveUnit(unit: warrior, to: hex(5, 2)), &state)
        #expect(state.raiderCamps.isEmpty && state.players[0].gold == 150)
        #expect(events(records).contains(.raiderCampCleared(player: p0, at: hex(5, 2), gold: 50)))
        #expect(state.view(for: p0).knownRaiderCamps.isEmpty)
        expectSound(state)
    }

    @Test func killingACampsGuardInMeleeMovesInAndClearsIt() throws {
        var (state, _) = world()
        let swordsman = state.insertUnit(.swordsman, owner: p0, at: hex(4, 2))
        let guardian = state.insertUnit(.warrior, owner: raider, at: hex(5, 2))
        state.updateUnit(guardian) { $0.hp = 1 }
        refreshKnowledge(&state)
        let t = placeCamp(&state, at: hex(5, 2))
        state.raiders!.camps[0].units = [guardian]
        let records = try apply(.attack(unit: swordsman, target: hex(5, 2)), &state)
        #expect(state.unit(guardian) == nil && state.unit(swordsman)?.position == hex(5, 2))
        #expect(state.raiderCamps.isEmpty && !state.holdsRaiderCamp(t))
        #expect(events(records).contains(.raiderCampCleared(player: p0, at: hex(5, 2), gold: 50)))
        expectSound(state)
    }

    @Test func raidersKillCiviliansRatherThanCaptureThem() throws {
        var (state, _) = world()
        let builder = state.insertUnit(.builder, owner: p0, at: hex(4, 7))
        let warrior = state.insertUnit(.warrior, owner: raider, at: hex(5, 7))
        state.currentPlayer = raider
        _ = try apply(.moveUnit(unit: warrior, to: hex(4, 7)), &state)
        #expect(state.unit(builder) == nil)
        #expect(state.units(of: raider).map(\.type) == [.warrior])
        #expect(state.unit(warrior)?.position == hex(4, 7))
    }

    @Test func aRaiderSacksACityAtZeroHPInsteadOfTakingIt() throws {
        var (state, city) = world()
        updateCity(&state, city) {
            $0.population = 3
            $0.hp = 0
        }
        let warrior = state.insertUnit(.warrior, owner: raider, at: hex(3, 5))
        state.currentPlayer = raider
        refreshKnowledge(&state)
        let records = try apply(.attack(unit: warrior, target: hex(2, 5)), &state)
        let after = try #require(state.city(city))
        #expect(after.owner == p0 && after.population == 2 && after.hp == state.rules.constants.city.maxHP)
        #expect(state.players[0].gold == 50)
        #expect(events(records).contains(.citySacked(city: city, by: raider, gold: 50, at: hex(2, 5))))
        #expect(state.unit(warrior)?.position == hex(3, 5) && state.unit(warrior)?.movesLeft == 0)
        expectSound(state)
    }

    @Test func aCityInRevoltRaisesRebels() throws {
        var (state, city) = world()
        updateCity(&state, city) { $0.stability = -20 }
        state.turn = 10
        var fx = Effects()
        state.runRaiders(&fx)
        refreshKnowledge(&state)
        let rebels = try #require(state.raiders?.rebels)
        #expect(rebels.count == 1 && rebels[0].city == city)
        let unit = try #require(state.unit(rebels[0].unit))
        #expect(unit.owner == raider && state.map.distance(unit.position, hex(2, 5)) <= 2)
        #expect(state.rebelCity(of: unit.id) == city)
        // Not between rebel turns.
        state.turn = 11
        state.runRaiders(&fx)
        #expect(state.raiders?.rebels?.count == 1)
        expectSound(state)
    }
}
