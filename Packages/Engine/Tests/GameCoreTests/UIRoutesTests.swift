import Foundation
import Testing
@testable import GameCore

// Why a route is refused (GameCore/Queries/UIRoutes.swift, M1 §16): closed borders at peace
// (Scouts too, M1 §9), a garrisoned city, water or mountains, no land route; from what the
// player knows only. And whether a route rests on unexplored ground (`routeFog`).

@Suite struct UIRoutesTests {
    private let me = PlayerID(0), them = PlayerID(1)

    /// At peace, a Scout cannot route into the other player's land, and the refusal says so.
    @Test func closedBordersAtPeace() throws {
        var state = makeTestState(map: openMap())
        addCity(&state, them, at: hex(6, 3))
        let scout = state.addUnit(.scout, owner: me, at: hex(3, 3))
        let builder = state.addUnit(.builder, owner: me, at: hex(3, 4))
        state.updateRelation(me, them) { $0.met = true }
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let owned = hex(5, 3)
        #expect(view.knownOwner(at: owned) == them)
        #expect(view.path(for: scout, to: owned) == nil)
        #expect(view.routeRefusal(for: scout, to: owned) == .closedBorders(them))
        #expect(view.landClosed(by: them) && !view.landClosed(by: me))
        // Civilians may enter.
        #expect(view.path(for: builder, to: owned) != nil)
        #expect(view.routeRefusal(for: builder, to: owned) == nil)
        // At war the land is open.
        setWar(&state, me, them)
        #expect(state.view(for: me).routeRefusal(for: scout, to: owned) == nil)
        #expect(!state.view(for: me).landClosed(by: them))
    }

