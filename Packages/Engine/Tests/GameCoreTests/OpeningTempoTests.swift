import Foundation
import Testing
@testable import GameCore

// p3f core-opening-tempo and core-young-city-production (M1 §4, §5): a Settler at the head of the
// queue takes production while it waits for population (`production.waitingHeadFillPct`, on), a
// young city's extra Production (`city.youngCityProduction`, off) and a captured city's stored
// progress (`city.capturedProduction`, off).

/// The standard rules with constants changed: (section, key, value), e.g.
/// ("production", "waitingHeadFillPct", 0).
private func rules(changing changes: [(String, String, Int)]) throws -> Ruleset {
    var json = try standardRulesJSON()
    var constants = json["constants"] as! [String: Any]
    for (section, key, value) in changes {
        var table = constants[section] as! [String: Any]
        #expect(table[key] != nil, "constants.\(section).\(key)")
        table[key] = value
        constants[section] = table
    }
    json["constants"] = constants
    return try loadRules(json)
}

/// A city of player 0 at (2, 2) with nothing stored (its founding production cleared): on the
/// test map it makes 4 Production (centre 2 + Palace 2) and +2 Food at population 1.
private func emptyCity(_ state: inout GameState) -> CityID {
    let id = addCity(&state, PlayerID(0), at: hex(2, 2))
    updateCity(&state, id) { $0.storedProgress = 0 }
    return id
}

@Suite struct OpeningTempoTests {
    /// A Settler first in the queue of a city of population 1 takes the production up to its
    /// cost; the rest stays stored progress. Full, it waits while the next item gets the
    /// production, and it completes in the phase the city grows (the food step comes first).
    @Test func aSettlerAtTheHeadFillsWhileItWaits() throws {
        var state = makeTestState()
        #expect(state.rules.constants.production.waitingHeadFillPct == 100)
        let id = emptyCity(&state)
        try apply(.setQueue(city: id, items: [.unit(.settler), .unit(.warrior)]), &state)
        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.settler), progress: 4), QueueEntry(.unit(.warrior))])

        // 58 + 4: it takes 2 and the other 2 stay stored.
        updateCity(&state, id) { $0.queue[0].progress = 58 }
        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.settler), progress: 60), QueueEntry(.unit(.warrior))])
        #expect(state.city(id)!.storedProgress == 2)

        // Full, it waits: the Warrior takes the phase's 4 and the stored 2.
        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.settler), progress: 60), QueueEntry(.unit(.warrior), progress: 6)])
        #expect(state.city(id)!.storedProgress == 0 && state.city(id)!.population == 1)

        // 9 + 2 reaches the threshold of 11 at the next phase start: it grows, then the Settler
        // completes in the same phase (60 + 4; the overflow 4 is stored) and costs the citizen.
        updateCity(&state, id) { $0.foodStore = 9 }
        try endPhases(until: PlayerID(1), &state)
        let records = try apply(.endTurn, &state)
        #expect(events(records).contains(.cityGrew(city: id, population: 2, at: hex(2, 2))))
        #expect(events(records).contains(.productionCompleted(city: id, item: .unit(.settler), at: hex(2, 2))))
        #expect(events(records).contains(.cityShrank(city: id, population: 1, at: hex(2, 2))))
        #expect(state.units(at: hex(2, 2)).contains { $0.type == .settler && $0.owner == PlayerID(0) })
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.warrior), progress: 6)])
        #expect(state.city(id)!.storedProgress == 4 && state.city(id)!.population == 1)
        expectSound(state)
    }

    /// It takes the stored progress too, and what it does not take stays stored, uncapped (the
    /// founding production or a removed entry's progress is never lost).
    @Test func whatTheSettlerDoesNotTakeStaysStored() throws {
        var state = makeTestState()
        let id = emptyCity(&state)
        try apply(.setQueue(city: id, items: [.unit(.settler)]), &state)
        updateCity(&state, id) { city in
            city.queue[0].progress = 30
            city.storedProgress = 40
        }
        try nextTurn(&state)
        // 30 + 4 + 40 = 74: 60 in the Settler, 14 stored.
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.settler), progress: 60)])
        #expect(state.city(id)!.storedProgress == 14)
        // Nothing else queued: the empty-queue rule (cap 2 × 4) keeps the 14.
        try nextTurn(&state)
        #expect(state.city(id)!.storedProgress == 14)
    }

    /// Only the head of the queue fills, and only a unit waiting for population: an item before
    /// it takes the production as before, and a Settler in a city that has the population
    /// simply completes. A smaller percentage fills to that share of the cost.
    @Test func onlyAHeadWaitingForPopulationFills() throws {
        var state = makeTestState()
        let id = emptyCity(&state)
        try apply(.setQueue(city: id, items: [.unit(.warrior), .unit(.settler)]), &state)
        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.warrior), progress: 4), QueueEntry(.unit(.settler))])

        updateCity(&state, id) { city in
            city.population = 2
            city.queue = [QueueEntry(.unit(.settler), progress: 57)]
        }
        try nextTurn(&state)
        #expect(state.city(id)!.queue.isEmpty && state.city(id)!.population == 1)
        #expect(state.units(at: hex(2, 2)).contains { $0.type == .settler })

        var half = makeTestState(rules: try rules(changing: [("production", "waitingHeadFillPct", 50)]))
        let other = emptyCity(&half)
        try apply(.setQueue(city: other, items: [.unit(.settler), .unit(.warrior)]), &half)
        updateCity(&half, other) { $0.queue[0].progress = 28 }
        try nextTurn(&half)
        // Half of 60: it takes 2 of the 4 and the other 2 stay stored.
        #expect(half.city(other)!.queue == [QueueEntry(.unit(.settler), progress: 30), QueueEntry(.unit(.warrior))])
        #expect(half.city(other)!.storedProgress == 2)
        try nextTurn(&half)
        #expect(half.city(other)!.queue == [QueueEntry(.unit(.settler), progress: 30), QueueEntry(.unit(.warrior), progress: 6)])
    }

    /// Switched off (0), a waiting Settler takes nothing and the next item gets the production:
    /// the rule before p3f.
    @Test func switchedOffAWaitingSettlerTakesNothing() throws {
        var state = makeTestState(rules: try rules(changing: [("production", "waitingHeadFillPct", 0)]))
        let id = emptyCity(&state)
        try apply(.setQueue(city: id, items: [.unit(.settler), .unit(.warrior)]), &state)
        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.settler)), QueueEntry(.unit(.warrior), progress: 4)])
        // Alone, it leaves the production to stored progress, capped at 2 × 4.
        try apply(.setQueue(city: id, items: [.unit(.settler)]), &state)
        try nextTurn(&state)
        try nextTurn(&state)
        #expect(state.city(id)!.queue == [QueueEntry(.unit(.settler))] && state.city(id)!.storedProgress == 8)
    }

    /// While a Settler fills, the stored progress is its, so the phases `productionOptions`
    /// gives for a new entry start from nothing; switched off, the stored progress still counts.
    @Test func aNewEntryDoesNotCountOnWhatAFillingSettlerTakes() throws {
        for (pct, start) in [(100, 0), (0, 8)] {
            var state = makeTestState(rules: try rules(changing: [("production", "waitingHeadFillPct", pct)]))
            let id = emptyCity(&state)
            try apply(.setQueue(city: id, items: [.unit(.settler)]), &state)
            updateCity(&state, id) { $0.storedProgress = 8 }
            let cost = state.rules.unit(.warrior).cost
            let option = try #require(state.view(for: PlayerID(0)).productionOptions(for: id).first { $0.item == .unit(.warrior) })
            #expect(option.turns == (cost - start + 3) / 4, "fill \(pct)%")
        }
    }

    /// Validation: the fill percentage is 0–100; the experiments' values are never negative.
    @Test func theNewValuesAreValidated() throws {
        func problems(_ section: String, _ key: String, _ value: Int) throws -> [String] {
            try validationProblems { json in
                var constants = json["constants"] as! [String: Any]
                var table = constants[section] as! [String: Any]
                table[key] = value
                constants[section] = table
                json["constants"] = constants
            }
        }
        #expect(try problems("production", "waitingHeadFillPct", 101).contains { $0.contains("waitingHeadFillPct out of range") })
        #expect(try problems("production", "waitingHeadFillPct", -1).contains { $0.contains("waitingHeadFillPct out of range") })
        #expect(try problems("production", "waitingHeadFillPct", 0).isEmpty)
        for key in ["youngCityProduction", "youngCityPopulation", "capturedProduction"] {
            #expect(try problems("city", key, -1).contains { $0.contains("young or captured city production negative") }, "\(key)")
        }
    }
}

