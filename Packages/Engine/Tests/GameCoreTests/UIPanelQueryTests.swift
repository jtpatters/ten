import Foundation
import Testing
@testable import GameCore

// The city panel's and attention queue's read-only queries (GameCore/Queries/UICityPanel.swift,
// M1 §16): each must say what the engine will do, from what the player knows.

@Suite struct UIPanelQueryTests {
    private let me = PlayerID(0), them = PlayerID(1)

    /// Turns to grow and to shrink match the engine's growth step (M1 §5).
    @Test func growthMatchesTheEngine() throws {
        var state = makeTestState(map: openMap())
        let city = addCity(&state, me, at: hex(3, 3))
        updateCity(&state, city) { $0.foodStore = 3 }
        let growth = try #require(state.view(for: me).growth(of: city))
        #expect(growth.threshold == state.rules.growthThreshold(population: 1))
        #expect(growth.surplus == state.cityYields(state.city(city)!).foodSurplus)
        #expect(growth.turnsToGrow == state.view(for: me).turnsToGrow(city))
        #expect(growth.turnsToShrink == nil)
        let turns = try #require(growth.turnsToGrow)
        for _ in 0..<turns { try nextTurn(&state) }
        #expect(state.city(city)?.population == 2, "the city grows in the phase the query says")

        // Starving: a population-3 city whose tiles are taken away eats more than it makes.
        updateCity(&state, city) { c in
            c.population = 3
            c.foodStore = 5
            c.cultureStore = 0 // no border growth during the test
        }
        for t in state.tileCity.indices where state.tileCity[t] == Int32(city.rawValue + 1) && state.map.coord(at: t) != hex(3, 3) {
            state.tileCity[t] = 0
        }
        refreshKnowledge(&state)
        state.assignCitizens(state.cityIndex(city)!)
        let starving = try #require(state.view(for: me).growth(of: city))
        #expect(starving.surplus < 0)
        let shrink = try #require(starving.turnsToShrink)
        for i in 1...shrink {
            try nextTurn(&state)
            #expect((state.city(city)!.population == 3) == (i < shrink), "shrinks in phase \(shrink), not \(i)")
        }
    }

