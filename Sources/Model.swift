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
    /// Resolution order: the persisted setting, then the ALIASBAR_ZSHRC environment
    /// variable, then ~/.zshrc.
    ///
    /// The environment variable alone is not enough. A login item launched by
    /// SMAppService does not inherit the environment of the session that registered
    /// it, so an env-only override silently reverts to ~/.zshrc after a reboot.
    static var path: String {
        if let stored = AppSettings.shared.rcPathOverride, !stored.isEmpty {
            return (stored as NSString).expandingTildeInPath
        }
        if let env = ProcessInfo.processInfo.environment["ALIASBAR_ZSHRC"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/.zshrc"
    }

    static var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func parse() -> ParseOutcome {
        parse(path: path)
    }

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
    static var path: String { NSHomeDirectory() + "/.zsh_history" }

    /// Command words extracted from history, with their invocation counts.
    /// Keyed by the command word only, so `gs` and `gs --short` both count for `gs`.
    static func commandWordCounts() -> [String: Int] {
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
    /// Directories on PATH, resolved once per scan.
    private static func pathDirectories() -> [String] {
        let raw = ProcessInfo.processInfo.environment["PATH"]
            // A GUI app launched by Finder or launchd gets a minimal PATH, so fall
            // back to the standard locations rather than reporting no conflicts at all.
            ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        return raw.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    static func detect(in entries: [ShellEntry]) -> [Conflict] {
        var conflicts: [Conflict] = []
        let byName = Dictionary(grouping: entries, by: \.name)
        let dirs = pathDirectories()
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
