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
        if case .upsert(let name, let command, _) = operation {
            try validate(name: name, command: command)
            // A definition outside the block wins or loses depending on file order, and
            // either way this writer has no business rewriting a line it did not author.
            if let clash = allEntries.first(where: { $0.name == name && !$0.managed }) {
                throw WriteError.definedOutsideBlock(name: name,
                                                     file: clash.sourceFile,
                                                     line: clash.line)
            }
        }

        let original: String
        do {
            original = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            // An rc file that does not exist yet is a legitimate starting state.
            if FileManager.default.fileExists(atPath: path) == false {
                original = ""
            } else {
                throw WriteError.unreadable(error.localizedDescription)
            }
        }

        // Whether the file ends in a newline is a property worth preserving exactly.
        let endedWithNewline = original.hasSuffix("\n") || original.isEmpty
        var lines = original.components(separatedBy: "\n")
        if endedWithNewline && lines.last == "" { lines.removeLast() }

        let bounds = try locateBlock(in: lines)

        // Read the current block, mutate that list, then re-emit the whole block. This
        // keeps the block canonical and means a delete cannot leave a dangling comment.
        var managed = try managedAliases(in: lines)
        switch operation {
        case .upsert(let name, let command, _):
            let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if let idx = managed.firstIndex(where: { $0.name == name }) {
                managed[idx] = (name, clean)
            } else {
                managed.append((name, clean))
            }
        case .delete(let name):
            managed.removeAll { $0.name == name }
        }

        var block: [String] = [ManagedBlock.begin, ManagedBlock.notice]
        block += managed.map { aliasLine(name: $0.name, command: $0.command) }
        block.append(ManagedBlock.end)

        var output: [String]
        if let begin = bounds.begin, let end = bounds.end {
            output = Array(lines[..<begin]) + block + Array(lines[(end + 1)...])
        } else {
            output = lines
            // Separate a fresh block from whatever the file already ended with.
            if let last = output.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                output.append("")
            }
            output += block
        }

        var text = output.joined(separator: "\n")
        if endedWithNewline || !text.isEmpty { text += "\n" }

        let backup = try writeBackup(of: original, for: path)
        try atomicWrite(text, to: path)
        return backup
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
    private static func atomicWrite(_ text: String, to path: String) throws {
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