    /// A Settler waits in a city of population 1 and, first in the queue, fills meanwhile (M1
    /// §5: it takes the production and the store, and the entries after it follow it); a unit
    /// waits with no tile to appear on; once the Settler is paid for, the first entry that does
    /// not wait takes the production with the stored progress.
    @Test func queueStatusSaysWhatWaits() throws {
        var state = makeTestState(map: openMap())
        let city = addCity(&state, me, at: hex(3, 3))
        updateCity(&state, city) { $0.storedProgress = 7 }
        try apply(.setQueue(city: city, items: [.unit(.settler), .unit(.warrior), .building("monument")]), &state)
        let filling = state.view(for: me).queueStatus(of: city)
        #expect(filling.map(\.wait) == [.population(2), nil, nil])
        #expect(filling.map(\.receivesProduction) == [true, false, false])
        #expect(filling.map(\.storedIncluded) == [7, 0, 0])
        let settlerDone = try #require(filling[0].turns)
        let warriorDone = try #require(filling[1].turns), monumentDone = try #require(filling[2].turns)
        #expect(settlerDone < warriorDone && warriorDone < monumentDone)

        // Paid for, the Settler takes nothing more while it waits: the Warrior takes the
        // production with the stored progress.
        let settlerCost = state.rules.cost(of: .unit(.settler))
        updateCity(&state, city) { $0.queue[0].progress = settlerCost }
        let view = state.view(for: me)
        let status = view.queueStatus(of: city)
        #expect(status.map(\.wait) == [.population(2), nil, nil])
        #expect(status.map(\.receivesProduction) == [false, true, false])
        #expect(status[1].progress == 7, "stored progress goes to the entry that takes production")
        #expect(status.map(\.storedIncluded) == [0, 7, 0])
        #expect(status[0].turns == nil)
        let production = state.cityYields(state.city(city)!).total.production
        let warrior = (state.rules.cost(of: .unit(.warrior)) - 7 + production - 1) / production
        #expect(status[1].turns == warrior)
        // The Warrior's overflow, capped at the phase's production, goes into the Monument.
        let overflow = min(7 + warrior * production - state.rules.cost(of: .unit(.warrior)), production)
        let monument = max(1, (state.rules.cost(of: .building("monument")) - overflow + production - 1) / production)
        #expect(status[2].turns == warrior + monument)
        #expect(view.productionWait(.unit(.settler), in: city) == .population(2))
        #expect(view.productionWait(.building("monument"), in: city) == nil)

        // A warrior alone (the city cannot grow into the Settler meanwhile) completes in the
        // phase the query says.
        var solo = makeTestState(map: openMap())
        let forge = addCity(&solo, me, at: hex(3, 3))
        updateCity(&solo, forge) { $0.storedProgress = 7 }
        try apply(.setQueue(city: forge, items: [.unit(.warrior)]), &solo)
        let turns = try #require(solo.view(for: me).queueStatus(of: forge).first?.turns)
        for i in 1...turns {
            try nextTurn(&solo)
            #expect(solo.units(of: me).contains { $0.type == .warrior } == (i == turns), "completes in phase \(turns), not \(i)")
        }

        // No room: every own tile within the spawn radius holds a military unit.
        var full = makeTestState(map: openMap())
        let crowded = addCity(&full, me, at: hex(3, 3))
        for hex in full.map.coords(within: full.rules.constants.production.spawnRadius, of: hex(3, 3))
            where full.tileOwner(full.map.index(of: hex)!) == me {
            full.addUnit(.warrior, owner: me, at: hex)
        }
        #expect(full.view(for: me).productionWait(.unit(.spearman), in: crowded) == .noRoom)
        #expect(full.view(for: me).productionWait(.unit(.builder), in: crowded) == nil, "civilians use their own slot")
    }

    /// The upkeep forecast disbands as many units as the engine does at the next phase start.
    @Test func upkeepForecastMatchesTheEngine() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        addCity(&state, me, at: hex(3, 3))
        let free = state.freeUnitAllowance(of: me)
        // Upkeep beyond what the city's gold pays.
        for col in 0..<(free + 6) { state.addUnit(.warrior, owner: me, at: hex(col, 6)) }
        let forecast = state.view(for: me).upkeepForecast()
        #expect(forecast.disbanded > 0)
        let before = state.militaryUnitCount(of: me)
        try nextTurn(&state)
        #expect(before - state.militaryUnitCount(of: me) == forecast.disbanded)
        #expect(state.players[0].gold == forecast.goldAfter)

