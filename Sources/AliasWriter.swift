import Foundation

/// Writes aliases into the user's rc file.
///
/// This is the only code in AliasBar that modifies anything, and a mistake here breaks
/// someone's shell on next login. The rules it holds to:
///
/// 1. It only ever rewrites the region between its own markers. Every byte outside is
///    carried through untouched.
/// 2. Every write is atomic: a temp file in the same directory, then `rename`. The
///    original is never truncated in place, so an interrupted write cannot produce a
///    half-written `.zshrc`.
/// 3. Every write is preceded by a timestamped backup.
/// 4. If the markers are anything other than exactly one well-formed pair, it refuses
///    to write rather than guessing.
enum AliasWriter {

    // MARK: - Errors

    enum WriteError: LocalizedError {
        case unreadable(String)
        case malformedMarkers(String)
        case invalidName(String)
        case emptyCommand
        case reservedName(String)
        case definedOutsideBlock(name: String, file: String, line: Int)
        case backupFailed(String)
        case writeFailed(String)
        case modifiedElsewhere
        case renameSourceMissing(String)
        case multilineCommand
        case wouldBreakSyntax(String)
        /// The edit would remove lines beyond the definition asked for.
        ///
        /// Carries the actual lines rather than a message, because the useful response is
        /// to show them to the user and let them decide. A person reads
        /// `alias gs='git status'; echo hi` and knows in a second whether that `echo`
        /// matters; no amount of shell analysis can answer that for them.
        case collateralDamage(removing: [String], suspect: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let why):
                return "Couldn't read your shell config: \(why)"
            case .malformedMarkers(let why):
                return "AliasBar's managed block is malformed, so nothing was written: \(why)"
            case .invalidName(let name):
                return "\"\(name)\" isn't a usable alias name. Use letters, digits, and _ . : @ + - with no spaces."
            case .emptyCommand:
                return "An alias needs a command."
            case .reservedName(let name):
                return "\"\(name)\" is a zsh reserved word. Aliasing it would break your shell."
            case .definedOutsideBlock(let name, let file, let line):
                return "\"\(name)\" is already defined at \((file as NSString).lastPathComponent):\(line), outside AliasBar's managed block. AliasBar won't edit that line. Remove it by hand first, or pick another name."
            case .backupFailed(let why):
                return "Couldn't write a backup, so nothing was changed: \(why)"
            case .writeFailed(let why):
                return "Couldn't save your shell config: \(why)"
            case .modifiedElsewhere:
                return "Something else changed your shell config while AliasBar had it open, so nothing was written. Reopen and try again."
            case .renameSourceMissing(let name):
                return "\"\(name)\" is no longer in AliasBar's block, so it can't be renamed. Something else edited your shell config. Reopen and try again."
            case .multilineCommand:
                return "An alias has to be a single line. For anything multi-line, write a shell function instead."
            case .collateralDamage(_, let suspect):
                return "This would also remove `\(suspect)`, which you didn't ask to change."
            case .wouldBreakSyntax(let why):
                return "That edit would have left your shell config unable to parse, so nothing was written. Edit the line by hand instead. (zsh said: \(why))"
            }
        }
    }

    // MARK: - Validation

    /// zsh reserved words and shell control operators. Aliasing any of these ranges from
    /// confusing to catastrophic.
    private static let reserved: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until",
        "do", "done", "in", "function", "select", "time", "coproc", "repeat", "foreach",
        "end", "nocorrect", "declare", "local", "return", "alias", "unalias",
    ]

    static func validate(name: String, command: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else { throw WriteError.invalidName(name) }
        guard trimmedCommand.isEmpty == false else { throw WriteError.emptyCommand }
        // A newline would be emitted as a physically multi-line alias statement held
        // together only by its quotes. Any later edit that touched one of those lines
        // would orphan the rest, and orphaned lines in an rc file are not inert: they
        // run at shell startup. zsh aliases are one-liners; functions exist for the
        // rest.
        guard !trimmedCommand.contains("\n") else { throw WriteError.multilineCommand }
        guard reserved.contains(trimmedName) == false else {
            throw WriteError.reservedName(trimmedName)
        }
        // Anything outside this set either cannot be an alias name in zsh or would need
        // quoting that makes the rc file hard for a human to read.
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:@+-")
        guard trimmedName.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw WriteError.invalidName(trimmedName)
        }
    }

    /// Wraps a command in single quotes for zsh.
    ///
    /// Single quotes are literal in zsh with exactly one exception: they cannot contain a
    /// single quote. The standard escape is to close the quote, emit an escaped quote, and
    /// reopen: `'` becomes `'\''`.
    static func quote(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        var quoted = "'\(escaped)'"
        // A command ending in a quote leaves a redundant empty `''` on the end. Both
        // forms are correct, but zsh itself omits it and this lands in a file the user
        // reads. The mirror-image trim on the leading end is deliberately not done: it
        // would emit `alias x=\'...`, which is valid but far less obvious to anyone
        // eyeballing their own rc file.
        if quoted.hasSuffix("''"), quoted.count > 2 { quoted = String(quoted.dropLast(2)) }
        return quoted
    }

    /// The literal line this writer emits for an entry.
    static func aliasLine(name: String, command: String) -> String {
        "alias \(name)=\(quote(command))"
    }

    // MARK: - Block location

    struct BlockBounds {
        /// Index of the begin marker line, or nil when the file has no block yet.
        let begin: Int?
        /// Index of the end marker line.
        let end: Int?
        var exists: Bool { begin != nil && end != nil }
    }

    /// Finds the managed block, and refuses ambiguity. Duplicated, unbalanced, or
    /// reversed markers all raise rather than resolving to a best guess, because every
    /// guess here risks writing over a line the user wrote.
    static func locateBlock(in lines: [String]) throws -> BlockBounds {
        var begins: [Int] = []
        var ends: [Int] = []
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == ManagedBlock.begin { begins.append(i) }
            if line == ManagedBlock.end { ends.append(i) }
        }

        if begins.isEmpty && ends.isEmpty { return BlockBounds(begin: nil, end: nil) }
        if begins.count > 1 {
            throw WriteError.malformedMarkers("found \(begins.count) begin markers, expected 1")
        }
        if ends.count > 1 {
            throw WriteError.malformedMarkers("found \(ends.count) end markers, expected 1")
        }
        guard let begin = begins.first else {
            throw WriteError.malformedMarkers("found an end marker with no begin marker")
        }
        guard let end = ends.first else {
            throw WriteError.malformedMarkers("found a begin marker with no end marker")
        }
        guard end > begin else {
            throw WriteError.malformedMarkers("the end marker appears before the begin marker")
        }
        return BlockBounds(begin: begin, end: end)
    }

    // MARK: - Read

    /// The alias definitions currently inside the managed block, in file order.
    static func managedAliases(in lines: [String]) throws -> [(name: String, command: String)] {
        let bounds = try locateBlock(in: lines)
        guard let begin = bounds.begin, let end = bounds.end else { return [] }
        var result: [(String, String)] = []
        for i in (begin + 1)..<end {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("alias ") else { continue }
            let rest = String(line.dropFirst("alias ".count))
            if let (name, command) = ZshrcParser.splitAliasAssignment(rest), !name.isEmpty {
                // Undo the '\'' escaping so the value round-trips into the edit field.
                result.append((name, command.replacingOccurrences(of: "'\\''", with: "'")))
            }
        }
        return result
    }

    // MARK: - Mutations

    enum Operation {
        case upsert(name: String, command: String, comment: String?)
        case delete(name: String)
        /// Renaming is one operation, never a delete followed by an insert. Split into
        /// two commits, the second can fail on a clash, a permission change, a full
        /// disk, or a concurrent edit, and the user is left with the original already
        /// gone and an error message.
        case rename(from: String, to: String, command: String)
    }

    /// Identity of the file as it stood when it was read, used to detect anyone else
    /// writing to it before this change is committed.
    private struct FileSnapshot: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modified: timespec

        static func == (a: FileSnapshot, b: FileSnapshot) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec
                && a.modified.tv_nsec == b.modified.tv_nsec
        }

        static func of(_ path: String) -> FileSnapshot? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return FileSnapshot(device: info.st_dev, inode: info.st_ino,
                                size: info.st_size, modified: info.st_mtimespec)
        }
    }

    /// Follows a symlink chain to the file that actually holds the content.
    ///
    /// This matters more than it looks. Plenty of people symlink `~/.zshrc` into a
    /// dotfiles repo. Renaming a temp file over the *link* would replace the link with
    /// a regular file and leave the repo copy untouched, quietly detaching the user's
    /// config from version control. A content backup cannot undo that, because what was
    /// lost is the link itself.
    static func resolveTarget(_ path: String) throws -> String {
        var current = (path as NSString).expandingTildeInPath
        var hops = 0
        while true {
            var info = stat()
            guard lstat(current, &info) == 0 else { return current }
            guard (info.st_mode & S_IFMT) == S_IFLNK else { return current }

            hops += 1
            guard hops <= 16 else {
                throw WriteError.malformedMarkers("symlink chain at \(path) is too deep")
            }
            // Failing open here would be the exact disaster this function exists to
            // prevent: we know it is a link, so returning the link path means the
            // rename replaces the link itself. Refuse instead.
            guard let destination = try? FileManager.default
                .destinationOfSymbolicLink(atPath: current) else {
                throw WriteError.unreadable(
                    "\(current) is a symlink whose target could not be resolved")
            }
            current = destination.hasPrefix("/")
                ? destination
                : (current as NSString).deletingLastPathComponent + "/" + destination
            current = (current as NSString).standardizingPath
        }
    }

    /// Applies an operation to the rc file at `path`.
    ///
    /// `allEntries` is the parsed state of the file and is used only to detect a name
    /// already defined outside the managed block, which this writer deliberately will
    /// not touch.
    @discardableResult
    /// - Parameter confirmedCollateral: set only after the user has been shown the exact
    ///   lines this will remove and has said to go ahead. It skips the collateral check and
    ///   nothing else. `guardSyntax` still runs, because leaving a `.zshrc` that cannot
    ///   parse is never a thing to confirm your way into, and a backup is still written.
    static func apply(_ operation: Operation,
                      path: String,
                      allEntries: [ShellEntry],
                      confirmedCollateral: Bool = false) throws -> String {
        // Both writing operations validate identically, and both must run every check
        // before anything is committed.
        var nameToWrite: String?
        var commandToWrite: String?
        switch operation {
        case .upsert(let name, let command, _):
            nameToWrite = name
            commandToWrite = command
        case .rename(_, let to, let command):
            nameToWrite = to
            commandToWrite = command
        case .delete:
            break
        }

        if let name = nameToWrite, let command = commandToWrite {
            try validate(name: name, command: command)
            // A definition outside the block wins or loses depending on file order, and
            // either way this writer has no business rewriting a line it did not author.
            if let clash = allEntries.first(where: { $0.name == name && !$0.managed }) {
                throw WriteError.definedOutsideBlock(name: name,
                                                     file: clash.sourceFile,
                                                     line: clash.line)
            }
        }

        // Everything from here operates on the file the content actually lives in, not
        // on a symlink pointing at it.
        let target = try resolveTarget(path)

        // The snapshot has to bracket the read, not follow it. Taken only afterwards, a
        // writer that finishes replacing the file *during* our read would be captured as
        // the "original" state: the final check would pass and we would commit contents
        // we read from the previous version, silently discarding theirs.
        let snapshotBeforeRead = FileSnapshot.of(target)
        let original: String
        do {
            original = try String(contentsOfFile: target, encoding: .utf8)
        } catch {
            // An rc file that does not exist yet is a legitimate starting state.
            if FileManager.default.fileExists(atPath: target) == false {
                original = ""
            } else {
                throw WriteError.unreadable(error.localizedDescription)
            }
        }
        let snapshotAfterRead = FileSnapshot.of(target)
        guard snapshotBeforeRead == snapshotAfterRead else {
            throw WriteError.modifiedElsewhere
        }

        // `allEntries` came from the UI's last parse and can be stale by the time Save
        // is pressed. Reparse the exact contents bracketed by the snapshots above so an
        // unmanaged definition added since the editor opened cannot be shadowed by a
        // new managed definition.
        if let name = nameToWrite,
           let clash = ZshrcParser.parseText(original, sourceFile: target)
               .first(where: { $0.name == name && !$0.managed }) {
            throw WriteError.definedOutsideBlock(name: name,
                                                 file: clash.sourceFile,
                                                 line: clash.line)
        }

        // Re-checked immediately before the replacement. Atomic rename prevents a
        // half-written file; it does nothing about a lost update.
        let snapshotAtRead = snapshotAfterRead

        // Whether the file ends in a newline is a property worth preserving exactly.
        let endedWithNewline = original.hasSuffix("\n") || original.isEmpty
        var lines = original.components(separatedBy: "\n")
        if endedWithNewline && lines.last == "" { lines.removeLast() }

        let (output, removedSpans) = try rewrite(lines: lines, applying: operation)

        var text = output.joined(separator: "\n")
        if endedWithNewline || !text.isEmpty { text += "\n" }

        let destructive: Bool
        switch operation {
        case .upsert: destructive = false
        case .delete, .rename: destructive = true
        }
        try guardSyntax(original: original, rewritten: text, destructive: destructive, removed: removedSpans)
        if !confirmedCollateral { try guardCollateral(removed: removedSpans) }

        let backup = try writeBackup(of: original, for: target)
        try atomicWrite(text, to: target, expecting: snapshotAtRead, matching: original)
        return backup
    }

    // MARK: - Collateral guard

    /// Refuses any edit that removed an alias it was not asked to remove.
    ///
    /// A mis-computed span fails in two directions, and the two need different guards.
    /// Truncation leaves a statement unterminated, which `guardSyntax` catches because the
    /// file stops parsing. **Over-deletion does not**: swallowing the next alias along
    /// with the target produces a file that parses perfectly and is simply missing a line
    /// the user never asked to lose. `zsh -n` is blind to it by construction.
    ///
    /// That is Codex round 9's route 7. `alias doomed=x;# comment \` followed by
    /// `alias victim='2'` deletes both, because zsh ends the statement at the `;` while
    /// the lexer reads the backslash as a continuation.
    ///
    /// Each span reported by `rewrite` is one definition it meant to remove or replace.
    /// The first line of a span is that definition; every line after it is legitimate only
    /// if it was a *continuation* of the same statement. Like the syntax guard, this does
    /// not need the lexer to be correct. It only needs to notice when the lexer was wrong.
    private static func guardCollateral(removed: [[String]]) throws {
        // The test is deliberately not "does this line stand alone". Inside a legacy
        // multiline alias, `echo two` stands alone perfectly well and is still a
        // continuation. The test is whether the statement was **already complete before
        // this line**: if zsh can parse everything above it as a finished statement, then
        // this line starts a new one and the edit was about to take it out too.
        //
        // Because the spans come from the rewrite itself rather than from a diff of the
        // block, no name exemption is needed. An earlier version reconstructed the removed
        // lines by diffing and therefore had to permit the operation's own names, which
        // meant that with two definitions sharing a name a wrong span could swallow the
        // second one and be waved through. Codex round 12 found that, and found that the
        // same diff mangled a rename onto an existing name, which performs two *disjoint*
        // edits and so reported everything between them as collateral. Knowing the exact
        // ranges removes both problems rather than patching them.
        // Completeness is tested BEFORE looking at what the line contains. An earlier
        // version skipped blank and comment lines first, which Codex round 13 caught: when
        // the span wrongly runs past `alias doomed=x;# comment \`, a following line like
        // `# how to recover this machine` was dropped without a word, and since comments
        // do not affect parsing, guardSyntax saw nothing wrong either. A comment the user
        // wrote is user content. If the statement was already finished above this line,
        // the line is not part of it, whatever it happens to say.
        // The FIRST line of every span, checked before anything else.
        //
        // Codex round 16: the checks below only ever looked at lines *after* the first, and
        // `guardSyntax` returns as soon as the rewritten file parses. So a definition that
        // carries a second statement on the same line went straight through on an ordinary,
        // perfectly valid `.zshrc`. `alias doomed='x'; print -r -- keep` is read as the
        // alias `doomed`, and deleting it takes the user's `print` with it while leaving a
        // file that still parses. Result syntax cannot prove that only the requested
        // statement was removed; that has to be established about the span itself.
        for span in removed where !span.isEmpty {
            guard removalIsProvablyOneAlias(span.joined(separator: "\n")) else {
                throw WriteError.collateralDamage(
                    removing: removed.flatMap { $0 },
                    suspect: span[0].trimmingCharacters(in: .whitespaces))
            }
        }

        for span in removed where span.count > 1 {
            for index in 1..<span.count {
                let above = span[0..<index].joined(separator: "\n") + "\n"
                guard isCompleteStatement(above) else { continue }
                let bare = span[index].trimmingCharacters(in: .whitespaces)
                throw WriteError.collateralDamage(
                    removing: removed.flatMap { $0 },
                    suspect: bare.isEmpty ? "(a blank line)" : bare)
            }
        }
    }

    /// Whether the opening line of a removal is provably a single alias definition and
    /// nothing else.
    ///
    /// Canonical lines are settled by `isCanonicalAliasLine`. The rest of the work is for
    /// definitions AliasBar did not write, which still have to stay editable: a hand-typed
    /// `alias ll=ls -la`, or the first line of a legacy multi-line alias. So the rule is
    /// conservative rather than clever.
    ///
    /// The value is safe if it is wholly enclosed in quotes, since then it is one word. If
    /// it is not quoted, it is safe only when it contains nothing that could start a second
    /// statement or a substitution. Note that a bare `|` or `;` in an unquoted value is not
    /// a false alarm: `alias x=a|b` really is an alias definition piped into `b`, and
    /// removing that line removes both halves.
    static func removalIsProvablyOneAlias(_ line: String) -> Bool {
        // Canonical form only. Nothing else is accepted, and the reasoning is worth keeping
        // because four rounds were spent learning it.
        //
        // Rounds 16 through 19 each found a new way for one apparent `alias` statement to
        // define two, and each fix was a tighter analysis of arbitrary zsh: a character
        // blacklist (beaten by `alias a=x b=y`), zsh's own tokenizer (beaten by
        // `alias a=x $extra`), then an operand allowlist that still trusted quoting
        // (beaten by `alias a="${arr[@]}"` with `arr=(one victim=y)`, which defines two
        // aliases from one double-quoted word).
        //
        // The pattern is the point. How many aliases a line defines is decided at
        // expansion time, so no static analysis of a hand-written line can settle it. Each
        // round bought a smaller bypass at the cost of more shell grammar embedded here.
        //
        // So the boundary moved instead. **AliasBar's managed block is written by
        // AliasBar**, and a non-canonical line is there only because someone hand-edited
        // it in. Refusing to touch those costs a little and removes the entire class:
        // there is nothing left to analyse, because the only lines this will remove are
        // ones it emitted itself and can reproduce byte for byte. The user gets an
        // actionable message naming the line rather than a silent surprise.
        //
        // Canonical-only was tried first and refused too much to be worth it: hand-written
        // aliases are most of what this app exists to manage, and a user cannot edit or
        // delete any of them if the rule is "AliasBar must have written it."
        //
        // So non-canonical lines are still accepted, but only on two guarantees zsh
        // actually makes, rather than on an enumeration of dangerous syntax:
        //
        // 1. **A single-quoted value cannot expand.** Nothing inside `'...'` is special in
        //    zsh, so it is exactly one word, always.
        // 2. **A double-quoted value cannot word-split without a `$` or a backtick.** All
        //    the splitting routes, `${arr[@]}`, `$arr`, `${(s.,.)x}` and command
        //    substitution, need one of those two characters.
        //
        // An unquoted value has too many routes (brace expansion `x={a,b}` alone yields two
        // definitions with no `$` in sight), so it must be plain literal text.
        if isCanonicalAliasLine(line) { return true }
        guard let operands = aliasOperands(in: line) else { return false }

        var assignments = 0
        for operand in operands {
            guard let eq = operand.firstIndex(of: "=") else {
                // No `=`, so this is an alias LOOKUP rather than a definition, but only if
                // it is literally a name. `$extra` looks like a lookup and expands into a
                // definition, which is how round 18 got through.
                guard isLiteralAliasName(operand) else { return false }
                continue
            }
            assignments += 1
            guard assignments == 1 else { return false }
            guard isLiteralAliasName(String(operand[..<eq])) else { return false }

            let value = String(operand[operand.index(after: eq)...])
            guard valueIsOneWord(value) else { return false }
        }
        return assignments == 1
    }

    /// Whether an alias value provably expands to exactly one word. See the guarantees
    /// listed in `removalIsProvablyOneAlias`.
    private static func valueIsOneWord(_ value: String) -> Bool {
        // The quote must run uninterrupted from end to end, which is not the same as the
        // value starting and ending with one. Codex round 20: `''${arr[@]}''` begins and
        // ends with a single quote while its middle is wide open, so with
        // `arr=(one victim=y)` it expands to two definitions. An interior delimiter means
        // the quoted run closed and reopened, so anything between was unquoted.
        if value.count >= 2, value.first == "'", value.last == "'" {
            return !value.dropFirst().dropLast().contains("'")
        }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            let inner = value.dropFirst().dropLast()
            return !inner.contains("\"") && !inner.contains("$") && !inner.contains("`")
        }
        // Unquoted. Anything beyond plain text can expand, split, or glob.
        let literal = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:@+-/#,%")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { literal.contains($0) }
    }

    /// The operands after `alias`, split by zsh itself, or nil if the span is not a lone
    /// `alias` command.
    ///
    /// `${(z)}` performs the shell's word splitting **without expanding or executing**
    /// anything, so it is safe to run over a line nobody has vetted. Command substitutions
    /// come back as literal text.
    private static func aliasOperands(in text: String) -> [String]? {
        let script = """
        line=$1
        words=(${(z)line})
        [[ ${words[1]} == alias ]] || exit 1
        shift words
        operands=()
        for w in $words; do
          # A `#` opening a word starts a comment: the statement ends here, harmlessly.
          [[ $w == '#'* ]] && break
          # A separator token means a second statement shares this line. zsh decided these
          # are tokens rather than text, which is the part that cannot be done by looking
          # at characters.
          case $w in
            ';'|'|'|'||'|'&'|'&&'|'('|')'|'{'|'}'|'&|'|';;'|'|&') exit 1 ;;
          esac
          operands+=($w)
        done
        print -rN -- $operands
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-f", "-c", script, "aliasbar", text]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let joined = String(data: data, encoding: .utf8) else { return nil }
        return joined.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    static func isCanonicalAliasLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("alias ") else { return false }
        let rest = String(trimmed.dropFirst("alias ".count))
        guard let eq = rest.firstIndex(of: "=") else { return false }

        let name = String(rest[..<eq])
        let value = String(rest[rest.index(after: eq)...])
        guard let command = unquoteCanonical(value) else { return false }
        // The name goes through the same validation a write does. The command deliberately
        // does not: `validate` rejects newlines, because new multi-line aliases are no
        // longer written, but earlier builds did write them and those still have to be
        // removable. They are canonical too, just with newlines inside the quotes.
        guard isLiteralAliasName(name), !reserved.contains(name) else { return false }
        return trimmed == aliasLine(name: name, command: command)
    }

    /// Whether `word` is a bare alias name, by the same allowlist a write validates against.
    private static func isLiteralAliasName(_ word: String) -> Bool {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:@+-")
        return !word.isEmpty && word.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The inverse of `quote(_:)` for canonically quoted values, or nil for anything else.
    ///
    /// Only has to be correct on values `quote(_:)` produced; the caller re-emits and
    /// compares, so a wrong decode fails the equality check and the edit is refused.
    private static func unquoteCanonical(_ value: String) -> String? {
        guard value.hasPrefix("'") else { return nil }
        var out = ""
        var i = value.index(after: value.startIndex)
        var closed = false

        while i < value.endIndex {
            guard value[i] == "'" else {
                out.append(value[i])
                i = value.index(after: i)
                continue
            }
            // A quote is only legal as the closing delimiter or as part of the `'\''`
            // splice that `quote(_:)` uses to embed a literal apostrophe.
            let after = value.index(after: i)
            if after == value.endIndex { closed = true; i = after; continue }
            guard value[after] == "\\" else { return nil }
            let backslashed = value.index(after: after)
            guard backslashed < value.endIndex, value[backslashed] == "'" else { return nil }
            out.append("'")
            let reopen = value.index(after: backslashed)
            if reopen == value.endIndex {
                // `quote(_:)` trims the redundant trailing `''` when a command ends in an
                // apostrophe, leaving the value ending at `'\'`.
                closed = true
                i = reopen
                continue
            }
            guard value[reopen] == "'" else { return nil }
            i = value.index(after: reopen)
        }
        return closed ? out : nil
    }

    /// Whether `text` is a finished statement, as opposed to one that continues onto the
    /// line after it.
    ///
    /// Parsing alone cannot answer this. `zsh -n` tolerates a trailing backslash at end of
    /// file, so `alias doomed=1 \` parses happily even though in a real file that backslash
    /// consumes the newline and the statement runs on. That tolerance is what made an
    /// earlier version refuse a perfectly valid delete of a legacy alias written across two
    /// lines (Codex round 14), and it is why probing for a minimal complete prefix does not
    /// work as a way to compute spans either.
    ///
    /// A sentinel settles it. `fi` is a syntax error standing on its own line, but an
    /// ordinary word when spliced onto the end of a previous line. So if appending it makes
    /// the text parse, it was absorbed, which means the text was still open:
    ///
    ///     alias doomed=1 \        + fi  ->  `alias doomed=1 fi`   parses    -> continues
    ///     alias doomed=x;# c \    + fi  ->  `fi` on its own line  no parse  -> complete
    ///
    /// The second case is right because the backslash sits inside a comment, where it is
    /// inert. That distinction is invisible to a plain parse and is exactly the one the
    /// hand-written lexer kept getting wrong.
    private static func isCompleteStatement(_ text: String) -> Bool {
        guard let (ok, _) = parses(text), ok else { return false }
        guard let (absorbed, _) = parses(text + "fi\n") else { return true }
        return !absorbed
    }

    /// The lines inside the managed block, verbatim.
    private static func blockBody(of lines: [String]) throws -> [String] {
        let bounds = try locateBlock(in: lines)
        guard let begin = bounds.begin, let end = bounds.end, end > begin + 1 else { return [] }
        return Array(lines[(begin + 1)..<end])
    }

    // MARK: - Syntax guard

    /// Refuses any edit that would leave the file unable to parse.
    ///
    /// **Why this exists.** Deciding which lines a shell statement occupies means knowing
    /// where that statement ends, and `scan(_:from:)` answers that with a hand-written
    /// lexer. Nine adversarial review rounds found eight distinct inputs where it was
    /// wrong, each one looking correct when it was written: a newline in a value, a
    /// trailing backslash, an embedded `#`, word-boundary state carried across a
    /// continuation, `}` inside `${...}`, `)` inside `$((...))`, a `;` before a comment,
    /// and nesting constructs that continue across lines with neither an open quote nor a
    /// backslash. When a span is computed wrong, the edit truncates or overruns a
    /// statement, and the remainder does not sit inertly in the file. It runs at shell
    /// startup.
    ///
    /// The lesson from eight routes is not that the next patch will be the correct one.
    /// It is that zsh's grammar is too large to re-implement by hand with confidence. So
    /// the authority on whether the result parses is **zsh itself**, via `zsh -n`, which
    /// parses without executing anything.
    ///
    /// This does not make the lexer correct. It makes every remaining lexer bug fail
    /// loudly and harmlessly instead of silently corrupting a shell.
    ///
    /// The comparison is deliberately relative: an rc file that already fails `zsh -n`
    /// before the edit stays editable, because refusing there would lock the user out of
    /// the app over a pre-existing problem AliasBar did not cause and cannot fix.
    private static func guardSyntax(original: String,
                                    rewritten: String,
                                    destructive: Bool,
                                    removed: [[String]]) throws {
        // Nothing to compare against if zsh is not where it should be. Not a reason to
        // block an edit; the rest of the writer's guards still apply.
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }

        // The managed block is AliasBar's own territory, and it is checked separately from
        // the file around it. Codex round 11: skipping the whole check whenever the file
        // was already broken left the truncation direction unguarded on exactly the path
        // this method claims to support. A file with an unrelated syntax error elsewhere
        // plus `alias doomed=$(print one` / `touch /tmp/side-effect` / `)` would truncate
        // to one line, orphan the `touch` as a standalone command, and commit, because
        // both before and after already failed at file level. Checking the block in
        // isolation catches that: the leftover `)` does not parse.
        let beforeBody = (try? blockBody(of: original.components(separatedBy: "\n"))) ?? []
        let afterBody = (try? blockBody(of: rewritten.components(separatedBy: "\n"))) ?? []
        let bodyWasOK = parses(beforeBody.joined(separator: "\n") + "\n")?.0 ?? false

        if bodyWasOK,
           let (bodyNowOK, bodyWhy) = parses(afterBody.joined(separator: "\n") + "\n"),
           !bodyNowOK {
            throw WriteError.wouldBreakSyntax(bodyWhy)
        }

        guard let (newOK, complaint) = parses(rewritten) else { return }
        if newOK { return }

        // The result does not parse, and the file did not parse before either. If the block
        // cannot be validated on its own, neither baseline can vouch for a destructive
        // edit, so the edit has to vouch for itself.
        //
        // Codex round 12: a managed block can sit inside a compound construct (an `if true`
        // above the begin marker, `fi` below the end marker), which makes its body
        // context-dependent and unparseable in isolation through no fault of the user.
        // Combined with an unrelated syntax error elsewhere in the file, both checks used
        // to opt out and a truncating edit committed.
        //
        // Round 13 then caught the overcorrection: refusing outright locked out edits that
        // are demonstrably safe, such as deleting a one-line `alias doomed='1'`, which
        // cannot orphan anything and leaves the pre-existing error exactly as it was.
        //
        // Round 14 then caught the first attempt at that relaxation. Accepting any span
        // that *parses* is not enough, because a script can hold more than one statement:
        // `alias doomed=1; print -r -- keep-this` is one line, parses fine, and is read as
        // defining `doomed`, so deleting it would take the user's `print` with it in
        // silence. Parseability proves the span is well formed, not that it is only the
        // alias.
        //
        // The test that does hold is whether the span is a line AliasBar itself wrote.
        // Round-tripping through `aliasLine` proves it is exactly one alias definition by
        // construction, with no room for a second statement. Anything hand-edited in a
        // block that cannot be validated is left alone, which is the right answer for a
        // situation where nothing else can vouch for the edit.
        if destructive, !bodyWasOK,
           !removed.allSatisfy({ $0.count == 1 && isCanonicalAliasLine($0[0]) }) {
            throw WriteError.wouldBreakSyntax(complaint)
        }

        // At file level, only refuse if the input parsed, so that a file which was already
        // broken by something AliasBar did not cause does not become permanently
        // uneditable. The block-level check above is what keeps that path honest.
        guard let (oldOK, _) = parses(original), oldOK else { return }

        throw WriteError.wouldBreakSyntax(complaint)
    }

    /// Runs `zsh -n` over `text`. Returns nil if the check could not be run at all, in
    /// which case the caller treats the result as unknown rather than as a failure.
    private static func parses(_ text: String) -> (Bool, String)? {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aliasbar-syntax-\(UUID().uuidString).zsh")
        guard (try? text.write(to: scratch, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `-n` parses without executing. `-f` skips startup files, so the check measures
        // this file alone and cannot be influenced by the user's own configuration.
        task.arguments = ["-f", "-n", scratch.path]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()

        guard (try? task.run()) != nil else { return nil }

        // `-n` never executes, so it terminates on its own. The read has to happen before
        // the wait or a complaint larger than the pipe buffer would deadlock.
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let complaint = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (task.terminationStatus == 0, complaint.isEmpty ? "syntax error" : complaint)
    }

    /// Produces the new file contents.
    ///
    /// Edits happen line by line inside the block rather than by regenerating it from a
    /// parsed alias list. Regenerating is tidier but destructive: anything inside the
    /// markers that is not a plain `alias` line, including comments the user added, a
    /// function, or a hand-repair after a bad merge, would vanish on the next save with
    /// no warning. Only the specific line being changed is touched.
    /// Returns the new contents, plus the verbatim lines of each span it removed.
    ///
    /// The removed spans are reported rather than reconstructed. An earlier version had
    /// `guardCollateral` recover them by diffing the block for a common prefix and suffix,
    /// and Codex round 12 found two separate bugs that were both really one bug: the diff
    /// assumed a single contiguous removal. A rename onto an existing name performs two
    /// *disjoint* edits, so the diff swallowed everything between them and reported
    /// untouched content as collateral damage. And with two definitions sharing a name,
    /// the diff could not tell which occurrence was the intended one. Reporting the exact
    /// ranges makes both questions unnecessary.
    private static func rewrite(lines: [String],
                                applying operation: Operation) throws -> (lines: [String], removed: [[String]]) {
        let bounds = try locateBlock(in: lines)

        /// The full line range a definition occupies, which is not always one line.
        ///
        /// A command containing a newline is emitted as a physically multi-line `alias`
        /// statement held together by the quotes around it. Editing only the first line
        /// would leave the remaining lines orphaned in the file, where they are no
        /// longer part of any assignment and simply *run* the next time the shell
        /// starts. New multi-line commands are now rejected outright, but blocks written
        /// by earlier builds can still contain them, so removal has to span the whole
        /// statement.
        func rangeOfAlias(named name: String, begin: Int, end: Int) throws -> ClosedRange<Int>? {
            guard end > begin + 1 else { return nil }
            for i in (begin + 1)..<end {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("alias ") else { continue }
                let rest = String(line.dropFirst("alias ".count))
                guard let (existing, _) = ZshrcParser.splitAliasAssignment(rest),
                      existing == name else { continue }

                // Walk forward until the statement is lexically complete.
                var last = i
                var state = scan(lines[i], from: LexState())
                while state.continues && last + 1 < end {
                    last += 1
                    state = scan(lines[last], from: state)
                }
                // A delimiter outside the recognized set means the scanner cannot know
                // where the heredoc body ends, so the span's extent is untrustworthy in
                // both directions. Refuse with the honest reason.
                if state.unsupportedHeredocDelimiter {
                    throw WriteError.wouldBreakSyntax(
                        "the definition of \"\(name)\" uses a heredoc delimiter this app cannot parse the way zsh does")
                }
                // This guard is intentionally independent of `continues`. If a future
                // scanner change drops a frame or forgets to propagate continuation,
                // unresolved heredoc input must turn into a refused edit, never a
                // successful under-span that exposes the payload as shell commands.
                if state.hasUnconsumedHeredoc {
                    throw WriteError.wouldBreakSyntax(
                        "the definition of \"\(name)\" has unconsumed heredoc input")
                }
                // Still incomplete at the end marker means the block is already
                // malformed. Consuming to the end would delete everything after it, so
                // refuse and let the user look at their own file.
                if state.continues {
                    throw WriteError.malformedMarkers(
                        "the definition of \"\(name)\" is never terminated")
                }
                return i...last
            }
            return nil
        }

        /// Where the lexer is when a line ends. Every nested shell construct owns its
        /// quote and word-boundary state: quotes inside `$(...)` do not close quotes in
        /// the surrounding value, and comments inside a substitution end at its newline
        /// without ending the substitution itself.
        enum QuoteState { case unquoted, single, double }

        enum NestingKind {
            case root
            case command
            case arithmetic
            case parameter
            case process
            case backtick

            /// `#` is shell-comment syntax in command contexts. In arithmetic it is the
            /// radix operator (`16#ff`), and in parameter expansion it is an operator.
            var allowsComments: Bool {
                switch self {
                case .root, .command, .process, .backtick: return true
                case .arithmetic, .parameter: return false
                }
            }
        }

        enum CasePhase {
            case awaitingIn
            case pattern
            case body
        }

        struct Heredoc {
            var delimiter: String
            var stripsTabs: Bool
        }

        struct LexFrame {
            var kind: NestingKind
            var quote: QuoteState = .unquoted
            var atWordStart = true
            var atCommandStart = true
            var token = ""
            var tokenStartedCommand = false
            var cases: [CasePhase] = []
            var pendingHeredocs: [Heredoc] = []
            var activeHeredoc: Heredoc?
            /// Number of unmatched delimiters belonging to this frame. Arithmetic
            /// starts at two for `$((`, while every other nested construct starts at
            /// one. Ordinary parentheses/braces inside the construct adjust the same
            /// count, so an inner `)` or `}` cannot close the outer construct early.
            var delimiterDepth: Int
        }

        /// Everything the lexer needs to carry from one line to the next.
        struct LexState {
            var frames = [LexFrame(kind: .root, delimiterDepth: 0)]
            /// Independent accounting for every heredoc delimiter the scanner has
            /// recognized but not yet consumed. Frames own the parsing details, while
            /// this count is the fail-safe invariant: resetting or popping a frame can
            /// never make an unresolved heredoc disappear from span completion.
            var unresolvedHeredocs = 0
            var heredocStateInvalid = false
            /// A heredoc operator was seen whose delimiter word falls outside the
            /// recognized set (line continuation, `$'…'` quoting, an unterminated
            /// quote, a backtick). Its terminator cannot be located the way zsh
            /// would, so no span containing it may complete. Never cleared.
            var unsupportedHeredocDelimiter = false
            /// Whether the statement continues onto the following line.
            var continues = false

            var hasUnconsumedHeredoc: Bool {
                heredocStateInvalid || unsupportedHeredocDelimiter
                    || unresolvedHeredocs > 0 || frames.contains {
                    $0.activeHeredoc != nil || !$0.pendingHeredocs.isEmpty
                }
            }
        }

        /// Advances the lexer across one line.
        func scan(_ line: String, from entering: LexState) -> LexState {
            var state = entering
            if state.frames.isEmpty {
                state.frames = [LexFrame(kind: .root, delimiterDepth: 0)]
            }
            var index = line.startIndex
            var trailingEscape = false
            var endedInComment = false
            var crossedRootSeparator = false

            func character(after position: String.Index) -> Character? {
                let next = line.index(after: position)
                return next < line.endIndex ? line[next] : nil
            }

            func character(twoAfter position: String.Index) -> Character? {
                let first = line.index(after: position)
                guard first < line.endIndex else { return nil }
                let second = line.index(after: first)
                return second < line.endIndex ? line[second] : nil
            }

            func advance(_ position: String.Index, by count: Int) -> String.Index {
                line.index(position, offsetBy: count, limitedBy: line.endIndex) ?? line.endIndex
            }

            func push(_ kind: NestingKind, delimiterDepth: Int, tokenLength: Int) {
                state.frames[state.frames.count - 1].atWordStart = false
                state.frames[state.frames.count - 1].atCommandStart = false
                state.frames.append(LexFrame(kind: kind, delimiterDepth: delimiterDepth))
                index = advance(index, by: tokenLength)
            }

            func finishToken(in frameIndex: Int) {
                let token = state.frames[frameIndex].token
                guard !token.isEmpty else { return }
                let beganCommand = state.frames[frameIndex].tokenStartedCommand
                state.frames[frameIndex].token = ""
                state.frames[frameIndex].tokenStartedCommand = false

                if beganCommand, token == "case" {
                    state.frames[frameIndex].cases.append(.awaitingIn)
                } else if state.frames[frameIndex].cases.last == .awaitingIn, token == "in" {
                    state.frames[frameIndex].cases[state.frames[frameIndex].cases.count - 1] = .pattern
                } else if beganCommand, token == "esac",
                          !state.frames[frameIndex].cases.isEmpty {
                    state.frames[frameIndex].cases.removeLast()
                }
                state.frames[frameIndex].atCommandStart = false
            }

            func appendToToken(_ ch: Character, in frameIndex: Int) {
                if state.frames[frameIndex].token.isEmpty {
                    state.frames[frameIndex].tokenStartedCommand =
                        state.frames[frameIndex].atCommandStart
                }
                state.frames[frameIndex].token.append(ch)
            }

            /// Reads the delimiter word after `<<` without treating its quotes as shell
            /// state. Heredoc delimiter quotes are removed by the shell, and the body is
            /// lexically opaque until that exact word appears on a line by itself.
            ///
            /// Only delimiter words whose quote removal resolves entirely on this
            /// physical line are recognized. Everything else — a trailing backslash
            /// that continues the word across the newline, `$'…'`/`$"…"` quoting, a
            /// quote still open at the newline, a backtick — is reported as
            /// `.unsupported` rather than guessed at. Round 4 proved the cost of
            /// guessing: a delimiter identity that diverges from zsh lets the
            /// unresolved-heredoc counter balance to zero against a false terminator,
            /// and the deletion orphans live heredoc payload as executable input.
            /// An unsupported delimiter must poison the whole span so the edit is
            /// refused, never quietly dropped or approximated.
            enum HeredocWord {
                case heredoc(Heredoc, String.Index)
                case hereString(String.Index)
                case unsupported(String.Index)
            }

            func heredoc(after operatorEnd: String.Index) -> HeredocWord {
                var cursor = operatorEnd
                var stripsTabs = false
                if cursor < line.endIndex, line[cursor] == "-" {
                    stripsTabs = true
                    cursor = line.index(after: cursor)
                } else if cursor < line.endIndex, line[cursor] == "<" {
                    // `<<<` is a here-string: its word is an ordinary argument, not
                    // deferred input. Hand back the position past the operator so the
                    // ordinary lexer reads the word and the loop cannot rediscover the
                    // trailing `<<` as a phantom heredoc.
                    return .hereString(line.index(after: cursor))
                }
                while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
                    cursor = line.index(after: cursor)
                }
                // `<<` with no delimiter word on this line is not valid zsh; whatever
                // the file means by it, this span's extent cannot be trusted.
                guard cursor < line.endIndex else { return .unsupported(cursor) }

                var delimiter = ""
                var quote: Character?
                var sawDelimiterWord = false
                while cursor < line.endIndex {
                    let ch = line[cursor]
                    if let activeQuote = quote {
                        if ch == activeQuote {
                            sawDelimiterWord = true
                            quote = nil
                            cursor = line.index(after: cursor)
                            continue
                        } else if activeQuote == "\"", ch == "\\" {
                            let next = line.index(after: cursor)
                            // A backslash against the newline continues the word onto
                            // the next physical line, outside the recognized set.
                            guard next < line.endIndex else { return .unsupported(cursor) }
                            if line[next] == "$" || line[next] == "`" || line[next] == "\""
                                || line[next] == "\\" {
                                delimiter.append(line[next])
                            } else {
                                delimiter.append(ch)
                                delimiter.append(line[next])
                            }
                            sawDelimiterWord = true
                            cursor = line.index(after: next)
                            continue
                        } else {
                            delimiter.append(ch)
                            sawDelimiterWord = true
                            cursor = line.index(after: cursor)
                            continue
                        }
                    } else if ch == "(" || ch == ")" {
                        // Parentheses are not a safe word boundary here: zsh accepts
                        // forms such as `foo(bar)` literally as the delimiter. In other
                        // contexts a parenthesis can be shell grammar instead. Refuse
                        // both rather than choosing an extent that can orphan payload.
                        return .unsupported(cursor)
                    } else if ch == " " || ch == "\t" || ch == ";" || ch == "|" || ch == "&"
                                || ch == "<" || ch == ">" {
                        break
                    } else if ch == "$",
                              let next = character(after: cursor),
                              next == "'" || next == "\"" || next == "("
                                  || next == "{" || next == "[" {
                        // `$'…'` and `$"…"` are quote-removal syntax whose result this
                        // scanner does not model. zsh accepts `$(…)` and `${…}` as
                        // delimiter syntax that can contain whitespace, while legacy
                        // `$[…]` arithmetic syntax computes a different delimiter. The
                        // ordinary token boundaries below cannot recover any of them.
                        return .unsupported(cursor)
                    } else if ch == "`" {
                        return .unsupported(cursor)
                    } else if ch == "'" || ch == "\"" {
                        quote = ch
                        sawDelimiterWord = true
                        cursor = line.index(after: cursor)
                        continue
                    } else if ch == "\\" {
                        let next = line.index(after: cursor)
                        // Line continuation: the delimiter word carries onto the next
                        // physical line, so its identity is not resolvable here.
                        guard next < line.endIndex else { return .unsupported(cursor) }
                        cursor = next
                    }
                    delimiter.append(line[cursor])
                    sawDelimiterWord = true
                    cursor = line.index(after: cursor)
                }
                // A quote still open at the newline continues the word across it, and a
                // quoted-empty word (`<<''`) has no line a terminator scan could match
                // the way zsh would.
                guard quote == nil, sawDelimiterWord, !delimiter.isEmpty else {
                    return .unsupported(cursor)
                }
                return .heredoc(Heredoc(delimiter: delimiter, stripsTabs: stripsTabs), cursor)
            }

            /// Expansions are active in unquoted and double-quoted text, but process
            /// substitution is syntax only in an unquoted command context.
            func openExpansion(allowProcess: Bool) -> Bool {
                let next = character(after: index)
                let afterNext = character(twoAfter: index)
                if line[index] == "$", next == "(", afterNext == "(" {
                    push(.arithmetic, delimiterDepth: 2, tokenLength: 3)
                    return true
                }
                if line[index] == "$", next == "(" {
                    push(.command, delimiterDepth: 1, tokenLength: 2)
                    return true
                }
                if line[index] == "$", next == "{" {
                    push(.parameter, delimiterDepth: 1, tokenLength: 2)
                    return true
                }
                if allowProcess, (line[index] == "<" || line[index] == ">"), next == "(" {
                    push(.process, delimiterDepth: 1, tokenLength: 2)
                    return true
                }
                if line[index] == "`" {
                    push(.backtick, delimiterDepth: 1, tokenLength: 1)
                    return true
                }
                return false
            }

            if let frameIndex = state.frames.indices.last,
               let active = state.frames[frameIndex].activeHeredoc {
                let candidate = active.stripsTabs
                    ? String(line.drop(while: { $0 == "\t" }))
                    : line
                if candidate == active.delimiter {
                    state.frames[frameIndex].activeHeredoc = nil
                    if state.unresolvedHeredocs > 0 {
                        state.unresolvedHeredocs -= 1
                    } else {
                        state.heredocStateInvalid = true
                    }
                    if !state.frames[frameIndex].pendingHeredocs.isEmpty {
                        state.frames[frameIndex].activeHeredoc =
                            state.frames[frameIndex].pendingHeredocs.removeFirst()
                    }
                    state.frames[frameIndex].atWordStart = true
                    state.frames[frameIndex].atCommandStart = true
                }
                state.continues =
                    state.frames.count > 1 || state.hasUnconsumedHeredoc
                return state
            }

            while index < line.endIndex {
                let ch = line[index]
                trailingEscape = false
                let frameIndex = state.frames.count - 1

                switch state.frames[frameIndex].quote {
                case .single:
                    // Wholly literal. A backslash here is just a backslash, so the very
                    // next apostrophe closes the string.
                    if ch == "'" { state.frames[frameIndex].quote = .unquoted }
                    state.frames[frameIndex].atWordStart = false

                case .double:
                    if ch == "\\" {
                        let next = line.index(after: index)
                        if next == line.endIndex { trailingEscape = true; index = next; continue }
                        index = next
                    } else if ch == "\"" {
                        state.frames[frameIndex].quote = .unquoted
                    } else if openExpansion(allowProcess: false) {
                        continue
                    }
                    state.frames[frameIndex].atWordStart = false

                case .unquoted:
                    if state.frames[frameIndex].kind == .backtick, ch == "`" {
                        finishToken(in: frameIndex)
                        state.frames.removeLast()
                    } else if ch == "\\" {
                        let next = line.index(after: index)
                        if next == line.endIndex { trailingEscape = true; index = next; continue }
                        index = next
                        state.frames[frameIndex].atWordStart = false
                    } else if ch == "'" {
                        state.frames[frameIndex].quote = .single
                        state.frames[frameIndex].atWordStart = false
                    } else if ch == "\"" {
                        state.frames[frameIndex].quote = .double
                        state.frames[frameIndex].atWordStart = false
                    } else if openExpansion(allowProcess: true) {
                        continue
                    } else if ch == "#",
                              state.frames[frameIndex].kind.allowsComments,
                              state.frames[frameIndex].atWordStart {
                        // A comment cannot carry an escape across its newline. A root
                        // comment ends the statement; a nested comment only ends this
                        // physical line, and its substitution remains open.
                        endedInComment = true
                        break
                    } else if state.frames[frameIndex].kind.allowsComments,
                              ch == "<", character(after: index) == "<" {
                        switch heredoc(after: advance(index, by: 2)) {
                        case .heredoc(let parsed, let end):
                            finishToken(in: frameIndex)
                            state.frames[frameIndex].pendingHeredocs.append(parsed)
                            state.unresolvedHeredocs += 1
                            index = end
                        case .hereString(let end):
                            finishToken(in: frameIndex)
                            state.frames[frameIndex].atWordStart = true
                            index = end
                        case .unsupported(let end):
                            // The operator is real but its delimiter is outside the
                            // recognized set, so the end of this heredoc cannot be
                            // located. Count it as forever-unresolved and mark the
                            // state: every span containing it must refuse the edit.
                            finishToken(in: frameIndex)
                            state.unresolvedHeredocs += 1
                            state.unsupportedHeredocDelimiter = true
                            index = end
                        }
                        continue
                    } else if ch == " " || ch == "\t" {
                        finishToken(in: frameIndex)
                        state.frames[frameIndex].atWordStart = true
                    } else if state.frames[frameIndex].kind == .root,
                              ch == ";" || ch == "|" || ch == "&" {
                        // A root separator ends the alias command, but heredocs anywhere
                        // on this physical shell list are read only after its newline.
                        // Keep scanning the complete line so delimiters both before and
                        // after the separator remain owned by this removal span.
                        finishToken(in: frameIndex)
                        state.frames[frameIndex].atWordStart = true
                        state.frames[frameIndex].atCommandStart = true
                        crossedRootSeparator = true
                    } else if state.frames[frameIndex].kind == .arithmetic, ch == "(" {
                        state.frames[frameIndex].delimiterDepth += 1
                        state.frames[frameIndex].atWordStart = false
                    } else if state.frames[frameIndex].kind == .arithmetic, ch == ")" {
                        state.frames[frameIndex].delimiterDepth -= 1
                        if state.frames[frameIndex].delimiterDepth == 0 {
                            state.frames.removeLast()
                        }
                    } else if state.frames[frameIndex].kind == .parameter, ch == "{" {
                        state.frames[frameIndex].delimiterDepth += 1
                        state.frames[frameIndex].atWordStart = false
                    } else if state.frames[frameIndex].kind == .parameter, ch == "}" {
                        state.frames[frameIndex].delimiterDepth -= 1
                        if state.frames[frameIndex].delimiterDepth == 0 {
                            state.frames.removeLast()
                        }
                    } else if state.frames[frameIndex].kind == .command
                                || state.frames[frameIndex].kind == .process
                                || state.frames[frameIndex].kind == .backtick {
                        if ch == "(" {
                            finishToken(in: frameIndex)
                            // zsh accepts both `word)` and `(word)` case-arm forms.
                            // The optional opening paren belongs to the pattern grammar,
                            // not to the command substitution's structural depth.
                            if state.frames[frameIndex].cases.last != .pattern {
                                state.frames[frameIndex].delimiterDepth += 1
                            }
                            state.frames[frameIndex].atWordStart = true
                        } else if ch == ")" {
                            finishToken(in: frameIndex)
                            if state.frames[frameIndex].cases.last == .pattern {
                                state.frames[frameIndex].cases[
                                    state.frames[frameIndex].cases.count - 1] = .body
                                state.frames[frameIndex].atCommandStart = true
                            } else {
                                state.frames[frameIndex].delimiterDepth -= 1
                                if state.frames[frameIndex].delimiterDepth == 0 {
                                    state.frames.removeLast()
                                }
                            }
                        } else if ch == ";" || ch == "|" || ch == "&" {
                            finishToken(in: frameIndex)
                            // Separators inside a substitution separate its commands,
                            // not the outer alias statement.
                            state.frames[frameIndex].atWordStart = true
                            state.frames[frameIndex].atCommandStart = true
                            if ch == ";",
                               let terminator = character(after: index),
                               terminator == ";" || terminator == "&" || terminator == "|",
                               state.frames[frameIndex].cases.last == .body {
                                state.frames[frameIndex].cases[
                                    state.frames[frameIndex].cases.count - 1] = .pattern
                                index = line.index(after: index)
                            }
                        } else {
                            appendToToken(ch, in: frameIndex)
                            state.frames[frameIndex].atWordStart = false
                        }
                    } else {
                        state.frames[frameIndex].atWordStart = false
                    }
                }
                if endedInComment { break }
                index = line.index(after: index)
            }

            if endedInComment {
                state.frames[state.frames.count - 1].atWordStart = true
            } else if !trailingEscape,
                      state.frames[state.frames.count - 1].quote == .unquoted {
                // A physical newline is a command boundary inside substitutions. A
                // backslash-newline is removed instead, so it deliberately preserves
                // the word-boundary state from before the backslash.
                finishToken(in: state.frames.count - 1)
                state.frames[state.frames.count - 1].atWordStart = true
                state.frames[state.frames.count - 1].atCommandStart = true
                if state.frames[state.frames.count - 1].activeHeredoc == nil,
                   !state.frames[state.frames.count - 1].pendingHeredocs.isEmpty {
                    state.frames[state.frames.count - 1].activeHeredoc =
                        state.frames[state.frames.count - 1].pendingHeredocs.removeFirst()
                }
            }

            // Any open nesting frame or quote carries the statement across a newline.
            // A comment suppresses a trailing backslash, exactly as zsh does.
            let rootQuoteOpen = state.frames.first?.quote != .unquoted
            let heredocOpen = state.frames.contains {
                $0.activeHeredoc != nil || !$0.pendingHeredocs.isEmpty
            }
            // Once a root separator has ended the alias command, later syntax on that
            // physical line must not extend its span. Heredoc bodies are the exception:
            // the shell consumes them after the newline, and leaving them behind would
            // turn their payload into executable input.
            state.continues = state.hasUnconsumedHeredoc
                || (!crossedRootSeparator
                    && (state.frames.count > 1 || rootQuoteOpen || heredocOpen
                        || (!endedInComment && trailingEscape)))
            return state
        }

        guard let begin = bounds.begin, let end = bounds.end else {
            // No block yet.
            switch operation {
            case .delete:
                // Nothing to remove, and nothing to report: the desired end state
                // already holds.
                return (lines, [])
            case .rename(let from, _, _):
                // A rename with no block at all means the source is definitively gone,
                // which is a stale edit rather than a no-op.
                throw WriteError.renameSourceMissing(from)
            case .upsert(let name, let command, _):
                var output = lines
                if let last = output.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                    output.append("")
                }
                output += [ManagedBlock.begin,
                           ManagedBlock.notice,
                           aliasLine(name: name,
                                     command: command.trimmingCharacters(in: .whitespacesAndNewlines)),
                           ManagedBlock.end]
                return (output, [])
            }
        }

        var output = lines
        var removed: [[String]] = []

        switch operation {
        case .upsert(let name, let command, _):
            let line = aliasLine(name: name,
                                 command: command.trimmingCharacters(in: .whitespacesAndNewlines))
            if let range = try rangeOfAlias(named: name, begin: begin, end: end) {
                removed.append(Array(lines[range]))
                output.replaceSubrange(range, with: [line])
            } else {
                output.insert(line, at: end)
            }

        case .delete(let name):
            if let range = try rangeOfAlias(named: name, begin: begin, end: end) {
                removed.append(Array(lines[range]))
                output.removeSubrange(range)
            }

        case .rename(let from, let to, let command):
            let line = aliasLine(name: to,
                                 command: command.trimmingCharacters(in: .whitespacesAndNewlines))
            let newRange = try rangeOfAlias(named: to, begin: begin, end: end)

            // The source must exist. Accepting "source or destination" was not enough:
            // if the source had been deleted while the editor was open but the
            // destination happened to exist, a stale rename would silently overwrite
            // the destination's command.
            guard let oldRange = try rangeOfAlias(named: from, begin: begin, end: end) else {
                throw WriteError.renameSourceMissing(from)
            }

            removed.append(Array(lines[oldRange]))
            if let newRange, newRange != oldRange { removed.append(Array(lines[newRange])) }

            if let newRange, newRange != oldRange {
                // The destination name already exists in the block: overwrite it and
                // drop the old definition. Both edits land in this one set of contents,
                // so there is no window where the alias exists under neither name.
                // Higher index first, or removing the earlier one shifts the later.
                if oldRange.lowerBound > newRange.lowerBound {
                    output.removeSubrange(oldRange)
                    output.replaceSubrange(newRange, with: [line])
                } else {
                    output.replaceSubrange(newRange, with: [line])
                    output.removeSubrange(oldRange)
                }
            } else {
                output.replaceSubrange(oldRange, with: [line])
            }
        }

        return (output, removed)
    }

    // MARK: - Backup

    /// Timestamped backup beside the original. The UUID keeps two writes in the same
    /// second from selecting the same path and overwriting the first recovery point.
    /// Returns its path so the UI can name it.
    private static func writeBackup(of contents: String, for path: String) throws -> String {
        guard !contents.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = TimeZone.current
        let stamp = formatter.string(from: Date())
        let unique = UUID().uuidString.lowercased()
        let backupPath = "\(path).aliasbar-backup-\(stamp)-\(unique)"
        do {
            try contents.write(toFile: backupPath, atomically: true, encoding: .utf8)
        } catch {
            throw WriteError.backupFailed(error.localizedDescription)
        }
        return backupPath
    }

    // MARK: - Atomic write

    /// Writes via a temp file in the same directory, then `rename`, which is atomic
    /// within a filesystem. Permissions and ownership are copied onto the replacement
    /// first, so the rc file does not silently become mode 600 or change owner.
    /// Commits the new contents.
    ///
    /// **On the limits of this, stated plainly:** `rename(2)` guarantees the file is
    /// never seen half-written. It guarantees nothing about lost updates. The final
    /// verification and the rename cannot be made a single atomic operation against an
    /// arbitrary file, and no cooperative locking exists for rc files — Vim, VS Code,
    /// and dotfile syncers do not take advisory locks on `.zshrc`, so taking one here
    /// would protect against nobody.
    ///
    /// What is done instead: the check is moved as close to the rename as possible, and
    /// compares the *content* as well as device, inode, size, and mtime, since a same-
    /// size edit within one timestamp tick would otherwise slip through. That narrows
    /// the window to the microseconds between the comparison and the syscall. It does
    /// not close it. The timestamped backup is the real backstop.
    private static func atomicWrite(_ text: String, to path: String,
                                    expecting snapshotAtRead: FileSnapshot?,
                                    matching originalContents: String) throws {
        let fm = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        let tempPath = directory + "/.aliasbar-write-\(UUID().uuidString)"

        // Capture the original's attributes before it is replaced.
        let originalAttributes = try? fm.attributesOfItem(atPath: path)

        do {
            try text.write(toFile: tempPath, atomically: false, encoding: .utf8)
        } catch {
            throw WriteError.writeFailed(error.localizedDescription)
        }

        // Last check before committing. Metadata first, then content: a same-size edit
        // landing inside a single mtime tick has identical metadata, so identity alone
        // would wave it through.
        let currentSnapshot = FileSnapshot.of(path)
        // lstat, not fileExists. `fileExists` follows symlinks, so a dangling symlink
        // planted at this path since the read reads as "absent" — and renaming over it
        // would destroy the link. With no original contents there is also no backup, so
        // that loss would be unrecoverable. Any directory entry that was not there
        // before is a reason to stop.
        var entry = stat()
        let entryExists = lstat(path, &entry) == 0
        let unchanged: Bool
        if !entryExists {
            // Absent now is only acceptable if it was absent when we read.
            unchanged = originalContents.isEmpty && snapshotAtRead == nil
        } else if snapshotAtRead == nil {
            // It was absent when we read and something exists now, whatever it is.
            unchanged = false
        } else if (entry.st_mode & S_IFMT) == S_IFLNK {
            // The target resolved to a real file at read time. If it is a symlink now,
            // the chain changed underneath us.
            unchanged = false
        } else if currentSnapshot != snapshotAtRead {
            unchanged = false
        } else {
            let now = try? String(contentsOfFile: path, encoding: .utf8)
            unchanged = (now == originalContents)
        }
        guard unchanged else {
            try? fm.removeItem(atPath: tempPath)
            throw WriteError.modifiedElsewhere
        }

        if let attributes = originalAttributes {
            var carried: [FileAttributeKey: Any] = [:]
            if let posix = attributes[.posixPermissions] { carried[.posixPermissions] = posix }
            if let owner = attributes[.ownerAccountID] { carried[.ownerAccountID] = owner }
            if let group = attributes[.groupOwnerAccountID] { carried[.groupOwnerAccountID] = group }
            // Ownership changes need privileges the app does not have when the file is
            // owned by someone else; permissions are the part that actually matters.
            try? fm.setAttributes(carried, ofItemAtPath: tempPath)
        }

        // `rename(2)` replaces the destination atomically. FileManager's replaceItem
        // would also work but leaves more room for partial states on failure.
        if rename(tempPath, path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tempPath)
            throw WriteError.writeFailed(reason)
        }
    }
}
