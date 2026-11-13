import Foundation
import Testing
@testable import GameCore

// Diplomacy (M1 §9): war, peace proposals and their cool-downs, closed borders and eviction.

@Suite struct DiplomacyTests {
    /// War needs a met player at peace; everyone who has met either side hears of it
    /// (M1 §9, §12.5).
    @Test func declaringWar() throws {
        var state = makeTestState(width: 24, height: 12, players: 4, map: openMap(width: 24, height: 12))
        #expect(throws: CommandError.rejected(reason: "you have not met P1")) { try apply(.declareWar(on: PlayerID(1)), &state) }
        #expect(throws: CommandError.rejected(reason: "no such player")) { try apply(.declareWar(on: PlayerID(0)), &state) }
        #expect(throws: CommandError.rejected(reason: "no such player")) { try apply(.declareWar(on: PlayerID(9)), &state) }
        #expect(state.view(for: PlayerID(0)).warProblem(on: PlayerID(1)) == "you have not met P1")

        state.addUnit(.scout, owner: PlayerID(0), at: hex(21, 1)) // sees player 1's Settler at (23,0)
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(2, 10)) // seen by player 2's Settler at (0,11)
        #expect(state.hasMet(PlayerID(0), PlayerID(1)) && state.hasMet(PlayerID(1), PlayerID(2)))
        #expect(!state.hasMet(PlayerID(0), PlayerID(2)) && !state.hasMet(PlayerID(0), PlayerID(3)))
        #expect(state.view(for: PlayerID(0)).warProblem(on: PlayerID(1)) == nil)

