import Foundation
import Testing
@testable import GameAI
@testable import GameCore

// One test (or a pair) per M1 §13 rule, on hand-made situations: the AI plays a whole phase and
// the test checks the commands that rule must (or must not) produce.

private let p0 = PlayerID(0)
private let p1 = PlayerID(1)

/// Every tile explored by `player`.
private func exploreAll(_ state: inout GameState, _ player: PlayerID) {
    for t in 0..<state.map.tileCount { state.players[player.rawValue].explored[t] = true }
    refreshKnowledge(&state)
}

@Suite struct AISettlingTests {
    /// First city: on turn 1 the Settler founds where it stands when no neighbour scores
    /// ≥ 110% of its tile.
    @Test func firstCityFoundedInPlace() throws {
        var state = makeState()
        let settler = state.addUnit(.settler, owner: p0, at: hex(10, 6))
        state.addUnit(.settler, owner: p1, at: hex(2, 2))
        let view = state.view(for: p0)
        let here = view.settleScore(at: hex(10, 6))
        try #require(view.neighbors(of: hex(10, 6)).allSatisfy { 100 * view.settleScore(at: $0) < 110 * here })
        let (commands, _) = playPhase(&state)
        #expect(commands.contains(.foundCity(unit: settler)))
        #expect(!commands.contains { if case .moveUnit(settler, _) = $0 { true } else { false } })
        #expect(state.cities.first { $0.owner == p0 }?.position == hex(10, 6))
    }

    /// First city: a neighbour scoring ≥ 110% draws the Settler, which founds there on turn 2.
    /// (Desert all around; grassland around (11,6) with a lake at (12,6): fresh water there.)
    @Test func firstCityMovesToABetterNeighbour() throws {
        var map = openMap(fill: Tile(terrain: .desert))
        for h in map.coords(within: 1, of: hex(11, 6)) { map[h] = Tile(terrain: .grassland) }
        map[hex(12, 6)] = Tile(terrain: .lake)
        var state = makeState(map: map)
        let settler = state.addUnit(.settler, owner: p0, at: hex(10, 6))
        state.addUnit(.settler, owner: p1, at: hex(2, 2))
        let view = state.view(for: p0)
        let here = view.settleScore(at: hex(10, 6))
        let better = view.neighbors(of: hex(10, 6)).filter { 100 * view.settleScore(at: $0) >= 110 * here }
        try #require(!better.isEmpty)

        let (turn1, _) = playPhase(&state)
        #expect(!turn1.contains(.foundCity(unit: settler)))
        let moved = try #require(state.unit(settler)?.position)
        #expect(better.contains(moved))
        playPhase(&state) // player 1
        #expect(state.turn == 2 && state.currentPlayer == p0)
        let (turn2, _) = playPhase(&state)
        #expect(turn2.contains(.foundCity(unit: settler)))
        #expect(state.cities.first { $0.owner == p0 }?.position == moved)
    }

    /// Good site: a Settler standing on the best good site founds a city there.
    @Test func settlerFoundsOnAGoodSite() throws {
        var state = makeState()
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p1, at: hex(18, 2))
        state.addUnit(.warrior, owner: p0, at: hex(4, 6))
        let settler = state.addUnit(.settler, owner: p0, at: hex(9, 6))
        exploreAll(&state, p0)
        let view = state.view(for: p0)
        try #require(view.settleScore(at: hex(9, 6)) >= state.rules.ai.minSettleScore)
        let (commands, _) = playPhase(&state)
        #expect(commands.contains(.foundCity(unit: settler)))
        #expect(state.cities.contains { $0.owner == p0 && $0.position == hex(9, 6) })
    }

    /// No good site: the Settler goes to the nearest own city and sleeps there.
    @Test func settlerWithoutASiteSleepsInTheNearestCity() throws {
        var map = openMap(fill: Tile(terrain: .ocean))
        for h in map.coords(within: 3, of: hex(6, 5)) { map[h] = Tile(terrain: .grassland) }
        for h in map.coords(within: 1, of: hex(16, 5)) { map[h] = Tile(terrain: .grassland) }
        var state = makeState(map: map)
        let city = addCity(&state, p0, at: hex(6, 5))
        addCity(&state, p1, at: hex(16, 5))
        let settler = state.addUnit(.settler, owner: p0, at: hex(8, 5))
        let view = state.view(for: p0)
        try #require((0..<view.tileCount).allSatisfy { !view.canFoundCity(at: view.coord(at: $0)) || view.settleScore(at: view.coord(at: $0)) == 0 || state.map.distance(view.coord(at: $0), hex(6, 5)) < 4 })
        let (commands, _) = playPhase(&state)
        #expect(!commands.contains(.foundCity(unit: settler)))
        #expect(state.unit(settler)?.position == state.city(city)?.position)
        #expect(state.unit(settler)?.activity == .sleeping)
    }
}

