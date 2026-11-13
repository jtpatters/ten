import Foundation
import Testing
@testable import GameAI
@testable import GameCore
import MapGen

// p3b ai-settler-escort (M1 §13 Safety). In the iPhone play-test a human Scout sleeping near the
// AI's way froze its Settler from T21 to T35 and the AI kept one city all game: every route ended
// a phase within 2 tiles of the Scout, the only fighter was the city's garrison (never an
// escort), and nothing built one. HeadlessSim showed the same with a Settler waiting inside its
// garrisoned city, where no escort can stand (one military unit per tile): 45 turns.

private let p0 = PlayerID(0)
private let p1 = PlayerID(1)

/// The world of these tests: a strip of land (rows 4–8: grassland, plains on rows 5 and 7) in
/// the ocean, player 0's city at (3,6) with a Warrior garrison and a Settler, its Scout far east;
/// player 1 (the "human", at peace and met) with a city at (21,6) and a Scout at `scout`. Every
/// way east from the city ends its first phase within 2 tiles of a Scout at (5,6) (bar a tile
/// north of the city, no nearer its sites); the good sites lie east (the land west of the city
/// is too close to it).
private func strip(settler: HexCoord = hex(3, 6), scout: HexCoord = hex(5, 6), gold: Int = 200,
                   war: Bool = false, ownScout: HexCoord = hex(17, 4)) -> (GameState, UnitID, UnitID) {
    var map = HexMap(width: 24, height: 12, wrapsX: false)
    for t in 0..<map.tileCount where (4...8).contains(map.coord(at: t).offset.row) && (1...22).contains(map.coord(at: t).offset.col) {
        map[index: t] = Tile(terrain: map.coord(at: t).offset.row % 2 == 1 ? .plains : .grassland)
    }
    var state = makeState(map: map, gold: gold)
    state.turn = 21
    addCity(&state, p0, at: hex(3, 6))
    addCity(&state, p1, at: hex(21, 6))
    state.addUnit(.warrior, owner: p0, at: hex(3, 6))
    state.addUnit(.scout, owner: p0, at: ownScout)
    let settler = state.addUnit(.settler, owner: p0, at: settler)
    let spy = state.addUnit(.scout, owner: p1, at: scout)
    state.updateUnit(spy) { $0.activity = .sleeping }
    state.addUnit(.warrior, owner: p1, at: hex(21, 6))
    setRelation(&state, p0, p1, war: war, since: nil)
    for t in 0..<state.map.tileCount { state.players[0].explored[t] = true }
    refreshKnowledge(&state)
    return (state, settler, spy)
}

/// Player 1's phase: its Scout keeps within 2 tiles of player 0's Settler, next to it and
/// ahead of it when it can (a human shadowing the AI's Settler), then its endTurn.
private func shadow(_ state: inout GameState, scout: UnitID) {
    let v = state.view(for: p1)
    if let unit = v.unit(scout), unit.movesLeft > 0,
       let settler = state.units.first(where: { $0.owner == p0 && $0.type == .settler }) {
        let field = v.movementField(for: scout)
        var best: (key: [Int], hex: HexCoord)?
        for t in 0..<field.count where field[t] >= 0 && Int(field[t]) <= unit.movesLeft {
            let hex = state.map.coord(at: t)
            let d = state.map.distance(hex, settler.position)
            guard d >= 1, d <= 2 else { continue }
            let key = [d, -hex.offset.col, t]
            if let b = best, b.key.lexicographicallyPrecedes(key) { continue }
            best = (key, hex)
        }
        if let best, best.hex != unit.position { _ = try? GameEngine.apply(.moveUnit(unit: scout, to: best.hex), by: p1, to: &state) }
    }
    _ = try? GameEngine.apply(.endTurn, by: p1, to: &state)
}

/// Player 1's phase at war: its Scout takes player 0's Settler if it reaches it this phase and
/// no city or military unit of player 0 shares its tile (a human hunting the AI's Settler), then
/// its endTurn.
private func hunt(_ state: inout GameState, scout: UnitID) {
    if let unit = state.unit(scout), unit.movesLeft > 0,
       let settler = state.units.first(where: { $0.owner == p0 && $0.type == .settler }),
       !state.cities.contains(where: { $0.position == settler.position }),
       !state.units.contains(where: { $0.owner == p0 && !$0.type.isCivilian && $0.position == settler.position }),
       Pathfinder.reachableTiles(for: unit, in: state).contains(settler.position) {
        _ = try? GameEngine.apply(.moveUnit(unit: scout, to: settler.position), by: p1, to: &state)
    }
    _ = try? GameEngine.apply(.endTurn, by: p1, to: &state)
}

