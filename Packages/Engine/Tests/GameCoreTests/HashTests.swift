import Foundation
import Testing
@testable import GameCore
import MapGen

// Stable hashing (M1 §12.7) and the invariants Core-2 added.

@Suite struct StableHashTests {
    /// FNV-1a 64 over the encoding: integers little-endian in their own width.
    @Test func hashesTheEncodingWithFNV1a() {
        func fnv(_ bytes: [UInt8]) -> UInt64 {
            bytes.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
        }
        #expect(StableHash.of(UInt8(7)) == fnv([7]))
        #expect(StableHash.of(1) == fnv([1, 0, 0, 0, 0, 0, 0, 0]))
        #expect(StableHash.of(Int16(-2)) == fnv([0xFE, 0xFF]))
        #expect(StableHash.of(true) == fnv([1]))
        #expect(StableHash.of("ab") == fnv([2, 0, 0, 0, 0, 0, 0, 0, 0x61, 0x62]))
        #expect(StableHash.of([UInt8(5)]) == fnv([0xF2, 0xF4, 5]))
        #expect(StableHash.of(Optional<Int>.none) == fnv([0xF5]))
    }

    /// Keys, nesting and order all count.
    @Test func structureChangesTheHash() {
        struct XY: Encodable { var x = 1, y = 2 }
        struct YX: Encodable { var y = 2, x = 1 }
        struct XZ: Encodable { var x = 1, z = 2 }
        #expect(StableHash.of(XY()) == StableHash.of(XY()))
        #expect(StableHash.of(XY()) != StableHash.of(YX()))
        #expect(StableHash.of(XY()) != StableHash.of(XZ()))
        #expect(StableHash.of([[1, 2], [3]]) != StableHash.of([[1], [2, 3]]))
        #expect(StableHash.of(["ab"]) != StableHash.of(["a", "b"]))
        #expect(StableHash.of(Optional(0)) != StableHash.of(Optional<Int>.none))
        #expect(StableHash.of(Int32(1)) != StableHash.of(Int64(1)))
    }

    /// `stateHash()` covers the whole state and does not depend on JSON.
    @Test func stateHashCoversTheState() {
        var state = makeWarState()
        let city = addCity(&state, PlayerID(0), at: hex(3, 3))
        let unit = state.addUnit(.warrior, owner: PlayerID(0), at: hex(4, 4))
        let base = state.stateHash()
        let copy = state
        #expect(state.stateHash() == base && copy.stateHash() == base)
        let changes: [(String, (inout GameState) -> Void)] = [
            ("unit hp", { $0.updateUnit(unit) { $0.hp -= 1 } }),
            ("unit xp", { $0.updateUnit(unit) { $0.xp += 1 } }),
            ("zoc", { $0.updateUnit(unit) { $0.zocStopped = true } }),
            ("city attacked", { updateCity(&$0, city) { $0.lastAttackedPhase += 1 } }),
            ("city captured", { updateCity(&$0, city) { $0.capturedTurn = 1 } }),
            ("gold", { $0.players[1].gold += 1 }),
            ("relation", { $0.updateRelation(PlayerID(0), PlayerID(1)) { $0.bCooldownEnds = 4 } }),
            ("territory", { $0.tileCity[0] = 1 }),
            ("memory", { $0.players[1].memory.tileOwner[5] = 2 }),
            ("map", { $0.map[hex(7, 7)].improvement = .farm }),
            ("phase", { $0.phaseCount += 1 }),
        ]
        for (name, change) in changes {
            var copy = state
            change(&copy)
            #expect(copy.stateHash() != base, "\(name)")
        }
    }

