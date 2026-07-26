import Foundation

// MARK: - Frontmatter

/// The metadata block at the top of a prompt file, between a pair of `---` lines.
///
/// Every line is kept close to its original text — split only on the first `:`, with
/// everything after it (including whatever spacing a human typed) stored verbatim.
/// That is what makes `PromptStore.write` able to reproduce a file byte-for-byte when
/// nothing in it actually changed: reconstruction is just `"\(key):\(raw)"` for each
/// entry, never a re-formatted guess at what the line "should" look like. Lines with no
/// colon at all (a human wrote something odd, or a future key type this code doesn't
/// know about) are kept too, as a `key: nil` entry carrying the whole raw line.
struct PromptFrontmatter: Equatable {
    struct Entry: Equatable {
        let key: String?
        /// For a recognized `key: value` line, everything after the first `:`,
        /// unmodified. For an unrecognized line, the entire original line.
        let raw: String
    }

    var entries: [Entry]

    private func value(for key: String) -> String? {
        entries.first { $0.key == key }?.raw
    }

    var schema: Int? {
        value(for: "schema").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    var description: String? {
        guard let raw = value(for: "description") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    var delivery: Set<DeliveryTarget> {
        guard let raw = value(for: "delivery") else { return [] }
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return Set(tokens.compactMap { DeliveryTarget(rawValue: $0.lowercased()) })
    }

    var edited: Date? {
        guard let raw = value(for: "edited") else { return nil }
        return PromptFrontmatter.iso8601.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    private static let iso8601 = ISO8601DateFormatter()

    /// A fresh frontmatter block with nothing but the required schema line.
    static func empty() -> PromptFrontmatter {
        PromptFrontmatter(entries: [Entry(key: "schema", raw: " 1")])
    }

    /// Renders a delivery set the way this format's `delivery:` line expects it.
    static func deliveryValue(_ targets: Set<DeliveryTarget>) -> String {
        targets.map(\.rawValue).sorted().joined(separator: ", ")
    }

    /// Returns a copy with `key` set to `value`, replacing the first existing entry
    /// for that key in place — so editing a description a human already wrote doesn't
    /// relocate it — or appending a new entry if the key wasn't present. `value` is
    /// stored with one leading space (`" \(value)"`) so freshly authored lines come
    /// out as `key: value`, matching the format everywhere else in this file.
    func setting(_ key: String, to value: String) -> PromptFrontmatter {
        var updated = entries
        let entry = Entry(key: key, raw: " \(value)")
        if let idx = updated.firstIndex(where: { $0.key == key }) {
            updated[idx] = entry
        } else {
            updated.append(entry)
        }
        return PromptFrontmatter(entries: updated)
    }

    func removingEntry(for key: String) -> PromptFrontmatter {
        PromptFrontmatter(entries: entries.filter { $0.key != key })
    }
}

// MARK: - Prompt

/// A prompt file's parsed contents: its name (the filename stem), the frontmatter block
/// if it had one, and the body exactly as it appeared after the closing `---`.
///
/// `frontmatter == nil` means the file had no recognized frontmatter at all — most
/// hand-written prompts will look like this, and for these `PromptStore.write` emits
/// exactly `body` and nothing else. This is deliberate: a prompt file is public, human-
/// edited API, and a file that never opted into frontmatter should never have one
/// silently added underneath it.
struct Prompt: Equatable {
    let name: String
    var frontmatter: PromptFrontmatter?
    var body: String

    var description: String? { frontmatter?.description }
    var deliveryTargets: Set<DeliveryTarget> { frontmatter?.delivery ?? [] }
    var editedAt: Date? { frontmatter?.edited }
    var slots: [String] { PromptSlotParser.slots(in: body) }
}

// MARK: - Slot parsing

/// Parses and renders the `{{slot_name}}` grammar used inside prompt bodies.
///
/// Kept free of anything specific to prompt *files* — it operates on a plain body
/// string — because PRE-251 reuses the same grammar for snippets.
///
/// The grammar, in full: a slot is `{{`, one or more `[A-Za-z0-9_-]` characters, `}}`,
/// with nothing else allowed in between. Everything else — a single brace, an unclosed
/// pair, a name containing a space or a dot, a name that's empty — is literal text.
/// There is no escape sequence and no error case: a body that doesn't match is simply a
/// body with no slots in that spot. This is what lets prompt bodies carry Python
/// f-strings (`{value}`, single braces), JSON (`{"key": "value"}`, single braces), and
/// real Jinja (`{{ user.name }}` — the spaces and the dot are not valid slot-name
/// characters, so this stays literal) without any of it being mistaken for a slot.
/// The one case this format cannot tell apart from a real slot is a literal `{{word}}`
/// with no spaces and a name-shaped word inside — the packet spec for this format is
/// explicit that there is no escape for that, so it is read as a slot.
enum PromptSlotParser {
    enum Span: Equatable {
        case literal(String)
        case slot(String)
    }

    /// A single left-to-right scan recognizing `{{name}}` occurrences. Both `slots(in:)`
    /// and `render` are built on this so they can never disagree about what counts as
    /// a slot.
    static func scan(_ body: String) -> [Span] {
        var spans: [Span] = []
        var literalStart = body.startIndex
        var i = body.startIndex

        func flushLiteral(upTo end: String.Index) {
            if literalStart < end {
                spans.append(.literal(String(body[literalStart..<end])))
            }
        }

        while i < body.endIndex {
            guard body[i] == "{" else {
                i = body.index(after: i)
                continue
            }
            let afterFirst = body.index(after: i)
            guard afterFirst < body.endIndex, body[afterFirst] == "{" else {
                i = body.index(after: i)
                continue
            }
            let nameStart = body.index(after: afterFirst)
            var j = nameStart
            while j < body.endIndex, isSlotNameCharacter(body[j]) {
                j = body.index(after: j)
            }
            // Require at least one name character and a `}}` immediately after it.
            // Anything short of that — including a lone `{{` with nothing that scans
            // as a name — falls through and is retried starting one character later,
            // so a malformed opener never swallows text that should stay literal.
            guard j > nameStart, j < body.endIndex, body[j] == "}" else {
                i = body.index(after: i)
                continue
            }
            let afterCloseFirst = body.index(after: j)
            guard afterCloseFirst < body.endIndex, body[afterCloseFirst] == "}" else {
                i = body.index(after: i)
                continue
            }

            flushLiteral(upTo: i)
            spans.append(.slot(String(body[nameStart..<j])))
            let afterCloseSecond = body.index(after: afterCloseFirst)
            i = afterCloseSecond
            literalStart = i
        }
        flushLiteral(upTo: body.endIndex)
        return spans
    }

    private static func isSlotNameCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
    }

    /// Ordered, de-duplicated slot names — the order a composer should ask for values
    /// in. A repeated name is one shared value, so it appears once here no matter how
    /// many times it occurs in the body.
    static func slots(in body: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for span in scan(body) {
            if case .slot(let name) = span, seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }

    /// Substitutes every occurrence of a recognized slot with its value. A slot with no
    /// supplied value is left exactly as written (`{{name}}`) rather than blanked —
    /// silently deleting part of a prompt the caller hasn't filled in yet would lose
    /// more than it's worth.
    static func render(_ body: String, values: [String: String]) -> String {
        scan(body).map { span in
            switch span {
            case .literal(let text): return text
            case .slot(let name): return values[name] ?? "{{\(name)}}"
            }
        }.joined()
    }
}

// MARK: - PromptStore

/// Reads and writes `~/.aliasbar/prompts/<name>.md` — a concrete-path API like
/// `ZshrcParser`, so nothing here reaches into the app's own stored settings or any
/// other app default.
///
/// This file format is public, human-edited API. Someone can write one by hand: a
/// frontmatter block if they want one, a body that's plain prose, a JSON blob, a Python
/// f-string, a Jinja template. `write` must reproduce whatever `read` handed back,
/// unchanged, for every part the caller didn't touch — that property is tested harder
/// than anything else in this file.
enum PromptStore {

    // MARK: Errors

    enum ReadError: LocalizedError {
        case unreadable(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let path, let reason):
                return "Couldn't read \((path as NSString).abbreviatingWithTildeInPath): \(reason)"
            }
        }
    }

    enum WriteError: LocalizedError {
        case invalidName(String)
        case caseCollision(requested: String, existing: String)
        case backupFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                return "\"\(name)\" isn't a usable prompt name. Use letters, digits, - and _ with no spaces."
            case .caseCollision(let requested, let existing):
                return "A prompt named \"\(existing)\" already exists. \"\(requested)\" can't be saved alongside it — names can't differ only by case."
            case .backupFailed(let why):
                return "Couldn't write a backup, so nothing was changed: \(why)"
            case .writeFailed(let why):
                return "Couldn't save the prompt: \(why)"
            }
        }
    }

    enum ScanOutcome {
        case ok(prompts: [Prompt])
        case unreadable(path: String, reason: String)

        var prompts: [Prompt] {
            if case .ok(let prompts) = self { return prompts }
            return []
        }

        var errorMessage: String? {
            if case .unreadable(let path, let reason) = self {
                return "Couldn't read \((path as NSString).abbreviatingWithTildeInPath): \(reason)"
            }
            return nil
        }
    }

    // MARK: Name validation

    /// `name = [a-z0-9-_]+`, case-insensitive — the filename stem, before `.md`.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    // MARK: Scanning a directory

    /// Every `.md` file directly inside `directory`, parsed. `.backups` (a directory,
    /// not a `.md` file) is excluded by the extension filter alone — no special-casing
    /// needed.
    ///
    /// A directory that doesn't exist yet reads as `.ok(prompts: [])`, not
    /// `.unreadable`: unlike an rc file, nobody has a `~/.aliasbar/prompts` directory
    /// before AliasBar creates one on the first prompt saved, so a missing directory is
    /// the ordinary state of a fresh install, not a problem to surface. `.unreadable` is
    /// reserved for a real anomaly: the path exists but isn't a directory, or it exists
    /// but can't be listed (permissions).
    ///
    /// A single file inside the directory that fails to parse is skipped rather than
    /// failing the whole scan — one bad file should not hide every other valid prompt.
    static func scan(directory: URL) -> ScanOutcome {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return .ok(prompts: [])
        }
        guard isDirectory.boolValue else {
            return .unreadable(path: directory.path, reason: "not a directory")
        }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            let reason = (error as NSError).localizedFailureReason
                ?? (error as NSError).localizedDescription
            return .unreadable(path: directory.path, reason: reason)
        }

        let prompts = contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> Prompt? in
                if case .success(let prompt) = read(url: url) { return prompt }
                return nil
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return .ok(prompts: prompts)
    }

    // MARK: Reading one file

    static func read(url: URL) -> Result<Prompt, ReadError> {
        let name = url.deletingPathExtension().lastPathComponent
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Retry as Latin-1, matching ZshrcParser: one stray non-UTF-8 byte should
            // not make an otherwise-fine prompt file unreadable.
            if let data = fileManager.contents(atPath: url.path),
               let salvaged = String(data: data, encoding: .isoLatin1) {
                return .success(parse(salvaged, name: name))
            }
            let reason = (error as NSError).localizedFailureReason
                ?? (error as NSError).localizedDescription
            return .failure(.unreadable(path: url.path, reason: reason))
        }
        return .success(parse(text, name: name))
    }

    private static let fileManager = FileManager.default

    // MARK: Writing

    /// Writes `prompt` to `<directory>/<prompt.name>.md`, atomically, backing up
    /// whatever was there before under `<directory>/.backups/<name>-<timestamp>.md`.
    /// Returns the backup's path, or nil when there was nothing to back up (a brand new
    /// prompt).
    ///
    /// Refuses a name that would collide with an existing file differing only by case
    /// (`Foo.md` vs `foo.md`) — the filesystem this ships on is typically
    /// case-insensitive, so that pair would silently clobber one another.
    @discardableResult
    static func write(prompt: Prompt, to directory: URL) throws -> String? {
        guard isValidName(prompt.name) else {
            throw WriteError.invalidName(prompt.name)
        }

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if let existing = try? fileManager.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil) {
            for url in existing where url.pathExtension.lowercased() == "md" {
                let stem = url.deletingPathExtension().lastPathComponent
                if stem.lowercased() == prompt.name.lowercased(), stem != prompt.name {
                    throw WriteError.caseCollision(requested: prompt.name, existing: stem)
                }
            }
        }

        let targetURL = directory.appendingPathComponent("\(prompt.name).md")
        let newContent = serialize(prompt)

        var backupPath: String?
        if let priorContent = try? String(contentsOf: targetURL, encoding: .utf8) {
            backupPath = try writeBackup(of: priorContent, name: prompt.name, in: directory)
        }

        try atomicWrite(newContent, to: targetURL)
        return backupPath
    }

    // MARK: Deletion

    /// Removes `<directory>/<name>.md`, after backing it up exactly the way `write`
    /// backs up whatever it replaces. Returns the backup path, or nil when there was
    /// nothing at that name to delete.
    ///
    /// This is the only way a prompt file is ever removed from a directory `PromptStore`
    /// manages — in particular, `PromptInbox`'s merge-approval flow (PRE-265) routes a
    /// merge's losing names through here rather than `FileManager.removeItem` directly,
    /// so a deletion driven by untrusted inbox content always leaves a recoverable copy
    /// behind, the same guarantee every other write in this file carries.
    @discardableResult
    static func delete(name: String, from directory: URL) throws -> String? {
        let targetURL = directory.appendingPathComponent("\(name).md")
        guard let priorContent = try? String(contentsOf: targetURL, encoding: .utf8) else {
            return nil
        }
        let backupPath = try writeBackup(of: priorContent, name: name, in: directory)
        do {
            try fileManager.removeItem(at: targetURL)
        } catch {
            throw WriteError.writeFailed(error.localizedDescription)
        }
        return backupPath
    }

    // MARK: Frontmatter parsing / serialization

    /// Splits `content` into frontmatter (if any) and body.
    ///
    /// A frontmatter block is recognized only when: the first line is exactly `---`,
    /// a later line is also exactly `---`, and somewhere between them there is a
    /// `schema: 1` line. Any file that doesn't meet all three is treated as having no
    /// frontmatter at all — its full content becomes the body, verbatim. This protects
    /// a hand-written prompt that happens to open with a Markdown horizontal rule
    /// (`---`) as prose: without a valid `schema: 1` inside it, it is never mistaken
    /// for metadata.
    private static func parse(_ content: String, name: String) -> Prompt {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---", lines.count > 1 else {
            return Prompt(name: name, frontmatter: nil, body: content)
        }

        var closeIndex: Int?
        for idx in 1..<lines.count where lines[idx] == "---" {
            closeIndex = idx
            break
        }
        guard let closeIdx = closeIndex else {
            return Prompt(name: name, frontmatter: nil, body: content)
        }

        var entries: [PromptFrontmatter.Entry] = []
        for line in lines[1..<closeIdx] {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                entries.append(PromptFrontmatter.Entry(key: key, raw: value))
            } else {
                entries.append(PromptFrontmatter.Entry(key: nil, raw: line))
            }
        }

        let hasValidSchema = entries.contains {
            $0.key == "schema" && $0.raw.trimmingCharacters(in: .whitespaces) == "1"
        }
        guard hasValidSchema else {
            return Prompt(name: name, frontmatter: nil, body: content)
        }

        let bodyLines = lines[(closeIdx + 1)...]
        let body = bodyLines.joined(separator: "\n")
        return Prompt(name: name, frontmatter: PromptFrontmatter(entries: entries), body: body)
    }

    /// The inverse of `parse`. When `prompt.frontmatter` is nil this is just
    /// `prompt.body`, unchanged — the important case, since most hand-written prompts
    /// have no frontmatter at all.
    ///
    /// One known, deliberate gap: a file with frontmatter and a genuinely empty body
    /// can round-trip with one trailing newline added if it didn't already have one —
    /// splitting `content` by `"\n"` cannot tell "closing `---` with nothing after it"
    /// apart from "closing `---` followed by exactly one newline and nothing else" once
    /// both have collapsed to an empty body string. Every body with actual content,
    /// which is the case this format exists for, round-trips exactly.
    private static func serialize(_ prompt: Prompt) -> String {
        guard let frontmatter = prompt.frontmatter else { return prompt.body }
        var lines: [String] = ["---"]
        for entry in frontmatter.entries {
            if let key = entry.key {
                lines.append("\(key):\(entry.raw)")
            } else {
                lines.append(entry.raw)
            }
        }
        lines.append("---")
        lines.append(contentsOf: prompt.body.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }

    // MARK: Backup

    /// Timestamped backup beside the original, under `.backups`. The timestamp carries
    /// microseconds, and a numeric suffix is appended on top of that if two backups
    /// still land on the same name — belt and suspenders against two writes in a tight
    /// loop landing in the same tick.
    private static func writeBackup(of contents: String, name: String, in directory: URL) throws -> String {
        let backupsDir = directory.appendingPathComponent(".backups")
        try? fileManager.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let stamp = subsecondTimestamp(Date())
        var candidate = backupsDir.appendingPathComponent("\(name)-\(stamp).md")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = backupsDir.appendingPathComponent("\(name)-\(stamp)-\(suffix).md")
            suffix += 1
        }

        do {
            try contents.write(to: candidate, atomically: true, encoding: .utf8)
        } catch {
            throw WriteError.backupFailed(error.localizedDescription)
        }
        return candidate.path
    }

    private static func subsecondTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let base = formatter.string(from: date)
        let interval = date.timeIntervalSince1970
        let microseconds = Int(((interval - interval.rounded(.down)) * 1_000_000).rounded())
        return "\(base)-\(String(format: "%06d", microseconds))"
    }

    // MARK: Atomic write

    /// Temp file in the same directory, then `rename` — the same shape as
    /// `AliasWriter`'s atomic write, without its multi-editor collision detection.
    /// `.zshrc` is routinely open in an editor and a dotfile syncer at the same time;
    /// a prompt file is not expected to be under that kind of concurrent pressure, so
    /// the added complexity isn't earning its keep here. What this still guarantees:
    /// the file is never observed half-written.
    private static func atomicWrite(_ text: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".aliasbar-prompt-write-\(UUID().uuidString)")
        do {
            try text.write(to: tempURL, atomically: false, encoding: .utf8)
        } catch {
            throw WriteError.writeFailed(error.localizedDescription)
        }
        if rename(tempURL.path, url.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fileManager.removeItem(at: tempURL)
            throw WriteError.writeFailed(reason)
        }
    }
}

