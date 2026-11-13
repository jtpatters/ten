import Foundation
import Testing
@testable import GameAI
@testable import GameCore

// p3f ai-after-city-loss (M1 §13 War, Cities). In the iPhone play-test the Mongols took Antium
// at T35 and Rome, left with its capital, neither tried to take it back nor founded a city to
// T50, beside an empty north. HeadlessSim's stand-ins never take an AI city early, so the scenes
// are made by hand: Rome (player 0, the AI) founded Rome and Antium; the Mongols (player 1) took
// Antium with a Warrior.

private let p0 = PlayerID(0)
private let p1 = PlayerID(1)

/// Rome's capital at `rome`, Antium at `antium` taken by player 1, player 1's capital at (21,6)
/// and, with `avarga`, a city of its own there. Everything explored by player 0, which remembers
/// player 1's cities. `lost`: Antium was Rome's (else player 1 founded it).
private func world(rome: HexCoord = hex(2, 6), antium: HexCoord = hex(12, 3), avarga: HexCoord? = nil,
                   lost: Bool = true, war: Bool, since: Int, turn: Int) -> (state: GameState, antium: CityID) {
    var state = makeState(map: openMap(width: 24, height: 12), gold: 0)
    state.players[0].civ = "rome"
    state.players[1].civ = "mongols"
    state.turn = turn
    addCity(&state, p0, at: rome)
    let karakorum = addCity(&state, p1, at: hex(21, 6))
    let city = addCity(&state, lost ? p0 : p1, at: antium)
    if let avarga { addCity(&state, p1, at: avarga) }
    for id in [karakorum, city] { updateCity(&state, id) { $0.population = 3 } }
    if lost {
        let captor = state.addUnit(.warrior, owner: p1, at: HexCoord(q: antium.q + 1, r: antium.r))
        var fx = Effects()
        state.captureCity(state.cityIndex(city)!, by: captor, &fx)
        state.updateKnowledge(&fx)
    }
    state.addUnit(.warrior, owner: p0, at: rome)
    setRelation(&state, p0, p1, war: war, since: since)
    for t in 0..<state.map.tileCount { state.players[0].explored[t] = true }
    refreshKnowledge(&state)
    for spot in [antium, hex(21, 6)] + (avarga.map { [$0] } ?? []) { reveal(&state, to: p0, from: spot) }
    return (state, city)
}

@Suite struct AIAfterLossTests {
    /// The lost city is told apart by its name, a name of the AI's own civ: Antium, not
    /// player 1's own cities, and nothing when player 1 founded Antium itself.
    @Test func aLostCityIsOneOfTheCivsNames() throws {
        let (state, antium) = world(avarga: hex(8, 9), war: true, since: 40, turn: 45)
        try #require(state.city(antium)?.owner == p1)
        let turn = AITurn(state: state, player: p0)
        let v = turn.view
        try #require(v.knownCities.filter { $0.owner == p1 }.count == 3)
        #expect(turn.lostCities(v).map(\.name) == ["Antium"])
        #expect(turn.lostCities(v, of: p1).map(\.id) == [antium])
        let (founded, _) = world(avarga: hex(8, 9), lost: false, war: true, since: 40, turn: 45)
        let other = AITurn(state: founded, player: p0)
        #expect(other.lostCities(other.view).isEmpty)
    }

    /// Recapture (M1 §13 War): at war, the lost city is the target, though Avarga costs less
    /// from the capital, while the army is at least the lost city's estimate (15 plus the units
    /// sighted within 4 of it); with too small an army the lowest-cost rule holds.
    @Test func theLostCityIsTheTargetWhileTheArmyMatchesIt() throws {
        var (state, _) = world(avarga: hex(8, 9), war: true, since: 40, turn: 45)
        state.players[0].memory.units = [
            UnitSighting(id: UnitID(900), owner: p1, type: .warrior, position: hex(12, 3), hp: 100, turnSeen: 44),
        ]
        var weak = AITurn(state: state, player: p0)
        weak.plan = weak.makePlan()
        #expect(weak.plan.target?.name == "Avarga", "\(weak.plan.summary)")
        let antium = try #require(weak.view.knownCities.first { $0.name == "Antium" })
        let estimate = weak.cityEstimate(antium, weak.view)
        #expect(estimate == state.rules.ai.cityPowerEstimate + weak.view.power(of: .warrior, hp: 100))

        for col in 3...5 { state.addUnit(.warrior, owner: p0, at: hex(col, 7)) }
        var strong = AITurn(state: state, player: p0)
        strong.plan = strong.makePlan()
        try #require(strong.plan.army >= estimate, "army \(strong.plan.army) < \(estimate)")
        #expect(strong.plan.target?.name == "Antium", "\(strong.plan.summary)")
    }

    /// Resettle (M1 §13 Cities): left with one city after losing one, at peace, Rome builds a
    /// Settler first, though Mongol units stand within 4 of it (threatened: a second defender
    /// and Walls first otherwise); not at war, nor when it never lost a city.
    @Test func leftWithOneCityAtPeaceItBuildsASettlerFirst() throws {
        func queue(lost: Bool, war: Bool) -> [ProductionItem] {
            var (state, _) = world(rome: hex(4, 6), antium: hex(11, 6), lost: lost, war: war, since: 47, turn: 48)
            let rome = state.cities.first { $0.owner == p0 }!.id
            updateCity(&state, rome) { $0.population = 4 }
            state.addUnit(.archer, owner: p1, at: hex(6, 6))
            state.addUnit(.warrior, owner: p1, at: hex(6, 5))
            refreshKnowledge(&state)
            var turn = AITurn(state: state, player: p0)
            turn.plan = turn.makePlan()
            #expect(turn.plan.isThreatened(rome))
            #expect(turn.plan.goodSiteExists)
            return turn.decideQueue(for: rome, turn.baseCounts())
        }
        let resettle = queue(lost: true, war: false)
        #expect(resettle.first == .unit(.settler), "\(resettle)")
        let never = queue(lost: false, war: false)
        #expect(never.first != .unit(.settler), "\(never)")
        let atWar = queue(lost: true, war: true)
        #expect(!atWar.contains(.unit(.settler)), "\(atWar)")
    }
}
