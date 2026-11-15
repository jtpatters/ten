#if DEBUG
import Foundation

/// Debug-build log lines on standard output, written straight through rather than through
/// stdio's buffer, so `simctl launch --stdout=<file>` shows each line as it happens
/// (App/AUTOMATION.md).
///
/// Logging never takes the app down: when standard output has gone away (the console that
/// launched the app was closed, a pipe's reader ended) a write fails with EIO or EPIPE, so
/// the throwing `write(contentsOf:)` is used (the older `write(_:)` raises an Objective-C
/// exception Swift cannot catch), SIGPIPE is ignored, and after the first failure the log is
/// silent.
enum DebugLog {
    nonisolated(unsafe) private static var broken = false  // a benign race: at worst one more failed write
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    static func write(_ line: String) {
        guard !broken else { return }
        _ = ignoreSigpipe
        do {
            try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            broken = true
        }
    }
}
#endif
