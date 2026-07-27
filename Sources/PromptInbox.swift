import Foundation

/// `~/.aliasbar/inbox/*.json` — proposals produced by `AuditPrompt` (or written by hand)
/// for a human to accept or reject one item at a time before anything reaches the real
/// prompt library.
///
/// Every file in this directory is untrusted mail. It may have been written by an AI
/// that hallucinated, or copied in from a stranger's web page. Nothing in this file
/// trusts a byte of it: parsing never crashes on a malformed file, and there is no path
/// from "a file exists in the inbox" to "something lands in the library" that doesn't
/// pass through an explicit call naming one specific item. There is no batch-approve
/// and no auto-compile — that is a structural property of this API's shape, not a
/// policy a caller has to remember to honor.
enum PromptInbox {

    // MARK: - Item

    enum ItemType: String, Equatable {
        case new, update, merge
    }

    /// A flag is advisory: it never blocks approval by itself, but `approve` refuses a
    /// flagged item unless the caller passes `acknowledgedFlags: true`. (The UI slice
    /// that calls this is expected to only pass that once the item has actually been
    /// viewed in full — the UI requires an explicit read-in-full control for flagged
    /// items; this API can only enforce the "was it ever passed at all" part.)
    struct Flag: Equatable {
        enum Reason: String, Equatable {
            case shellCommandShape = "shell-command-shape"
            case containsURL = "contains-url"
            case sensitiveContent = "sensitive-content"
        }
        let reason: Reason
        /// One line of human-readable specifics. For `.sensitiveContent` this is the
        /// classifier's own reason description; for the others it's a fixed string, so
        /// a caller always has something to show without special-casing which flags
        /// carry extra detail.
        let detail: String
    }

    /// One proposal, already validated against the schema and flagged, but not yet
    /// decided. Nothing on `Item` implies it's safe — `flags` is exactly the advisory
    /// signal a reviewer needs, and `approve` still requires unflagged items to be
    /// looked at like any other before being written.
    struct Item: Equatable {
        /// Where this item's inbox file currently lives. Informational only — this API
        /// never locates or mutates an item inside its file; a file only ever leaves
        /// the live inbox as a whole, via `markDone`/`discardFile`.
        let sourceFile: URL
        let type: ItemType
        let name: String
        let description: String?
        let body: String
        /// Set only for `type == .update`: the name of the existing prompt this
        /// proposes to replace.
        let replaces: String?
        /// Set only for `type == .merge`: the existing prompt names being folded into
        /// this item (whose `name` is the survivor).
        let merges: [String]
        /// Field names present in this item's raw JSON that aren't part of the schema.
        /// Tolerated, never a reason to reject the file, but reported so a reviewer (or
        /// a log) can see that something unrecognized rode along.
        let unknownFields: [String]
        let flags: [Flag]

        var isFlagged: Bool { !flags.isEmpty }
    }

    // MARK: - Scanning

    enum FileOutcome: Equatable {
        case ok(url: URL, items: [Item], unknownTopLevelFields: [String])
        case invalid(url: URL, reason: String)
    }

    enum ScanOutcome {
        case ok([FileOutcome])
        case unreadable(path: String, reason: String)

        var files: [FileOutcome] {
            if case .ok(let files) = self { return files }
            return []
        }
    }

