import Foundation
import Testing
@testable import GameCore

// Fog leaks (core-3 audit of M1 §8.6, §11, §12.5): two worlds that differ only in what player 0
// cannot see must look exactly the same to player 0 — every PlayerView query, every command's
// result or refusal, and every event record it receives. Scores and `isAlive` are public by
// M1 §11 ("public rules and scores"), so the pairs keep them equal.

/// Everything player `player` can learn from its view, as labelled descriptions.
func observations(of state: GameState, player: PlayerID = PlayerID(0), destinations: [HexCoord] = [],
                  unitIDs: ClosedRange<Int> = 0...40, cityIDs: ClosedRange<Int> = 0...12) -> [(String, String)] {
    let view = state.view(for: player)
    var out: [(String, String)] = []
    func note(_ label: String, _ value: Any) { out.append((label, String(describing: value))) }

    note("phase", [view.turn, view.phaseCount, view.currentPlayer.rawValue])
    note("me", view.me)
    note("visible units", view.visibleUnits)
    note("visible foreign units", view.visibleForeignUnits)
    note("known cities", view.knownCities)
    note("sightings", view.sightings)
    note("territory", view.knownTerritory)
    note("improvements", view.knownImprovements)
    note("income", view.income())
    note("research", view.researchOptions())
    note("danger", view.dangerMap())
    note("proposals", view.peaceProposals)
    note("tribal villages", [view.knownTribalVillages.map(Int.init), [view.tribalVillageGiftsReceived]])
    for other in 0..<state.players.count {
        let p = PlayerID(other)
        note("relation \(other)", String(describing: view.relation(with: p)))
        note("war problem \(other)", String(describing: view.warProblem(on: p)))
        note("peace problem \(other)", String(describing: view.peaceProblem(to: p)))
        note("sightings of \(other)", view.sightings(of: p))
    }
    for t in 0..<view.tileCount {
        let h = view.coord(at: t)
        note("tile \(h.offset)", [String(describing: view.tile(at: h)), String(describing: view.tileYields(at: h)),
                                  String(describing: view.knownCity(at: h)), "\(view.canFoundCity(at: h))",
                                  "\(view.settleScore(at: h))", String(describing: view.units(at: h)),
                                  "\(view.isKnownTribalVillage(h))"])
    }
    for raw in unitIDs {
        let id = UnitID(raw)
        note("unit \(raw)", String(describing: view.unit(id)))
    }
    for raw in cityIDs {
        let id = CityID(raw)
        note("city \(raw)", [String(describing: view.city(id)), String(describing: view.garrison(of: id)), "\(view.canRaze(id))"])
    }
    for unit in view.units {
        note("\(unit.id) reach", view.reachableTiles(for: unit.id))
        note("\(unit.id) field", view.movementField(for: unit.id))
        note("\(unit.id) actions", view.unitActions(for: unit.id))
        let options = view.attackOptions(for: unit.id)
        note("\(unit.id) attacks", options)
        for option in options {
            note("\(unit.id) preview \(option.target.offset)",
                 String(describing: view.combatPreview(attacker: .unit(unit.id), target: option.target, from: option.from)))
        }
        for destination in destinations {
            note("\(unit.id) path \(destination.offset)", String(describing: view.path(for: unit.id, to: destination)))
            // Previews from any tile near the destination, hidden ones included.
            for from in view.coords(within: 2, of: destination) {
                note("\(unit.id) preview \(destination.offset) from \(from.offset)",
                     String(describing: view.combatPreview(attacker: .unit(unit.id), target: destination, from: from)))
            }
        }
    }
    for city in view.cities {
        note("\(city.id) yields", String(describing: view.cityYields(city.id)))
        note("\(city.id) production", view.productionOptions(for: city.id))
        note("\(city.id) grow", String(describing: view.turnsToGrow(city.id)))
        note("\(city.id) bombard", view.cityAttackOptions(for: city.id))
        note("\(city.id) distance", view.distanceField(from: city.position))
        for destination in destinations {
            note("\(city.id) preview \(destination.offset)",
                 String(describing: view.combatPreview(attacker: .city(city.id), target: destination, from: city.position)))
        }
    }
    return out
}

