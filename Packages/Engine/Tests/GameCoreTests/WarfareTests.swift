import Foundation
import Testing
@testable import GameCore

// Zone of control (M1 §8.5), city capture, razing and the Palace (M1 §5), civilian capture
// (M1 §7.3).

/// Three rows: a road along row 0, mountains along row 1 except (5,1), open row 2. A unit at
/// (5,1) puts a zone of control on (5,0) and (6,0), which every path along row 0 crosses.
func corridorState() -> GameState {
    var map = openMap(width: 12, height: 3)
    for col in 0..<12 where col != 5 {
        map[hex(col, 1)] = Tile(terrain: .grassland, elevation: .mountains)
    }
    var state = makeTestState(map: map)
    setWar(&state, PlayerID(0), PlayerID(1))
    return state
}

@Suite struct ZoneOfControlTests {
    /// Entering a tile next to an enemy military unit ends the unit's movement for the phase;
    /// it keeps its moves and may attack (M1 §8.5).
    @Test func zoneOfControlStopsMovementButNotAttacks() throws {
        var state = makeWarState()
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let enemy = state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 1))
        let records = try apply(.moveUnit(unit: w, to: hex(4, 1)), &state)
        #expect(events(records) == [.unitMoved(unit: w, from: hex(3, 1), path: [hex(4, 1)])])
        var unit = try #require(state.unit(w))
        #expect(unit.position == hex(4, 1) && unit.movesLeft == 1 && unit.zocStopped && unit.destination == nil)
        #expect(throws: CommandError.zoneOfControl) { try apply(.moveUnit(unit: w, to: hex(3, 1)), &state) }
        let view = state.view(for: PlayerID(0))
        #expect(view.reachableTiles(for: w).isEmpty)
        #expect(view.attackOptions(for: w) == [AttackOption(target: hex(5, 1), defender: .unit(enemy), from: hex(4, 1), moveCost: 0)])
        let attack = try apply(.attack(unit: w, target: hex(5, 1)), &state)
        #expect(combatEvent(attack) != nil)
        expectSound(state)

        try nextTurn(&state)
        unit = try #require(state.unit(w))
        #expect(!unit.zocStopped && unit.movesLeft == 2)
    }

    /// `attackOptions` picks the cheapest tile to attack from, entering the zone of control
    /// (M1 §8.4); moving there and attacking works.
    @Test func moveIntoTheZoneOfControlThenAttack() throws {
        var state = makeWarState()
        let w = state.addUnit(.warrior, owner: PlayerID(0), at: hex(2, 1))
        let enemy = state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        let options = state.view(for: PlayerID(0)).attackOptions(for: w)
        #expect(options == [AttackOption(target: hex(4, 1), defender: .unit(enemy), from: hex(3, 1), moveCost: 1)])
        try apply(.moveUnit(unit: w, to: hex(3, 1)), &state)
        #expect(state.unit(w)!.zocStopped && state.unit(w)!.movesLeft == 1)
        let records = try apply(.attack(unit: w, target: hex(4, 1)), &state)
        #expect(combatEvent(records)?.attacker == .unit(w))
        #expect(state.unit(w).map { $0.movesLeft == 0 } ?? true)
    }

    /// Paths treat zone-of-control tiles as turn-ending, from the enemies the player sees
    /// (M1 §8.5); the move keeps its standing order across the stops.
    @Test func pathsEndTheTurnInZonesOfControl() throws {
        var state = corridorState()
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(3, 0))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 1))
        let path = try #require(Pathfinder.findPath(for: state.unit(scout)!, to: hex(9, 0), in: state))
        #expect(path.steps.map(\.hex) == [hex(4, 0), hex(5, 0), hex(6, 0), hex(7, 0), hex(8, 0), hex(9, 0)])
        #expect(path.steps.map(\.turn) == [1, 1, 2, 3, 3, 3])

        var peace = state
        peace.updateRelation(PlayerID(0), PlayerID(1)) { $0.stance = .peace }
        let free = try #require(Pathfinder.findPath(for: peace.unit(scout)!, to: hex(9, 0), in: peace))
        #expect(free.steps.map(\.turn) == [1, 1, 1, 2, 2, 2])

        // Executing it: stopped at (5,0) with a move left, the order standing.
        let records = try apply(.moveUnit(unit: scout, to: hex(9, 0)), &state)
        #expect(events(records) == [.unitMoved(unit: scout, from: hex(3, 0), path: [hex(4, 0), hex(5, 0)])])
        var unit = try #require(state.unit(scout))
        #expect(unit.position == hex(5, 0) && unit.movesLeft == 1 && unit.zocStopped && unit.destination == hex(9, 0))
        try nextTurn(&state)
        unit = try #require(state.unit(scout))
        #expect(unit.position == hex(6, 0) && unit.movesLeft == 2 && unit.zocStopped && unit.destination == hex(9, 0))
        try nextTurn(&state)
        unit = try #require(state.unit(scout))
        #expect(unit.position == hex(9, 0) && unit.destination == nil && !unit.zocStopped)
        expectSound(state)
    }

    /// A zone of control the plan did not expect (an unseen enemy) stops the move and clears
    /// the order (M1 §8.6).
    @Test func unexpectedZoneOfControlInterruptsTheMove() throws {
        var state = corridorState()
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(3, 0))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 1))
        state.players[0].visible = TileBitSet(count: state.map.tileCount) // the enemy unseen
        let records = try apply(.moveUnit(unit: scout, to: hex(6, 0)), &state)
        #expect(events(records) == [.unitMoved(unit: scout, from: hex(3, 0), path: [hex(4, 0), hex(5, 0)]),
                                    .moveInterrupted(unit: scout, at: hex(5, 0))])
        let unit = try #require(state.unit(scout))
        #expect(unit.position == hex(5, 0) && unit.movesLeft == 1 && unit.zocStopped && unit.destination == nil)
        expectSound(state)
    }

    /// Enemy cities exert a zone of control; units at peace do not (M1 §8.5, §9). Civilians
    /// are land units too.
    @Test func zonesOfControlComeFromEnemiesAtWar() throws {
        var state = makeWarState(width: 16, height: 10)
        addCity(&state, PlayerID(1), at: hex(6, 3))
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(3, 3))
        try apply(.moveUnit(unit: scout, to: hex(5, 3)), &state)
        #expect(state.unit(scout)!.position == hex(5, 3) && state.unit(scout)!.zocStopped && state.unit(scout)!.movesLeft == 1)

        var peace = makeTestState(map: openMap())
        let walker = peace.addUnit(.scout, owner: PlayerID(0), at: hex(3, 0))
        let settler = peace.addUnit(.settler, owner: PlayerID(0), at: hex(3, 2))
        peace.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        var war = peace
        setWar(&war, PlayerID(0), PlayerID(1))

        try apply(.moveUnit(unit: walker, to: hex(5, 0)), &peace)
        #expect(peace.unit(walker)!.position == hex(5, 0) && !peace.unit(walker)!.zocStopped)
        try apply(.moveUnit(unit: walker, to: hex(5, 0)), &war)
        #expect(war.unit(walker)!.position == hex(4, 0) && war.unit(walker)!.zocStopped)
        try apply(.moveUnit(unit: settler, to: hex(4, 2)), &war)
        #expect(war.unit(settler)!.zocStopped && war.unit(settler)!.movesLeft == 1)
        #expect(throws: CommandError.zoneOfControl) { try apply(.moveUnit(unit: settler, to: hex(3, 2)), &war) }
        expectSound(war)
    }
}

