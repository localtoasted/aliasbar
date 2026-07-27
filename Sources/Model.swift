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
        // Which physical lines are value bytes belonging to a statement that began
        // earlier: the interior of a multi-line quoted value, a backslash-continuation
        // tail, a heredoc body. Walked once for the whole file rather than carried along
        // by the loop below, which jumps over function bodies and so cannot advance a
        // lexer of its own.
        //
        // This is the only lexer-aware decision the parser makes. The managed-block
        // markers are still matched as plain text on purpose: `AliasWriter.locateBlock`
        // finds them the same way, and the two must not disagree about where the block
        // is.
        let nested = ShellStatementLexer.linesInsideCompletedSpans(of: lines,
                                                                  from: 0,
                                                                  upTo: lines.count)
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

            // Inside somebody else's value, so it defines nothing — `alias ghost=inner`
            // between `alias outer='first` and `last'` is three words of text. Placed
            // ahead of both definition branches and behind the comment branch, so the
            // only classification that changes is definition-or-not. Falling through
            // clears the pending comments exactly as the untaken branches below would.
            if nested.contains(i) {
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

/// What a file or directory looked like at an instant: modification time to the
/// nanosecond, and size. `nil` for a path that could not be `stat`'d at all, which is
/// its own stable observation — a path that stays missing never re-reads, and one that
/// appears does.
///
/// Raw `stat(2)` rather than `FileManager.attributesOfItem`, for two reasons that each
/// decide correctness or cost somewhere in this app:
///
///   - **`stat` follows symbolic links; `attributesOfItem` does not** (it has `lstat`
///     semantics on the final component). Every reader these stamps guard —
///     `contentsOfDirectory`, `FileManager.contents(atPath:)`, `String(contentsOfFile:)`
///     — *does* follow. Stamp a symlink with `lstat` and you record the link's own mtime
///     and size, which nothing the target does can ever move: the stamp never disagrees,
///     the guarded read never happens again, and the cache is frozen for the life of the
///     process. That is not hypothetical for a menu-bar app that stays resident for
///     weeks — `~/bin -> ~/dotfiles/bin` and `~/.zsh_history -> ~/dotfiles/zsh_history`
///     are the ordinary dotfiles layout, and both froze a cache here once.
///   - **`attributesOfItem` is not one stat.** It builds a ~15-key dictionary including
///     `getpwuid`/`getgrgid` account-name resolution. Measured over a 32-directory PATH,
///     once per directory: 396 µs against 21 µs for the raw call, and 24 µs for the whole
///     per-name loop `PathExecutableIndex` exists to replace — so paying it inside
///     `revalidate` made a keystroke in the Composer 16x more expensive than no caching
///     at all.
///
/// One declaration, shared by every freshness gate in the app, so a fix to the semantics
/// cannot land at one site and be forgotten at the next-door one. That is exactly how the
/// second of the two symlink freezes above survived the fix to the first.
struct FileStamp: Equatable {
    var seconds: Int
    var nanoseconds: Int
    var size: Int64

    static func of(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStamp(seconds: info.st_mtimespec.tv_sec,
                         nanoseconds: info.st_mtimespec.tv_nsec,
                         size: info.st_size)
    }
}

/// A snapshot of which command names each PATH directory offers.
///
/// `ConflictDetector.detect(in:)` used to ask the filesystem "is `<dir>/<name>`
/// executable?" once per (entry, directory) pair. A 200-entry rc file over a
/// 20-directory developer PATH is 4,000 stat calls, made from `EntryStore.reload()`
/// on the main thread on the way to showing the popover. `SuggestionEngine` is worse
/// still: `proposeName` probes up to a thousand candidate names for a single
/// suggestion, each one its own walk of the whole PATH. One `contentsOfDirectory`
/// per directory answers all of them at once.
///
/// Two things keep this honest rather than merely fast:
///
///   - Every directory carries its own `stat`, and every request for the shared index
///     (`ConflictDetector.executableIndex`) re-reads it. Creating or removing an entry
///     moves a directory's mtime, so a `brew install` between two summons costs one
///     re-listing of one directory and is visible immediately. The filesystem is the
///     invalidation signal — there is no in-app dirty flag to forget to set, the same
///     reasoning `loadHistoryIfNeeded` and the prompt-delivery snapshot already use.
///     Time *and* size because a same-second change can leave the time looking
///     untouched at whatever resolution the volume records.
///   - A listing says a name *exists*, not that it is *executable*, and a `chmod`
///     moves no directory's mtime at all. So a name the listing knows about is still
///     confirmed with `isExecutableFile` before it is reported — the exact check the
///     old loop made, now made once per hit instead of once per (name, directory).
///     A directory that refuses to be listed (no read permission, or it is not a
///     directory) keeps the old per-name stat, so nothing it holds becomes invisible.
///
/// The listing is a filter on which directories are worth confirming, never an answer
/// in its own right, so it has to be at least as permissive as the volume it describes
/// — see `Listing.foldedNames`. Get that backwards and the `continue` fires before the
/// confirming stat ever runs, and a real shadow goes unreported.
///
/// That "at least as permissive" claim is only provable for ASCII, which is why the skip
/// is gated on it. `String.lowercased()` is Unicode case *mapping*; a case-insensitive
/// APFS volume compares by case *folding*, and the two are not the same relation. Where
/// they differ the volume is the more permissive of the two, so an un-gated skip would
/// drop a directory the volume would have matched. Outside ASCII the filter is simply
/// switched off and every directory is confirmed by `isExecutableFile`, exactly as the
/// original loop did — slower for a handful of names, never wrong.
///
/// With that gate in place the result is answer-for-answer identical to the loop it
/// replaces, including which directory wins when several hold the same name: PATH order,
/// first match. (Without it, it was not: an earlier directory holding a spelling that
/// folds to the query but does not lowercase to it was skipped, and a *later* directory
/// got reported — so `Conflict.shadowsBinary` could name a binary the user's shell would
/// not actually run.)
struct PathExecutableIndex {
    /// PATH order, which is the order a lookup reports its winner in. Also the cache
    /// key — an index built for injected test paths can never answer for the real PATH.
    let searchPaths: [String]

    private typealias Stamp = FileStamp

    private struct Listing {
        var stamp: Stamp?
        /// Lowercased, because the volume this app ships on is case-insensitive APFS by
        /// default, so `isExecutableFile` is too and an exact-byte `Set` lookup is not.
        /// `/usr/bin` alone ships `Rez`, `DeRez`, `SetFile`, `GetFileInfo`,
        /// `networkQuality` and two dozen more; on an exact-byte set, asking about
        /// `rez` skips the directory that holds it and the shadow advisory goes silent
        /// on a name that really is taken. Only consulted when `allASCII` holds, where
        /// lowercasing and the volume's fold are the same relation — so folding really
        /// can only add a candidate, and the `isExecutableFile` confirm still decides.
        var foldedNames: Set<String>
        /// True when every name in this listing is ASCII, which is the region where
        /// `lowercased()` provably agrees with a case-insensitive volume's comparison.
        /// One non-ASCII filename anywhere in the directory disables the skip for that
        /// directory: the cost is a stat per lookup there, and the alternative is a
        /// silently missed shadow. Deliberately NOT solved by swapping in
        /// `folding(options: .caseInsensitive)` — that still disagrees with the volume on
        /// about ten pairs (the U+1C80–1C88 historic Cyrillic forms, U+FEFF) and is
        /// slower on the listing path.
        var allASCII: Bool
        /// False when the directory refused to be listed; lookups fall back to a
        /// direct `isExecutableFile` there, exactly as before this index existed.
        var listable: Bool
    }
    private var listings: [Listing]

    init(searchPaths: [String]) {
        self.searchPaths = searchPaths
        self.listings = Array(repeating: Listing(stamp: nil, foldedNames: [],
                                                 allASCII: false, listable: false),
                              count: searchPaths.count)
        for index in searchPaths.indices { load(index) }
    }

    /// Re-lists only the directories whose stamp has moved. One `stat` per PATH
    /// directory; on an unchanged PATH that is the whole cost of a lookup, against
    /// one stat per (name, directory) before.
    mutating func revalidate() {
        for index in searchPaths.indices {
            if Stamp.of(searchPaths[index]) != listings[index].stamp {
                load(index)
            }
        }
    }

    private mutating func load(_ index: Int) {
        let path = searchPaths[index]
        // Stamp first, list second. A change that lands between the two leaves the
        // stamp looking older than the listing, so the next request re-lists and is
        // merely redundant. The other order would bake in a stamp that already
        // describes content this listing missed, and the miss would be permanent.
        let stamp = Stamp.of(path)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: path)
        let entries = contents ?? []
        listings[index] = Listing(stamp: stamp,
                                  foldedNames: Set(entries.map { $0.lowercased() }),
                                  allASCII: entries.allSatisfy(Self.isASCII),
                                  listable: contents != nil)
    }

    private static func isASCII(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy(\.isASCII)
    }

    /// The first executable on PATH with this name, or nil. The full path, because
    /// that is what `Conflict.shadowsBinary` shows the user.
    func executablePath(for name: String) -> String? {
        // Only a bare filename can be answered from a directory listing. Anything
        // holding a separator (or nothing at all) is left to the filesystem, which is
        // what the old loop did for every name.
        let listable = !name.isEmpty && !name.contains("/")
        let folded = name.lowercased()
        // Both sides of the comparison have to be ASCII for lowercasing to mean what the
        // volume means. A non-ASCII query, or a directory holding any non-ASCII name,
        // falls through to the confirming stat rather than risking a skip the volume
        // would not have made.
        let comparable = listable && Self.isASCII(name)
        let fm = FileManager.default
        for (index, directory) in searchPaths.enumerated() {
            if comparable, listings[index].listable, listings[index].allASCII,
               !listings[index].foldedNames.contains(folded) {
                continue
            }
            // The on-disk spelling is deliberately not substituted here: the reported
            // path is what `Conflict.shadowsBinary` shows the user, and the old loop
            // reported the name they typed.
            let candidate = directory + "/" + name
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func contains(_ name: String) -> Bool { executablePath(for: name) != nil }
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

    /// The one PATH snapshot every shadow lookup in the process shares, re-stamped on
    /// every call (see `PathExecutableIndex`). Held rather than rebuilt because the
    /// per-keystroke callers — `ComposerState`'s live shadow advisory,
    /// `SuggestionEngine.proposeName`'s probe loop — each want one name, and building
    /// an index for one name would trade a stat storm for a listing storm.
    ///
    /// Rebuilt from scratch rather than revalidated whenever the caller asks about a
    /// different PATH than the cached one holds, which is what keeps `searchPaths:`
    /// injectable: a test's fake directory and the real machine's PATH can never
    /// answer for each other.
    ///
    /// `nonisolated(unsafe)` because the `ab` CLI compiles this file under
    /// `-swift-version 6`, where a mutable static is an error unless the safety claim
    /// is stated. The claim: every reader is main-actor confined — `EntryStore.reload`
    /// (Store.swift:62), `ComposerState`'s shadow advisory (ComposerState.swift:164),
    /// `SuggestionEngine.proposeName` (SuggestionEngine.swift:147), and the tests' own
    /// top-level code — while the CLI never references `ConflictDetector` at all. It is
    /// an annotation, not a lock; anything that later reads this off the main thread has
    /// to isolate it properly rather than inherit the exemption.
    nonisolated(unsafe) private static var indexCache: PathExecutableIndex?

    static func executableIndex(searchPaths: [String]? = nil) -> PathExecutableIndex {
        let dirs = searchPaths ?? pathDirectories()
        guard var cached = indexCache, cached.searchPaths == dirs else {
            let fresh = PathExecutableIndex(searchPaths: dirs)
            indexCache = fresh
            return fresh
        }
        cached.revalidate()
        indexCache = cached
        return cached
    }

    static func detect(in entries: [ShellEntry],
                       searchPaths: [String]? = nil) -> [Conflict] {
        var conflicts: [Conflict] = []
        let byName = Dictionary(grouping: entries, by: \.name)
        // One PATH snapshot for the whole scan, not one filesystem probe per
        // (entry, directory) pair.
        let executables = executableIndex(searchPaths: searchPaths)

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

            // Shadowing something real on PATH. Still resolved against the actual
            // filesystem rather than a hardcoded list of command names — the index
            // narrows which directories are worth asking, it does not answer for them.
            if let candidate = executables.executablePath(for: name) {
                conflicts.append(Conflict(name: name, reason: .shadowsBinary(path: candidate)))
            }
        }
        return conflicts.sorted { $0.name < $1.name }
    }
}

// MARK: - Ranking

enum Ranker {
    /// Tiers, highest first: exact name, name prefix, name substring, comment, command.
    /// Usage count breaks ties inside a tier, which is why a bare score is not enough.
    ///
    /// Takes raw lowercased fields rather than `RankedEntry` so this one ladder can be
    /// shared with anything else that scores a shell-shaped thing by name/comment/
    /// command — `ShortcutRanker` (`DialectContext.swift`) scores `Shortcut`, a
    /// different type with no relationship to `RankedEntry`, and calls this directly
    /// instead of keeping its own copy of the same five numbers in sync by hand.
    static func shellFieldScore(name: String, comment: String, command: String,
                                query: String, scope: SearchScope) -> Int? {
        if name == query { return 500_000 }
        if name.hasPrefix(query) { return 400_000 }
        if name.contains(query) { return 300_000 }

        if scope == .name { return nil }
        if comment.contains(query) { return 200_000 }

        if scope == .nameComment { return nil }
        if command.contains(query) { return 100_000 }

        return nil
    }

    private static func score(_ r: RankedEntry, query: String, scope: SearchScope) -> Int? {
        shellFieldScore(name: r.entry.name.lowercased(),
                        comment: (r.entry.comment ?? "").lowercased(),
                        command: r.entry.command.lowercased(),
                        query: query, scope: scope)
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

    /// Where `OnboardingScanner` looks for a Claude Code install to detect. Same
    /// shape again: no stored setting, just an environment override so the
    /// first-run scan can be pointed at a fixture directory in tests instead of a
    /// real `~/.claude`.
    static func resolveClaudeDirectory(environmentOverride: String?,
                                       homeDirectory: String) -> String {
        if let environmentOverride, !environmentOverride.isEmpty {
            return (environmentOverride as NSString).expandingTildeInPath
        }
        return homeDirectory + "/.claude"
    }

    /// Where `PromptCompiler` writes the `.md` files it installs — Claude Code's own
    /// command directory, not anything under `~/.aliasbar`. Same shape as the other
    /// resolvers here: no per-app stored setting, just an environment override so
    /// MANAGE's Delivery bucket (the one app-side writer of this directory) can be
    /// tested against a fixture instead of a real `~/.claude/commands`.
    static func resolveClaudeCommandsDirectory(environmentOverride: String?,
                                               homeDirectory: String) -> String {
        if let environmentOverride, !environmentOverride.isEmpty {
            return (environmentOverride as NSString).expandingTildeInPath
        }
        return homeDirectory + "/.claude/commands"
    }

    /// Where `PromptInbox` scans for untrusted proposal files — the directory
    /// `AuditPrompt`'s `.localAgent` ending tells an agent to write into. Same
    /// shape as `resolvePromptsDirectory`: no per-app stored setting, just an
    /// environment override for testability.
    static func resolveInboxDirectory(environmentOverride: String?,
                                      homeDirectory: String) -> String {
        if let environmentOverride, !environmentOverride.isEmpty {
            return (environmentOverride as NSString).expandingTildeInPath
        }
        return homeDirectory + "/.aliasbar/inbox"
    }
}
