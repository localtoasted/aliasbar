import Foundation

// MARK: - Model

struct ShellEntry: Identifiable, Hashable {
    enum Kind: String { case alias = "Aliases", function = "Functions" }
    let kind: Kind
    let name: String
    let command: String
    let comment: String?

    /// Where this definition physically lives. Powers the "By file" bucket and lets
    /// the editor refuse to touch anything it did not write.
    let sourceFile: String
    let line: Int
    /// True when the definition sits inside AliasBar's managed block, which is the
    /// only region the writer is allowed to modify.
    let managed: Bool

    var id: String { "\(kind.rawValue)-\(name)-\(sourceFile):\(line)" }

    var sourceDisplayName: String {
        (sourceFile as NSString).lastPathComponent
    }
}

/// Which entry fields participate in a search.
enum SearchScope: String, CaseIterable, Identifiable {
    case name, nameComment, everything
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name only"
        case .nameComment: return "Name and comment"
        case .everything: return "Name, comment, and command"
        }
    }
}

/// An entry paired with how often it has actually been run.
struct RankedEntry: Identifiable, Hashable {
    let entry: ShellEntry
    let uses: Int
    var id: String { entry.id }
    var name: String { entry.name }
}

// MARK: - Parse result

/// A missing file and a file with no aliases are completely different problems, and
/// v0.1 rendered both as an empty list. Callers need to be able to tell them apart.
enum ParseOutcome {
    case ok(entries: [ShellEntry])
    case unreadable(path: String, reason: String)

    var entries: [ShellEntry] {
        if case .ok(let entries) = self { return entries }
        return []
    }

    var errorMessage: String? {
        if case .unreadable(let path, let reason) = self {
            return "Couldn't read \((path as NSString).abbreviatingWithTildeInPath): \(reason)"
        }
        return nil
    }
}

// MARK: - Managed block markers

enum ManagedBlock {
    static let begin = "# >>> aliasbar managed block >>>"
    static let end = "# <<< aliasbar managed block <<<"
    static let notice = "# Edited by AliasBar. Anything outside these markers is never touched."
}

// MARK: - Parser