/// Expects two observation lists to match label by label.
func expectSameObservations(_ a: [(String, String)], _ b: [(String, String)], _ context: String,
                            sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a.count == b.count, "\(context): \(a.count) vs \(b.count) observations", sourceLocation: sourceLocation)
    var differences = 0
    for (x, y) in zip(a, b) where x != y {
        differences += 1
        if differences <= 5 {
            Issue.record("\(context): \(x.0) differs\n  A: \(x.1.prefix(400))\n  B: \(y.0) \(y.1.prefix(400))", sourceLocation: sourceLocation)
        }
    }
    #expect(differences == 0, "\(context): \(differences) observations differ", sourceLocation: sourceLocation)
}

/// The records of a list that `player` receives.
func received(_ records: [EventRecord], by player: PlayerID = PlayerID(0)) -> [EventRecord] {
    records.filter { $0.isVisible(to: player) }
}

@Suite struct FogLeakTests {
    /// The shared world: player 0 (city at (4,6), warrior, archer, scout) at war with player 1,
    /// whose warrior at (10,6) player 0 sees and whose city at (19,6) it has never seen. Player
    /// 1's scout starts on a hidden tile that differs between the worlds (`scoutAt`). Player 2
    /// is a bystander. Returns the state and the ids that matter.
    struct World {
        var state: GameState
        var city: CityID, theirCity: CityID
        var warrior: UnitID, archer: UnitID, scout: UnitID
        var theirWarrior: UnitID, theirScout: UnitID
    }

