import SwiftUI

// MARK: - Store

final class EntryStore: ObservableObject {
    @Published private(set) var ranked: [RankedEntry] = []
    @Published private(set) var conflicts: [Conflict] = []
    /// Set when the rc file could not be read at all, which is a different problem
    /// from a file that simply defines nothing.
    @Published private(set) var loadError: String?

    private var usage: [String: Int] = [:]
    /// History is far larger than an rc file and changes far less meaningfully, so it
    /// is scanned once per launch rather than on every popover open.
    private var usageLoaded = false

    init() { reload() }

    func reload() {
        if !usageLoaded {
            usage = HistoryScanner.commandWordCounts()
            usageLoaded = true
        }
        let outcome = ZshrcParser.parse()
        loadError = outcome.errorMessage
        let entries = outcome.entries
        ranked = entries.map { RankedEntry(entry: $0, uses: usage[$0.name] ?? 0) }
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

    /// The graveyard: defined, never run. The most interesting number in the app.
    var neverRun: [RankedEntry] {
        ranked.filter { $0.uses == 0 }.sorted { $0.name < $1.name }
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
