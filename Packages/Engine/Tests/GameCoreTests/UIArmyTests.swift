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

    /// At an enemy city places go by role: the melee units close around it, the Archers stand
    /// at their range behind them, not in the line.
    @Test func siegePutsTheLineCloseAndArchersAtRange() throws {
        var state = makeWarState(width: 20, height: 12)
        let city = hex(12, 6)
        addCity(&state, them, at: city)
        let warriors = [hex(9, 5), hex(9, 6), hex(9, 7)].map { state.addUnit(.warrior, owner: me, at: $0) }
        // The Archers stand nearer the city than the Warriors: role, not distance, decides.
        let archers = [hex(10, 5), hex(10, 7)].map { state.addUnit(.archer, owner: me, at: $0) }
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let plan = view.formation(of: warriors + archers, around: city)
        #expect(plan.placed == 5 && plan.unreachable.isEmpty)
        #expect(!plan.slots.values.contains(city))
        for id in warriors { #expect(plan.slots[id].map { view.distance($0, city) } == 1) }
        for id in archers { #expect(plan.slots[id].map { view.distance($0, city) } == 2) }
        #expect(Set(plan.slots.values).count == 5)

        // An Archer already at its range keeps its tile.
        let set = try #require(plan.slots[archers[0]])
        var there = state
        there.updateUnit(archers[0]) { $0.position = set }
        refreshKnowledge(&there)
        let again = there.view(for: me).formation(of: archers, around: city)
        #expect(again.slots[archers[0]] == set && again.turns[archers[0]] == 0)
    }

    /// Away from the enemy, Archers in a group pack around the goal like everyone else.
    @Test func archersPackAroundAMusterPoint() throws {
        var state = makeTestState(map: openMap(width: 20, height: 12))
        let ids = [state.addUnit(.warrior, owner: me, at: hex(2, 6)), state.addUnit(.archer, owner: me, at: hex(2, 7))]
        let view = state.view(for: me)
        let plan = view.formation(of: ids, around: hex(10, 6))
        #expect(plan.placed == 2)
        #expect(plan.slots.values.allSatisfy { view.distance($0, hex(10, 6)) <= 1 })
    }

    /// A group keeps together: a unit more than a phase ahead of the slowest waits; the
    /// slowest and those near it march.
    @Test func marchStepsKeepTheGroupTogether() throws {
        var state = makeTestState(map: openMap(width: 24, height: 12))
        let goal = hex(18, 6)
        let slow = state.addUnit(.warrior, owner: me, at: hex(2, 6))
        let fast = state.addUnit(.horseman, owner: me, at: hex(2, 5))
        let ahead = state.addUnit(.warrior, owner: me, at: hex(12, 6))
        let view = state.view(for: me)
        let legs = [MarchLeg(unit: slow, target: goal, slot: goal),
                    MarchLeg(unit: fast, target: goal, slot: hex(17, 5)),
                    MarchLeg(unit: ahead, target: goal, slot: hex(17, 6))]
        let turns = legs.map { try? #require(view.path(for: $0.unit, to: $0.slot)).turns }
        let slowest = try #require(turns[0])
        #expect(try #require(turns[1]) < slowest - 1 && (try #require(turns[2])) < slowest - 1)
        let steps = view.marchSteps(legs)
        #expect(steps[slow] == .move)
        #expect(steps[fast] == .wait)
        #expect(steps[ahead] == .wait)
        // Alone, the fast unit marches.
        #expect(view.marchSteps([legs[1]])[fast] == .move)
    }

    /// Arrived, gone, out of reach; and contact: an enemy unit or city within 2 tiles stops a
    /// march, but not the goal itself (a city under siege, its garrison), and not an order
    /// given just now (`stopOnContact: false`).
    @Test func marchStepsStopOnContact() throws {
        var map = openMap(width: 20, height: 12)
        map[hex(18, 10)] = Tile(terrain: .ocean)
        var state = makeTestState(map: map)
        setWar(&state, me, them)
        let walker = state.addUnit(.warrior, owner: me, at: hex(5, 6))
        let enemy = state.addUnit(.warrior, owner: them, at: hex(7, 6))
        let home = state.addUnit(.warrior, owner: me, at: hex(3, 2))
        let builder = state.addUnit(.builder, owner: me, at: hex(2, 9))
        refreshKnowledge(&state)
        var view = state.view(for: me)
        #expect(view.marchContact(at: hex(5, 6), target: hex(15, 6)))
        #expect(!view.marchContact(at: hex(5, 6), target: hex(7, 6)))
        #expect(!view.marchContact(at: hex(3, 2), target: hex(15, 6)))
        let legs = [MarchLeg(unit: walker, target: hex(15, 6), slot: hex(15, 6)),
                    MarchLeg(unit: home, target: hex(3, 2), slot: hex(3, 2)),
                    MarchLeg(unit: builder, target: hex(15, 6), slot: hex(14, 6)),
                    MarchLeg(unit: UnitID(999), target: hex(15, 6), slot: hex(14, 7))]
        var steps = view.marchSteps(legs)
        #expect(steps[walker] == .contact)
        #expect(steps[home] == .arrived)
        #expect(steps[builder] == .gone && steps[UnitID(999)] == .gone)
        #expect(view.marchSteps(legs, stopOnContact: false)[walker] == .move)
        // Marching on the enemy unit itself: no contact, it goes on.
        #expect(view.marchSteps([MarchLeg(unit: walker, target: hex(7, 6), slot: hex(6, 6))])[walker] == .move)
        #expect(view.marchSteps([MarchLeg(unit: walker, target: hex(15, 6), slot: hex(18, 10))], stopOnContact: false)[walker] == .noRoute)

        // An enemy city that is not the goal counts too; the city marched on does not.
        state.removeUnit(enemy)
        addCity(&state, them, at: hex(8, 6))
        state.addUnit(.warrior, owner: me, at: hex(6, 6)) // in sight of the city
        refreshKnowledge(&state)
        view = state.view(for: me)
        #expect(view.marchContact(at: hex(6, 6), target: hex(15, 6)))
        #expect(!view.marchContact(at: hex(6, 6), target: hex(8, 6)))
        steps = view.marchSteps([MarchLeg(unit: walker, target: hex(15, 6), slot: hex(15, 6))])
        #expect(steps[walker] == .move) // (5, 6) is 3 from the city
    }

    /// A siege's outlook: the Archers in range shoot (out of range: not), the Warrior beside the
    /// city may storm it, enemies near are counted; at 0 HP the storm is a capture and no one
    /// shoots; no war, no siege.
    @Test func siegeOutlookShootsAndStorms() throws {
        var state = makeWarState(width: 20, height: 12)
        let city = hex(12, 6)
        let cityID = addCity(&state, them, at: city)
        let archer = state.addUnit(.archer, owner: me, at: hex(10, 6))
        let far = state.addUnit(.archer, owner: me, at: hex(7, 6))
        let warrior = state.addUnit(.warrior, owner: me, at: hex(11, 6))
        let builder = state.addUnit(.builder, owner: me, at: hex(10, 7))
        state.addUnit(.warrior, owner: them, at: hex(13, 6)) // beside the city, in sight
        refreshKnowledge(&state)
        var view = state.view(for: me)
        let outlook = try #require(view.siegeOutlook(of: [archer, far, warrior, builder], at: city))
        #expect(outlook.city.id == cityID)
        #expect(outlook.shots == [archer])
        #expect(outlook.assault?.unit == warrior && outlook.assault?.preview.capturesCity == false)
        #expect(outlook.enemiesNear == 1)
        #expect(outlook.maxHP == state.rules.constants.city.maxHP && outlook.maxWallHP == 0)
        // The shot is accepted as planned.
        try apply(.attack(unit: archer, target: city), &state)
        refreshKnowledge(&state)
        view = state.view(for: me)
        #expect(try #require(view.knownCity(at: city)).hp < outlook.city.hp)

        // Its defences down: the Warrior takes it, and shooting is pointless.
        updateCity(&state, cityID) { $0.hp = 0 }
        refreshKnowledge(&state)
        view = state.view(for: me)
        let fallen = try #require(view.siegeOutlook(of: [archer, warrior], at: city))
        #expect(fallen.shots.isEmpty)
        #expect(fallen.assault?.unit == warrior && fallen.assault?.preview.capturesCity == true)

        // At peace (or no city there): no siege.
        #expect(view.siegeOutlook(of: [warrior], at: hex(5, 5)) == nil)
        state.updateRelation(me, them) { $0.stance = .peace }
        #expect(state.view(for: me).siegeOutlook(of: [warrior], at: city) == nil)
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
