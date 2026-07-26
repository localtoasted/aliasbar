import Foundation

// MARK: - Step order

/// The order the first-run flow presents itself in: detect first, show what that
/// turned up, only then start asking anything. `found` is new (PRE-266); the rest
/// keeps the order PRE-239 shipped it in and PRE-277 extended it with.
///
/// Plain data, not a view concern — living here rather than in `Onboarding.swift`
/// keeps it Foundation-only and reachable from tests without pulling in SwiftUI,
/// AppKit, or Sparkle.
enum OnboardingStep: Int, CaseIterable {
    case found, shortcut, enter, file, updates, look
}

// MARK: - First-run scan

/// What the first-run scan found, before onboarding asks a single question.
///
/// Every field here is read straight from the user's own files through the same
/// concrete-path machinery `ZshrcParser`/`HistoryScanner` already expose — never a
/// canned number. That is the whole point of the found-treasure screen: it is the
/// app's first impression, and a placeholder count there would be a lie the size of
/// the entire flow.
struct OnboardingScanResult: Equatable {
    let aliasCount: Int
    let functionCount: Int
    /// Defined but never run once, per `HistoryScanner`'s usage counts — computed
    /// the exact same way `EntryStore.neverRun` (the graveyard MANAGE shows later)
    /// is, so the number onboarding leads with never drifts from the one the rest
    /// of the app shows.
    let neverRunCount: Int
    /// Top 5 by usage, highest first, ties broken by name — the "first aha": proof
    /// the app read *their* shell, shown immediately after this screen and before
    /// any question is asked.
    let topUsed: [RankedEntry]
    /// Whether a Claude Code install was found on disk. File-presence only — its
    /// contents are never read, only whether the directory exists.
    let claudeCodeDetected: Bool

    static let empty = OnboardingScanResult(aliasCount: 0, functionCount: 0, neverRunCount: 0,
                                            topUsed: [], claudeCodeDetected: false)
}

/// Runs the silent local scan onboarding's first screen presents.
///
/// Concrete-path API, matching `ZshrcParser.parse(path:)` and
/// `HistoryScanner.commands(path:)`: the app calls this with `AppPaths`'s real
/// (env-overridable) locations, tests call it with fixtures directly. Every read is
/// local and read-only — nothing here writes anything, and nothing leaves the Mac.
enum OnboardingScanner {
    static func scan(rcPath: String, historyPath: String, claudeDirectoryPath: String) -> OnboardingScanResult {
        let entries = ZshrcParser.parse(path: rcPath).entries
        let usage = HistoryScanner.commandWordCounts(path: historyPath)
        let ranked = entries.map { RankedEntry(entry: $0, uses: usage[$0.name] ?? 0) }

        let topUsed = Array(
            ranked.filter { $0.uses > 0 }
                .sorted { $0.uses != $1.uses ? $0.uses > $1.uses : $0.name < $1.name }
                .prefix(5)
        )

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: claudeDirectoryPath, isDirectory: &isDirectory)

        return OnboardingScanResult(
            aliasCount: entries.filter { $0.kind == .alias }.count,
            functionCount: entries.filter { $0.kind == .function }.count,
            neverRunCount: ranked.filter { $0.uses == 0 }.count,
            topUsed: topUsed,
            claudeCodeDetected: exists && isDirectory.boolValue
        )
    }
}

// MARK: - Found-treasure decisions

/// The found-treasure screen's three opt-in checkboxes, and the one place they are
/// ever written to settings.
///
/// A plain struct rather than inline view logic, because the mapping is the part
/// worth testing hardest — "clipboardMonitoring stays false unless checked" — and
/// that should never depend on rendering a SwiftUI view to verify.
struct OnboardingDecisions: Equatable {
    var historyUsageRanking: Bool
    var claudeCodePromptFeatures: Bool
    /// This **is** the `clipboardMonitoring` opt-in moment. Nothing about this
    /// struct or its defaults ever turns it on by itself.
    var clipboardWatching: Bool

    /// The screen's starting checkbox state: usage ranking on, clipboard watching
    /// always off until chosen, and prompt features pre-checked only when the scan
    /// actually found Claude Code — the honesty rule extends to the checkbox's own
    /// starting position, not just the numbers next to it.
    static func defaults(for scan: OnboardingScanResult) -> OnboardingDecisions {
        OnboardingDecisions(historyUsageRanking: true,
                            claudeCodePromptFeatures: scan.claudeCodeDetected,
                            clipboardWatching: false)
    }

    /// Writes the three decisions to settings. Idempotent and total: calling it
    /// again with the same values is a no-op, and every field is always written,
    /// so a partial checkbox change can never leave one of the three stale.
    func apply(to settings: AppSettings) {
        settings.historyUsageRankingEnabled = historyUsageRanking
        settings.promptFeaturesEnabled = claudeCodePromptFeatures
        settings.clipboardMonitoring = clipboardWatching
    }
}
