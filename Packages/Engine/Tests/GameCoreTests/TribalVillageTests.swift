import Foundation
import MapGen
import Testing
@testable import GameCore

// Tribal villages, the core (phase 3g H1; M1 §7.7; DESIGN §3.2–§3.6): placement and its tags,
// taking, the gift bag, city claims and the phase-start order, the other paths (spawns,
// eviction, `addUnit`, `spawnUnits`), the invariants and a random stress run. The contracts
// (rules, memory, queries, events, debug tools) are in TribalVillageContractTests, the fog twins
// in FogLeakTests and the golden game with tribal villages in HashTests. The helpers here are
// private to this file.

// MARK: - Helpers

/// The gift number (0, 1 or 2) of a player's first bag that is of `kind`.
private func firstGift(_ kind: TribalVillageGiftKind, seed: UInt64, player: Int) -> Int {
    TribalVillageState.bag(seed: seed, player: player, bag: 0).firstIndex(of: kind)!
}

/// Makes `player`'s next gift one of `kind` (its place in the first bag). The game must have
/// tribal villages.
private func nextGift(_ kind: TribalVillageGiftKind, for player: PlayerID, in state: inout GameState) {
    state.tribalVillages!.gifts[player.rawValue] = firstGift(kind, seed: state.seed, player: player.rawValue)
}

/// The tribal village events of a list of records (taken, gift), with the `unitCreated` of a
/// Builder gift, in order.
private func villageEvents(_ records: [EventRecord]) -> [GameEvent] {
    var out: [GameEvent] = []
    var builders: [UnitID] = []
    for record in records {
        switch record.event {
        case .tribalVillageTaken: out.append(record.event)
        case let .tribalVillageGift(_, _, gift):
            out.append(record.event)
            if case let .builder(id) = gift { builders.append(id) }
        case let .unitCreated(id, _, _, _) where builders.contains(id): out.append(record.event)
        default: break
        }
    }
    return out
}

/// The live tribal villages of a state, as hexes in tile order.
private func liveVillages(_ state: GameState) -> [HexCoord] { DebugTools.tribalVillages(in: state) }

/// What player `player` remembers, as hexes in tile order.
private func remembered(_ state: GameState, _ player: Int) -> [HexCoord] {
    (state.players[player].memory.tribalVillages ?? []).map { state.map.coord(at: Int($0)) }
}

/// Rules whose tribal village section is changed by `change` (the section as JSON).
private func villageRules(_ change: (inout [String: Any]) -> Void) throws -> Ruleset {
    var json = try standardRulesJSON()
    var section = try #require(json["tribalVillages"] as? [String: Any])
    change(&section)
    json["tribalVillages"] = section
    return try loadRules(json)
}

// MARK: - Taking (DESIGN §3.3)

