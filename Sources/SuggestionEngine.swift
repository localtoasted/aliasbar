import Foundation

// MARK: - Full-command frequency

/// `HistoryScanner.commands(path:)` already groups history lines by their trimmed
/// text and filters secrets through `isWorthOffering`. What it does not do is treat
/// two lines that differ only in incidental spacing (`git  status` vs `git status`)
/// as the same command — its job is to hand back something runnable, not something
/// to group by intent. This extension adds that grouping on top, without re-scanning
/// the file or re-implementing the secret filter: everything here is built from
/// `commands(path:)`'s already-filtered output, so nothing can reach a suggestion
/// through a path that skipped `isWorthOffering`.
extension HistoryScanner {
    /// One entry per command, normalized by collapsing every run of whitespace to a
    /// single space (in addition to the trimming `commands(path:)` already applied).
    /// Counts and `lastSeen` from every variant that collapses to the same text are
    /// merged: counts sum, `lastSeen` takes the most recent (highest) ordinal.
    static func normalizedCommands(path: String) -> [Command] {
        var counts: [String: Int] = [:]
        var lastSeen: [String: Int] = [:]
        for command in commands(path: path) {
            let normalized = collapseWhitespace(command.text)
            // Belt and suspenders: collapsing whitespace can only ever shorten a
            // line, never introduce new content, so a line that already passed
            // `isWorthOffering` cannot fail it here. Checked anyway so this file's
            // secret-safety property never depends on that reasoning holding up
            // under some future change to either function.
            guard !normalized.isEmpty, isWorthOffering(normalized) else { continue }
            counts[normalized, default: 0] += command.count
            lastSeen[normalized] = max(lastSeen[normalized] ?? 0, command.lastSeen)
        }
        return counts.map { Command(text: $0.key, count: $0.value, lastSeen: lastSeen[$0.key] ?? 0) }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}

// MARK: - PATH lookup reuse

extension ConflictDetector {
    /// Whether `name` matches an executable found on PATH — the same filesystem
    /// check `detect(in:)` uses to report `.shadowsBinary`, exposed as a single-name
    /// lookup so other core code (`SuggestionEngine`'s name dedup) can reuse it
    /// without re-scanning every entry the way a full conflict pass does.
    static func isShadowed(_ name: String, searchPaths: [String]? = nil) -> Bool {
        let dirs = searchPaths ?? pathDirectories()
        let fm = FileManager.default
        return dirs.contains { fm.isExecutableFile(atPath: $0 + "/" + name) }
    }
}

// MARK: - Suggestion

/// One full command from history that keeps coming up, and the name it could go by.
struct AliasSuggestion: Identifiable, Hashable {
    let command: String
    let count: Int
    let proposedName: String
    var id: String { command }
}

// MARK: - SuggestionEngine

enum SuggestionEngine {
    /// A command has to show up this many times before typing it out is worth
    /// replacing with an alias at all.
    static let minimumOccurrenceCount = 5
    /// A single word is already about as fast to type as any alias name would be,
    /// so it is never a candidate no matter how often it recurs.
    static let minimumWordCount = 2

    /// Suggestions mined from `history`, ready to offer as new aliases.
    ///
    /// - `existingEntries`: the current rc file's parsed contents. Used two ways —
    ///   any alias command a candidate already collapses onto (exact match, or the
    ///   candidate is that alias's command plus a trailing-args suffix) removes the
    ///   candidate, and every existing name (alias or function) is off-limits for
    ///   the proposed name.
    /// - `ignores`: full command text the user has already dismissed a suggestion
    ///   for (see `SuggestionIgnoreStore`). Compared against the normalized text, so
    ///   an ignore survives incidental respacing in later history the same way
    ///   coverage-by-alias does.
    /// - `pathLookup`: reports whether a candidate name collides with something on
    ///   PATH. Real callers pass `ConflictDetector.isShadowed`; tests inject a fake
    ///   so this stays hermetic (no real filesystem PATH scan in a unit test).
    ///
    /// Order is deterministic: count descending, then command text ascending —
    /// callers needing "most worth aliasing first" get that for free, and a fixture
    /// run twice produces byte-identical output.
    static func suggest(history: String,
                        existingEntries: [ShellEntry],
                        ignores: Set<String>,
                        pathLookup: (String) -> Bool) -> [AliasSuggestion] {
        let aliasCommands = existingEntries.filter { $0.kind == .alias }.map(\.command)
        var takenNames = Set(existingEntries.map(\.name))

        let candidates = HistoryScanner.normalizedCommands(path: history)
            .filter { $0.count >= minimumOccurrenceCount }
            .filter { wordCount($0.text) >= minimumWordCount }
            .filter { !ignores.contains($0.text) }
            .filter { !isCovered($0.text, by: aliasCommands) }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.text < rhs.text
            }

