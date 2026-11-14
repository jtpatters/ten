import Foundation
import MapGen
import Testing
@testable import GameCore

// Tribal villages, the contracts (phase 3g H0; M1 §7.7): the rules section and its kill switch,
// what players remember and the queries over it, the events' audiences and the debug tools.
// Placement, taking and the gifts come with H1 (TribalVillageTests).

/// The standard rules' content hash before the tribal village section existed: the post-3f tree
/// (snapshot p3fs), as PersistenceTests' version-1 save fixture records it.
/// The standard rules without the tribal village section. Re-pinned for M2 2.1a's research arc
/// (0x3CA4_9347_F3CE_D14C before).
let preTribalVillagesContentHash: UInt64 = 0xBFEF_02A2_E741_CF62 // M2 2.1c naval (roads 0x64A7_845F_7191_2D3E) (resources 0xCF31_AB6F_FA55_2850) (2.1b 0x759D_2BF3_A784_F5D9) (siege walls: 0xD2D1_D061_C19D_3D1F) (units: 0x8AD0_7E93_B606_6DB7) (2.1a: 0x727F_8E66_FA5E_7BBD)

/// C0: the standard rules without their tribal village section.
func c0Rules() throws -> Ruleset {
    var json = try standardRulesJSON()
    json.removeValue(forKey: "tribalVillages")
    return try loadRules(json)
}

/// Removes a tribal village the way every path that removes one must (M1 §7.7): the site goes
/// and its tile is touched, so every player who sees the tile updates their memory.
func removeTribalVillage(at hex: HexCoord, in state: inout GameState) {
    let t = state.map.index(of: hex)!
    state.tribalVillages?.remove(t)
    var fx = Effects()
    fx.touchTile(t)
    state.updateKnowledge(&fx)
}

@Suite struct TribalVillageRulesTests {
    /// The numbers of M1 §7.7, as the data holds them.
    @Test func theStandardRulesHaveTheSection() throws {
        let v = try #require(Ruleset.standard.tribalVillages)
        typealias Band = TribalVillageRules.Band
        let wide = [Band(min: 7, max: 11, margin: 3), Band(min: 6, max: 12, margin: 2), Band(min: 5, max: 13, margin: 1),
                    Band(min: 4, max: 14, margin: 0)]
        #expect(v.rounds == [[Band(min: 4, max: 6, margin: 3), Band(min: 3, max: 7, margin: 2)], wide, wide])
        #expect(v.shared == TribalVillageRules.Shared(perStart: 1, minSteps: 7, maxMargin: 1))
        #expect(v.spacing == 4 && v.seekTurns == 3)
        #expect(v.gifts == TribalVillageRules.Gifts(gold: 50, science: 20, builderRadius: 2))
        #expect(Ruleset.standard.id == "m1.1")
    }

    /// The validation problems of the standard rules with the tribal village section changed.
    func problems(_ change: (inout [String: Any]) -> Void) throws -> [String] {
        try validationProblems { json in
            var section = json["tribalVillages"] as! [String: Any]
            change(&section)
            json["tribalVillages"] = section
        }
    }

    /// Sets one field of one band.
    static func band(_ section: inout [String: Any], _ round: Int, _ band: Int, _ field: String, _ value: Int) {
        var rounds = section["rounds"] as! [[[String: Any]]]
        rounds[round][band][field] = value
        section["rounds"] = rounds
    }

    /// Sets one field of a nested group (`shared`, `gifts`).
    static func group(_ section: inout [String: Any], _ name: String, _ field: String, _ value: Int) {
        var group = section[name] as! [String: Any]
        group[field] = value
        section[name] = group
    }

