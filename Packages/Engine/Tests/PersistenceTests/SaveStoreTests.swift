import Foundation
@testable import GameCore
import Synchronization
import Testing
@testable import Persistence

/// A clock for the store that moves a minute on at every save, so "newest" is unambiguous.
final class SteppingClock: Sendable {
    private let ticks = Mutex(0)

    func next() -> Date {
        ticks.withLock { tick in
            tick += 1
            return Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(tick) * 60)
        }
    }
}

/// A clock a test sets and moves by hand (it may step back).
final class SettableClock: Sendable {
    private let seconds: Mutex<TimeInterval>

    init(_ seconds: TimeInterval) {
        self.seconds = Mutex(seconds)
    }

    func now() -> Date { seconds.withLock { Date(timeIntervalSinceReferenceDate: $0) } }
    func advance(_ by: TimeInterval) { seconds.withLock { $0 += by } }
    func set(_ to: TimeInterval) { seconds.withLock { $0 = to } }
}

/// A fresh, empty saves directory, removed again by `cleanUp`.
struct TempSaves {
    let url = FileManager.default.temporaryDirectory.appending(path: "TTYSaves-\(UUID().uuidString)", directoryHint: .isDirectory)
    let clock = SteppingClock()

    func store() -> SaveStore {
        let clock = clock
        return SaveStore(directory: url, now: { clock.next() })
    }

    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The standard rules' JSON as an object, to derive rules that differ.
func standardRulesObject() throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Ruleset.standard.data)) as? [String: Any])
}

/// Rules from the standard data with `change` applied.
func rules(changing change: (inout [String: Any]) -> Void) throws -> Ruleset {
    var json = try standardRulesObject()
    change(&json)
    return try Ruleset(jsonData: JSONSerialization.data(withJSONObject: json))
}

@Suite struct SaveStoreTests {
    // MARK: Round trips