@Suite struct TribalVillageTakingTests {
    /// Moving onto one takes it: the site goes, the gift comes from the player's bag, the
    /// player forgets it, and the events follow the move's own: taken, gift (and the Builder's
    /// `unitCreated`).
    @Test func movingOntoOneTakesIt() throws {
        var state = makeTestState()
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 1))
        let site = hex(3, 1)
        #expect(DebugTools.placeTribalVillage(at: site, in: &state))
        #expect(remembered(state, 0) == [site])
        let records = try apply(.moveUnit(unit: scout, to: site), &state)
        #expect(state.unit(scout)?.position == site)
        #expect(liveVillages(state).isEmpty && state.tribalVillages?.gifts == [1, 0])
        #expect(remembered(state, 0).isEmpty && state.players[0].memory.tribalVillages == nil)
        let kinds = villageEvents(records)
        #expect(kinds.first == .tribalVillageTaken(at: site, player: PlayerID(0), unit: scout, city: nil))
        guard kinds.count >= 2, case let .tribalVillageGift(player, at, gift) = kinds[1] else {
            Issue.record("no gift: \(kinds)")
            return
        }
        #expect(player == PlayerID(0) && at == site)
        switch TribalVillageState.giftKind(seed: state.seed, player: 0, gift: 0) {
        case .gold: #expect(gift == .gold(50) && kinds.count == 2)
        case .science: #expect(gift == .science(20, toward: nil) && kinds.count == 2)
        case .builder: #expect(kinds.count == 3)
        }
        // The move's own event comes first.
        let order = records.map(\.event)
        let moved = try #require(order.firstIndex { if case .unitMoved = $0 { true } else { false } })
        let taken = try #require(order.firstIndex { if case .tribalVillageTaken = $0 { true } else { false } })
        #expect(moved < taken)
        expectSound(state)
    }

    /// Passing through takes it, and a move takes every one it enters, in path order (debug
    /// placements may break the spacing).
    @Test func passingThroughTakesThemInPathOrder() throws {
        var state = makeTestState()
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 1))
        #expect(DebugTools.placeTribalVillage(at: hex(3, 1), in: &state))
        #expect(DebugTools.placeTribalVillage(at: hex(2, 1), in: &state))
        let records = try apply(.moveUnit(unit: scout, to: hex(4, 1)), &state)
        #expect(state.unit(scout)?.position == hex(4, 1))
        let taken = villageEvents(records).compactMap { event -> HexCoord? in
            if case let .tribalVillageTaken(at, player, unit, city) = event, player == PlayerID(0), unit == scout, city == nil { return at }
            return nil
        }
        #expect(taken == [hex(2, 1), hex(3, 1)])
        #expect(liveVillages(state).isEmpty && state.tribalVillages?.gifts == [2, 0])
        expectSound(state)
    }

    /// A move cut short takes only the tiles it entered: by a hidden unit (M1 §8.6) and by a
    /// zone of control it did not expect (M1 §8.5).
    @Test func aStoppedMoveTakesOnlyTheTilesItEntered() throws {
        // A hidden foreign unit on the way (EngineTests' recipe: player 0 sees nothing).
        var state = makeTestState()
        let mover = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 0))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(2, 0))
        #expect(DebugTools.placeTribalVillage(at: hex(1, 0), in: &state))
        #expect(DebugTools.placeTribalVillage(at: hex(3, 0), in: &state))
        state.players[0].visible = TileBitSet(count: state.map.tileCount)
        let records = try apply(.moveUnit(unit: mover, to: hex(3, 0)), &state)
        #expect(state.unit(mover)?.position == hex(1, 0) && state.unit(mover)?.destination == nil)
        #expect(events(records).contains(.moveInterrupted(unit: mover, at: hex(1, 0))))
        #expect(villageEvents(records).first == .tribalVillageTaken(at: hex(1, 0), player: PlayerID(0), unit: mover, city: nil))
        #expect(liveVillages(state) == [hex(3, 0)])

        // An unexpected zone of control: the enemy Warrior at (3,2) is hidden when the move is
        // planned; the Scout stops on (2,1), next to it.
        var war = makeWarState()
        let scout = war.addUnit(.scout, owner: PlayerID(0), at: hex(0, 1))
        war.addUnit(.warrior, owner: PlayerID(1), at: hex(3, 2))
        #expect(DebugTools.placeTribalVillage(at: hex(2, 1), in: &war))
        #expect(DebugTools.placeTribalVillage(at: hex(3, 0), in: &war))
        war.players[0].visible = TileBitSet(count: war.map.tileCount)
        let stopped = try apply(.moveUnit(unit: scout, to: hex(3, 0)), &war)
        let unit = try #require(war.unit(scout))
        #expect(unit.position == hex(2, 1) && unit.zocStopped)
        #expect(villageEvents(stopped).first == .tribalVillageTaken(at: hex(2, 1), player: PlayerID(0), unit: scout, city: nil))
        #expect(liveVillages(war) == [hex(3, 0)])
    }

    /// A civilian takes one like any unit; a Builder gift then cannot share its tile and stands
    /// on the nearest free tile (ties: lower index).
    @Test func aCivilianTakesIt() throws {
        var state = makeTestState()
        let settler = state.addUnit(.settler, owner: PlayerID(0), at: hex(1, 1))
        #expect(DebugTools.placeTribalVillage(at: hex(2, 1), in: &state))
        nextGift(.builder, for: PlayerID(0), in: &state)
        let records = try apply(.moveUnit(unit: settler, to: hex(2, 1)), &state)
        let kinds = villageEvents(records)
        #expect(kinds.first == .tribalVillageTaken(at: hex(2, 1), player: PlayerID(0), unit: settler, city: nil))
        let builder = try #require(state.units.first { $0.type == .builder && $0.owner == PlayerID(0) })
        // (2,1)'s neighbours in index order: (2,0), (3,0), (1,1), (3,1), (2,2), (3,2).
        #expect(builder.position == hex(2, 0))
        #expect(Array(kinds.dropFirst()) == [.tribalVillageGift(player: PlayerID(0), at: hex(2, 1), gift: .builder(builder.id)),
                                             .unitCreated(unit: builder.id, type: .builder, owner: PlayerID(0), at: hex(2, 0))])
        expectSound(state)
    }

    /// First come, first served, in phase order: player 0's Scout takes it in its phase; player
    /// 1's Scout, entering the tile in its own phase, finds nothing. Player 1, who saw the take,
    /// heard of it but not of the gift; player 2, who did not see it, heard nothing.
    @Test func firstComeInPhaseOrder() throws {
        var state = makeTestState(players: 3)
        let mine = state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 0))
        let theirs = state.addUnit(.scout, owner: PlayerID(1), at: hex(5, 1))
        let site = hex(3, 0)
        #expect(DebugTools.placeTribalVillage(at: site, in: &state))
        nextGift(.gold, for: PlayerID(0), in: &state) // a Builder would stand on the tile
        let t = tile(state, site)
        #expect(state.players[0].visible[t] && state.players[1].visible[t] && !state.players[2].visible[t])
        #expect(remembered(state, 1) == [site])

        let records = try apply(.moveUnit(unit: mine, to: hex(4, 0)), &state)
        let taken = try #require(records.first { if case .tribalVillageTaken = $0.event { true } else { false } })
        let gift = try #require(records.first { if case .tribalVillageGift = $0.event { true } else { false } })
        #expect(taken.event == .tribalVillageTaken(at: site, player: PlayerID(0), unit: mine, city: nil))
        #expect(taken.audience == 0b011 && gift.audience == 0b001)
        #expect(!gift.isVisible(to: PlayerID(1)) && !taken.isVisible(to: PlayerID(2)))
        for record in records where record.isVisible(to: PlayerID(1)) {
            if case .tribalVillageGift = record.event { Issue.record("player 1 heard of the gift") }
        }
        #expect(remembered(state, 1).isEmpty) // it saw the tile emptied

        try endPhases(until: PlayerID(1), &state)
        let late = try apply(.moveUnit(unit: theirs, to: site), &state)
        #expect(state.unit(theirs)?.position == site)
        #expect(villageEvents(late).isEmpty)
        #expect(state.tribalVillages?.gifts == [firstGift(.gold, seed: state.seed, player: 0) + 1, 0, 0])
        expectSound(state)
    }

    /// A take its viewer saw only as the command began is forgotten all the same (p3g review
    /// fix): player 1's Builder alone sees the tribal village, and player 0's Warrior passes
    /// through it and captures the Builder in one move. Player 1 hears of the take (the rival's
    /// line), forgets the tribal village at once (no marker, no Explore goal is left), and when
    /// it sees the tile again finds nothing gone (no second line).
    @Test func aTakeSeenOnlyAsTheCommandBeganIsForgotten() throws {
        let p1 = PlayerID(1)
        var state = makeWarState()
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(2, 3))
        let builder = state.addUnit(.builder, owner: p1, at: hex(4, 3))
        let site = hex(3, 3)
        #expect(DebugTools.placeTribalVillage(at: site, in: &state))
        let t = tile(state, site)
        let knownBefore = state.view(for: p1).knownTribalVillages
        #expect(knownBefore == [Int32(t)] && state.players[1].visible[t])

        let records = try apply(.moveUnit(unit: warrior, to: hex(4, 3)), &state)
        #expect(state.unit(warrior)?.position == hex(4, 3) && state.unit(builder) == nil)
        #expect(!state.players[1].visible[t]) // the capture took its sight of the tile away
        let heard = records.filter { $0.isVisible(to: p1) }
        #expect(heard.contains { $0.event == .tribalVillageTaken(at: site, player: PlayerID(0), unit: warrior, city: nil) })
        #expect(remembered(state, 1).isEmpty && state.players[1].memory.tribalVillages == nil)
        let view = state.view(for: p1)
        #expect(!view.isKnownTribalVillage(site))
        #expect(view.tribalVillageNews(in: heard, knownBefore: knownBefore, viewerActed: false)
                == [.reachedFirst(PlayerID(0), at: site, place: view.tribalVillagePlace(of: site))])
        expectSound(state)

        // Seen again: nothing is found gone.
        let knownNow = view.knownTribalVillages
        state.addUnit(.scout, owner: p1, at: hex(5, 4))
        #expect(state.players[1].visible[t])
        #expect(state.view(for: p1).tribalVillageNews(in: [], knownBefore: knownNow, viewerActed: false).isEmpty)
        expectSound(state)
    }
}

// MARK: - Gifts (DESIGN §3.4)

@Suite struct TribalVillageGiftTests {
    /// The bag, recomputed here from its definition: Fisher–Yates over [Gold, Science, Builder]
    /// (i from 2 down to 1, j below i + 1) with `SplitMix64(seed:, salts: player, bag, 0x4EA8)`.
    static func expectedBag(seed: UInt64, player: Int, bag: Int) -> [TribalVillageGiftKind] {
        var items: [TribalVillageGiftKind] = [.gold, .science, .builder]
        var rng = SplitMix64(seed: seed, salts: UInt64(player), UInt64(bag), 0x4EA8)
        var i = 2
        while i >= 1 {
            let j = rng.nextInt(below: i + 1)
            items.swapAt(i, j)
            i -= 1
        }
        return items
    }

