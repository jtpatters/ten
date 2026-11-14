@testable import GameCore
import Testing

/// Siege and walls (M2 §9.2).
@Suite struct SiegeTests {
    func walledCity(_ state: inout GameState) -> CityID {
        let city = addCity(&state, PlayerID(1), at: hex(6, 3))
        updateCity(&state, city) { c in
            c.buildings = ["palace", "walls"]
            c.wallHP = 100
        }
        return city
    }

    func preview(_ state: GameState, _ attacker: UnitID, _ target: HexCoord) throws -> CombatPreview {
        let unit = try #require(state.unit(attacker))
        return try #require(state.view(for: unit.owner).combatPreview(attacker: .unit(attacker), target: target, from: unit.position))
    }

    /// The raw damage of `attacker`'s shot at `city` with the strengths `p` previewed.
    func rawDamage(_ state: GameState, _ attacker: UnitID, _ city: CityID, _ p: CombatPreview) -> Int {
        let rolls = state.combatRolls(attacker: UInt64(attacker.rawValue), defender: UInt64(1) << 32 | UInt64(city.rawValue))
        return CombatMath.damage(base: CombatMath.baseDamage(p.attackerStrength.total - p.defenderStrength.total), roll: rolls.attack)
    }

    /// A Catapult ignores the Walls' strength and deals 150% to wall HP.
    @Test func siegeBreaksWalls() throws {
        var state = makeWarState(width: 16, height: 10)
        let city = walledCity(&state)
        let catapult = state.addUnit(.catapult, owner: PlayerID(0), at: hex(4, 3))
        let p = try preview(state, catapult, hex(6, 3))
        #expect(!p.defenderStrength.modifiers.contains { $0.kind == .walls })
        let raw = rawDamage(state, catapult, city, p)
        let records = try apply(.attack(unit: catapult, target: hex(6, 3)), &state)
        let walls = min(100, raw * 3 / 2)
        #expect(state.city(city)!.wallHP == 100 - walls)
        #expect(combatEvent(records)?.dealt == state.city(city).map { 300 - $0.wallHP - $0.hp })
        #expect(p.damageDealt.contains(combatEvent(records)!.dealt))
        expectSound(state)
    }

    /// An Archer deals 50% to wall HP; with Incendiaries 150%.
    @Test func incendiariesBurnWalls() throws {
        var state = makeWarState(width: 16, height: 10)
        let city = walledCity(&state)
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(4, 3))
        #expect(state.wallDamagePct(of: .unit(state.unit(archer)!)) == 50)
        var p = try preview(state, archer, hex(6, 3))
        #expect(p.defenderStrength.modifiers.contains { $0.kind == .walls })
        let raw = rawDamage(state, archer, city, p)
        try apply(.attack(unit: archer, target: hex(6, 3)), &state)
        #expect(state.city(city)!.wallHP == 100 - raw / 2)

        state.updateUnit(archer) { $0.promotions = ["volley", "incendiaries"] }
        #expect(state.wallDamagePct(of: .unit(state.unit(archer)!)) == 150)
        try nextTurn(&state)
        p = try preview(state, archer, hex(6, 3))
        let before = state.city(city)!.wallHP
        let second = rawDamage(state, archer, city, p)
        let records = try apply(.attack(unit: archer, target: hex(6, 3)), &state)
        let split = CombatMath.cityDamage(second, wallHP: before, wallPct: 150)
        #expect(state.city(city)!.wallHP == before - split.walls)
        #expect(p.damageDealt.contains(combatEvent(records)!.dealt))
    }

    /// Damage the walls do not absorb reaches HP at full value; no walls, no scaling.
    @Test func cityDamageSplit() {
        #expect(CombatMath.cityDamage(40, wallHP: 100, wallPct: 50) == (20, 0))
        #expect(CombatMath.cityDamage(40, wallHP: 10, wallPct: 50) == (10, 20))
        #expect(CombatMath.cityDamage(40, wallHP: 100, wallPct: 150) == (60, 0))
        #expect(CombatMath.cityDamage(40, wallHP: 30, wallPct: 150) == (30, 20))
        #expect(CombatMath.cityDamage(40, wallHP: 0, wallPct: 50) == (0, 40))
        #expect(CombatMath.cityDamage(40, wallHP: 100, wallPct: 100) == (40, 0))
    }
}
