import Foundation
import Persistence

/// The Notices log kept with each save (M1 §14, §16), in the app's own storage beside the saves:
/// `Documents/NoticeLogs/<save file name>.json`, the log's newest `limit` notices with the time
/// stamp of the save they belong to, and the newest notice read then (the unread count). Save
/// files are unchanged (no format change): a save without its log, with one written for an older
/// file of the same name, or with one that will not read opens with an empty log. Logs whose save
/// is gone (pruned, deleted, replaced) are swept away after every write and delete.
struct NoticeLogStore: Sendable {
    static let limit = 50

    /// Beside the saves folder.
    let directory: URL
    let savesDirectory: URL

    init(savesDirectory: URL) {
        self.savesDirectory = savesDirectory
        directory = savesDirectory.deletingLastPathComponent().appending(path: "NoticeLogs", directoryHint: .isDirectory)
    }

    /// The app's: `Documents/Saves` and `Documents/NoticeLogs`.
    static let app = NoticeLogStore(savesDirectory: URL.documentsDirectory.appending(path: "Saves", directoryHint: .isDirectory))

    private struct File: Codable {
        var version = 1
        /// The save's `savedAt`: file names are reused, so a log is read back only into its save.
        var savedAt: Date
        var notices: [Notice]
        /// The newest notice read when the save was made (`NoticeCenter.readThroughID`); the later
        /// ones come back unread. Absent from logs written before the unread count: all read.
        var readThrough: Int?
    }

    /// A save's log as kept: its notices, oldest first, and the newest of them read (nil: all).
    struct Kept {
        var notices: [Notice] = []
        var readThrough: Int?
    }

    private func url(for save: SaveSummary) -> URL {
        directory.appending(path: save.url.lastPathComponent + ".json")
    }

    /// Writes the log for a save just written (its newest `limit` notices, and the newest read),
    /// then sweeps.
    func write(_ notices: [Notice], readThrough: Int, for save: SaveSummary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(File(savedAt: save.savedAt, notices: Array(notices.suffix(Self.limit)), readThrough: readThrough))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: save), options: [.atomic])
        sweep()
    }

    /// The log kept with a save; empty when there is none for it.
    func read(for save: SaveSummary) -> Kept {
        guard let data = try? Data(contentsOf: url(for: save)),
              let file = try? JSONDecoder().decode(File.self, from: data),
              abs(file.savedAt.timeIntervalSince(save.savedAt)) < 0.001 else { return Kept() }
        return Kept(notices: file.notices, readThrough: file.readThrough)
    }

    /// Removes the logs whose save file is gone.
    func sweep() {
        let manager = FileManager.default
        guard let logs = try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        for name in logs where name.hasSuffix(".json") {
            let save = savesDirectory.appending(path: String(name.dropLast(".json".count)))
            if !manager.fileExists(atPath: save.path(percentEncoded: false)) {
                try? manager.removeItem(at: directory.appending(path: name))
            }
        }
    }

    /// Removes every log (with the saves, debug `-resetSaves`).
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
