import Foundation

// `ab`: a command-line front end onto the same core the app uses — ZshrcParser,
// HistoryScanner, Ranker, AliasNameSuggester, and AliasWriter. It adds no parsing,
// ranking, or writing logic of its own; every rule an alias has to pass lives in
// AliasWriter and applies here exactly as it does in the app.
//
// Never prompts. A CLI has no reliable way to tell a human is at the keyboard, and a
// hang waiting on stdin in a script or a cron job is worse than a refusal with a clear
// exit code. Every decision that would otherwise need a prompt (confirming collateral
// damage, picking a name) is instead a flag, with a documented refusal when it's absent.

// MARK: - Exit codes

/// v1 contract: 0 ok, 2 usage error, 3 writer refusal, 4 nothing to do, 5 unreadable file.
enum ExitCode: Int32 {
    case ok = 0
    case usage = 2
    case writerRefusal = 3
    case nothingToDo = 4
    case unreadableFile = 5
}

/// Writes a message to stderr and exits with the given code. Every failure path in
/// this CLI funnels through here so stdout stays clean for `--json` and for anything
/// piping the human-readable output.
func fail(_ code: ExitCode, _ message: String) -> Never {
    FileHandle.standardError.write(Data("ab: \(message)\n".utf8))
    exit(code.rawValue)
}

let usageText = """
Usage: ab <command> [options]

Commands:
  list [--json]
      Parse the rc file and print name<TAB>command, one per line.
      Managed entries (the ones AliasBar's own block owns) have a * before the name.

  search <query> [--json]
      Rank entries by name, comment, and command against <query>. Top 20.

  add <name> <command> [--comment <text>] [--force-collateral]
      Write or update an alias in the managed block.

  last [n]
      Print the n most recent distinct history commands (default 10), newest first.

  promote [n] [--name <name>] [--force-collateral]
      Take history command #n (default 1, most recent) and create an alias for it.
      Without --name, a name is suggested and deduplicated against existing names.

Path resolution:
  rc file:  --file  >  $ALIASBAR_ZSHRC  >  ~/.zshrc
  history:  $ALIASBAR_HISTORY  >  ~/.zsh_history

Exit codes: 0 ok, 2 usage error, 3 writer refusal, 4 nothing to do, 5 unreadable file.
"""

// MARK: - Argument parsing

/// Deliberately hand-rolled rather than pulled in as a dependency: no SPM in this
/// project, and the grammar here (a handful of value flags and boolean flags per
/// command, plus positionals) doesn't need more than this.
struct UsageError: Error {
    let message: String
}

struct ParsedArgs {
    var positionals: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
}

func parseArgs(_ args: [String], valueFlags: Set<String>, boolFlags: Set<String>) throws -> ParsedArgs {
    var result = ParsedArgs()
    var i = 0
    while i < args.count {
        let arg = args[i]
        if valueFlags.contains(arg) {
            guard i + 1 < args.count else {
                throw UsageError(message: "\(arg) requires a value")
            }
            result.values[arg] = args[i + 1]
            i += 2
        } else if boolFlags.contains(arg) {
            result.flags.insert(arg)
            i += 1
        } else if arg.hasPrefix("--") {
            throw UsageError(message: "unknown flag \(arg)")
        } else {
            result.positionals.append(arg)
            i += 1
        }
    }
    return result
}

/// Parses `args` against the given flag grammar, or exits with a usage error. Every
/// command calls this first so a bad invocation fails the same way everywhere.
func parseArgsOrExit(_ args: [String], valueFlags: Set<String>, boolFlags: Set<String>) -> ParsedArgs {
    do {
        return try parseArgs(args, valueFlags: valueFlags, boolFlags: boolFlags)
    } catch let error as UsageError {
        fail(.usage, error.message)
    } catch {
        fail(.usage, "\(error)")
    }
}

// MARK: - Path resolution

/// `--file` sits above the core's own precedence chain (env var, then `~/.zshrc`).
/// The chain itself is `CorePaths.resolveRcPath`, called with `stored: nil` — the CLI
/// has no app settings to consult, which is the entire point of that parameter.
func resolveRcPath(fileFlag: String?) -> String {
    if let fileFlag, !fileFlag.isEmpty {
        return (fileFlag as NSString).expandingTildeInPath
    }
    return CorePaths.resolveRcPath(stored: nil,
                                   environmentOverride: ProcessInfo.processInfo.environment["ALIASBAR_ZSHRC"],
                                   homeDirectory: NSHomeDirectory())
}