    /// Each limit of M1 §7.7's table is checked on load; the limits themselves load.
    @Test func badSectionsAreRejected() throws {
        let bad: [(String, (inout [String: Any]) -> Void)] = [
            ("min 0", { Self.band(&$0, 0, 0, "min", 0) }),
            ("min above max", { Self.band(&$0, 0, 0, "min", 7) }),
            ("max 31", { Self.band(&$0, 1, 3, "max", 31) }),
            ("margin -1", { Self.band(&$0, 2, 0, "margin", -1) }),
            ("margin 21", { Self.band(&$0, 2, 1, "margin", 21) }),
            ("7 rounds", { s in
                let rounds = s["rounds"] as! [[[String: Any]]]
                s["rounds"] = Array(repeating: rounds[0], count: 7)
            }),
            ("an empty round", { s in
                var rounds = s["rounds"] as! [[[String: Any]]]
                rounds[1] = []
                s["rounds"] = rounds
            }),
            ("5 bands", { s in
                var rounds = s["rounds"] as! [[[String: Any]]]
                rounds[1].append(rounds[1][0])
                s["rounds"] = rounds
            }),
            ("perStart 4", { Self.group(&$0, "shared", "perStart", 4) }),
            ("perStart -1", { Self.group(&$0, "shared", "perStart", -1) }),
            ("minSteps 0", { Self.group(&$0, "shared", "minSteps", 0) }),
            ("minSteps 31", { Self.group(&$0, "shared", "minSteps", 31) }),
            ("maxMargin 11", { Self.group(&$0, "shared", "maxMargin", 11) }),
            ("maxMargin -1", { Self.group(&$0, "shared", "maxMargin", -1) }),
            ("spacing 0", { $0["spacing"] = 0 }),
            ("spacing 9", { $0["spacing"] = 9 }),
            ("gold 501", { Self.group(&$0, "gifts", "gold", 501) }),
            ("gold -1", { Self.group(&$0, "gifts", "gold", -1) }),
            ("science 501", { Self.group(&$0, "gifts", "science", 501) }),
            ("science -1", { Self.group(&$0, "gifts", "science", -1) }),
            ("builderRadius 4", { Self.group(&$0, "gifts", "builderRadius", 4) }),
            ("builderRadius -1", { Self.group(&$0, "gifts", "builderRadius", -1) }),
            ("seekTurns 11", { $0["seekTurns"] = 11 }),
            ("seekTurns -1", { $0["seekTurns"] = -1 }),
        ]
        for (name, change) in bad {
            let found = try problems(change)
            #expect(!found.isEmpty && found.allSatisfy { $0.contains("tribalVillages") }, "\(name): \(found)")
        }

        let limits: [(String, (inout [String: Any]) -> Void)] = [
            ("min 1, max 30, margins 0 and 20", { s in
                Self.band(&s, 0, 0, "min", 1)
                Self.band(&s, 0, 0, "max", 30)
                Self.band(&s, 0, 0, "margin", 20)
                Self.band(&s, 0, 1, "margin", 0)
            }),
            ("min = max", { s in
                Self.band(&s, 1, 0, "min", 9)
                Self.band(&s, 1, 0, "max", 9)
            }),
            ("no rounds", { $0["rounds"] = [[[String: Any]]]() }),
            ("6 rounds", { s in
                let rounds = s["rounds"] as! [[[String: Any]]]
                s["rounds"] = Array(repeating: rounds[1], count: 6)
            }),
            ("low ends", { s in
                Self.group(&s, "shared", "perStart", 0)
                Self.group(&s, "shared", "minSteps", 1)
                Self.group(&s, "shared", "maxMargin", 0)
                s["spacing"] = 1
                Self.group(&s, "gifts", "gold", 0)
                Self.group(&s, "gifts", "science", 0)
                Self.group(&s, "gifts", "builderRadius", 0)
                s["seekTurns"] = 0
            }),
            ("high ends", { s in
                Self.group(&s, "shared", "perStart", 3)
                Self.group(&s, "shared", "minSteps", 30)
                Self.group(&s, "shared", "maxMargin", 10)
                s["spacing"] = 8
                Self.group(&s, "gifts", "gold", 500)
                Self.group(&s, "gifts", "science", 500)
                Self.group(&s, "gifts", "builderRadius", 3)
                s["seekTurns"] = 10
            }),
        ]
        for (name, change) in limits {
            #expect(try problems(change).isEmpty, "\(name)")
        }

        // A field missing from the section does not decode.
        var json = try standardRulesJSON()
        var section = try #require(json["tribalVillages"] as? [String: Any])
        section.removeValue(forKey: "seekTurns")
        json["tribalVillages"] = section
        #expect(throws: (any Error).self) { try loadRules(json) }
    }

