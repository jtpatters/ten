import Testing
@testable import GameCore

// The tile sheet's tribal village row (phase 3g H4; design §6.3): what `tileFacts` says of a
// tribal village the player knows, from memory.

@Suite struct UITileInfoTribalVillageTests {
    let p0 = PlayerID(0)

    /// The tile sheet's tribal village: seen while its tile is in sight, remembered when not
    /// (even after it was taken out of sight), none once its tile is seen without it.
    @Test func seenAndRemembered() throws {
        var state = makeTestState()
        let scout = state.addUnit(.scout, owner: p0, at: hex(2, 2))
        let site = hex(4, 2), plain = hex(4, 1)
        #expect(DebugTools.placeTribalVillage(at: site, in: &state))
        #expect(state.view(for: p0).tileFacts(at: site)?.tribalVillage == .seen)
        #expect(state.view(for: p0).tileFacts(at: plain).map { $0.tribalVillage == nil } == true)
        // Out of sight: remembered, even once taken.
        try apply(.moveUnit(unit: scout, to: hex(0, 2)), &state)
        #expect(state.view(for: p0).tileFacts(at: site)?.tribalVillage == .remembered)
        removeTribalVillage(at: site, in: &state)
        #expect(state.view(for: p0).tileFacts(at: site)?.tribalVillage == .remembered)
        // Seen again: gone.
        try nextTurn(&state)
        try apply(.moveUnit(unit: scout, to: hex(2, 2)), &state)
        let facts = try #require(state.view(for: p0).tileFacts(at: site))
        #expect(facts.isVisible && facts.tribalVillage == nil)
        // A player who never saw the tile has no facts for it.
        #expect(state.view(for: PlayerID(1)).tileFacts(at: site) == nil)
    }
}
