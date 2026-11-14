import Foundation
@testable import GameCore
import Testing
@testable import Persistence

// G11 (phase 3g, tribal villages; M1 §14): a real save of format version 1 written before
// tribal villages existed, by the post-3f tree (snapshot p3fs): Duel seed 11, AI against AI,
// saved at the start of turn 30 (Fixtures/v1-duel-11-t30.json says how, with the state hash and
// the rules' content hash recorded then). Tribal villages came as additive optional fields, so
// the format stays at 1 and such a save still opens. The M1 rules it was made with no longer
// validate (M2 added unit types, and every type needs a definition), so M1 saves are best
// effort (M2-D4): the trimmed M1 rules data still hashes to the recorded content hash (the
// fixture's provenance), and C0 (those rules with M2's units appended) opens it with the
// rules-changed warning and round trips it; under the standard rules it opens with the warning,
// without any tribal village, and with its state's hash under those rules.

/// The version-1 fixture and what was recorded when it was written.
struct LegacySave {
    var bytes: Data
    var stateHash: UInt64
    var contentHash: UInt64
    var seed: UInt64
    var turn: Int
    var phaseCount: Int
    var currentPlayer: Int

    static let name = "v1-duel-11-t30"

    static func load() throws -> LegacySave {
        let file = try #require(Bundle.module.url(forResource: name, withExtension: "ttys", subdirectory: "Fixtures"))
        let facts = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: facts)) as? [String: Any])
        func hash(_ key: String) throws -> UInt64 {
            let text = try #require(json[key] as? String)
            return try #require(UInt64(text.dropFirst(2), radix: 16), "\(key): \(text)")
        }
        func int(_ key: String) throws -> Int { try #require(json[key] as? Int, "\(key)") }
        #expect(json["formatVersion"] as? Int == 1 && json["rulesID"] as? String == "m1.1" && json["mapSize"] as? String == "duel")
        return LegacySave(bytes: try Data(contentsOf: file), stateHash: try hash("stateHash"), contentHash: try hash("contentHash"),
                          seed: UInt64(try int("seed")), turn: try int("turn"), phaseCount: try int("phaseCount"),
                          currentPlayer: try int("currentPlayer"))
    }

    /// Writes the file (or `bytes` in its place) into the saves directory; returns its URL.
    func install(in saves: TempSaves, bytes: Data? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: saves.url, withIntermediateDirectories: true)
        let url = saves.url.appending(path: Self.name + ".ttys")
        try (bytes ?? self.bytes).write(to: url)
        return url
    }

    /// The standard rules data as it was when the fixture was saved: without its tribal
    /// village section, without M2's eras, progression, Insights and later techs (M2 2.1a), and
    /// without M2's units, promotions and wall damage (2.1b), and without M2's resources,
    /// stockpiles, resource improvements and roads (2.1c). It no longer validates (every unit
    /// type needs a definition); its hash is the recorded content hash.
    static func m1Data() throws -> RulesetData { try decode(m1Object().m1) }

    /// C0: the M1 rules data with M2's units appended (needing no tech), and M2's resources,
    /// stockpiles and improvements (without their later techs), so that it validates.
    static func c0() throws -> Ruleset { try Ruleset(data: decode(m1Object().playable)) }

    private static func decode(_ object: [String: Any]) throws -> RulesetData {
        try JSONDecoder().decode(RulesetData.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static func m1Object() throws -> (m1: [String: Any], playable: [String: Any]) {
        var json = try standardRulesObject()
        let m2Resources = json["resources"], m2Stockpile = json["stockpile"]
        json.removeValue(forKey: "resources")
        json.removeValue(forKey: "stockpile")
        // M2 2.1c roads (M2 §3.3).
        json.removeValue(forKey: "roads")
        let improvements = json["improvements"] as? [[String: Any]] ?? []
        json["improvements"] = improvements.prefix(3).map { imp in imp.filter { !["resources", "techBonuses"].contains($0.key) } }
        for key in ["tribalVillages", "eras", "progression", "promotions", "promotionXP"] { json.removeValue(forKey: key) }
        var constants = json["constants"] as? [String: Any] ?? [:]
        var combat = constants["combat"] as? [String: Any] ?? [:]
        combat.removeValue(forKey: "wallDamagePct")
        constants["combat"] = combat
        json["constants"] = constants
        let m1Techs = ["pottery", "mining", "animalHusbandry", "sailing", "writing", "irrigation",
                       "archery", "bronzeWorking", "masonry", "currency"]
        let techs = (json["techs"] as? [[String: Any]] ?? []).filter { m1Techs.contains($0["id"] as? String ?? "") }
        json["techs"] = techs.map { tech in tech.filter { $0.key != "era" && $0.key != "insight" } }
        var ai = json["ai"] as? [String: Any] ?? [:]
        ai["researchOrderPeace"] = ["pottery", "animalHusbandry", "mining", "irrigation", "writing", "bronzeWorking",
                                    "archery", "masonry", "sailing", "currency"]
        ai["researchOrderWar"] = ["mining", "bronzeWorking", "animalHusbandry", "archery", "masonry", "pottery",
                                  "writing", "irrigation", "currency", "sailing"]
        json["ai"] = ai
        let units = json["units"] as? [[String: Any]] ?? []
        let m1Units = units.prefix(6).map { unit in
            var unit = unit.filter { !["upgradesTo", "rangedAfterMove", "wallDamagePct", "resource", "vsCity"].contains($0.key) }
            if unit["type"] as? String == "spearman" { unit["classBonuses"] = [["against": "cavalry", "strength": 10]] }
            return unit
        }
        var m1 = json
        m1["units"] = Array(m1Units)
        var playable = json
        playable["units"] = Array(m1Units) + units.dropFirst(6).map { unit in unit.filter { $0.key != "tech" } }
        playable["resources"] = m2Resources
        playable["stockpile"] = m2Stockpile
        playable["improvements"] = improvements.map { imp in
            imp.filter { $0.key != "techBonuses" && !($0.key == "tech" && imp["name"] as? String == "lumberMill") }
        }
        return (m1, playable)
    }
}

@Suite struct LegacySaveTests {
    /// The fixture is a version-1 file; the format is still version 1; the M1 rules data hashes
    /// to the content hash recorded with it, and C0's and the standard rules' differ.
    @Test func theFixtureIsAVersion1SaveFromBeforeTribalVillages() throws {
        let legacy = try LegacySave.load()
        let bytes = [UInt8](legacy.bytes)
        #expect(Array(bytes[0..<4]) == SaveStore.signature)
        #expect(UInt16(bytes[4]) | UInt16(bytes[5]) << 8 == 1)
        #expect(SaveStore.formatVersion == 1)
        let c0 = try LegacySave.c0()
        #expect(StableHash.of(try LegacySave.m1Data()) == legacy.contentHash)
        #expect(c0.tribalVillages == nil && c0.contentHash != legacy.contentHash)
        #expect(Ruleset.standard.tribalVillages != nil && Ruleset.standard.contentHash != legacy.contentHash)
    }

    /// Listed like any save of this version; nothing about it is unreadable.
    @Test func itIsListedAsReadable() async throws {
        let legacy = try LegacySave.load()
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let url = try legacy.install(in: saves)
        let store = saves.store()
        let listed = try await store.list()
        #expect(listed.map(\.url) == [url])
        let summary = try #require(listed.first)
        #expect(summary.turn == legacy.turn && summary.seed == legacy.seed && summary.rulesID == "m1.1" && summary.mapSizeName == "duel")
        #expect(summary.currentPlayer == PlayerID(legacy.currentPlayer))
        #expect(try await store.listUnreadable().isEmpty)
    }

    /// Under C0 it opens with the rules-changed warning, at the recorded turn, phase, seed and
    /// player, its invariants kept; saved again and reopened, it is the same state with the same
    /// hash, and without the warning.
    @Test func underC0ItOpensWithAWarningAndRoundTrips() async throws {
        let legacy = try LegacySave.load()
        let saves = TempSaves()
        defer { saves.cleanUp() }
        _ = try legacy.install(in: saves)
        let store = saves.store()
        let summary = try #require(try await store.list().first)
        let loaded = try await store.open(summary, rules: try LegacySave.c0())
        #expect(loaded.warnings == [.rulesDataChanged(rulesID: "m1.1")])
        let state = loaded.state
        #expect(state.rulesRef.savedContentHash == legacy.contentHash)
        #expect(state.turn == legacy.turn && state.phaseCount == legacy.phaseCount && state.seed == legacy.seed)
        #expect(state.currentPlayer == PlayerID(legacy.currentPlayer))
        #expect(state.tribalVillages == nil && state.players.allSatisfy { $0.memory.tribalVillages == nil })
        #expect(!state.units.isEmpty && !state.cities.isEmpty && state.players.count == 2)
        #expect(state.checkInvariants().isEmpty)

        let again = try await store.save(state, name: "Again", kind: .manual)
        let reopened = try await store.open(again, rules: try LegacySave.c0())
        #expect(reopened.warnings.isEmpty && reopened.state == state && reopened.state.stateHash() == state.stateHash())
    }

    /// Under the standard rules it opens with the rules-changed warning, every field as saved,
    /// no tribal village (live or remembered), its invariants kept, and the hash of that state
    /// under the standard rules. Saved again, it opens without the warning and with that hash;
    /// played on, it never gains a tribal village.
    @Test func underTheStandardRulesItOpensWithAWarning() async throws {
        let legacy = try LegacySave.load()
        let saves = TempSaves()
        defer { saves.cleanUp() }
        _ = try legacy.install(in: saves)
        let store = saves.store()
        let summary = try #require(try await store.list().first)
        let loaded = try await store.open(summary, rules: .standard)
        #expect(loaded.warnings == [.rulesDataChanged(rulesID: "m1.1")])
        let state = loaded.state
        #expect(state.rules === Ruleset.standard && state.rulesRef.contentHashChanged)
        #expect(state.rulesRef.savedContentHash == legacy.contentHash)
        #expect(state.tribalVillages == nil && DebugTools.tribalVillages(in: state).isEmpty)
        #expect(state.players.allSatisfy { $0.memory.tribalVillages == nil })
        #expect(state.players.indices.allSatisfy { state.view(for: PlayerID($0)).knownTribalVillages.isEmpty })
        #expect(state.checkInvariants().isEmpty)
        #expect(state.stateHash() != legacy.stateHash)

        // The same state as under C0 but for the rules it plays by.
        let asSaved = try await store.open(summary, rules: try LegacySave.c0()).state
        func fields(_ state: GameState) throws -> [String: Any] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
            json.removeValue(forKey: "rulesRef")
            return json
        }
        #expect(NSDictionary(dictionary: try fields(state)) == NSDictionary(dictionary: try fields(asSaved)))

        // Saved again under the standard rules, it opens without the warning and keeps the hash.
        let again = try await store.save(state, name: "Again", kind: .manual)
        let reopened = try await store.open(again, rules: .standard)
        #expect(reopened.warnings.isEmpty && reopened.state == state && reopened.state.stateHash() == state.stateHash())

        // Played on, it never gains a tribal village.
        var later = state
        for _ in 0..<6 { PersistenceFixture.playPhase(&later) }
        #expect(later.tribalVillages == nil && later.players.allSatisfy { $0.memory.tribalVillages == nil })
        #expect(later.checkInvariants().isEmpty)
    }

    /// A game with tribal villages (the populated fixture: two, with gifts given, one
    /// remembered) round trips with everything kept.
    @Test func aRoundTripKeepsTribalVillages() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let state = PersistenceFixture.populated()
        let villages = try #require(state.tribalVillages)
        #expect(villages.sites.count == 2 && villages.gifts.contains { $0 > 0 })
        #expect(state.players.contains { $0.memory.tribalVillages != nil })
        let summary = try await store.save(state, name: "Tribal villages", kind: .manual)
        let loaded = try await store.open(summary, rules: .standard)
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.state == state && loaded.state.stateHash() == state.stateHash())
        #expect(loaded.state.tribalVillages == villages)
        #expect(loaded.state.players.map(\.memory.tribalVillages) == state.players.map(\.memory.tribalVillages))
    }

    /// The version-1 file with its version patched to 2 is refused and listed apart, as another
    /// version's file; nothing about the listing changed.
    @Test func version2IsStillRefused() async throws {
        let legacy = try LegacySave.load()
        let saves = TempSaves()
        defer { saves.cleanUp() }
        var bytes = [UInt8](legacy.bytes)
        bytes[4] = 2
        bytes[5] = 0
        let url = try legacy.install(in: saves, bytes: Data(bytes))
        let store = saves.store()
        #expect(try await store.list().isEmpty)
        let unreadable = try await store.listUnreadable()
        #expect(unreadable.map(\.url) == [url])
        #expect(unreadable.first?.reason == .unsupportedFormat(found: 2, supported: 1))
        #expect(unreadable.first?.isOtherVersion == true && unreadable.first?.summary?.turn == legacy.turn)
        let summary = try #require(unreadable.first?.summary)
        await #expect(throws: SaveError.unsupportedFormat(found: 2, supported: 1)) {
            try await store.open(summary, rules: .standard)
        }
    }
}