    /// The golden game (M1 §12.7): a short fixed command log with a city, war and combat, played
    /// under `rules`. Returns the state at the end and the events.
    static func goldenGame(rules: Ruleset = .standard) throws -> (state: GameState, records: [EventRecord]) {
        var state = makeTestState(width: 16, height: 10, map: openMap(width: 16, height: 10), seed: 2024, rules: rules)
        let settler = state.addUnit(.settler, owner: PlayerID(0), at: hex(3, 4))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(5, 4))
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(4, 5))
        let theirSettler = state.addUnit(.settler, owner: PlayerID(1), at: hex(12, 4))
        let theirWarrior = state.addUnit(.warrior, owner: PlayerID(1), at: hex(8, 4))

        var records: [EventRecord] = []
        func apply(_ command: Command, _ state: inout GameState) throws {
            records += try GameEngine.apply(command, by: state.currentPlayer, to: &state)
        }

        // Turn 1.
        try apply(.foundCity(unit: settler), &state)
        let city = try #require(state.cities.first?.id)
        try apply(.setQueue(city: city, items: [.unit(.warrior), .building("monument")]), &state)
        try apply(.setResearch(tech: "pottery"), &state)
        try apply(.moveUnit(unit: warrior, to: hex(7, 4)), &state)
        try apply(.declareWar(on: PlayerID(1)), &state)
        try apply(.endTurn, &state)
        try apply(.foundCity(unit: theirSettler), &state)
        try apply(.attack(unit: theirWarrior, target: hex(7, 4)), &state)
        try apply(.endTurn, &state)
        // Turn 2.
        if state.unit(warrior) != nil, state.unit(theirWarrior) != nil {
            try apply(.attack(unit: warrior, target: state.unit(theirWarrior)!.position), &state)
        }
        try apply(.moveUnit(unit: archer, to: hex(6, 5)), &state)
        try apply(.endTurn, &state)
        try apply(.endTurn, &state)
        // Turns 3–6.
        for _ in 0..<4 {
            if let target = state.view(for: PlayerID(0)).attackOptions(for: archer).first, target.from == state.unit(archer)?.position {
                try apply(.attack(unit: archer, target: target.target), &state)
            }
            try apply(.endTurn, &state)
            try apply(.endTurn, &state)
        }
        return (state, records)
    }

    /// The hash of the golden game (M1 §12.7). Update the value on purpose when the rules or the
    /// state change.
    @Test func goldenHash() throws {
        let (state, records) = try Self.goldenGame()
        expectSound(state)
        #expect(state.turn == 7 && state.cities.count == 2)
        let combats = records.filter { if case .combat = $0.event { true } else { false } }
        #expect(combats.count >= 3)
        // ai-2: the ruleset's AI section changed (archersPerMeleePct, warGoldDeficitMultiplier,
        // buyArmyGoldPct, siegeStageRadius), which changes the rules content hash in the state hash.
        // ai-3: again (builderMaxMoveCost added); nothing else in the game changed.
        // p3 early-game: again (armyFirstCities added); nothing else in the game changed.
        // p3d core-new-city-production: city.foundingProduction (40) added, and both cities here
        // start with it stored, so their production differs from the first phase on.
        // p3f ai-prepare-posture: again (prepareSettlersRivalPct, prepareSiteRivalWeight,
        // prepareStageRadius, prepareStageUnits added); nothing else in the game changed.
        // p3f core-opening-tempo: growth.base 15 → 11 and production.waitingHeadFillPct (100)
        // added, with the young- and captured-city experiments (0, off) in the city constants.
        // p3g contracts: the rules' tribal village section added (0x04D7_4139_CB7A_64C6 before);
        // the game has none, so only the rules content hash moved (`goldenHashWithoutTribalVillages`).
        // M2 2.1a: 30 techs, eras and Insights in the rules; the state's world era (0xD11F_A96D_D6E7_E48A before).
        #expect(state.stateHash() == 0x1675_6DCB_85EA_5E09, // M2 2.1c roads (resources 0xB3AC_BDA5_E8F0_0455; 2.1b 0xF02C_AF50_2AD7_DAE3; 0x01B1_8EA9_AAFB_33AD; 2.1a 0xA75D_D47F_DE8E_AE8A)
                "golden hash: 0x\(String(state.stateHash(), radix: 16))")
    }

    /// The golden game with tribal villages (DESIGN §9, G8): Duel seed 11 with them placed,
    /// both players playing a fixed procedure to the end of turn 25. Each phase: research the
    /// first tech on offer when idle; queue a Scout and a Warrior in an idle city; then, unit by
    /// unit in id order (those on a standing order or asleep aside), found a city with a
    /// Settler where it stands, put a Builder to sleep, and send any other unit to the nearest
    /// tribal village it knows of (fewest turns, then fewest steps, then tile order), or else
    /// to a random tile it can reach, drawn from `SplitMix64(seed: 11, salts: 0x601D)`.
    static func goldenGameWithTribalVillages() throws -> (state: GameState, records: [EventRecord]) {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: 11))
        var state = GameState.newGame(seed: 11, map: generated.map, startPositions: generated.startPositions,
                                      humanPlayers: [], mapSizeName: MapSize.duel.rawValue, placeTribalVillages: true)
        var rng = SplitMix64(seed: 11, salts: 0x601D)
        var records: [EventRecord] = []
        while state.turn <= 25, state.outcome == nil {
            let me = state.currentPlayer
            func apply(_ command: Command) throws {
                records += try GameEngine.apply(command, by: me, to: &state)
            }
            var view = state.view(for: me)
            if view.me.researching == nil, let tech = view.researchOptions().first(where: { $0.available }) {
                try apply(.setResearch(tech: tech.tech))
            }
            for city in view.cities where city.queue.isEmpty {
                try apply(.setQueue(city: city.id, items: [.unit(.scout), .unit(.warrior)]))
            }
            for id in view.units.map(\.id) {
                guard let unit = state.unit(id), unit.movesLeft > 0, unit.destination == nil,
                      unit.activity == .none else { continue }
                view = state.view(for: me)
                switch unit.type {
                case .settler where view.canFoundCity(at: unit.position):
                    try apply(.foundCity(unit: id))
                    continue
                case .builder:
                    try apply(.sleep(unit: id))
                    continue
                default:
                    break
                }
                var best: (turns: Int, steps: Int, hex: HexCoord)?
                for site in view.knownTribalVillages {
                    let hex = view.coord(at: Int(site))
                    guard let path = view.path(for: id, to: hex), !path.steps.isEmpty else { continue }
                    if let b = best, (b.turns, b.steps) <= (path.turns, path.steps.count) { continue }
                    best = (path.turns, path.steps.count, hex)
                }
                if let best {
                    try apply(.moveUnit(unit: id, to: best.hex))
                } else {
                    let reach = view.reachableTiles(for: id).filter { $0 != unit.position }
                    if !reach.isEmpty { try apply(.moveUnit(unit: id, to: reach[rng.nextInt(below: reach.count)])) }
                }
            }
            if state.outcome == nil, state.currentPlayer == me { try apply(.endTurn) }
        }
        return (state, records)
    }

    /// The hash of the golden game with tribal villages (DESIGN §9): takes by units, on a
    /// command and on standing orders, and gifts of every kind; sound at the end. Update the
    /// value on purpose when the rules, the state or the procedure change (H5 re-pins it after
    /// the final tuning).
    @Test func goldenHashWithTribalVillages() throws {
        let (state, records) = try Self.goldenGameWithTribalVillages()
        expectSound(state)
        #expect(state.turn == 26 && state.outcome == nil)
        var byUnit = 0, byCity = 0, gold = 0, science = 0, builders = 0
        for record in records {
            switch record.event {
            case let .tribalVillageTaken(_, _, unit, city):
                if unit != nil { byUnit += 1 }
                if city != nil { byCity += 1 }
            case let .tribalVillageGift(_, _, gift):
                switch gift {
                case .gold: gold += 1
                case .science: science += 1
                case .builder: builders += 1
                }
            default:
                break
            }
        }
        // At pinning: 6 taken, all by units (none by a city); 3 Gold, 2 Science, 1 Builder; 2 left.
        #expect(byUnit > 0 && gold > 0 && science > 0 && builders > 0)
        #expect(byUnit + byCity == gold + science + builders && state.tribalVillages?.gifts.reduce(0, +) == byUnit + byCity)
        #expect(state.stateHash() == 0x9AE0_D946_36E8_6017, // M2 2.1c roads (resources 0xAD3C_557E_A36E_4FD9) (2.1b 0xCFA3_9056_772E_7BA6) (0x21E2_F500_2BB9_D548) (2.1a: 0x184E_3AA6_7A01_0E95) (0x1346_6444_C3B0_D609 before)
                "golden hash with tribal villages: 0x\(String(state.stateHash(), radix: 16))")
    }

    /// The kill switch (M1 §7.7): under the standard rules without their tribal village section
    /// (C0), the golden game hashes exactly as it did before the section existed (post-3f).
    @Test func goldenHashWithoutTribalVillages() throws {
        let (state, _) = try Self.goldenGame(rules: try c0Rules())
        #expect(state.rules.tribalVillages == nil && state.rules.contentHash == preTribalVillagesContentHash)
        #expect(state.stateHash() == 0x7141_182D_444C_7E53, // M2 2.1c roads (resources 0xB01D_ED97_0541_E3D5) (2.1b 0x6727_BE8E_6D58_9247) (0x3864_3AAA_2133_7AAA) (2.1a: 0x4386_124D_CC4E_C3A5) (0x04D7_4139_CB7A_64C6 before)
                "C0 golden hash: 0x\(String(state.stateHash(), radix: 16))")
    }
}