    /// Every bag holds one of each gift, in the documented order, the same every time for the
    /// same seed and player; bags differ between players and bags (all six orders occur).
    @Test func theBagGivesOneOfEachPerThreeGifts() {
        var orders: [[TribalVillageGiftKind]] = []
        for seed in UInt64(1)...40 {
            for player in 0..<4 {
                for bag in 0..<3 {
                    let kinds = TribalVillageState.bag(seed: seed, player: player, bag: bag)
                    #expect(kinds.sorted { $0.rawValue < $1.rawValue } == [.gold, .science, .builder])
                    #expect(kinds == Self.expectedBag(seed: seed, player: player, bag: bag))
                    #expect(kinds == TribalVillageState.bag(seed: seed, player: player, bag: bag))
                    for k in 0..<3 {
                        #expect(TribalVillageState.giftKind(seed: seed, player: player, gift: 3 * bag + k) == kinds[k])
                    }
                    if !orders.contains(kinds) { orders.append(kinds) }
                }
            }
        }
        #expect(orders.count == 6)
    }

    /// Through the engine: a player who takes six tribal villages in a row gets one of each
    /// gift in each run of three, in its bags' order, whatever tiles they stood on.
    @Test func sixTakesGiveTwoOfEach() throws {
        var state = makeTestState(width: 16, height: 4, map: openMap(width: 16, height: 4))
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(0, 1))
        try apply(.setResearch(tech: "pottery"), &state)
        for col in 1...6 { #expect(DebugTools.placeTribalVillage(at: hex(col, 1), in: &state)) }
        var gifts: [TribalVillageGift] = []
        for target in [hex(3, 1), hex(6, 1)] {
            let records = try apply(.moveUnit(unit: scout, to: target), &state)
            for case let .tribalVillageGift(_, _, gift) in records.map(\.event) { gifts.append(gift) }
            try nextTurn(&state)
        }
        #expect(gifts.count == 6 && state.tribalVillages?.gifts == [6, 0])
        func kind(_ gift: TribalVillageGift) -> TribalVillageGiftKind {
            switch gift {
            case .gold: .gold
            case .science: .science
            case .builder: .builder
            }
        }
        let expected = TribalVillageState.bag(seed: state.seed, player: 0, bag: 0) + TribalVillageState.bag(seed: state.seed, player: 0, bag: 1)
        #expect(gifts.map(kind) == expected)
        expectSound(state)
    }

    /// The amounts: +50 Gold to the treasury; +20 research progress toward the current
    /// research; a Builder with the rules' 3 charges and no moves left, which costs no upkeep.
    @Test func theAmountsAreRight() throws {
        func take(_ kind: TribalVillageGiftKind) throws -> (before: GameState, after: GameState, gift: TribalVillageGift) {
            var state = makeTestState()
            let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
            try apply(.setResearch(tech: "pottery"), &state)
            #expect(DebugTools.placeTribalVillage(at: hex(2, 1), in: &state))
            nextGift(kind, for: PlayerID(0), in: &state)
            let before = state
            let records = try apply(.moveUnit(unit: warrior, to: hex(2, 1)), &state)
            var gift: TribalVillageGift?
            for case let .tribalVillageGift(_, _, g) in records.map(\.event) { gift = g }
            expectSound(state)
            return (before, state, try #require(gift))
        }

        let gold = try take(.gold)
        #expect(gold.gift == .gold(50))
        #expect(gold.after.players[0].gold == gold.before.players[0].gold + 50)
        #expect(gold.after.players[0].researchProgress == gold.before.players[0].researchProgress)

        let science = try take(.science)
        #expect(science.gift == .science(20, toward: "pottery"))
        #expect(science.after.players[0].researchProgress == science.before.players[0].researchProgress + 20)
        #expect(science.after.players[0].gold == science.before.players[0].gold)

        let builder = try take(.builder)
        guard case let .builder(id) = builder.gift else {
            Issue.record("not a Builder: \(builder.gift)")
            return
        }
        let unit = try #require(builder.after.unit(id))
        #expect(unit.type == .builder && unit.owner == PlayerID(0) && unit.position == hex(2, 1)) // shares the Warrior's tile
        #expect(unit.charges == 3 && unit.charges == builder.after.rules.unit(.builder).charges && unit.movesLeft == 0)
        #expect(builder.after.upkeep(of: PlayerID(0)) == builder.before.upkeep(of: PlayerID(0)))
        #expect(builder.after.militaryUnitCount(of: PlayerID(0)) == builder.before.militaryUnitCount(of: PlayerID(0)))
        #expect(builder.after.players[0].gold == builder.before.players[0].gold)
    }

    /// Science with every tech known is the Gold gift; with nothing being researched it is
    /// banked, and goes into the next research.
    @Test func scienceFallsBackOrIsBanked() throws {
        var state = makeTestState()
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(1, 1))
        #expect(DebugTools.placeTribalVillage(at: hex(2, 1), in: &state))
        #expect(DebugTools.placeTribalVillage(at: hex(3, 1), in: &state))

        var allKnown = state
        allKnown.players[0].knownTechs = allKnown.rules.techs.map(\.id).sorted()
        nextGift(.science, for: PlayerID(0), in: &allKnown)
        let gold = allKnown.players[0].gold, progress = allKnown.players[0].researchProgress
        let records = try apply(.moveUnit(unit: warrior, to: hex(2, 1)), &allKnown)
        #expect(villageEvents(records).last == .tribalVillageGift(player: PlayerID(0), at: hex(2, 1), gift: .gold(50)))
        #expect(allKnown.players[0].gold == gold + 50 && allKnown.players[0].researchProgress == progress)
        #expect(allKnown.tribalVillages?.gifts[0] == firstGift(.science, seed: 1, player: 0) + 1)
        expectSound(allKnown)

        var banked = state
        nextGift(.science, for: PlayerID(0), in: &banked)
        #expect(banked.players[0].researching == nil)
        let bankedRecords = try apply(.moveUnit(unit: warrior, to: hex(2, 1)), &banked)
        #expect(villageEvents(bankedRecords).last == .tribalVillageGift(player: PlayerID(0), at: hex(2, 1), gift: .science(20, toward: nil)))
        #expect(banked.players[0].researchProgress == 20)
        // Banked overflow goes into the next research (M1 §6): Pottery (25) after one more phase
        // start with 5 more, here from the progress set by hand.
        try apply(.setResearch(tech: "pottery"), &banked)
        banked.players[0].researchProgress += 5
        try nextTurn(&banked)
        #expect(banked.players[0].knows("pottery"))
        expectSound(banked)
    }