/// Plays player 0 (the AI) and player 1 (idle, or shadowing with its Scout) until player 0 has
/// two cities or `turns` turns have passed. Returns the turn the second city was founded (nil:
/// never) and the military units player 0 had then.
private func play(_ state: inout GameState, turns: Int, scout: UnitID, follow: Bool) -> (founded: Int?, military: Int) {
    let last = state.turn + turns
    while state.outcome == nil, state.turn < last {
        if state.currentPlayer == p0 {
            _ = AIPlayer.playTurn(&state, player: p0)
            if state.cities.filter({ $0.owner == p0 }).count >= 2 { return (state.turn, state.militaryUnitCount(of: p0)) }
        } else if follow {
            shadow(&state, scout: scout)
        } else {
            _ = try? GameEngine.apply(.endTurn, by: p1, to: &state)
        }
    }
    return (nil, state.militaryUnitCount(of: p0))
}

@Suite struct AISettlerEscortTests {
    /// The scene is as described: the Settler's every way east ends its first phase within 2
    /// tiles of the Scout, a good site exists, and the only fighter is the garrison.
    @Test func everyWayOnPassesTheScout() throws {
        let (state, settler, spy) = strip()
        let v = state.view(for: p0)
        let scout = try #require(state.unit(spy))
        try #require(v.visibleForeignUnits.contains { $0.id == spy })
        let unit = try #require(v.unit(settler))
        let field = v.movementField(for: settler, limit: unit.movesLeft)
        let reach = (0..<field.count).filter { field[$0] > 0 }
        try #require(!reach.isEmpty)
        for t in reach {
            let hex = state.map.coord(at: t)
            if hex.offset.col > 3 { #expect(state.map.distance(hex, scout.position) <= 2, "\(hex) is clear of the Scout") }
        }
        var turn = AITurn(state: state, player: p0)
        turn.plan = turn.makePlan()
        #expect(turn.plan.goodSiteExists)
        #expect(turn.plan.sites.allSatisfy { state.map.coord(at: $0.tile).offset.col >= 6 })
    }

    /// The play-test's case: the Settler waits in its garrisoned city while a foreign Scout
    /// sleeps across its way, and the city's garrison is its only fighter. An escort is built
    /// (here bought) and the two leave together: a second city within ten turns, with one
    /// fighter more than before.
    @Test func aSettlerHeldByASleepingScoutGetsAnEscort() throws {
        var (state, _, spy) = strip()
        let before = state.militaryUnitCount(of: p0)
        let result = play(&state, turns: 10, scout: spy, follow: false)
        let founded = try #require(result.founded, "no second city in 10 turns")
        #expect(founded <= 31)
        #expect(result.military <= before + 1)
    }

    /// The same with the Settler just outside the city (the play-test's (8,4) beside Rome), on a
    /// safe tile with every way on unsafe.
    @Test func aSettlerWaitingBesideItsCityGetsAnEscort() throws {
        var (state, _, spy) = strip(settler: hex(2, 6), scout: hex(5, 6))
        let before = state.militaryUnitCount(of: p0)
        let result = play(&state, turns: 10, scout: spy, follow: false)
        #expect(result.founded != nil, "no second city in 10 turns")
        #expect(result.military <= before + 1)
    }

    /// Without the gold to buy it, the escort is built: the city's production goes to the
    /// cheapest fighter first (here helped by stored progress), and the Settler still founds its
    /// city.
    @Test func withoutGoldTheEscortIsBuilt() throws {
        var (state, _, spy) = strip(gold: 0)
        let city = try #require(state.cities.first { $0.owner == p0 }?.id)
        updateCity(&state, city) { $0.storedProgress = 30 }
        let before = state.militaryUnitCount(of: p0)
        _ = AIPlayer.playTurn(&state, player: p0)
        #expect(state.city(city)?.queue.first?.item == .unit(.warrior))
        _ = try? GameEngine.apply(.endTurn, by: p1, to: &state)
        let result = play(&state, turns: 20, scout: spy, follow: false)
        #expect(result.founded != nil, "no second city in 20 turns")
        #expect(result.military <= before + 1)
    }

    /// A Settler no escort can come to would wait for ever: no free fighter, and the city's
    /// garrison (standing for an escort the city would build) is more than escortMaxMoveCost
    /// away. It goes on alone to where its path stops this phase, at peace; at war it keeps
    /// clear of the enemy (HeadlessSim, a Scout shadowing the Settler, seed 19: it had gone
    /// where closed borders kept every escort out; one was bought that could never come, more
    /// were built, and it waited 44 turns).
    @Test func aSettlerNoEscortCanComeToGoesOnAlone() throws {
        for war in [false, true] {
            let (state, settler, _) = strip(settler: hex(13, 6), scout: hex(12, 6), war: war)
            var turn = AITurn(state: state, player: p0)
            turn.plan = turn.makePlan()
            let v = turn.view
            let unit = try #require(v.unit(settler))
            let danger = turn.civilianDanger(v)
            let goal = hex(8, 6)
            try #require(!turn.safe(tile(state, unit.position), v, danger: danger))
            let safeAhead = turn.reachableThisPhase(unit).filter {
                turn.safe($0, v, danger: danger) && state.map.distance(state.map.coord(at: $0), goal) < state.map.distance(unit.position, goal)
            }
            try #require(safeAhead.isEmpty, "a safe tile ahead is in reach")
            let canCome = turn.escortCanCome(to: turn.escortSpots(for: unit, toward: goal, v))
            try #require(!canCome, "an escort could come")
            let stop = try #require(turn.path(settler, to: goal, v)?.steps.last { $0.turn <= 1 }?.hex)
            try #require(!turn.safe(tile(state, stop), v, danger: danger))
            turn.travel(settler, to: goal)
            let after = try #require(turn.state.unit(settler)?.position)
            if war {
                #expect(after != stop, "at war it went on to \(after), next to the enemy")
            } else {
                #expect(after == stop)
            }
            #expect(turn.unescorted.isEmpty)
        }
    }

    /// p3d ai-settlers-at-war (M1 §13 Safety): the iPhone play-test's capture, rebuilt (its
    /// command log was lost). At war a human Scout took the AI's lone Settler from 3 tiles away:
    /// the danger zone was 2 tiles around each foreign military unit, and a Scout moves 3. Here
    /// an enemy Scout in sight of the AI's own Scout stands 3 tiles from tiles of the Settler's
    /// way east. At war those tiles are in the danger zone (the Scout's next-phase reach), at
    /// peace not (2 tiles); in a whole turn the Settler keeps out of the reach, and the Scout,
    /// moving in on it where it can, takes nothing. (With the 2-tile zone at war the Settler
    /// stopped 3 tiles from the Scout and was taken.)
    @Test func atWarASettlerKeepsOutOfAnEnemyScoutsReach() throws {
        var (state, settler, spy) = strip(scout: hex(8, 6), war: true, ownScout: hex(10, 6))
        state.updateUnit(spy) { $0.activity = .none }
        let scout = try #require(state.unit(spy))
        let v = state.view(for: p0)
        try #require(v.visibleForeignUnits.contains { $0.id == spy }, "player 0 does not see the Scout")
        let reach = Pathfinder.reachableTiles(for: scout, in: state)
        let unit = try #require(v.unit(settler))
        let field = v.movementField(for: settler, limit: unit.movesLeft)
        let exposed = (0..<field.count).filter { field[$0] > 0 }.map { state.map.coord(at: $0) }.filter {
            $0.offset.col > 3 && state.map.distance($0, scout.position) == 3 && reach.contains($0)
        }
        try #require(!exposed.isEmpty, "no tile of the way east 3 tiles from the Scout and in its reach")

        var turn = AITurn(state: state, player: p0)
        turn.plan = turn.makePlan()
        let danger = turn.civilianDanger(turn.view)
        for hex in exposed { #expect(danger[tile(state, hex)], "\(hex) is out of the danger zone at war") }
        var peace = state
        setRelation(&peace, p0, p1, war: false, since: nil)
        var calm = AITurn(state: peace, player: p0)
        calm.plan = calm.makePlan()
        let zone = calm.civilianDanger(calm.view)
        for hex in exposed { #expect(!zone[tile(peace, hex)], "\(hex) is in the danger zone at peace") }

        _ = AIPlayer.playTurn(&state, player: p0)
        let after = try #require(state.unit(settler))
        let hunter = try #require(state.unit(spy), "player 0 killed the Scout")
        let guarded = state.cities.contains { $0.position == after.position }
            || state.units.contains { $0.owner == p0 && !$0.type.isCivilian && $0.position == after.position }
        #expect(guarded || !Pathfinder.reachableTiles(for: hunter, in: state).contains(after.position),
                "the Settler ends at \(after.position), in the Scout's reach")
        hunt(&state, scout: spy)
        #expect(state.unit(settler)?.owner == p0, "the Scout took the Settler")
    }

    /// p3d ai-settlers-at-war (M1 §13 Cities): at war no Settler is started in a front-line
    /// city, one whose tile or a neighbour lies where a Settler keeps out — here within 2 tiles
    /// of an enemy Warrior remembered 3 tiles away, out of sight (a visible enemy within 4 tiles
    /// stops Settlers anyway). In HeadlessSim such Settlers waited 12–28 phases in their city for
    /// an escort the front kept busy. With no enemy remembered near, or at peace, it is started.
    @Test func atWarNoSettlerIsStartedInAFrontLineCity() throws {
        func world(war: Bool, sighting: Bool) -> (GameState, CityID) {
            var state = makeState()
            let city = addCity(&state, p0, at: hex(6, 6))
            addCity(&state, p1, at: hex(18, 2))
            updateCity(&state, city) { $0.population = 3 }
            state.addUnit(.warrior, owner: p0, at: hex(6, 6))
            state.addUnit(.scout, owner: p0, at: hex(1, 11))
            state.addUnit(.builder, owner: p0, at: hex(5, 6))
            for t in 0..<state.map.tileCount { state.players[0].explored[t] = true }
            setRelation(&state, p0, p1, war: war, since: war ? 30 : nil)
            state.turn = 35
            refreshKnowledge(&state)
            if sighting {
                state.players[0].memory.units = [
                    UnitSighting(id: UnitID(500), owner: p1, type: .warrior, position: hex(9, 6), hp: 100, turnSeen: 34),
                ]
            }
            return (state, city)
        }
        func queue(_ world: (GameState, CityID)) -> [ProductionItem] {
            var turn = AITurn(state: world.0, player: p0)
            turn.plan = turn.makePlan()
            return turn.decideQueue(for: world.1, turn.baseCounts())
        }
        let front = world(war: true, sighting: true)
        let v = front.0.view(for: p0)
        try #require(front.0.map.distance(hex(6, 6), hex(9, 6)) == 3)
        try #require(!v.isVisible(hex(9, 6)) && v.visibleForeignUnits.isEmpty)
        #expect(!queue(front).contains(.unit(.settler)), "\(queue(front))")
        let quiet = world(war: true, sighting: false)
        #expect(queue(quiet).contains(.unit(.settler)), "\(queue(quiet))")
        let peace = world(war: false, sighting: true)
        #expect(queue(peace).contains(.unit(.settler)), "\(queue(peace))")
    }

    /// A human Scout that follows the Settler every turn, keeping next to it and ahead of it,
    /// stops nothing: the escort and the Settler travel together, and only one fighter is added.
    @Test func aScoutShadowingTheSettlerDoesNotStopIt() throws {
        var (state, _, spy) = strip()
        let before = state.militaryUnitCount(of: p0)
        let result = play(&state, turns: 14, scout: spy, follow: true)
        #expect(result.founded != nil, "no second city in 14 turns")
        #expect(result.military <= before + 1)
    }
}

// MARK: p3f ai-civilian-reach

/// p3f ai-civilian-reach (M1 §13 Safety): the iPhone side game's T19 scene, rebuilt on its map
/// (`newgame duel 23 mongols fog`, at war from T4; Rome is player 0 here, the Mongols player 1).
/// Rome's Settler stands at (12,5) next to a Mongol Scout at (13,4), every tile it reaches in
/// the Scout's reach (a Scout moves 3), and its Warrior is at (9,4), 3 tiles off: in the side
/// game the Warrior came only to (11,4) and the Scout took the Settler on T20.
private func sideGameT19() -> (state: GameState, settler: UnitID, escort: UnitID, scout: UnitID) {
    let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: 23))
    var state = makeState(map: generated.map, gold: 20, seed: 23)
    state.turn = 19
    let rome = HexCoord(q: 7, r: 6), karakorum = HexCoord(q: 18, r: 7)
    addCity(&state, p0, at: rome)
    addCity(&state, p1, at: karakorum)
    let garrison = state.addUnit(.warrior, owner: p0, at: rome)
    state.updateUnit(garrison) { $0.activity = .fortified }
    let escort = state.addUnit(.warrior, owner: p0, at: HexCoord(q: 9, r: 4))
    let settler = state.addUnit(.settler, owner: p0, at: HexCoord(q: 12, r: 5))
    state.addUnit(.warrior, owner: p1, at: karakorum)
    let scout = state.addUnit(.scout, owner: p1, at: HexCoord(q: 13, r: 4))
    setRelation(&state, p0, p1, war: true, since: 4)
    for t in 0..<state.map.tileCount where state.map.distance(state.map.coord(at: t), rome) <= 8 {
        state.players[0].explored[t] = true
    }
    refreshKnowledge(&state)
    return (state, settler, escort, scout)
}

