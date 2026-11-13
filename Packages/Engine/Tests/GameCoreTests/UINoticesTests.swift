import Foundation
import Testing
@testable import GameCore

// The notices' helpers (GameCore/Queries/UINotices.swift, M1 §16 "Notifications"): a unit's
// population cost is not hunger, blows on an own unit are summed per unit, a lost unit is paired
// with the blow that destroyed it, and military units sent out of land closed to them are found.

@Suite struct UINoticesTests {
    private let me = PlayerID(0), them = PlayerID(1)

    /// Ends phases until player 0's next phase, returning the records player 0 may see.
    private func recordsUntilMyPhase(_ state: inout GameState) throws -> [EventRecord] {
        var records: [EventRecord] = []
        var phases = 0
        repeat {
            records += try apply(.endTurn, &state)
            phases += 1
        } while state.currentPlayer != me && phases < 8
        return records.filter { $0.isVisible(to: me) }
    }

    /// A Settler finished through production at the owner's phase start pays its population
    /// with a `cityShrank` just before its completion: the two are paired, so the shrink is not
    /// hunger (M1 §5).
    @Test func aSettlerFromProductionPaysItsPopulation() throws {
        var state = makeTestState()
        let city = addCity(&state, me, at: hex(3, 3))
        let cost = state.rules.cost(of: .unit(.settler))
        updateCity(&state, city) { c in
            c.population = 2
            c.queue = [QueueEntry(.unit(.settler))]
            c.queue[0].progress = cost - 1
        }
        let records = try recordsUntilMyPhase(&state)
        let costs = state.view(for: me).populationCosts(in: records)
        #expect(costs.count == 1)
        let paid = try #require(costs.first)
        #expect(paid.city == city && paid.population == 1)
        guard case .cityShrank(city, 1, _) = records[paid.shrink].event else {
            Issue.record("the paired record is not the city's shrink: \(records[paid.shrink].event)")
            return
        }
        guard case .productionCompleted(city, .unit(.settler), _) = records[paid.completion].event else {
            Issue.record("the paired completion is not the Settler: \(records[paid.completion].event)")
            return
        }
        #expect(paid.shrink < paid.completion)
    }

    /// A Settler bought pays its population the same way.
    @Test func aSettlerBoughtPaysItsPopulation() throws {
        var state = makeTestState()
        let city = addCity(&state, me, at: hex(3, 3))
        updateCity(&state, city) { $0.population = 2 }
        let records = try apply(.purchase(city: city, item: .unit(.settler)), &state).filter { $0.isVisible(to: me) }
        let costs = state.view(for: me).populationCosts(in: records)
        #expect(costs.map(\.population) == [1])
        #expect(costs.first.map { records[$0.shrink].event } == .cityShrank(city: city, population: 1, at: hex(3, 3)))
    }

    /// A city that starves and finishes a Settler in the same records keeps its hunger: only the
    /// shrink right before the completion is paid for.
    @Test func starvingAndASettlerInOneBatch() {
        let state = makeTestState()
        let city = CityID(7), at = hex(3, 3)
        let everyone = EventRecord.everyone
        let records = [
            EventRecord(.cityShrank(city: city, population: 2, at: at), audience: everyone), // hunger (growth step)
            EventRecord(.cityShrank(city: city, population: 1, at: at), audience: everyone), // the Settler's cost
            EventRecord(.productionCompleted(city: city, item: .unit(.settler), at: at), audience: everyone),
            EventRecord(.unitCreated(unit: UnitID(99), type: .settler, owner: me, at: at), audience: everyone),
        ]
        let costs = state.view(for: me).populationCosts(in: records)
        #expect(costs == [PopulationCost(city: city, shrink: 1, completion: 2, population: 1)])

        // A Warrior costs no population: a shrink before it is hunger.
        let warrior = [
            EventRecord(.cityShrank(city: city, population: 1, at: at), audience: everyone),
            EventRecord(.productionCompleted(city: city, item: .unit(.warrior), at: at), audience: everyone),
        ]
        #expect(state.view(for: me).populationCosts(in: warrior).isEmpty)

        // A shrink before the city's previous completion is not paid by a later one.
        let earlier = [
            EventRecord(.cityShrank(city: city, population: 1, at: at), audience: everyone),
            EventRecord(.productionCompleted(city: city, item: .building("monument"), at: at), audience: everyone),
            EventRecord(.productionCompleted(city: city, item: .unit(.settler), at: at), audience: everyone),
        ]
        #expect(state.view(for: me).populationCosts(in: earlier).isEmpty)
    }

