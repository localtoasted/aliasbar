import SwiftUI

// MARK: - Store

final class EntryStore: ObservableObject {
    @Published private(set) var ranked: [RankedEntry] = []
    @Published private(set) var conflicts: [Conflict] = []
    /// Set when the rc file could not be read at all, which is a different problem
    /// from a file that simply defines nothing.
    @Published private(set) var loadError: String?

    /// Read only to decide whether `usage` ever reaches `ranked` — see `reload`.
    private let settings: AppSettings
    private var usage: [String: Int] = [:]
    /// History is far larger than an rc file and changes far less meaningfully, so it
    /// is scanned once per launch rather than on every popover open.
    private var usageLoaded = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
        reload()
    }

    func reload() {
        if !usageLoaded {
            usage = HistoryScanner.commandWordCounts()
            usageLoaded = true
        }
        let outcome = ZshrcParser.parse()
        loadError = outcome.errorMessage
        let entries = outcome.entries
        // The scan above still runs even when the setting is off — it's a cheap local
        // read, and keeping it warm means flipping the setting back on takes effect on
        // the very next reload rather than needing a fresh history scan. What the
        // setting actually gates is whether a count ever reaches a `RankedEntry` at
        // all, which is what keeps it out of ranking (`Ranker`/`ShortcutRanker` both
        // tie-break on `uses`) and out of every "×N" badge in FIND/BOARD/MANAGE.
        let effectiveUsage = settings.historyUsageRankingEnabled ? usage : [:]
        ranked = entries.map { RankedEntry(entry: $0, uses: effectiveUsage[$0.name] ?? 0) }
        conflicts = ConflictDetector.detect(in: entries)
    }

    /// Forces a fresh history scan. Wired to the explicit Refresh action only.
    func reloadIncludingUsage() {
        usageLoaded = false
        reload()
    }

    // MARK: Filtering

    /// Entries the user has chosen to see at all, per the show-functions and
    /// show-aliases settings.
    func visible(_ settings: AppSettings) -> [RankedEntry] {
        ranked.filter { r in
            switch r.entry.kind {
            case .function: return settings.showFunctions
            case .alias: return settings.showAliases
            }
        }
    }

    // MARK: Buckets

    var functions: [RankedEntry] { ranked.filter { $0.entry.kind == .function } }
    var aliases: [RankedEntry] { ranked.filter { $0.entry.kind == .alias } }
    var mostUsed: [RankedEntry] { ranked.filter { $0.uses > 0 }.sorted { $0.uses > $1.uses } }

    /// The graveyard: defined, never run. The most interesting number in the app —
    /// which is exactly why it needs its own guard rather than falling out of
    /// `reload`'s zeroed `uses` for free: `uses == 0` for every single entry when
    /// tracking is off would otherwise read as "you've never run anything you've
    /// defined", a much stronger and false claim compared to `mostUsed`'s symmetric
    /// (and honest) emptiness above.
    var neverRun: [RankedEntry] {
        guard settings.historyUsageRankingEnabled else { return [] }
        return ranked.filter { $0.uses == 0 }.sorted { $0.name < $1.name }
    }

    var conflictedEntries: [RankedEntry] {
        let names = Set(conflicts.map(\.name))
        return ranked.filter { names.contains($0.name) }.sorted { $0.name < $1.name }
    }

    var byFile: [(file: String, entries: [RankedEntry])] {
        Dictionary(grouping: ranked, by: { $0.entry.sourceFile })
            .map { (file: $0.key, entries: $0.value.sorted { $0.entry.line < $1.entry.line }) }
            .sorted { $0.file < $1.file }
    }

    func conflicts(for name: String) -> [Conflict] {
        conflicts.filter { $0.name == name }
    }

    // MARK: Sorting

    func sorted(_ entries: [RankedEntry], by order: SortOrder) -> [RankedEntry] {
        switch order {
        case .usage:
            return entries.sorted {
                $0.uses != $1.uses ? $0.uses > $1.uses : $0.name < $1.name
            }
        case .alphabetical:
            return entries.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .fileOrder:
            return entries.sorted { $0.entry.line < $1.entry.line }
        }
    }
}