func resolveHistoryPath() -> String {
    CorePaths.resolveHistoryPath(environmentOverride: ProcessInfo.processInfo.environment["ALIASBAR_HISTORY"],
                                 homeDirectory: NSHomeDirectory())
}

// MARK: - Loading the rc file

/// Parses the rc file, or exits with the unreadable-file code.
///
/// A missing rc file is not an error here any more than it is in the app: it just
/// means there is nothing to list yet, and `add`/`promote` are perfectly able to
/// create the file from scratch. Only a file that exists and genuinely can't be read
/// (bad permissions, an encoding `ZshrcParser` can't salvage) is a real failure.
func loadEntriesOrExit(path: String) -> [ShellEntry] {
    switch ZshrcParser.parse(path: path) {
    case .ok(let entries):
        return entries
    case .unreadable(let unreadablePath, let reason):
        if FileManager.default.fileExists(atPath: unreadablePath) {
            fail(.unreadableFile, "couldn't read \(unreadablePath): \(reason)")
        }
        return []
    }
}

// MARK: - Output

struct EntryRow: Codable {
    let kind: String
    let name: String
    let command: String
    let comment: String?
    let managed: Bool
    let sourceFile: String
    let line: Int
    let uses: Int?
}

func row(_ entry: ShellEntry, uses: Int? = nil) -> EntryRow {
    EntryRow(kind: entry.kind == .alias ? "alias" : "function",
             name: entry.name,
             command: entry.command,
             comment: entry.comment,
             managed: entry.managed,
             sourceFile: entry.sourceFile,
             line: entry.line,
             uses: uses)
}

/// A single compact JSON array to stdout. No pretty-printing, no ANSI — this output
/// is for scripts, and scripts want one line they can pipe to `jq`, not decoration.
func printJSON(_ rows: [EntryRow]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(rows), let text = String(data: data, encoding: .utf8) else {
        fail(.usage, "internal error: failed to encode JSON")
    }
    print(text)
}

/// name<TAB>command, one per line, managed entries prefixed with `*` on the name.
/// A literal tab rather than padded spaces: it stays exactly two fields per line, so
/// `cut -f2` or `column -t -s $'\t'` both work on it, which hand-padded columns don't.
func printHuman(_ entries: [ShellEntry]) {
    for entry in entries {
        let marker = entry.managed ? "*" : ""
        print("\(marker)\(entry.name)\t\(entry.command)")
    }
}

// MARK: - list

func runList(_ args: [String]) {
    let parsed = parseArgsOrExit(args, valueFlags: ["--file"], boolFlags: ["--json"])
    guard parsed.positionals.isEmpty else {
        fail(.usage, "list takes no positional arguments")
    }

    let path = resolveRcPath(fileFlag: parsed.values["--file"])
    let entries = loadEntriesOrExit(path: path)
    let sorted = entries.sorted { lhs, rhs in
        let l = lhs.name.lowercased()
        let r = rhs.name.lowercased()
        return l == r ? lhs.name < rhs.name : l < r
    }

    if parsed.flags.contains("--json") {
        printJSON(sorted.map { row($0) })
    } else {
        printHuman(sorted)
    }
    exit(ExitCode.ok.rawValue)
}

// MARK: - search

func runSearch(_ args: [String]) {
    let parsed = parseArgsOrExit(args, valueFlags: ["--file"], boolFlags: ["--json"])
    guard parsed.positionals.count == 1, let query = parsed.positionals.first else {
        fail(.usage, "search requires exactly one query argument")
    }

    let path = resolveRcPath(fileFlag: parsed.values["--file"])
    let entries = loadEntriesOrExit(path: path)

    // Ranker needs usage counts to break ties the same way the app does.
    let counts = HistoryScanner.commandWordCounts(path: resolveHistoryPath())
    let ranked = entries.map { RankedEntry(entry: $0, uses: counts[$0.name] ?? 0) }
    let results = Array(Ranker.rank(ranked, query: query, scope: .everything).prefix(20))

    if parsed.flags.contains("--json") {
        printJSON(results.map { row($0.entry, uses: $0.uses) })
    } else {
        printHuman(results.map(\.entry))
    }
    exit(ExitCode.ok.rawValue)
}

// MARK: - add