    /// Two blows on one own unit in another player's phase: one entry, both attackers, the HP
    /// lost in all and the HP left.
    @Test func twoBlowsOnOneUnitAreSummed() throws {
        var state = makeWarState()
        let mine = state.addUnit(.spearman, owner: me, at: hex(4, 3))
        let archer = state.addUnit(.archer, owner: them, at: hex(6, 3))
        let warrior = state.addUnit(.warrior, owner: them, at: hex(5, 3))
        refreshKnowledge(&state)
        try endPhases(until: them, &state)
        var records = try apply(.attack(unit: archer, target: hex(4, 3)), &state)
        records += try apply(.attack(unit: warrior, target: hex(4, 3)), &state)
        let visible = records.filter { $0.isVisible(to: me) }
        let unit = try #require(state.unit(mine), "the Spearman lives through both blows")
        let dealt = visible.compactMap { record -> Int? in
            if case let .combat(_, .unit(id), _, _, _, dealt, _) = record.event, id == mine { return dealt }
            return nil
        }
        #expect(dealt.count == 2)
        let damage = state.view(for: me).unitDamage(in: visible)
        #expect(damage.count == 1)
        let hurt = try #require(damage.first)
        #expect(hurt.unit == mine && hurt.type == .spearman)
        #expect(hurt.attackers == [.unit(archer), .unit(warrior)])
        #expect(hurt.ranged == [true, false])
        #expect(hurt.damage == dealt.reduce(0, +))
        #expect(hurt.hp == unit.hp && hurt.hp == state.rules.constants.healing.maxHP - hurt.damage)
        #expect(hurt.tile == unit.position)
    }

    /// A blow that kills is left out: the unit's `unitKilled` reports it.
    @Test func aBlowThatKillsIsLeftOut() throws {
        var state = makeWarState()
        let mine = state.addUnit(.warrior, owner: me, at: hex(4, 3))
        let warrior = state.addUnit(.warrior, owner: them, at: hex(5, 3))
        let index = try #require(state.units.firstIndex { $0.id == mine })
        state.units[index].hp = 1
        refreshKnowledge(&state)
        try endPhases(until: them, &state)
        let records = try apply(.attack(unit: warrior, target: hex(4, 3)), &state).filter { $0.isVisible(to: me) }
        #expect(state.unit(mine) == nil)
        #expect(records.contains { if case .unitKilled(mine, _, _, _) = $0.event { true } else { false } })
        #expect(state.view(for: me).unitDamage(in: records).isEmpty)
    }

    /// A unit killed in another player's phase is paired with the blow that destroyed it: the
    /// attacker and the kind of blow, where it fell, and its `unitKilled` record.
    @Test func aLossIsPairedWithTheBlowThatDealtIt() throws {
        var state = makeWarState()
        let mine = state.addUnit(.warrior, owner: me, at: hex(4, 3))
        state.updateUnit(mine) { $0.hp = 1 }
        let warrior = state.addUnit(.warrior, owner: them, at: hex(5, 3))
        refreshKnowledge(&state)
        try endPhases(until: them, &state)
        let records = try apply(.attack(unit: warrior, target: hex(4, 3)), &state).filter { $0.isVisible(to: me) }
        try #require(state.unit(mine) == nil)
        let losses = state.view(for: me).unitLosses(in: records)
        #expect(losses.count == 1)
        let loss = try #require(losses.first)
        #expect(loss.unit == mine && loss.type == .warrior && loss.tile == hex(4, 3))
        #expect(loss.killer == .unit(warrior) && !loss.ranged)
        #expect(loss.earlierAttackers.isEmpty && loss.earlierDamage == 0)
        #expect(records[loss.record].event == .unitKilled(unit: mine, type: .warrior, owner: me, at: hex(4, 3)))
        // The other player's view has no losses of its own here.
        #expect(state.view(for: them).unitLosses(in: records).isEmpty)
    }

    /// A city's bombard that destroys a unit is its killer, a ranged blow.
    @Test func aBombardKillNamesTheCity() throws {
        var state = makeWarState()
        let city = addCity(&state, them, at: hex(6, 3))
        let mine = state.addUnit(.archer, owner: me, at: hex(4, 3))
        state.updateUnit(mine) { $0.hp = 1 }
        refreshKnowledge(&state)
        try endPhases(until: them, &state)
        let records = try apply(.cityAttack(city: city, target: hex(4, 3)), &state).filter { $0.isVisible(to: me) }
        try #require(state.unit(mine) == nil)
        let loss = try #require(state.view(for: me).unitLosses(in: records).first)
        #expect(loss.killer == .city(city) && loss.ranged && loss.type == .archer)
    }

