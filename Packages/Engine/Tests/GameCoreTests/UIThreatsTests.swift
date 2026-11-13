import Foundation
import Testing
@testable import GameCore

// The war warnings' queries (GameCore/Queries/UIThreats.swift, M1 §16): foreign troops the player
// sees near its cities, what it remembers of another player's army, and the capital a two-player
// game is lost with.

@Suite struct UIThreatsTests {
    private let me = PlayerID(0), them = PlayerID(1)

    /// Visible foreign military units within 4 tiles count at the own city nearest to each (ties:
    /// the lower city id), at peace as at war. Scouts, civilians, units farther away and units
    /// out of sight do not count.
    @Test func troopsNearCities() {
        var state = makeTestState(map: openMap(width: 30, height: 14))
        let rome = addCity(&state, me, at: hex(5, 6))
        let antium = addCity(&state, me, at: hex(11, 6))
        // Own Scouts to see with, away from the tile that must stay hidden.
        state.addUnit(.scout, owner: me, at: hex(8, 5))
        state.addUnit(.scout, owner: me, at: hex(17, 5))
        let middle = state.addUnit(.warrior, owner: them, at: hex(8, 6)) // 3 from both cities
        let spearman = state.addUnit(.spearman, owner: them, at: hex(13, 6)) // 2 from Antium
        let second = state.addUnit(.warrior, owner: them, at: hex(9, 6)) // 2 from Antium, 4 from Rome
        state.addUnit(.scout, owner: them, at: hex(6, 6)) // recon
        state.addUnit(.builder, owner: them, at: hex(4, 6)) // civilian
        state.addUnit(.archer, owner: them, at: hex(17, 6)) // 6 from Antium
        let hidden = state.addUnit(.warrior, owner: them, at: hex(5, 10)) // 4 from Rome, unseen

        let view = state.view(for: me)
        #expect(state.map.distance(hex(8, 6), hex(5, 6)) == 3 && state.map.distance(hex(8, 6), hex(11, 6)) == 3)
        #expect(view.isVisible(hex(17, 6)) && view.isVisible(hex(8, 6)))
        #expect(view.unit(hidden) == nil && state.map.distance(hex(5, 10), hex(5, 6)) == 4)
        let expected = [TroopsNear(city: rome, units: [state.unit(middle)!]),
                        TroopsNear(city: antium, units: [state.unit(spearman)!, state.unit(second)!])]
        #expect(view.foreignMilitaryNear() == expected)

        // At war: the same units.
        setWar(&state, me, them)
        #expect(state.view(for: me).foreignMilitaryNear() == expected)
        // A smaller radius leaves the farther ones out.
        #expect(state.view(for: me).foreignMilitaryNear(radius: 2) == [TroopsNear(city: antium, units: [state.unit(spearman)!,
                                                                                                      state.unit(second)!])])
    }

    /// No own city, nothing near.
    @Test func noCityNoTroopsNear() {
        var state = makeTestState(map: openMap(width: 30, height: 14))
        state.addUnit(.warrior, owner: them, at: hex(28, 12))
        #expect(state.view(for: me).foreignMilitaryNear().isEmpty)
    }

    /// The army remembered: military sightings (not recon), still counted once out of sight;
    /// the own city nearest to any of them, how far, and when the latest was seen.
    @Test func rememberedArmy() throws {
        var state = makeTestState(map: openMap(width: 30, height: 14))
        let rome = addCity(&state, me, at: hex(5, 6))
        addCity(&state, me, at: hex(20, 6))
        let eye = state.addUnit(.scout, owner: me, at: hex(9, 5))
        state.addUnit(.warrior, owner: them, at: hex(9, 6)) // 4 from Rome
        state.addUnit(.archer, owner: them, at: hex(11, 6)) // 6 from Rome
        state.addUnit(.scout, owner: them, at: hex(10, 6)) // recon: not counted
        let seen = state.view(for: me).rememberedArmy(of: them)
        #expect(seen == RememberedArmy(owner: them, units: 2, nearestCity: rome, distance: 4, lastSeen: state.turn))

        // Out of sight, the sightings stay.
        state.removeUnit(eye)
        refreshKnowledge(&state)
        try nextTurn(&state)
        let view = state.view(for: me)
        #expect(view.visibleForeignUnits.filter { $0.owner == them && !$0.type.isCivilian }.isEmpty)
        #expect(view.rememberedArmy(of: them) == RememberedArmy(owner: them, units: 2, nearestCity: rome, distance: 4, lastSeen: 1))

        // A player never seen: nothing.
        var three = makeTestState(players: 3, map: openMap(width: 30, height: 14))
        addCity(&three, me, at: hex(5, 6))
        #expect(three.view(for: me).rememberedArmy(of: PlayerID(2))
            == RememberedArmy(owner: PlayerID(2), units: 0, nearestCity: nil, distance: nil, lastSeen: nil))
    }

    /// In a two-player game, the original capital is at stake: once the other player owns it,
    /// it has won by domination (M1 §10). Not before a city is founded, nor with more players.
    @Test func capitalAtStakeInADuel() throws {
        var state = makeWarState(width: 20, height: 10)
        #expect(state.view(for: me).capitalAtStake == nil)
        let rome = addCity(&state, me, at: hex(5, 4))
        addCity(&state, me, at: hex(5, 9))
        addCity(&state, them, at: hex(15, 4))
        #expect(state.view(for: me).capitalAtStake == rome)
        #expect(state.view(for: them).capitalAtStake != nil)

        // Their Warrior takes Rome at 0 HP: the game is lost, though another city remains.
        updateCity(&state, rome) { $0.hp = 0 }
        let warrior = state.addUnit(.warrior, owner: them, at: hex(6, 4))
        try apply(.endTurn, &state)
        try apply(.attack(unit: warrior, target: hex(5, 4)), &state)
        #expect(state.outcome == .victory(player: them, kind: .domination))
        #expect(state.view(for: me).capitalAtStake == nil)

        // Three players: who holds the third capital may be hidden, so nothing is claimed.
        var three = makeTestState(players: 3, map: openMap(width: 20, height: 10))
        addCity(&three, me, at: hex(5, 4))
        #expect(three.view(for: me).capitalAtStake == nil)
    }
}
