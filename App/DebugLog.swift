#if DEBUG
import Foundation

/// Debug-build log lines on standard output, written straight through rather than through
/// stdio's buffer, so `simctl launch --stdout=<file>` shows each line as it happens
/// (App/AUTOMATION.md).
enum DebugLog {
    static func write(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
#endif
