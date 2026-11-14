import Foundation
import Testing
@testable import GameCore

// The Explore order's queries (GameCore/Queries/UIExplore.swift, M1 §16): where an own unit on the
// order goes next, why the order ends, the enemies in its sight and the enemy reach it keeps out
// of, all from its player's knowledge.

@Suite struct UIExploreTests {
    private let me = PlayerID(0), them = PlayerID(1)

    /// Marks every tile explored for player 0 where `include` holds, and unexplored elsewhere
    /// (tiles in sight stay explored).
    private func explore(_ state: inout GameState, where include: (OffsetCoord) -> Bool) {
        let width = state.map.width
        for t in 0..<state.map.tileCount {
            let offset = OffsetCoord(col: t % width, row: t / width)
            state.players[0].explored[t] = include(offset) || state.players[0].visible[t]
        }
    }

    /// A Scout heads for the frontier and walks as far as it gets this phase: the move ends
    /// there, with no standing order left behind.
    @Test func walksTowardTheFrontierWithinThePhase() throws {
        // (Settlers parked, so no one is eliminated when the move is applied.)
        var state = makeTestState(map: openMap(width: 30, height: 14))
        let scout = state.addUnit(.scout, owner: me, at: hex(4, 7))
        let view = state.view(for: me)
        let step = view.exploreStep(for: scout)
        guard case let .move(to, goal, _) = step else {
            Issue.record("expected a move, got \(step)")
            return
        }
        #expect(view.aiFrontier().contains(tile(state, goal)))
        #expect(try #require(view.path(for: scout, to: to)).turns == 1)
        try GameEngine.apply(.moveUnit(unit: scout, to: to), by: me, to: &state)
        let moved = try #require(state.unit(scout))
        #expect(moved.position == to && moved.destination == nil)
        // On it goes from there, toward land it has not seen.
        if case .end = state.view(for: me).exploreStep(for: scout) { Issue.record("the order ended on open land") }
    }

    /// Not only Scouts: any military unit on the order heads for the frontier, as far as it
    /// gets this phase.
    @Test func anyMilitaryUnitExplores() throws {
        var state = makeTestState(map: openMap(width: 30, height: 14))
        let warrior = state.addUnit(.warrior, owner: me, at: hex(4, 7))
        let view = state.view(for: me)
        let step = view.exploreStep(for: warrior)
        guard case let .move(to, goal, _) = step else {
            Issue.record("expected a move, got \(step)")
            return
        }
        #expect(view.aiFrontier().contains(tile(state, goal)))
        #expect(try #require(view.path(for: warrior, to: to)).turns == 1)
    }

    /// A goal's worth: its cost in turns times the tiles a turn is worth, less the unexplored
    /// tiles in sight of it. A near goal with little to see loses to a farther one with much
    /// when a turn is worth few tiles, and wins when it is worth many.
    @Test func weighsWhatItWouldSeeAgainstTheWalk() throws {
        var state = makeTestState(map: openMap(width: 30, height: 14), parkSettlers: false)
        let scout = state.addUnit(.scout, owner: me, at: hex(4, 7))
        let near = hex(8, 7), far = hex(16, 7)
        // Unexplored: one tile 3 from the near goal; seven around a tile 3 from the far one.
        let hidden = [hex(11, 7), hex(19, 7)] + state.map.neighbors(of: hex(19, 7))
        explore(&state) { !hidden.contains($0.hex) }
        let view = state.view(for: me)
        let def = state.rules.unit(.scout)
        #expect(view.unexploredTiles(within: def.sight, of: tile(state, near)) == 1)
        #expect(view.unexploredTiles(within: def.sight, of: tile(state, far)) == 4)
        // Costs as a movement field gives them: the near goal this phase, the far one in 3 turns.
        var field = [Int32](repeating: -1, count: state.map.tileCount)
        field[tile(state, near)] = 9
        field[tile(state, far)] = 27
        let unit = try #require(state.unit(scout))
        let frontier = [tile(state, near), tile(state, far)]
        func goal(_ tilesPerTurn: Int) -> Int? {
            view.exploreGoal(unit, field: field, frontier: frontier, claimed: [], tuning: ExploreTuning(tilesPerTurn: tilesPerTurn))
        }
        // 16 a turn: near 9×16 − 1×9 = 135, far 27×16 − 4×9 = 396. 1 a turn: 0 against −9.
        #expect(goal(16) == tile(state, near))
        #expect(goal(1) == tile(state, far))
        // A goal it cannot stop on does not count.
        field[tile(state, near)] = -1
        #expect(goal(16) == tile(state, far))
    }

    /// With all it can reach explored, the order ends; it names no closed land then.
    @Test func endsWhenNothingIsLeftToSee() {
        var state = makeTestState(map: openMap(width: 30, height: 14), parkSettlers: false)
        let scout = state.addUnit(.scout, owner: me, at: hex(4, 7))
        explore(&state) { _ in true }
        #expect(state.view(for: me).exploreStep(for: scout) == .end(.explored(closedLand: [])))
        // So does a unit standing alone on an island, all of whose coast it has seen.
        var island = makeTestState(map: HexMap(width: 20, height: 10, wrapsX: false, fill: Tile(terrain: .ocean)), parkSettlers: false)
        for h in [hex(9, 5), hex(10, 5), hex(9, 4)] { island.map[h] = Tile(terrain: .grassland) }
        let castaway = island.addUnit(.scout, owner: me, at: hex(9, 5))
        explore(&island) { $0.hex.distance(to: hex(9, 5)) <= 4 }
        #expect(island.view(for: me).exploreStep(for: castaway) == .end(.explored(closedLand: [])))
    }

    /// p3g review: a foreign unit at peace on the only way on (a one-tile land bridge) does not
    /// end the order as if all were explored. The order waits for it to move on, heading for the
    /// land beyond, while the explorer last moved at most 2 turns ago; then it ends as before.
    /// Once the way is clear it goes on.
    @Test func waitsForAForeignUnitOnTheOnlyWayOn() throws {
        // Water but for columns 0–6 and 8–19, joined only at (7,2).
        var map = HexMap(width: 20, height: 5, wrapsX: false, fill: Tile(terrain: .ocean))
        for col in 0..<20 where col != 7 {
            for row in 0..<5 { map[hex(col, row)] = Tile(terrain: .grassland) }
        }
        map[hex(7, 2)] = Tile(terrain: .grassland)
        var state = makeTestState(map: map, parkSettlers: false)
        let scout = state.addUnit(.scout, owner: me, at: hex(4, 2))
        let blocker = state.addUnit(.warrior, owner: them, at: hex(7, 2))
        explore(&state) { $0.col <= 8 }
        state.updateUnit(scout) { $0.lastActedTurn = 1 }
        let view = state.view(for: me)
        try #require(view.isVisible(hex(7, 2)) && !view.isAtWar(with: them) && state.turn == 1)
        let frontier = view.aiFrontier()
        try #require(!frontier.isEmpty && frontier.allSatisfy { state.map.coord(at: $0).offset.col == 8 })
        try #require(frontier.allSatisfy { view.movementField(for: scout)[$0] < 0 })
        let step = view.exploreStep(for: scout)
        guard case let .wait(goal) = step else {
            Issue.record("expected a wait for the Warrior to move on, got \(step)")
            return
        }
        #expect(goal.offset.col == 8)
        // It last moved 2 turns ago: it still waits; 3 turns ago: the order ends.
        state.turn = 3
        #expect(state.view(for: me).exploreStep(for: scout, goal: goal) == .wait(goal: goal))
        state.turn = 4
        #expect(state.view(for: me).exploreStep(for: scout, goal: goal) == .end(.explored(closedLand: [])))
        // The way clear, on it goes.
        state.turn = 3
        state.removeUnit(blocker)
        refreshKnowledge(&state)
        let onward = state.view(for: me).exploreStep(for: scout, goal: goal)
        guard case let .move(_, next, _) = onward else {
            Issue.record("expected a move once the way is clear, got \(onward)")
            return
        }
        #expect(next.offset.col == 8)
    }