    /// A Builder gift lands on the tribal village's tile; else on the nearest tile within
    /// `builderRadius` where it may stand that holds no tribal village (ties: lower index); else
    /// it is the Gold gift.
    @Test func aBuilderLandsOnTheTileThenNearbyThenFallsBackToGold() throws {
        // A Settler takes it, so the tile's civilian slot is full; the neighbours with lower
        // indices are taken: (2,0) holds a Builder, (3,0) a tribal village.
        func scene(_ rules: Ruleset) -> (state: GameState, settler: UnitID) {
            var state = makeTestState(rules: rules)
            let settler = state.addUnit(.settler, owner: PlayerID(0), at: hex(1, 1))
            state.addUnit(.builder, owner: PlayerID(0), at: hex(2, 0))
            #expect(DebugTools.placeTribalVillage(at: hex(2, 1), in: &state))
            #expect(DebugTools.placeTribalVillage(at: hex(3, 0), in: &state))
            nextGift(.builder, for: PlayerID(0), in: &state)
            return (state, settler)
        }
        var (near, settler) = scene(.standard)
        let records = try apply(.moveUnit(unit: settler, to: hex(2, 1)), &near)
        guard case let .tribalVillageGift(_, _, .builder(id))? = villageEvents(records).dropFirst().first else {
            Issue.record("no Builder: \(villageEvents(records))")
            return
        }
        #expect(near.unit(id)?.position == hex(1, 1)) // the Settler's old tile: next in index order
        #expect(liveVillages(near) == [hex(3, 0)])
        expectSound(near)

        // Nothing within the radius (0 here): the Gold gift.
        var (tight, _) = scene(try villageRules { s in
            var gifts = s["gifts"] as! [String: Any]
            gifts["builderRadius"] = 0
            s["gifts"] = gifts
        })
        let gold = tight.players[0].gold
        let fallback = try apply(.moveUnit(unit: settler, to: hex(2, 1)), &tight)
        #expect(Array(villageEvents(fallback).dropFirst()) == [.tribalVillageGift(player: PlayerID(0), at: hex(2, 1), gift: .gold(50))])
        #expect(tight.players[0].gold == gold + 50 && !tight.units.contains { $0.type == .builder && $0.position != hex(2, 0) })
        expectSound(tight)
    }
}

// MARK: - The phase-start order (DESIGN §3.4; M1 §3, §7.7)

@Suite struct TribalVillageTimingTests {
    /// A test state where player 0 researches Pottery (25) with 5 progress, so a Science gift
    /// (20) reaches its cost.
    static func researching() throws -> GameState {
        var state = makeTestState(map: openMap())
        try apply(.setResearch(tech: "pottery"), &state)
        state.players[0].researchProgress = 5
        return state
    }

    /// A unit's take during a phase: the Science is learnt at the player's next phase start, and
    /// the Builder has no moves until then.
    @Test func aUnitsTakeCountsAtTheNextPhaseStart() throws {
        var state = try Self.researching()
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 1))
        #expect(DebugTools.placeTribalVillage(at: hex(3, 1), in: &state))
        #expect(DebugTools.placeTribalVillage(at: hex(4, 1), in: &state))
        nextGift(.science, for: PlayerID(0), in: &state)
        try apply(.moveUnit(unit: scout, to: hex(3, 1)), &state)
        #expect(state.players[0].researchProgress == 25 && !state.players[0].knows("pottery"))
        // The next gift in the bag after Science, made a Builder for this check.
        var builderState = state
        nextGift(.builder, for: PlayerID(0), in: &builderState)
        let records = try apply(.moveUnit(unit: scout, to: hex(4, 1)), &builderState)
        guard case let .tribalVillageGift(_, _, .builder(id))? = villageEvents(records).dropFirst().first else {
            Issue.record("no Builder: \(villageEvents(records))")
            return
        }
        #expect(builderState.unit(id)?.movesLeft == 0)

        try nextTurn(&state)
        #expect(state.players[0].knows("pottery") && state.players[0].researchProgress == 0)
        try nextTurn(&builderState)
        #expect(builderState.unit(id)?.movesLeft == builderState.rules.points(builderState.rules.unit(.builder).moves))
        expectSound(state)
        expectSound(builderState)
    }

    /// A standing order's take at phase start (after the science step and the moves restored):
    /// the same as a take during the phase.
    @Test func aStandingOrdersTakeAtPhaseStartCountsAtTheNextOne() throws {
        for kind in [TribalVillageGiftKind.science, .builder] {
            var state = try Self.researching()
            let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(0, 1))
            #expect(DebugTools.placeTribalVillage(at: hex(3, 1), in: &state))
            nextGift(kind, for: PlayerID(0), in: &state)
            try apply(.moveUnit(unit: warrior, to: hex(6, 1)), &state)
            #expect(state.unit(warrior)?.position == hex(2, 1) && state.unit(warrior)?.destination == hex(6, 1))
            var records: [EventRecord] = []
            repeat {
                records += try apply(.endTurn, &state)
            } while state.currentPlayer != PlayerID(0)
            #expect(state.unit(warrior)?.position == hex(4, 1) && liveVillages(state).isEmpty)
            let taken = villageEvents(records)
            #expect(taken.first == .tribalVillageTaken(at: hex(3, 1), player: PlayerID(0), unit: warrior, city: nil))
            switch kind {
            case .science:
                #expect(state.players[0].researchProgress == 25 && !state.players[0].knows("pottery"))
                try nextTurn(&state)
                #expect(state.players[0].knows("pottery"))
            default:
                let builder = try #require(state.units.first { $0.type == .builder })
                #expect(builder.position == hex(3, 1) && builder.movesLeft == 0)
                try nextTurn(&state)
                #expect(state.unit(builder.id)?.movesLeft == state.rules.points(state.rules.unit(.builder).moves))
            }
            expectSound(state)
        }
    }

    /// A border claim at phase start (the cities step) comes before that phase start's gold,
    /// science and unit steps: the Science is learnt in that phase start and the Builder gets
    /// its moves. A twin without the tribal village shows the difference.
    @Test func aBorderClaimAtPhaseStartCountsInThatPhaseStart() throws {
        for kind in TribalVillageGiftKind.allCases {
            var state = try Self.researching()
            let city = addCity(&state, PlayerID(0), at: hex(3, 3))
            let claim = try #require(DebugTools.primeBorderGrowth(of: city, in: &state))
            var twin = state
            #expect(DebugTools.placeTribalVillage(at: claim, in: &state))
            nextGift(kind, for: PlayerID(0), in: &state)
            var records: [EventRecord] = []
            repeat {
                records += try apply(.endTurn, &state)
            } while state.currentPlayer != PlayerID(0)
            try nextTurn(&twin)
            #expect(state.tileCity[tile(state, claim)] == Int32(city.rawValue + 1) && liveVillages(state).isEmpty)
            let order = records.map(\.event)
            let grew = try #require(order.firstIndex(of: .borderGrew(city: city, tile: claim)))
            let taken = try #require(order.firstIndex(of: .tribalVillageTaken(at: claim, player: PlayerID(0), unit: nil, city: city)))
            #expect(grew < taken)
            switch kind {
            case .gold:
                #expect(state.players[0].gold == twin.players[0].gold + 50)
            case .science:
                #expect(!twin.players[0].knows("pottery"))
                #expect(state.players[0].knows("pottery"))
                #expect(records.contains { $0.event == .techResearched(player: PlayerID(0), tech: "pottery") })
            case .builder:
                let builder = try #require(state.units.first { $0.type == .builder })
                #expect(builder.position == claim && builder.movesLeft == state.rules.points(state.rules.unit(.builder).moves))
            }
            expectSound(state)
        }
    }

    /// A founding claim counts like a unit's take: Science at the next phase start, a Builder
    /// with no moves.
    @Test func aFoundingClaimCountsLikeAUnitsTake() throws {
        for kind in [TribalVillageGiftKind.science, .builder] {
            var state = try Self.researching()
            let settler = state.addUnit(.settler, owner: PlayerID(0), at: hex(3, 3))
            #expect(DebugTools.placeTribalVillage(at: hex(4, 3), in: &state))
            nextGift(kind, for: PlayerID(0), in: &state)
            try apply(.foundCity(unit: settler), &state)
            #expect(liveVillages(state).isEmpty)
            switch kind {
            case .science:
                #expect(state.players[0].researchProgress == 25 && !state.players[0].knows("pottery"))
                try nextTurn(&state)
                #expect(state.players[0].knows("pottery"))
            default:
                let builder = try #require(state.units.first { $0.type == .builder })
                #expect(builder.position == hex(4, 3) && builder.movesLeft == 0)
            }
            expectSound(state)
        }
    }
}

