import Foundation
import Testing
@testable import GameCore

// Move-then-attack (M1 §16 tap rules, §8.1): a preview made before the move to the tile to strike
// from sees only the supporters in sight then; the App strikes only when the preview made after
// the move rests on the same inputs (`CombatPreview.sameInputs`), else it shows the new odds.

@Suite struct MoveThenAttackPreviewTests {
    private let me = PlayerID(0), them = PlayerID(1)

    /// A Spearman out of sight supports the target: after the move it is seen, and the defence
    /// rises by the support bonus, so the earlier preview no longer holds.
    @Test func aSupporterSeenAfterTheMoveChangesTheOdds() throws {
        var state = makeWarState()
        let a = state.addUnit(.warrior, owner: me, at: hex(2, 3))
        _ = state.addUnit(.warrior, owner: them, at: hex(4, 3))
        _ = state.addUnit(.spearman, owner: them, at: hex(5, 3))
        refreshKnowledge(&state)
        let view = state.view(for: me)
        #expect(!view.isVisible(hex(5, 3)), "the supporter is out of sight before the move")
        let option = try #require(view.attackOptions(for: a).first { $0.target == hex(4, 3) })
        #expect(option.from != hex(2, 3) && option.moveCost > 0)
        let before = try #require(view.combatPreview(attacker: .unit(a), target: option.target, from: option.from))

        try apply(.moveUnit(unit: a, to: option.from), &state)
        let after = state.view(for: me)
        // The fresh option strikes from where the unit stands now.
        let fresh = try #require(after.attackOptions(for: a).first { $0.target == option.target })
        #expect(fresh.from == option.from && fresh.moveCost == 0)
        let now = try #require(after.combatPreview(attacker: .unit(a), target: fresh.target, from: fresh.from))
        #expect(now.defenderStrength.total == before.defenderStrength.total + 2)
        #expect(!now.sameInputs(as: before))
        #expect(!before.sameInputs(as: now))
    }

    /// With nothing new in sight, the preview after the move is the same: the attack goes ahead.
    @Test func nothingNewInSightKeepsThePreview() throws {
        var state = makeWarState()
        let a = state.addUnit(.warrior, owner: me, at: hex(2, 3))
        _ = state.addUnit(.warrior, owner: them, at: hex(4, 3))
        refreshKnowledge(&state)
        let view = state.view(for: me)
        let option = try #require(view.attackOptions(for: a).first { $0.target == hex(4, 3) })
        let before = try #require(view.combatPreview(attacker: .unit(a), target: option.target, from: option.from))
        try apply(.moveUnit(unit: a, to: option.from), &state)
        let now = try #require(state.view(for: me).combatPreview(attacker: .unit(a), target: option.target, from: option.from))
        #expect(now.sameInputs(as: before))
        #expect(!now.sameInputs(as: nil))
    }
}
