import Foundation

/// Installs approved prompts as Claude Code slash commands under `~/.claude/commands`.
///
/// This is a fully siloed writer. It shares no types, no helpers, and no code with
/// AliasWriter, on purpose: a bug in one must be physically incapable of touching what
/// the other manages. Nothing here ever reads or writes a shell config, and nothing in
/// AliasWriter ever reads or writes a Claude Code command file.
///
/// The rules it holds to:
///
/// 1. It never overwrites, deletes, or uninstalls a file it did not itself write,
///    byte for byte. Ownership is tracked in a registry (`compiled.json`), and every
///    mutation checks the file on disk against the hash the registry recorded before
///    touching anything. A mismatch means someone else — most likely the user, by
///    hand — changed the file since, and that always wins over AliasBar's copy.
/// 2. Every write is atomic: a temp file in the same directory, then `rename`.
/// 3. Every replacement or removal is preceded by a timestamped backup.
/// 4. A registry that fails to parse is never repaired by overwriting it. Refusing
///    outright is the only response that cannot make things worse.
enum PromptCompiler {

    // MARK: - Errors

    enum CompileError: LocalizedError {
        case invalidName(String)
        case caseCollision(name: String, existing: String)
        case collision(name: String, path: String)
        case hashMismatch(name: String, path: String)
        case notInstalled(String)
        case registryPathEscape(name: String, path: String)
        case registryCorrupt(String)
        case registryUnreadable(String)
        case backupFailed(String)
        case writeFailed(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                return "\"\(name)\" isn't a usable command name. Use letters, digits, - and _ only."
            case .caseCollision(let name, let existing):
                return "\"\(name)\" differs only in case from the existing command \"\(existing)\", which would be ambiguous. Nothing was written."
            case .collision(let name, let path):
                return "\(path) already exists and wasn't installed by AliasBar, so \"\(name)\" wasn't touched. Remove or rename it by hand first."
            case .hashMismatch(let name, let path):
                return "\(path) was edited since AliasBar installed it, so \"\(name)\" wasn't touched. Reinstall on purpose if you want AliasBar's version back."
            case .notInstalled(let name):
                return "\"\(name)\" isn't in AliasBar's registry, so there's nothing to uninstall."
            case .registryPathEscape(let name, let path):
                return "The registry entry for \"\(name)\" points at \(path), which is not where AliasBar installs commands. Nothing was touched."
            case .registryCorrupt(let path):
                return "AliasBar's command registry at \(path) is malformed, so nothing was changed. Fix or remove it by hand first."
            case .registryUnreadable(let path):
                return "Couldn't read AliasBar's command registry at \(path), so nothing was changed."
            case .backupFailed(let path):
                return "Couldn't write a backup at \(path), so nothing was changed."
            case .writeFailed(let path):
                return "Couldn't write \(path)."
            case .unreadable(let path):
                return "Couldn't read \(path)."
            }
        }
    }

    // MARK: - Registry

    /// One row of `compiled.json`: everything needed to prove, later, that a file is
    /// still exactly what AliasBar wrote.
    struct RegistryEntry: Codable, Equatable {
        let path: String
        let sha256: String
        let installedAt: Date
    }

    /// The ownership registry, keyed by command name. A dictionary rather than an
    /// array because the operations that matter — "do we own this name", "what did we
    /// record for it" — are all lookups by name.
    private typealias Registry = [String: RegistryEntry]

    /// A row of `installedCommands`, with the name promoted out of the registry's key
    /// so callers get a self-contained value.
    struct InstalledCommand: Equatable {
        let name: String
        let path: String
        let sha256: String
        let installedAt: Date
    }

    enum RegistryOutcome {
        case ok([InstalledCommand])
        case corrupt(path: String, reason: String)
    }

    /// Everything AliasBar's registry currently believes it installed, or why the
    /// registry couldn't be read. A missing registry file is not corruption — it is
    /// the state before the first install — and reads back as an empty list.
    static func installedCommands(registryPath: String) -> RegistryOutcome {
        do {
            let registry = try loadRegistry(at: registryPath)
            let list = registry
                .map { InstalledCommand(name: $0.key, path: $0.value.path,
                                        sha256: $0.value.sha256, installedAt: $0.value.installedAt) }
                .sorted { $0.name < $1.name }
            return .ok(list)
        } catch let error as CompileError {
            return .corrupt(path: registryPath, reason: error.errorDescription ?? "unreadable")
        } catch {
            return .corrupt(path: registryPath, reason: error.localizedDescription)
        }
    }

    // MARK: - Compile

    struct CompileResult {
        let path: String
        /// Set only when this call replaced a file AliasBar had already installed:
        /// the path of the backup taken of what was there immediately before.
        let backup: String?
        /// Advisory only. A command name that shadows a Claude Code builtin still
        /// installs; the caller decides whether to warn the user or block on it.
        let builtinCollision: BuiltinSlashCommands.CollisionKind?
    }

    /// Writes `name.md` into `commandsDir` and records it in the registry at
    /// `registryPath`.
    ///
    /// Every check below runs before anything is written. A fresh install just needs
    /// the name to be valid and the destination free; updating a name AliasBar already
    /// owns additionally needs the file on disk to still match the hash recorded for
    /// it, or the edit is refused rather than clobbered.
    static func compile(name: String,
                        description: String?,
                        body: String,
                        commandsDir: String,
                        registryPath: String) throws -> CompileResult {
        try validateName(name, commandsDir: commandsDir)

        var registry = try loadRegistry(at: registryPath)
        let destination = (commandsDir as NSString).appendingPathComponent("\(name).md")
        let content = render(description: description, body: body)
        let newHash = SHA256Digest.hex(content)

        try FileManager.default.createDirectory(atPath: commandsDir, withIntermediateDirectories: true)

        var backupPath: String?
        if FileManager.default.fileExists(atPath: destination) {
            // A file is here already. AliasBar may only replace it if the registry
            // says AliasBar put it here, and only if it still reads back exactly as
            // recorded — otherwise this either belongs to the user outright or has
            // been hand-edited since, and either way it is not this call's to touch.
            guard let existing = registry[name] else {
                throw CompileError.collision(name: name, path: destination)
            }
            let onDisk = try readFile(destination)
            guard SHA256Digest.hex(onDisk) == existing.sha256 else {
                throw CompileError.hashMismatch(name: name, path: destination)
            }
            backupPath = try writeBackup(of: onDisk, name: name,
                                         backupsDir: backupsDirectory(for: registryPath))
        }

        // The file is written before the registry that claims ownership of it, on
        // purpose. If the registry write below failed after this succeeded, the next
        // call would find a file on disk with no matching registry entry and refuse
        // it as a collision — a safe failure that asks a human to look, never one
        // that clobbers or deletes. The reverse order risks the opposite: a registry
        // entry vouching for content that was never actually written.
        try atomicWrite(content, to: destination)

        registry[name] = RegistryEntry(path: destination, sha256: newHash, installedAt: Date())
        try saveRegistry(registry, to: registryPath)

        return CompileResult(path: destination, backup: backupPath,
                             builtinCollision: BuiltinSlashCommands.collides(name: name))
    }

    // MARK: - Uninstall

    /// Removes `name`'s file and registry entry, but only if the registry still owns
    /// it and the file on disk still matches what was recorded. Returns the path of
    /// the backup taken of the removed content.
    @discardableResult
    static func uninstall(name: String, commandsDir: String, registryPath: String) throws -> String {
        var registry = try loadRegistry(at: registryPath)
        guard let entry = registry[name] else {
            throw CompileError.notInstalled(name)
        }

        // The registry is a plain JSON file that may live in a synced directory, so
        // its contents are data, not authority: the only file uninstall may ever act
        // on is the one this compiler would itself have written for this name.
        let expectedPath = URL(fileURLWithPath: commandsDir)
            .appendingPathComponent("\(name).md").standardizedFileURL.path
        guard URL(fileURLWithPath: entry.path).standardizedFileURL.path == expectedPath else {
            throw CompileError.registryPathEscape(name: name, path: entry.path)
        }

        guard FileManager.default.fileExists(atPath: entry.path) else {
            // Nothing left on disk to protect or back up. The registry entry is now
            // just stale bookkeeping, so it is dropped and nothing else happens.
            registry.removeValue(forKey: name)
            try saveRegistry(registry, to: registryPath)
            return entry.path
        }

        let onDisk = try readFile(entry.path)
        guard SHA256Digest.hex(onDisk) == entry.sha256 else {
            throw CompileError.hashMismatch(name: name, path: entry.path)
        }

        let backupPath = try writeBackup(of: onDisk, name: name,
                                         backupsDir: backupsDirectory(for: registryPath))

        try FileManager.default.removeItem(atPath: entry.path)
        registry.removeValue(forKey: name)
        try saveRegistry(registry, to: registryPath)

        return backupPath
    }

    // MARK: - Name validation

    /// Same character class prompt names use elsewhere in AliasBar: ASCII letters,
    /// digits, `-`, and `_`. Anything else either cannot appear in a `/slash-command`
    /// invocation or would need escaping Claude Code does not support.
    private static let allowedNameCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    private static func validateName(_ name: String, commandsDir: String) throws {
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowedNameCharacters.contains($0) }) else {
            throw CompileError.invalidName(name)
        }
        // Case-insensitive collision against whatever is already on disk. On the
        // case-insensitive filesystem most Macs use, "Foo.md" and "foo.md" are the
        // same file, so treating them as distinct here would be a fiction; on a
        // case-sensitive one it would create two commands a user can only tell apart
        // by squinting. Refusing is simpler than making that call for them, and an
        // exact-case match (updating the same name again) is explicitly allowed
        // through.
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: commandsDir) else {
            return
        }
        for entry in entries where entry.hasSuffix(".md") {
            let stem = String(entry.dropLast(3))
            if stem.lowercased() == name.lowercased(), stem != name {
                throw CompileError.caseCollision(name: name, existing: stem)
            }
        }
    }

    // MARK: - File contents

    /// The literal bytes this writer emits for a prompt.
    ///
    /// The frontmatter block is entirely optional: with no description, the file is
    /// just the provenance comment followed by the body. Claude Code's own command
    /// files are plain markdown, and there is no reason for AliasBar's to look any
    /// different when there is nothing to put in the frontmatter.
    static func render(description: String?, body: String) -> String {
        var out = ""
        if let description {
            // A description belongs to the YAML frontmatter as a single scalar line;
            // a newline inside it would either break the block or silently swallow
            // everything after the first line. Collapsing it here, rather than
            // trusting every call site to have already done so, is what keeps that
            // guarantee unconditional.
            let oneLine = description
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .first ?? ""
            if !oneLine.isEmpty {
                out += "---\n"
                out += "description: \(oneLine)\n"
                out += "---\n"
            }
        }
        out += "<!-- managed by AliasBar -->\n"
        out += body
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - Registry I/O

    private static func loadRegistry(at path: String) throws -> Registry {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw CompileError.registryUnreadable(path)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Registry.self, from: data)
        } catch {
            throw CompileError.registryCorrupt(path)
        }
    }

    private static func saveRegistry(_ registry: Registry, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys and pretty-printing cost nothing here and make the file
        // readable and diffable for anyone who goes looking at it directly.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try atomicWrite(data, to: path)
    }

    /// Backups live next to the registry rather than under a hardcoded `~/.aliasbar`,
    /// so tests can point both at the same fixture root and never touch a real home
    /// directory.
    private static func backupsDirectory(for registryPath: String) -> String {
        let base = (registryPath as NSString).deletingLastPathComponent
        return (base.isEmpty ? "." : base) + "/.backups/commands"
    }

    private static func writeBackup(of content: String, name: String, backupsDir: String) throws -> String {
        try FileManager.default.createDirectory(atPath: backupsDir, withIntermediateDirectories: true)
        let path = backupsDir + "/\(name)-\(backupTimestamp()).md"
        guard FileManager.default.createFile(atPath: path, contents: Data(content.utf8)) else {
            throw CompileError.backupFailed(path)
        }
        return path
    }

    /// Microsecond-resolution timestamp, so two backups of the same name taken within
    /// the same wall-clock second — easily reachable from a test loop, and not
    /// impossible from a person clicking twice — still land at distinct paths.
    private static func backupTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded()) % 1_000_000
        return "\(formatter.string(from: date))-\(String(format: "%06d", micros))"
    }

    private static func readFile(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw CompileError.unreadable(path)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Atomic write

    /// Writes `data` to `path` via a temp file in the same directory followed by
    /// `rename`, which POSIX guarantees is atomic. A reader can observe the old
    /// contents or the new ones, in full, and nothing in between — never a partial
    /// write, whichever process gets there first.
    private static func atomicWrite(_ data: Data, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let targetDir = dir.isEmpty ? "." : dir
        try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        let temp = targetDir + "/.aliasbar-tmp-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: temp, contents: data) else {
            throw CompileError.writeFailed(path)
        }
        guard rename(temp, path) == 0 else {
            try? FileManager.default.removeItem(atPath: temp)
            throw CompileError.writeFailed(path)
        }
    }

    private static func atomicWrite(_ content: String, to path: String) throws {
        try atomicWrite(Data(content.utf8), to: path)
    }
}