// MARK: - PromptUsageCounter

/// Local, per-machine record of how often each prompt has been invoked, stored at
/// `~/.aliasbar/usage.json`. Deliberately not part of the prompt file itself: prompt
/// files are meant to be committed to a dotfiles repo and shared, and a use count that
/// changes every time the prompt runs would dirty that file on every invocation, the
/// same reason `~/.zsh_history` lives outside the rc file it's related to.
///
/// Concrete-path API, like `ZshrcParser` and `PromptStore`. Tolerant by design: a
/// missing or corrupt usage file reads as empty rather than failing, because a usage
/// count is a convenience, never something worth losing prompts over.
enum PromptUsageCounter {
    struct Entry: Codable, Equatable {
        var count: Int
        var lastUsed: Date
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Every recorded prompt's usage. A missing or corrupt file reads as empty.
    static func all(path: String) -> [String: Entry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    /// Records one invocation of `name`, bumping its count and stamping `now` as its
    /// most recent use. Never throws: a failed write here should not interrupt
    /// whatever the prompt was just used for.
    @discardableResult
    static func recordUse(of name: String, path: String, now: Date = Date()) -> Entry {
        var entries = all(path: path)
        var entry = entries[name] ?? Entry(count: 0, lastUsed: now)
        entry.count += 1
        entry.lastUsed = now
        entries[name] = entry
        write(entries, path: path)
        return entry
    }

    private static func write(_ entries: [String: Entry], path: String) {
        guard let data = try? encoder.encode(entries) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let tempPath = directory + "/.aliasbar-usage-\(UUID().uuidString)"
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