    /// The kill switch: without the section (C0) the rules have none, their canonical encoding
    /// leaves the key out, and their content hash is the one the rules had before the section
    /// existed. A null section is the same as none.
    @Test func withoutTheSectionTheRulesAreAsBefore() throws {
        let c0 = try c0Rules()
        #expect(c0.tribalVillages == nil && c0.id == Ruleset.standard.id)
        #expect(c0.contentHash == preTribalVillagesContentHash, "C0 content hash: 0x\(String(c0.contentHash, radix: 16))")
        #expect(Ruleset.standard.contentHash != preTribalVillagesContentHash)
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(c0.data)) as? [String: Any])
        #expect(encoded["tribalVillages"] == nil)

        var json = try standardRulesJSON()
        json["tribalVillages"] = NSNull()
        let null = try loadRules(json)
        #expect(null.tribalVillages == nil && null.contentHash == preTribalVillagesContentHash)
    }

    /// The kill switch when a game is made, which H1's placement must keep green: under C0 a new
    /// game asked to place tribal villages is the very game made without asking, field for field
    /// and hash for hash, with none placed and none remembered. On generated maps with their
    /// starts:
    /// - Duel seed 11 (the play-test's map), where the standard rules place them once H1 lands;
    /// - `make headless`'s game (Large seed 42, every player an AI, 300 units spawned, set up as
    ///   HeadlessSim's `playGame` does), whose state hash is the post-3f tree's turn-1 hash
    ///   (snapshot p3fs; `build/m1/merge6/logs/headless.log`), so C0 starts bit-identical to it.
    @Test func underC0ANewGameIsAsBeforeEvenWhenAskedToPlaceThem() throws {
        let c0 = try c0Rules()
        func expectNone(_ state: GameState, _ label: String) {
            #expect(state.tribalVillages == nil && DebugTools.tribalVillages(in: state).isEmpty, "\(label)")
            #expect(state.players.allSatisfy { $0.memory.tribalVillages == nil }, "\(label)")
            expectSound(state)
        }

        let duel = MapGenerator.generate(MapGenSettings(size: .duel, seed: 11))
        func duelGame(placing: Bool) -> GameState {
            GameState.newGame(seed: 11, map: duel.map, startPositions: duel.startPositions, rules: c0,
                              mapSizeName: MapSize.duel.rawValue, placeTribalVillages: placing)
        }
        let asked = duelGame(placing: true), plain = duelGame(placing: false)
        #expect(asked == plain)
        #expect(asked.stateHash() == plain.stateHash())
        expectNone(asked, "duel seed 11")

        let large = MapGenerator.generate(MapGenSettings(size: .large, seed: 42))
        var headless = GameState.newGame(seed: 42, map: large.map, startPositions: large.startPositions, humanPlayers: [],
                                         rules: c0, mapSizeName: MapSize.large.rawValue, placeTribalVillages: true)
        DebugTools.spawnUnits(count: 300, seed: 42, in: &headless)
        for i in headless.players.indices { headless.players[i].gold = 1_000_000 }
        expectNone(headless, "large seed 42")
        #expect(headless.stateHash() == 0x6D9F_7234_C1DB_DC2E, // M2 2.1c naval (roads 0xBC93_26CB_1A9F_9024) (resources 0x9F24_0878_A03E_DA36) (2.1b 0xE472_7556_EE7F_970B) (0xD1F8_0F1F_CE0D_4014) (2.1a: 0x1640_6D53_F16E_6AB9) (0xFD8F_CBC6_4C98_2AD4 before)
                "turn-1 hash: 0x\(String(headless.stateHash(), radix: 16))")
    }
}

