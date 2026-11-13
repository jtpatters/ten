import Foundation
import Testing
@testable import GameCore

// Combat (M1 §8): damage, rolls, effective strength, attacks, bombards and previews.

@Suite struct DamageTests {
    /// The hard-coded table is `round(30 · e^(Δ/25))` for Δ = −50…50 (M1 §8.2).
    @Test func damageTableMatchesTheFormula() {
        let c = Ruleset.standard.constants.combat
        #expect(CombatMath.maxDifference == c.maxDifference)
        #expect(CombatMath.damageTable.count == 2 * c.maxDifference + 1)
        for delta in -c.maxDifference...c.maxDifference {
            let exact = Double(c.damageBase) * exp(Double(delta) / Double(c.damageScale))
            #expect(CombatMath.baseDamage(delta) == Int(exact.rounded()), "Δ = \(delta)")
        }
        // Δ is clamped to ±50.
        #expect(CombatMath.baseDamage(-80) == CombatMath.baseDamage(-50) && CombatMath.baseDamage(-50) == 4)
        #expect(CombatMath.baseDamage(80) == CombatMath.baseDamage(50) && CombatMath.baseDamage(50) == 222)
        #expect(CombatMath.baseDamage(0) == 30)
        // damage = (base · (100 + r) + 50) / 100
        #expect(CombatMath.damage(base: 30, roll: -15) == 26)
        #expect(CombatMath.damage(base: 30, roll: 0) == 30)
        #expect(CombatMath.damage(base: 30, roll: 15) == 35)
        #expect(CombatMath.damage(base: 37, roll: -1) == 37) // 36.63 rounds up
        #expect(CombatMath.damage(base: 4, roll: -15) == 3)
    }

    /// Rolls come from `SplitMix64(seed, salts: turn, attackerKey, defenderKey, 0xC0B)`, the
    /// attacker's roll first, each uniform in −15…15 (M1 §8.2).
    @Test func rollsComeFromTheSaltedCombatStream() {
        var state = makeWarState(seed: 99)
        state.turn = 7
        let attacker: UInt64 = 12, city: UInt64 = 1 << 32 | 3
        var rng = SplitMix64(seed: 99, salts: 7, attacker, city, 0xC0B)
        let first = rng.nextInt(in: -15...15)
        let second = rng.nextInt(in: -15...15)
        let rolls = state.combatRolls(attacker: attacker, defender: city)
        #expect(rolls.attack == first && rolls.retaliation == second)

        // Over many fights every roll lies in −15…15 and both ends occur; the stream depends on
        // the turn and on both keys.
        var seen = Set<Int>()
        var changedWithTurn = 0
        for key in UInt64(1)...400 {
            let r = state.combatRolls(attacker: key, defender: key + 1000)
            seen.insert(r.attack)
            seen.insert(r.retaliation)
            var later = state
            later.turn = 8
            if later.combatRolls(attacker: key, defender: key + 1000) != r { changedWithTurn += 1 }
        }
        #expect(seen == Set(-15...15))
        #expect(changedWithTurn > 350)
        #expect(state.combatRolls(attacker: 5, defender: 6) != state.combatRolls(attacker: 6, defender: 5)
            || state.combatRolls(attacker: 5, defender: 7) != state.combatRolls(attacker: 7, defender: 5))
    }
}

@Suite struct StrengthTests {
    /// The preview of player 0's unit `attacker` on `target` from its tile.
    func preview(_ state: GameState, _ attacker: UnitID, _ target: HexCoord) throws -> CombatPreview {
        let unit = try #require(state.unit(attacker))
        return try #require(state.view(for: unit.owner).combatPreview(attacker: .unit(attacker), target: target, from: unit.position))
    }

