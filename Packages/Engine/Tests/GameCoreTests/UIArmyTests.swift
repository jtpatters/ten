import Foundation
import Testing
@testable import GameCore

// The war tools' queries (GameCore/Queries/UIArmy.swift): a group's formation around a goal,
// and one production order for many cities.

@Suite struct UIArmyTests {
    private let me = PlayerID(0), them = PlayerID(1)

    /// Three Warriors sent to open ground: one takes the goal, the others tiles next to it,
    /// each its own, each with a route.
    @Test func packsAroundTheGoal() throws {
        var state = makeTestState(map: openMap(width: 20, height: 12))
        let ids = [hex(2, 5), hex(2, 6), hex(3, 6)].map { state.addUnit(.warrior, owner: me, at: $0) }
        let goal = hex(10, 6)
        let view = state.view(for: me)
        let plan = view.formation(of: ids, around: goal)
        #expect(plan.placed == 3 && plan.unreachable.isEmpty)
        #expect(Set(plan.slots.values).count == 3)
        #expect(plan.slots.values.contains(goal))
        for (id, slot) in plan.slots {
            #expect(view.distance(slot, goal) <= 1)
            #expect(try #require(view.path(for: id, to: slot)).turns == plan.turns[id])
        }
        // They come from the west: the tiles beside the goal are on its west side.
        let vanguard = hex(3, 6)
        for slot in plan.slots.values where slot != goal { #expect(view.distance(slot, vanguard) <= view.distance(goal, vanguard)) }
        #expect(plan.arrivals != nil)
        // Ordered as planned, all march, and none is refused.
        for (id, slot) in plan.slots { try apply(.moveUnit(unit: id, to: slot), &state) }
        expectSound(state)
    }

    /// Sent at an enemy city, the group closes around it: no one is sent onto the city.
    @Test func surroundsAnEnemyCity() throws {
        var state = makeWarState(width: 20, height: 12)
        let city = hex(12, 6)
        addCity(&state, them, at: city)
        let ids = [hex(10, 5), hex(10, 6), hex(10, 7), hex(9, 6)].map { state.addUnit(.warrior, owner: me, at: $0) }
        refreshKnowledge(&state)
        let view = state.view(for: me)
        #expect(view.knownCity(at: city) != nil)
        let plan = view.formation(of: ids, around: city)
        #expect(plan.placed == 4 && plan.unreachable.isEmpty)
        #expect(!plan.slots.values.contains(city))
        #expect(plan.slots.values.allSatisfy { view.distance($0, city) == 1 })
    }

    /// A unit already on a tile the group needs stays there; reserved tiles are left alone.
    @Test func keepsUnitsInPlaceAndSkipsReservedTiles() throws {
        var state = makeTestState(map: openMap(width: 20, height: 12))
        let goal = hex(10, 6)
        let there = state.addUnit(.warrior, owner: me, at: goal)
        let far = state.addUnit(.warrior, owner: me, at: hex(2, 6))
        let view = state.view(for: me)
        let plan = view.formation(of: [far, there], around: goal)
        #expect(plan.slots[there] == goal && plan.turns[there] == 0)
        #expect(plan.slots[far].map { view.distance($0, goal) } == 1)

        let reserved = Set(view.neighbors(of: goal))
        let ringed = view.formation(of: [far], around: hex(10, 6), reserved: reserved.union([goal]))
        let slot = try #require(ringed.slots[far])
        #expect(!reserved.contains(slot) && slot != goal && view.distance(slot, goal) == 2)
    }

    /// Tiles held by own units outside the group are skipped, and the formation reaches as far
    /// out as it needs to place everyone: a rally point already crowded still takes newcomers.
    @Test func growsPastTilesAlreadyHeld() throws {
        var state = makeTestState(map: openMap(width: 20, height: 12))
        let goal = hex(10, 6)
        for spot in [goal] + state.map.neighbors(of: goal) { state.addUnit(.warrior, owner: me, at: spot) }
        let newcomers = [hex(2, 4), hex(2, 6), hex(2, 8)].map { state.addUnit(.warrior, owner: me, at: $0) }
        let view = state.view(for: me)
        let plan = view.formation(of: newcomers, around: goal)
        #expect(plan.placed == 3 && plan.unreachable.isEmpty)
        #expect(plan.slots.values.allSatisfy { view.distance($0, goal) == 2 })
    }

    /// Civilians and other players' units are no part of a formation; a unit with no way there
    /// is unreachable.
    @Test func leavesOutCiviliansAndReportsTheUnreachable() throws {
        var map = openMap(width: 20, height: 12)
        // An island: a ring of ocean around (16, 6).
        for n in map.coords(within: 2, of: hex(16, 6)) where map.distance(n, hex(16, 6)) >= 1 {
            map[n] = Tile(terrain: .ocean)
        }
        var state = makeTestState(map: map)
        for t in 0..<state.map.tileCount { state.players[0].explored[t] = true }
        let builder = state.addUnit(.builder, owner: me, at: hex(3, 3))
        let theirs = state.addUnit(.warrior, owner: them, at: hex(3, 9))
        let warrior = state.addUnit(.warrior, owner: me, at: hex(3, 6))
        let view = state.view(for: me)
        let plan = view.formation(of: [builder, theirs, warrior], around: hex(16, 6))
        #expect(plan.slots[builder] == nil && plan.slots[theirs] == nil)
        #expect(plan.unreachable == [warrior])
        #expect(plan.arrivals == nil)
    }

    /// One production order for many cities: first, last or in place of the queue, with each
    /// city's reason when it cannot take the item.
    @Test func bulkQueues() throws {
        var state = makeTestState(map: openMap(width: 20, height: 12))
        let a = addCity(&state, me, at: hex(3, 3))
        let b = addCity(&state, me, at: hex(10, 3))
        let c = addCity(&state, me, at: hex(3, 9))
        try apply(.setQueue(city: a, items: [.unit(.warrior)]), &state)
        try apply(.setQueue(city: b, items: [.building("monument"), .unit(.scout)]), &state)
        try apply(.setQueue(city: c, items: Array(repeating: .unit(.warrior), count: state.rules.constants.production.maxQueue)), &state)
        let view = state.view(for: me)

        let first = view.bulkQueues(.unit(.scout), in: [a, b, c], placement: .first)
        #expect(first.map(\.city) == [a, b, c])
        #expect(first[0].items == [.unit(.scout), .unit(.warrior)])
        #expect(first[1].items == [.unit(.scout), .building("monument"), .unit(.scout)])
        #expect(first[2].items == nil && first[2].problem == "queue full")

        let last = view.bulkQueues(.building("monument"), in: [a, b], placement: .last)
        #expect(last[0].items == [.unit(.warrior), .building("monument")])
        #expect(last[1].problem == "already queued")
        // A queued building moves to the front.
        let monumentFirst = view.bulkQueues(.building("monument"), in: [b], placement: .first)
        #expect(monumentFirst[0].problem == "already first")

        let only = view.bulkQueues(.unit(.warrior), in: [a, c], placement: .only)
        #expect(only[0].problem == "already its only item")
        #expect(only[1].items == [.unit(.warrior)])

        // Applied, each change is a legal queue.
        for change in first + last + only {
            if let items = change.items { try apply(.setQueue(city: change.city, items: items), &state) }
        }
        expectSound(state)
    }
}