@Suite struct TribalVillageMemoryTests {
    /// Player 0's Warrior at (2,2) sees a tribal village placed at (3,2); one at (8,3) is in no
    /// one's sight.
    static func scene() throws -> (state: GameState, warrior: UnitID, near: HexCoord, far: HexCoord) {
        var state = makeTestState()
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(2, 2))
        let near = hex(3, 2), far = hex(8, 3)
        #expect(DebugTools.placeTribalVillage(at: near, in: &state))
        #expect(DebugTools.placeTribalVillage(at: far, in: &state))
        let t = try #require(state.map.index(of: far))
        #expect(state.players.allSatisfy { !$0.visible[t] })
        return (state, warrior, near, far)
    }

    static func index(_ state: GameState, _ hex: HexCoord) -> Int32 { Int32(state.map.index(of: hex)!) }

    /// What the player knows, as memory and as the view gives it (they must agree).
    static func known(_ state: GameState, _ player: Int) -> [Int32] {
        let memory = state.players[player].memory.tribalVillages
        let view = state.view(for: PlayerID(player))
        #expect(view.knownTribalVillages == (memory ?? []))
        #expect(memory.map { !$0.isEmpty && $0 == $0.sorted() && Set($0).count == $0.count } ?? true, "\(memory ?? [])")
        for t in 0..<state.map.tileCount {
            #expect(view.isKnownTribalVillage(state.map.coord(at: t)) == (memory?.contains(Int32(t)) ?? false))
        }
        return memory ?? []
    }

    /// One placed in sight enters memory; one out of sight does not, until it is seen.
    @Test func seenEntersMemory() throws {
        let scene = try Self.scene()
        var state = scene.state
        let near = scene.near, far = scene.far
        #expect(Self.known(state, 0) == [Self.index(state, near)])
        #expect(Self.known(state, 1).isEmpty && state.players[1].memory.tribalVillages == nil)
        // Player 1 comes to see the far one.
        state.addUnit(.scout, owner: PlayerID(1), at: hex(8, 4))
        #expect(Self.known(state, 1) == [Self.index(state, far)])
        #expect(Self.known(state, 0) == [Self.index(state, near)])
        expectSound(state)
    }

    /// One seen gone leaves memory, and an empty list is nil (absent from saves), never [].
    @Test func seenGoneLeavesMemory() throws {
        let scene = try Self.scene()
        var state = scene.state
        let near = scene.near
        removeTribalVillage(at: near, in: &state)
        #expect(state.players[0].memory.tribalVillages == nil)
        #expect(Self.known(state, 0).isEmpty && state.view(for: PlayerID(0)).knownTribalVillages == [])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.players[0].memory)) as? [String: Any])
        #expect(json["tribalVillages"] == nil)
        expectSound(state)
    }

    /// One taken out of the player's sight stays remembered until the player sees its tile
    /// again.
    @Test func takenOutOfSightStaysRemembered() throws {
        let scene = try Self.scene()
        var state = scene.state
        let warrior = scene.warrior, near = scene.near
        // The Warrior walks off to (0,2), three tiles from it.
        try apply(.moveUnit(unit: warrior, to: hex(0, 2)), &state)
        let t = try #require(state.map.index(of: near))
        #expect(!state.players[0].visible[t])
        removeTribalVillage(at: near, in: &state)
        #expect(Self.known(state, 0) == [Int32(t)])
        // Back in sight next turn, it is gone from memory too.
        try nextTurn(&state)
        try apply(.moveUnit(unit: warrior, to: hex(2, 2)), &state)
        #expect(state.players[0].visible[t])
        #expect(state.players[0].memory.tribalVillages == nil && Self.known(state, 0).isEmpty)
        expectSound(state)
    }

    /// The queries read memory only: two worlds that differ in a tribal village player 0 has
    /// never seen (and in gifts player 1 had) look the same to player 0, through every query;
    /// player 1 sees its own count.
    @Test func theViewIsTheSameWithAHiddenTribalVillage() throws {
        var plain = makeTestState()
        plain.addUnit(.warrior, owner: PlayerID(0), at: hex(2, 2))
        plain.addUnit(.scout, owner: PlayerID(1), at: hex(8, 4))
        var twin = plain
        #expect(DebugTools.placeTribalVillage(at: hex(8, 3), in: &twin))
        twin.tribalVillages?.gifts[1] = 2
        #expect(twin.players[1].memory.tribalVillages != nil)

        func queries(_ state: GameState, _ player: Int) -> [String] {
            let view = state.view(for: PlayerID(player))
            return ["\(view.knownTribalVillages)", "\(view.tribalVillageGiftsReceived)"]
                + (0..<view.tileCount).map { "\(view.isKnownTribalVillage(view.coord(at: $0)))" }
        }
        let a = observations(of: plain), b = observations(of: twin)
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) where x != y { Issue.record("\(x.0) differs: \(x.1) vs \(y.1)") }
        #expect(queries(plain, 0) == queries(twin, 0))
        #expect(twin.view(for: PlayerID(0)).tribalVillageGiftsReceived == 0)
        #expect(twin.view(for: PlayerID(1)).tribalVillageGiftsReceived == 2)
        #expect(plain.view(for: PlayerID(1)).tribalVillageGiftsReceived == 0)
        // Placed in player 0's sight instead, player 0 knows it.
        var seen = plain
        #expect(DebugTools.placeTribalVillage(at: hex(3, 2), in: &seen))
        #expect(queries(plain, 0) != queries(seen, 0))
    }
}