@Suite struct AIWarTests {
    /// The war test's world: turn `turn`; player 0's capital at (4,6) with a garrison and an
    /// army of `archers` Archers and `warriors` Warriors next to it; player 1's city at (14,6),
    /// remembered by player 0; met, at peace, never at war.
    static func world(turn: Int, archers: Int, warriors: Int) -> GameState {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p1, at: hex(14, 6))
        state.players[0].knownTechs.append("archery")
        state.addUnit(.warrior, owner: p0, at: hex(4, 6))
        let spots = [hex(5, 6), hex(3, 6), hex(4, 5), hex(4, 7), hex(5, 5), hex(5, 7)]
        var i = 0
        for _ in 0..<archers { state.addUnit(.archer, owner: p0, at: spots[i]); i += 1 }
        for _ in 0..<warriors { state.addUnit(.warrior, owner: p0, at: spots[i]); i += 1 }
        reveal(&state, to: p0, from: hex(13, 6))
        setRelation(&state, p0, p1, war: false, since: nil)
        state.turn = turn
        return state
    }

    /// All conditions hold: war is declared on the rival.
    @Test func declaresWarWhenReady() throws {
        var state = Self.world(turn: 30, archers: 2, warriors: 2)
        try #require(state.view(for: p0).knownCities.contains { $0.owner == p1 })
        let (commands, report) = playPhase(&state)
        #expect(commands.contains(.declareWar(on: p1)))
        #expect(report.posture == .war)
        #expect(state.isAtWar(p0, p1))
    }

    /// Too early (turn < 30): no war.
    @Test func noWarBeforeTurn30() {
        var state = Self.world(turn: 29, archers: 2, warriors: 2)
        let (commands, _) = playPhase(&state)
        #expect(!commands.contains(.declareWar(on: p1)))
    }

    /// One ranged unit short: no war, but the AI prepares.
    @Test func noWarWithoutTwoRangedUnits() {
        var state = Self.world(turn: 40, archers: 1, warriors: 3)
        let (commands, report) = playPhase(&state)
        #expect(!commands.contains(.declareWar(on: p1)))
        #expect(report.posture == .prepare)
    }

    /// At peace for fewer than 10 turns since the last war: no war.
    @Test func noWarSoonAfterPeace() {
        var state = Self.world(turn: 40, archers: 2, warriors: 2)
        setRelation(&state, p0, p1, war: false, since: 35)
        let (commands, _) = playPhase(&state)
        #expect(!commands.contains(.declareWar(on: p1)))
    }
}

@Suite struct AITacticsTests {
    /// At war: player 0's capital far west at (0,6) or nearer at (2,6); player 1's capital at
    /// (22,6) and its city at (8,6) with 0 HP and no garrison, next to player 0's Warrior; a
    /// player 1 Warrior at (5,9) that player 0's Archer at (4,8) and Spearman at (5,8) can hit.
    struct World {
        var state: GameState
        var target: CityID
        var warrior: UnitID, archer: UnitID, spearman: UnitID
        var enemy: UnitID
    }