    /// Blows a unit took before the one that destroyed it, in the same records, are kept apart
    /// from the killing blow; records of the last blow alone have none (playback shows each
    /// attack as its own batch).
    @Test func aLossKeepsTheEarlierBlowsOfItsBatch() throws {
        var state = makeWarState()
        let mine = state.addUnit(.warrior, owner: me, at: hex(4, 3))
        state.updateUnit(mine) { $0.hp = 60 }
        let archer = state.addUnit(.archer, owner: them, at: hex(6, 3))
        let warrior = state.addUnit(.warrior, owner: them, at: hex(5, 3))
        refreshKnowledge(&state)
        try endPhases(until: them, &state)
        let shot = try apply(.attack(unit: archer, target: hex(4, 3)), &state).filter { $0.isVisible(to: me) }
        try #require(state.unit(mine) != nil, "the set-up: the shot leaves it alive")
        let blow = try apply(.attack(unit: warrior, target: hex(4, 3)), &state).filter { $0.isVisible(to: me) }
        try #require(state.unit(mine) == nil, "the set-up: the second blow destroys it")
        let dealt = try #require(combatEvent(shot)?.dealt)

        let both = try #require(state.view(for: me).unitLosses(in: shot + blow).first)
        #expect(both.killer == .unit(warrior) && !both.ranged)
        #expect(both.earlierAttackers == [.unit(archer)] && both.earlierRanged == [true] && both.earlierDamage == dealt)

        let alone = try #require(state.view(for: me).unitLosses(in: blow).first)
        #expect(alone.killer == .unit(warrior) && alone.earlierAttackers.isEmpty)
    }

    /// A garrison destroyed when its city is taken was destroyed by no blow: no killer.
    @Test func aGarrisonLostWithItsCityHasNoKiller() throws {
        var state = makeWarState()
        addCity(&state, me, at: hex(1, 1)) // the capital, kept
        let town = addCity(&state, me, at: hex(6, 3))
        updateCity(&state, town) { $0.hp = 0 }
        let garrison = state.addUnit(.warrior, owner: me, at: hex(6, 3))
        let captor = state.addUnit(.warrior, owner: them, at: hex(7, 3))
        refreshKnowledge(&state)
        try endPhases(until: them, &state)
        let records = try apply(.attack(unit: captor, target: hex(6, 3)), &state).filter { $0.isVisible(to: me) }
        try #require(state.city(town)?.owner == them && state.unit(garrison) == nil)
        let loss = try #require(state.view(for: me).unitLosses(in: records).first { $0.unit == garrison })
        #expect(loss.killer == nil && loss.tile == hex(6, 3) && loss.earlierAttackers.isEmpty)
    }

    /// The city a notice names a place by: the one on the tile, else the nearest known city
    /// within the radius (ties: the lower id), else none.
    @Test func theNearestKnownCityNamesAPlace() throws {
        var state = makeTestState(map: openMap())
        let rome = addCity(&state, me, at: hex(2, 3))
        let antium = addCity(&state, me, at: hex(8, 3))
        let view = state.view(for: me)
        #expect(view.nearestKnownCity(to: hex(2, 3), within: 4)?.id == rome)
        #expect(view.nearestKnownCity(to: hex(7, 3), within: 4)?.id == antium)
        #expect(view.nearestKnownCity(to: hex(5, 3), within: 4)?.id == rome, "a tie goes to the lower id")
        #expect(view.nearestKnownCity(to: hex(5, 3), within: 2) == nil)
    }

    /// At peace, a military unit on the other player's land is sent out at its owner's phase
    /// start (M1 §9): the move is found as an eviction; an ordinary move is not.
    @Test func evictionsFromClosedLand() throws {
        var state = makeTestState(map: openMap())
        addCity(&state, them, at: hex(7, 3))
        state.updateRelation(me, them) { $0.met = true }
        let warrior = state.addUnit(.warrior, owner: me, at: hex(6, 3))
        refreshKnowledge(&state)
        #expect(state.view(for: me).knownOwner(at: hex(6, 3)) == them)
        let records = try recordsUntilMyPhase(&state)
        let evictions = state.view(for: me).evictions(in: records)
        #expect(evictions.count == 1)
        let eviction = try #require(evictions.first)
        #expect(eviction.unit == warrior && eviction.type == .warrior && eviction.owner == them)
        #expect(eviction.to == state.unit(warrior)?.position)
        #expect(state.view(for: me).knownOwner(at: eviction.to) != them)

        // A move that starts on land open to it is no eviction.
        let position = try #require(state.unit(warrior)?.position)
        let open = [EventRecord(.unitMoved(unit: warrior, from: position, path: [position, hex(2, 3)]), audience: EventRecord.everyone)]
        #expect(state.view(for: me).evictions(in: open).isEmpty)
    }
}
