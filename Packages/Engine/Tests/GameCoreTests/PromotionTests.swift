@testable import GameCore
import Testing

/// Promotions (M2 §8.3).
@Suite struct PromotionTests {
    @Test func aWarriorWithEnoughXPTakesATierOnePromotion() throws {
        var state = makeTestState()
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 3))
        #expect(state.promotionsOffered(to: state.unit(warrior)!).isEmpty)
        state.updateUnit(warrior) { u in
            u.xp = 15
            u.hp = 40
        }
        #expect(state.promotionsOffered(to: state.unit(warrior)!).map(\.id) == ["battlecry", "tortoise"])
        #expect(throws: CommandError.self) { try apply(.promote(unit: warrior, promotion: "volley"), &state) }
        let records = try apply(.promote(unit: warrior, promotion: "battlecry"), &state)
        let unit = try #require(state.unit(warrior))
        #expect(unit.promotions == ["battlecry"] && unit.hp == 90 && unit.movesLeft == 0)
        #expect(events(records).contains(.unitPromoted(unit: warrior, promotion: "battlecry", owner: PlayerID(0), at: hex(3, 3))))
        #expect(state.promotionsOffered(to: unit).isEmpty)
        state.updateUnit(warrior) { $0.xp = 45 }
        #expect(state.promotionsOffered(to: state.unit(warrior)!).map(\.id) == ["commando", "amphibious"])
    }

    @Test func pursuitAddsAMove() {
        var state = makeTestState()
        let horse = state.addUnit(.horseman, owner: PlayerID(0), at: hex(3, 3))
        state.updateUnit(horse) { $0.promotions = ["caparison", "pursuit"] }
        state.startPhase(ofUnit: horse)
        #expect(state.unit(horse)!.movesLeft == 5)
    }
}