enum ZshrcParser {
    /// The core parser receives a concrete path. App and future CLI defaults belong
    /// in their own adapters.
    static func parse(path: String) -> ParseOutcome {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            // Retry as Latin-1. A single stray byte in an otherwise fine rc file should
            // not make the whole app look broken.
            if let data = FileManager.default.contents(atPath: path),
               let salvaged = String(data: data, encoding: .isoLatin1) {
                return .ok(entries: parseText(salvaged, sourceFile: path))
            }
            let reason = (error as NSError).localizedFailureReason
                ?? (error as NSError).localizedDescription
            return .unreadable(path: path, reason: reason)
        }
        return .ok(entries: parseText(text, sourceFile: path))
    }

    static func parseText(_ text: String, sourceFile: String) -> [ShellEntry] {
        var entries: [ShellEntry] = []
        let lines = text.components(separatedBy: "\n")
        var pendingComments: [String] = []
        var insideManagedBlock = false
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line == ManagedBlock.begin {
                insideManagedBlock = true
                pendingComments.removeAll()
                i += 1
                continue
            }
            if line == ManagedBlock.end {
                insideManagedBlock = false
                pendingComments.removeAll()
                i += 1
                continue
            }

            if line.hasPrefix("#") {
                // The managed block's own notice line is plumbing, not documentation.
                if line != ManagedBlock.notice {
                    pendingComments.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                }
                i += 1
                continue
            }
            if line.isEmpty {
                pendingComments.removeAll()
                i += 1
                continue
            }

            if line.hasPrefix("alias ") {
                let rest = String(line.dropFirst("alias ".count))
                if let (name, value) = splitAliasAssignment(rest), !name.isEmpty {
                    entries.append(ShellEntry(kind: .alias,
                                              name: name,
                                              command: value,
                                              comment: joined(pendingComments),
                                              sourceFile: sourceFile,
                                              line: i + 1,
                                              managed: insideManagedBlock))
                }
                pendingComments.removeAll()
                i += 1
                continue
            }

            if let fnName = functionName(in: line) {
                var depth = braceDelta(of: raw)
                var body: [String] = []
                if let braceIdx = raw.firstIndex(of: "{") {
                    let after = raw[raw.index(after: braceIdx)...].trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty && after != "}" { body.append(after) }
                }
                var j = i + 1
                while j < lines.count && depth > 0 {
                    let bodyLine = lines[j]
                    depth += braceDelta(of: bodyLine)
                    if depth > 0 {
                        body.append(bodyLine)
                    } else {
                        let trimmed = bodyLine.trimmingCharacters(in: .whitespaces)
                        if trimmed != "}" && !trimmed.isEmpty { body.append(bodyLine) }
                    }
                    j += 1
                }
                let command = dedent(body).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(ShellEntry(kind: .function,
                                          name: fnName,
                                          command: command,
                                          comment: joined(pendingComments),
                                          sourceFile: sourceFile,
                                          line: i + 1,
                                          managed: insideManagedBlock))
                pendingComments.removeAll()
                i = j
                continue
            }

            pendingComments.removeAll()
            i += 1
        }
        return entries
    }

    /// Splits `name='value'` on the first `=`, then strips one layer of matching quotes.
    /// Returns nil when there is no assignment at all.
    static func splitAliasAssignment(_ rest: String) -> (String, String)? {
        guard let eq = rest.firstIndex(of: "=") else { return nil }
        let name = String(rest[..<eq]).trimmingCharacters(in: .whitespaces)
        var value = String(rest[rest.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.first == "'" && value.last == "'") || (value.first == "\"" && value.last == "\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (name, value)
    }

    private static func joined(_ comments: [String]) -> String? {
        let s = comments.joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    private static func functionName(in line: String) -> String? {
        // name() {   |   function name() {   |   function name {
        if let match = line.range(of: #"^(?:function\s+)?([A-Za-z0-9_.:@+-]+)\s*\(\s*\)\s*\{"#,
                                  options: .regularExpression) {
            var header = String(line[match])
            if header.hasPrefix("function") { header = String(header.dropFirst("function".count)) }
            if let paren = header.firstIndex(of: "(") {
                return String(header[..<paren]).trimmingCharacters(in: .whitespaces)
            }
        }
        if let match = line.range(of: #"^function\s+([A-Za-z0-9_.:@+-]+)\s*\{"#,
                                  options: .regularExpression) {
            let header = String(line[match]).dropFirst("function".count)
            if let brace = header.firstIndex(of: "{") {
                return String(header[..<brace]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func braceDelta(of line: String) -> Int {
        var delta = 0
        for ch in line {
            if ch == "{" { delta += 1 }
            if ch == "}" { delta -= 1 }
        }
        return delta
    }

    private static func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }
        guard let minIndent = indents.min(), minIndent > 0 else { return lines }
        return lines.map { line in
            line.count >= minIndent ? String(line.dropFirst(minIndent)) : line
        }
    }
}

// MARK: - Usage counts from shell history

/// Counts how many times each name has actually been run, by reading ~/.zsh_history.
/// Strictly read-only, strictly local: nothing here writes or transmits anything.
enum HistoryScanner {
    /// Command words extracted from history, with their invocation counts.
    /// Keyed by the command word only, so `gs` and `gs --short` both count for `gs`.
    static func commandWordCounts(path: String) -> [String: Int] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }

        // zsh history is frequently not valid UTF-8 (metafied bytes above 0x80), so a
        // strict decode would throw away the entire file over one bad character.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else { return [:] }

        var counts: [String: Int] = [:]
        var continuation = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)

            // Extended history format: ": <started>:<elapsed>;<command>"
            if line.hasPrefix(":"), let semi = line.firstIndex(of: ";") {
                line = String(line[line.index(after: semi)...])
            }

            // A trailing backslash continues the command onto the next line.
            if line.hasSuffix("\\") {
                continuation += String(line.dropLast())
                continue
            }
            if !continuation.isEmpty {
                line = continuation + line
                continuation = ""
            }

            for word in commandWords(in: line) {
                counts[word, default: 0] += 1
            }
        }
        return counts
    }

    /// Every position in the line where a command word can legally start: the beginning,
    /// and after each `|`, `;`, `&&`, `||`, or `$(`. Without this, `git push && gp` would
    /// only ever credit `git`.
    static func commandWords(in line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var atCommandPosition = true
        var iterator = line.startIndex

        func flush() {
            // A shell command word cannot be arbitrarily long, and history files pick up
            // junk: terminal mouse-tracking escape sequences land as one enormous line
            // full of semicolons, which splits into hundreds of meaningless tokens.
            // They could never match an alias name, but there is no reason to keep them.
            if current.count > 64 { current = "" }
            if atCommandPosition && !current.isEmpty {
                // Skip env-var prefixes (FOO=bar cmd) and leading `sudo`, so the real
                // command word gets the credit.
                if !current.contains("=") && current != "sudo" {
                    words.append(current)
                }
                // An assignment or sudo keeps us in command position for the next word.
                if !current.contains("=") && current != "sudo" { atCommandPosition = false }
            }
            current = ""
        }

        while iterator < line.endIndex {
            let ch = line[iterator]
            if ch == " " || ch == "\t" {
                flush()
            } else if ch == "|" || ch == ";" || ch == "&" || ch == "(" || ch == "{" {
                flush()
                atCommandPosition = true
            } else {
                current.append(ch)
            }
            iterator = line.index(after: iterator)
        }
        flush()
        return words
    }

    // MARK: Whole commands

    /// One distinct command line, with how often it was run and how recently.
    struct Command: Identifiable, Hashable {
        let text: String
        let count: Int
        /// Position in the file, counting from the top. Higher is more recent. Ordinal
        /// rather than a timestamp because the plain (non-extended) history format has no
        /// timestamps at all, and the file is already in chronological order either way.
        let lastSeen: Int
        var id: String { text }
    }

    /// Every distinct command in the history file, most recent occurrence wins.
    ///
    /// Unlike `commandWordCounts`, this keeps the whole line: the point is to hand you
    /// back something you can run, not to attribute a count to an alias name.
    static func commands(path: String) -> [Command] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        var lastSeen: [String: Int] = [:]
        var continuation = ""
        var ordinal = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)

            if line.hasPrefix(":"), let semi = line.firstIndex(of: ";") {
                line = String(line[line.index(after: semi)...])
            }
            if line.hasSuffix("\\") {
                continuation += String(line.dropLast()) + "\n"
                continue
            }
            if !continuation.isEmpty {
                line = continuation + line
                continuation = ""
            }

            ordinal += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard isWorthOffering(trimmed) else { continue }
            counts[trimmed, default: 0] += 1
            lastSeen[trimmed] = ordinal
        }

        return counts.map { Command(text: $0.key, count: $0.value,
                                    lastSeen: lastSeen[$0.key] ?? 0) }
    }

    /// Whether a history line should be shown back to the user at all.
    ///
    /// Shell history is not a curated list — it is a transcript, and transcripts contain
    /// things nobody meant to keep. Anything that looks like it carries a credential is
    /// dropped outright rather than shown and marked, because a secret you can see is a
    /// secret that can end up in a screenshot, a screen share, or a paste.
    ///
    /// This is a filter, not a guarantee. It cannot know that `deploy prod` takes a token
    /// from the environment. It is here to catch the obvious cases, which are also the
    /// common ones.
    static func isWorthOffering(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 512 else { return false }
        // A bare word is almost always something you would never need looked up.
        guard line.contains(" ") || line.count > 3 else { return false }

        let lowered = line.lowercased()
        for marker in secretMarkers where lowered.contains(marker) {
            return false
        }
        // A long unbroken run of base64-ish characters is a key, a token, or a hash.
        var run = 0
        for scalar in line.unicodeScalars {
            let isTokenish = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "+" || scalar == "/"
            run = isTokenish ? run + 1 : 0
            if run >= 40 { return false }
        }
        return true
    }

    /// How well a query matches a command, or nil if it does not match at all.
    ///
    /// Ordered by how much the user had to remember: a command that starts with what they
    /// typed beats one that merely contains it, which beats one where the letters only
    /// appear in order.
    static func score(_ query: String, in text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let needle = query.lowercased()
        let haystack = text.lowercased()

        if haystack.hasPrefix(needle) { return 300 }
        if let found = haystack.range(of: needle) {
            let offset = haystack.distance(from: haystack.startIndex, to: found.lowerBound)
            return 200 - min(99, offset)
        }
        var next = needle.startIndex
        for character in haystack where character == needle[next] {
            next = needle.index(after: next)
            if next == needle.endIndex { return 50 }
        }
        return nil
    }

    private static let secretMarkers = [
        "password", "passwd", "secret", "token", "api_key", "apikey", "api-key",
        "access_key", "private_key", "credential", "bearer ", "authorization:",
        "-----begin", "aws_secret", "client_secret", "ghp_", "sk-", "xoxb-",
    ]
}