// MARK: - City claims (DESIGN §3.5)

@Suite struct TribalVillageCityClaimTests {
    /// Founding claims the ring: the tribal villages on the tiles it claims go to the founder,
    /// in tile order, after `cityFounded`; one further out stays.
    @Test func foundingTakesTheRingsTribalVillages() throws {
        var state = makeTestState()
        let settler = state.addUnit(.settler, owner: PlayerID(0), at: hex(2, 2))
        for site in [hex(3, 2), hex(1, 1), hex(4, 2)] { #expect(DebugTools.placeTribalVillage(at: site, in: &state)) }
        let records = try apply(.foundCity(unit: settler), &state)
        let city = try #require(state.city(at: hex(2, 2))?.id)
        let taken = villageEvents(records).filter { if case .tribalVillageTaken = $0 { true } else { false } }
        #expect(taken == [.tribalVillageTaken(at: hex(1, 1), player: PlayerID(0), unit: nil, city: city),
                          .tribalVillageTaken(at: hex(3, 2), player: PlayerID(0), unit: nil, city: city)])
        let order = records.map(\.event)
        let founded = try #require(order.firstIndex { if case .cityFounded = $0 { true } else { false } })
        let first = try #require(order.firstIndex { if case .tribalVillageTaken = $0 { true } else { false } })
        #expect(founded < first)
        #expect(liveVillages(state) == [hex(4, 2)] && state.tribalVillages?.gifts == [2, 0])
        #expect(remembered(state, 0) == [hex(4, 2)])
        expectSound(state)
    }

    /// Border growth claims one: the city's owner gets the gift, after `borderGrew`.
    @Test func borderGrowthTakesIt() throws {
        var state = makeTestState()
        let city = addCity(&state, PlayerID(0), at: hex(2, 2))
        let claim = try #require(DebugTools.primeBorderGrowth(of: city, in: &state))
        #expect(DebugTools.placeTribalVillage(at: claim, in: &state))
        let gold = state.players[0].gold
        var records: [EventRecord] = []
        repeat {
            records += try apply(.endTurn, &state)
        } while state.currentPlayer != PlayerID(0)
        #expect(state.tileCity[tile(state, claim)] == Int32(city.rawValue + 1))
        let kinds = villageEvents(records)
        #expect(kinds.first == .tribalVillageTaken(at: claim, player: PlayerID(0), unit: nil, city: city))
        #expect(kinds.count >= 2 && state.tribalVillages?.gifts == [1, 0])
        if TribalVillageState.giftKind(seed: state.seed, player: 0, gift: 0) == .gold { #expect(state.players[0].gold >= gold + 50) }
        #expect(liveVillages(state).isEmpty && remembered(state, 0).isEmpty)
        expectSound(state)
    }
}

// MARK: - Every other path (DESIGN §3.6)

@Suite struct TribalVillageOtherPathTests {
    /// A unit made in a city never lands on one: spawns go to owned tiles (M1 §5), where none
    /// stands. Here the centre is full and every unowned tile within the spawn radius holds one.
    @Test func aSpawnNeverLandsOnOne() throws {
        var state = makeTestState(map: openMap())
        let city = addCity(&state, PlayerID(0), at: hex(3, 3))
        state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 3))
        var placed: [HexCoord] = []
        for h in state.map.coords(within: 2, of: hex(3, 3)) where state.tileOwner(tile(state, h)) == nil {
            if DebugTools.placeTribalVillage(at: h, in: &state) { placed.append(h) }
        }
        #expect(placed.count == 12)
        let records = try apply(.purchase(city: city, item: .unit(.warrior)), &state)
        let created = records.compactMap { record -> HexCoord? in
            if case let .unitCreated(_, .warrior, _, at) = record.event { return at }
            return nil
        }
        let spot = try #require(created.first)
        #expect(state.tileOwner(tile(state, spot)) == PlayerID(0) && !placed.contains(spot))
        #expect(villageEvents(records).isEmpty && liveVillages(state).count == 12)
        expectSound(state)
    }

    /// Eviction from closed borders (M1 §9) skips a tile that holds one, and takes nothing: the
    /// Warrior evicted from (6,3) goes to (7,3), not to (7,2), the lowest index.
    @Test func evictionSkipsThem() throws {
        var state = makeTestState(map: openMap())
        addCity(&state, PlayerID(1), at: hex(5, 3))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(6, 3))
        var plain = state
        #expect(DebugTools.placeTribalVillage(at: hex(7, 2), in: &state))
        try nextTurn(&plain)
        #expect(plain.unit(warrior)?.position == hex(7, 2))
        let records: [EventRecord] = try {
            var all: [EventRecord] = []
            repeat {
                all += try apply(.endTurn, &state)
            } while state.currentPlayer != PlayerID(0)
            return all
        }()
        #expect(state.unit(warrior)?.position == hex(7, 3))
        #expect(villageEvents(records).isEmpty && liveVillages(state) == [hex(7, 2)])
        expectSound(state)
    }

    /// Eviction skips a tribal village its player never saw, as it skips a unit its player cannot
    /// see (M1 §9, §7.7: the nearest tile it may stand on that holds no tribal village; M1 §8.6:
    /// the real world decides where a unit can go). So where the evicted unit lands depends on
    /// both, and fog twins that differ only there (G10) differ after an eviction: an exception the
    /// p3g review accepted, as for hidden units, rather than change the binding rule. Pinned:
    /// every tile within 2 of the Warrior is closed to it, so it lands 3 tiles out, beyond its
    /// sight, on (5,0), the lowest index, or on (6,0) when a hidden tribal village or a hidden
    /// unit stands on (5,0); nothing is taken.
    @Test func evictionSkipsAHiddenTribalVillageAsItSkipsAHiddenUnit() throws {
        var plain = makeTestState(map: openMap())
        let city = addCity(&plain, PlayerID(1), at: hex(5, 3))
        for h in plain.map.coords(within: 2, of: hex(6, 3)) where plain.tileOwner(tile(plain, h)) == nil {
            claimTile(&plain, h, for: city)
        }
        let warrior = plain.addUnit(.warrior, owner: PlayerID(0), at: hex(6, 3))
        let spot = hex(5, 0)
        #expect(plain.map.distance(spot, hex(6, 3)) == 3 && !plain.players[0].explored[tile(plain, spot)])
        var village = plain, unit = plain
        #expect(DebugTools.placeTribalVillage(at: spot, in: &village))
        unit.addUnit(.scout, owner: PlayerID(1), at: spot)
        #expect(!village.players[0].visible[tile(village, spot)] && !unit.players[0].visible[tile(unit, spot)])
        expectSameObservations(observations(of: village), observations(of: plain), "a hidden tribal village")
        expectSameObservations(observations(of: unit), observations(of: plain), "a hidden unit")

        try nextTurn(&plain)
        try nextTurn(&village)
        try nextTurn(&unit)
        #expect(plain.unit(warrior)?.position == spot)
        #expect(village.unit(warrior)?.position == hex(6, 0) && liveVillages(village) == [spot])
        #expect(unit.unit(warrior)?.position == hex(6, 0))
        expectSound(village)
    }

    /// `addUnit` onto one (debug and tests) removes it with no gift, and every player who sees
    /// the tile forgets it at once.
    @Test func addUnitClearsOneAndRefreshesEveryViewer() throws {
        var state = makeTestState(map: openMap())
        state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 3))
        state.addUnit(.scout, owner: PlayerID(1), at: hex(5, 3))
        let site = hex(3, 3)
        #expect(DebugTools.placeTribalVillage(at: site, in: &state))
        #expect(remembered(state, 0) == [site] && remembered(state, 1) == [site])
        let gold = state.players.map(\.gold)
        state.addUnit(.warrior, owner: PlayerID(0), at: site)
        #expect(liveVillages(state).isEmpty && state.tribalVillages?.gifts == [0, 0])
        #expect(remembered(state, 0).isEmpty && remembered(state, 1).isEmpty)
        #expect(state.players.map(\.gold) == gold)
        expectSound(state)
    }

    /// `DebugTools.spawnUnits` never puts a unit on one.
    @Test func spawnUnitsSkipsThem() throws {
        var state = makeTestState(width: 16, height: 10, map: openMap(width: 16, height: 10))
        var placed: [HexCoord] = []
        for col in stride(from: 1, to: 15, by: 2) {
            for row in stride(from: 1, to: 9, by: 2) where DebugTools.placeTribalVillage(at: hex(col, row), in: &state) {
                placed.append(hex(col, row))
            }
        }
        #expect(placed.count == 28)
        DebugTools.spawnUnits(count: 60, seed: 5, in: &state)
        #expect(state.units.count > 40)
        #expect(state.units.allSatisfy { !placed.contains($0.position) })
        #expect(liveVillages(state) == placed.sorted { tile(state, $0) < tile(state, $1) })
        expectSound(state)
    }
}