@Suite struct CombatInvariantTests {
    /// `checkInvariants` catches broken relations, capitals and wall HP.
    @Test func invariantsCatchBrokenCombatState() {
        var state = makeWarState()
        let city = addCity(&state, PlayerID(1), at: hex(6, 3))
        expectSound(state)
        func problems(_ change: (inout GameState) -> Void) -> [String] {
            var copy = state
            change(&copy)
            return copy.checkInvariants()
        }
        #expect(problems { $0.updateRelation(PlayerID(0), PlayerID(1)) { $0.met = false } }.contains { $0.contains("without having met") })
        #expect(problems { $0.updateRelation(PlayerID(0), PlayerID(1)) { $0.stance = .peace; $0.proposalFrom = PlayerID(0) } }
            .contains { $0.contains("peace proposal") })
        #expect(problems { $0.players[1].capital = nil }.contains { $0.contains("cities but no capital") })
        #expect(problems { updateCity(&$0, city) { $0.wallHP = 10 } }.contains { $0.contains("wall HP") })
        #expect(problems { updateCity(&$0, city) { $0.capturedTurn = 5 } }.contains { $0.contains("captured in turn") })
        #expect(problems { $0.updateUnit(UnitID(1)) { $0.xp = -1 } }.contains { $0.contains("xp") })
    }
}
