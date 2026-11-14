import Foundation
import Testing
@testable import GameCore

// Save compatibility and hash coverage (core-3 audit of M1 §12.3, §12.7): a game with every
// optional set and every enum case survives a JSON round trip unchanged, and every field the
// encoding carries feeds `stateHash()`.

enum SaveFixture {
    /// A small wrapping map holding every terrain, elevation, feature and improvement, rivers.
    static func map() -> HexMap {
        var map = HexMap(width: 10, height: 8, wrapsX: true, fill: Tile(terrain: .grassland))
        map[hex(0, 0)] = Tile(terrain: .grassland, riverEdges: 0b0000_0011, improvement: .farm)
        for (i, terrain) in Terrain.allCases.enumerated() { map[hex(i, 7)] = Tile(terrain: terrain) }
        for (i, feature) in Feature.allCases.enumerated() {
            let terrain: Terrain = feature == .reef ? .coast : feature == .ice ? .snow : feature == .oasis ? .desert : .grassland
            map[hex(i, 6)] = Tile(terrain: terrain, feature: feature)
        }
        for (i, elevation) in Elevation.allCases.enumerated() { map[hex(i, 5)] = Tile(terrain: .plains, elevation: elevation) }
        map[hex(1, 5)] = Tile(terrain: .plains, elevation: .hills, improvement: .mine)
        map[hex(4, 5)] = Tile(terrain: .plains, improvement: .pasture)
        return map
    }

