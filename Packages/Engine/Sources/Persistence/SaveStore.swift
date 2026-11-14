import Foundation
import GameCore

// Save files (M1 §14):
//
//     "TTYS" | UInt16 LE format version | UInt32 LE header length | header JSON (`SaveSummary`)
//     | LZFSE-compressed `GameState` JSON
//
// written atomically into one directory (the App uses Documents/Saves). The header lets the Load
// list show a save without reading the game. A store loads only its own format version
// (`SaveStore.formatVersion`, bumped on any change to `GameState`'s encoding other than an
// additive optional field, M1 §14; the schema fingerprint test in PersistenceTests guards it and
// lists those fields) and only saves made under the same rules id; a save made under the same id
// but other rules data loads with a warning (M1 §12.3).

/// Why a save was written.
public enum SaveKind: String, Codable, Sendable {
    case manual, auto, background
}

/// What the Load list shows about a save without reading the game: the file's header, plus
/// where the file is. `url` is not stored in the file: decoding a header takes it from
/// `decoder.userInfo[SaveSummary.fileURLKey]`.
public struct SaveSummary: Codable, Hashable, Sendable, Identifiable {
    public var url: URL
    public var name: String
    public var kind: SaveKind
    public var savedAt: Date
    public var turn: Int
    public var currentPlayer: PlayerID
    public var civName: String
    public var mapSizeName: String
    public var seed: UInt64
    public var rulesID: String
    /// Own units on the App's Explore order (M1 §16); empty when there are none, as in saves made
    /// before the order existed. Stored only when not empty, so a header without explorers is
    /// unchanged (and an older reader ignores the key: no format bump).
    public var explorers: [SavedExplorer]
    /// The game the save belongs to (M1 §14): an id the App gives each new game, which its
    /// saves carry on. Nil in saves made before games had ids (their game is their seed, map
    /// size and civ); stored only when set, as `explorers` is.
    public var game: String?

    public var id: URL { url }

    public init(url: URL, name: String, kind: SaveKind, savedAt: Date, turn: Int, currentPlayer: PlayerID, civName: String,
                mapSizeName: String, seed: UInt64, rulesID: String, explorers: [SavedExplorer] = [], game: String? = nil) {
        self.url = url
        self.name = name
        self.kind = kind
        self.savedAt = savedAt
        self.turn = turn
        self.currentPlayer = currentPlayer
        self.civName = civName
        self.mapSizeName = mapSizeName
        self.seed = seed
        self.rulesID = rulesID
        self.explorers = explorers
        self.game = game
    }

    /// `decoder.userInfo` key: the URL of the file whose header is being decoded.
    public static let fileURLKey = CodingUserInfoKey(rawValue: "TenThousandYears.saveFileURL")!

    private enum CodingKeys: String, CodingKey {
        case name, kind, savedAt, turn, currentPlayer, civName, mapSizeName, seed, rulesID, explorers, game
    }

    public init(from decoder: Decoder) throws {
        guard let url = decoder.userInfo[Self.fileURLKey] as? URL else {
            throw DecodingError.valueNotFound(URL.self, DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "a save header decodes with its file's URL in userInfo[SaveSummary.fileURLKey]"))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: url, name: try c.decode(String.self, forKey: .name), kind: try c.decode(SaveKind.self, forKey: .kind),
                  savedAt: try c.decode(Date.self, forKey: .savedAt), turn: try c.decode(Int.self, forKey: .turn),
                  currentPlayer: try c.decode(PlayerID.self, forKey: .currentPlayer), civName: try c.decode(String.self, forKey: .civName),
                  mapSizeName: try c.decode(String.self, forKey: .mapSizeName), seed: try c.decode(UInt64.self, forKey: .seed),
                  rulesID: try c.decode(String.self, forKey: .rulesID),
                  explorers: try c.decodeIfPresent([SavedExplorer].self, forKey: .explorers) ?? [],
                  game: try c.decodeIfPresent(String.self, forKey: .game))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(savedAt, forKey: .savedAt)
        try c.encode(turn, forKey: .turn)
        try c.encode(currentPlayer, forKey: .currentPlayer)
        try c.encode(civName, forKey: .civName)
        try c.encode(mapSizeName, forKey: .mapSizeName)
        try c.encode(seed, forKey: .seed)
        try c.encode(rulesID, forKey: .rulesID)
        if !explorers.isEmpty { try c.encode(explorers, forKey: .explorers) }
        if let game { try c.encode(game, forKey: .game) }
    }
}