// MARK: - Placement (DESIGN §3.2)

/// Land steps from `start` over passable land, each step counting 1 (−1: unreachable),
/// computed here independently of the engine's placement.
private func landSteps(from start: HexCoord, map: HexMap, rules: Ruleset) -> [Int] {
    var steps = [Int](repeating: -1, count: map.tileCount)
    guard let s = map.index(of: start) else { return steps }
    steps[s] = 0
    var frontier = [s]
    while !frontier.isEmpty {
        var next: [Int] = []
        for t in frontier {
            for n in map.neighbors(of: map.coord(at: t)).compactMap(map.index(of:)) where steps[n] < 0 && rules.isPassable(map.tiles[n]) {
                steps[n] = steps[t] + 1
                next.append(n)
            }
        }
        frontier = next
    }
    return steps
}

/// A tile's side as M1 §7.7 defines it: its nearest start (ties: lower player), the steps to
/// it, the margin over the next-nearest (30 when no other start reaches it), and how many
/// starts reach it.
private func side(of t: Int, _ steps: [[Int]]) -> (start: Int, steps: Int, margin: Int, reached: Int)? {
    var best: (start: Int, steps: Int)?
    var next = Int.max, reached = 0
    for (s, field) in steps.enumerated() where field[t] >= 0 {
        reached += 1
        if let b = best, b.steps <= field[t] {
            next = min(next, field[t])
        } else {
            if let b = best { next = min(next, b.steps) }
            best = (s, field[t])
        }
    }
    guard let best else { return nil }
    return (best.start, best.steps, next == .max ? 30 : next - best.steps, reached)
}