    /// Defender terrain: hills +3, forest or jungle +3, marsh −2; fortified +4 (M1 §8.1).
    @Test func defenderTerrainAndFortification() throws {
        var state = makeWarState()
        state.map[hex(4, 1)] = Tile(terrain: .grassland, elevation: .hills, feature: .forest)
        state.map[hex(4, 5)] = Tile(terrain: .grassland, feature: .marsh)
        state.map[hex(8, 5)] = Tile(terrain: .grassland, feature: .jungle)
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let b = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 5))
        let c = state.addUnit(.warrior, owner: PlayerID(0), at: hex(7, 5))
        let onHills = state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 5))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(8, 5))
        state.updateUnit(onHills) { $0.activity = .fortified }

        let p = try preview(state, a, hex(4, 1))
        #expect(p.attackerStrength == Strength(base: 20))
        #expect(p.defenderStrength.base == 20)
        #expect(p.defenderStrength.modifiers == [StrengthModifier(kind: .elevation(.hills), value: 3),
                                                 StrengthModifier(kind: .feature(.forest), value: 3),
                                                 StrengthModifier(kind: .fortified, value: 4)])
        #expect(p.defenderStrength.modifiers.map(\.name) == ["Hills", "Forest", "Fortified"])
        #expect(p.defenderStrength.total == 30)
        #expect(try preview(state, b, hex(4, 5)).defenderStrength.total == 18)
        #expect(try preview(state, c, hex(8, 5)).defenderStrength.total == 23)

        // Fortifying (not yet fortified) gives nothing.
        state.updateUnit(onHills) { $0.activity = .fortifying }
        #expect(try preview(state, a, hex(4, 1)).defenderStrength.total == 26)
    }

    /// Support: +2 per other own military unit next to the defender, max +6, against melee
    /// attacks only (M1 §8.1).
    @Test func supportCountsOnlyAgainstMelee() throws {
        var state = makeWarState()
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(2, 1))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 1))
        state.addUnit(.builder, owner: PlayerID(1), at: hex(4, 0)) // civilians do not support
        var p = try preview(state, warrior, hex(4, 1))
        #expect(p.defenderStrength.modifiers == [StrengthModifier(kind: .support, value: 2)])
        #expect(p.defenderStrength.modifiers.map(\.name) == ["Support"])

        state.addUnit(.archer, owner: PlayerID(1), at: hex(5, 0))
        state.addUnit(.scout, owner: PlayerID(1), at: hex(4, 2))
        state.addUnit(.spearman, owner: PlayerID(1), at: hex(5, 2))
        p = try preview(state, warrior, hex(4, 1))
        #expect(p.defenderStrength.modifiers == [StrengthModifier(kind: .support, value: 6)]) // 4 supporters, capped

        let ranged = try preview(state, archer, hex(4, 1))
        #expect(ranged.ranged && ranged.attackerStrength == Strength(base: 25))
        #expect(ranged.defenderStrength == Strength(base: 20))
    }

    /// Flanking: the melee attacker gets +2 per other own military unit next to the target,
    /// max +6, on units and cities (M1 §8.1).
    @Test func flankingCountsForMeleeOnUnitsAndCities() throws {
        var state = makeWarState(width: 16, height: 10)
        let attacker = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(2, 1))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        state.addUnit(.warrior, owner: PlayerID(0), at: hex(4, 0))
        state.addUnit(.settler, owner: PlayerID(0), at: hex(5, 1)) // civilians do not flank
        var p = try preview(state, attacker, hex(4, 1))
        #expect(p.attackerStrength.modifiers == [StrengthModifier(kind: .flanking, value: 2)])
        #expect(p.attackerStrength.modifiers.map(\.name) == ["Flanking"])
        state.addUnit(.scout, owner: PlayerID(0), at: hex(5, 0))
        state.addUnit(.archer, owner: PlayerID(0), at: hex(4, 2))
        state.addUnit(.spearman, owner: PlayerID(0), at: hex(5, 2))
        p = try preview(state, attacker, hex(4, 1))
        #expect(p.attackerStrength.total == 26) // 4 flankers, capped at +6
        #expect(try preview(state, archer, hex(4, 1)).attackerStrength == Strength(base: 25))

        // On a city.
        let city = addCity(&state, PlayerID(1), at: hex(10, 6))
        let besieger = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 6))
        state.addUnit(.warrior, owner: PlayerID(0), at: hex(11, 6))
        p = try preview(state, besieger, hex(10, 6))
        #expect(p.defender == .city(city))
        #expect(p.attackerStrength.modifiers == [StrengthModifier(kind: .flanking, value: 2)])
    }

    /// A melee attack across a river edge, on a unit or a city, has −5; ranged attacks do not
    /// (M1 §8.1).
    @Test func riverCrossingWeakensMeleeAttacks() throws {
        var state = makeWarState(width: 16, height: 10)
        state.map[hex(3, 1)].riverEdges = 1 << UInt8(HexDirection.east.rawValue)
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(4, 3)) // not next to the target: no flanking
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        let p = try preview(state, warrior, hex(4, 1))
        #expect(p.attackerStrength.modifiers == [StrengthModifier(kind: .river, value: -5)])
        #expect(p.attackerStrength.modifiers.map(\.name) == ["River crossing"])
        #expect(try preview(state, archer, hex(4, 1)).attackerStrength.modifiers.isEmpty)

        // The edge counts from either side's record, and on cities.
        addCity(&state, PlayerID(1), at: hex(10, 6))
        state.map[hex(10, 6)].riverEdges = 1 << UInt8(HexDirection.west.rawValue)
        let besieger = state.addUnit(.warrior, owner: PlayerID(0), at: hex(9, 6))
        #expect(try preview(state, besieger, hex(10, 6)).attackerStrength.modifiers == [StrengthModifier(kind: .river, value: -5)])
    }

    /// Wounded units lose 1 per 10 HP missing, attacking and defending (M1 §8.1).
    @Test func woundsWeakenBothSides() throws {
        var state = makeWarState()
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let d = state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        state.updateUnit(a) { $0.hp = 75 }
        state.updateUnit(d) { $0.hp = 41 }
        let p = try preview(state, a, hex(4, 1))
        #expect(p.attackerStrength.modifiers == [StrengthModifier(kind: .wounded, value: -2)])
        #expect(p.defenderStrength.modifiers == [StrengthModifier(kind: .wounded, value: -5)])
        #expect(p.defenderStrength.modifiers.map(\.name) == ["Wounded"])
    }

    /// Class bonuses come from the rules data and count attacking and defending.
    @Test func classBonusesComeFromTheRules() throws {
        var json = try standardRulesJSON()
        edit(&json, "units", 3, "classBonuses", [["against": "recon", "strength": 7]]) // warriors vs recon
        let rules = try loadRules(json)
        var state = makeWarState(rules: rules)
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let scout = state.addUnit(.scout, owner: PlayerID(1), at: hex(4, 1))
        let p = try preview(state, warrior, hex(4, 1))
        #expect(p.attackerStrength.modifiers == [StrengthModifier(kind: .classBonus(.recon), value: 7)])
        #expect(p.attackerStrength.modifiers.map(\.name) == ["vs Recon"])

        try apply(.endTurn, &state)
        let back = try preview(state, scout, hex(3, 1))
        #expect(back.defenderStrength.modifiers == [StrengthModifier(kind: .classBonus(.recon), value: 7)])
        // The standard Spearman's bonus is against cavalry, which nothing in M1 is.
        #expect(Ruleset.standard.unit(.spearman).classBonuses.map(\.against) == [.cavalry, .heavyCavalry])
    }

    /// City Strength = 14 + 2·population, +5 while wall HP > 0, +3 on hills, +4 with a
    /// garrison (M1 §5).
    @Test func cityStrength() throws {
        var state = makeWarState(width: 16, height: 10)
        state.map[hex(6, 3)] = Tile(terrain: .grassland, elevation: .hills)
        let city = addCity(&state, PlayerID(1), at: hex(6, 3))
        updateCity(&state, city) { c in
            c.population = 3
            c.buildings = ["palace", "walls"]
            c.wallHP = 100
        }
        let attacker = state.addUnit(.warrior, owner: PlayerID(0), at: hex(5, 3))
        var p = try preview(state, attacker, hex(6, 3))
        #expect(p.defenderStrength.base == 14)
        #expect(p.defenderStrength.modifiers.map(\.name) == ["Population", "Walls", "Hills"])
        #expect(p.defenderStrength.total == 28)

        state.addUnit(.warrior, owner: PlayerID(1), at: hex(6, 3))
        p = try preview(state, attacker, hex(6, 3))
        #expect(p.defenderStrength.modifiers.last == StrengthModifier(kind: .garrison, value: 4))
        #expect(p.defenderStrength.total == 32)

        // Walls at 0 wall HP still exist but add nothing.
        updateCity(&state, city) { $0.wallHP = 0 }
        p = try preview(state, attacker, hex(6, 3))
        #expect(p.defenderStrength.total == 27)
        #expect(!p.defenderStrength.modifiers.contains { $0.kind == .walls })
    }
}