    /// A game with every field set comes back equal, with the same `stateHash()`, for every
    /// outcome; nothing to warn about.
    @Test func roundTripKeepsTheHash() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        for outcome in PersistenceFixture.outcomes {
            let state = PersistenceFixture.populated(outcome: outcome)
            #expect(state.checkInvariants().isEmpty, "\(state.checkInvariants())")
            let summary = try await store.save(state, name: "Fixture", kind: .manual)
            let loaded = try await store.open(summary, rules: .standard)
            #expect(loaded.state == state, "\(String(describing: outcome))")
            #expect(loaded.state.stateHash() == state.stateHash(), "\(String(describing: outcome))")
            #expect(loaded.warnings.isEmpty && loaded.summary == summary)
            #expect(loaded.state.rules === Ruleset.standard)
            // City Stability (M2 §5.2, additive) comes back as saved.
            #expect(state.cities.contains { $0.stability == -2 })
            #expect(loaded.state.cities.map(\.stability) == state.cities.map(\.stability))
        // Quarters, a queued quarter and its fixed cost (M2 §5.3, additive) come back as saved.
        #expect(state.cities.contains { $0.quarters?.isEmpty == false })
        #expect(state.cities.contains { $0.queue.contains { if case .quarter = $0.item { $0.cost != nil } else { false } } })
        #expect(loaded.state.cities.map(\.quarters) == state.cities.map(\.quarters))
        #expect(loaded.state.cities.map(\.queue) == state.cities.map(\.queue))
        // Loyalty and the Free Cities (M2 §5.5, §12.5, additive) come back as saved.
        #expect(state.freeCities != nil && state.cities.contains { $0.freeCityLeader != nil && $0.freeCityTurns != nil })
        #expect(loaded.state.players.map(\.kind) == state.players.map(\.kind))
        #expect(loaded.state.freeCities == state.freeCities)
        #expect(loaded.state.cities.map(\.loyalty) == state.cities.map(\.loyalty))
        #expect(state.cities.contains { $0.tilesBought != nil } && state.cities.contains { $0.specialists?.isEmpty == false })
        #expect(loaded.state.cities.map(\.tilesBought) == state.cities.map(\.tilesBought))
        #expect(loaded.state.cities.map(\.specialists) == state.cities.map(\.specialists))
        #expect(loaded.state.cities.map(\.freeCityLeader) == state.cities.map(\.freeCityLeader))
        #expect(loaded.state.cities.map(\.freeCityTurns) == state.cities.map(\.freeCityTurns))
        // Civics, government, policies and Influence (M2 §7, §4.3).
        #expect(state.players[0].knownCivics?.isEmpty == false && state.players[0].policies?.isEmpty == false)
        for (a, b) in zip(loaded.state.players, state.players) {
            #expect(a.studying == b.studying && a.civicTarget == b.civicTarget && a.civicProgress == b.civicProgress)
            #expect(a.knownCivics == b.knownCivics && a.civicInsights == b.civicInsights)
            #expect(a.government == b.government && a.governmentsAdopted == b.governmentsAdopted && a.policies == b.policies)
            #expect(a.freeChangeTurn == b.freeChangeTurn && a.influence == b.influence)
            #expect(a.envoyTokens == b.envoyTokens && a.envoysEarned == b.envoysEarned)
        }
            // The loaded game answers the same questions.
            let (a, b) = (loaded.state.view(for: PlayerID(0)), state.view(for: PlayerID(0)))
            #expect(a.dangerMap() == b.dangerMap() && a.knownCities == b.knownCities && a.income() == b.income())
        }
    }

    /// A real game (a Duel played 25 turns by random players: cities, combat, diplomacy)
    /// survives a save and load, and plays on exactly as if it had never stopped.
    @Test func loadingAndPlayingOnMatchesAnUninterruptedGame() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        var straight = PersistenceFixture.newGame(size: .duel, seed: 11)
        PersistenceFixture.play(&straight, untilTurn: 25, random: true)
        var resumed = PersistenceFixture.newGame(size: .duel, seed: 11)
        PersistenceFixture.play(&resumed, untilTurn: 12, random: true)
        // Saved mid-turn, in the second player's phase.
        PersistenceFixture.playPhase(&resumed, random: true)
        #expect(resumed.currentPlayer == PlayerID(1))
        let hash = resumed.stateHash()
        let summary = try await store.autosave(resumed)
        resumed = try await store.load(summary, rules: .standard)
        #expect(resumed.stateHash() == hash)
        PersistenceFixture.play(&resumed, untilTurn: 25, random: true)
        #expect(resumed.stateHash() == straight.stateHash())
        #expect(!straight.cities.isEmpty)
    }

    /// The bytes on disk follow M1 §14: signature, format version and header length (little
    /// endian), the header JSON, then the game as LZFSE-compressed JSON.
    @Test func fileLayout() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let state = PersistenceFixture.populated()
        let summary = try await saves.store().save(state, name: "Layout", kind: .manual)
        let data = try Data(contentsOf: summary.url)
        let bytes = [UInt8](data)
        #expect(Array(bytes[0..<4]) == Array("TTYS".utf8))
        #expect(UInt16(bytes[4]) | UInt16(bytes[5]) << 8 == SaveStore.formatVersion)
        let length = Int(UInt32(bytes[6]) | UInt32(bytes[7]) << 8 | UInt32(bytes[8]) << 16 | UInt32(bytes[9]) << 24)
        let header = data[10..<(10 + length)]
        let decoder = JSONDecoder()
        decoder.userInfo[SaveSummary.fileURLKey] = summary.url
        #expect(try decoder.decode(SaveSummary.self, from: header) == summary)
        #expect(!String(decoding: header, as: UTF8.self).contains(summary.url.lastPathComponent))
        let json = try (Data(data[(10 + length)...]) as NSData).decompressed(using: .lzfse) as Data
        #expect(try JSONDecoder().decode(GameState.self, from: json) == state)
        #expect(summary.name == "Layout" && summary.kind == .manual && summary.turn == 4 && summary.currentPlayer == PlayerID(1))
        #expect(summary.civName == "Rome" && summary.mapSizeName == "duel" && summary.seed == state.seed && summary.rulesID == "m1.1")
        #expect(SaveStore.defaultName(for: state) == "Rome – Turn 4")
    }

    // MARK: Slots

    /// Autosaves are named `auto-<turn>-<player>-<n>.ttys` and only the newest ten stay.
    @Test func autosavesRotate() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        var state = PersistenceFixture.newGame()
        var written: [SaveSummary] = []
        var hashes: [UInt64] = []
        for _ in 0..<13 {
            written.append(try await store.autosave(state))
            hashes.append(state.stateHash())
            PersistenceFixture.playPhase(&state)
        }
        #expect(written.map(\.url.lastPathComponent).prefix(4) == ["auto-1-0-1.ttys", "auto-1-1-2.ttys", "auto-2-0-3.ttys", "auto-2-1-4.ttys"])
        #expect(written.allSatisfy { $0.kind == .auto })
        let listed = try await store.list()
        #expect(listed.count == SaveStore.autosavesKept)
        #expect(listed == Array(written.suffix(10).reversed()))
        #expect(saves.files() == written.suffix(10).map(\.url.lastPathComponent).sorted())
        // The oldest three are gone; the newest still loads.
        for old in written.prefix(3) { #expect(!FileManager.default.fileExists(atPath: old.url.path)) }
        #expect(try await store.load(listed[0], rules: .standard).stateHash() == hashes[12])
        #expect(try await store.load(listed[9], rules: .standard).stateHash() == hashes[3])
        // Numbering carries on after the rotation (no name is reused).
        let next = try await store.autosave(state)
        #expect(next.url.lastPathComponent.hasSuffix("-14.ttys"))
    }

    /// The background slot is one file per game, overwritten.
    @Test func backgroundSlotIsOverwritten() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        var state = PersistenceFixture.newGame()
        let first = try await store.saveBackground(state)
        PersistenceFixture.play(&state, untilTurn: 3)
        let second = try await store.saveBackground(state)
        #expect(first.url == second.url && second.url.lastPathComponent == SaveStore.backgroundFileName(for: state))
        #expect(second.url.lastPathComponent == "background-7-duel-rome.ttys")
        #expect(saves.files() == [SaveStore.backgroundFileName(for: state)])
        let listed = try await store.list()
        #expect(listed == [second] && second.kind == .background && second.turn == 3)
        #expect(try await store.load(second, rules: .standard) == state)
    }

    /// Playing a second game never costs the first its resume point, and its autosaves only
    /// down to its newest two (review-lifecycle save-crossgame-1); coming back, the first game
    /// keeps ten again and the second keeps two.
    @Test func autosavesArePrunedPerGame() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        var a = PersistenceFixture.newGame(seed: 11)
        var aSaves: [SaveSummary] = []
        for _ in 0..<5 {
            aSaves.append(try await store.autosave(a))
            PersistenceFixture.play(&a, untilTurn: a.turn + 1)
        }
        // Moves in A's phase, then Quit to Menu: A's resume point.
        PersistenceFixture.playPhase(&a)
        let aBackground = try await store.saveBackground(a)

        var b = PersistenceFixture.newGame(seed: 12)
        var bSaves = [try await store.autosave(b)]
        let bBackground = try await store.saveBackground(b) // B backgrounded once
        #expect(aBackground.url != bBackground.url)
        var listed = try await store.list()
        #expect(listed.filter { $0.kind == .background }.map(\.url) == [bBackground.url, aBackground.url])
        #expect(try await store.load(aBackground, rules: .standard) == a)
        for _ in 0..<12 {
            PersistenceFixture.play(&b, untilTurn: b.turn + 1)
            bSaves.append(try await store.autosave(b))
        }
        listed = try await store.list()
        func autos(_ seed: UInt64) -> [SaveSummary] { listed.filter { $0.kind == .auto && $0.seed == seed } }
        #expect(autos(12) == Array(bSaves.suffix(10).reversed()))
        #expect(autos(11) == Array(aSaves.suffix(2).reversed()))
        #expect(listed.contains(aBackground) && listed.contains(where: { $0.url == bBackground.url }))
        #expect(listed.first == bSaves.last) // Continue: the newest save of any game

        // Back to A: it keeps ten again from here, and B keeps its newest two.
        let resumed = try await store.load(aBackground, rules: .standard)
        aSaves.append(try await store.autosave(resumed))
        listed = try await store.list()
        #expect(autos(11) == [aSaves[5], aSaves[4], aSaves[3]])
        #expect(autos(12) == Array(bSaves.suffix(2).reversed()))
    }

    /// Other games keep their two newest autosaves while at most forty are kept in all: the
    /// oldest games go first, never the one being played.
    @Test func autosavesAreCappedInAll() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        for seed in UInt64(1)...16 {
            for _ in 0..<3 { try await store.autosave(Self.bareGame(seed: seed)) }
        }
        var current: [SaveSummary] = []
        for _ in 0..<12 { current.append(try await store.autosave(Self.bareGame(seed: 99))) }
        let listed = try await store.list()
        #expect(listed.count == SaveStore.autosavesKeptInAll)
        #expect(listed.filter { $0.seed == 99 } == Array(current.suffix(10).reversed()))
        #expect(!listed.contains { $0.seed == 1 })
        for seed in UInt64(2)...16 { #expect(listed.filter { $0.seed == seed }.count == 2, "game \(seed)") }
    }

    /// The clock stepping back an hour (review-lifecycle save-clock-1): the autosave just
    /// written stays, and the oldest by serial goes.
    @Test func pruningFollowsSerialsNotTheClock() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let clock = SettableClock(800_000_000)
        let store = SaveStore(directory: saves.url, now: { clock.now() })
        var state = PersistenceFixture.newGame(seed: 9)
        var written: [SaveSummary] = []
        for _ in 0..<10 {
            clock.advance(60)
            written.append(try await store.autosave(state))
            PersistenceFixture.play(&state, untilTurn: state.turn + 1)
        }
        clock.set(800_000_000 - 3600)
        let newest = try await store.autosave(state)
        #expect(FileManager.default.fileExists(atPath: newest.url.path))
        #expect(!FileManager.default.fileExists(atPath: written[0].url.path))
        let autos = try await store.list().filter { $0.kind == .auto }
        #expect(Set(autos.map(\.url)) == Set((written.dropFirst() + [newest]).map(\.url)))
        #expect(try await store.load(newest, rules: .standard) == state)
    }

    /// Background slots: one per game; the legacy shared slot goes once its game has its own,
    /// and other games keep their newest three.
    @Test func backgroundSlotsArePerGame() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let games = (UInt64(1)...6).map { Self.bareGame(seed: $0) }
        // A legacy slot holding game 1, and one holding game 2.
        let legacy = saves.url.appending(path: SaveStore.legacyBackgroundFileName)
        let first = try await store.saveBackground(games[0])
        try FileManager.default.moveItem(at: first.url, to: legacy)
        #expect(try await store.list().map(\.url) == [legacy])
        try await store.saveBackground(games[0])
        #expect(saves.files() == [SaveStore.backgroundFileName(for: games[0])])
        let second = try await store.saveBackground(games[1])
        try FileManager.default.moveItem(at: second.url, to: legacy)
        try await store.saveBackground(games[0])
        #expect(saves.files() == [SaveStore.legacyBackgroundFileName, SaveStore.backgroundFileName(for: games[0])].sorted())
        // Games 3 to 6 in turn: each keeps its slot, the three newest others stay.
        for game in games[2...] { try await store.saveBackground(game) }
        let listed = try await store.list()
        #expect(listed.map(\.seed) == [6, 5, 4, 3])
        #expect(listed.allSatisfy { $0.kind == .background && $0.url.lastPathComponent.hasPrefix("background-") })
        #expect(SaveStore.backgroundFileName(for: games[5]) == "background-6-duel-rome.ttys")
    }

    /// Two games alike in seed, map size and civ, each with its own id (M1 §14), keep their own
    /// autosave rotations and background slots: the second one's ten autosaves leave the first
    /// its newest two, as any other game, where under one key they would have pushed out all of
    /// them, and its slot stays (play-ipad z01: a scenario on the real game's seed and civ).
    /// Saves from before ids keep the key they had, apart from both; the id comes back with a
    /// save, so the game goes on in its own rotation.
    @Test func gamesAlikeKeepTheirOwnRotations() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let state = Self.bareGame(seed: 11)
        var legacy: [SaveSummary] = []
        for _ in 0..<3 { legacy.append(try await store.autosave(state)) }
        var first: [SaveSummary] = []
        for _ in 0..<10 { first.append(try await store.autosave(state, game: "game-1")) }
        let firstSlot = try await store.saveBackground(state, game: "game-1")
        var second: [SaveSummary] = []
        for _ in 0..<10 { second.append(try await store.autosave(state, game: "game-2")) }
        let secondSlot = try await store.saveBackground(state, game: "game-2")

        var listed = try await store.list()
        func autos(_ game: String?) -> [SaveSummary] { listed.filter { $0.kind == .auto && $0.game == game } }
        #expect(autos("game-2") == Array(second.reversed()))
        #expect(autos("game-1") == Array(first.suffix(2).reversed()))
        #expect(autos(nil) == Array(legacy.suffix(2).reversed()))
        #expect(firstSlot.url != secondSlot.url && listed.contains(firstSlot) && listed.contains(secondSlot))
        #expect(secondSlot.url.lastPathComponent == "background-11-duel-rome-game_2.ttys")
        #expect(SaveStore.backgroundFileName(for: state) == "background-11-duel-rome.ttys")

        let loaded = try await store.open(firstSlot, rules: .standard)
        #expect(loaded.summary.game == "game-1")
        first.append(try await store.autosave(loaded.state, game: loaded.summary.game))
        listed = try await store.list()
        #expect(autos("game-1") == [first[10], first[9], first[8]])
        #expect(autos("game-2") == Array(second.suffix(2).reversed()))
    }

    /// A game's id is stored only when set: a header without one is the fixed schema, as before
    /// ids, and reads back with none.
    @Test func aGameIDIsStoredOnlyWhenSet() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let state = Self.bareGame(seed: 3)
        let plain = try await store.save(state, name: "Plain", kind: .manual)
        let named = try await store.save(state, name: "Named", kind: .manual, game: "game-9")
        let fixed = ["civName", "currentPlayer", "currentPlayer.rawValue", "kind", "mapSizeName", "name", "rulesID", "savedAt", "seed",
                     "turn"]
        #expect(try SchemaFingerprintTests.keyPaths(of: ExplorerHeaderTests.header(of: plain.url)) == fixed)
        #expect(try SchemaFingerprintTests.keyPaths(of: ExplorerHeaderTests.header(of: named.url)) == (fixed + ["game"]).sorted())
        let listed = try await store.list()
        #expect(listed.first { $0.url == plain.url }?.game == nil)
        #expect(listed.first { $0.url == named.url }?.game == "game-9")
    }

    /// Files of another format version, or damaged, are listed apart (with the header when it
    /// still decodes), never pruned, and can be deleted.
    @Test func unreadableSavesAreListedApart() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        var state = PersistenceFixture.newGame()
        let old = try await store.autosave(state)
        let kept = try await store.save(state, name: "Kept", kind: .manual)
        var bytes = [UInt8](try Data(contentsOf: old.url))
        bytes[4] = UInt8((SaveStore.formatVersion + 1) & 0xFF)
        try Data(bytes).write(to: old.url)
        let junk = saves.url.appending(path: "junk.ttys")
        try Data("not a save".utf8).write(to: junk)
        try Data("notes".utf8).write(to: saves.url.appending(path: "notes.txt"))
        #expect(try await store.list() == [kept])
        var unreadable = try await store.listUnreadable()
        #expect(unreadable.map(\.url) == [old.url, junk])
        #expect(unreadable[0].reason == .unsupportedFormat(found: SaveStore.formatVersion + 1, supported: SaveStore.formatVersion))
        #expect(unreadable[0].isOtherVersion && unreadable[0].summary == old)
        #expect(unreadable[1].reason == .notASave && unreadable[1].summary == nil && !unreadable[1].isOtherVersion)
        // Autosaves of the same game go on rotating without touching it.
        for _ in 0..<12 {
            PersistenceFixture.playPhase(&state)
            try await store.autosave(state)
        }
        #expect(FileManager.default.fileExists(atPath: old.url.path))
        try await store.delete(fileAt: old.url)
        try await store.delete(fileAt: junk)
        unreadable = try await store.listUnreadable()
        #expect(unreadable.isEmpty)
        await #expect(throws: SaveError.notInStore) { try await store.delete(fileAt: saves.url.appending(path: "notes.txt")) }
    }

    /// A bare game of its own seed (another game, as the slot rules see it) on the fixture map.
    static func bareGame(seed: UInt64) -> GameState {
        let map = PersistenceFixture.map()
        let players = (0..<2).map { i in
            Player(id: PlayerID(i), name: "Player \(i)", isHuman: i == 0, tileCount: map.tileCount, civ: i == 0 ? "rome" : "mongols", gold: 0)
        }
        return GameState(seed: seed, map: map, players: players, rules: .standard, mapSizeName: "duel")
    }

    /// The list holds every kind, newest first, and leaves out files that are not saves.
    @Test func listIsNewestFirst() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        #expect(try await store.list().isEmpty) // no directory yet
        var state = PersistenceFixture.newGame()
        let a = try await store.save(state, name: "Before the march", kind: .manual)
        PersistenceFixture.playPhase(&state)
        let b = try await store.autosave(state)
        let c = try await store.saveBackground(state)
        PersistenceFixture.playPhase(&state)
        let d = try await store.save(state, name: "Rome – Turn 2", kind: .manual)
        try Data("not a save".utf8).write(to: saves.url.appending(path: "junk.ttys"))
        try Data("notes".utf8).write(to: saves.url.appending(path: "notes.txt"))
        let listed = try await store.list()
        #expect(listed == [d, c, b, a])
        #expect(listed.map(\.kind) == [.manual, .background, .auto, .manual])
        #expect(a.url.lastPathComponent == "manual-1.ttys" && d.url.lastPathComponent == "manual-2.ttys")
        #expect(d.name == "Rome – Turn 2" && d.turn == 2)
    }

    @Test func deleteRemovesTheSave() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let state = PersistenceFixture.newGame()
        let a = try await store.save(state, name: "A", kind: .manual)
        let b = try await store.autosave(state)
        try await store.delete(a)
        #expect(try await store.list() == [b])
        try await store.delete(a) // already gone
        let elsewhere = SaveSummary(url: FileManager.default.temporaryDirectory.appending(path: "other.ttys"), name: "x", kind: .manual,
                                    savedAt: Date(), turn: 1, currentPlayer: PlayerID(0), civName: "Rome", mapSizeName: "duel",
                                    seed: 1, rulesID: "m1.1")
        await #expect(throws: SaveError.notInStore) { try await store.delete(elsewhere) }
    }

    // MARK: Refusals

    /// Another rules id is refused, whether the header or the game data says so; the same id
    /// with other rules data loads with a warning (M1 §12.3).
    @Test func rulesIdentity() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let state = PersistenceFixture.populated()
        let summary = try await store.save(state, name: "Rules", kind: .manual)

        let other = try rules { $0["id"] = "m1.x" }
        await #expect(throws: SaveError.rulesMismatch(saved: "m1.1", current: "m1.x")) {
            try await store.load(summary, rules: other)
        }

        let tuned = try rules { json in
            var units = json["units"] as! [[String: Any]]
            units[3]["cost"] = 41
            json["units"] = units
        }
        #expect(tuned.id == Ruleset.standard.id && tuned.contentHash != Ruleset.standard.contentHash)
        let loaded = try await store.open(summary, rules: tuned)
        #expect(loaded.warnings == [.rulesDataChanged(rulesID: "m1.1")])
        #expect(loaded.state.rules === tuned && loaded.state.rulesRef.contentHashChanged)
        #expect(loaded.state.units == state.units && loaded.state.cities == state.cities)
        // Saved again, it records the new rules and loads without the warning.
        let again = try await store.save(loaded.state, name: "Rules", kind: .manual)
        #expect(try await store.open(again, rules: tuned).warnings.isEmpty)

        // A header naming other rules than the game data inside: the header decides first;
        // the game data's own id is checked as it decodes.
        let data = try SaveStore.encode(state, summary: SaveSummary(url: summary.url, name: "x", kind: .manual, savedAt: Date(), turn: state.turn,
                                                                 currentPlayer: state.currentPlayer, civName: "Rome", mapSizeName: "duel",
                                                                 seed: state.seed, rulesID: "m1.x"))
        let forged = saves.url.appending(path: "forged.ttys")
        try data.write(to: forged)
        let forgedSummary = SaveSummary(url: forged, name: "x", kind: .manual, savedAt: Date(), turn: 4, currentPlayer: PlayerID(1),
                                        civName: "Rome", mapSizeName: "duel", seed: state.seed, rulesID: "m1.x")
        await #expect(throws: SaveError.rulesMismatch(saved: "m1.x", current: "m1.1")) {
            try await store.load(forgedSummary, rules: .standard)
        }
        await #expect(throws: SaveError.rulesMismatch(saved: "m1.1", current: "m1.x")) {
            try await store.load(forgedSummary, rules: other)
        }
    }

    /// Another format version is refused, and such files stay out of the list.
    @Test func otherFormatVersionsAreRefused() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let summary = try await store.save(PersistenceFixture.newGame(), name: "Old", kind: .manual)
        var bytes = [UInt8](try Data(contentsOf: summary.url))
        for version in [SaveStore.formatVersion + 1, 0, 0x0100] {
            bytes[4] = UInt8(version & 0xFF)
            bytes[5] = UInt8(version >> 8)
            try Data(bytes).write(to: summary.url)
            await #expect(throws: SaveError.unsupportedFormat(found: version, supported: SaveStore.formatVersion)) {
                try await store.load(summary, rules: .standard)
            }
            #expect(try await store.list().isEmpty)
        }
    }

    // MARK: Damage

    /// A file cut short anywhere throws `SaveError` (never crashes and never loads).
    @Test func truncatedFilesThrowCleanly() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let summary = try await store.save(PersistenceFixture.populated(), name: "Cut", kind: .manual)
        let data = try Data(contentsOf: summary.url)
        let headerEnd = 10 + Int(data[6]) + Int(data[7]) << 8
        var cuts = Array(0...12) + [headerEnd - 1, headerEnd, headerEnd + 1, headerEnd + 2, data.count - 1]
        cuts += stride(from: headerEnd + 3, to: data.count - 1, by: max(1, (data.count - headerEnd) / 40))
        for cut in cuts {
            try data.prefix(cut).write(to: summary.url)
            do {
                _ = try await store.load(summary, rules: .standard)
                Issue.record("a file cut at \(cut) of \(data.count) bytes loaded")
            } catch let error as SaveError {
                switch error {
                case .truncated, .corrupt, .notASave: break
                default: Issue.record("cut at \(cut): \(error)")
                }
            }
        }
        // The header of a file cut short within its header does not list either.
        try data.prefix(headerEnd - 1).write(to: summary.url)
        #expect(try await store.list().isEmpty)
    }

    /// Damaged files throw `SaveError` or load a sound game; they never crash.
    @Test func corruptFilesThrowCleanly() async throws {
        let saves = TempSaves()
        defer { saves.cleanUp() }
        let store = saves.store()
        let state = PersistenceFixture.populated()
        let summary = try await store.save(state, name: "Damaged", kind: .manual)
        let data = try Data(contentsOf: summary.url)
        let headerEnd = 10 + Int(data[6]) + Int(data[7]) << 8

        func load(_ bytes: [UInt8]) async -> Result<GameState, SaveError>? {
            do {
                try Data(bytes).write(to: summary.url)
                return .success(try await store.load(summary, rules: .standard))
            } catch let error as SaveError {
                return .failure(error)
            } catch {
                Issue.record("not a SaveError: \(error)")
                return nil
            }
        }
        // Not a save at all; an empty file.
        if case .failure(.notASave) = await load(Array("hello, this is not a save at all".utf8)) {} else { Issue.record("text read as a save") }
        if case .failure(.notASave) = await load(Array("TTYX".utf8)) {} else { Issue.record("a wrong signature read as a save") }
        if case .failure(.truncated) = await load(Array("TT".utf8)) {} else { Issue.record("half a signature read as a save") }
        if case .failure(.truncated) = await load([]) {} else { Issue.record("an empty file read as a save") }
        // A broken header length, header or game data.
        var bytes = [UInt8](data)
        bytes[9] = 0x7F
        if case .failure(.corrupt) = await load(bytes) {} else { Issue.record("a huge header length loaded") }
        bytes = [UInt8](data)
        bytes[11] = UInt8(ascii: "#")
        if case .failure(.corrupt) = await load(bytes) {} else { Issue.record("a broken header loaded") }
        bytes = Array(data.prefix(headerEnd)) + Array(repeating: 0xA5, count: 4000)
        if case .failure(.corrupt) = await load(bytes) {} else { Issue.record("garbage game data loaded") }
        bytes = Array(data.prefix(headerEnd)) + [UInt8](try (Data("{\"seed\": 1}".utf8) as NSData).compressed(using: .lzfse) as Data)
        if case .failure(.corrupt) = await load(bytes) {} else { Issue.record("incomplete game JSON loaded") }
        // Single flipped bytes all through the file: each throws or loads a sound game.
        var thrown = 0, loaded = 0
        for offset in stride(from: 0, to: data.count, by: max(1, data.count / 300)) {
            bytes = [UInt8](data)
            bytes[offset] ^= 0x5A
            switch await load(bytes) {
            case let .success(game)?:
                loaded += 1
                #expect(game.checkInvariants().isEmpty)
            case .failure?: thrown += 1
            case nil: break
            }
        }
        #expect(thrown > 0)
        print("corruptFilesThrowCleanly: \(thrown) flipped files refused, \(loaded) loaded sound games")
    }

    /// A game whose data contradicts itself is refused by the shape and invariant checks.
    @Test func inconsistentGamesAreRefused() throws {
        let state = PersistenceFixture.populated()
        let url = URL(fileURLWithPath: "/tmp/x.ttys")
        let summary = SaveSummary(url: url, name: "x", kind: .manual, savedAt: Date(), turn: state.turn, currentPlayer: state.currentPlayer,
                                  civName: "Rome", mapSizeName: "duel", seed: state.seed, rulesID: "m1.1")
        func reencoded(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
            edit(&json)
            let game = try JSONSerialization.data(withJSONObject: json)
            let decoded = try { () throws -> GameState in
                let decoder = JSONDecoder()
                return try decoder.decode(GameState.self, from: game)
            }()
            return try SaveStore.encode(decoded, summary: summary)
        }
        // Territory of a missing city (structural), a unit on a mountain (invariant).
        let territory = try reencoded { json in
            var tiles = json["tileCity"] as! [Int]
            tiles[0] = 99
            json["tileCity"] = tiles
        }
        #expect(throws: SaveError.corrupt("territory")) { try SaveStore.decode(territory, url: url, rules: .standard) }
        let misplaced = try reencoded { json in
            var units = json["units"] as! [[String: Any]]
            units[0]["position"] = ["q": at(11, 6).q, "r": at(11, 6).r]
            json["units"] = units
        }
        #expect(throws: SaveError.self) { try SaveStore.decode(misplaced, url: url, rules: .standard) }
        // The intact game decodes.
        #expect(try SaveStore.decode(SaveStore.encode(state, summary: summary), url: url, rules: .standard).state == state)
    }
}