func runAdd(_ args: [String]) {
    let parsed = parseArgsOrExit(args, valueFlags: ["--file", "--comment"], boolFlags: ["--force-collateral"])
    guard parsed.positionals.count == 2 else {
        fail(.usage, "add requires a name and a command")
    }
    let name = parsed.positionals[0]
    let command = parsed.positionals[1]
    let comment = parsed.values["--comment"]
    let forceCollateral = parsed.flags.contains("--force-collateral")

    let path = resolveRcPath(fileFlag: parsed.values["--file"])
    let entries = loadEntriesOrExit(path: path)

    do {
        let backup = try AliasWriter.apply(.upsert(name: name, command: command, comment: comment),
                                           path: path,
                                           allEntries: entries,
                                           confirmedCollateral: forceCollateral)
        printWriteResult(action: "Wrote", name: name, path: path, backup: backup)
        exit(ExitCode.ok.rawValue)
    } catch let error as AliasWriter.WriteError {
        fail(.writerRefusal, error.errorDescription ?? "write refused")
    } catch {
        fail(.writerRefusal, "\(error)")
    }
}

/// Shared success message for `add` and `promote`. `AliasWriter.apply` returns "" when
/// the rc file was empty (nothing existed yet to back up), which is a legitimate
/// outcome, not a missing backup — so it's only mentioned when there is one.
func printWriteResult(action: String, name: String, path: String, backup: String) {
    if backup.isEmpty {
        print("\(action) \(name) to \(path)")
    } else {
        print("\(action) \(name) to \(path) (backup: \(backup))")
    }
}

// MARK: - last

func runLast(_ args: [String]) {
    let parsed = parseArgsOrExit(args, valueFlags: [], boolFlags: [])
    guard parsed.positionals.count <= 1 else {
        fail(.usage, "last takes at most one argument")
    }
    let n = parseCount(parsed.positionals.first, default: 10)

    let mostRecentFirst = HistoryScanner.commands(path: resolveHistoryPath())
        .sorted { $0.lastSeen > $1.lastSeen }
    for command in mostRecentFirst.prefix(n) {
        print(command.text)
    }
    exit(ExitCode.ok.rawValue)
}

// MARK: - promote

func runPromote(_ args: [String]) {
    let parsed = parseArgsOrExit(args, valueFlags: ["--file", "--name"], boolFlags: ["--force-collateral"])
    guard parsed.positionals.count <= 1 else {
        fail(.usage, "promote takes at most one positional argument")
    }
    let n = parseCount(parsed.positionals.first, default: 1)

    let mostRecentFirst = HistoryScanner.commands(path: resolveHistoryPath())
        .sorted { $0.lastSeen > $1.lastSeen }
    guard n <= mostRecentFirst.count else {
        fail(.nothingToDo, "history has no command at position \(n)")
    }
    let command = mostRecentFirst[n - 1].text

    let path = resolveRcPath(fileFlag: parsed.values["--file"])
    let entries = loadEntriesOrExit(path: path)
    let takenNames = Set(entries.map(\.name))

    let name: String
    if let override = parsed.values["--name"], !override.isEmpty {
        name = override
    } else {
        let suggestion = AliasNameSuggester.suggest(for: command, takenNames: takenNames)
        guard !suggestion.isEmpty else {
            fail(.nothingToDo, "couldn't suggest a name for \"\(command)\" — pass --name")
        }
        name = suggestion
    }

    let forceCollateral = parsed.flags.contains("--force-collateral")
    do {
        let backup = try AliasWriter.apply(.upsert(name: name, command: command, comment: nil),
                                           path: path,
                                           allEntries: entries,
                                           confirmedCollateral: forceCollateral)
        printWriteResult(action: "Promoted history #\(n) to", name: name, path: path, backup: backup)
        exit(ExitCode.ok.rawValue)
    } catch let error as AliasWriter.WriteError {
        fail(.writerRefusal, error.errorDescription ?? "write refused")
    } catch {
        fail(.writerRefusal, "\(error)")
    }
}

/// Shared `[n]` parsing for `last` and `promote`: a bare positive integer, or the
/// default. Anything else is a usage error, not a silent fallback to the default.
func parseCount(_ raw: String?, default defaultValue: Int) -> Int {
    guard let raw else { return defaultValue }
    guard let n = Int(raw), n > 0 else {
        fail(.usage, "n must be a positive integer, got \"\(raw)\"")
    }
    return n
}

// MARK: - Entry point

@main
struct ABMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            FileHandle.standardError.write(Data((usageText + "\n").utf8))
            exit(ExitCode.usage.rawValue)
        }
        let rest = Array(args.dropFirst())

        switch command {
        case "list": runList(rest)
        case "search": runSearch(rest)
        case "add": runAdd(rest)
        case "last": runLast(rest)
        case "promote": runPromote(rest)
        case "help", "-h", "--help":
            print(usageText)
            exit(ExitCode.ok.rawValue)
        default:
            fail(.usage, "unknown command \"\(command)\"")
        }
    }
}