@Suite struct CaptureTests {
    /// A melee unit attacking a city at 0 HP takes it without combat (M1 §5): the garrison is
    /// destroyed, civilians captured, the city loses a citizen, its Walls, queue and stored
    /// progress, keeps its other buildings and territory, and has 50 HP. It may be razed in
    /// that phase: removed, its tiles unowned, improvements kept.
    @Test func meleeUnitsTakeCitiesAtZeroHP() throws {
        var state = makeWarState(width: 24, height: 12, players: 3)
        let mine = addCity(&state, PlayerID(0), at: hex(3, 3))
        addCity(&state, PlayerID(1), at: hex(18, 6))
        let city = addCity(&state, PlayerID(1), at: hex(10, 6))
        state.map[hex(11, 6)].improvement = .farm
        updateCity(&state, city) { c in
            c.population = 3
            c.buildings = ["monument", "walls"]
            c.wallHP = 0
            c.hp = 0
            c.queue = [QueueEntry(.unit(.warrior), progress: 12)]
            c.storedProgress = 7
        }
        let garrison = state.addUnit(.warrior, owner: PlayerID(1), at: hex(10, 6))
        let builder = state.addUnit(.builder, owner: PlayerID(1), at: hex(10, 6))
        state.updateUnit(builder) { $0.charges = 1 }
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 6))
        refreshKnowledge(&state)
        let name = state.city(city)!.name

        let preview = try #require(state.view(for: PlayerID(0)).combatPreview(attacker: .unit(a), target: hex(10, 6), from: hex(9, 6)))
        #expect(preview.capturesCity && preview.killPairs == preview.rollPairs && preview.deathPairs == 0)

        let records = try apply(.attack(unit: a, target: hex(10, 6)), &state)
        let captured = UnitID(state.units.map(\.id.rawValue).max()!)
        #expect(events(records) == [
            .unitKilled(unit: garrison, type: .warrior, owner: PlayerID(1), at: hex(10, 6)),
            .unitMoved(unit: a, from: hex(9, 6), path: [hex(10, 6)]),
            .unitCaptured(old: builder, new: captured, type: .builder, from: PlayerID(1), to: PlayerID(0), at: hex(10, 6)),
            .cityCaptured(city: city, name: name, from: PlayerID(1), to: PlayerID(0), at: hex(10, 6)),
        ])
        let taken = try #require(state.city(city))
        #expect(taken.owner == PlayerID(0) && taken.originalOwner == PlayerID(1))
        #expect(taken.population == 2 && taken.buildings == ["monument"] && taken.wallHP == 0 && taken.hp == 50)
        #expect(taken.queue.isEmpty && taken.storedProgress == 0 && taken.capturedTurn == 1)
        let winner = try #require(state.unit(a))
        #expect(winner.position == hex(10, 6) && winner.movesLeft == 0 && winner.hp == 100 && winner.xp == 0)
        let newBuilder = try #require(state.unit(captured))
        #expect(newBuilder.owner == PlayerID(0) && newBuilder.charges == 1 && newBuilder.movesLeft == 0)
        let code = Int32(city.rawValue + 1)
        let territory = state.tileCity.indices.filter { state.tileCity[$0] == code }
        #expect(territory.count == 7 && territory.allSatisfy { state.tileOwner($0) == PlayerID(0) })
        // The loser knows its tiles changed hands.
        #expect(territory.allSatisfy { state.players[1].memory.tileOwner[$0] == 1 })
        #expect(state.players[0].capital == mine && state.players[1].capital != city)
        expectSound(state)

        let razed = try apply(.razeCity(city: city), &state)
        #expect(events(razed) == [.cityRazed(city: city, name: name, owner: PlayerID(0), at: hex(10, 6))])
        #expect(state.city(city) == nil && territory.allSatisfy { state.tileCity[$0] == 0 })
        #expect(state.map[hex(11, 6)].improvement == .farm && state.unit(a)?.position == hex(10, 6))
        expectSound(state)
    }

    /// Only melee and antiCavalry units capture: a ranged attack on a 0-HP city does nothing
    /// more, and recon units never attack cities (M1 §5, §7, §8.3).
    @Test func onlyMeleeAndAntiCavalryUnitsCapture() throws {
        var state = makeWarState(width: 16, height: 10, players: 3)
        addCity(&state, PlayerID(1), at: hex(14, 2))
        let city = addCity(&state, PlayerID(1), at: hex(6, 4))
        updateCity(&state, city) { $0.hp = 0 }
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(4, 4))
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(5, 4))
        let spearman = state.addUnit(.spearman, owner: PlayerID(0), at: hex(7, 4))
        let records = try apply(.attack(unit: archer, target: hex(6, 4)), &state)
        #expect(events(records) == [.combat(attacker: .unit(archer), defender: .city(city), from: hex(4, 4), to: hex(6, 4),
                                            ranged: true, dealt: 0, taken: 0)])
        #expect(state.city(city)!.owner == PlayerID(1))
        #expect(throws: CommandError.rejected(reason: "Scouts cannot attack cities")) {
            try apply(.attack(unit: scout, target: hex(6, 4)), &state)
        }
        try apply(.attack(unit: spearman, target: hex(6, 4)), &state)
        #expect(state.city(city)!.owner == PlayerID(0))
        expectSound(state)
    }

    /// A player who loses their capital gets the Palace in their largest remaining city (ties:
    /// lower id); regaining the original capital moves it back. Original capitals cannot be
    /// razed (M1 §5).
    @Test func thePalaceMovesAndComesBack() throws {
        var state = makeWarState(width: 24, height: 12, players: 3)
        let mine = addCity(&state, PlayerID(0), at: hex(2, 2))
        let capital = addCity(&state, PlayerID(1), at: hex(10, 3))
        let b = addCity(&state, PlayerID(1), at: hex(16, 3))
        let c = addCity(&state, PlayerID(1), at: hex(16, 9))
        updateCity(&state, b) { $0.population = 4 }
        updateCity(&state, c) { $0.population = 4 }
        updateCity(&state, capital) { c in
            c.population = 2
            c.hp = 0
        }
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 3))
        try apply(.attack(unit: a, target: hex(10, 3)), &state)
        #expect(state.city(capital)!.owner == PlayerID(0) && state.city(capital)!.buildings.isEmpty)
        #expect(state.city(capital)!.population == 1)
        #expect(state.players[1].capital == b && state.city(b)!.has("palace") && !state.city(c)!.has("palace"))
        #expect(state.players[1].originalCapital == capital && state.players[0].capital == mine)
        #expect(state.outcome == nil) // player 2 never founded a city and is alive
        #expect(throws: CommandError.rejected(reason: "original capitals cannot be razed")) {
            try apply(.razeCity(city: capital), &state)
        }
        #expect(!state.view(for: PlayerID(0)).canRaze(capital))
        expectSound(state)

        // Player 1 takes it back: the garrison dies and the Palace returns.
        try endPhases(until: PlayerID(1), &state)
        updateCity(&state, capital) { $0.hp = 0 }
        let back = state.addUnit(.spearman, owner: PlayerID(1), at: hex(11, 3))
        try apply(.attack(unit: back, target: hex(10, 3)), &state)
        #expect(state.unit(a) == nil && state.city(capital)!.owner == PlayerID(1))
        #expect(state.city(capital)!.has("palace") && !state.city(b)!.has("palace"))
        #expect(state.players[1].capital == capital)
        expectSound(state)
    }

    /// A player whose only city falls gets no capital; one who takes a city while having none
    /// gets the Palace there (a player with cities always has a capital).
    @Test func capitalsFollowCities() throws {
        var state = makeWarState(width: 24, height: 12, players: 3)
        let city = addCity(&state, PlayerID(1), at: hex(10, 3))
        updateCity(&state, city) { $0.hp = 0 }
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 3))
        try apply(.attack(unit: a, target: hex(10, 3)), &state)
        #expect(state.players[1].capital == nil && state.players[1].isAlive) // its Settler keeps it in the game
        #expect(state.players[0].capital == city && state.city(city)!.buildings == ["palace"])
        #expect(state.players[0].originalCapital == nil)
        expectSound(state)
    }

    /// Razing is allowed only in the phase of the capture (M1 §5).
    @Test func razingOnlyInThePhaseOfCapture() throws {
        var state = makeWarState(width: 24, height: 12, players: 3)
        let mine = addCity(&state, PlayerID(0), at: hex(2, 2))
        addCity(&state, PlayerID(1), at: hex(18, 6))
        let city = addCity(&state, PlayerID(1), at: hex(10, 6))
        updateCity(&state, city) { $0.hp = 0 }
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 6))
        let window = "only a city captured this phase can be razed"
        #expect(throws: CommandError.rejected(reason: window)) { try apply(.razeCity(city: mine), &state) }
        #expect(throws: CommandError.notYourCity(city)) { try apply(.razeCity(city: city), &state) }
        try apply(.attack(unit: a, target: hex(10, 6)), &state)
        #expect(state.view(for: PlayerID(0)).canRaze(city))
        try nextTurn(&state)
        #expect(!state.view(for: PlayerID(0)).canRaze(city))
        #expect(throws: CommandError.rejected(reason: window)) { try apply(.razeCity(city: city), &state) }
        expectSound(state)
    }
}