// MARK: - Conflicts

/// Cases where a definition is not doing what its author thinks it does.
struct Conflict: Identifiable, Hashable {
    enum Reason: Hashable {
        /// Defined more than once. The last definition wins; earlier ones are dead.
        case redefined(times: Int, winningLine: Int)
        /// Shadows an executable found on PATH.
        case shadowsBinary(path: String)
        /// An alias and a function share a name.
        case aliasFunctionClash

        var headline: String {
            switch self {
            case .redefined(let times, _):
                return "Defined \(times) times"
            case .shadowsBinary:
                return "Shadows a command on your PATH"
            case .aliasFunctionClash:
                return "Alias and function share this name"
            }
        }

        var detail: String {
            switch self {
            case .redefined(_, let line):
                return "zsh keeps the last definition, on line \(line). The earlier ones never run."
            case .shadowsBinary(let path):
                return "Typing this name runs your definition instead of \(path). Often deliberate."
            case .aliasFunctionClash:
                return "zsh expands the alias before the function is ever considered, so the alias wins."
            }
        }
    }

    let name: String
    let reason: Reason
    var id: String { "\(name)-\(reason.headline)" }
}

enum ConflictDetector {
    /// Directories on PATH, resolved once per scan. Not file-private: `isShadowed`
    /// (below, reused by `SuggestionEngine`'s name dedup) shares this resolution
    /// rather than re-implementing PATH lookup.
    static func pathDirectories() -> [String] {
        let raw = ProcessInfo.processInfo.environment["PATH"]
            // A GUI app launched by Finder or launchd gets a minimal PATH, so fall
            // back to the standard locations rather than reporting no conflicts at all.
            ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        return raw.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    static func detect(in entries: [ShellEntry],
                       searchPaths: [String]? = nil) -> [Conflict] {
        var conflicts: [Conflict] = []
        let byName = Dictionary(grouping: entries, by: \.name)
        let dirs = searchPaths ?? pathDirectories()
        let fm = FileManager.default

        for (name, group) in byName {
            // Redefinition: same name, same kind, more than once.
            for kind in [ShellEntry.Kind.alias, .function] {
                let sameKind = group.filter { $0.kind == kind }
                if sameKind.count > 1 {
                    let winning = sameKind.map(\.line).max() ?? 0
                    conflicts.append(Conflict(name: name,
                                              reason: .redefined(times: sameKind.count,
                                                                 winningLine: winning)))
                }
            }

            // An alias and a function with the same name: the alias always wins.
            if group.contains(where: { $0.kind == .alias }),
               group.contains(where: { $0.kind == .function }) {
                conflicts.append(Conflict(name: name, reason: .aliasFunctionClash))
            }

            // Shadowing something real on PATH. Resolved against the actual filesystem
            // rather than a hardcoded list of command names.
            for dir in dirs {
                let candidate = dir + "/" + name
                if fm.isExecutableFile(atPath: candidate) {
                    conflicts.append(Conflict(name: name, reason: .shadowsBinary(path: candidate)))
                    break
                }
            }
        }
        return conflicts.sorted { $0.name < $1.name }
    }
}

// MARK: - Ranking

enum Ranker {
    /// Tiers, highest first: exact name, name prefix, name substring, comment, command.
    /// Usage count breaks ties inside a tier, which is why a bare score is not enough.
    private static func score(_ r: RankedEntry, query: String, scope: SearchScope) -> Int? {
        let name = r.entry.name.lowercased()
        let comment = (r.entry.comment ?? "").lowercased()
        let command = r.entry.command.lowercased()

        if name == query { return 500_000 }
        if name.hasPrefix(query) { return 400_000 }
        if name.contains(query) { return 300_000 }

        if scope == .name { return nil }
        if comment.contains(query) { return 200_000 }

        if scope == .nameComment { return nil }
        if command.contains(query) { return 100_000 }

        return nil
    }

