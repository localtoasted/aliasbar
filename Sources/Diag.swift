import Foundation

/// Append-only diagnostics log.
///
/// Exists because the failure this app is most prone to is invisible by definition: a
/// menu bar icon that macOS declines to draw. Without a log there is nothing to look at
/// when someone says "it's not there".
enum Diag {
    static let path = NSHomeDirectory() + "/Library/Logs/AliasBar-diag.log"

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