@Suite struct YoungAndCapturedCityTests {
    /// p3f experiment G2 (off by default): a city below `youngCityPopulation` gets
    /// `youngCityProduction` more Production at its centre.
    @Test func aYoungCityGetsExtraProductionAtItsCentre() throws {
        var plain = makeTestState()
        let a = emptyCity(&plain)
        #expect(plain.cityYields(plain.city(a)!).total.production == 4)

        var state = makeTestState(rules: try rules(changing: [("city", "youngCityProduction", 1), ("city", "youngCityPopulation", 3)]))
        let id = emptyCity(&state)
        let young = state.cityYields(state.city(id)!)
        #expect(young.total.production == 5)
        #expect(young.breakdown.first { $0.source == .centre }?.yields.production == 3)
        updateCity(&state, id) { $0.population = 3 }
        state.assignCitizens(state.cityIndex(id)!)
        #expect(state.cityYields(state.city(id)!).breakdown.first { $0.source == .centre }?.yields.production == 2)
    }

    /// p3f experiment (off by default): a captured city keeps `capturedProduction` stored
    /// progress instead of none.
    @Test func aCapturedCityHoldsItsCapturedProduction() throws {
        for (stored, expected) in [(0, 0), (20, 20)] {
            var state = makeWarState(width: 24, height: 12, rules: try rules(changing: [("city", "capturedProduction", stored)]))
            addCity(&state, PlayerID(0), at: hex(3, 3))
            addCity(&state, PlayerID(1), at: hex(18, 6))
            let city = addCity(&state, PlayerID(1), at: hex(10, 6))
            updateCity(&state, city) { c in
                c.hp = 0
                c.queue = [QueueEntry(.unit(.warrior), progress: 12)]
                c.storedProgress = 7
            }
            let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 6))
            refreshKnowledge(&state)
            try apply(.attack(unit: a, target: hex(10, 6)), &state)
            let taken = try #require(state.city(city))
            #expect(taken.owner == PlayerID(0) && taken.queue.isEmpty && taken.storedProgress == expected)
            expectSound(state)
        }
    }
}
