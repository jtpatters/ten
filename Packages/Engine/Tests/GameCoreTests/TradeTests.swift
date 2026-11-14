import Testing
@testable import GameCore

// M2 §13 trade routes on an open 20×8 map: player 0 has cities at (2, 4) and (8, 4), player 1
// one at (14, 4). Everyone has explored the whole map.

@Suite struct TradeTests {
    let p0 = PlayerID(0), p1 = PlayerID(1)

    func world() -> (GameState, CityID, CityID, CityID) {
        let map = openMap(width: 20, height: 8)
        let players = [
            Player(id: p0, name: "P0", isHuman: true, tileCount: map.tileCount, gold: 100),
            Player(id: p1, name: "P1", isHuman: false, tileCount: map.tileCount, gold: 100),
        ]
        var state = GameState(seed: 5, map: map, players: players, rules: .standard)
        let a = addCity(&state, p0, at: hex(2, 4))
        let b = addCity(&state, p0, at: hex(8, 4))
        let c = addCity(&state, p1, at: hex(14, 4))
        for p in 0..<2 { for t in 0..<map.tileCount { state.players[p].explored[t] = true } }
        var fx = Effects()
        state.meet(p0, p1, &fx)
        refreshKnowledge(&state)
        state.remember(state.city(c)!, by: p0)
        return (state, a, b, c)
    }

    func trader(_ state: inout GameState, in city: CityID) -> UnitID {
        state.addUnit(.trader, owner: state.city(city)!.owner, at: state.city(city)!.position)
    }

    @Test func aDomesticRoutePaysFromArrivalLaysRoadsAndBringsTheTraderHome() throws {
        var (state, a, b, _) = world()
        let id = trader(&state, in: a)
        #expect(state.tradeCapacity(of: p0) == 1)
        _ = try GameEngine.perform(.startTradeRoute(unit: id, toCity: b), by: p0, on: &state)
        let route = try #require(state.tradeRoutes(of: p0).first)
        #expect(state.unit(id) == nil && route.kind == .domestic && route.path.count == 6)
        #expect(route.path.allSatisfy { state.map.tiles[Int($0)].hasRoad })
        #expect(route.arrives == state.turn + 3 && route.ends == route.arrives + state.rules.trade!.routeTurns)
        #expect(state.tradeYields(state.city(a)!) == .zero, "not before the Trader arrives")
        state.turn = route.arrives
        #expect(state.tradeYields(state.city(a)!) == Yields(food: 2, production: 1))
        state.cities[state.cityIndex(b)!].buildings.append("granary")
        #expect(state.tradeYields(state.city(a)!) == Yields(food: 3, production: 1))
        #expect(state.cityYields(state.city(a)!).breakdown.contains { $0.source == .trade })
        expectSound(state)

        let second = trader(&state, in: a)
        #expect(state.tradeRouteProblem(state.unit(second)!, to: b) == "no trade route capacity left")
        state.turn = route.ends
        var fx = Effects()
        state.runTrade(for: p0, &fx)
        state.updateKnowledge(&fx)
        #expect(state.tradeRoutes == nil)
        #expect(state.units.filter { $0.owner == p0 && $0.type == .trader }.count == 2)
        expectSound(state)
    }

    @Test func anInternationalRoutePaysBothSidesAndNeedsPeace() throws {
        var (state, _, b, c) = world()
        let id = trader(&state, in: b)
        _ = try GameEngine.perform(.startTradeRoute(unit: id, toCity: c), by: p0, on: &state)
        let route = try #require(state.tradeRoutes?.first)
        state.turn = route.arrives
        #expect(route.kind == .international && state.tradeYields(state.city(b)!).gold == 3)
        #expect(state.tradeYields(state.city(c)!) == Yields(gold: 1))
        let other = trader(&state, in: b)
        var fx = Effects()
        state.declareWar(p0, on: p1, &fx)
        #expect(state.tradeRouteProblem(state.unit(other)!, to: c) != nil)
        state.runTrade(for: p0, &fx)
        #expect(state.tradeRoutes == nil, "a war breaks the route")
    }

    @Test func anEnemyOnTheRoutePlundersIt() throws {
        var (state, a, b, _) = world()
        let id = trader(&state, in: a)
        _ = try GameEngine.perform(.startTradeRoute(unit: id, toCity: b), by: p0, on: &state)
        let route = try #require(state.tradeRoutes?.first)
        var fx = Effects()
        state.declareWar(p1, on: p0, &fx)
        let spot = state.map.coord(at: Int(route.path[1]))
        let raider = state.addUnit(.warrior, owner: p1, at: spot)
        #expect(state.plunderProblem(state.unit(raider)!) == nil)
        let gold = state.players[1].gold
        let events = try GameEngine.perform(.plunder(unit: raider), by: p1, on: &state)
        #expect(state.tradeRoutes == nil && state.players[1].gold == gold + state.rules.trade!.plunderGold)
        #expect(events.contains { if case .tradeRouteEnded(_, _, p1?) = $0.event { true } else { false } })
        #expect(!state.units.contains { $0.type == .trader }, "a plundered Trader is lost")
        expectSound(state)
    }

    @Test func aCapturedTraderIsRemovedForGold() throws {
        var (state, a, _, _) = world()
        let id = trader(&state, in: a)
        let spot = state.map.neighbors(of: state.city(a)!.position).first!
        state.updateUnit(id) { $0.position = spot }
        var fx = Effects()
        state.declareWar(p1, on: p0, &fx)
        let gold = state.players[1].gold
        state.captureCivilians(at: tile(state, spot), by: p1, &fx)
        #expect(state.unit(id) == nil && !state.units.contains { $0.owner == p1 && $0.type == .trader })
        #expect(state.players[1].gold == gold + state.rules.trade!.traderCaptureGold)
    }
}
