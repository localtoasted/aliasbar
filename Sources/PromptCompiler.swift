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

// MARK: - SHA-256

/// A from-scratch SHA-256, kept in this file rather than pulled in from CryptoKit or
/// CommonCrypto so PromptCompiler stays a single self-contained, Foundation-only unit
/// with nothing to link and nothing shared with any other part of the app. Verified
/// against the standard NIST/Wikipedia test vectors, including a multi-block input,
/// before being relied on for the hash comparisons that decide whether a file gets
/// overwritten.
enum SHA256Digest {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%08x", $0) }.joined()
    }

    static func hex(_ text: String) -> String {
        hex(Data(text.utf8))
    }

    private static func digest(_ data: Data) -> [UInt32] {
        var h = initialHash
        let k = roundConstants

        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(i)) & 0xff))
        }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

        var chunkStart = 0
        while chunkStart < message.count {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(message[base]) << 24) | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8) | UInt32(message[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh

            chunkStart += 64
        }

        return h
    }
}