@Suite struct TribalVillageDebugToolTests {
    /// `placeTribalVillage` refuses what M1 §7.7 lists and otherwise inserts in tile order;
    /// `tribalVillages(in:)` lists the live ones.
    @Test func placingRefusesWhatItMust() throws {
        var state = makeTestState()
        let city = addCity(&state, PlayerID(0), at: hex(2, 2))
        let ring = try #require(state.map.neighbors(of: hex(2, 2)).first)
        #expect(state.tileCity[state.map.index(of: ring)!] == Int32(city.rawValue + 1))
        let before = state
        for refused in [hex(2, 2), ring, parkingSpot(0, in: state.map), hex(5, 3), hex(8, 6), hex(20, 3), hex(1, -1)] {
            #expect(!DebugTools.placeTribalVillage(at: refused, in: &state), "\(refused.offset)")
        }
        #expect(state == before && state.tribalVillages == nil)

        #expect(DebugTools.placeTribalVillage(at: hex(7, 5), in: &state))
        #expect(DebugTools.placeTribalVillage(at: hex(6, 1), in: &state))
        #expect(!DebugTools.placeTribalVillage(at: hex(7, 5), in: &state))
        let villages = try #require(state.tribalVillages)
        #expect(villages.sites == [hex(6, 1), hex(7, 5)].map { Int32(state.map.index(of: $0)!) })
        #expect(villages.gifts == [0, 0])
        #expect(DebugTools.tribalVillages(in: state) == [hex(6, 1), hex(7, 5)])
        // A forest is passable land.
        #expect(DebugTools.placeTribalVillage(at: hex(3, 6), in: &state))
        expectSound(state)

        // Rules without the section refuse every tile.
        var c0 = makeTestState(rules: try c0Rules())
        #expect(!DebugTools.placeTribalVillage(at: hex(7, 5), in: &c0) && c0.tribalVillages == nil)
    }

