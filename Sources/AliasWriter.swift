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
    static func apply(_ operation: Operation,
                      path: String,
                      allEntries: [ShellEntry]) throws -> String {
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
        // Re-checked immediately before the replacement. Atomic rename prevents a
        // half-written file; it does nothing about a lost update.
        let snapshotAtRead = snapshotAfterRead

        // Whether the file ends in a newline is a property worth preserving exactly.
        let endedWithNewline = original.hasSuffix("\n") || original.isEmpty
        var lines = original.components(separatedBy: "\n")
        if endedWithNewline && lines.last == "" { lines.removeLast() }

        let output = try rewrite(lines: lines, applying: operation)

        var text = output.joined(separator: "\n")
        if endedWithNewline || !text.isEmpty { text += "\n" }

        let backup = try writeBackup(of: original, for: target)
        try atomicWrite(text, to: target, expecting: snapshotAtRead, matching: original)
        return backup
    }

    /// Produces the new file contents.
    ///
    /// Edits happen line by line inside the block rather than by regenerating it from a
    /// parsed alias list. Regenerating is tidier but destructive: anything inside the
    /// markers that is not a plain `alias` line, including comments the user added, a
    /// function, or a hand-repair after a bad merge, would vanish on the next save with
    /// no warning. Only the specific line being changed is touched.
    private static func rewrite(lines: [String], applying operation: Operation) throws -> [String] {
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

        /// Where the lexer is when a line ends.
        ///
        /// Tracking single quotes alone is not enough. Three cases break it:
        /// an apostrophe inside a double-quoted value (`alias x="echo it's fine"`) looks
        /// like an opening quote; a double-quoted value spanning lines looks complete
        /// after the first; and a trailing unescaped backslash continues the statement
        /// onto the next line with no quote involved at all. Each of those either
        /// rejects a valid alias or, worse, truncates a statement and leaves the
        /// remainder as a bare command that runs at shell startup.
        enum QuoteState { case unquoted, single, double }

        /// Everything the lexer needs to carry from one line to the next.
        struct LexState {
            var quote: QuoteState = .unquoted
            /// Whether the previous character was unquoted whitespace (or this is the
            /// start of a line). `#` introduces a comment only there; anywhere inside a
            /// word it is an ordinary character.
            ///
            /// **Only whitespace sets this, deliberately.** Shell metacharacters look
            /// like word separators, but `(`, `)`, `{`, and `}` all occur *inside*
            /// single words through `${HOME}`, `$((1))`, `$(cmd)`, `<(cmd)`, and brace
            /// expansion. Counting any of them as a boundary makes a following `#` look
            /// like a comment introducer, which hides a trailing backslash and orphans
            /// the continuation line as a command that runs at shell startup. That
            /// exact bug arrived twice, via `}` and via `)`.
            ///
            /// Distinguishing a metacharacter from a substitution needs full nesting
            /// state for arithmetic, command, process, and glob constructs. Whitespace
            /// is the rule that is both simple and safe. The one case it gets wrong is
            /// `;#comment` or `|#comment` ending in a backslash, where the span extends
            /// one line too far; that costs an over-delete of a comment line rather than
            /// leaving live code behind, and standalone metacharacters are surrounded by
            /// whitespace in practice anyway.
            var atWordStart = true
            /// Whether the statement continues onto the following line.
            var continues = false
        }

        /// Advances the lexer across one line.
        func scan(_ line: String, from entering: LexState) -> LexState {
            var state = entering
            var index = line.startIndex
            var trailingEscape = false

            while index < line.endIndex {
                let ch = line[index]
                trailingEscape = false

                switch state.quote {
                case .single:
                    // Wholly literal. A backslash here is just a backslash, so the very
                    // next apostrophe closes the string.
                    if ch == "'" { state.quote = .unquoted }
                    state.atWordStart = false

                case .double:
                    if ch == "\\" {
                        let next = line.index(after: index)
                        if next == line.endIndex { trailingEscape = true; index = next; continue }
                        index = next
                    } else if ch == "\"" {
                        state.quote = .unquoted
                    }
                    state.atWordStart = false

                case .unquoted:
                    if ch == "\\" {
                        let next = line.index(after: index)
                        if next == line.endIndex { trailingEscape = true; index = next; continue }
                        index = next
                        state.atWordStart = false
                    } else if ch == "'" {
                        state.quote = .single
                        state.atWordStart = false
                    } else if ch == "\"" {
                        state.quote = .double
                        state.atWordStart = false
                    } else if ch == "#" && state.atWordStart {
                        // A real comment: runs to end of line, opens nothing, and
                        // cannot carry a line continuation.
                        state.continues = false
                        return state
                    } else if ch == " " || ch == "\t" {
                        state.atWordStart = true
                    } else {
                        // Includes `#` mid-word, which zsh treats as an ordinary
                        // character. Missing that would let `echo#tag\` hide a
                        // continuation and orphan the next line as a live command.
                        state.atWordStart = false
                    }
                }
                index = line.index(after: index)
            }

            // The statement continues if a quote is still open, or if the line ended on
            // an unescaped backslash. In single quotes a trailing backslash is literal,
            // but the open quote already means continuation.
            state.continues = state.quote != .unquoted || trailingEscape
            // Deliberately does NOT force atWordStart false on a trailing backslash.
            // zsh removes the backslash-newline pair but not the whitespace before it,
            // so `alias x=1 \` resumes at a word boundary and a following `# comment`
            // really is a comment, while `echo#tag\` resumes mid-word. The state left
            // by the character before the backslash already encodes exactly that
            // distinction, because the trailing-backslash branch returns before
            // touching it. Overriding it here merged a comment line into the statement
            // and let a deletion swallow the next alias.
            return state
        }

        guard let begin = bounds.begin, let end = bounds.end else {
            // No block yet.
            switch operation {
            case .delete:
                // Nothing to remove, and nothing to report: the desired end state
                // already holds.
                return lines
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
                return output
            }
        }

        var output = lines

        switch operation {
        case .upsert(let name, let command, _):
            let line = aliasLine(name: name,
                                 command: command.trimmingCharacters(in: .whitespacesAndNewlines))
            if let range = try rangeOfAlias(named: name, begin: begin, end: end) {
                output.replaceSubrange(range, with: [line])
            } else {
                output.insert(line, at: end)
            }

        case .delete(let name):
            if let range = try rangeOfAlias(named: name, begin: begin, end: end) {
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

        return output
    }

    // MARK: - Backup

    /// Timestamped backup beside the original. Returns its path so the UI can name it.
    private static func writeBackup(of contents: String, for path: String) throws -> String {
        guard !contents.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = TimeZone.current
        let stamp = formatter.string(from: Date())
        let backupPath = "\(path).aliasbar-backup-\(stamp)"
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