    /// At war, with an enemy's reach over the explorer, it does not wait there for the units in
    /// the way: the order ends as before.
    @Test func noWaitWithinEnemyReach() throws {
        var map = HexMap(width: 20, height: 5, wrapsX: false, fill: Tile(terrain: .ocean))
        for col in 0..<20 where col != 7 {
            for row in 0..<5 { map[hex(col, row)] = Tile(terrain: .grassland) }
        }
        map[hex(7, 2)] = Tile(terrain: .grassland)
        var state = makeTestState(map: map, parkSettlers: false)
        setWar(&state, me, them)
        let scout = state.addUnit(.scout, owner: me, at: hex(6, 2))
        let enemy = state.addUnit(.warrior, owner: them, at: hex(7, 2))
        explore(&state) { $0.col <= 8 }
        let view = state.view(for: me)
        let unit = try #require(state.unit(scout))
        try #require(view.exploreThreats(for: unit)[tile(state, hex(6, 2))] != nil)
        let step = view.exploreStep(for: scout, knownEnemies: [enemy])
        if case .wait = step { Issue.record("waited within enemy reach") }
        if case .move = step { Issue.record("moved past an enemy on the only way on: \(step)") }
    }

    /// The only way on through land closed to it at peace: the order ends, naming whose land it is.
    @Test func namesTheLandClosedToIt() throws {
        // A corridor three rows high; player 1's land spans it at columns 7 and 8.
        var state = makeTestState(map: openMap(width: 20, height: 3), parkSettlers: false)
        let city = addCity(&state, them, at: hex(16, 1))
        let scout = state.addUnit(.scout, owner: me, at: hex(5, 1))
        for col in 7...8 {
            for row in 0..<3 { claimTile(&state, hex(col, row), for: city) }
        }
        explore(&state) { $0.col <= 8 }
        let view = state.view(for: me)
        for col in 7...8 {
            for row in 0..<3 { try #require(view.memory.tileOwner[tile(state, hex(col, row))] == UInt8(them.rawValue + 1)) }
        }
        try #require(state.bordersClosed(to: me, by: them))
        #expect(view.exploreStep(for: scout) == .end(.explored(closedLand: [them])))
        // A civilian may walk in: it goes on (and names nothing when it cannot).
        let builder = state.addUnit(.builder, owner: me, at: hex(4, 1))
        if case .end = state.view(for: me).exploreStep(for: builder) { Issue.record("a civilian's order ended at open borders") }
        // At war the land is open: on it goes.
        setWar(&state, me, them)
        if case .end(.explored) = state.view(for: me).exploreStep(for: scout) { Issue.record("closed land at war") }
    }

    /// An enemy military unit in its sight that it was not told of ends the order; one it was
    /// told of does not. Civilians, units beyond its sight and foreign units at peace do not count.
    @Test func stopsForEnemiesComingIntoSight() throws {
        var state = makeWarState(width: 30, height: 14)
        let scout = state.addUnit(.scout, owner: me, at: hex(10, 7))
        state.addUnit(.warrior, owner: me, at: hex(20, 7)) // sees what the Scout does not
        state.addUnit(.builder, owner: them, at: hex(11, 7))
        let far = state.addUnit(.warrior, owner: them, at: hex(21, 7))
        var view = state.view(for: me)
        try #require(view.unit(far) != nil)
        #expect(view.enemiesInSight(of: scout).isEmpty)
        if case .end(.enemyInSight) = view.exploreStep(for: scout) { Issue.record("stopped for units out of its sight") }

        let near = state.addUnit(.warrior, owner: them, at: hex(12, 7))
        let nearer = state.addUnit(.archer, owner: them, at: hex(11, 6))
        view = state.view(for: me)
        #expect(view.enemiesInSight(of: scout) == [nearer, near])
        #expect(view.exploreStep(for: scout) == .end(.enemyInSight([nearer, near])))
        #expect(view.exploreStep(for: scout, knownEnemies: [near]) == .end(.enemyInSight([nearer])))
        if case .end(.enemyInSight) = view.exploreStep(for: scout, knownEnemies: [near, nearer]) {
            Issue.record("stopped for enemies it was told of")
        }
        // Another player's unit has none in its sight; at peace there are no enemies.
        #expect(view.enemiesInSight(of: near).isEmpty)
        var peace = makeTestState(map: openMap(width: 30, height: 14))
        let other = peace.addUnit(.scout, owner: me, at: hex(10, 7))
        peace.addUnit(.warrior, owner: them, at: hex(12, 7))
        #expect(peace.view(for: me).enemiesInSight(of: other).isEmpty)
    }

    /// At war it ends its phases only where no enemy it sees could strike it next; when the
    /// only way on stops in reach, the order ends.
    @Test func keepsOutOfEnemyReach() throws {
        var state = makeWarState(width: 30, height: 14)
        let scout = state.addUnit(.scout, owner: me, at: hex(8, 7))
        let enemy = state.addUnit(.warrior, owner: them, at: hex(11, 7))
        var view = state.view(for: me)
        let reach = view.enemyReach()
        try #require(reach.contains(true))
        let step = view.exploreStep(for: scout, knownEnemies: [enemy])
        guard case let .move(to, goal, _) = step else {
            Issue.record("expected a move, got \(step)")
            return
        }
        #expect(!reach[tile(state, to)] && !reach[tile(state, goal)])

        // A corridor two rows high, an enemy Warrior in it, unexplored land only beyond.
        var corridor = makeTestState(map: openMap(width: 16, height: 2), parkSettlers: false)
        setWar(&corridor, me, them)
        let walker = corridor.addUnit(.scout, owner: me, at: hex(4, 0))
        let guardian = corridor.addUnit(.warrior, owner: them, at: hex(6, 1))
        explore(&corridor) { $0.col <= 8 }
        view = corridor.view(for: me)
        try #require(view.unit(guardian) != nil)
        #expect(view.exploreStep(for: walker, knownEnemies: [guardian]) == .end(.enemyReach))
        // The same corridor at peace: it walks on.
        var calm = makeTestState(map: openMap(width: 16, height: 2), parkSettlers: false)
        let stroller = calm.addUnit(.scout, owner: me, at: hex(4, 0))
        calm.addUnit(.warrior, owner: them, at: hex(6, 1))
        explore(&calm) { $0.col <= 8 }
        #expect(calm.view(for: me).enemyReach().allSatisfy { !$0 })
        if case .end = calm.view(for: me).exploreStep(for: stroller) { Issue.record("ended at peace") }
    }

    /// Enemy reach: the tiles enemy units in sight could strike next phase, and the bombard
    /// range of remembered enemy cities; nothing at peace.
    @Test func enemyReachHoldsCityBombardRange() {
        var state = makeTestState(map: openMap(width: 30, height: 14))
        let city = addCity(&state, them, at: hex(12, 7))
        state.addUnit(.scout, owner: me, at: hex(9, 7))
        #expect(state.view(for: me).enemyReach().allSatisfy { !$0 })
        setWar(&state, me, them)
        let reach = state.view(for: me).enemyReach()
        let range = state.rules.constants.city.bombardRange
        let centre = state.city(city)!.position
        for t in 0..<state.map.tileCount {
            let d = state.map.distance(state.map.coord(at: t), centre)
            if d <= range { #expect(reach[t], "\(state.map.coord(at: t))") }
        }
        #expect(!reach[tile(state, hex(5, 7))])
    }

    /// A second explorer leaves the first one's goal to it: it heads for a goal out of its sight
    /// of the claimed one, while there is such a goal.
    @Test func claimedGoalsSpreadExplorers() throws {
        var state = makeTestState(map: openMap(width: 30, height: 14), parkSettlers: false)
        let first = state.addUnit(.scout, owner: me, at: hex(14, 7))
        let second = state.addUnit(.scout, owner: me, at: hex(15, 7))
        let view = state.view(for: me)
        guard case let .move(_, claimed, _) = view.exploreStep(for: first),
              case let .move(_, spread, _) = view.exploreStep(for: second, claimed: [claimed]) else {
            Issue.record("expected moves")
            return
        }
        #expect(state.map.distance(spread, claimed) > state.rules.unit(.scout).sight)
        // With every goal near the claimed one, it takes one of those.
        let sight = state.rules.unit(.scout).sight
        let frontier = view.aiFrontier().filter { state.map.distance(view.coord(at: $0), claimed) <= sight }
        let unit = try #require(state.unit(second))
        let field = view.movementField(for: second)
        let crowded = view.exploreGoal(unit, field: field, frontier: frontier, claimed: [claimed], tuning: .standard)
        #expect(crowded.map { frontier.contains($0) } == true)
    }

    /// No moves left, or held by a zone of control: it waits, still headed for its goal.
    @Test func waitsWithoutMoves() throws {
        var state = makeTestState(map: openMap(width: 30, height: 14), parkSettlers: false)
        let scout = state.addUnit(.scout, owner: me, at: hex(4, 7))
        guard case let .move(_, goal, _) = state.view(for: me).exploreStep(for: scout) else {
            Issue.record("expected a move")
            return
        }
        state.updateUnit(scout) { $0.movesLeft = 0 }
        #expect(state.view(for: me).exploreStep(for: scout) == .wait(goal: goal))
        state.updateUnit(scout) { u in
            u.movesLeft = 2
            u.zocStopped = true
        }
        #expect(state.view(for: me).exploreStep(for: scout) == .wait(goal: goal))
    }

    /// Only the player's own units: another player's, or none, is unavailable.
    @Test func onlyOwnUnits() {
        var state = makeTestState(map: openMap(width: 30, height: 14))
        let theirs = state.addUnit(.scout, owner: them, at: hex(10, 7))
        #expect(state.view(for: me).exploreStep(for: theirs) == .end(.unavailable))
        #expect(state.view(for: me).exploreStep(for: UnitID(999)) == .end(.unavailable))
    }

    /// What the player cannot see changes nothing: hidden terrain, hidden enemy units and a
    /// hidden enemy city give the same steps.
    @Test func hiddenThingsChangeNothing() throws {
        func game(_ hide: (inout GameState) -> Void) -> (GameState, UnitID, UnitID) {
            var state = makeWarState(width: 30, height: 14)
            let scout = state.addUnit(.scout, owner: me, at: hex(8, 7))
            let known = state.addUnit(.warrior, owner: them, at: hex(10, 8))
            hide(&state)
            refreshKnowledge(&state)
            return (state, scout, known)
        }
        let (plain, scout, known) = game { _ in }
        let (hidden, _, _) = game { state in
            for col in 20..<26 {
                for row in 0..<9 { state.map[hex(col, row)] = Tile(terrain: .grassland, elevation: .mountains) }
            }
            state.map[hex(14, 2)] = Tile(terrain: .lake)
            state.addUnit(.warrior, owner: them, at: hex(14, 7))
            state.addUnit(.archer, owner: them, at: hex(4, 12))
            _ = addCity(&state, them, at: hex(16, 10))
        }
        let a = plain.view(for: me), b = hidden.view(for: me)
        try #require(a.explored == b.explored && a.visibleForeignUnits == b.visibleForeignUnits)
        #expect(a.exploreStep(for: scout, knownEnemies: [known]) == b.exploreStep(for: scout, knownEnemies: [known]))
        #expect(a.exploreStep(for: scout) == b.exploreStep(for: scout))
        #expect(a.enemyReach() == b.enemyReach())
        #expect(a.exploreThreats(for: try #require(a.unit(scout))) == b.exploreThreats(for: try #require(b.unit(scout))))
    }

    // MARK: The compass (p3f app-explore-heading)

    /// The card's heading names the direction as the map is drawn: rows grow northward and are
    /// drawn upward, so a tile of a lower row is to the south. p3e's iPad Scout at (17,9) heading
    /// for (22,5), drawn down and to the right, read "north-east"; it is south-east.
    @Test func theCompassPinsAKnownPairOfTiles() {
        let duel = HexMap(width: 44, height: 26, wrapsX: true, fill: Tile(terrain: .grassland))
        #expect(duel.compassPoint(from: HexCoord(q: 17, r: 9), to: HexCoord(q: 22, r: 5)) == .southEast)
        #expect(duel.compassPoint(from: HexCoord(q: 17, r: 9), to: HexCoord(q: 22, r: 5))?.name == "south-east")
        // And the iPad's T5 Warrior: (10,9) is straight down the screen from (9,11).
        #expect(duel.compassPoint(from: HexCoord(q: 9, r: 11), to: HexCoord(q: 10, r: 9)) == .south)
        #expect(duel.compassPoint(from: HexCoord(q: 10, r: 9), to: HexCoord(q: 9, r: 11)) == .north)
    }

    /// One case per octant, and each of the six neighbours lies where its `HexDirection` names it.
    @Test func theCompassHasEightPoints() {
        let map = HexMap(width: 30, height: 20, wrapsX: false, fill: Tile(terrain: .grassland))
        let c = HexCoord(q: 10, r: 10)
        let octants: [(HexCoord, CompassPoint)] = [
            (HexCoord(q: 14, r: 10), .east), (HexCoord(q: 11, r: 12), .northEast), (HexCoord(q: 9, r: 12), .north),
            (HexCoord(q: 8, r: 12), .northWest), (HexCoord(q: 6, r: 10), .west), (HexCoord(q: 9, r: 8), .southWest),
            (HexCoord(q: 11, r: 8), .south), (HexCoord(q: 12, r: 8), .southEast),
        ]
        for (to, point) in octants {
            #expect(map.compassPoint(from: c, to: to) == point, "\(c) → \(to)")
            #expect(map.compassPoint(from: to, to: c) == CompassPoint(rawValue: (point.rawValue + 4) % 8), "\(to) → \(c)")
        }
        #expect(Set(octants.map(\.1)) == Set(CompassPoint.allCases))
        let named: [HexDirection: CompassPoint] = [.east: .east, .southEast: .southEast, .southWest: .southWest, .west: .west,
                                                   .northWest: .northWest, .northEast: .northEast]
        for direction in HexDirection.allCases {
            #expect(map.compassPoint(from: c, to: c.neighbor(direction)) == named[direction], "\(direction)")
        }
        // Nearly level lines stay east or west; the same place has no direction.
        #expect(map.compassPoint(from: c, to: HexCoord(q: 12, r: 11)) == .east)
        #expect(map.compassPoint(from: c, to: HexCoord(q: 11, r: 11)) == .northEast)
        #expect(map.compassPoint(from: c, to: c) == nil)
        #expect(CompassPoint.allCases.map(\.name) == ["east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east"])
    }

    /// On a wrapping map the short way round the seam counts; on one that does not wrap, the
    /// long way is the only way.
    @Test func theCompassGoesTheShortWayRoundTheSeam() {
        let wrapping = HexMap(width: 44, height: 26, wrapsX: true, fill: Tile(terrain: .grassland))
        let flat = HexMap(width: 44, height: 26, wrapsX: false, fill: Tile(terrain: .grassland))
        let west = hex(42, 4), east = hex(1, 4), eastUp = hex(2, 7)
        #expect(wrapping.compassPoint(from: west, to: east) == .east)
        #expect(wrapping.compassPoint(from: east, to: west) == .west)
        #expect(wrapping.compassPoint(from: west, to: eastUp) == .northEast)
        #expect(flat.compassPoint(from: west, to: east) == .west)
        // A coordinate a whole map width round is the same place.
        #expect(wrapping.compassPoint(from: east, to: HexCoord(q: east.q + 44, r: east.r)) == nil)
    }

    // MARK: Behaviour (p3f app-explore-behaviour)

    /// The goal it heads for is kept while another scores better by at most a turn of walking,
    /// and dropped for one better by more, or when it can no longer be reached or is no longer
    /// frontier.
    @Test func keepsItsGoalUnlessAnotherIsBetterByMoreThanATurn() throws {
        var state = makeTestState(map: openMap(width: 30, height: 14), parkSettlers: false)
        let scout = state.addUnit(.scout, owner: me, at: hex(4, 7))
        let near = hex(8, 7), far = hex(16, 7)
        let hidden = [hex(11, 7), hex(19, 7)] + state.map.neighbors(of: hex(19, 7))
        explore(&state) { !hidden.contains($0.hex) }
        let view = state.view(for: me)
        let unit = try #require(state.unit(scout))
        let frontier = [tile(state, near), tile(state, far)]
        var field = [Int32](repeating: -1, count: state.map.tileCount)
        field[tile(state, near)] = 9
        func goal(current: HexCoord?, keep: Int = 1) -> Int? {
            view.exploreGoal(unit, field: field, frontier: frontier, claimed: [], current: current.map { tile(state, $0) },
                             tuning: ExploreTuning(tilesPerTurn: 16, keepGoalTurns: keep))
        }
        // A turn is 9 points × 16 = 144. Near: 9×16 − 1×9 = 135. Far in 18 points: 18×16 −
        // 4×9 = 252, within a turn of 135: kept. Far in 27: 396, more than a turn worse: dropped.
        field[tile(state, far)] = 18
        #expect(goal(current: nil) == tile(state, near))
        #expect(goal(current: far) == tile(state, far))
        #expect(goal(current: far, keep: 0) == tile(state, near))
        field[tile(state, far)] = 27
        #expect(goal(current: far) == tile(state, near))
        // Out of reach, or no longer frontier: chosen afresh.
        field[tile(state, far)] = -1
        #expect(goal(current: far) == tile(state, near))
        field[tile(state, far)] = 18
        #expect(view.exploreGoal(unit, field: field, frontier: [tile(state, near)], claimed: [], current: tile(state, far),
                                 tuning: .standard) == tile(state, near))
    }