        var rich = makeTestState(map: openMap(), gold: 1000)
        addCity(&rich, me, at: hex(3, 3))
        #expect(rich.view(for: me).upkeepForecast().disbanded == 0)
    }

    /// A Settler after another Settler finds the city one smaller (M1 §5): with two queued at
    /// population 2 in a city that does not grow (plains: no food to spare), the second waits for
    /// population 2 (foreseen, and not merely possible), as the engine then does; the first
    /// still takes the production.
    @Test func aSecondSettlerWaitsForTheFirstsPopulation() throws {
        var state = makeTestState(map: HexMap(width: 12, height: 8, wrapsX: false, fill: Tile(terrain: .plains)))
        let city = addCity(&state, me, at: hex(3, 3))
        updateCity(&state, city) { $0.population = 2 }
        state.assignCitizens(state.cityIndex(city)!)
        try #require(state.view(for: me).growth(of: city)?.surplus == 0)
        try apply(.setQueue(city: city, items: [.unit(.settler), .unit(.builder), .unit(.settler)]), &state)
        let status = state.view(for: me).queueStatus(of: city)
        #expect(status.map(\.receivesProduction) == [true, false, false])
        #expect(status[0].wait == nil && status[0].turns != nil && !status[0].waitIsForeseen)
        #expect(status[1].wait == nil && status[1].turns != nil, "a Builder costs no population")
        #expect(status[2].wait == .population(2) && status[2].turns == nil && status[2].waitIsForeseen)
        #expect(!status[2].waitIsUncertain, "the city does not grow back")
        // The engine: once the first Settler is out (the city not growing meanwhile), the city
        // is at population 1 and the second Settler cannot complete until it grows.
        let cost = state.rules.cost(of: .unit(.settler))
        updateCity(&state, city) { c in
            c.queue[0].progress = cost - 1
            c.foodStore = 0
        }
        try nextTurn(&state)
        #expect(state.city(city)?.population == 1)
        #expect(state.city(city)?.queue.map(\.item) == [.unit(.builder), .unit(.settler)])
        #expect(state.view(for: me).productionWait(.unit(.settler), in: city) == .population(2))

        // A waiting Settler first fills meanwhile (M1 §5, p3f): it takes the production and the
        // store, nothing is foreseen; the entry after it waits its turn.
        var small = makeTestState(map: openMap())
        let village = addCity(&small, me, at: hex(3, 3))
        try apply(.setQueue(city: village, items: [.unit(.settler), .unit(.warrior)]), &small)
        let waiting = small.view(for: me).queueStatus(of: village)
        #expect(waiting.map(\.receivesProduction) == [true, false])
        #expect(waiting[0].wait == .population(2) && !waiting[0].waitIsForeseen)
        #expect(waiting[0].storedIncluded == small.city(village)!.storedProgress)
    }

    /// The filling Settler's forecast (M1 §5, p3f): it takes the next production, and its turns
    /// are the phase the engine completes it (the city grows first, then it is paid for). No
    /// military unit is forecast to complete meanwhile, and nothing stored is lost.
    @Test func aFillingSettlerIsForecastAsTheEngineBuildsIt() throws {
        var state = makeTestState(map: openMap())
        let city = addCity(&state, me, at: hex(3, 3))
        updateCity(&state, city) { $0.storedProgress = 0 }
        state.assignCitizens(state.cityIndex(city)!)
        try apply(.setQueue(city: city, items: [.unit(.settler), .unit(.warrior)]), &state)
        let view = state.view(for: me)
        let status = view.queueStatus(of: city)
        try #require(status.count == 2)
        #expect(status[0].receivesProduction && status[0].wait == .population(2))
        let turns = try #require(status[0].turns)
        #expect(view.upkeepForecast().completing == 0)
        #expect(view.storedProduction(of: city)?.lostNextPhase == 0)
        let settlers = state.units(of: me).filter { $0.type == .settler }.count
        for phase in 1...turns {
            #expect(state.units(of: me).filter { $0.type == .settler }.count == settlers, "not before phase \(turns) (phase \(phase))")
            try nextTurn(&state)
        }
        #expect(state.units(of: me).filter { $0.type == .settler }.count == settlers + 1, "the Settler at phase \(turns)")
    }

    /// The forecast lets the city grow meanwhile (M1 §5, at its current surplus): a growing
    /// city of population 2 with two Settlers queued is big enough again for the second by the
    /// time the first is out, so the second gets its turns, as the engine then bears out. With
    /// the first Settler about to complete, the city cannot grow back in time: the second may
    /// wait (the forecast rests on the growth).
    @Test func theQueueForecastCountsGrowth() throws {
        var state = makeTestState(map: openMap())
        let city = addCity(&state, me, at: hex(3, 3))
        // Its founding production (M1 §5) cleared: the first Settler is built from the phase's
        // production alone, slowly enough for the city to grow meanwhile.
        updateCity(&state, city) { $0.population = 2; $0.storedProgress = 0 }
        state.assignCitizens(state.cityIndex(city)!)
        let growth = try #require(state.view(for: me).growth(of: city))
        try #require(growth.surplus > 0)
        try apply(.setQueue(city: city, items: [.unit(.settler), .unit(.settler)]), &state)
        let status = state.view(for: me).queueStatus(of: city)
        let first = try #require(status[0].turns)
        #expect(first > (growth.turnsToGrow ?? .max), "the city grows before the first Settler is out")
        #expect(status[1].wait == nil && !status[1].waitIsForeseen)
        let production = state.cityYields(state.city(city)!).total.production
        // The second starts from what the first leaves over (capped at the phase's production).
        let settlerCost = state.rules.cost(of: .unit(.settler))
        let overflow = min(first * production - settlerCost, production)
        let settler = max(1, (settlerCost - overflow + production - 1) / production)
        #expect(status[1].turns == first + settler)
        // The engine: once the first Settler is out, the city is big enough for the second.
        for _ in 0..<first { try nextTurn(&state) }
        #expect(state.units(of: me).filter { $0.type == .settler }.count == 2, "the parked Settler and the first one")
        #expect(state.city(city)?.queue.map(\.item) == [.unit(.settler)])
        #expect(try #require(state.city(city)).population >= 2)
        #expect(state.view(for: me).productionWait(.unit(.settler), in: city) == nil)

        // The first Settler done next phase: the city is at population 1 after it, too soon to
        // grow back; a growing city may yet spare the wait, so it is uncertain.
        var soon = makeTestState(map: openMap())
        let town = addCity(&soon, me, at: hex(3, 3))
        updateCity(&soon, town) { $0.population = 2 }
        soon.assignCitizens(soon.cityIndex(town)!)
        try apply(.setQueue(city: town, items: [.unit(.settler), .unit(.settler)]), &soon)
        let cost = soon.rules.cost(of: .unit(.settler))
        updateCity(&soon, town) { $0.queue[0].progress = cost - 1 }
        let next = soon.view(for: me).queueStatus(of: town)
        #expect(next[0].turns == 1)
        #expect(next[1].wait == .population(2) && next[1].turns == nil && next[1].waitIsForeseen && next[1].waitIsUncertain)
    }

    /// A new city's founding production (M1 §5) finishes its first item at once, and that item's
    /// overflow, capped at the phase's production, goes into the next one (play-ipad T18: Antium
    /// showed its Monument at 9 turns, where 8 was right): the forecast counts it, and the
    /// engine completes the Monument in the phase it says. The stored line has nothing to add:
    /// the store goes into the Warrior, whose row counts it.
    @Test func theForecastCarriesTheOverflow() throws {
        // Plains: a city too slow to grow meanwhile, whose first phase finishes the Warrior with
        // a whole phase's production to spare.
        var state = makeTestState(map: HexMap(width: 12, height: 8, wrapsX: false, fill: Tile(terrain: .plains)))
        let city = addCity(&state, me, at: hex(3, 3))
        let stored = try #require(state.city(city)).storedProgress
        try #require(stored == state.rules.constants.city.foundingProduction)
        try apply(.setQueue(city: city, items: [.unit(.warrior), .building("monument")]), &state)
        let view = state.view(for: me)
        let status = view.queueStatus(of: city)
        let production = state.cityYields(state.city(city)!).total.production
        let warriorCost = state.rules.cost(of: .unit(.warrior)), monumentCost = state.rules.cost(of: .building("monument"))
        let overflow = min(stored + production - warriorCost, production)
        try #require(overflow == production)
        #expect(status[0].turns == 1 && status[0].receivesProduction && status[0].storedIncluded == stored)
        #expect(status[0].progress == warriorCost, "the row counts the store, capped at the cost")
        #expect(status[1].storedIncluded == 0 && !status[1].receivesProduction)
        let monument = try #require(status[1].turns)
        #expect(monument == 1 + max(1, (monumentCost - overflow + production - 1) / production))
        #expect(monument < 1 + (monumentCost + production - 1) / production, "a phase sooner than without the overflow")
        let store = try #require(view.storedProduction(of: city))
        #expect(store.receiver == 0 && store.amount == stored && store.lostNextPhase == 0)

        let grows = try #require(view.growth(of: city)).turnsToGrow ?? .max
        try #require(grows > monument, "the production stays the same meanwhile")
        for phase in 1...monument {
            try nextTurn(&state)
            let now = try #require(state.city(city))
            #expect(now.has("monument") == (phase == monument), "the Monument completes in phase \(monument), not \(phase)")
            if phase == 1 { #expect(now.storedProgress == overflow, "the Warrior's overflow is stored for the Monument") }
        }
    }

    /// While every item waits (a Settler in a city of population 1), production goes to the
    /// store, which keeps at most 2 × the phase's production (M1 §5): the panel's numbers say
    /// what the engine keeps and loses phase by phase, and a store already above the cap (the
    /// founding production) stays while new production is lost.
    @Test func theStoredProductionCapMatchesTheEngine() throws {
        var state = makeTestState(map: HexMap(width: 12, height: 8, wrapsX: false, fill: Tile(terrain: .plains)))
        let city = addCity(&state, me, at: hex(3, 3))
        try apply(.setQueue(city: city, items: [.unit(.settler)]), &state)
        // A Settler already paid for, waiting for population: it takes nothing more (a Settler
        // that is still filling would take the production, M1 §5), so the store gets it.
        let settlerCost = state.rules.cost(of: .unit(.settler))
        updateCity(&state, city) { $0.queue[0].progress = settlerCost }
        let production = state.cityYields(state.city(city)!).total.production
        let cap = state.rules.constants.production.storedProgressCapMultiplier * production
        // The founding production, above the cap: kept, and every new point lost.
        let founding = try #require(state.view(for: me).storedProduction(of: city))
        try #require(founding.amount > cap)
        #expect(founding.receiver == nil && founding.cap == cap && founding.lostNextPhase == production)
        try nextTurn(&state)
        #expect(state.city(city)?.storedProgress == founding.amount)

        // From a little: it fills up to the cap, then the rest is lost.
        updateCity(&state, city) { $0.storedProgress = 2 }
        let grows = try #require(state.view(for: me).growth(of: city)).turnsToGrow ?? .max
        try #require(grows > 4 && state.view(for: me).queueStatus(of: city).first?.wait == .population(2))
        for _ in 0..<4 {
            let before = try #require(state.view(for: me).storedProduction(of: city))
            #expect(before.receiver == nil && before.cap == cap)
            try nextTurn(&state)
            let after = try #require(state.city(city)).storedProgress
            #expect(after == min(before.amount + production, cap) && before.amount + production - after == before.lostNextPhase)
        }
        #expect(state.city(city)?.storedProgress == cap)
    }

    /// A military unit that completes at the next phase start is paid for at that phase start
    /// (production comes before the gold step): the forecast counts it, as the engine does.
    @Test func upkeepForecastCountsAUnitAboutToComplete() throws {
        var state = makeTestState(map: openMap(), gold: 0)
        let city = addCity(&state, me, at: hex(3, 3))
        // Units whose upkeep the city's gold does not cover, and a treasury that after the next
        // gold step pays exactly the upkeep of the units there now.
        var col = 0
        while state.view(for: me).income().upkeep < state.view(for: me).income().gold + 1 || col <= state.freeUnitAllowance(of: me) {
            state.addUnit(.warrior, owner: me, at: hex(col % 12, 6 + col / 12))
            col += 1
        }
        refreshKnowledge(&state)
        let income = state.view(for: me).income()
        state.players[0].gold = income.upkeep - income.gold
        #expect(state.view(for: me).upkeepForecast().disbanded == 0)
        // A Warrior one production short of done.
        let cost = state.rules.cost(of: .unit(.warrior))
        updateCity(&state, city) { c in
            c.queue = [QueueEntry(.unit(.warrior))]
            c.queue[0].progress = cost - 1
        }
        let forecast = state.view(for: me).upkeepForecast()
        #expect(forecast.completing == 1)
        #expect(forecast.disbanded == 1)
        var disbanded = 0
        var phases = 0
        repeat {
            for record in try apply(.endTurn, &state) {
                if case let .unitDisbanded(_, _, owner, _, upkeep) = record.event, owner == me, upkeep { disbanded += 1 }
            }
            phases += 1
        } while state.currentPlayer != me && phases < 8
        #expect(disbanded == forecast.disbanded)
    }

    /// Only visible enemy military units next to an own city count as a threat.
    @Test func threatenedCitiesUseOnlyWhatIsSeen() throws {
        var state = makeWarState()
        let city = addCity(&state, me, at: hex(3, 3))
        #expect(state.view(for: me).threatenedCities().isEmpty)
        state.addUnit(.builder, owner: them, at: hex(4, 3))
        #expect(state.view(for: me).threatenedCities().isEmpty, "civilians are no threat")
        state.addUnit(.warrior, owner: them, at: hex(2, 3))
        #expect(state.view(for: me).threatenedCities() == [city])

        var peace = makeTestState(map: openMap())
        addCity(&peace, me, at: hex(3, 3))
        peace.addUnit(.warrior, owner: them, at: hex(2, 3))
        #expect(peace.view(for: me).threatenedCities().isEmpty, "units at peace are no threat")
    }

    /// The Keep/Raze card's Raze says why not exactly when the engine refuses `razeCity`: only
    /// the capturer, in the phase of the capture, and never an original capital (M1 §5).
    @Test func razeProblemMatchesTheEngine() throws {
        var state = makeWarState(width: 16, height: 10)
        addCity(&state, them, at: hex(14, 2)) // their original capital
        let city = addCity(&state, them, at: hex(10, 6))
        updateCity(&state, city) { $0.hp = 0 }
        let warrior = state.addUnit(.warrior, owner: me, at: hex(9, 6))
        refreshKnowledge(&state)
        #expect(state.view(for: me).razeProblem(city) != nil, "not ours yet")
        try apply(.attack(unit: warrior, target: hex(10, 6)), &state)
        #expect(state.city(city)?.owner == me)
        #expect(state.view(for: me).razeProblem(city) == nil)
        #expect(state.view(for: them).razeProblem(city) != nil, "only the new owner may raze it")

        // A phase later the chance has passed, and the engine agrees.
        var later = state
        try nextTurn(&later)
        let problem = try #require(later.view(for: me).razeProblem(city))
        #expect(problem.contains("captured"))
        #expect(throws: (any Error).self) { try apply(.razeCity(city: city), &later) }

        // An original capital can never be razed. (A third player, who has founded no city
        // yet, keeps the capture from ending the game by domination.)
        var capitals = makeWarState(width: 16, height: 10, players: 3)
        let capital = addCity(&capitals, them, at: hex(10, 6))
        addCity(&capitals, them, at: hex(14, 2))
        updateCity(&capitals, capital) { $0.hp = 0 }
        let attacker = capitals.addUnit(.warrior, owner: me, at: hex(9, 6))
        refreshKnowledge(&capitals)
        try apply(.attack(unit: attacker, target: hex(10, 6)), &capitals)
        #expect(capitals.city(capital)?.owner == me)
        #expect(capitals.view(for: me).razeProblem(capital) == "original capitals cannot be razed")
        #expect(throws: (any Error).self) { try apply(.razeCity(city: capital), &capitals) }

        // The capture's own phase: the engine razes what the query allows.
        try apply(.razeCity(city: city), &state)
        #expect(state.city(city) == nil)
    }
}
