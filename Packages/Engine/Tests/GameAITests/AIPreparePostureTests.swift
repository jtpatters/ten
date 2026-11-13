import Foundation
import Testing
@testable import GameAI
@testable import GameCore

// p3f ai-prepare-posture (GameAI/AIPreparePosture.swift, M1 §13 Cities, Settling, War): in
// prepare, B keeps Settlers ahead of the army while the rival has as many cities and sends them
// toward it; C puts the army unit nearest the stage on watch in the target's sight. Each scene
// sets the values it needs, so the tests hold whatever the ruleset's defaults are.

private let p0 = PlayerID(0)
private let p1 = PlayerID(1)

/// The four p3f values: missing (nil), as before p3f.
private let off: [String: Int?] = [
    "prepareSettlersRivalPct": nil, "prepareSiteRivalWeight": nil, "prepareStageRadius": nil, "prepareStageUnits": nil,
]
/// The four p3f values as M1 §13 sets them.
private let on: [String: Int?] = [
    "prepareSettlersRivalPct": 125, "prepareSiteRivalWeight": 2, "prepareStageRadius": 2, "prepareStageUnits": 1,
]

/// The standard rules with these "ai" values (nil: the key removed).
private func rules(_ values: [String: Int?], _ more: [String: Int?] = [:]) throws -> Ruleset {
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Ruleset.standard.data)) as? [String: Any])
    var ai = try #require(json["ai"] as? [String: Any])
    for (key, value) in values.merging(more, uniquingKeysWith: { $1 }) {
        if let value { ai[key] = value } else { ai.removeValue(forKey: key) }
    }
    json["ai"] = ai
    return try Ruleset(jsonData: JSONSerialization.data(withJSONObject: json))
}

/// A 30×14 open map: p0 (AI) with cities at `mine` (population 3, a Warrior each) and two
/// Builders, the whole map explored; p1 with cities at `theirs`, all remembered by p0; met, at
/// peace, at `turn`. With p1 remembered from turn 30 on, p0 prepares against it.
private func scene(_ rules: Ruleset, mine: [HexCoord], theirs: [HexCoord], turn: Int = 40) -> (GameState, [CityID]) {
    let map = openMap(width: 30, height: 14)
    let players = (0..<2).map { Player(id: PlayerID($0), name: "P\($0)", isHuman: false, tileCount: map.tileCount, gold: 100) }
    var state = GameState(seed: 1, map: map, players: players, rules: rules, mapSizeName: "duel")
    var cities: [CityID] = []
    for spot in mine {
        let city = addCity(&state, p0, at: spot)
        updateCity(&state, city) { $0.population = 3 }
        state.addUnit(.warrior, owner: p0, at: spot)
        cities.append(city)
    }
    for i in 0..<2 { state.addUnit(.builder, owner: p0, at: hex(1, 1 + 2 * i)) }
    for spot in theirs { addCity(&state, p1, at: spot) }
    for t in 0..<state.map.tileCount { state.players[p0.rawValue].explored[t] = true }
    refreshKnowledge(&state)
    for spot in theirs { reveal(&state, to: p0, from: OffsetCoord(col: spot.offset.col - 1, row: spot.offset.row).hex) }
    setRelation(&state, p0, p1, war: false, since: nil)
    state.turn = turn
    return (state, cities)
}

/// The AI of p0 with this phase's plan made.
private func planned(_ state: GameState) -> AITurn {
    var turn = AITurn(state: state, player: p0)
    turn.plan = turn.makePlan()
    return turn
}

/// The head of the queue p0 wants for `city` now.
private func wantedHead(_ state: GameState, _ city: CityID) -> ProductionItem? {
    let turn = planned(state)
    return turn.decideQueue(for: city, turn.baseCounts()).first
}

private func isMilitary(_ item: ProductionItem?) -> Bool {
    if case let .unit(type)? = item { !type.isCivilian } else { false }
}

private let westCities = [hex(4, 3), hex(4, 10), hex(9, 6)]
private let eastCities = [hex(26, 3), hex(26, 10), hex(21, 6)]

@Suite struct AIPreparePostureTests {
    /// The standard rules carry M1 §13's values.
    @Test func defaults() {
        let ai = Ruleset.standard.ai
        #expect(ai.prepareSettlersRivalPct == 125)
        #expect(ai.prepareSiteRivalWeight == 2)
        #expect(ai.prepareStageRadius == 2)
        #expect(ai.prepareStageUnits == 1)
    }

    // MARK: B