/// Why a save could not be written, read or deleted. `description` is shown to the player.
public enum SaveError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file does not start with the "TTYS" signature.
    case notASave
    /// The file was written in another save format version.
    case unsupportedFormat(found: UInt16, supported: UInt16)
    /// The save was made under other rules (another rules id).
    case rulesMismatch(saved: String, current: String)
    /// The file ends before its header or game data does.
    case truncated
    /// The file is damaged (why, for logs).
    case corrupt(String)
    /// The save is not a file of this store's directory.
    case notInStore

    public var description: String {
        switch self {
        case .notASave: "This file is not a Ten Thousand Years save."
        case let .unsupportedFormat(found, supported):
            "This save was written by another version of the game (save format \(found); this version reads format \(supported))."
        case let .rulesMismatch(saved, current):
            "This save was made with other rules (\(saved)); this version plays rules \(current)."
        case .truncated: "This save is incomplete; the file was cut short."
        case let .corrupt(reason): "This save is damaged (\(reason))."
        case .notInStore: "This save is not in the saves folder."
        }
    }
}

/// Something worth telling the player about a save that loaded.
public enum SaveWarning: Hashable, Sendable, CustomStringConvertible {
    /// The save was made under the same rules id but different rules data (M1 §12.3): the game
    /// continues under the current rules, which may play differently.
    case rulesDataChanged(rulesID: String)

    public var description: String {
        switch self {
        case let .rulesDataChanged(id):
            "This save was made with an earlier tuning of rules \(id). It continues under the current rules, so some numbers may differ."
        }
    }
}

/// A loaded save: the game, its header and what the player should be told about it.
public struct LoadedGame: Sendable {
    public var state: GameState
    public var summary: SaveSummary
    public var warnings: [SaveWarning]

    public init(state: GameState, summary: SaveSummary, warnings: [SaveWarning]) {
        self.state = state
        self.summary = summary
        self.warnings = warnings
    }
}

/// A file in the saves directory that `list()` leaves out because its header cannot be read:
/// another format version, or damage. `summary` is its header when that still decodes (a
/// save of another version whose header has not changed), to say which game it held.
public struct UnreadableSave: Hashable, Sendable, Identifiable {
    public var url: URL
    public var reason: SaveError
    public var summary: SaveSummary?

    public var id: URL { url }

    public init(url: URL, reason: SaveError, summary: SaveSummary?) {
        self.url = url
        self.reason = reason
        self.summary = summary
    }

    /// Made by another version of the game (rather than damaged).
    public var isOtherVersion: Bool {
        if case .unsupportedFormat = reason { true } else { false }
    }
}