    /// Ranked matches for a query. An empty query returns the rest state: whatever the
    /// user's sort order says, which defaults to most-used first.
    static func rank(_ entries: [RankedEntry],
                     query: String,
                     scope: SearchScope) -> [RankedEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            return entries.sorted {
                $0.uses != $1.uses ? $0.uses > $1.uses : $0.name < $1.name
            }
        }
        return entries
            .compactMap { r -> (RankedEntry, Int)? in
                guard let tier = score(r, query: q, scope: scope) else { return nil }
                return (r, tier)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.uses != rhs.0.uses { return lhs.0.uses > rhs.0.uses }
                // Shorter names win at equal relevance: `gs` beats `gstash` for "gs".
                if lhs.0.name.count != rhs.0.name.count {
                    return lhs.0.name.count < rhs.0.name.count
                }
                return lhs.0.name < rhs.0.name
            }
            .map(\.0)
    }

    /// Whether an entry matches at all, ignoring order. Used by BOARD, which dims
    /// non-matches instead of removing them.
    static func matches(_ r: RankedEntry, query: String, scope: SearchScope) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return score(r, query: q, scope: scope) != nil
    }
}

// MARK: - Alias name suggestion

enum AliasNameSuggester {
    /// Initials of the first few real words: `git status -sb` suggests `gs`.
    ///
    /// Flags and environment assignments are skipped — they are the part that varies, so
    /// they are the part that makes a bad name.
    static func suggest(for command: String, takenNames: Set<String>) -> String {
        let words = command.split(separator: " ").map(String.init)
            .filter { !$0.hasPrefix("-") && !$0.contains("=") && $0 != "sudo" }
        guard !words.isEmpty else { return "" }

        func clean(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        // Tried in order, longest-lived first. A collision should push toward a name
        // that is still readable rather than straight to a numbered one — `gs` taken
        // should suggest `gis`, not `gs2`.
        var candidates: [String] = []
        candidates.append(clean(words.prefix(3).compactMap { $0.first.map(String.init) }.joined()))
        if words.count >= 2 {
            candidates.append(clean(String(words[0].prefix(2)) + String(words[1].prefix(1))))
            candidates.append(clean(String(words[0].prefix(2)) + String(words[1].prefix(2))))
        }
        candidates.append(clean(String(words[0].prefix(4))))

        let usable = candidates.filter { $0.count >= 2 }
        for candidate in usable where !takenNames.contains(candidate) { return candidate }

        guard let base = usable.first else { return "" }
        for suffix in 2...9 where !takenNames.contains(base + String(suffix)) {
            return base + String(suffix)
        }
        return base
    }
}

// MARK: - Path resolution

/// Pure precedence rules for locating the rc file and the history file. Lives in the
/// Foundation-only core, not in `AppPaths`, so a second executable (the `ab` CLI) can
/// resolve paths the exact same way the app does without linking anything app-owned —
/// it just passes `stored: nil`, since it has no app settings to consult.
enum CorePaths {
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