/// Player 0's phase as `AITurn.play` runs it up to the military's moves: the whole phase before
/// p3f's last look at the civilians (`secureCivilians`), bar the cities and the endTurn.
private func phaseUpToTheMilitary(_ turn: inout AITurn) {
    turn.respondToPeace()
    turn.plan = turn.makePlan()
    if turn.declareWarIfReady() { turn.plan = turn.makePlan() }
    turn.proposePeaceIfWanted()
    turn.chooseResearch()
    turn.foundFirstCity()
    let atWar = !turn.plan.enemies.isEmpty
    if atWar {
        turn.captureCities()
        turn.bombardAndShoot()
        turn.meleeAttacks()
    }
    turn.retreatWounded()
    if atWar {
        turn.defendCities()
        turn.captureCivilians()
    }
    turn.buyThreatDefenders()
    turn.moveSettlers()
    turn.moveBuilders()
    turn.explore()
    turn.moveMilitary()
}

/// Whether player 0's unit at `hex` stands guarded: in an own city or with an own military unit.
private func guarded(_ state: GameState, _ hex: HexCoord) -> Bool {
    state.cities.contains { $0.owner == p0 && $0.position == hex }
        || state.units.contains { $0.owner == p0 && !$0.type.isCivilian && $0.position == hex }
}