    static func world(home: HexCoord) -> World {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: home)
        addCity(&state, p1, at: hex(22, 6))
        let target = addCity(&state, p1, at: hex(8, 6))
        updateCity(&state, target) { $0.hp = 0 }
        state.players[0].knownTechs += ["archery", "bronzeWorking"]
        let warrior = state.addUnit(.warrior, owner: p0, at: hex(7, 6))
        let archer = state.addUnit(.archer, owner: p0, at: hex(4, 8))
        let spearman = state.addUnit(.spearman, owner: p0, at: hex(5, 8))
        let enemy = state.addUnit(.warrior, owner: p1, at: hex(5, 9))
        setRelation(&state, p0, p1, war: true, since: 1)
        refreshKnowledge(&state)
        return World(state: state, target: target, warrior: warrior, archer: archer, spearman: spearman, enemy: enemy)
    }

    static func firstIndex(_ commands: [Command], _ match: (Command) -> Bool) -> Int? { commands.firstIndex(where: match) }

    /// Tactic 1 comes first (the 0-HP city is captured), then ranged fire (tactic 2), then
    /// melee attacks (tactic 3).
    @Test func tacticsRunInOrder() throws {
        var w = Self.world(home: hex(2, 6))
        let view = w.state.view(for: p0)
        let capture = try #require(view.attackOptions(for: w.warrior).first { $0.target == hex(8, 6) })
        try #require(view.combatPreview(attacker: .unit(w.warrior), target: capture.target, from: capture.from)?.capturesCity == true)
        let (commands, _) = playPhase(&w.state)
        let captureAt = try #require(commands.firstIndex(of: .attack(unit: w.warrior, target: hex(8, 6))))
        let shotAt = try #require(commands.firstIndex { if case .attack(w.archer, _) = $0 { true } else { false } })
        #expect(captureAt < shotAt)
        if let meleeAt = commands.firstIndex(where: { if case .attack(w.spearman, _) = $0 { true } else { false } }) {
            #expect(shotAt < meleeAt)
        }
        #expect(w.state.city(w.target)?.owner == p0)
    }

    /// Captured cities are kept near home (closer than 8 tiles to an own city).
    @Test func capturedCityNearHomeIsKept() throws {
        var w = Self.world(home: hex(2, 6))
        let (commands, _) = playPhase(&w.state)
        #expect(!commands.contains(.razeCity(city: w.target)))
        #expect(w.state.city(w.target)?.owner == p0)
    }

    /// A captured population-1 city at least 8 tiles from every own city is razed.
    @Test func capturedCityFarAwayIsRazed() throws {
        var w = Self.world(home: hex(0, 6))
        try #require(w.state.map.distance(hex(0, 6), hex(8, 6)) >= 8)
        let (commands, _) = playPhase(&w.state)
        #expect(commands.contains(.attack(unit: w.warrior, target: hex(8, 6))))
        #expect(commands.contains(.razeCity(city: w.target)))
        #expect(w.state.city(w.target) == nil)
    }
}

@Suite struct AIPeaceTests {
    /// At war since `since` (turn 40): player 0 has its capital with a garrison and `army`
    /// Warriors; player 1 has three cities player 0 remembers.
    static func world(since: Int, army: Int, proposal: Bool = false) -> GameState {
        var state = makeState(map: openMap(width: 24, height: 12))
        addCity(&state, p0, at: hex(2, 6))
        state.addUnit(.warrior, owner: p0, at: hex(2, 6))
        for h in [hex(3, 5), hex(3, 6), hex(3, 7), hex(1, 5)].prefix(army) {
            state.addUnit(.warrior, owner: p0, at: h)
        }
        for (col, row) in [(14, 3), (14, 9), (20, 6)] {
            addCity(&state, p1, at: hex(col, row))
            reveal(&state, to: p0, from: hex(col - 1, row))
        }
        state.turn = 40
        setRelation(&state, p0, p1, war: true, since: since)
        if proposal { state.updateRelation(p0, p1) { $0.proposalFrom = p1 } }
        return state
    }

    /// After ≥ 10 turns of war, an AI whose army is under 80% of its estimate of the rival
    /// proposes peace.
    @Test func weakAIProposesPeaceAfterTenTurns() {
        var state = Self.world(since: 30, army: 0)
        let (commands, _) = playPhase(&state)
        #expect(commands.contains(.proposePeace(to: p1)))
    }

    /// Fewer than 10 turns of war: no proposal.
    @Test func noPeaceBeforeTenTurns() {
        var state = Self.world(since: 31, army: 0)
        let (commands, _) = playPhase(&state)
        #expect(!commands.contains(.proposePeace(to: p1)))
    }

    /// A strong AI in a war younger than 30 turns does not propose peace.
    @Test func strongAIKeepsFighting() {
        var state = Self.world(since: 30, army: 4)
        let (commands, _) = playPhase(&state)
        #expect(!commands.contains(.proposePeace(to: p1)))
    }

    /// The same rule answers proposals: the weak AI accepts, the strong one refuses.
    @Test func proposalsAreAnsweredByTheSameRule() {
        var weak = Self.world(since: 30, army: 0, proposal: true)
        let (accepted, _) = playPhase(&weak)
        #expect(accepted.contains(.respondToPeace(from: p1, accept: true)))
        #expect(!weak.isAtWar(p0, p1))
        var strong = Self.world(since: 30, army: 4, proposal: true)
        let (refused, _) = playPhase(&strong)
        #expect(refused.contains(.respondToPeace(from: p1, accept: false)))
        #expect(strong.isAtWar(p0, p1))
    }