    /// Every `.json` file directly inside `inboxDirectory` (never `.done`, which is a
    /// directory and so is excluded by the extension filter alone, the same way
    /// `PromptStore.scan` excludes `.backups`).
    ///
    /// A missing directory reads as `.ok([])`, not `.unreadable` — nobody has
    /// `~/.aliasbar/inbox` before the first audit prompt is ever run, so a missing
    /// directory is the ordinary state of a fresh install, not an anomaly.
    static func scan(inboxDirectory: URL) -> ScanOutcome {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: inboxDirectory.path, isDirectory: &isDirectory) else {
            return .ok([])
        }
        guard isDirectory.boolValue else {
            return .unreadable(path: inboxDirectory.path, reason: "not a directory")
        }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: inboxDirectory, includingPropertiesForKeys: nil)
        } catch {
            let reason = (error as NSError).localizedFailureReason
                ?? (error as NSError).localizedDescription
            return .unreadable(path: inboxDirectory.path, reason: reason)
        }

        let files = contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { parseFile(at: $0) }
        return .ok(files)
    }

    /// Every field name a top-level inbox object is allowed to have. Anything else is
    /// tolerated and reported, the same as an unrecognized item field.
    private static let knownItemKeys: Set<String> = [
        "type", "name", "description", "body", "replaces", "merges",
    ]

    static func parseFile(at url: URL) -> FileOutcome {
        guard let data = try? Data(contentsOf: url) else {
            return .invalid(url: url, reason: "couldn't read the file")
        }
        return parse(data: data, url: url)
    }

    private static func parse(data: Data, url: URL) -> FileOutcome {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .invalid(url: url, reason: "not valid JSON")
        }
        guard let top = raw as? [String: Any] else {
            return .invalid(url: url, reason: "top-level JSON value must be an object")
        }
        guard let itemsRaw = top["items"] else {
            return .invalid(url: url, reason: "missing an \"items\" array")
        }
        guard let itemsArray = itemsRaw as? [Any] else {
            return .invalid(url: url, reason: "\"items\" must be an array")
        }

        var items: [Item] = []
        for (index, rawItem) in itemsArray.enumerated() {
            guard let dict = rawItem as? [String: Any] else {
                return .invalid(url: url, reason: "item \(index) is not an object")
            }
            switch parseItem(dict, sourceFile: url) {
            case .success(let item):
                items.append(item)
            case .failure(let error):
                return .invalid(url: url, reason: "item \(index): \(error.reason)")
            }
        }

        let unknownTopLevel = top.keys.filter { $0 != "items" }.sorted()
        return .ok(url: url, items: items, unknownTopLevelFields: unknownTopLevel)
    }

    /// A bare `String` isn't `Error`-conforming, so `Result<Item, ItemShapeError>`
    /// needs this trivial wrapper purely to carry the rejection reason.
    private struct ItemShapeError: Error {
        let reason: String
    }

    private static func parseItem(_ dict: [String: Any], sourceFile: URL) -> Result<Item, ItemShapeError> {
        guard let typeRaw = dict["type"] as? String, let type = ItemType(rawValue: typeRaw) else {
            return .failure(ItemShapeError(reason: "\"type\" must be one of \"new\", \"update\", \"merge\""))
        }
        guard let name = dict["name"] as? String, PromptStore.isValidName(name) else {
            return .failure(ItemShapeError(reason: "\"name\" must be a valid prompt name (letters, digits, - and _)"))
        }
        guard let body = dict["body"] as? String else {
            return .failure(ItemShapeError(reason: "\"body\" must be a string"))
        }

        var description: String?
        if let raw = dict["description"], !(raw is NSNull) {
            guard let str = raw as? String else {
                return .failure(ItemShapeError(reason: "\"description\" must be a string"))
            }
            description = str
        }

        var replaces: String?
        if type == .update {
            guard let raw = dict["replaces"] as? String, PromptStore.isValidName(raw) else {
                return .failure(ItemShapeError(reason: "type \"update\" requires a \"replaces\" name"))
            }
            replaces = raw
        } else if let raw = dict["replaces"], !(raw is NSNull) {
            replaces = raw as? String
        }

        var merges: [String] = []
        if type == .merge {
            guard let raw = dict["merges"] as? [Any], !raw.isEmpty else {
                return .failure(ItemShapeError(reason: "type \"merge\" requires a non-empty \"merges\" array"))
            }
            let names = raw.compactMap { $0 as? String }
            guard names.count == raw.count, names.allSatisfy(PromptStore.isValidName) else {
                return .failure(ItemShapeError(reason: "\"merges\" must be an array of valid prompt names"))
            }
            merges = names
        } else if let raw = dict["merges"] as? [Any] {
            merges = raw.compactMap { $0 as? String }
        }

        let unknown = dict.keys.filter { !knownItemKeys.contains($0) }.sorted()
        let flags = InboxFlagging.flags(name: name, description: description, body: body)
        return .success(Item(sourceFile: sourceFile, type: type, name: name, description: description,
                             body: body, replaces: replaces, merges: merges,
                             unknownFields: unknown, flags: flags))
    }

    // MARK: - Decisions

    enum ApproveError: LocalizedError {
        case flaggedRequiresAcknowledgement(name: String)
        case nameCollision(name: String)
        case updateTargetMissing(name: String)
        case mergeSourceMissing(name: String)
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .flaggedRequiresAcknowledgement(let name):
                return "\"\(name)\" was flagged for review and needs acknowledgedFlags: true before it can be approved."
            case .nameCollision(let name):
                return "A prompt named \"\(name)\" already exists. Submit this as an update."
            case .updateTargetMissing(let name):
                return "No existing prompt matches \"\(name)\". Choose a prompt to update."
            case .mergeSourceMissing(let name):
                return "No existing prompt matches \"\(name)\". Choose a prompt to merge."
            case .underlying(let message):
                return message
            }
        }
    }

    struct ApproveResult: Equatable {
        let name: String
        /// Set when writing this prompt replaced an existing file's content — the path
        /// of the backup `PromptStore` took of what was there immediately before.
        let replacedBackup: String?
        /// For a merge: every merged-away name actually removed, paired with the
        /// backup `PromptStore` made of it before removing it. Empty for `.new`/`.update`.
        let removedMerges: [(name: String, backup: String)]

        static func == (lhs: ApproveResult, rhs: ApproveResult) -> Bool {
            lhs.name == rhs.name && lhs.replacedBackup == rhs.replacedBackup
                && lhs.removedMerges.elementsEqual(rhs.removedMerges) { $0.name == $1.name && $0.backup == $1.backup }
        }
    }

    /// Writes `item` into the real prompt library, or throws without writing anything.
    ///
    /// This is the only path from an inbox item to the library — there is no separate
    /// "compile everything" or "approve all" entry point. A flagged item is refused
    /// outright unless `acknowledgedFlags` is `true`; the caller (the UI slice) is
    /// responsible for only ever passing that once a human has actually viewed the item
    /// in full, which isn't something this API can verify on its own.
    ///
    /// - `new` refuses a name that already exists in `existingLibrary` — a genuinely
    ///   new prompt colliding with one already there almost always means the audit
    ///   should have proposed an update instead, so this never silently overwrites.
    /// - `update` requires `replaces` to name a prompt that's actually in
    ///   `existingLibrary`; the write itself goes through `PromptStore.write`, whose own
    ///   backup keeps the prior body recoverable.
    /// - `merge` requires every name in `merges` (other than the survivor's own name,
    ///   if it happens to be one of them) to exist in `existingLibrary`, writes the
    ///   survivor, then removes each merged-away name through `PromptStore.delete` —
    ///   never a raw filesystem removal — so every loss is backed up.
    ///
    /// Approving never touches `~/.claude/commands`: delivering an approved prompt to
    /// Claude Code is a separate, explicit `PromptCompiler` call the UI slice makes on
    /// its own, not a side effect of this function.
    @discardableResult
    static func approve(_ item: Item,
                        existingLibrary: [Prompt],
                        promptsDirectory: URL,
                        acknowledgedFlags: Bool = false,
                        now: Date = Date()) throws -> ApproveResult {
        guard acknowledgedFlags || !item.isFlagged else {
            throw ApproveError.flaggedRequiresAcknowledgement(name: item.name)
        }

        func exists(_ name: String) -> Bool {
            existingLibrary.contains { $0.name.lowercased() == name.lowercased() }
        }

        switch item.type {
        case .new:
            guard !exists(item.name) else {
                throw ApproveError.nameCollision(name: item.name)
            }
            return try writeApprovedPrompt(item, to: promptsDirectory, now: now)

        case .update:
            guard let replaces = item.replaces, exists(replaces) else {
                throw ApproveError.updateTargetMissing(name: item.replaces ?? item.name)
            }
            return try writeApprovedPrompt(item, to: promptsDirectory, now: now)

        case .merge:
            let sources = item.merges.filter { $0.lowercased() != item.name.lowercased() }
            for source in sources where !exists(source) {
                throw ApproveError.mergeSourceMissing(name: source)
            }

            let survivor = try writeApprovedPrompt(item, to: promptsDirectory, now: now)

            var removed: [(name: String, backup: String)] = []
            for source in sources {
                do {
                    if let backup = try PromptStore.delete(name: source, from: promptsDirectory) {
                        removed.append((name: source, backup: backup))
                    }
                } catch {
                    // The survivor is already written and safe; a merge-source removal
                    // failing partway through is surfaced rather than silently dropped,
                    // but it never rolls back or re-throws in a way that could suggest
                    // the survivor's write itself failed.
                    throw ApproveError.underlying(
                        "Wrote \"\(item.name)\" but couldn't remove merged-away \"\(source)\": \(error.localizedDescription)")
                }
            }
            return ApproveResult(name: survivor.name, replacedBackup: survivor.replacedBackup, removedMerges: removed)
        }
    }

    private static func writeApprovedPrompt(_ item: Item, to directory: URL, now: Date) throws -> ApproveResult {
        var frontmatter = PromptFrontmatter.empty()
        if let description = item.description, !description.isEmpty {
            frontmatter = frontmatter.setting("description", to: description)
        }
        frontmatter = frontmatter.setting("edited", to: iso8601.string(from: now))

        let prompt = Prompt(name: item.name, frontmatter: frontmatter, body: item.body)
        do {
            let backup = try PromptStore.write(prompt: prompt, to: directory)
            return ApproveResult(name: item.name, replacedBackup: backup, removedMerges: [])
        } catch {
            throw ApproveError.underlying(error.localizedDescription)
        }
    }

    private static let iso8601 = ISO8601DateFormatter()

    /// Symmetric with `approve` at the single-item level, for API parity and any future
    /// audit logging: there is nothing on disk to undo for an item that was never
    /// written anywhere, so this is intentionally a no-op. Removing the item's *file*
    /// from the live inbox — once every item in it has a decision, approved or
    /// discarded — is `markDone`/`discardFile`, a separate, explicit step a caller
    /// takes once it's actually done with the file.
    static func discard(_ item: Item) {}

    // MARK: - Inbox file lifecycle

    enum LifecycleError: LocalizedError {
        case moveFailed(String)

        var errorDescription: String? {
            switch self {
            case .moveFailed(let reason):
                return "Couldn't move the inbox file: \(reason)"
            }
        }
    }

    /// Moves `url` — a file directly inside the live inbox — to
    /// `<inboxDirectory>/.done/<timestamp>-<original-filename>`, so a later `scan` of
    /// the live inbox never sees it again while the original content stays recoverable
    /// for anyone who wants to look back at what was submitted and decided.
    ///
    /// This is the only way a file ever leaves the live inbox — whether every item in
    /// it ended up approved, discarded, or a human rejected the whole file without
    /// looking at it item by item. There is no separate delete path.
    @discardableResult
    static func markDone(_ url: URL) throws -> URL {
        let inboxDirectory = url.deletingLastPathComponent()
        let doneDirectory = inboxDirectory.appendingPathComponent(".done")
        try FileManager.default.createDirectory(at: doneDirectory, withIntermediateDirectories: true)

        let stamp = subsecondTimestamp(Date())
        var destination = doneDirectory.appendingPathComponent("\(stamp)-\(url.lastPathComponent)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = doneDirectory.appendingPathComponent("\(stamp)-\(suffix)-\(url.lastPathComponent)")
            suffix += 1
        }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw LifecycleError.moveFailed(error.localizedDescription)
        }
        return destination
    }

    /// Discards an entire inbox file without approving anything in it — used when a
    /// human decides the whole thing isn't worth reviewing item by item. Equivalent to
    /// `markDone`; kept as a distinctly named entry point because the two call sites
    /// mean different things ("I finished reviewing this" vs. "I'm not reviewing this
    /// at all"), even though the mechanics are identical.
    @discardableResult
    static func discardFile(at url: URL) throws -> URL {
        try markDone(url)
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
}

