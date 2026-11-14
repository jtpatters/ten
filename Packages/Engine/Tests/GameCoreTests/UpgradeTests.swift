@testable import GameCore
import Testing

/// Upgrades (M2 §8.2).
@Suite struct UpgradeTests {
    @Test func aWarriorUpgradesToASwordsmanInOwnTerritory() throws {
        var state = makeTestState()
        addCity(&state, PlayerID(0), at: hex(3, 3))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 3))
        #expect(state.upgradeCost(of: .warrior) == 100)
        #expect(throws: CommandError.self) { try apply(.upgrade(unit: warrior), &state) }
        state.learn("bronzeWorking", player: PlayerID(0))
        state.learn("ironWorking", player: PlayerID(0))
        state.players[0].gold = 120
        state.updateUnit(warrior) { $0.xp = 7 }
        let records = try apply(.upgrade(unit: warrior), &state)
        let unit = try #require(state.unit(warrior))
        #expect(unit.type == .swordsman && unit.xp == 7 && unit.movesLeft == 0 && state.players[0].gold == 20)
        #expect(events(records).contains(.unitUpgraded(unit: warrior, from: .warrior, to: .swordsman, owner: PlayerID(0), at: hex(3, 3))))
    }

    @Test func noUpgradeOutsideOwnTerritoryOrWithoutOne() throws {
        var state = makeTestState()
        state.learn("bronzeWorking", player: PlayerID(0))
        state.learn("ironWorking", player: PlayerID(0))
        state.players[0].gold = 500
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(6, 4))
        #expect(state.upgradeProblem(state.unit(warrior)!) == "only in your territory")
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(7, 4))
        #expect(state.upgradeCost(of: .scout) == nil && state.upgradeProblem(state.unit(scout)!) != nil)
    }
}