    /// Three players at turn 3: player 0 at war with 1 (a peace proposal pending, cool-downs
    /// running) and at peace with 2; four cities with every focus, one captured; a unit of
    /// every type, every activity, a standing order, a zone-of-control stop; research with a
    /// target; memory of cities and units; two tribal villages, one in player 0's sight (so
    /// remembered) and one out of everyone's, with gifts given; `outcome` as given.
    static func populated(outcome: GameOutcome? = .victory(player: PlayerID(0), kind: .domination)) -> GameState {
        let map = map()
        let players = (0..<3).map { i in
            Player(id: PlayerID(i), name: "P\(i)", isHuman: i == 0, tileCount: map.tileCount,
                   civ: ["rome", "mongols", "mali"][i], gold: 50 + i)
        }
        var state = GameState(seed: 0xC0FF_EE00_1234, map: map, players: players, rules: .standard, mapSizeName: "duel")
        let c0 = addCity(&state, PlayerID(0), at: hex(3, 2))
        let c1 = addCity(&state, PlayerID(1), at: hex(7, 2))
        let c2 = addCity(&state, PlayerID(2), at: hex(5, 4))
        let c3 = addCity(&state, PlayerID(1), at: hex(9, 4))

        // Units: every type and activity.
        let settler = state.addUnit(.settler, owner: PlayerID(0), at: hex(2, 2))
        let builder = state.addUnit(.builder, owner: PlayerID(0), at: hex(3, 3))
        let scout = state.addUnit(.scout, owner: PlayerID(0), at: hex(6, 2))
        let warrior = state.addUnit(.warrior, owner: PlayerID(0), at: hex(3, 2))
        let archer = state.addUnit(.archer, owner: PlayerID(0), at: hex(2, 1))
        let spearman = state.addUnit(.spearman, owner: PlayerID(0), at: hex(5, 4))
        state.addUnit(.warrior, owner: PlayerID(1), at: hex(8, 2))
        state.addUnit(.settler, owner: PlayerID(2), at: hex(1, 3))
        for (i, type) in UnitType.allCases.dropFirst(6).enumerated() { state.addUnit(type, owner: PlayerID(0), at: hex(i + 1, 0)) }
        state.updateUnit(settler) { u in
            u.activity = .sleeping
            u.destination = hex(1, 1)
        }
        state.updateUnit(builder) { u in
            u.activity = .skipped
            u.charges = 2
        }
        state.updateUnit(scout) { u in
            u.zocStopped = true
            u.xp = 3
            u.movesLeft = 1
            u.lastActedTurn = 3
        }
        state.updateUnit(warrior) { u in
            u.activity = .fortified
            u.hp = 70
            u.xp = 5
            u.promotions = ["tortoise"]
            u.attacked = true
        }
        state.updateUnit(archer) { $0.activity = .fortifying }
        state.updateUnit(spearman) { $0.lastActedTurn = 2 }

        // Cities: every focus, queue kinds, walls, damage, a capture.
        updateCity(&state, c0) { c in
            c.population = 3
            c.foodStore = 7
            c.queue = [QueueEntry(.unit(.settler), progress: 5), QueueEntry(.building("granary"))]
            c.storedProgress = 4
            c.buildings = ["monument", "palace", "walls"]
            c.cultureStore = 3
            c.tilesGained = 1
            c.focus = .food
            c.hp = 180
            c.wallHP = 60
            c.lastAttackedPhase = 4
            c.bombarded = true
        }
        updateCity(&state, c1) { c in
            c.focus = .production
            c.queue = [QueueEntry(.unit(.archer), progress: 1)]
        }
        updateCity(&state, c2) { c in
            // Player 2's first city, taken by player 0 in turn 2.
            c.owner = PlayerID(0)
            c.focus = .gold
            c.capturedTurn = 2
            c.buildings = ["monument"]
        }
        updateCity(&state, c3) { $0.focus = .balanced }
        state.players[2].capital = nil
        for index in state.cities.indices { state.assignCitizens(index) }

        // Research, relations, phases.
        state.players[0].knownTechs = ["animalHusbandry", "pottery"]
        state.players[0].researching = TechID("mining")
        state.players[0].researchTarget = TechID("masonry")
        state.players[0].researchProgress = 9
        // Insight credit and Insights fired (M2 §6.2, additive fields).
        state.players[0].techCredit = Array(repeating: 0, count: state.rules.techs.count)
        state.players[0].techCredit![state.rules.techIndex("writing")!] = 18
        state.players[0].insights = ["writing"]
        state.players[0].lastPhaseStart = 7
        state.players[1].lastPhaseStart = 8
        state.players[2].lastPhaseStart = 6
        state.updateRelation(PlayerID(0), PlayerID(1)) { r in
            r.met = true
            r.stance = .war
            r.since = 1
            r.proposalFrom = PlayerID(0)
            r.aCooldownEnds = 13
            r.bCooldownEnds = 11
        }
        state.updateRelation(PlayerID(0), PlayerID(2)) { r in
            r.met = true
            r.since = 2
        }
        state.turn = 3
        state.phaseCount = 8
        state.currentPlayer = PlayerID(1)

        // Tribal villages (M1 §7.7): (4,1) in player 0's sight, (0,7) in no one's.
        for site in [hex(4, 1), hex(0, 7)] {
            let placed = DebugTools.placeTribalVillage(at: site, in: &state)
            precondition(placed, "SaveFixture: no tribal village at \(site.offset)")
        }
        state.tribalVillages?.gifts = [2, 1, 0]
        refreshKnowledge(&state)
        state.outcome = outcome
        return state
    }

    static let outcomes: [GameOutcome?] = [
        .victory(player: PlayerID(0), kind: .domination), .victory(player: PlayerID(1), kind: .lastStanding),
        .victory(player: PlayerID(2), kind: .score), .defeat, nil,
    ]

    static func decoder(_ rules: Ruleset = .standard) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.ruleset] = rules
        return decoder
    }
}