@Suite struct TribalVillagePlacementTests {
    /// Checks one generated map's placement against M1 §7.7 by tag; returns the own count per
    /// start and the total.
    static func check(_ size: MapSize, seed: UInt64) -> (perStart: Int, total: Int) {
        let rules = Ruleset.standard
        let v = rules.tribalVillages!
        let generated = MapGenerator.generate(MapGenSettings(size: size, seed: seed))
        let map = generated.map, starts = generated.startPositions
        let label = "\(size.rawValue) seed \(seed)"
        let sites = DebugTools.tribalVillagePlacement(seed: seed, map: map, startPositions: starts)

        // Deterministic; the tags' tiles are newGame's sites; independent of who is human and of
        // the civs.
        #expect(DebugTools.tribalVillagePlacement(seed: seed, map: map, startPositions: starts) == sites, "\(label)")
        let game = GameState.newGame(seed: seed, map: map, startPositions: starts, mapSizeName: size.rawValue,
                                     placeTribalVillages: true)
        #expect(DebugTools.tribalVillages(in: game) == sites.map(\.hex), "\(label)")
        let other = GameState.newGame(seed: seed, map: map, startPositions: starts, humanPlayers: [],
                                      civs: Array(rules.civs.map(\.id).reversed()), mapSizeName: size.rawValue,
                                      placeTribalVillages: true)
        #expect(DebugTools.tribalVillages(in: other) == sites.map(\.hex), "\(label)")
        #expect(game.tribalVillages?.gifts == [Int](repeating: 0, count: game.players.count), "\(label)")
        expectSound(game)

        // Equal own-side counts, by tag.
        var own = [Int](repeating: 0, count: starts.count)
        for site in sites { if let s = site.start { own[s] += 1 } }
        #expect(own.allSatisfy { $0 == own[0] }, "\(label): own counts \(own)")

        // Tile order, allowed tiles, sides, bands, margins and spacing.
        let steps = starts.map { landSteps(from: $0, map: map, rules: rules) }
        let startTiles = starts.compactMap(map.index(of:))
        let bands = v.rounds.flatMap { $0 }
        let tiles = sites.map { map.index(of: $0.hex)! }
        #expect(tiles == tiles.sorted() && Set(tiles).count == tiles.count, "\(label)")
        for (site, t) in zip(sites, tiles) {
            let tile = map.tiles[t]
            #expect(rules.isPassable(tile) && tile.feature != .oasis && tile.terrain != .snow, "\(label) \(site)")
            #expect(!startTiles.contains(t) && game.tileCity[t] == 0 && game.units(at: site.hex).isEmpty, "\(label) \(site)")
            guard let side = side(of: t, steps) else {
                Issue.record("\(label): \(site) reachable from no start")
                continue
            }
            if let s = site.start {
                #expect(side.start == s, "\(label): \(site) is on start \(side.start)'s side")
                #expect(bands.contains { $0.min <= side.steps && side.steps <= $0.max && side.margin >= $0.margin },
                        "\(label): \(site) at \(side.steps) steps, margin \(side.margin), fits no band")
            } else {
                #expect(side.reached == starts.count && side.steps >= v.shared.minSteps && side.margin <= v.shared.maxMargin,
                        "\(label): shared \(site) at \(side.steps) steps, margin \(side.margin), reached by \(side.reached)")
            }
        }
        for i in sites.indices {
            for j in sites.indices where j > i {
                #expect(map.distance(sites[i].hex, sites[j].hex) >= v.spacing, "\(label): \(sites[i].hex) and \(sites[j].hex)")
            }
        }
        return (own[0], sites.count)
    }

    /// Duel seeds 1–120: the properties on every map, and a mean of at least 7 per map.
    @Test func duelPlacementProperties() {
        var total = 0, threeEach = 0
        for seed in UInt64(1)...120 {
            let result = Self.check(.duel, seed: seed)
            total += result.total
            if result.perStart == 3 { threeEach += 1 }
        }
        #expect(total * 10 >= 7 * 10 * 120, "Duel mean \(Double(total) / 120)")
        #expect(threeEach >= 100, "3 own per start on \(threeEach) of 120 maps")
    }

    /// Small, Standard and Large seeds 1–20: the properties on every map.
    @Test(arguments: [MapSize.small, .standard, .large])
    func placementPropertiesOnLargerMaps(_ size: MapSize) {
        var total = 0
        for seed in UInt64(1)...20 { total += Self.check(size, seed: seed).total }
        // About 8 per start pair (M1 §7.7): at least 3 own and some shared per start on most maps.
        #expect(total >= 20 * 3 * size.defaultPlayers, "\(size.rawValue): \(total) on 20 maps")
    }

    /// Placement takes under 50 ms on Large in a debug build (the 5 ms budget is a release gate):
    /// the slowest of 20 seeds, each the best of five runs, so that other tests running at the
    /// same time rarely move it. Provisional: a heavily loaded machine still can.
    @Test func placementIsFastOnLarge() {
        var slowest = Duration.zero
        for seed in UInt64(1)...20 {
            let generated = MapGenerator.generate(MapGenSettings(size: .large, seed: seed))
            let state = GameState.newGame(seed: seed, map: generated.map, startPositions: generated.startPositions)
            var best = Duration.seconds(1)
            for _ in 0..<5 {
                let clock = ContinuousClock()
                let elapsed = clock.measure {
                    var placer = TribalVillagePlacer(state: state, startPositions: generated.startPositions,
                                                     rules: Ruleset.standard.tribalVillages!)
                    _ = placer.place()
                }
                best = min(best, elapsed)
            }
            slowest = max(slowest, best)
        }
        #expect(slowest < .milliseconds(50), "placement on Large: \(slowest)")
    }

    /// Without the rules section, or without the flag, a new game has none (the C0 kill switch
    /// itself is `underC0ANewGameIsAsBeforeEvenWhenAskedToPlaceThem`); the tags are empty.
    @Test func noSectionOrNoFlagPlacesNone() throws {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: 11))
        let c0 = try c0Rules()
        #expect(DebugTools.tribalVillagePlacement(seed: 11, map: generated.map, startPositions: generated.startPositions, rules: c0).isEmpty)
        let plain = GameState.newGame(seed: 11, map: generated.map, startPositions: generated.startPositions)
        #expect(plain.tribalVillages == nil)
        let placed = GameState.newGame(seed: 11, map: generated.map, startPositions: generated.startPositions, placeTribalVillages: true)
        #expect(placed.tribalVillages != nil && !liveVillages(placed).isEmpty)
        // Those in a start's sight are known on turn 1.
        for p in placed.players {
            let seen = liveVillages(placed).filter { p.visible[placed.map.index(of: $0)!] }
            #expect(remembered(placed, p.id.rawValue) == seen)
        }
    }

    /// The rounds are all or none (M1 §7.7). A hand-built map: start 0 on open land, starts 1
    /// and 2 each in a pocket of seven tiles walled by mountains. Round 1 (4–6 steps) visits
    /// start 0 first (the seed is chosen for it), which picks; start 1 has no candidate, so the
    /// round stops: its pick is dropped, `blocked` is as before the round, start 2 draws
    /// nothing, and the stream is not rewound (two draws made). Round 2 (1 step) then follows
    /// the documented stream from there.
    @Test func aRoundIsAllOrNone() throws {
        var map = openMap(width: 20, height: 9)
        let pockets = [hex(16, 2), hex(16, 6)]
        for pocket in pockets {
            let inner = map.coords(within: 1, of: pocket)
            for h in map.coords(within: 2, of: pocket) where !inner.contains(h) {
                map[h] = Tile(terrain: .grassland, elevation: .mountains)
            }
        }
        let starts = [hex(3, 4)] + pockets
        typealias Band = TribalVillageRules.Band
        let rules = TribalVillageRules(rounds: [[Band(min: 4, max: 6, margin: 0)], [Band(min: 1, max: 1, margin: 0)]],
                                       shared: .init(perStart: 1, minSteps: 1, maxMargin: 10), spacing: 2,
                                       gifts: .init(gold: 50, science: 20, builderRadius: 2), seekTurns: 3)
        let seed = try #require((UInt64(1)...200).first { seed in
            var rng = SplitMix64(seed: seed, salts: 0x4EA7)
            return rng.nextInt(below: 3) == 0
        })
        let state = GameState.newGame(seed: seed, map: map, startPositions: starts)
        let occupied = state.units.map { map.index(of: $0.position)! }
        let steps = starts.map { landSteps(from: $0, map: map, rules: state.rules) }
        let startTiles = starts.map { map.index(of: $0)! }
        /// Start `s`'s own allowed tiles at `range` steps, in tile order, unblocked.
        func candidates(_ s: Int, _ range: ClosedRange<Int>, _ blocked: TileBitSet) -> [Int] {
            (0..<map.tileCount).filter { t in
                guard let side = side(of: t, steps), side.start == s, range.contains(side.steps) else { return false }
                return !startTiles.contains(t) && !occupied.contains(t) && !blocked[t]
            }
        }

        var placer = TribalVillagePlacer(state: state, startPositions: starts, rules: rules)
        let blockedBefore = placer.blocked
        var expected = placer.rng
        let free = TileBitSet(count: map.tileCount)
        let near0 = placer.own[0].filter { (4...6).contains($0.steps) }.map { (c: TribalVillagePlacer.Candidate) in c.tile }
        #expect(near0 == candidates(0, 4...6, free))
        #expect(candidates(1, 4...6, free).isEmpty && candidates(2, 4...6, free).isEmpty)

        let first = placer.runRound(rules.rounds[0])
        #expect(!first)
        #expect(placer.picks.isEmpty && placer.blocked == blockedBefore)
        let firstOffset = expected.nextInt(below: 3)
        #expect(firstOffset == 0)
        _ = expected.nextInt(below: candidates(0, 4...6, free).count)
        #expect(placer.rng == expected, "exactly two draws: the offset and start 0's pick")

        let second = placer.runRound(rules.rounds[1])
        #expect(second)
        var blocked = free
        var picks: [TribalVillagePlacer.Pick] = []
        let offset = expected.nextInt(below: 3)
        for k in 0..<3 {
            let s = (offset + k) % 3
            let list = candidates(s, 1...1, blocked)
            let t = list[expected.nextInt(below: list.count)]
            picks.append(.init(tile: t, start: s))
            for h in map.coords(within: 1, of: map.coord(at: t)) { blocked[map.index(of: h)!] = true }
        }
        #expect(placer.picks == picks && placer.blocked == blocked && placer.rng == expected)

        // The whole placement: round 1 dropped, round 2 kept, no shared one (no tile is reached
        // from every start).
        var whole = TribalVillagePlacer(state: state, startPositions: starts, rules: rules)
        let all = whole.place()
        #expect(all == picks.sorted { $0.tile < $1.tile })
    }
}