    /// B: with 3 cities against a rival's 3, Settlers come before the army at 125% (3 < 1.25 × 3)
    /// but not at 100%, with the rule off, or with a Settler alive (it counts as a city).
    @Test func settlersAheadOfTheArmyWhileTheRivalHasAsManyCities() throws {
        try #require(Ruleset.standard.ai.armyFirstCities == 3)
        let (state, cities) = scene(try rules(on), mine: westCities, theirs: eastCities)
        let plan = planned(state).plan
        try #require(plan.posture == .prepare && plan.goodSiteExists && plan.rival == p1)
        #expect(wantedHead(state, cities[0]) == .unit(.settler))

        let (even, evenCities) = scene(try rules(on, ["prepareSettlersRivalPct": 100]), mine: westCities, theirs: eastCities)
        #expect(isMilitary(wantedHead(even, evenCities[0])), "\(String(describing: wantedHead(even, evenCities[0])))")

        let (plain, plainCities) = scene(try rules(off), mine: westCities, theirs: eastCities)
        #expect(isMilitary(wantedHead(plain, plainCities[0])))

        var (settling, settlingCities) = scene(try rules(on), mine: westCities, theirs: eastCities)
        settling.addUnit(.settler, owner: p0, at: hex(9, 6))
        #expect(isMilitary(wantedHead(settling, settlingCities[0])))

        // Against a rival with one city, 3 is not fewer: the army comes first as before.
        let (ahead, aheadCities) = scene(try rules(on), mine: westCities, theirs: [hex(26, 6)])
        #expect(isMilitary(wantedHead(ahead, aheadCities[0])))
    }

    /// B: in prepare a site is worth prepareSiteRivalWeight less per tile from the rival's
    /// nearest remembered city; off without the rule, the weight, or the prepare posture.
    @Test func sitesAreMeasuredFromTheRival() throws {
        let (state, _) = scene(try rules(on), mine: westCities, theirs: eastCities)
        let turn = planned(state)
        let toward = try #require(turn.rivalSitePreference(turn.view))
        #expect(toward.weight == 2)
        #expect(toward.cities.sorted() == eastCities.map { tile(state, $0) }.sorted())
        #expect(toward.penalty(tile(state, hex(15, 6)), turn.view) == 2 * 6) // 6 tiles from hex(21, 6)
        #expect(toward.penalty(tile(state, hex(21, 6)), turn.view) == 0)

        for values in [off, on.merging(["prepareSiteRivalWeight": 0], uniquingKeysWith: { $1 }),
                       on.merging(["prepareSettlersRivalPct": 0], uniquingKeysWith: { $1 })] {
            let (other, _) = scene(try rules(values), mine: westCities, theirs: eastCities)
            let t = planned(other)
            #expect(t.rivalSitePreference(t.view) == nil)
        }
        let (early, _) = scene(try rules(on), mine: westCities, theirs: eastCities, turn: 20)
        let t = planned(early)
        try #require(t.plan.posture == .expand)
        #expect(t.rivalSitePreference(t.view) == nil)
    }

    /// B: a Settler between its cities heads for a site nearer the rival than it would without
    /// the rule.
    @Test func aSettlerHeadsTowardTheRival() throws {
        func settled(_ values: [String: Int?]) throws -> Int {
            var (state, _) = scene(try rules(values), mine: westCities, theirs: eastCities)
            let settler = state.addUnit(.settler, owner: p0, at: hex(6, 6))
            state.addUnit(.warrior, owner: p0, at: hex(6, 6))
            playPhase(&state)
            let at = try #require(state.unit(settler)?.position)
            return eastCities.map { state.map.distance(at, $0) }.min()!
        }
        let plain = try settled(off), toward = try settled(on)
        #expect(toward < plain, "toward \(toward), plain \(plain)")
    }

    // MARK: C

    /// C: the stage is a tile the army may stand on within the target's sight (2), nearest the
    /// rally city; off without the rule.
    @Test func theStageLiesInTheTargetsSightNearestTheRallyCity() throws {
        let target = hex(20, 6)
        let (state, _) = scene(try rules(on), mine: [hex(4, 6), hex(9, 6)], theirs: [target])
        let turn = planned(state)
        let plan = turn.plan
        try #require(plan.posture == .prepare && plan.target?.position == target)
        let rally = try #require(plan.rally?.position)
        let stage = try #require(plan.stage)
        let v = turn.view
        let closed = v.aiClosedToMilitary()
        #expect(v.aiDistance(stage, tile(state, target)) <= 2)
        #expect(!closed[stage])
        // Nearest the rally city (open grassland: the terrain cost is the distance) of the
        // tiles within 2 of the target outside the rival's (closed) territory.
        let candidates = state.map.coords(within: 2, of: target).map { tile(state, $0) }.filter { !closed[$0] && $0 != tile(state, target) }
        try #require(!candidates.isEmpty)
        let nearest = candidates.map { state.map.distance(rally, state.map.coord(at: $0)) }.min()!
        #expect(state.map.distance(rally, state.map.coord(at: stage)) == nearest)

        let (plain, _) = scene(try rules(off), mine: [hex(4, 6), hex(9, 6)], theirs: [target])
        #expect(planned(plain).plan.stage == nil)
    }