@Suite struct CivilianCaptureTests {
    /// A military unit (any class) moving onto enemy civilians captures them at normal cost:
    /// each is removed and the captor gets a new unit with 0 moves; a Settler becomes a Builder
    /// with 2 charges, a Builder keeps its charges (M1 §7.3).
    @Test func militaryUnitsCaptureCiviliansByMovingOntoThem() throws {
        var state = makeWarState()
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(2, 1))
        let settler = state.addUnit(.settler, owner: PlayerID(1), at: hex(4, 1))
        let records = try apply(.moveUnit(unit: scout, to: hex(4, 1)), &state)
        let builder = UnitID(state.units.map(\.id.rawValue).max()!)
        #expect(events(records) == [
            .unitMoved(unit: scout, from: hex(2, 1), path: [hex(3, 1), hex(4, 1)]),
            .unitCaptured(old: settler, new: builder, type: .builder, from: PlayerID(1), to: PlayerID(0), at: hex(4, 1)),
        ])
        #expect(state.unit(settler) == nil && state.unit(scout)!.movesLeft == 1)
        let unit = try #require(state.unit(builder))
        #expect(unit.owner == PlayerID(0) && unit.type == .builder && unit.charges == 2 && unit.movesLeft == 0)
        #expect(unit.position == hex(4, 1))
        expectSound(state)

        // A Builder keeps its charges.
        let theirs = state.addUnit(.builder, owner: PlayerID(1), at: hex(6, 4))
        state.updateUnit(theirs) { $0.charges = 3 }
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(5, 4))
        try apply(.moveUnit(unit: warrior, to: hex(6, 4)), &state)
        let kept = try #require(state.units(at: hex(6, 4)).first { $0.type == .builder })
        #expect(kept.owner == PlayerID(0) && kept.charges == 3 && kept.id != theirs)
        expectSound(state)
    }

    /// Civilians never capture, and nobody captures at peace.
    @Test func civiliansAndPeaceDoNotCapture() throws {
        var state = makeWarState(players: 3)
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(3, 1))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 4))
        state.addUnit(.settler, owner: PlayerID(1), at: hex(4, 1))
        state.addUnit(.settler, owner: PlayerID(2), at: hex(4, 4))
        #expect(throws: CommandError.noPath) { try apply(.moveUnit(unit: builder, to: hex(4, 1)), &state) }
        #expect(throws: CommandError.noPath) { try apply(.moveUnit(unit: warrior, to: hex(4, 4)), &state) }
    }
}