/// Claude Code's built-in slash commands, as a fixed reference list.
///
/// `collides(name:)` only ever produces a warning, never a refusal: nothing here
/// blocks `compile`, because a name shadowing a builtin might be exactly what the
/// user wants (project conventions vary), and this list will drift out of date as
/// Claude Code adds or retires commands. Undercounting a collision is a missed
/// warning; it is never an incorrect refusal, because refusing is not this type's
/// job in the first place.
enum BuiltinSlashCommands {
    /// The version this snapshot was taken from. Update alongside the list below
    /// when Claude Code's builtins change; there is no automated way to detect drift.
    static let version = "claude-code v2026-07"

    static let names: Set<String> = [
        "help", "clear", "compact", "config", "cost", "doctor", "init", "login", "logout",
        "mcp", "memory", "model", "permissions", "pr-comments", "review", "status",
        "terminal-setup", "vim", "add-dir", "agents", "bashes", "bug", "code-review",
        "security-review", "fast", "resume", "rewind", "todos", "statusline",
        "output-style", "release-notes", "migrate-installer", "install-github-app",
        "upgrade", "exit", "hooks", "ide", "export", "context", "usage", "plugin", "skills",
    ]

    enum CollisionKind { case builtin }

    static func collides(name: String) -> CollisionKind? {
        names.contains(name.lowercased()) ? .builtin : nil
    }
}