    /// C: never a tile closed to the army; with every tile in the target's sight closed, the
    /// stage is the open tile nearest the target.
    @Test func theStageIsNeverClosed() throws {
        let target = hex(20, 6)
        var (state, _) = scene(try rules(on), mine: [hex(4, 6), hex(9, 6)], theirs: [target])
        for h in state.map.coords(within: 2, of: target) {
            state.players[p0.rawValue].memory.tileOwner[tile(state, h)] = UInt8(p1.rawValue + 1)
        }
        let turn = planned(state)
        let stage = try #require(turn.plan.stage)
        #expect(!turn.view.aiClosedToMilitary()[stage])
        #expect(turn.view.aiDistance(stage, tile(state, target)) == 3)
    }

    /// C: with prepareStageUnits 1 only the army unit nearest the stage goes there; with it
    /// missing, all; without a stage, none.
    @Test func theUnitNearestTheStageStandsWatch() throws {
        func units(_ values: [String: Int?]) throws -> (watch: [UnitID], army: [UnitID]) {
            var (state, _) = scene(try rules(values), mine: [hex(4, 6), hex(9, 6)], theirs: [hex(20, 6)])
            let far = state.addUnit(.archer, owner: p0, at: hex(8, 5))
            let near = state.addUnit(.spearman, owner: p0, at: hex(11, 6))
            let middle = state.addUnit(.warrior, owner: p0, at: hex(10, 7))
            let turn = planned(state)
            return (turn.stageUnits([far, near, middle], turn.view), [far, near, middle])
        }
        let one = try units(on)
        #expect(one.watch == [one.army[1]])
        let all = try units(on.merging(["prepareStageUnits": nil], uniquingKeysWith: { $1 }))
        #expect(all.watch == all.army)
        #expect(try units(off).watch.isEmpty)
    }

    /// C: in a phase, the watch moves toward the stage while the rest of the army gathers by the
    /// rally city, away from the rival; without the rule none goes toward the target.
    @Test func oneUnitMovesToTheStage() throws {
        func closer(_ values: [String: Int?]) throws -> Int {
            var (state, _) = scene(try rules(values), mine: [hex(4, 6), hex(9, 6)], theirs: [hex(20, 6)])
            let army = [state.addUnit(.warrior, owner: p0, at: hex(10, 6)), state.addUnit(.warrior, owner: p0, at: hex(9, 7)),
                        state.addUnit(.archer, owner: p0, at: hex(8, 6))]
            let before = army.map { state.map.distance(state.unit($0)!.position, hex(20, 6)) }
            try #require(planned(state).plan.posture == .prepare)
            playPhase(&state)
            let after = try army.map { state.map.distance(try #require(state.unit($0)).position, hex(20, 6)) }
            return zip(before, after).filter { $1 < $0 }.count
        }
        #expect(try closer(on) == 1)
        #expect(try closer(off) == 0)
    }

    /// C: the war test counts the units at the stage as well as those near the rally city.
    @Test func theWarTestCountsTheWatch() throws {
        func ready(_ values: [String: Int?]) throws -> Bool {
            let target = hex(20, 6)
            var (state, _) = scene(try rules(values), mine: [hex(4, 6), hex(9, 6)], theirs: [target])
            // Two Archers and two Spearmen in the target's sight on the side of the rally city,
            // outside the rival's territory: 100 power against an estimate of 15 (one city).
            for (type, spot) in [(UnitType.archer, hex(18, 5)), (.archer, hex(18, 7)), (.spearman, hex(18, 6)), (.spearman, hex(17, 6))] {
                state.addUnit(type, owner: p0, at: spot)
            }
            refreshKnowledge(&state)
            let plan = planned(state).plan
            try #require(plan.posture == .prepare)
            return plan.readyForWar
        }
        #expect(try ready(on))
        #expect(try !ready(off))
    }
}