@Suite struct AttackTests {
    /// Melee: both sides take damage from the table and the rolls; the attacker spends its
    /// moves, clears its activity and gains 5 XP, a surviving defender 3 (M1 §8.3, §7.6).
    @Test func meleeDamagesBothSides() throws {
        var state = makeWarState()
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let d = state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        state.updateUnit(a) { $0.activity = .fortified }
        let rolls = state.combatRolls(attacker: UInt64(a.rawValue), defender: UInt64(d.rawValue))
        let dealt = CombatMath.damage(base: 30, roll: rolls.attack)
        let taken = CombatMath.damage(base: 30, roll: rolls.retaliation)
        let records = try apply(.attack(unit: a, target: hex(4, 1)), &state)
        #expect(events(records) == [.combat(attacker: .unit(a), defender: .unit(d), from: hex(3, 1), to: hex(4, 1),
                                            ranged: false, dealt: dealt, taken: taken)])
        #expect(records[0].audience == 0b11)
        let attacker = try #require(state.unit(a)), defender = try #require(state.unit(d))
        #expect(defender.hp == 100 - dealt && attacker.hp == 100 - taken)
        #expect(attacker.position == hex(3, 1) && attacker.movesLeft == 0 && attacker.activity == .none)
        #expect(attacker.xp == 5 && defender.xp == 3)
        #expect(throws: CommandError.rejected(reason: "no moves left")) { try apply(.attack(unit: a, target: hex(4, 1)), &state) }
        expectSound(state)
    }

    /// A melee winner survives with at least 1 HP and moves in, capturing civilians there
    /// (M1 §8.3).
    @Test func meleeWinnerSurvivesAndAdvances() throws {
        var state = makeWarState()
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let d = state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        let settler = state.addUnit(.settler, owner: PlayerID(1), at: hex(4, 1))
        state.updateUnit(a) { $0.hp = 5 }
        state.updateUnit(d) { $0.hp = 10 }
        let records = try apply(.attack(unit: a, target: hex(4, 1)), &state)
        let captured = UnitID(state.units.map(\.id.rawValue).max()!)
        #expect(events(records) == [
            .combat(attacker: .unit(a), defender: .unit(d), from: hex(3, 1), to: hex(4, 1), ranged: false, dealt: 10, taken: 4),
            .unitKilled(unit: d, type: .warrior, owner: PlayerID(1), at: hex(4, 1)),
            .unitMoved(unit: a, from: hex(3, 1), path: [hex(4, 1)]),
            .unitCaptured(old: settler, new: captured, type: .builder, from: PlayerID(1), to: PlayerID(0), at: hex(4, 1)),
            // A kill by a melee unit is Archery's Insight (M2 §6.2).
            .insightGained(player: PlayerID(0), tech: "archery", credit: 18),
        ])
        #expect(state.unit(d) == nil && state.unit(settler) == nil)
        let winner = try #require(state.unit(a))
        #expect(winner.hp == 1 && winner.position == hex(4, 1) && winner.movesLeft == 0)
        let builder = try #require(state.unit(captured))
        #expect(builder.owner == PlayerID(0) && builder.type == .builder && builder.charges == 2 && builder.movesLeft == 0)
        expectSound(state)
    }

    /// A melee attacker brought to 0 HP by the retaliation dies (M1 §8.3).
    @Test func meleeAttackerCanDie() throws {
        var state = makeWarState()
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let d = state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        state.updateUnit(a) { $0.hp = 10 }
        // Δ = (20 − 9) − 20 = −9.
        let rolls = state.combatRolls(attacker: UInt64(a.rawValue), defender: UInt64(d.rawValue))
        let dealt = CombatMath.damage(base: CombatMath.baseDamage(-9), roll: rolls.attack)
        let records = try apply(.attack(unit: a, target: hex(4, 1)), &state)
        #expect(events(records) == [
            .combat(attacker: .unit(a), defender: .unit(d), from: hex(3, 1), to: hex(4, 1), ranged: false, dealt: dealt, taken: 10),
            .unitKilled(unit: a, type: .warrior, owner: PlayerID(0), at: hex(3, 1)),
        ])
        #expect(state.unit(a) == nil && state.unit(d)!.hp == 100 - dealt)
        expectSound(state)
    }

    /// Ranged: the defender takes damage, the attacker none and stays put; +3 XP (M1 §8.3).
    @Test func rangedAttacksGetNoRetaliation() throws {
        var state = makeWarState()
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(2, 1))
        let d = state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        let rolls = state.combatRolls(attacker: UInt64(archer.rawValue), defender: UInt64(d.rawValue))
        let dealt = CombatMath.damage(base: CombatMath.baseDamage(5), roll: rolls.attack)
        let records = try apply(.attack(unit: archer, target: hex(4, 1)), &state)
        #expect(events(records) == [.combat(attacker: .unit(archer), defender: .unit(d), from: hex(2, 1), to: hex(4, 1),
                                            ranged: true, dealt: dealt, taken: 0)])
        let unit = try #require(state.unit(archer))
        #expect(unit.hp == 100 && unit.position == hex(2, 1) && unit.movesLeft == 0 && unit.xp == 3)
        #expect(state.unit(d)!.hp == 100 - dealt && state.unit(d)!.xp == 3)

        // A ranged kill does not move the archer.
        try nextTurn(&state)
        state.updateUnit(d) { $0.hp = 1 }
        try apply(.attack(unit: archer, target: hex(4, 1)), &state)
        #expect(state.unit(d) == nil && state.unit(archer)!.position == hex(2, 1))
        expectSound(state)
    }

    /// What can attack what, and from where (M1 §7, §8.3).
    @Test func attackValidation() throws {
        var state = makeWarState(width: 16, height: 10, players: 3)
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(2, 1))
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(1, 3))
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(9, 6))
        let settler = state.addUnit(.settler, owner: PlayerID(0), at: hex(3, 1))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        state.addUnit(.builder, owner: PlayerID(1), at: hex(2, 2))
        let city = addCity(&state, PlayerID(1), at: hex(10, 6))
        state.addUnit(.warrior, owner: PlayerID(2), at: hex(4, 3))
        updateRelationsMet(&state)

        func reason(_ command: Command) -> CommandError? {
            var copy = state
            do { try apply(command, &copy) } catch { return error as? CommandError }
            return nil
        }
        #expect(reason(.attack(unit: warrior, target: hex(4, 1))) == .rejected(reason: "target not adjacent"))
        #expect(reason(.attack(unit: archer, target: hex(4, 1))) == .rejected(reason: "target out of range"))
        #expect(reason(.attack(unit: warrior, target: hex(2, 2))) == .rejected(reason: "civilians cannot be attacked"))
        #expect(reason(.attack(unit: archer, target: hex(2, 2))) == .rejected(reason: "civilians cannot be attacked"))
        #expect(reason(.attack(unit: warrior, target: hex(1, 1))) == .rejected(reason: "no enemy there"))
        #expect(reason(.attack(unit: warrior, target: hex(3, 1))) == .rejected(reason: "no enemy there")) // own unit
        #expect(reason(.attack(unit: archer, target: hex(4, 3))) == .rejected(reason: "not at war with P2"))
        #expect(reason(.attack(unit: settler, target: hex(4, 1))) == .rejected(reason: "civilians cannot attack"))
        #expect(reason(.attack(unit: scout, target: hex(10, 6))) == .rejected(reason: "Scouts cannot attack cities"))
        #expect(reason(.attack(unit: UnitID(999), target: hex(4, 1))) == .unknownUnit(UnitID(999)))
        #expect(reason(.cityAttack(city: city, target: hex(9, 6))) == .notYourCity(city))
        #expect(state.view(for: PlayerID(0)).attackOptions(for: scout).isEmpty) // recon: no city targets
    }

    /// A melee garrison that kills its target stays in the city (M1 §5).
    @Test func garrisonStaysInItsCity() throws {
        var state = makeWarState()
        addCity(&state, PlayerID(0), at: hex(3, 1))
        let garrison = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let d = state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        state.updateUnit(d) { $0.hp = 5 }
        let records = try apply(.attack(unit: garrison, target: hex(4, 1)), &state)
        #expect(state.unit(d) == nil && state.unit(garrison)!.position == hex(3, 1))
        #expect(!events(records).contains { if case .unitMoved = $0 { true } else { false } })
        expectSound(state)
    }

    /// Cities lose wall HP first, then HP, never below 0; melee attackers on cities take
    /// retaliation; reaching 0 HP is not a capture (M1 §5, §8.3).
    @Test func citiesTakeDamageOnWallsFirst() throws {
        var state = makeWarState(width: 16, height: 10)
        let city = addCity(&state, PlayerID(1), at: hex(6, 3))
        updateCity(&state, city) { c in
            c.buildings = ["palace", "walls"]
            c.wallHP = 100
        }
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(5, 3))
        let key = UInt64(1) << 32 | UInt64(city.rawValue)
        // City Strength 14 + 2 + 5 = 21 against 20: Δ = −1.
        var rolls = state.combatRolls(attacker: UInt64(a.rawValue), defender: key)
        let dealt = CombatMath.damage(base: CombatMath.baseDamage(-1), roll: rolls.attack)
        let taken = CombatMath.damage(base: CombatMath.baseDamage(1), roll: rolls.retaliation)
        var records = try apply(.attack(unit: a, target: hex(6, 3)), &state)
        // A city that keeps its walls standing is Castles' Insight (M2 §6.2).
        #expect(events(records) == [.combat(attacker: .unit(a), defender: .city(city), from: hex(5, 3), to: hex(6, 3),
                                            ranged: false, dealt: dealt, taken: taken),
                                    .insightGained(player: PlayerID(1), tech: "castles", credit: 92)])
        #expect(state.city(city)!.wallHP == 100 - dealt && state.city(city)!.hp == 200)
        #expect(state.city(city)!.lastAttackedPhase == state.phaseCount)
        #expect(state.unit(a)!.hp == 100 - taken)

        // The overflow goes to HP.
        try nextTurn(&state)
        updateCity(&state, city) { $0.wallHP = 10 }
        state.updateUnit(a) { $0.hp = 100 }
        rolls = state.combatRolls(attacker: UInt64(a.rawValue), defender: key)
        let second = CombatMath.damage(base: CombatMath.baseDamage(-1), roll: rolls.attack)
        records = try apply(.attack(unit: a, target: hex(6, 3)), &state)
        #expect(combatEvent(records)?.dealt == second)
        #expect(state.city(city)!.wallHP == 0 && state.city(city)!.hp == 200 - (second - 10))

        // HP stops at 0, and the city stays the defender's.
        try nextTurn(&state)
        updateCity(&state, city) { $0.hp = 5 }
        records = try apply(.attack(unit: a, target: hex(6, 3)), &state)
        #expect(combatEvent(records)?.dealt == 5)
        #expect(state.city(city)!.hp == 0 && state.city(city)!.owner == PlayerID(1))
        #expect(state.unit(a)!.position == hex(5, 3))
        expectSound(state)
    }

    /// A melee attacker on a city can die even when the city reaches 0 HP.
    @Test func cityRetaliationCanKill() throws {
        var state = makeWarState(width: 16, height: 10)
        let city = addCity(&state, PlayerID(1), at: hex(6, 3))
        updateCity(&state, city) { $0.hp = 1 }
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(5, 3))
        state.updateUnit(a) { $0.hp = 10 }
        let preview = try #require(state.view(for: PlayerID(0)).combatPreview(attacker: .unit(a), target: hex(6, 3), from: hex(5, 3)))
        #expect(preview.killPairs == 961 && preview.deathPairs == 961)
        let records = try apply(.attack(unit: a, target: hex(6, 3)), &state)
        #expect(combatEvent(records)?.dealt == 1 && combatEvent(records)?.taken == 10)
        #expect(events(records).last == .unitKilled(unit: a, type: .warrior, owner: PlayerID(0), at: hex(5, 3)))
        #expect(state.city(city)!.hp == 0 && state.unit(a) == nil)
    }

    /// A city bombards once per phase: a ranged attack with City Strength at distance ≤ 2
    /// (M1 §5).
    @Test func citiesBombardOncePerPhase() throws {
        var state = makeWarState(width: 16, height: 10)
        let city = addCity(&state, PlayerID(0), at: hex(3, 3))
        let d = state.addUnit(.warrior, owner: PlayerID(1), at: hex(5, 3))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(7, 3)) // out of range (and out of sight)
        let view = state.view(for: PlayerID(0))
        #expect(view.cityAttackOptions(for: city) == [AttackOption(target: hex(5, 3), defender: .unit(d), from: hex(3, 3), moveCost: 0)])
        // City Strength 16 against 20: Δ = −4.
        let rolls = state.combatRolls(attacker: UInt64(1) << 32 | UInt64(city.rawValue), defender: UInt64(d.rawValue))
        let dealt = CombatMath.damage(base: CombatMath.baseDamage(-4), roll: rolls.attack)
        let preview = try #require(view.combatPreview(attacker: .city(city), target: hex(5, 3), from: hex(3, 3)))
        #expect(preview.ranged && preview.attackerStrength.total == 16 && preview.damageTaken == 0...0)
        let records = try apply(.cityAttack(city: city, target: hex(5, 3)), &state)
        #expect(events(records) == [.combat(attacker: .city(city), defender: .unit(d), from: hex(3, 3), to: hex(5, 3),
                                            ranged: true, dealt: dealt, taken: 0)])
        #expect(state.unit(d)!.hp == 100 - dealt && state.unit(d)!.xp == 3)
        #expect(state.city(city)!.bombarded)
        #expect(state.view(for: PlayerID(0)).cityAttackOptions(for: city).isEmpty)
        #expect(throws: CommandError.rejected(reason: "already bombarded this turn")) {
            try apply(.cityAttack(city: city, target: hex(5, 3)), &state)
        }
        try nextTurn(&state)
        #expect(!state.city(city)!.bombarded)
        #expect(throws: CommandError.rejected(reason: "no enemy there")) { try apply(.cityAttack(city: city, target: hex(6, 3)), &state) }
        // A unit seen by someone else, beyond the range.
        state.addUnit(.scout, owner: PlayerID(0), at: hex(6, 5))
        #expect(throws: CommandError.rejected(reason: "target out of range")) { try apply(.cityAttack(city: city, target: hex(7, 3)), &state) }
        try apply(.cityAttack(city: city, target: hex(5, 3)), &state)
        expectSound(state)
    }

    /// Nothing attacks at peace (M1 §9).
    @Test func noAttacksAtPeace() throws {
        var state = makeTestState(map: openMap())
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let city = addCity(&state, PlayerID(0), at: hex(3, 3))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        let theirs = addCity(&state, PlayerID(1), at: hex(8, 3))
        #expect(state.hasMet(PlayerID(0), PlayerID(1)))
        #expect(throws: CommandError.rejected(reason: "not at war with P1")) { try apply(.attack(unit: warrior, target: hex(4, 1)), &state) }
        #expect(throws: CommandError.rejected(reason: "not at war with P1")) { try apply(.cityAttack(city: city, target: hex(4, 1)), &state) }
        let view = state.view(for: PlayerID(0))
        #expect(view.attackOptions(for: warrior).isEmpty && view.cityAttackOptions(for: city).isEmpty)
        #expect(view.combatPreview(attacker: .unit(warrior), target: hex(4, 1), from: hex(3, 1)) == nil)
        #expect(view.dangerMap().allSatisfy { $0 == 0 })
        _ = theirs
    }
}