@Suite struct SaveCompatibilityTests {
    /// The fixture really sets every optional and uses every enum case.
    @Test func theFixtureIsFullyPopulated() {
        let state = SaveFixture.populated()
        let tiles = state.map.tiles
        #expect(Set(tiles.map(\.terrain)) == Set(Terrain.allCases))
        #expect(Set(tiles.map(\.elevation)) == Set(Elevation.allCases))
        #expect(Set(tiles.map(\.feature)) == Set(Feature.allCases))
        #expect(Set(tiles.compactMap(\.improvement)) == Set(Improvement.allCases))
        #expect(tiles.contains { $0.riverEdges != 0 } && state.map.wrapsX)
        #expect(Set(state.units.map(\.type)) == Set(UnitType.allCases))
        #expect(Set(state.units.map(\.activity.rawValue)) == ["none", "fortifying", "fortified", "sleeping", "skipped"])
        #expect(state.units.contains { $0.destination != nil } && state.units.contains(where: \.zocStopped))
        #expect(state.units.contains { $0.xp > 0 } && state.units.contains { $0.charges > 0 } && state.units.contains { $0.lastActedTurn > 0 })
        #expect(Set(state.cities.map(\.focus)) == Set(CityFocus.allCases))
        #expect(state.cities.contains { $0.capturedTurn != nil } && state.cities.contains(where: \.bombarded))
        #expect(state.cities.contains { $0.originalOwner != $0.owner } && state.cities.contains { $0.wallHP > 0 })
        let items = state.cities.flatMap(\.queuedItems)
        #expect(items.contains { if case .unit = $0 { true } else { false } } && items.contains { if case .building = $0 { true } else { false } })
        let p0 = state.players[0]
        #expect(p0.researching != nil && p0.researchTarget != nil && p0.originalCapital != nil && p0.capital != nil)
        #expect(p0.techCredit != nil && p0.insights?.isEmpty == false && state.worldEra != nil)
        #expect(!p0.memory.cities.isEmpty && !p0.memory.units.isEmpty && p0.memory.tileImprovement.contains { $0 != 0 })
        // Tribal villages: the live state with gifts, and one remembered.
        #expect(state.tribalVillages.map { $0.sites.count == 2 && $0.gifts.contains { $0 > 0 } } == true)
        #expect(p0.memory.tribalVillages?.isEmpty == false)
        #expect(state.relations.contains { $0.stance == .war } && state.relations.contains { $0.stance == .peace })
        #expect(state.relations.contains { $0.since != nil } && state.relations.contains { $0.proposalFrom != nil })
        #expect(state.outcome != nil && !state.mapSizeName.isEmpty)
    }