    /// Beyond closed land: every way crosses it.
    @Test func closedBordersOnTheWay() throws {
        // A strip of the other player's land across the map: columns 5–6 claimed by its cities.
        var state = makeTestState(width: 12, height: 5, map: openMap(width: 12, height: 5))
        let a = addCity(&state, them, at: hex(5, 0))
        let b = addCity(&state, them, at: hex(5, 4))
        for row in 0..<5 {
            for col in 5...6 { claimTile(&state, hex(col, row), for: row < 2 ? a : b) }
        }
        // Units along the strip see all of it (borders are known where seen).
        let scout = state.addUnit(.scout, owner: me, at: hex(4, 2))
        state.addUnit(.warrior, owner: me, at: hex(4, 0))
        state.addUnit(.warrior, owner: me, at: hex(4, 4))
        state.updateRelation(me, them) { $0.met = true }
        for t in 0..<state.map.tileCount { state.players[0].explored[t] = true }
        refreshKnowledge(&state)
        let view = state.view(for: me)
        for row in 0..<5 { #expect(view.knownOwner(at: hex(6, row)) == them) }
        #expect(view.path(for: scout, to: hex(9, 2)) == nil)
        #expect(view.routeRefusal(for: scout, to: hex(9, 2)) == .closedBordersOnTheWay([them]))
    }

    /// An own city that already holds a military unit refuses another; a civilian may join it.
    @Test func aGarrisonedCity() throws {
        var state = makeTestState(map: openMap())
        let city = addCity(&state, me, at: hex(3, 3))
        _ = city
        _ = state.addUnit(.warrior, owner: me, at: hex(3, 3))
        let other = state.addUnit(.spearman, owner: me, at: hex(1, 3))
        let builder = state.addUnit(.builder, owner: me, at: hex(1, 4))
        refreshKnowledge(&state)
        let view = state.view(for: me)
        #expect(view.path(for: other, to: hex(3, 3)) == nil)
        #expect(view.routeRefusal(for: other, to: hex(3, 3)) == .ownUnitThere(.warrior))
        #expect(view.routeRefusal(for: builder, to: hex(3, 3)) == nil)
    }

    /// Water and mountains, explored, are refused by their ground.
    @Test func waterAndMountains() throws {
        var state = makeTestState() // the test map: mountains at (5,2)-(5,4), a lake at (8,6)
        let w = state.addUnit(.warrior, owner: me, at: hex(7, 5))
        refreshKnowledge(&state)
        let view = state.view(for: me)
        #expect(view.isExplored(hex(8, 6)))
        #expect(view.routeRefusal(for: w, to: hex(8, 6)) == .impassable(.water))
        let m = state.addUnit(.warrior, owner: me, at: hex(4, 3))
        refreshKnowledge(&state)
        #expect(state.view(for: me).routeRefusal(for: m, to: hex(5, 3)) == .impassable(.mountains))
        // Where it stands, or a tile it can reach: no refusal.
        #expect(state.view(for: me).routeRefusal(for: m, to: hex(4, 3)) == nil)
        #expect(state.view(for: me).routeRefusal(for: m, to: hex(2, 3)) == nil)
    }

    /// Land beyond explored water: no land route, as far as the player knows. Unexplored water
    /// would count as land (the pathfinder plans through fog).
    @Test func noLandRoute() throws {
        var map = openMap()
        for row in 0..<map.height { map[hex(6, row)] = Tile(terrain: .coast) }
        var state = makeTestState(map: map)
        let w = state.addUnit(.warrior, owner: me, at: hex(4, 3))
        refreshKnowledge(&state)
        for t in 0..<state.map.tileCount where state.map.coord(at: t).offset.col <= 6 { state.players[0].explored[t] = true }
        let view = state.view(for: me)
        #expect(view.path(for: w, to: hex(9, 3)) == nil)
        #expect(view.routeRefusal(for: w, to: hex(9, 3)) == .noLandRoute)
        // The goal itself is water.
        #expect(view.routeRefusal(for: w, to: hex(6, 3)) == .impassable(.water))
    }

    /// A foreign city refuses entry; an enemy military unit in sight blocks its tile.
    @Test func foreignCitiesAndUnits() throws {
        var state = makeTestState(map: openMap())
        let city = addCity(&state, them, at: hex(7, 3))
        let w = state.addUnit(.warrior, owner: me, at: hex(5, 3))
        _ = state.addUnit(.spearman, owner: them, at: hex(5, 5))
        state.updateRelation(me, them) { $0.met = true }
        refreshKnowledge(&state)
        #expect(state.view(for: me).knownCity(at: hex(7, 3))?.id == city)
        #expect(state.view(for: me).routeRefusal(for: w, to: hex(7, 3)) == .foreignCity(city))
        setWar(&state, me, them)
        let view = state.view(for: me)
        #expect(view.isVisible(hex(5, 5)))
        #expect(view.routeRefusal(for: w, to: hex(5, 5)) == .foreignUnit(owner: them, type: .spearman))
    }

    /// A route over explored ground is firm; one to an unexplored goal, or through unexplored
    /// tiles, is a guess (the pathfinder counts them as land at one move), and says which.
    @Test func routesThroughFogAreMarked() throws {
        var state = makeTestState(map: openMap())
        let w = state.addUnit(.warrior, owner: me, at: hex(2, 3))
        refreshKnowledge(&state)
        var view = state.view(for: me)
        // In sight: explored all the way.
        let near = try #require(view.path(for: w, to: hex(3, 3)))
        #expect(view.routeFog(near) == nil)
        // Far off: the goal is unexplored.
        #expect(!view.isExplored(hex(9, 3)))
        let far = try #require(view.path(for: w, to: hex(9, 3)))
        #expect(view.routeFog(far) == .goal)
        // The goal explored, the way there not.
        state.players[0].explored[state.map.index(of: hex(9, 3))!] = true
        view = state.view(for: me)
        let through = try #require(view.path(for: w, to: hex(9, 3)))
        #expect(through.steps.contains { !view.isExplored($0.hex) })
        #expect(view.routeFog(through) == .way)
    }
}