/// Marks every pair of players as met (tests that need a third player's name in a reason).
func updateRelationsMet(_ state: inout GameState) {
    for i in state.players.indices {
        for j in state.players.indices where j > i {
            state.updateRelation(PlayerID(i), PlayerID(j)) { $0.met = true }
        }
    }
}

@Suite struct PreviewTests {
    /// Exact kill and death chances over the 31 × 31 roll pairs (M1 §8.4).
    @Test func chancesAreCountedOverEveryRollPair() throws {
        var state = makeWarState()
        let a = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 1))
        let d = state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 1))
        func preview() throws -> CombatPreview {
            try #require(state.view(for: PlayerID(0)).combatPreview(attacker: .unit(a), target: hex(4, 1), from: hex(3, 1)))
        }
        // Even fight at full HP: 26–35 damage each way, nobody dies.
        var p = try preview()
        #expect(p.damageDealt == 26...35 && p.damageTaken == 26...35 && p.meanDealt == 30 && p.meanTaken == 30)
        #expect(p.rollPairs == 961 && p.killPairs == 0 && p.deathPairs == 0)
        #expect(p.killChancePercent == 0 && !p.capturesCity && !p.capturesCivilians)

        // Both at 30 HP (−7 each, still Δ = 0): a roll ≥ −1 does 30 (17 of 31 rolls).
        state.updateUnit(a) { $0.hp = 30 }
        state.updateUnit(d) { $0.hp = 30 }
        p = try preview()
        #expect(p.killPairs == 17 * 31)
        #expect(p.deathPairs == 14 * 17) // the attacker dies only when it does not kill
        #expect(p.killChancePercent == 55 && p.deathChancePercent == 25)
        #expect(p.killChance(atLeast: 54) && !p.killChance(atLeast: 55)) // 54.8 %
        #expect(p.deathChance(atLeast: 24) && !p.deathChance(atLeast: 25))

        // A defender with a civilian: captured if the attacker wins and moves in.
        state.addUnit(.builder, owner: PlayerID(1), at: hex(4, 1))
        #expect(try preview().capturesCivilians)
    }

    /// For many random fights, the preview's strengths predict the actual outcome for the
    /// actual rolls, and its chances are the exact counts over all roll pairs (M1 §8.4).
    @Test func previewsMatchOutcomes() throws {
        let attackers: [UnitType] = [.warrior, .spearman, .scout, .archer]
        var fights = 0, kills = 0, expectedKills = 0.0
        for seed in UInt64(1)...300 {
            var rng = SplitMix64(seed: seed, salts: 0x7E57)
            var state = makeWarState(seed: seed)
            state.turn = 1 + rng.nextInt(below: 50)
            let target = hex(5, 3)
            let againstCity = rng.nextInt(below: 4) == 0
            let type = attackers[rng.nextInt(below: attackers.count)]
            let ranged = Ruleset.standard.unit(type).isRanged
            if againstCity && type == .scout { continue }
            let elevations: [Elevation] = [.flat, .flat, .hills]
            let features: [Feature] = [.none, .none, .forest, .marsh, .jungle]
            state.map[target] = Tile(terrain: .grassland, elevation: elevations[rng.nextInt(below: 3)],
                                     feature: againstCity ? .none : features[rng.nextInt(below: features.count)])
            let from = ranged && rng.nextInt(below: 2) == 0 ? hex(3, 3) : hex(4, 3)
            if !ranged, rng.nextInt(below: 3) == 0 { state.map[from].riverEdges = 1 << UInt8(HexDirection.east.rawValue) }

            var defenderID: Combatant
            var defenderHP: Int
            if againstCity {
                let city = addCity(&state, PlayerID(1), at: target)
                let walls = rng.nextInt(below: 2) == 0
                let hp = 1 + rng.nextInt(below: 200)
                let wallHP = walls ? rng.nextInt(below: 101) : 0
                updateCity(&state, city) { c in
                    c.population = 1 + rng.nextInt(below: 8)
                    if walls { c.buildings = ["palace", "walls"] }
                    c.wallHP = wallHP
                    c.hp = hp
                }
                if rng.nextInt(below: 2) == 0 { state.addUnit(.warrior, owner: PlayerID(1), at: target) }
                defenderID = .city(city)
                defenderHP = hp + wallHP
            } else {
                let d = state.addUnit(attackers[rng.nextInt(below: attackers.count)], owner: PlayerID(1), at: target)
                let hp = 1 + rng.nextInt(below: 100)
                let activity: UnitActivity = rng.nextInt(below: 3) == 0 ? .fortified : .none
                state.updateUnit(d) { u in
                    u.hp = hp
                    u.activity = activity
                }
                if rng.nextInt(below: 3) == 0 { state.addUnit(.builder, owner: PlayerID(1), at: target) }
                defenderID = .unit(d)
                defenderHP = hp
            }
            // Other units around the target: supporters (player 1) and flankers (player 0).
            for n in [hex(6, 3), hex(5, 2), hex(6, 2), hex(5, 4), hex(6, 4)] {
                switch rng.nextInt(below: 3) {
                case 0: state.addUnit(.warrior, owner: PlayerID(0), at: n)
                case 1: state.addUnit(.spearman, owner: PlayerID(1), at: n)
                default: break
                }
            }
            let a = state.addUnit(type, owner: PlayerID(0), at: from)
            let attackerHP = 1 + rng.nextInt(below: 100)
            state.updateUnit(a) { $0.hp = attackerHP }
            refreshKnowledge(&state)
            expectSound(state)

            let view = state.view(for: PlayerID(0))
            let p = try #require(view.combatPreview(attacker: .unit(a), target: target, from: from), "seed \(seed)")
            #expect(p.defender == defenderID && p.ranged == ranged)
            let delta = p.attackerStrength.total - p.defenderStrength.total
            let base = CombatMath.baseDamage(delta), baseTaken = CombatMath.baseDamage(-delta)
            #expect(p.damageDealt == CombatMath.damage(base: base, roll: -15)...CombatMath.damage(base: base, roll: 15))
            #expect(p.damageTaken == (ranged ? 0...0 : CombatMath.damage(base: baseTaken, roll: -15)...CombatMath.damage(base: baseTaken, roll: 15)))

            // The exact counts, recomputed.
            var killPairs = 0, deathPairs = 0
            for r1 in -15...15 {
                let kill = CombatMath.damage(base: base, roll: r1) >= defenderHP
                for r2 in -15...15 {
                    if kill { killPairs += 1 }
                    if !ranged, CombatMath.damage(base: baseTaken, roll: r2) >= attackerHP, !kill || againstCity { deathPairs += 1 }
                }
            }
            #expect(p.killPairs == killPairs && p.deathPairs == deathPairs && p.rollPairs == 961, "seed \(seed)")

            // The outcome for the actual rolls.
            let defenderKey: UInt64
            switch defenderID {
            case let .unit(id): defenderKey = UInt64(id.rawValue)
            case let .city(id): defenderKey = 1 << 32 | UInt64(id.rawValue)
            }
            let rolls = state.combatRolls(attacker: UInt64(a.rawValue), defender: defenderKey)
            let damage = CombatMath.damage(base: base, roll: rolls.attack)
            let retaliation = ranged ? 0 : CombatMath.damage(base: baseTaken, roll: rolls.retaliation)
            let killed = damage >= defenderHP
            let unitKilled = killed && !againstCity
            let attackerAfter = unitKilled ? max(1, attackerHP - retaliation) : attackerHP - retaliation
            let records = try apply(.attack(unit: a, target: target), &state)
            let event = try #require(combatEvent(records), "seed \(seed)")
            #expect(event.dealt == min(damage, defenderHP) && event.taken == attackerHP - max(0, attackerAfter), "seed \(seed)")
            switch defenderID {
            case let .unit(id): #expect((state.unit(id) == nil) == killed, "seed \(seed)")
            case let .city(id): #expect((state.city(id)!.hp == 0) == killed, "seed \(seed)")
            }
            #expect((state.unit(a) == nil) == (attackerAfter <= 0), "seed \(seed)")
            if let unit = state.unit(a) {
                #expect(unit.hp == attackerAfter)
                #expect(unit.position == (unitKilled && !ranged ? target : from), "seed \(seed)")
            }
            let capturedCivilians = records.contains { if case .unitCaptured = $0.event { true } else { false } }
            #expect(capturedCivilians == (p.capturesCivilians && unitKilled && !ranged), "seed \(seed)")
            expectSound(state)

            fights += 1
            if killed { kills += 1 }
            expectedKills += Double(p.killPairs) / Double(p.rollPairs)
        }
        // The kill chances add up to about the kills seen (4 standard deviations at most).
        #expect(fights > 250)
        #expect(abs(Double(kills) - expectedKills) < 4 * sqrt(Double(fights) / 4), "\(kills) kills, \(expectedKills) expected")
    }
}