    /// No `stored:` parameter here — unlike the rc path, there is no per-app setting
    /// that redirects where prompts live, only the environment override that makes
    /// this testable.
    static func resolvePromptsDirectory(environmentOverride: String?,
                                        homeDirectory: String) -> String {
        if let environmentOverride, !environmentOverride.isEmpty {
            return (environmentOverride as NSString).expandingTildeInPath
        }
        return homeDirectory + "/.aliasbar/prompts"
    }

    /// Where `PromptCompiler`'s ownership registry lives. Same reasoning as
    /// `resolvePromptsDirectory`: no per-app setting redirects this, only the
    /// environment override, which exists purely so FIND's delivery-chip check can be
    /// tested against a fixture registry instead of a real `~/.aliasbar/compiled.json`.
    static func resolveCompiledRegistryPath(environmentOverride: String?,
                                            homeDirectory: String) -> String {
        if let environmentOverride, !environmentOverride.isEmpty {
            return (environmentOverride as NSString).expandingTildeInPath
        }
        return homeDirectory + "/.aliasbar/compiled.json"
    }

    /// Where `SuggestionIgnoreStore` records suggestions the user has dismissed.
    /// Same shape as `resolvePromptsDirectory`: no per-app stored setting, just an
    /// environment override for testability.
    static func resolveSuggestionIgnoresPath(environmentOverride: String?,
                                             homeDirectory: String) -> String {
        if let environmentOverride, !environmentOverride.isEmpty {
            return (environmentOverride as NSString).expandingTildeInPath
        }
        return homeDirectory + "/.aliasbar/suggestion-ignores.json"
    }
}