// MARK: - Invariants (DESIGN §3.6)

@Suite struct TribalVillageInvariantTests {
    /// `checkInvariants` catches each broken rule, out-of-range indices included (no trap), and
    /// stale memory on a visible tile; one taken out of sight may stay remembered.
    @Test func eachViolationIsCaught() throws {
        var state = makeTestState()
        state.addUnit(.scout, owner: PlayerID(0), at: hex(1, 1))
        let seen = hex(3, 1), unseen = hex(8, 4)
        #expect(DebugTools.placeTribalVillage(at: seen, in: &state))
        #expect(DebugTools.placeTribalVillage(at: unseen, in: &state))
        let theirs = addCity(&state, PlayerID(1), at: hex(9, 1))
        expectSound(state)
        let count = state.map.tileCount
        let s = tile(state, seen), u = tile(state, unseen)
        #expect(state.players[0].visible[s] && !state.players[0].visible[u] && !state.players[1].visible[u])
        #expect(state.tribalVillages?.sites == [Int32(s), Int32(u)])

        func problems(_ change: (inout GameState) -> Void) -> [String] {
            var copy = state
            change(&copy)
            return copy.checkInvariants()
        }
        let cases: [(String, String, (inout GameState) -> Void)] = [
            ("unsorted", "not sorted and unique", { $0.tribalVillages?.sites = [Int32(u), Int32(s)] }),
            ("twice", "not sorted and unique", { $0.tribalVillages?.sites = [Int32(u), Int32(u)] }),
            ("off the map", "off the map", { $0.tribalVillages?.sites.append(Int32(count + 3)) }),
            ("negative", "off the map", { $0.tribalVillages?.sites.insert(-1, at: 0) }),
            ("on a mountain", "impassable", { $0.tribalVillages?.sites = [Int32(s), Int32(tile(state, hex(5, 3))), Int32(u)] }),
            ("owned", "owned", { $0.tileCity[u] = Int32(theirs.rawValue + 1) }),
            ("under a unit", "a unit on the tribal village", { $0.insertUnit(.warrior, owner: PlayerID(1), at: unseen) }),
            ("gift counts", "gifts for 1 players", { $0.tribalVillages?.gifts = [0] }),
            ("a negative gift count", "tribal village gifts", { $0.tribalVillages?.gifts = [-1, 0] }),
            ("empty memory", "empty list", { $0.players[1].memory.tribalVillages = [] }),
            ("unsorted memory", "memory not sorted", { $0.players[1].memory.tribalVillages = [Int32(u), Int32(s - 1)] }),
            ("memory off the map", "remembers a tribal village off the map", { $0.players[1].memory.tribalVillages = [Int32(count)] }),
            ("seen, not remembered", "1 seen and not remembered", { $0.players[0].memory.tribalVillages = nil }),
            ("remembered, gone", "1 remembered and gone", { $0.players[0].memory.tribalVillages = [Int32(s - 1), Int32(s)] }),
        ]
        for (name, message, change) in cases {
            let found = problems(change)
            #expect(found.contains { $0.contains(message) }, "\(name): \(found)")
        }
        // Remembered out of sight with nothing there now: allowed (taken out of sight).
        #expect(problems { $0.players[0].memory.tribalVillages = [Int32(s), Int32(tile(state, hex(7, 7)))] }.isEmpty)
    }
}

// MARK: - Random stress (DESIGN §9)

@Suite struct TribalVillageStressTests {
    /// 20 random games on Duel maps with tribal villages (random commands for both players:
    /// moves, founding, war, attacks, production), the invariants checked after every phase.
    /// Every take gives exactly one gift to its taker, heard by the taker alone; the counts add
    /// up. Returns the takes of each game.
    @Test(arguments: 1...20)
    func randomGamesKeepTheInvariants(_ seed: Int) throws {
        let generated = MapGenerator.generate(MapGenSettings(size: .duel, seed: UInt64(seed)))
        var state = GameState.newGame(seed: UInt64(seed), map: generated.map, startPositions: generated.startPositions,
                                      humanPlayers: [], mapSizeName: MapSize.duel.rawValue, placeTribalVillages: true)
        let placed = liveVillages(state).count
        #expect(placed > 0)
        var rng = SplitMix64(seed: UInt64(seed), salts: 0x7E57)
        var takes = 0, byCity = 0
        var gifts = [Int](repeating: 0, count: state.players.count)
        func tally(_ records: [EventRecord]) {
            for record in records {
                switch record.event {
                case let .tribalVillageTaken(_, player, unit, city):
                    takes += 1
                    if city != nil { byCity += 1 }
                    #expect((unit == nil) != (city == nil) && record.isVisible(to: player))
                case let .tribalVillageGift(player, _, _):
                    gifts[player.rawValue] += 1
                    #expect(record.audience == UInt16(1) << UInt16(player.rawValue))
                default: break
                }
            }
        }
        for _ in 0..<(40 * state.players.count) {
            guard state.outcome == nil else { break }
            let me = state.currentPlayer
            for command in DebugTools.randomCommands(in: state, rng: &rng) {
                if let records = try? GameEngine.apply(command, by: me, to: &state) { tally(records) }
            }
            if state.outcome == nil, state.currentPlayer == me { tally(try GameEngine.apply(.endTurn, by: me, to: &state)) }
            let problems = state.checkInvariants()
            #expect(problems.isEmpty, "seed \(seed), turn \(state.turn): \(problems)")
            if !problems.isEmpty { return }
        }
        #expect(takes > 0, "seed \(seed): no tribal village taken")
        #expect(placed - liveVillages(state).count == takes)
        #expect(state.tribalVillages?.gifts == gifts && gifts.reduce(0, +) == takes)
    }
}