    static func world(scoutAt: HexCoord) -> World {
        var state = makeWarState(width: 26, height: 14, players: 3)
        state.map[hex(12, 8)] = Tile(terrain: .plains, elevation: .hills, feature: .forest)
        // Mountains make (14,5) the only way into (13,5) from the east.
        state.map[hex(14, 4)] = Tile(terrain: .grassland, elevation: .mountains)
        state.map[hex(14, 6)] = Tile(terrain: .grassland, elevation: .mountains)
        let city = addCity(&state, PlayerID(0), at: hex(4, 6))
        let theirCity = addCity(&state, PlayerID(1), at: hex(19, 6))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(8, 6))
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(7, 7))
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(11, 4))
        let theirWarrior = state.addUnit(.warrior, owner: PlayerID(1), at: hex(10, 6))
        let theirScout = state.addUnit(.scout, owner: PlayerID(1), at: scoutAt)
        return World(state: state, city: city, theirCity: theirCity, warrior: warrior, archer: archer, scout: scout,
                     theirWarrior: theirWarrior, theirScout: theirScout)
    }

    /// World B's extra hidden facts: more units of player 1 (ids after every shared one), a
    /// different city, treasury, research and improvements in player 1's fog, and a tribal
    /// village player 0 has never seen (A has none at all).
    static func addHiddenFacts(_ w: inout World) {
        let theirCity = w.theirCity
        w.state.addUnit(.warrior, owner: PlayerID(1), at: hex(15, 9))
        w.state.addUnit(.archer, owner: PlayerID(1), at: hex(16, 3))
        w.state.addUnit(.builder, owner: PlayerID(1), at: hex(18, 7))
        w.state.addUnit(.spearman, owner: PlayerID(1), at: hex(19, 6)) // a garrison
        updateCity(&w.state, theirCity) { c in
            c.foodStore = 9
            c.queue = [QueueEntry(.unit(.warrior), progress: 12)]
            c.hp = 150
            c.cultureStore = 5
            c.focus = .production
        }
        w.state.map[hex(20, 6)].improvement = .farm
        w.state.players[1].gold = 412
        w.state.players[1].researching = TechID("pottery")
        w.state.players[1].researchProgress = 7
        _ = DebugTools.placeTribalVillage(at: hex(22, 4), in: &w.state)
        var fx = Effects()
        fx.touchTile(tile(w.state, hex(20, 6)))
        fx.touchAllPlayers(w.state.players.count)
        w.state.updateKnowledge(&fx)
    }

    static let destinations = [hex(10, 6), hex(15, 9), hex(16, 3), hex(19, 6), hex(14, 5), hex(12, 8)]

    /// The pair: A without, B with the hidden facts; player 1's scout on different hidden tiles.
    static func pair() throws -> (World, World) {
        let a = world(scoutAt: hex(16, 5))
        var b = world(scoutAt: hex(16, 6))
        addHiddenFacts(&b)
        for w in [a, b] {
            let visible = w.state.players[0].visible
            for h in [hex(15, 9), hex(16, 3), hex(18, 7), hex(19, 6), hex(20, 6), hex(16, 5), hex(16, 6), hex(14, 5), hex(22, 4)] {
                try #require(!visible[tile(w.state, h)], "\(h.offset) must be hidden from player 0")
            }
            try #require(visible[tile(w.state, hex(10, 6))] && visible[tile(w.state, hex(13, 5))])
            try #require(w.state.players[0].memory.city(w.theirCity) == nil)
            expectSound(w.state)
        }
        try #require(a.state.score(of: PlayerID(1)) == b.state.score(of: PlayerID(1)))
        try #require(a.state.tribalVillages == nil && b.state.holdsTribalVillage(tile(b.state, hex(22, 4))))
        return (a, b)
    }

    /// Every query player 0 can make gives the same answer in both worlds.
    @Test func queriesAreTheSameInBothWorlds() throws {
        let (a, b) = try Self.pair()
        expectSameObservations(observations(of: a.state, destinations: Self.destinations),
                               observations(of: b.state, destinations: Self.destinations), "queries")
    }

    /// Every command player 0 could give has the same result or refusal in both worlds, and
    /// leaves player 0 with the same records and the same view.
    @Test func commandsBehaveTheSameInBothWorlds() throws {
        let (a, b) = try Self.pair()
        let hiddenUnit = UnitID(a.state.nextUnitID) // exists only in B
        let commands: [Command] = [
            .attack(unit: a.archer, target: hex(10, 6)),
            .attack(unit: a.warrior, target: hex(10, 6)),
            .attack(unit: a.archer, target: hex(15, 9)),
            .attack(unit: a.warrior, target: hex(19, 6)),
            .attack(unit: a.archer, target: hex(9, 8)),
            .cityAttack(city: a.city, target: hex(15, 9)),
            .cityAttack(city: a.city, target: hex(6, 6)),
            .moveUnit(unit: a.scout, to: hex(10, 2)),
            .moveUnit(unit: a.archer, to: hex(6, 8)),
            .moveUnit(unit: hiddenUnit, to: hex(15, 8)),
            .fortify(unit: hiddenUnit),
            .disband(unit: hiddenUnit),
            .fortify(unit: a.theirScout),
            .sleep(unit: a.theirWarrior),
            .fortify(unit: a.warrior),
            .setQueue(city: a.theirCity, items: []),
            .purchase(city: a.theirCity, item: .unit(.warrior)),
            .razeCity(city: a.theirCity),
            .cityAttack(city: a.theirCity, target: hex(10, 6)),
            .setQueue(city: a.city, items: [.unit(.warrior), .unit(.settler)]),
            .purchase(city: a.city, item: .building("monument")),
            // Not `purchase(unit)`: unit ids are one global counter, so a new own unit's id
            // counts every unit created before it, hidden ones included (a known side channel,
            // reported by core-3; it needs per-player id spaces).
            .setResearch(tech: "writing"),
            .declareWar(on: PlayerID(2)),
            .proposePeace(to: PlayerID(1)),
            .respondToPeace(from: PlayerID(1), accept: true),
            .disband(unit: a.archer),
            .endTurn,
        ]
        for command in commands {
            var x = a.state, y = b.state
            let rx = Result { try GameEngine.apply(command, by: PlayerID(0), to: &x) }
            let ry = Result { try GameEngine.apply(command, by: PlayerID(0), to: &y) }
            switch (rx, ry) {
            case let (.success(ex), .success(ey)):
                #expect(received(ex) == received(ey), "\(command): records differ")
                expectSameObservations(observations(of: x, destinations: Self.destinations),
                                       observations(of: y, destinations: Self.destinations), "after \(command)")
            case let (.failure(ex), .failure(ey)):
                #expect(String(describing: ex) == String(describing: ey), "\(command): refused differently")
            default:
                Issue.record("\(command): \(rx) in A, \(ry) in B")
            }
        }
    }

    /// Player 1 plays its phase differently in its fog; its scout walks into view from
    /// different hidden tiles. Player 0 receives the same records and sees the same world.
    @Test func hiddenMovesAndPhasesLeaveNoTrace() throws {
        var (a, b) = try Self.pair()
        var recordsA: [EventRecord] = [], recordsB: [EventRecord] = []
        recordsA += try apply(.endTurn, &a.state)
        recordsB += try apply(.endTurn, &b.state)
        #expect(a.state.currentPlayer == PlayerID(1) && b.state.currentPlayer == PlayerID(1))

        // B only: player 1's hidden units wander in its fog.
        let extraWarrior = UnitID(a.state.nextUnitID)
        recordsB += try apply(.moveUnit(unit: extraWarrior, to: hex(16, 10)), &b.state)
        recordsB += try apply(.fortify(unit: UnitID(extraWarrior.rawValue + 1)), &b.state)
        recordsB += try apply(.setQueue(city: b.theirCity, items: [.unit(.scout)]), &b.state)

        // Both: the scout enters player 0's view at (13,5), from (16,5) in A and (16,6) in B.
        let moveA = try apply(.moveUnit(unit: a.theirScout, to: hex(13, 5)), &a.state)
        let moveB = try apply(.moveUnit(unit: b.theirScout, to: hex(13, 5)), &b.state)
        recordsA += moveA
        recordsB += moveB
        #expect(a.state.unit(a.theirScout)?.position == hex(13, 5) && b.state.unit(b.theirScout)?.position == hex(13, 5))
        // Player 1 gets its whole path; player 0 only the step into its view.
        #expect(moveA.contains { $0.isVisible(to: PlayerID(1)) && $0.event == .unitMoved(unit: a.theirScout, from: hex(16, 5), path: [hex(15, 5), hex(14, 5), hex(13, 5)]) })
        let seen = received(moveA).filter { if case .unitMoved = $0.event { true } else { false } }
        #expect(seen.map(\.event) == [.unitMoved(unit: a.theirScout, from: hex(14, 5), path: [hex(13, 5)])])

        recordsA += try apply(.endTurn, &a.state)
        recordsB += try apply(.endTurn, &b.state)
        #expect(received(recordsA) == received(recordsB))
        expectSameObservations(observations(of: a.state, destinations: Self.destinations),
                               observations(of: b.state, destinations: Self.destinations), "next phase")
        expectSound(a.state)
        expectSound(b.state)
    }

    /// Tribal villages (M1 §7.7): in B a second one player 0 has never seen stands on the one
    /// way into (13,5), and player 1's scout takes it on its way into player 0's view, whatever
    /// gift its bag gives (a Builder appears on the hidden tile). Player 0 receives the same
    /// records and sees the same world as in A, where there is none, through the end of the
    /// turn.
    @Test(arguments: TribalVillageGiftKind.allCases)
    func aHiddenTakeLeavesNoTrace(_ kind: TribalVillageGiftKind) throws {
        var (a, b) = try Self.pair()
        let site = hex(14, 5)
        try #require(DebugTools.placeTribalVillage(at: site, in: &b.state))
        let gift = try #require((0..<30).first { TribalVillageState.giftKind(seed: b.state.seed, player: 1, gift: $0) == kind })
        b.state.tribalVillages?.gifts[1] = gift
        try #require(!b.state.players[0].visible[tile(b.state, site)] && b.state.players[0].memory.tribalVillages == nil)
        expectSound(b.state)
        var recordsA = try apply(.endTurn, &a.state)
        var recordsB = try apply(.endTurn, &b.state)
        let goldBefore = b.state.players[1].gold, progressBefore = b.state.players[1].researchProgress

        let moveA = try apply(.moveUnit(unit: a.theirScout, to: hex(13, 5)), &a.state)
        let moveB = try apply(.moveUnit(unit: b.theirScout, to: hex(13, 5)), &b.state)
        #expect(a.state.unit(a.theirScout)?.position == hex(13, 5) && b.state.unit(b.theirScout)?.position == hex(13, 5))
        // B: taken by the scout passing through, the gift player 1's alone.
        #expect(!b.state.holdsTribalVillage(tile(b.state, site)) && b.state.tribalVillages?.gifts[1] == gift + 1)
        let taken = moveB.filter { if case .tribalVillageTaken = $0.event { true } else { false } }
        let given = moveB.filter { if case .tribalVillageGift = $0.event { true } else { false } }
        #expect(taken.map(\.event) == [.tribalVillageTaken(at: site, player: PlayerID(1), unit: b.theirScout, city: nil)])
        #expect(given.count == 1 && given.allSatisfy { $0.audience == 0b010 })
        switch kind {
        case .gold:
            #expect(b.state.players[1].gold == goldBefore + 50)
        case .science:
            #expect(b.state.players[1].researchProgress == progressBefore + 20)
        case .builder:
            #expect(b.state.units.contains { $0.type == .builder && $0.owner == PlayerID(1) && $0.position == site })
        }
        #expect(received(moveA) == received(moveB))
        recordsA += moveA
        recordsB += moveB
        expectSameObservations(observations(of: a.state, destinations: Self.destinations),
                               observations(of: b.state, destinations: Self.destinations), "after a hidden \(kind)")

        // Player 1 ends its phase, then the bystander: player 0's phase starts the same way.
        for _ in 0..<2 {
            recordsA += try apply(.endTurn, &a.state)
            recordsB += try apply(.endTurn, &b.state)
        }
        #expect(a.state.currentPlayer == PlayerID(0) && b.state.currentPlayer == PlayerID(0))
        #expect(received(recordsA) == received(recordsB))
        expectSameObservations(observations(of: a.state, destinations: Self.destinations),
                               observations(of: b.state, destinations: Self.destinations), "\(kind), next turn")
        expectSound(a.state)
        expectSound(b.state)
    }

    /// A city player 0 has never seen exists in B only: commands naming its id are refused
    /// exactly like a city id that does not exist; a hidden unit id likewise (no id probing).
    @Test func hiddenIdsAreRefusedLikeMissingOnes() throws {
        let a = Self.world(scoutAt: hex(16, 5))
        var b = a
        let extra = addCity(&b.state, PlayerID(1), at: hex(22, 10))
        let unit = b.state.addUnit(.warrior, owner: PlayerID(1), at: hex(22, 2))
        try #require(!b.state.players[0].visible[tile(b.state, hex(22, 10))] && !b.state.players[0].visible[tile(b.state, hex(22, 2))])
        let commands: [Command] = [
            .setQueue(city: extra, items: []), .purchase(city: extra, item: .unit(.warrior)),
            .setFocus(city: extra, focus: .food), .razeCity(city: extra), .cityAttack(city: extra, target: hex(10, 6)),
            .moveUnit(unit: unit, to: hex(21, 2)), .fortify(unit: unit), .disband(unit: unit),
            .attack(unit: unit, target: hex(8, 6)), .foundCity(unit: unit), .cancelOrders(unit: unit),
            .buildImprovement(unit: unit, improvement: .farm), .sleep(unit: unit), .wake(unit: unit), .skip(unit: unit),
        ]
        for command in commands {
            var x = a.state, y = b.state
            let rx = Result { try GameEngine.apply(command, by: PlayerID(0), to: &x) }
            let ry = Result { try GameEngine.apply(command, by: PlayerID(0), to: &y) }
            #expect(String(describing: rx) == String(describing: ry), "\(command)")
        }
        // Once seen, the refusal names the owner: "not yours".
        var seen = b.state
        seen.addUnit(.scout, owner: PlayerID(0), at: hex(21, 9))
        #expect(throws: CommandError.notYourCity(extra)) { try apply(.setQueue(city: extra, items: []), &seen) }
        #expect(throws: CommandError.unknownUnit(unit)) { try apply(.fortify(unit: unit), &seen) }
    }

    /// A move is announced per step (M1 §12.5): a player sees the steps that touch a tile it
    /// sees, as one record per run of such steps; the hidden middle of a path stays hidden.
    @Test func movesAreTrimmedToTheStepsAPlayerSees() throws {
        // A corridor along row 0 (mountains below); player 2's units on row 2 watch parts of it.
        var map = openMap(width: 16, height: 3)
        for col in 0..<16 { map[hex(col, 1)] = Tile(terrain: .grassland, elevation: .mountains) }
        var state = makeTestState(players: 3, map: map)
        let runner = state.addUnit(.scout, owner: PlayerID(0), at: hex(2, 0))
        state.addUnit(.scout, owner: PlayerID(2), at: hex(1, 2)) // sight 3: (0…3, 0)
        state.addUnit(.warrior, owner: PlayerID(2), at: hex(7, 2)) // sight 2: (6…8, 0)
        func sees(_ cols: [Int]) -> [Bool] { cols.map { state.players[2].visible[tile(state, hex($0, 0))] } }
        #expect(sees([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]) == [true, true, true, true, false, false, true, true, true, false])
        func moves(_ records: [EventRecord]) -> [EventRecord] {
            records.filter { if case .unitMoved = $0.event { true } else { false } }
        }

        // (2,0) → (5,0): player 2 sees the steps into (3,0) and (4,0), not the one into (5,0).
        var records = try apply(.moveUnit(unit: runner, to: hex(5, 0)), &state)
        #expect(moves(records) == [
            EventRecord(.unitMoved(unit: runner, from: hex(2, 0), path: [hex(3, 0), hex(4, 0), hex(5, 0)]), audience: 0b001),
            EventRecord(.unitMoved(unit: runner, from: hex(2, 0), path: [hex(3, 0), hex(4, 0)]), audience: 0b100),
        ])
        // (5,0) → (8,0): every step touches a seen tile, so player 2 shares the owner's record.
        try nextTurn(&state)
        records = try apply(.moveUnit(unit: runner, to: hex(8, 0)), &state)
        #expect(moves(records) == [
            EventRecord(.unitMoved(unit: runner, from: hex(5, 0), path: [hex(6, 0), hex(7, 0), hex(8, 0)]), audience: 0b101),
        ])
        // (8,0) → (11,0) with a watcher of (11…13, 0): out of sight and back, two runs.
        try nextTurn(&state)
        state.addUnit(.warrior, owner: PlayerID(2), at: hex(12, 2))
        #expect(sees([8, 9, 10, 11]) == [true, false, false, true])
        records = try apply(.moveUnit(unit: runner, to: hex(11, 0)), &state)
        #expect(moves(records) == [
            EventRecord(.unitMoved(unit: runner, from: hex(8, 0), path: [hex(9, 0), hex(10, 0), hex(11, 0)]), audience: 0b001),
            EventRecord(.unitMoved(unit: runner, from: hex(8, 0), path: [hex(9, 0)]), audience: 0b100),
            EventRecord(.unitMoved(unit: runner, from: hex(10, 0), path: [hex(11, 0)]), audience: 0b100),
        ])
        expectSound(state)
    }

    /// An upkeep disband tells nobody but the owner (M1 §12.5: upkeep events → the owner);
    /// a disband the owner orders is a tile event.
    @Test func upkeepDisbandsAreTheOwnersBusiness() throws {
        var state = makeTestState(gold: 0)
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 4))
        state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 5))
        state.addUnit(.scout, owner: PlayerID(0), at: hex(8, 5))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(10, 4)) // watches (9,4)
        try #require(state.players[1].visible[tile(state, hex(9, 4))])
        try endPhases(until: PlayerID(1), &state)
        let records = try apply(.endTurn, &state)
        let disbanded = records.filter { if case let .unitDisbanded(_, _, owner, _, upkeep) = $0.event { owner == PlayerID(0) && upkeep } else { false } }
        #expect(!disbanded.isEmpty)
        #expect(disbanded.allSatisfy { $0.audience == 0b01 })
        _ = warrior

        let mine = state.units(of: PlayerID(0)).first { $0.position == hex(9, 4) || $0.position == hex(9, 5) }
        if let mine {
            let ordered = try apply(.disband(unit: mine.id), &state)
            #expect(ordered.first?.audience == 0b11)
        }
    }
}