extension AISettlerEscortTests {
    /// The scene is the side game's: the Settler is hemmed in (its tile and every tile it reaches
    /// lie in the Scout's reach), its Warrior cannot reach its tile this phase, and the phase up
    /// to the military's moves ends as the side game's T19 did: the Settler waiting at (12,5), the
    /// Warrior 2 tiles short at (11,4). Ended there, the Scout takes the Settler. The last look
    /// at the civilians (p3f) moves the Settler onto the Warrior's tile instead.
    @Test func sideGameT19TheEscortStopsShortOfTheSettler() throws {
        let (state, settler, escort, spy) = sideGameT19()
        let v = state.view(for: p0)
        try #require(v.visibleForeignUnits.contains { $0.id == spy }, "Rome does not see the Scout")
        let reach = v.aiEnemyReach()
        var turn = AITurn(state: state, player: p0)
        let unit = try #require(v.unit(settler))
        for t in turn.reachableThisPhase(unit) + [tile(state, unit.position)] {
            try #require(reach[t], "\(state.map.coord(at: t)) is out of the Scout's reach")
        }
        let warrior = try #require(v.unit(escort))
        try #require(!turn.reachableThisPhase(warrior).contains(tile(state, unit.position)), "the Warrior reaches the Settler")

        phaseUpToTheMilitary(&turn)
        let waited = try #require(turn.state.unit(settler)?.position)
        let stopped = try #require(turn.state.unit(escort)?.position)
        #expect(waited == HexCoord(q: 12, r: 5), "the Settler went to \(waited)")
        #expect(stopped == HexCoord(q: 11, r: 4), "the Warrior went to \(stopped)")
        try #require(!guarded(turn.state, waited) && turn.view.aiEnemyReach()[tile(state, waited)])
        var before = turn.state
        _ = try GameEngine.apply(.endTurn, by: p0, to: &before)
        hunt(&before, scout: spy)
        #expect(before.unit(settler)?.owner != p0, "the Scout did not take the Settler")

        turn.secureCivilians()
        let after = try #require(turn.state.unit(settler)?.position)
        #expect(guarded(turn.state, after), "the Settler ends at \(after), unguarded")
    }

    /// The whole phase: the Settler ends guarded or out of the Scout's reach, and the Scout,
    /// moving in on it where it can, takes nothing.
    @Test func sideGameT19TheSettlerIsNotTaken() throws {
        var (state, settler, _, spy) = sideGameT19()
        _ = AIPlayer.playTurn(&state, player: p0)
        let after = try #require(state.unit(settler))
        let hunter = try #require(state.unit(spy), "Rome killed the Scout")
        #expect(guarded(state, after.position) || !Pathfinder.reachableTiles(for: hunter, in: state).contains(after.position),
                "the Settler ends at \(after.position), in the Scout's reach")
        hunt(&state, scout: spy)
        #expect(state.unit(settler)?.owner == p0, "the Scout took the Settler")
    }
}
