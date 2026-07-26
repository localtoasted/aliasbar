import Foundation

/// App-owned path resolution. The shared core accepts concrete paths so a future
/// executable can choose its own defaults without importing app settings.
enum AppPaths {
    static var rcPath: String {
        resolveRcPath(stored: AppSettings.shared.rcPathOverride,
                      environmentOverride: ProcessInfo.processInfo.environment["ALIASBAR_ZSHRC"],
                      homeDirectory: NSHomeDirectory())
    }

    static var historyPath: String {
        resolveHistoryPath(
            environmentOverride: ProcessInfo.processInfo.environment["ALIASBAR_HISTORY"],
            homeDirectory: NSHomeDirectory()
        )
    }

    static func resolveRcPath(stored: String?,
                              environmentOverride: String?,
                              homeDirectory: String) -> String {
        if let stored, !stored.isEmpty {
            return (stored as NSString).expandingTildeInPath
        }
        if let environmentOverride, !environmentOverride.isEmpty {
            return (environmentOverride as NSString).expandingTildeInPath
        }
        return homeDirectory + "/.zshrc"
    }

    static func resolveHistoryPath(environmentOverride: String?,
                                   homeDirectory: String) -> String {
        if let environmentOverride, !environmentOverride.isEmpty {
            return (environmentOverride as NSString).expandingTildeInPath
        }
        return homeDirectory + "/.zsh_history"
    }
}

/// Compatibility surface for the app. None of these defaults are part of the core
/// parser interface; they are resolved here and passed in explicitly.
extension ZshrcParser {
    static var path: String { AppPaths.rcPath }

    static var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func parse() -> ParseOutcome {
        parse(path: path)
    }
}

/// The app keeps its existing zero-argument history calls while the reusable scanner
/// exposes only concrete-path operations.
extension HistoryScanner {
    static var path: String { AppPaths.historyPath }

    static func commandWordCounts() -> [String: Int] {
        commandWordCounts(path: path)
    }

    static func commands() -> [Command] {
        commands(path: path)
    }
}
