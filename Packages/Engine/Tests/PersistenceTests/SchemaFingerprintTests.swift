import Foundation
import GameCore
import Testing
@testable import Persistence

// Save format versions (M1 §14): a save loads only in the format version it was written in,
// so the version must change whenever `GameState`'s encoding does. The fingerprint is a hash
// of the sorted key paths of a fully populated state (array elements merged as `[]`); any
// field added, removed or renamed anywhere in the state changes it.
//
// The one exception is an additive optional field: a field added later that is optional, nil
// in every state made before it existed (so its key is absent there), and that leaves every
// other field as it was. Older saves of the same version decode with it nil, and states
// without it encode exactly as before, so the version stays. Such fields are listed per
// version in `additivePaths`, with every key path below them: the fingerprint is taken over the
// fixture's paths minus these, and every one of them must be in the fixture. A field renamed,
// removed or added in any other way still changes the fingerprint. (Phase 3g's tribal villages
// were added this way: `GameState.tribalVillages` and `PlayerMemory.tribalVillages`.)
//
// When this test fails because the state's schema changed on purpose: bump
// `SaveStore.formatVersion` and add the new fingerprint (printed below) for the new version, or,
// for an additive optional field as above, list its paths in `additivePaths`.

@Suite struct SchemaFingerprintTests {
    /// Every format version and the schema it reads.
    static let fingerprints: [UInt16: UInt64] = [
        1: 0x083B_F3AB_2D95_C02F,
    ]

    /// Per format version: the key paths of its additive optional fields (see above), left out
    /// of the fingerprint and required in the fixture.
    static let additivePaths: [UInt16: [String]] = [
        // M2 2.1a: the world era and Insight credit (M2 §2, §6.2).
        // M2 2.1c: map resources and strategic stockpiles (M2 §3.1), roads and pillage (§3.3).
        // M2 2.2a: city Stability (M2 §5.2). M2 2.2b: quarters, queued quarters and their fixed cost (§5.3).
        1: ["cities[].quarters", "cities[].quarters[].kind", "cities[].quarters[].tile", "cities[].quarters[].tile.q",
            "cities[].quarters[].tile.r", "cities[].queue[].cost", "cities[].queue[].item.quarter", "cities[].queue[].item.quarter._0",
            "cities[].queue[].item.quarter.at", "cities[].queue[].item.quarter.at.q", "cities[].queue[].item.quarter.at.r",
            "cities[].stability", "cities[].loyalty", "cities[].freeCityLeader", "cities[].freeCityLeader.rawValue", "cities[].freeCityTurns", "players[].kind", "map.tiles[].pillaged", "map.tiles[].resource", "map.tiles[].road", "players[].insights", "players[].memory.tileRoad",
            "players[].memory.tileRoad.count", "players[].memory.tileRoad.words", "players[].memory.tribalVillages", "players[].stockpile",
            "players[].techCredit", "tribalVillages", "tribalVillages.gifts", "tribalVillages.sites", "units[].attacked",
            "units[].promotions", "worldEra"],
    ]

    /// The sorted key paths of a value's JSON encoding: object keys joined with ".", array
    /// elements merged under "[]".
    static func keyPaths(of data: Data) throws -> [String] {
        var paths = Set<String>()
        func visit(_ node: Any, _ path: String) {
            if let object = node as? [String: Any] {
                for (key, value) in object {
                    let child = path.isEmpty ? key : "\(path).\(key)"
                    paths.insert(child)
                    visit(value, child)
                }
            } else if let array = node as? [Any] {
                for element in array { visit(element, path + "[]") }
            }
        }
        visit(try JSONSerialization.jsonObject(with: data), "")
        return paths.sorted()
    }

    /// FNV-1a over the paths, one per line.
    static func fingerprint(_ paths: [String]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in paths.joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    @Test func theSchemaMatchesTheFormatVersion() throws {
        // Every outcome's shape, so a renamed case shows too.
        var union = Set<String>()
        for outcome in PersistenceFixture.outcomes {
            union.formUnion(try Self.keyPaths(of: JSONEncoder().encode(PersistenceFixture.populated(outcome: outcome))))
        }
        let all = union.sorted()
        let additive = Self.additivePaths[SaveStore.formatVersion] ?? []
        for path in additive {
            #expect(all.contains(path), "the fixture does not set the additive field \(path)")
        }
        let paths = all.filter { !additive.contains($0) }
        let fingerprint = Self.fingerprint(paths)
        let expected = Self.fingerprints[SaveStore.formatVersion]
        if fingerprint != expected {
            print("GameState schema (\(paths.count) key paths, \(additive.count) additive left out):\n" + paths.joined(separator: "\n"))
        }
        #expect(fingerprint == expected, """
            GameState's encoding changed (fingerprint 0x\(String(fingerprint, radix: 16))): bump SaveStore.formatVersion \
            and record the new fingerprint for it in SchemaFingerprintTests.fingerprints, or, for an additive optional \
            field (see the header), list its paths in SchemaFingerprintTests.additivePaths
            """)
        // The fixture reaches every corner of the schema: optionals set, every activity.
        for path in ["outcome.victory.kind", "outcome.defeat", "units[].destination.q", "cities[].capturedTurn", "cities[].queue[].item.unit._0",
                     "cities[].queue[].item.building._0", "relations[].proposalFrom.rawValue", "relations[].since",
                     "players[].researchTarget", "players[].originalCapital.rawValue", "players[].capital.rawValue",
                     "players[].memory.cities[].wallHP", "players[].memory.units[].turnSeen", "map.tiles[].improvement",
                     "tribalVillages.sites", "tribalVillages.gifts", "players[].memory.tribalVillages", "map.tiles[].resource",
                     "players[].stockpile", "map.tiles[].road", "map.tiles[].pillaged", "players[].memory.tileRoad",
                     "cities[].stability", "cities[].loyalty", "cities[].freeCityLeader", "cities[].freeCityTurns", "players[].kind", "cities[].quarters[].tile.q", "cities[].queue[].cost", "cities[].queue[].item.quarter.at.q"] {
            #expect(all.contains(path), "the fixture does not set \(path)")
        }
    }

    /// The header's schema is part of the format too.
    @Test func theHeaderSchemaIsFixed() throws {
        let summary = SaveSummary(url: URL(fileURLWithPath: "/tmp/a.ttys"), name: "n", kind: .auto, savedAt: Date(timeIntervalSinceReferenceDate: 0),
                                  turn: 1, currentPlayer: PlayerID(0), civName: "Rome", mapSizeName: "duel", seed: 1, rulesID: "m1.1")
        #expect(try Self.keyPaths(of: JSONEncoder().encode(summary)) == [
            "civName", "currentPlayer", "currentPlayer.rawValue", "kind", "mapSizeName", "name", "rulesID", "savedAt", "seed", "turn",
        ])
    }
}