    /// No city changed hands for 30 turns: even a strong AI makes peace.
    @Test func stalemateEndsInPeace() {
        var state = Self.world(since: 10, army: 4)
        let (commands, _) = playPhase(&state)
        #expect(commands.contains(.proposePeace(to: p1)))
    }
}

@Suite struct AIPurchaseTests {
    /// Player 0's city of population 2 making a Settler (good sites all around), with a
    /// garrison and a Scout; `gold` in the treasury.
    static func settlerWorld(gold: Int) -> (GameState, CityID) {
        var state = makeState(gold: gold)
        let city = addCity(&state, p0, at: hex(4, 6))
        addCity(&state, p1, at: hex(18, 2))
        updateCity(&state, city) { $0.population = 2 }
        state.addUnit(.warrior, owner: p0, at: hex(4, 6))
        state.addUnit(.scout, owner: p0, at: hex(6, 9))
        exploreAll(&state, p0)
        return (state, city)
    }

    /// Settlers are bought only with at least twice their price in the treasury.
    @Test func civiliansAreBoughtOnlyWithTwiceTheirPrice() throws {
        let price = Ruleset.standard.cost(of: .unit(.settler)) * Ruleset.standard.constants.production.purchaseCostMultiplier
        var poor = Self.settlerWorld(gold: 2 * price - 1)
        let (poorCommands, _) = playPhase(&poor.0)
        #expect(!poorCommands.contains(.purchase(city: poor.1, item: .unit(.settler))))
        #expect(poor.0.city(poor.1)?.queue.first?.item == .unit(.settler))
        var rich = Self.settlerWorld(gold: 2 * price)
        let (richCommands, _) = playPhase(&rich.0)
        #expect(richCommands.contains(.purchase(city: rich.1, item: .unit(.settler))))
    }

    /// A threatened city short of defenders buys one when gold ≥ price + 20.
    static func threatWorld(gold: Int) -> (GameState, CityID) {
        var state = makeState(gold: gold)
        let city = addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 2))
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        state.addUnit(.warrior, owner: p1, at: hex(8, 6))
        setRelation(&state, p0, p1, war: false, since: nil)
        refreshKnowledge(&state)
        return (state, city)
    }

    @Test func threatenedCitiesBuyADefender() throws {
        let price = Ruleset.standard.cost(of: .unit(.warrior)) * Ruleset.standard.constants.production.purchaseCostMultiplier
        var short = Self.threatWorld(gold: price + 19)
        try #require(short.0.view(for: p0).visibleForeignUnits.count == 1)
        let (shortCommands, report) = playPhase(&short.0)
        #expect(report.planSummary.contains("threatened"))
        #expect(!shortCommands.contains(.purchase(city: short.1, item: .unit(.warrior))))
        var enough = Self.threatWorld(gold: price + 20)
        let (commands, _) = playPhase(&enough.0)
        #expect(commands.contains(.purchase(city: enough.1, item: .unit(.warrior))))
    }
}

@Suite struct AISafetyTests {
    /// Civilian safety: a Builder and a Settler never end the phase within 2 tiles of a visible
    /// foreign military unit unless an own military unit shares their tile.
    @Test func civiliansStayClearOfForeignMilitary() throws {
        var state = makeState()
        let city = addCity(&state, p0, at: hex(6, 6))
        addCity(&state, p1, at: hex(18, 2))
        updateCity(&state, city) { $0.population = 3 }
        state.addUnit(.warrior, owner: p0, at: hex(6, 6))
        let builder = state.addUnit(.builder, owner: p0, at: hex(6, 6))
        let settler = state.addUnit(.settler, owner: p0, at: hex(5, 5))
        state.addUnit(.warrior, owner: p1, at: hex(8, 5))
        state.addUnit(.warrior, owner: p1, at: hex(3, 8))
        setRelation(&state, p0, p1, war: false, since: nil)
        exploreAll(&state, p0)
        playPhase(&state)
        let foreign = state.view(for: p0).visibleForeignUnits.filter { !$0.type.isCivilian }.map(\.position)
        for id in [builder, settler] {
            guard let unit = state.unit(id) else { continue }
            let escorted = state.units.contains { $0.owner == p0 && !$0.type.isCivilian && $0.position == unit.position }
            let clear = foreign.allSatisfy { state.map.distance($0, unit.position) > 2 }
            #expect(escorted || clear, "\(unit.type) ends at \(unit.position) near \(foreign)")
        }
    }
}