// MARK: - Flag detection

/// Pure, advisory content flagging for inbox items. Kept as a private helper rather
/// than folded into `parseItem` so the detection rules read as one place, separate from
/// schema validation.
private enum InboxFlagging {
    static func flags(name: String, description: String?, body: String) -> [PromptInbox.Flag] {
        let haystack = [name, description ?? "", body].joined(separator: "\n")
        var flags: [PromptInbox.Flag] = []

        if containsShellCommandShape(haystack) {
            flags.append(PromptInbox.Flag(reason: .shellCommandShape,
                                          detail: "Looks like it contains a shell command"))
        }
        if containsURL(haystack) {
            flags.append(PromptInbox.Flag(reason: .containsURL, detail: "Contains a URL"))
        }
        if let reason = SensitiveContentClassifier.quarantineReason(in: haystack) {
            flags.append(PromptInbox.Flag(reason: .sensitiveContent, detail: reason.description))
        }
        return flags
    }

    // Backticks and `$(` are checked directly rather than by regex — they're fixed
    // substrings, not patterns, so there's nothing a regex buys here.
    private static func containsShellCommandShape(_ text: String) -> Bool {
        if text.contains("`") || text.contains("$(") {
            return true
        }
        let range = NSRange(text.startIndex..., in: text)
        if sudoPattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        if curlPipePattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        return false
    }

    private static let sudoPattern = try! NSRegularExpression(pattern: "\\bsudo\\b")

    // `curl ... | bash` and its near-variants (wget, sh/zsh, an intervening `sudo`) —
    // the classic "pipe a downloaded script straight into a shell" shape.
    private static let curlPipePattern = try! NSRegularExpression(
        pattern: "\\b(curl|wget)\\b[^\\n|]*\\|\\s*(sudo\\s+)?(sh|bash|zsh)\\b",
        options: [.caseInsensitive]
    )

    private static func containsURL(_ text: String) -> Bool {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text.range(of: "https?://", options: .regularExpression) != nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range) != nil
    }
}