/// The saves in one directory (the App uses Documents/Saves). Writes are atomic: a crash or a
/// full disk leaves the previous file of that name intact.
public actor SaveStore {
    /// The file layout version this store writes and reads. Bump it on any change to how
    /// `GameState` (or the header) encodes, except an additive optional field (M1 §14: optional
    /// and left out while empty, so older files decode without it), which keeps the version;
    /// `SchemaFingerprintTests` fails until it is bumped or, for such a field of `GameState`,
    /// the field's paths are listed in its `additivePaths`.
    public static let formatVersion: UInt16 = 1
    /// The four bytes every save starts with.
    public static let signature: [UInt8] = Array("TTYS".utf8)
    /// Autosaves kept of the game being autosaved (M1 §14); older ones are deleted as new ones
    /// are written.
    public static let autosavesKept = 10
    /// Autosaves kept of each other game, and of all games together (M1 §14).
    public static let otherGameAutosavesKept = 2
    public static let autosavesKeptInAll = 40
    /// Background slots kept of other games than the one being saved.
    public static let otherGameBackgroundsKept = 3
    public static let fileExtension = "ttys"
    /// The one background slot every game shared before slots were kept per game; such a file
    /// still lists, loads and is pruned like the others.
    public static let legacyBackgroundFileName = "background.ttys"

    /// Signature, version and header length.
    static let prefixLength = 10
    /// Headers are small; anything larger is damage, not a header.
    static let maxHeaderLength = 64 * 1024

    public let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL) {
        self.init(directory: directory, now: { Date() })
    }

    /// `now` stamps each save (tests pass a clock that steps, so "newest" is unambiguous).
    public init(directory: URL, now: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.now = now
    }

    // MARK: Writing

    /// Writes a save of any kind under a new file name and returns its summary. Manual saves
    /// are files `manual-<n>.ttys`; `name` is what the Load list shows. `explorers` and `game`
    /// go into the header (`SaveSummary.explorers`, `.game`), as with every kind of save.
    @discardableResult
    public func save(_ state: GameState, name: String, kind: SaveKind, explorers: [SavedExplorer] = [],
                     game: String? = nil) throws -> SaveSummary {
        switch kind {
        case .auto: return try autosave(state, name: name, explorers: explorers, game: game)
        case .background: return try saveBackground(state, name: name, explorers: explorers, game: game)
        case .manual:
            let n = try nextSerial(prefix: "manual-")
            return try write(state, name: name, kind: .manual, to: directory.appending(path: "manual-\(n).\(Self.fileExtension)"),
                             explorers: explorers, game: game)
        }
    }

    /// Writes an autosave named `auto-<turn>-<player>-<n>.ttys` (n counts up across all
    /// autosaves), then prunes autosaves per game (M1 §14): this game keeps its newest
    /// `autosavesKept`, every other game its newest `otherGameAutosavesKept`, and all games
    /// together at most `autosavesKeptInAll`.
    @discardableResult
    public func autosave(_ state: GameState, explorers: [SavedExplorer] = [], game: String? = nil) throws -> SaveSummary {
        try autosave(state, name: Self.defaultName(for: state), explorers: explorers, game: game)
    }

    /// Writes the game's background slot (M1 §14: when the app leaves the screen), replacing
    /// that game's previous one; other games keep their newest `otherGameBackgroundsKept`.
    @discardableResult
    public func saveBackground(_ state: GameState, explorers: [SavedExplorer] = [], game: String? = nil) throws -> SaveSummary {
        try saveBackground(state, name: Self.defaultName(for: state), explorers: explorers, game: game)
    }

    private func autosave(_ state: GameState, name: String, explorers: [SavedExplorer], game: String?) throws -> SaveSummary {
        let n = try nextSerial(prefix: "auto-")
        let file = "auto-\(state.turn)-\(state.currentPlayer.rawValue)-\(n).\(Self.fileExtension)"
        let summary = try write(state, name: name, kind: .auto, to: directory.appending(path: file), explorers: explorers, game: game)
        try pruneAutosaves(keeping: summary)
        return summary
    }

    private func saveBackground(_ state: GameState, name: String, explorers: [SavedExplorer], game: String?) throws -> SaveSummary {
        let summary = try write(state, name: name, kind: .background,
                                to: directory.appending(path: Self.backgroundFileName(for: state, game: game)), explorers: explorers,
                                game: game)
        try pruneBackgrounds(keeping: summary)
        return summary
    }

    /// A game's background slot: `background-<seed>-<map size>-<civ>.ttys`, with `-<game>` before
    /// the extension for a game with an id.
    public static func backgroundFileName(for state: GameState, game: String? = nil) -> String {
        "background-\(state.seed)-\(fileSafe(state.mapSizeName))-\(fileSafe(civName(of: state)))"
            + (game.map { "-\(fileSafe($0))" } ?? "") + ".\(fileExtension)"
    }

    /// Lowercase ASCII letters and digits; anything else becomes "_".
    static func fileSafe(_ text: String) -> String {
        String(text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    /// The default name of a save: "<Civ> – Turn N" (M1 §14), the civ being the first human
    /// player's (else player 0's).
    public static func defaultName(for state: GameState) -> String {
        "\(civName(of: state)) – Turn \(state.turn)"
    }

    static func civName(of state: GameState) -> String {
        guard let player = state.players.first(where: \.isHuman) ?? state.players.first else { return "Unknown" }
        return state.rules.civ(player.civ)?.name ?? player.name
    }

    private func write(_ state: GameState, name: String, kind: SaveKind, to url: URL, explorers: [SavedExplorer],
                       game: String?) throws -> SaveSummary {
        let summary = SaveSummary(url: url, name: name, kind: kind, savedAt: now(), turn: state.turn, currentPlayer: state.currentPlayer,
                                  civName: Self.civName(of: state), mapSizeName: state.mapSizeName, seed: state.seed,
                                  rulesID: state.rules.id, explorers: explorers, game: game)
        let data = try Self.encode(state, summary: summary)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        return summary
    }

    /// The bytes of a save file.
    static func encode(_ state: GameState, summary: SaveSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(summary)
        let game = try encoder.encode(state)
        let body: Data
        do {
            body = try (game as NSData).compressed(using: .lzfse) as Data
        } catch {
            throw SaveError.corrupt("could not compress the game: \(error.localizedDescription)")
        }
        var data = Data(capacity: prefixLength + header.count + body.count)
        data.append(contentsOf: signature)
        withUnsafeBytes(of: formatVersion.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(header.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(header)
        data.append(body)
        return data
    }

    // MARK: Listing

    /// Every readable save of this format version, newest first (ties: the higher serial, then
    /// the file name). Unreadable files are left out (Load cannot open them either; see
    /// `listUnreadable`).
    public func list() throws -> [SaveSummary] {
        let saves = try saveFiles().compactMap { try? Self.readHeader(of: $0) }
        return saves.sorted(by: Self.newerFirst)
    }

    /// The `.ttys` files whose header cannot be read, by file name, each with why: another
    /// format version (with its header, when that still decodes, to name the game), or damage.
    /// They are never pruned: another version of the game may still open them.
    public func listUnreadable() throws -> [UnreadableSave] {
        try saveFiles().compactMap { url in
            do {
                _ = try Self.readHeader(of: url)
                return nil
            } catch let error as SaveError {
                let summary = if case .unsupportedFormat = error { try? Self.readHeader(of: url, anyVersion: true) } else { SaveSummary?.none }
                return UnreadableSave(url: url, reason: error, summary: summary)
            } catch {
                return UnreadableSave(url: url, reason: .corrupt("cannot read the file"), summary: nil)
            }
        }
    }

    /// The `.ttys` files of the directory, by file name. URLs name files under `directory` as
    /// given (not as the enumeration resolves symbolic links), so summaries compare equal to
    /// the ones `save` returned.
    private func saveFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles])
        return files.filter { $0.pathExtension == Self.fileExtension }.map(\.lastPathComponent).sorted()
            .map { directory.appending(path: $0) }
    }

    static func newerFirst(_ a: SaveSummary, _ b: SaveSummary) -> Bool {
        if a.savedAt != b.savedAt { return a.savedAt > b.savedAt }
        let (sa, sb) = (serial(of: a.url) ?? -1, serial(of: b.url) ?? -1)
        if sa != sb { return sa > sb }
        return a.url.lastPathComponent > b.url.lastPathComponent
    }

    /// The `<n>` of `auto-<turn>-<player>-<n>.ttys` and `manual-<n>.ttys`.
    static func serial(of url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("auto-") || stem.hasPrefix("manual-") else { return nil }
        return stem.split(separator: "-").last.flatMap { Int($0) }
    }

    private func nextSerial(prefix: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 1 }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let serials = files.filter { $0.lastPathComponent.hasPrefix(prefix) }.compactMap(Self.serial(of:))
        return (serials.max() ?? 0) + 1
    }

    /// Which game a save belongs to, as its header tells: its game id, with its seed, map size
    /// and the human's civ. Saves from before games had ids (no id) count as one game when
    /// alike in those three.
    struct GameKey: Hashable {
        var seed: UInt64
        var mapSizeName: String
        var civName: String
        var game: String?

        init(_ save: SaveSummary) {
            seed = save.seed
            mapSizeName = save.mapSizeName
            civName = save.civName
            game = save.game
        }
    }

    /// After an autosave: the written save's game keeps its `autosavesKept` newest autosaves,
    /// every other game its `otherGameAutosavesKept` newest while fewer than
    /// `autosavesKeptInAll` are kept in all. Newest by serial, which only grows (never by the
    /// clock), so the file just written always stays. Unreadable files are left alone.
    private func pruneAutosaves(keeping written: SaveSummary) throws {
        let game = GameKey(written)
        let autos = try list().filter { $0.kind == .auto }.sorted(by: Self.higherSerialFirst)
        let own = autos.filter { GameKey($0) == game }
        var doomed = Array(own.dropFirst(Self.autosavesKept))
        var budget = Self.autosavesKeptInAll - min(own.count, Self.autosavesKept)
        var kept: [GameKey: Int] = [:]
        for save in autos where GameKey(save) != game {
            let key = GameKey(save)
            if kept[key, default: 0] < Self.otherGameAutosavesKept, budget > 0 {
                kept[key, default: 0] += 1
                budget -= 1
            } else {
                doomed.append(save)
            }
        }
        for save in doomed where save.url.lastPathComponent != written.url.lastPathComponent {
            try? FileManager.default.removeItem(at: save.url)
        }
    }

    static func higherSerialFirst(_ a: SaveSummary, _ b: SaveSummary) -> Bool {
        let (sa, sb) = (serial(of: a.url) ?? -1, serial(of: b.url) ?? -1)
        if sa != sb { return sa > sb }
        return a.url.lastPathComponent > b.url.lastPathComponent
    }

    /// After a background save: the game's other slots go (such as the legacy shared slot), and
    /// other games keep their newest `otherGameBackgroundsKept`, one slot each. Unreadable files
    /// are left alone.
    private func pruneBackgrounds(keeping written: SaveSummary) throws {
        let game = GameKey(written)
        var kept: Set<GameKey> = []
        for save in try list() where save.kind == .background && save.url.lastPathComponent != written.url.lastPathComponent {
            let key = GameKey(save)
            if key != game, !kept.contains(key), kept.count < Self.otherGameBackgroundsKept {
                kept.insert(key)
            } else {
                try? FileManager.default.removeItem(at: save.url)
            }
        }
    }

    /// Reads a save's header (the first bytes of the file only). `anyVersion` skips the format
    /// version check, to name a save of another version (its header may still not decode).
    static func readHeader(of url: URL, anyVersion: Bool = false) throws -> SaveSummary {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: prefixLength) ?? Data()
        let headerLength = try checkPrefix(prefix, anyVersion: anyVersion)
        let header = try handle.read(upToCount: headerLength) ?? Data()
        guard header.count == headerLength else { throw SaveError.truncated }
        return try decodeHeader(header, url: url)
    }

    /// Checks the signature and format version (unless `anyVersion`); returns the header length.
    static func checkPrefix(_ prefix: Data, anyVersion: Bool = false) throws -> Int {
        let bytes = [UInt8](prefix.prefix(prefixLength))
        guard bytes.count >= signature.count else { throw bytes.isEmpty || signature.starts(with: bytes) ? SaveError.truncated : SaveError.notASave }
        guard Array(bytes[0..<4]) == signature else { throw SaveError.notASave }
        guard bytes.count == prefixLength else { throw SaveError.truncated }
        let version = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        guard version == formatVersion || anyVersion else { throw SaveError.unsupportedFormat(found: version, supported: formatVersion) }
        let length = Int(UInt32(bytes[6]) | UInt32(bytes[7]) << 8 | UInt32(bytes[8]) << 16 | UInt32(bytes[9]) << 24)
        guard length > 0, length <= maxHeaderLength else { throw SaveError.corrupt("header length \(length)") }
        return length
    }

    static func decodeHeader(_ header: Data, url: URL) throws -> SaveSummary {
        let decoder = JSONDecoder()
        decoder.userInfo[SaveSummary.fileURLKey] = url
        do {
            return try decoder.decode(SaveSummary.self, from: header)
        } catch {
            throw SaveError.corrupt("unreadable header")
        }
    }

    // MARK: Loading

    /// Loads a save's game (M1 §14): only this format version and only saves made under
    /// `rules.id`; the state decodes against `rules`. Use `open` to also get the warnings.
    public func load(_ save: SaveSummary, rules: Ruleset) throws -> GameState {
        try open(save, rules: rules).state
    }

    /// Loads a save's game with its header and warnings: `rulesDataChanged` when it was made
    /// under the same rules id but different rules data (it loads; M1 §12.3).
    public func open(_ save: SaveSummary, rules: Ruleset) throws -> LoadedGame {
        let data: Data
        do {
            data = try Data(contentsOf: save.url)
        } catch {
            throw SaveError.corrupt("cannot read the file: \(error.localizedDescription)")
        }
        return try Self.decode(data, url: save.url, rules: rules)
    }

    /// Decodes the bytes of a save file.
    static func decode(_ data: Data, url: URL, rules: Ruleset) throws -> LoadedGame {
        let headerLength = try checkPrefix(data.prefix(prefixLength))
        guard data.count >= prefixLength + headerLength else { throw SaveError.truncated }
        let start = data.startIndex
        let summary = try decodeHeader(data[(start + prefixLength)..<(start + prefixLength + headerLength)], url: url)
        guard summary.rulesID == rules.id else { throw SaveError.rulesMismatch(saved: summary.rulesID, current: rules.id) }
        let body = data[(start + prefixLength + headerLength)...]
        guard !body.isEmpty else { throw SaveError.truncated }
        let json: Data
        do {
            json = try (Data(body) as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw SaveError.corrupt("the game data does not decompress")
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.ruleset] = rules
        let state: GameState
        do {
            state = try decoder.decode(GameState.self, from: json)
        } catch let mismatch as RulesMismatch {
            throw SaveError.rulesMismatch(saved: mismatch.saved, current: mismatch.current)
        } catch {
            throw SaveError.corrupt("unreadable game data")
        }
        guard state.turn == summary.turn, state.seed == summary.seed, state.currentPlayer == summary.currentPlayer else {
            throw SaveError.corrupt("the header does not match the game")
        }
        if let problem = structuralProblem(of: state) { throw SaveError.corrupt(problem) }
        let problems = state.checkInvariants()
        guard problems.isEmpty else { throw SaveError.corrupt("inconsistent game: \(problems.prefix(3).joined(separator: "; "))") }
        let warnings: [SaveWarning] = state.rulesRef.contentHashChanged ? [.rulesDataChanged(rulesID: rules.id)] : []
        return LoadedGame(state: state, summary: summary, warnings: warnings)
    }

    /// The first problem with the shape of a decoded state that would make the game (or
    /// `checkInvariants`) index out of range, or nil. Valid saves never have one; a damaged
    /// file that still decodes might.
    static func structuralProblem(of state: GameState) -> String? {
        let map = state.map
        let count = map.tileCount
        guard map.width > 0, map.height > 0, map.width * map.height == count, count <= 1 << 20 else { return "map size" }
        let n = state.players.count
        guard (1...16).contains(n), state.players.indices.allSatisfy({ state.players[$0].id == PlayerID($0) }) else { return "players" }
        guard state.relations.count == n * (n - 1) / 2,
              state.relations.allSatisfy({ (0..<n).contains($0.a.rawValue) && (0..<n).contains($0.b.rawValue) }) else { return "relations" }
        guard (0..<n).contains(state.currentPlayer.rawValue) else { return "current player" }
        guard state.tileCity.count == count, state.nextCityID >= 1, state.nextUnitID >= 1,
              state.tileCity.allSatisfy({ $0 >= 0 && Int($0) <= state.nextCityID }) else { return "territory" }
        guard state.cities.allSatisfy({ (0..<state.nextCityID).contains($0.id.rawValue) && (0..<n).contains($0.owner.rawValue)
            && (0..<n).contains($0.originalOwner.rawValue) && map.index(of: $0.position) != nil }) else { return "cities" }
        guard state.units.allSatisfy({ $0.id.rawValue >= 0 && (0..<n).contains($0.owner.rawValue) }) else { return "units" }
        for player in state.players {
            for set in [player.explored, player.visible] {
                guard set.count == count, set.words.count == (count + 63) / 64 else { return "\(player.id) bitsets" }
            }
            let memory = player.memory
            guard memory.tileOwner.count == count, memory.tileImprovement.count == count,
                  memory.tileRoad.map({ $0.count == count && $0.words.count == (count + 63) / 64 }) ?? true,
                  memory.tileOwner.allSatisfy({ Int($0) <= n }),
                  memory.cities.allSatisfy({ (0..<n).contains($0.owner.rawValue) }),
                  memory.units.allSatisfy({ (0..<n).contains($0.owner.rawValue) }) else { return "\(player.id) memory" }
        }
        return nil
    }

    // MARK: Deleting

    /// Deletes a save of this store (a file already gone counts as deleted).
    public func delete(_ save: SaveSummary) throws {
        try delete(fileAt: save.url)
    }

    /// Deletes a `.ttys` file of this store, readable or not (`listUnreadable`); a file already
    /// gone counts as deleted.
    public func delete(fileAt url: URL) throws {
        let file = url.standardizedFileURL
        guard file.deletingLastPathComponent().path == directory.standardizedFileURL.path,
              file.pathExtension == Self.fileExtension else { throw SaveError.notInStore }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }
}
