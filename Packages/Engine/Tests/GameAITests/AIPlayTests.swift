import Testing
@testable import GameAI
@testable import GameCore

// Play-quality rules added by ai-2 on top of M1 §13: Settlers retarget beyond the move-cost
// limit, the army assaults only once enough of it stands at the target, and units bought after
// the military moved fortify instead of standing idle.

private let p0 = PlayerID(0)
private let p1 = PlayerID(1)

@Suite struct AIPlayTests {
    /// A Settler with no good site within settleMaxMoveCost heads for the nearest good site
    /// beyond it instead of sleeping in a city.
    @Test func settlerHeadsForAFarGoodSite() throws {
        var map = openMap(width: 26, height: 12, fill: Tile(terrain: .desert))
        for t in 0..<map.tileCount where map.coord(at: t).offset.col >= 14 { map[map.coord(at: t)] = Tile(terrain: .grassland) }
        var state = makeState(map: map)
        addCity(&state, p0, at: hex(2, 6))
        addCity(&state, p0, at: hex(22, 6))
        addCity(&state, p1, at: hex(24, 11))
        let settler = state.addUnit(.settler, owner: p0, at: hex(2, 6))
        for t in 0..<state.map.tileCount { state.players[0].explored[t] = true }
        refreshKnowledge(&state)
        let view = state.view(for: p0)
        let ai = state.rules.ai
        let field = view.movementField(for: settler)
        func good(_ t: Int) -> Bool {
            view.canFoundCity(at: view.coord(at: t)) && view.settleScore(at: view.coord(at: t)) >= ai.minSettleScore
        }
        try #require((0..<view.tileCount).allSatisfy { field[$0] < 0 || field[$0] > ai.settleMaxMoveCost || !good($0) })
        try #require((0..<view.tileCount).contains { good($0) && state.map.distance(view.coord(at: $0), hex(22, 6)) <= ai.settleMaxCityDistance })
        let (commands, _) = playPhase(&state)
        #expect(!commands.contains(.sleep(unit: settler)))
        let after = try #require(state.unit(settler))
        #expect(after.position.offset.col > 2)
        #expect(after.activity != .sleeping)
    }

    /// The march on a target at war: two archers and two warriors standing within
    /// siegeStageRadius of it make the assault; with one archer there, the army only stages.
    @Test func assaultNeedsTheArmyAtTheTarget() throws {
        func world(archers: Int) -> GameState {
            var state = makeState(map: openMap(width: 24, height: 12))
            addCity(&state, p0, at: hex(3, 6))
            addCity(&state, p1, at: hex(14, 6))
            state.players[0].knownTechs.append("archery")
            state.addUnit(.warrior, owner: p0, at: hex(3, 6))
            let spots = [hex(10, 5), hex(10, 7), hex(10, 6), hex(11, 3)]
            for i in 0..<archers { state.addUnit(.archer, owner: p0, at: spots[i]) }
            state.addUnit(.warrior, owner: p0, at: hex(11, 4))
            state.addUnit(.warrior, owner: p0, at: hex(11, 8))
            reveal(&state, to: p0, from: hex(13, 6))
            state.turn = 60
            setRelation(&state, p0, p1, war: true, since: 40)
            refreshKnowledge(&state)
            return state
        }
        var ready = world(archers: 2)
        let target = try #require(ready.view(for: p0).knownCities.first { $0.owner == p1 })
        let radius = ready.rules.ai.siegeStageRadius
        try #require(ready.units.filter { $0.owner == p0 && $0.position != hex(3, 6) }
            .allSatisfy { ready.map.distance($0.position, target.position) <= radius })
        let (_, report) = playPhase(&ready)
        #expect(report.posture == .war && report.advancing && report.target == target.id)
        #expect(report.planSummary.contains("assault"))
        var short = world(archers: 1)
        let (_, shortReport) = playPhase(&short)
        #expect(shortReport.advancing)
        #expect(!shortReport.planSummary.contains("assault"))
    }

    /// After a phase every military unit has something to do: none is left with full moves,
    /// no activity and no orders (units bought after the military moved fortify).
    @Test func noIdleMilitaryAfterAPhase() throws {
        var state = aiGame(.duel, seed: 7)
        playAI(&state, until: 60)
        try #require(state.currentPlayer == p0 && state.outcome == nil)
        _ = AIPlayer.playTurn(&state, player: p0)
        let idle = state.units.filter { u in
            u.owner == p0 && !u.type.isCivilian && u.activity == .none && u.destination == nil && !u.zocStopped
                && u.movesLeft == state.rules.unit(u.type).moves
        }
        #expect(idle.isEmpty, "idle: \(idle.map(\.id))")
    }
}
