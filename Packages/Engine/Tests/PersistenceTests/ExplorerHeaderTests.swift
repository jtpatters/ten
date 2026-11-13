import Foundation
@testable import GameCore
import Testing
@testable import Persistence

// The App's Explore order in the save header (`SaveSummary.explorers`, M1 §14 and §16): stored
// with every kind of save, left out when there are none (so such a header is byte-for-byte what
// it was), and empty when a header without it is read (saves made before the order existed).
@Suite struct ExplorerHeaderTests {
    static let explorers = [SavedExplorer(unit: UnitID(5), knownEnemies: [UnitID(9), UnitID(12)]), SavedExplorer(unit: UnitID(7))]

    /// Manual saves, autosaves and background slots carry the explorers: the list shows them and
    /// loading returns them, with the game unchanged.
    @Test func everyKindOfSaveKeepsTheExplorers() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let state = PersistenceFixture.populated(outcome: nil)
        let written = [
            try await store.save(state, name: "Manual", kind: .manual, explorers: Self.explorers),
            try await store.autosave(state, explorers: Self.explorers),
            try await store.saveBackground(state, explorers: Self.explorers),
            try await store.save(state, name: "Auto by kind", kind: .auto, explorers: Self.explorers),
        ]
        let listed = try await store.list()
        #expect(listed.count == written.count)
        for summary in written {
            #expect(summary.explorers == Self.explorers)
            #expect(listed.first { $0.url == summary.url } == summary)
            let loaded = try await store.open(summary, rules: .standard)
            #expect(loaded.summary.explorers == Self.explorers && loaded.summary == summary)
            #expect(loaded.state.stateHash() == state.stateHash())
        }
    }

    /// Without explorers the header has no such key: its schema is the fixed one. With them the
    /// key holds each unit and the enemies it knows of, by id.
    @Test func theKeyIsStoredOnlyWhenThereAreExplorers() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let state = SaveStoreTests.bareGame(seed: 3)
        let plain = try await store.save(state, name: "Plain", kind: .manual)
        let exploring = try await store.save(state, name: "Exploring", kind: .manual, explorers: Self.explorers)
        let fixed = ["civName", "currentPlayer", "currentPlayer.rawValue", "kind", "mapSizeName", "name", "rulesID", "savedAt", "seed",
                     "turn"]
        #expect(try SchemaFingerprintTests.keyPaths(of: Self.header(of: plain.url)) == fixed)
        #expect(plain.explorers.isEmpty)
        #expect(try SchemaFingerprintTests.keyPaths(of: Self.header(of: exploring.url)) == (fixed + [
            "explorers", "explorers[].knownEnemies", "explorers[].knownEnemies[].rawValue", "explorers[].unit", "explorers[].unit.rawValue",
        ]).sorted())
        // An empty list is no list: the same header as none.
        let empty = SaveSummary(url: plain.url, name: plain.name, kind: plain.kind, savedAt: plain.savedAt, turn: plain.turn,
                                currentPlayer: plain.currentPlayer, civName: plain.civName, mapSizeName: plain.mapSizeName, seed: plain.seed,
                                rulesID: plain.rulesID, explorers: [])
        #expect(try Self.encoded(empty) == Self.encoded(plain))
    }

    /// A header written before the field existed reads with no explorers; an explorer stored
    /// without enemies reads with none.
    @Test func olderHeadersReadWithoutExplorers() throws {
        let url = URL(fileURLWithPath: "/tmp/Saves/auto-3-0-1.ttys")
        let decoder = JSONDecoder()
        decoder.userInfo[SaveSummary.fileURLKey] = url
        let old = #"""
            {"civName":"Rome","currentPlayer":{"rawValue":0},"kind":"auto","mapSizeName":"duel","name":"Rome – Turn 3",
             "rulesID":"m1.1","savedAt":0,"seed":7,"turn":3}
            """#
        let summary = try decoder.decode(SaveSummary.self, from: Data(old.utf8))
        #expect(summary.explorers.isEmpty && summary.turn == 3 && summary.url == url)

        let bare = #"""
            {"civName":"Rome","currentPlayer":{"rawValue":0},"kind":"auto","mapSizeName":"duel","name":"Rome – Turn 3",
             "rulesID":"m1.1","savedAt":0,"seed":7,"turn":3,"explorers":[{"unit":{"rawValue":4}}]}
            """#
        #expect(try decoder.decode(SaveSummary.self, from: Data(bare.utf8)).explorers == [SavedExplorer(unit: UnitID(4))])
    }

    /// The header JSON of a save file.
    static func header(of url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        let length = Int(UInt32(bytes[6]) | UInt32(bytes[7]) << 8 | UInt32(bytes[8]) << 16 | UInt32(bytes[9]) << 24)
        return data[10..<(10 + length)]
    }

    static func encoded(_ summary: SaveSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(summary)
    }
}