    /// JSON with the ruleset in `userInfo` gives back an equal state with an equal hash, for
    /// every outcome; encoding again gives the same bytes.
    @Test func roundTripKeepsEverything() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for outcome in SaveFixture.outcomes {
            let state = SaveFixture.populated(outcome: outcome)
            let data = try encoder.encode(state)
            let decoded = try SaveFixture.decoder().decode(GameState.self, from: data)
            #expect(decoded == state, "\(String(describing: outcome))")
            #expect(decoded.stateHash() == state.stateHash(), "\(String(describing: outcome))")
            #expect(try encoder.encode(decoded) == data)
            #expect(decoded.rules === Ruleset.standard && !decoded.rulesRef.contentHashChanged)
            #expect(decoded.view(for: PlayerID(0)).dangerMap() == state.view(for: PlayerID(0)).dangerMap())
        }
    }

    /// A save made under the same rules id but other rules data loads, flagged for the warning
    /// (M1 §12.3); another rules id is refused.
    @Test func changedRulesDataLoadsWithAWarning() throws {
        let state = SaveFixture.populated()
        let data = try JSONEncoder().encode(state)
        var json = try standardRulesJSON()
        edit(&json, "units", 3, "cost", 41)
        let tuned = try loadRules(json)
        #expect(tuned.id == Ruleset.standard.id && tuned.contentHash != Ruleset.standard.contentHash)
        let loaded = try SaveFixture.decoder(tuned).decode(GameState.self, from: data)
        #expect(loaded.rules === tuned && loaded.rulesRef.contentHashChanged)
        #expect(loaded.rulesRef.savedContentHash == Ruleset.standard.contentHash)
        // Re-saving records the new rules.
        let again = try SaveFixture.decoder(tuned).decode(GameState.self, from: JSONEncoder().encode(loaded))
        #expect(!again.rulesRef.contentHashChanged)

        json["id"] = "m1.x"
        #expect(throws: RulesMismatch(saved: "m1.1", current: "m1.x")) {
            try SaveFixture.decoder(try loadRules(json)).decode(GameState.self, from: data)
        }
    }

    /// Every value the encoding carries feeds the hash: changing any leaf of the JSON (the
    /// first elements of long arrays, every element of short ones), or dropping any optional
    /// key, gives a state with another `stateHash()`. The one exception is by design: the
    /// recorded content hash of the rules (the hash covers the rules the state plays by).
    @Test func everyEncodedFieldFeedsTheHash() throws {
        let state = SaveFixture.populated()
        let base = state.stateHash()
        let data = try JSONEncoder().encode(state)
        let root = try JSONSerialization.jsonObject(with: data)
        let decoder = SaveFixture.decoder()
        var checked = 0, unchanged: [String] = [], undecodable: [String] = []

        func hashOf(_ object: Any) -> UInt64? {
            guard let bytes = try? JSONSerialization.data(withJSONObject: object),
                  let decoded = try? decoder.decode(GameState.self, from: bytes) else { return nil }
            return decoded.stateHash()
        }
        func replacing(_ node: Any, at path: ArraySlice<String>, with value: Any?) -> Any {
            guard let key = path.first else { return value as Any }
            if var dict = node as? [String: Any] {
                if path.count == 1, value == nil { dict.removeValue(forKey: key) } else {
                    dict[key] = replacing(dict[key]!, at: path.dropFirst(), with: value)
                }
                return dict
            }
            var array = node as! [Any]
            let i = Int(key)!
            array[i] = replacing(array[i], at: path.dropFirst(), with: value)
            return array
        }
        func check(_ path: [String], _ value: Any?) {
            let label = path.joined(separator: ".")
            guard let hash = hashOf(replacing(root, at: path[...], with: value)) else {
                undecodable.append(label)
                return
            }
            checked += 1
            if hash == base { unchanged.append(label) }
        }
        /// Another valid value for a string leaf: the next case of a string-backed enum, or
        /// the string with an "x" appended.
        func otherString(_ s: String) -> String {
            let families: [[String]] = [UnitType.allCases.map(\.rawValue), CityFocus.allCases.map(\.rawValue),
                                        ["none", "fortifying", "fortified", "sleeping", "skipped"], ["peace", "war"],
                                        ["domination", "lastStanding", "score"],
                                        Ruleset.standard.techs.map(\.id.rawValue), Ruleset.standard.buildings.map(\.id.rawValue),
                                        Ruleset.standard.civs.map(\.id.rawValue)]
            for family in families {
                if let i = family.firstIndex(of: s) { return family[(i + 1) % family.count] }
            }
            return s + "x"
        }
        func visit(_ node: Any, _ path: [String]) {
            if let dict = node as? [String: Any] {
                for key in dict.keys.sorted() {
                    visit(dict[key]!, path + [key])
                    // Dropping a key: decodes only for optionals, which must hash differently.
                    let label = (path + [key]).joined(separator: ".")
                    if let hash = hashOf(replacing(root, at: (path + [key])[...], with: nil)) {
                        checked += 1
                        if hash == base { unchanged.append(label + " (dropped)") }
                    }
                }
            } else if let array = node as? [Any] {
                let indices = array.count <= 12 ? Array(array.indices) : Array(array.indices.prefix(2))
                for i in indices { visit(array[i], path + [String(i)]) }
            } else if let number = node as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    check(path, NSNumber(value: !number.boolValue))
                } else if String(cString: number.objCType) == "Q" {
                    check(path, NSNumber(value: number.uint64Value ^ 1))
                } else {
                    check(path, NSNumber(value: number.int64Value ^ 1))
                }
            } else if let string = node as? String {
                check(path, otherString(string))
            }
        }
        #expect(hashOf(root) == base) // the JSON object itself round-trips
        visit(root, [])
        #expect(unchanged == ["rulesRef.contentHash"], "fields that do not feed the hash: \(unchanged)")
        #expect(checked > 300, "\(checked) mutations checked, \(undecodable.count) undecodable: \(undecodable.prefix(20))")
        print("everyEncodedFieldFeedsTheHash: \(checked) mutations checked, \(undecodable.count) undecodable")
        // The undecodable ones are the rules id and values a type rejects (an unknown raw value).
        #expect(undecodable.contains("rulesRef.id"))
    }
}