        var suggestions: [AliasSuggestion] = []
        for candidate in candidates {
            let name = proposeName(for: candidate.text, avoiding: takenNames, pathLookup: pathLookup)
            guard !name.isEmpty else { continue }
            // Reserve the name immediately so two candidates in the same batch can
            // never be handed the same proposal — dedup applies within a single
            // `suggest` call, not only against what already existed beforehand.
            takenNames.insert(name)
            suggestions.append(AliasSuggestion(command: candidate.text, count: candidate.count, proposedName: name))
        }
        return suggestions
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(separator: " ").count
    }

    /// True when `command` is already reachable through an existing alias: either
    /// the alias runs exactly this command, or `command` is that alias's command
    /// with extra arguments tacked on the end (`git log --oneline` is covered by an
    /// alias for `git log`, since typing the alias and then the extra flags is no
    /// slower than what history already shows the user doing).
    private static func isCovered(_ command: String, by aliasCommands: [String]) -> Bool {
        aliasCommands.contains { existing in
            !existing.isEmpty && (command == existing || command.hasPrefix(existing + " "))
        }
    }

    /// `AliasNameSuggester.suggest` only knows about `takenNames`; it has no notion
    /// of PATH. This wraps it in a retry loop that keeps feeding back names
    /// `pathLookup` rejects as additional "taken" names, so the suggester's own
    /// fallback ladder (shorter stems, then numbered suffixes) runs again against a
    /// wider exclusion set.
    ///
    /// `AliasNameSuggester.suggest` has one deliberate escape hatch of its own: if
    /// every stem and every numbered suffix it tries is already taken, it returns
    /// the base stem anyway rather than nothing. Looping on that here would spin
    /// forever, since re-adding an already-fallen-back-to name changes nothing about
    /// what the suggester tries next. The retry loop is bounded, and if it's still
    /// stuck when it runs out, a `2`, `3`, ... suffix is appended directly — cruder
    /// than the suggester's own ladder, but guaranteed to terminate.
    private static func proposeName(for command: String, avoiding: Set<String>,
                                    pathLookup: (String) -> Bool) -> String {
        var excluded = avoiding
        var candidate = AliasNameSuggester.suggest(for: command, takenNames: excluded)
        guard !candidate.isEmpty else { return "" }

        var attempts = 0
        while (excluded.contains(candidate) || pathLookup(candidate)) && attempts < 20 {
            excluded.insert(candidate)
            let next = AliasNameSuggester.suggest(for: command, takenNames: excluded)
            if next == candidate {
                // The suggester has nothing left to try and is repeating itself.
                break
            }
            candidate = next
            attempts += 1
        }

        guard excluded.contains(candidate) || pathLookup(candidate) else { return candidate }

        var suffix = 2
        while suffix < 1000,
              excluded.contains(candidate + String(suffix)) || pathLookup(candidate + String(suffix)) {
            suffix += 1
        }
        return candidate + String(suffix)
    }

    /// Convenience for real callers: PATH lookups go through
    /// `ConflictDetector.isShadowed`, the same mechanism `detect(in:)` uses, so
    /// nothing outside tests needs to construct its own `pathLookup` closure.
    static func suggest(history: String,
                        existingEntries: [ShellEntry],
                        ignores: Set<String>) -> [AliasSuggestion] {
        suggest(history: history, existingEntries: existingEntries, ignores: ignores,
                pathLookup: { ConflictDetector.isShadowed($0) })
    }
}

// MARK: - SuggestionIgnoreStore

/// Local, per-machine record of which suggested commands the user has dismissed,
/// stored at `~/.aliasbar/suggestion-ignores.json`. Same shape as
/// `PromptUsageCounter`: concrete-path API, atomic temp+rename writes, tolerant of a
/// missing or corrupt file (starts fresh rather than failing) — a dismissed-list is
/// a convenience, never something worth crashing over or losing history-scanning
/// over.
enum SuggestionIgnoreStore {
    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Every ignored command's full text. A missing or corrupt file reads as empty.
    static func all(path: String) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return Set((try? decoder.decode([String].self, from: data)) ?? [])
    }

    @discardableResult
    static func ignore(_ command: String, path: String) -> Set<String> {
        var entries = all(path: path)
        entries.insert(command)
        write(entries, path: path)
        return entries
    }

    @discardableResult
    static func unignore(_ command: String, path: String) -> Set<String> {
        var entries = all(path: path)
        entries.remove(command)
        write(entries, path: path)
        return entries
    }

    private static func write(_ entries: Set<String>, path: String) {
        guard let data = try? encoder.encode(entries.sorted()) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let tempPath = directory + "/.aliasbar-suggestion-ignores-\(UUID().uuidString)"
        do {
            try data.write(to: URL(fileURLWithPath: tempPath))
        } catch {
            return
        }
        if rename(tempPath, path) != 0 {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
    }
}
