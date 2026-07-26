import Foundation

/// App-owned path resolution. The shared core accepts concrete paths so a future
/// executable can choose its own defaults without importing app settings.
///
/// The precedence rules themselves live in `CorePaths` (Model.swift), which is
/// Foundation-only and knows nothing of `AppSettings`. This type's whole job is to
/// supply the app's one extra precedence source — the stored override — and defer to
/// `CorePaths` for everything else, so the app and the `ab` CLI can never drift apart
/// on where a path resolves to.
enum AppPaths {
    static var rcPath: String {
        CorePaths.resolveRcPath(stored: AppSettings.shared.rcPathOverride,
                                environmentOverride: ProcessInfo.processInfo.environment["ALIASBAR_ZSHRC"],
                                homeDirectory: NSHomeDirectory())
    }

    static var historyPath: String {
        CorePaths.resolveHistoryPath(
            environmentOverride: ProcessInfo.processInfo.environment["ALIASBAR_HISTORY"],
            homeDirectory: NSHomeDirectory()
        )
    }

    /// Where `PromptStore` looks for prompt files. `ALIASBAR_PROMPTS_DIR` exists
    /// purely for testability — there is no per-app setting for this, unlike the rc
    /// path, so tests are the only caller that ever needs the override.
    static var promptsDirectory: String {
        CorePaths.resolvePromptsDirectory(
            environmentOverride: ProcessInfo.processInfo.environment["ALIASBAR_PROMPTS_DIR"],
            homeDirectory: NSHomeDirectory()
        )
    }

    /// Where `PromptUsageCounter` records invocation counts: always a sibling of
    /// whatever `promptsDirectory` resolves to, so a test pointing `ALIASBAR_PROMPTS_DIR`
    /// at a fixture also keeps usage recording out of the real `~/.aliasbar` — a
    /// second, independent override here would let a test forget to set it and
    /// silently write to the real file.
    static var promptUsagePath: String {
        (promptsDirectory as NSString).deletingLastPathComponent + "/usage.json"
    }

    /// Where `PromptCompiler` records what it has installed to `~/.claude/commands`.
    /// FIND's delivery chip (PRE-260) is the one app-side reader of this — it never
    /// writes here, only asks `PromptCompiler.installedCommands(registryPath:)`.
    static var compiledRegistryPath: String {
        CorePaths.resolveCompiledRegistryPath(
            environmentOverride: ProcessInfo.processInfo.environment["ALIASBAR_COMPILED_REGISTRY"],
            homeDirectory: NSHomeDirectory())
    }

    /// Where `SuggestionIgnoreStore` records dismissed suggestions.
    static var suggestionIgnoresPath: String {
        CorePaths.resolveSuggestionIgnoresPath(
            environmentOverride: ProcessInfo.processInfo.environment["ALIASBAR_SUGGESTION_IGNORES"],
            homeDirectory: NSHomeDirectory()
        )
    }

    // Existing call sites (including WriterTests.swift) reach the resolvers through
    // AppPaths. Kept as thin forwarders so nothing outside this file has to change,
    // while CorePaths remains the one place the actual precedence logic lives.
    static func resolveRcPath(stored: String?,
                              environmentOverride: String?,
                              homeDirectory: String) -> String {
        CorePaths.resolveRcPath(stored: stored,
                                environmentOverride: environmentOverride,
                                homeDirectory: homeDirectory)
    }

    static func resolveHistoryPath(environmentOverride: String?,
                                   homeDirectory: String) -> String {
        CorePaths.resolveHistoryPath(environmentOverride: environmentOverride,
                                     homeDirectory: homeDirectory)
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