        let records = try apply(.declareWar(on: PlayerID(1)), &state)
        #expect(events(records) == [.warDeclared(by: PlayerID(0), on: PlayerID(1))])
        #expect(records[0].audience == 0b0111) // not player 3, who met neither
        let relation = state.relation(PlayerID(0), PlayerID(1))
        #expect(relation.stance == .war && relation.since == 1 && state.isAtWar(PlayerID(1), PlayerID(0)))
        #expect(throws: CommandError.rejected(reason: "already at war with P1")) { try apply(.declareWar(on: PlayerID(1)), &state) }
        #expect(!state.isAtWar(PlayerID(0), PlayerID(2)))
        expectSound(state)
    }

    /// Peace can be proposed after 5 turns of war, once at a time; the target answers in its
    /// own phase; a declined proposal starts a 10-turn cool-down for its proposer; peace sets
    /// `since`, and war may follow only 10 turns later (M1 §9).
    @Test func peaceProposalsAndCoolDowns() throws {
        var state = makeWarState()
        #expect(throws: CommandError.rejected(reason: "peace can be proposed from turn 6")) {
            try apply(.proposePeace(to: PlayerID(1)), &state)
        }
        for _ in 0..<5 { try nextTurn(&state) }
        #expect(state.turn == 6)
        let proposed = try apply(.proposePeace(to: PlayerID(1)), &state)
        #expect(events(proposed) == [.peaceProposed(from: PlayerID(0), to: PlayerID(1))] && proposed[0].audience == 0b11)
        #expect(state.relation(PlayerID(0), PlayerID(1)).proposalFrom == PlayerID(0))
        #expect(throws: CommandError.rejected(reason: "a peace proposal is pending")) { try apply(.proposePeace(to: PlayerID(1)), &state) }
        #expect(throws: CommandError.rejected(reason: "no peace proposal from P1")) {
            try apply(.respondToPeace(from: PlayerID(1), accept: true), &state)
        }

        try endPhases(until: PlayerID(1), &state)
        #expect(state.view(for: PlayerID(1)).peaceProposals == [PlayerID(0)])
        #expect(throws: CommandError.rejected(reason: "a peace proposal is pending")) { try apply(.proposePeace(to: PlayerID(0)), &state) }
        let declined = try apply(.respondToPeace(from: PlayerID(0), accept: false), &state)
        #expect(events(declined) == [.peaceDeclined(proposer: PlayerID(0), by: PlayerID(1))] && declined[0].audience == 0b11)
        #expect(state.relation(PlayerID(0), PlayerID(1)).stance == .war)
        #expect(state.relation(PlayerID(0), PlayerID(1)).aCooldownEnds == 16)

        // The decliner's own proposals are not cooled down.
        let theirs = try apply(.proposePeace(to: PlayerID(0)), &state)
        #expect(events(theirs) == [.peaceProposed(from: PlayerID(1), to: PlayerID(0))])
        try endPhases(until: PlayerID(0), &state)
        #expect(state.turn == 7)
        #expect(throws: CommandError.rejected(reason: "a peace proposal is pending")) { try apply(.proposePeace(to: PlayerID(1)), &state) }
        let signed = try apply(.respondToPeace(from: PlayerID(1), accept: true), &state)
        #expect(events(signed) == [.peaceSigned(PlayerID(0), PlayerID(1))] && signed[0].audience == 0b11)
        let relation = state.relation(PlayerID(0), PlayerID(1))
        #expect(relation.stance == .peace && relation.since == 7 && relation.proposalFrom == nil)
        #expect(throws: CommandError.rejected(reason: "not at war with P1")) { try apply(.proposePeace(to: PlayerID(1)), &state) }
        #expect(throws: CommandError.rejected(reason: "a peace treaty holds until turn 17")) {
            try apply(.declareWar(on: PlayerID(1)), &state)
        }
        for _ in 0..<10 { try nextTurn(&state) }
        try apply(.declareWar(on: PlayerID(1)), &state)
        #expect(state.relation(PlayerID(0), PlayerID(1)).since == 17)
        expectSound(state)

        // Back at war, player 0's cool-down from turn 6 is over.
        for _ in 0..<5 { try nextTurn(&state) }
        try apply(.proposePeace(to: PlayerID(1)), &state)
    }

    /// An unanswered proposal expires at its proposer's next phase start, which starts the
    /// cool-down (M1 §3, §9).
    @Test func unansweredProposalsExpire() throws {
        var state = makeWarState()
        for _ in 0..<5 { try nextTurn(&state) }
        try apply(.proposePeace(to: PlayerID(1)), &state)
        try apply(.endTurn, &state) // player 1 ignores it
        let records = try apply(.endTurn, &state)
        #expect(state.turn == 7 && state.currentPlayer == PlayerID(0))
        let expiry = try #require(records.first { $0.event == .peaceDeclined(proposer: PlayerID(0), by: PlayerID(1)) })
        #expect(expiry.audience == 0b11)
        let relation = state.relation(PlayerID(0), PlayerID(1))
        #expect(relation.proposalFrom == nil && relation.aCooldownEnds == 17 && relation.bCooldownEnds == 0)
        #expect(throws: CommandError.rejected(reason: "peace can be proposed again from turn 17")) {
            try apply(.proposePeace(to: PlayerID(1)), &state)
        }
        #expect(state.view(for: PlayerID(0)).peaceProblem(to: PlayerID(1)) == "peace can be proposed again from turn 17")
    }

    /// At peace, military units may not enter the other's territory; civilians may (M1 §9).
    @Test func bordersAreClosedToMilitaryAtPeace() throws {
        var state = makeTestState(map: openMap())
        addCity(&state, PlayerID(1), at: hex(6, 3))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 3))
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(4, 4))
        #expect(state.hasMet(PlayerID(0), PlayerID(1)))
        #expect(throws: CommandError.noPath) { try apply(.moveUnit(unit: warrior, to: hex(5, 3)), &state) }
        #expect(!state.view(for: PlayerID(0)).reachableTiles(for: warrior).contains(hex(5, 3)))
        try apply(.moveUnit(unit: builder, to: hex(6, 4)), &state)
        #expect(state.unit(builder)!.position == hex(6, 4))

        // At war the border opens.
        setWar(&state, PlayerID(0), PlayerID(1))
        try apply(.moveUnit(unit: warrior, to: hex(5, 3)), &state)
        #expect(state.unit(warrior)!.position == hex(5, 3))
        expectSound(state)
    }

    /// Military units inside territory that closes to them (peace signed, or a border grown
    /// under them) move at their owner's next phase start to the nearest tile they may stand
    /// on outside it (ties: lower index), M1 §9.
    @Test func peaceEvictsMilitaryUnits() throws {
        var state = makeWarState()
        let city = addCity(&state, PlayerID(1), at: hex(6, 3))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(5, 3))
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(6, 4))
        for _ in 0..<5 { try nextTurn(&state) }
        try apply(.proposePeace(to: PlayerID(1)), &state)
        try endPhases(until: PlayerID(1), &state)
        try apply(.respondToPeace(from: PlayerID(0), accept: true), &state)
        #expect(state.unit(warrior)!.position == hex(5, 3)) // not yet
        let records = try apply(.endTurn, &state)
        #expect(events(records).contains(.unitMoved(unit: warrior, from: hex(5, 3), path: [hex(5, 2)])))
        #expect(state.unit(warrior)!.position == hex(5, 2))
        #expect(state.unit(builder)!.position == hex(6, 4)) // civilians stay
        expectSound(state)

        // The border grows under it.
        claimTile(&state, hex(5, 2), for: city)
        try nextTurn(&state)
        #expect(state.unit(warrior)!.position == hex(4, 1))
        expectSound(state)
    }
}