    /// The order walks on toward the goal it was given while that stays worth it: each step's
    /// goal is the one it headed for.
    @Test func theStepKeepsTheGoalItHeadsFor() throws {
        var state = makeTestState(map: openMap(width: 30, height: 14), parkSettlers: false)
        let scout = state.addUnit(.scout, owner: me, at: hex(14, 7))
        let view = state.view(for: me)
        guard case let .move(_, first, _) = view.exploreStep(for: scout) else {
            Issue.record("expected a move")
            return
        }
        // The frontier tile farthest from it (as good within a turn: all lie 3 tiles away),
        // given as the goal, is kept.
        let other = view.aiFrontier().map(view.coord(at:))
            .max { (state.map.distance($0, first), -tile(state, $0)) < (state.map.distance($1, first), -tile(state, $1)) }
        let kept = try #require(other)
        try #require(state.map.distance(kept, first) >= 5)
        guard case let .move(_, goal, _) = view.exploreStep(for: scout, goal: kept) else {
            Issue.record("expected a move")
            return
        }
        #expect(goal == kept)
    }

    /// A Scout's reach (Strength 10) counts only against a Scout: a Warrior on the order does not
    /// turn aside for it, nor end its order because the way on is within it; a Scout still
    /// does. Other enemies' reach counts for both, as `enemyReach` reckons it.
    @Test func aWarriorIgnoresAScoutsReach() throws {
        var state = makeWarState(width: 30, height: 14)
        let warrior = state.addUnit(.warrior, owner: me, at: hex(8, 7))
        let scout = state.addUnit(.scout, owner: me, at: hex(8, 9))
        let enemyScout = state.addUnit(.scout, owner: them, at: hex(10, 7))
        var view = state.view(for: me)
        let warriorThreats = view.exploreThreats(for: try #require(view.unit(warrior)))
        let scoutThreats = view.exploreThreats(for: try #require(view.unit(scout)))
        #expect(warriorThreats.allSatisfy { $0 == nil })
        #expect(scoutThreats.map { $0 != nil } == view.enemyReach())
        #expect(scoutThreats.contains(.unit(enemyScout)))
        // An enemy Warrior's reach counts for both.
        let enemyWarrior = state.addUnit(.warrior, owner: them, at: hex(10, 10))
        view = state.view(for: me)
        try #require(view.unit(enemyScout) != nil && view.unit(enemyWarrior) != nil)
        #expect(view.exploreThreats(for: try #require(view.unit(warrior))).contains(.unit(enemyWarrior)))

        // p3e's iPhone side game: a corridor two rows high, an enemy Scout in it, unexplored land
        // only beyond. A Scout's order ends; a Warrior walks on.
        var corridor = makeTestState(map: openMap(width: 16, height: 2), parkSettlers: false)
        setWar(&corridor, me, them)
        let guardian = corridor.addUnit(.scout, owner: them, at: hex(6, 1))
        let walker = corridor.addUnit(.scout, owner: me, at: hex(4, 0))
        let fighter = corridor.addUnit(.warrior, owner: me, at: hex(3, 1))
        explore(&corridor) { $0.col <= 8 }
        let v = corridor.view(for: me)
        try #require(v.unit(guardian) != nil)
        #expect(v.exploreStep(for: walker, knownEnemies: [guardian]) == .end(.enemyReach))
        if case .end = v.exploreStep(for: fighter, knownEnemies: [guardian]) { Issue.record("a Warrior stopped for a Scout's reach") }
    }

    /// Without enemy recon units, an explorer's threats cover exactly `enemyReach`: the reach of
    /// enemy units in sight and the bombard range of remembered enemy cities.
    @Test func threatsCoverTheEnemyReach() throws {
        var state = makeWarState(width: 30, height: 14)
        let warrior = state.addUnit(.warrior, owner: me, at: hex(6, 7))
        state.addUnit(.scout, owner: me, at: hex(9, 7)) // sees the enemy units
        let archer = state.addUnit(.archer, owner: them, at: hex(10, 6))
        let spearman = state.addUnit(.spearman, owner: them, at: hex(9, 9))
        let city = addCity(&state, them, at: hex(14, 7))
        state.addUnit(.warrior, owner: me, at: hex(12, 7)) // sees the city
        refreshKnowledge(&state)
        let view = state.view(for: me)
        try #require(view.unit(archer) != nil && view.unit(spearman) != nil && view.knownCities.contains { $0.id == city })
        let threats = view.exploreThreats(for: try #require(view.unit(warrior)))
        #expect(threats.map { $0 != nil } == view.enemyReach())
        #expect(threats.contains(.unit(archer)) && threats.contains(.unit(spearman)) && threats.contains(.city(city)))
    }

    /// A step that leads no nearer its goal, to keep out of an enemy's reach, says whose; a step
    /// on the direct way says nothing.
    @Test func aDetourNamesTheReachItKeepsOutOf() throws {
        // An enemy Archer beside the Scout, the unexplored land to the east: the Scout steps
        // back out of its reach, no nearer its goal, and says whose reach it keeps out of.
        var state = makeTestState(map: openMap(width: 26, height: 14), parkSettlers: false)
        setWar(&state, me, them)
        let here = hex(8, 7)
        let scout = state.addUnit(.scout, owner: me, at: here)
        let archer = state.addUnit(.archer, owner: them, at: hex(9, 7))
        explore(&state) { $0.col <= 12 }
        let view = state.view(for: me)
        try #require(view.unit(archer) != nil)
        let step = view.exploreStep(for: scout, knownEnemies: [archer])
        guard case let .move(to, goal, avoiding) = step else {
            Issue.record("expected a move, got \(step)")
            return
        }
        #expect(state.map.distance(to, goal) >= state.map.distance(here, goal), "\(step)")
        #expect(avoiding == .unit(archer), "\(step)")
        #expect(view.exploreThreats(for: try #require(view.unit(scout)))[tile(state, to)] == nil)
        // A step on the way, or any step at peace, avoids nothing.
        var calm = makeTestState(map: openMap(width: 30, height: 14), parkSettlers: false)
        let walker = calm.addUnit(.scout, owner: me, at: hex(8, 7))
        guard case let .move(_, _, none) = calm.view(for: me).exploreStep(for: walker) else {
            Issue.record("expected a move")
            return
        }
        #expect(none == nil)
    }

    /// Below 50 HP with no enemy in sight it rests where it stands, and goes on resting until
    /// 80 HP; with an enemy in sight it does not, nor where an enemy could strike it. `resting:
    /// nil` asks the unit: it rested last phase when it neither moved nor attacked then.
    @Test func aWoundedExplorerRestsUntilItHasHealed() throws {
        var state = makeTestState(map: openMap(width: 30, height: 14))
        let scout = state.addUnit(.scout, owner: me, at: hex(4, 7))
        guard case let .move(_, goal, _) = state.view(for: me).exploreStep(for: scout) else {
            Issue.record("expected a move")
            return
        }
        func step(hp: Int, resting: Bool?) -> ExploreStep {
            state.updateUnit(scout) { $0.hp = hp }
            return state.view(for: me).exploreStep(for: scout, resting: resting)
        }
        #expect(step(hp: 49, resting: false) == .rest(goal: goal, untilHP: 80))
        #expect(step(hp: 50, resting: false) != .rest(goal: goal, untilHP: 80))
        #expect(step(hp: 79, resting: true) == .rest(goal: goal, untilHP: 80))
        if case .rest = step(hp: 80, resting: true) { Issue.record("rested at 80 HP") }
        // The unit tells: at turn 2, not having acted since turn 0, it rested last phase.
        try nextTurn(&state)
        #expect(step(hp: 60, resting: nil) == .rest(goal: goal, untilHP: 80))
        let lastTurn = state.turn - 1
        state.updateUnit(scout) { $0.lastActedTurn = lastTurn }
        if case .rest = step(hp: 60, resting: nil) { Issue.record("rested after moving last phase") }
        // An enemy in its sight (known when the order was given): no rest.
        setWar(&state, me, them)
        let enemy = state.addUnit(.warrior, owner: them, at: hex(6, 7))
        state.updateUnit(scout) { $0.hp = 30 }
        if case .rest = state.view(for: me).exploreStep(for: scout, knownEnemies: [enemy]) { Issue.record("rested with an enemy in sight") }

        // An enemy out of its sight (a lookout sees it) that could strike it there, an Archer
        // three tiles off: it walks on, out of reach, and rests where none can.
        var war = makeWarState(width: 30, height: 14)
        let wounded = war.addUnit(.warrior, owner: me, at: hex(10, 7))
        let raider = war.addUnit(.archer, owner: them, at: hex(13, 7))
        war.addUnit(.warrior, owner: me, at: hex(15, 7)) // the lookout
        war.updateUnit(wounded) { $0.hp = 30 }
        refreshKnowledge(&war)
        let view = war.view(for: me)
        try #require(view.unit(raider) != nil && view.enemiesInSight(of: wounded).isEmpty)
        let threats = view.exploreThreats(for: try #require(view.unit(wounded)))
        #expect(threats[tile(war, hex(10, 7))] == .unit(raider))
        let walk = view.exploreStep(for: wounded)
        guard case let .move(to, _, _) = walk else {
            Issue.record("expected a move out of reach, got \(walk)")
            return
        }
        #expect(threats[tile(war, to)] == nil)
        try apply(.moveUnit(unit: wounded, to: to), &war)
        if case .rest = war.view(for: me).exploreStep(for: wounded, resting: false) {} else {
            Issue.record("did not rest out of reach")
        }
    }

    // MARK: Finds (p3f app-explore-finds)

    /// A walk that brings a good city site into view near an own city finds it: here the ground
    /// by a lake east of the city, the best of what lies within 8 tiles of it. Sites near one
    /// already announced, and sites it knew as good, are not found again.
    @Test func aWalkFindsGoodCitySites() throws {
        var map = openMap(width: 30, height: 14)
        map[hex(17, 7)] = Tile(terrain: .lake)
        map[hex(16, 8)] = Tile(terrain: .plains, elevation: .hills)
        var state = makeTestState(map: map, parkSettlers: false)
        let city = addCity(&state, me, at: hex(10, 7))
        explore(&state) { $0.col <= 13 }
        let before = state.view(for: me)
        #expect(before.goodCitySites().allSatisfy { state.map.coord(at: $0.tile).offset.col <= 13 })
        explore(&state) { $0.col <= 19 }
        let after = state.view(for: me)
        let finds = after.exploreFinds(since: before)
        let best = try #require(finds.first)
        #expect(state.map.distance(best.hex, hex(17, 7)) == 1, "\(best)")
        #expect(best.city == city && best.cityName == state.city(city)?.name && best.distance == state.map.distance(best.hex, hex(10, 7)))
        #expect(best.score == after.settleScore(at: best.hex) && best.distance <= state.rules.ai.settleMaxCityDistance)
        #expect(finds.allSatisfy { after.goodCitySites().map(\.tile).contains(tile(state, $0.hex)) })
        #expect(zip(finds, finds.dropFirst()).allSatisfy { $0.score >= $1.score })
        // Announced: nothing within 3 tiles of it is found again; nothing is found twice.
        let spacing = state.rules.constants.city.minDistance - 1
        #expect(after.exploreFinds(since: before, announced: [best.hex]).allSatisfy { state.map.distance($0.hex, best.hex) > spacing })
        #expect(after.exploreFinds(since: after).isEmpty)
        // Without an own city there is nothing near one.
        var empty = makeTestState(map: map, parkSettlers: false)
        explore(&empty) { $0.col <= 13 }
        let early = empty.view(for: me)
        explore(&empty) { $0.col <= 19 }
        #expect(empty.view(for: me).exploreFinds(since: early).isEmpty)
    }

    /// Finds come only from what the player knows: a city and units it has not seen change
    /// nothing.
    @Test func findsLeakNothing() throws {
        func game(_ hide: (inout GameState) -> Void) -> (PlayerView, PlayerView) {
            var map = openMap(width: 30, height: 14)
            map[hex(17, 7)] = Tile(terrain: .lake)
            var state = makeTestState(map: map, parkSettlers: false)
            addCity(&state, me, at: hex(10, 7))
            hide(&state)
            refreshKnowledge(&state)
            explore(&state) { $0.col <= 13 }
            let before = state.view(for: me)
            explore(&state) { $0.col <= 19 }
            return (before, state.view(for: me))
        }
        let (a0, a1) = game { _ in }
        let (b0, b1) = game { state in
            addCity(&state, them, at: hex(24, 3))
            state.addUnit(.warrior, owner: them, at: hex(26, 10))
        }
        try #require(a1.explored == b1.explored)
        #expect(a1.exploreFinds(since: a0) == b1.exploreFinds(since: b0))
        #expect(a1.goodCitySites() == b1.goodCitySites())
    }

    // MARK: Tribal villages (p3g, M1 §7.7)

    /// Places a tribal village on each of `villages` (`DebugTools.placeTribalVillage`) and lets
    /// player 0 see it once: a Scout of its stands at `lookouts[i]` (default: the first free
    /// neighbour) while knowledge is refreshed, and goes again. Player 0 then remembers it
    /// without seeing it now (unless its own units do).
    private func know(_ state: inout GameState, _ villages: [HexCoord], lookouts: [HexCoord]? = nil) throws {
        for (i, village) in villages.enumerated() {
            try #require(DebugTools.placeTribalVillage(at: village, in: &state), "\(village)")
            let spot = try #require(lookouts?[i] ?? state.map.neighbors(of: village).first { n in
                state.rules.isPassable(state.map[n]) && !state.units.contains { $0.position == n } && !villages.contains(n)
            })
            let lookout = state.insertUnit(.scout, owner: me, at: spot)
            refreshKnowledge(&state)
            state.removeUnit(lookout)
            refreshKnowledge(&state)
        }
        let view = state.view(for: me)
        try #require(villages.allSatisfy { view.isKnownTribalVillage($0) })
    }

    /// Player 0's Scout at (4,7) on open land 30×14 explored up to column `explored` (the
    /// frontier lies there; all of it at 29), knowing tribal villages at `villages`; `parked`:
    /// with each player's Settler parked in a corner (a command applied eliminates no one).
    private func tribalVillageScene(explored col: Int, villages: [HexCoord], parked: Bool = false) throws -> (state: GameState, scout: UnitID) {
        var state = makeTestState(map: openMap(width: 30, height: 14), parkSettlers: parked)
        let scout = state.addUnit(.scout, owner: me, at: hex(4, 7))
        try know(&state, villages)
        explore(&state) { $0.col <= col }
        return (state, scout)
    }

    /// The goal a step heads for (nil when the order ends).
    private func goal(of step: ExploreStep) -> HexCoord? {
        switch step {
        case let .move(_, goal, _), let .wait(goal), let .rest(goal, _): goal
        case .end: nil
        }
    }

    /// A tuning as the App's (`standard`), with a horizon of `turns` (nil: the rules').
    private func seeking(_ turns: Int?) -> ExploreTuning {
        var tuning = ExploreTuning.standard
        tuning.tribalVillageTurns = turns
        return tuning
    }

    /// A known tribal village it can reach within three turns' walk (the rules' `seekTurns`) is
    /// its goal before any frontier tile, even a nearer one; it walks the path there as far as
    /// it gets. With no horizon it heads for the frontier exactly as in a world without one.
    @Test func aTribalVillageWithinTheHorizonComesFirst() throws {
        let village = hex(2, 12)
        let (state, scout) = try tribalVillageScene(explored: 6, villages: [village])
        let view = state.view(for: me)
        let field = view.movementField(for: scout)
        let cost = field[tile(state, village)]
        try #require(cost > 0 && cost <= Int32(state.rules.points(3 * state.rules.unit(.scout).moves)))
        let nearestFrontier = try #require(view.aiFrontier().filter { field[$0] > 0 }.map { field[$0] }.min())
        try #require(nearestFrontier < cost)
        let step = view.exploreStep(for: scout)
        guard case let .move(to, goal, avoiding) = step else {
            Issue.record("expected a move, got \(step)")
            return
        }
        #expect(goal == village && avoiding == nil)
        #expect(to == view.path(for: scout, to: village)?.steps.last { $0.turn <= 1 }?.hex)
        // The horizon is the rules' (`seekTurns` 3) unless the tuning sets one.
        #expect(ExploreTuning.standard.tribalVillageTurns == nil && state.rules.tribalVillages?.seekTurns == 3)
        #expect(view.exploreStep(for: scout, knownEnemies: [], claimed: [], tuning: seeking(3)) == step)
        // Not seeking: as in the same world without the tribal village.
        let (plain, _) = try tribalVillageScene(explored: 6, villages: [])
        let off = view.exploreStep(for: scout, knownEnemies: [], claimed: [], tuning: seeking(0))
        #expect(off == plain.view(for: me).exploreStep(for: scout))
        #expect(self.goal(of: off).map { view.aiFrontier().contains(tile(state, $0)) } == true, "\(off)")
    }

    /// One beyond the horizon is not a goal while frontier is left (a longer horizon takes it);
    /// with no frontier left it is the goal at any distance, before the order ends.
    @Test func oneBeyondTheHorizonWaitsForTheFrontierToRunOut() throws {
        let village = hex(14, 7) // 10 tiles east: 10 points, beyond three turns' 9
        let (state, scout) = try tribalVillageScene(explored: 16, villages: [village])
        let view = state.view(for: me)
        try #require(view.movementField(for: scout)[tile(state, village)] == 30)
        let step = view.exploreStep(for: scout)
        #expect(goal(of: step).map { view.aiFrontier().contains(tile(state, $0)) } == true, "\(step)")
        #expect(goal(of: view.exploreStep(for: scout, knownEnemies: [], claimed: [], tuning: seeking(4))) == village)
        // Nothing left to explore: it heads there, however far, rather than end the order.
        var all = state
        explore(&all) { _ in true }
        let late = all.view(for: me)
        try #require(late.aiFrontier().isEmpty)
        let last = late.exploreStep(for: scout)
        guard case let .move(_, goal, _) = last else {
            Issue.record("expected a move, got \(last)")
            return
        }
        #expect(goal == village)
        #expect(late.exploreStep(for: scout, knownEnemies: [], claimed: [], tuning: seeking(0)) == .end(.explored(closedLand: [])))
    }

    /// Two at the same cost: the lower tile index. Another explorer's goal (`claimed`) is left to
    /// it, also when it was this one's goal; with every one claimed, the frontier.
    @Test func aClaimedTribalVillageLeadsElsewhere() throws {
        let north = hex(5, 3), south = hex(4, 11) // both 4 tiles from the Scout
        let (state, scout) = try tribalVillageScene(explored: 12, villages: [south, north])
        let view = state.view(for: me)
        let field = view.movementField(for: scout)
        try #require(field[tile(state, north)] == field[tile(state, south)] && tile(state, north) < tile(state, south))
        #expect(goal(of: view.exploreStep(for: scout)) == north)
        #expect(goal(of: view.exploreStep(for: scout, claimed: [north])) == south)
        #expect(goal(of: view.exploreStep(for: scout, claimed: [north], goal: north)) == south)
        let neither = view.exploreStep(for: scout, claimed: [north, south])
        #expect(goal(of: neither).map { view.aiFrontier().contains(tile(state, $0)) } == true, "\(neither)")
        // A claimed one is never taken when nothing else is left either: the order ends.
        var all = state
        explore(&all) { _ in true }
        #expect(all.view(for: me).exploreStep(for: scout, claimed: [north, south]) == .end(.explored(closedLand: [])))
        #expect(goal(of: all.view(for: me).exploreStep(for: scout, claimed: [north])) == south)
    }

    /// The tribal village it heads for stays its goal, even past the horizon and with another
    /// nearer, until it is seen gone (taken out of sight, it is still remembered); a frontier goal
    /// it headed for gives way to one within the horizon.
    @Test func itKeepsItsTribalVillageUntilItIsSeenGone() throws {
        let far = hex(16, 7), near = hex(4, 11) // 12 and 4 tiles from the Scout
        let scene = try tribalVillageScene(explored: 20, villages: [far, near])
        var state = scene.state
        let scout = scene.scout
        var view = state.view(for: me)
        #expect(goal(of: view.exploreStep(for: scout)) == near)
        #expect(goal(of: view.exploreStep(for: scout, goal: far)) == far)
        let frontierGoal = try #require(goal(of: view.exploreStep(for: scout, knownEnemies: [], claimed: [], tuning: seeking(0))))
        #expect(goal(of: view.exploreStep(for: scout, goal: frontierGoal)) == near)
        // Not seeking at all, nothing is kept.
        #expect(goal(of: view.exploreStep(for: scout, knownEnemies: [], claimed: [], goal: far, tuning: seeking(0))) == frontierGoal)
        // Taken out of the player's sight: still remembered, still the goal.
        removeTribalVillage(at: far, in: &state)
        view = state.view(for: me)
        try #require(view.isKnownTribalVillage(far))
        #expect(goal(of: view.exploreStep(for: scout, goal: far)) == far)
        // Seen gone: the nearest one within the horizon.
        reveal(&state, from: hex(15, 7))
        explore(&state) { $0.col <= 20 }
        view = state.view(for: me)
        try #require(!view.isKnownTribalVillage(far))
        #expect(goal(of: view.exploreStep(for: scout, goal: far)) == near)
    }

    /// Wounded, it rests with the tribal village still its goal, and walks on to it once healed;
    /// there the order goes on toward the frontier.
    @Test func itRestsAndGoesOnWithItsTribalVillage() throws {
        let village = hex(7, 7) // 3 tiles east: reached this phase
        let scene = try tribalVillageScene(explored: 12, villages: [village], parked: true)
        var state = scene.state
        let scout = scene.scout
        func step(hp: Int, resting: Bool) -> ExploreStep {
            state.updateUnit(scout) { $0.hp = hp }
            return state.view(for: me).exploreStep(for: scout, goal: village, resting: resting)
        }
        #expect(step(hp: 100, resting: false) == .move(to: village, goal: village, avoiding: nil))
        #expect(step(hp: 40, resting: false) == .rest(goal: village, untilHP: 80))
        #expect(step(hp: 79, resting: true) == .rest(goal: village, untilHP: 80))
        #expect(step(hp: 80, resting: true) == .move(to: village, goal: village, avoiding: nil))
        // It walks in (taking it, M1 §7.7); the order goes on toward the frontier.
        state.updateUnit(scout) { $0.hp = 100 }
        try apply(.moveUnit(unit: scout, to: village), &state)
        removeTribalVillage(at: village, in: &state) // what the take does (nothing if it is gone)
        let view = state.view(for: me)
        try #require(state.unit(scout)?.position == village && !view.isKnownTribalVillage(village))
        // Its moves spent there, it waits for the next phase, headed for the frontier.
        let next = view.exploreStep(for: scout, goal: village)
        guard case let .wait(goal) = next else {
            Issue.record("expected a wait, got \(next)")
            return
        }
        #expect(goal != village && view.aiFrontier().contains(tile(state, goal)))
        state.updateUnit(scout) { $0.movesLeft = 3 }
        guard case let .move(_, onward, _) = state.view(for: me).exploreStep(for: scout, goal: goal) else {
            Issue.record("expected a move on")
            return
        }
        #expect(onward == goal)
    }

    /// With no frontier left, a known tribal village it cannot reach (on an island) does not
    /// keep the order going.
    @Test func anUnreachableTribalVillageEndsNothing() throws {
        var map = openMap(width: 30, height: 14)
        let island = hex(20, 7)
        for n in map.neighbors(of: island) { map[n] = Tile(terrain: .lake) }
        var state = makeTestState(map: map, parkSettlers: false)
        let scout = state.addUnit(.scout, owner: me, at: hex(4, 7))
        try know(&state, [island], lookouts: [hex(22, 7)])
        explore(&state) { _ in true }
        let view = state.view(for: me)
        try #require(view.movementField(for: scout)[tile(state, island)] < 0)
        #expect(view.exploreStep(for: scout) == .end(.explored(closedLand: [])))
    }

    /// At war, a tribal village is a goal only through the safe field: one the Scout could reach
    /// only by stopping within an enemy's reach ends the order (`.enemyReach`), not `.explored`;
    /// one behind it, out of reach, is its goal; at peace the far one is.
    @Test func atWarATribalVillageCountsOnlyThroughReach() throws {
        func corridor(war: Bool, villages: [HexCoord]) throws -> (GameState, UnitID, UnitID) {
            var state = makeTestState(map: openMap(width: 16, height: 2), parkSettlers: false)
            if war { setWar(&state, me, them) }
            let walker = state.addUnit(.scout, owner: me, at: hex(4, 0))
            let guardian = state.addUnit(.warrior, owner: them, at: hex(6, 1))
            try know(&state, villages)
            explore(&state) { _ in true }
            try #require(state.view(for: me).unit(guardian) != nil)
            return (state, walker, guardian)
        }
        let beyond = hex(12, 0), behind = hex(1, 0)
        let (bare, walker, guardian) = try corridor(war: true, villages: [])
        #expect(bare.view(for: me).exploreStep(for: walker, knownEnemies: [guardian]) == .end(.explored(closedLand: [])))
        let (blocked, _, _) = try corridor(war: true, villages: [beyond])
        let view = blocked.view(for: me)
        try #require(view.movementField(for: walker)[tile(blocked, beyond)] > 0)
        #expect(view.exploreStep(for: walker, knownEnemies: [guardian]) == .end(.enemyReach))
        // Another explorer's: nothing is left to this one.
        #expect(view.exploreStep(for: walker, knownEnemies: [guardian], claimed: [beyond]) == .end(.explored(closedLand: [])))
        let (both, _, _) = try corridor(war: true, villages: [beyond, behind])
        #expect(goal(of: both.view(for: me).exploreStep(for: walker, knownEnemies: [guardian])) == behind)
        let (calm, _, _) = try corridor(war: false, villages: [beyond])
        #expect(goal(of: calm.view(for: me).exploreStep(for: walker)) == beyond)
    }

    /// A good city site on a known tribal village's tile is not a find (its sighting already
    /// points there); the other finds are as without it.
    @Test func noFindOnAKnownTribalVillage() throws {
        var map = openMap(width: 30, height: 14)
        map[hex(17, 7)] = Tile(terrain: .lake)
        map[hex(16, 8)] = Tile(terrain: .plains, elevation: .hills)
        var state = makeTestState(map: map, parkSettlers: false)
        addCity(&state, me, at: hex(10, 7))
        explore(&state) { $0.col <= 13 }
        let before = state.view(for: me)
        explore(&state) { $0.col <= 19 }
        let finds = state.view(for: me).exploreFinds(since: before)
        let best = try #require(finds.first)
        try know(&state, [best.hex])
        explore(&state) { $0.col <= 19 }
        let after = state.view(for: me)
        #expect(after.exploreFinds(since: before) == finds.filter { $0.hex != best.hex })
        #expect(after.goodCitySites().contains { $0.tile == tile(state, best.hex) })
    }

    /// Lets player 0 see what stands around `spot` once: a Scout of its stands there while
    /// knowledge is refreshed, and goes again.
    private func reveal(_ state: inout GameState, from spot: HexCoord) {
        let lookout = state.insertUnit(.scout, owner: me, at: spot)
        refreshKnowledge(&state)
        state.removeUnit(lookout)
        refreshKnowledge(&state)
    }

    /// G10 (M1 §7.7, §11): worlds that differ only in a tribal village player 0 never saw give
    /// the same steps and finds, whatever the order is told: here the hidden one lies nearer
    /// than the known one, on explored land, and on the best find's tile; and with no frontier
    /// left, at war or at peace. Without the rules section (C0) the steps are those of a world
    /// with none.
    @Test func aTribalVillageNeverSeenChangesNothing() throws {
        let known = hex(12, 7), hidden = hex(8, 9) // 8 and 5 tiles from the Scout
        func twins(explored col: Int, war: Bool = false) throws -> (GameState, GameState, UnitID) {
            let scene = try tribalVillageScene(explored: col, villages: [known])
            var a = scene.state
            let scout = scene.scout
            if war {
                setWar(&a, me, them)
                a.addUnit(.warrior, owner: them, at: hex(6, 9))
                explore(&a) { $0.col <= col }
            }
            var b = a
            try #require(DebugTools.placeTribalVillage(at: hidden, in: &b))
            let t = tile(b, hidden)
            try #require(!b.players[0].visible[t] && b.players[0].explored[t])
            try #require(a.view(for: me).knownTribalVillages == b.view(for: me).knownTribalVillages)
            return (a, b, scout)
        }
        for (col, war) in [(12, false), (29, false), (12, true), (29, true)] {
            let (a, b, scout) = try twins(explored: col, war: war)
            let va = a.view(for: me), vb = b.view(for: me)
            let enemies = va.enemiesInSight(of: scout)
            for (claimed, goal) in [([], nil), ([known], nil), ([], known), ([], hex(20, 3)), ([known], hidden)] as [([HexCoord], HexCoord?)] {
                for tuning in [ExploreTuning.standard, seeking(1), seeking(10)] {
                    let x = va.exploreStep(for: scout, knownEnemies: enemies, claimed: claimed, goal: goal, tuning: tuning)
                    let y = vb.exploreStep(for: scout, knownEnemies: enemies, claimed: claimed, goal: goal, tuning: tuning)
                    #expect(x == y, "explored to \(col), war \(war), claimed \(claimed), goal \(goal.map { "\($0)" } ?? "none"): \(x) vs \(y)")
                }
            }
            let unit = try #require(va.unit(scout))
            for current in [nil, tile(a, known), tile(a, hidden)] as [Int?] {
                #expect(va.exploreTribalVillage(unit, field: va.movementField(for: scout), claimed: [], current: current, turns: nil)
                    == vb.exploreTribalVillage(unit, field: vb.movementField(for: scout), claimed: [], current: current, turns: nil))
            }
        }
        // The find on the hidden one's tile is still a find.
        var map = openMap(width: 30, height: 14)
        map[hex(17, 7)] = Tile(terrain: .lake)
        map[hex(16, 8)] = Tile(terrain: .plains, elevation: .hills)
        var a = makeTestState(map: map, parkSettlers: false)
        addCity(&a, me, at: hex(10, 7))
        explore(&a) { $0.col <= 13 }
        let before = a.view(for: me)
        explore(&a) { $0.col <= 19 }
        let best = try #require(a.view(for: me).exploreFinds(since: before).first)
        var b = a
        try #require(DebugTools.placeTribalVillage(at: best.hex, in: &b))
        try #require(!b.view(for: me).isKnownTribalVillage(best.hex))
        #expect(a.view(for: me).exploreFinds(since: before) == b.view(for: me).exploreFinds(since: before))
        // C0: no tribal villages at all, the steps of a world without them.
        var c0 = makeTestState(map: openMap(width: 30, height: 14), parkSettlers: false, rules: try c0Rules())
        let c0Scout = c0.addUnit(.scout, owner: me, at: hex(4, 7))
        #expect(!DebugTools.placeTribalVillage(at: known, in: &c0))
        explore(&c0) { $0.col <= 12 }
        let (plain, scout) = try tribalVillageScene(explored: 12, villages: [])
        try #require(c0Scout == scout)
        #expect(c0.view(for: me).exploreStep(for: scout) == plain.view(for: me).exploreStep(for: scout))
    }
}