    /// `primeBorderGrowth`: the owner's next phase start grows the city's borders onto the tile
    /// it returned (without it, not yet).
    @Test func primedBordersTakeTheReturnedTile() throws {
        var state = makeTestState()
        let city = addCity(&state, PlayerID(0), at: hex(2, 2))
        var unprimed = state
        let tile = try #require(DebugTools.primeBorderGrowth(of: city, in: &state))
        let t = try #require(state.map.index(of: tile))
        let culture = state.cityYields(try #require(state.city(city))).total.culture
        #expect(culture > 0 && state.tileCity[t] == 0)
        #expect(state.city(city)?.cultureStore == state.rules.borderThreshold(tilesGained: 0) - culture)
        #expect(DebugTools.primeBorderGrowth(of: city, in: &state) == tile) // the same again

        var records: [EventRecord] = []
        repeat {
            records += try GameEngine.apply(.endTurn, by: state.currentPlayer, to: &state)
        } while state.currentPlayer != PlayerID(0)
        #expect(state.tileCity[t] == Int32(city.rawValue + 1))
        #expect(state.city(city)?.tilesGained == 1 && state.city(city)?.cultureStore == 0)
        #expect(records.contains { $0.event == .borderGrew(city: city, tile: tile) })
        try nextTurn(&unprimed)
        #expect(unprimed.tileCity[t] == 0 && unprimed.city(city)?.tilesGained == 0)
        expectSound(state)
    }

    /// Nil, with nothing changed: an unknown city, or one with no tile left to take.
    @Test func primingRefusesWhatItCannot() throws {
        var state = makeTestState()
        let city = addCity(&state, PlayerID(0), at: hex(2, 2))
        let before = state
        #expect(DebugTools.primeBorderGrowth(of: CityID(99), in: &state) == nil && state == before)
        let code = Int32(city.rawValue + 1)
        for t in state.map.coords(within: state.rules.constants.borders.radius + 1, of: hex(2, 2)).compactMap(state.map.index(of:)) {
            state.tileCity[t] = code
        }
        let full = state
        #expect(DebugTools.primeBorderGrowth(of: city, in: &state) == nil && state == full)
    }
}

@Suite struct TribalVillageEventTests {
    /// `tribalVillageTaken` goes to the taker and every player who sees the tile;
    /// `tribalVillageGift` to the taker only (M1 §12.5).
    @Test func audiences() throws {
        var state = makeTestState(players: 3)
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(3, 3))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(4, 2))
        let site = hex(3, 2)
        let t = try #require(state.map.index(of: site))
        #expect(state.players[0].visible[t] && state.players[1].visible[t] && !state.players[2].visible[t])
        let before = state.players.map(\.visible)

        var fx = Effects()
        fx.emitTribalVillageTaken(at: t, hex: site, player: PlayerID(0), unit: scout, city: nil)
        fx.emitTribalVillageGift(player: PlayerID(0), at: site, gift: .gold(50))
        // A player who does not see the tile still hears of its own take and gift.
        fx.emitTribalVillageTaken(at: t, hex: site, player: PlayerID(2), unit: nil, city: CityID(4))
        fx.emitTribalVillageGift(player: PlayerID(2), at: site, gift: .builder(UnitID(9)))
        let records = fx.records(before: before, after: state)
        #expect(records.map(\.event) == [
            .tribalVillageTaken(at: site, player: PlayerID(0), unit: scout, city: nil),
            .tribalVillageGift(player: PlayerID(0), at: site, gift: .gold(50)),
            .tribalVillageTaken(at: site, player: PlayerID(2), unit: nil, city: CityID(4)),
            .tribalVillageGift(player: PlayerID(2), at: site, gift: .builder(UnitID(9))),
        ])
        #expect(records.map(\.audience) == [0b011, 0b001, 0b111, 0b100])
        #expect(!records[1].isVisible(to: PlayerID(1)) && records[0].isVisible(to: PlayerID(1)))
    }

    /// The new events encode and decode (records are kept by the App's notice log).
    @Test func eventsRoundTrip() throws {
        let at = hex(3, 2)
        let events: [GameEvent] = [
            .tribalVillageTaken(at: at, player: PlayerID(1), unit: UnitID(7), city: nil),
            .tribalVillageTaken(at: at, player: PlayerID(0), unit: nil, city: CityID(2)),
            .tribalVillageGift(player: PlayerID(1), at: at, gift: .gold(50)),
            .tribalVillageGift(player: PlayerID(1), at: at, gift: .science(20, toward: "pottery")),
            .tribalVillageGift(player: PlayerID(1), at: at, gift: .science(20, toward: nil)),
            .tribalVillageGift(player: PlayerID(1), at: at, gift: .builder(UnitID(12))),
        ]
        let records = events.map { EventRecord($0, audience: 0b10) }
        let decoded = try JSONDecoder().decode([EventRecord].self, from: JSONEncoder().encode(records))
        #expect(decoded == records)
        let sites = [TribalVillageSite(hex: at, start: 1), TribalVillageSite(hex: hex(5, 5), start: nil)]
        #expect(try JSONDecoder().decode([TribalVillageSite].self, from: JSONEncoder().encode(sites)) == sites)
    }
}
