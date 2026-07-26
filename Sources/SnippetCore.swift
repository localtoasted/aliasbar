import Foundation

// MARK: - Snippet

/// A text-expansion shortcut: type `trigger`, get `template` (with any `{{holes}}`
/// filled in). The `;`-prefix convention some users like (`;sig`, `;addr`) is just a
/// habit this format happens to support — nothing here requires, assumes, or strips
/// a leading punctuation character.
struct Snippet: Codable, Equatable {
    let id: UUID
    var trigger: String
    var template: String
    var modifiedAt: Date

    init(id: UUID = UUID(), trigger: String, template: String, modifiedAt: Date = Date()) {
        self.id = id
        self.trigger = trigger
        self.template = template
        self.modifiedAt = modifiedAt
    }
}

extension Snippet: SharedRecordConvertible {}

// MARK: - Trigger validation

/// Rules a trigger must satisfy before a `Snippet` carrying it can be saved. Kept
/// separate from `Snippet` itself so a caller can validate a candidate trigger before
/// ever constructing one (e.g. as a user types it into a field).
enum SnippetTriggerValidation {
    enum TriggerError: LocalizedError, Equatable {
        case tooShort
        case tooLong
        case containsWhitespaceOrControl
        case duplicate(existing: String)

        var errorDescription: String? {
            switch self {
            case .tooShort:
                return "A trigger needs at least 2 characters."
            case .tooLong:
                return "A trigger can't be longer than 64 characters."
            case .containsWhitespaceOrControl:
                return "A trigger can't contain spaces, tabs, newlines, or control characters."
            case .duplicate(let existing):
                return "\"\(existing)\" is already a trigger — triggers can't differ only by case."
            }
        }
    }

    /// 2–64 characters (counted as user-perceived characters, so a multi-scalar emoji
    /// counts once, not per Unicode scalar), no whitespace or control characters
    /// anywhere in it, and — case-insensitively — not equal to any trigger already in
    /// `existing`. `excluding` lets a caller validate an edit to a snippet's own
    /// trigger without it colliding with itself.
    static func validate(_ trigger: String, against existing: [Snippet],
                         excluding excludedID: UUID? = nil) -> Result<Void, TriggerError> {
        guard trigger.count >= 2 else { return .failure(.tooShort) }
        guard trigger.count <= 64 else { return .failure(.tooLong) }
        guard !containsWhitespaceOrControl(trigger) else { return .failure(.containsWhitespaceOrControl) }

        let lowered = trigger.lowercased()
        if let collision = existing.first(where: { $0.id != excludedID && $0.trigger.lowercased() == lowered }) {
            return .failure(.duplicate(existing: collision.trigger))
        }
        return .success(())
    }

    private static func containsWhitespaceOrControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

// MARK: - Rendering

/// Fills in a snippet's `{{hole}}` template using the shared grammar `PromptSlotParser`
/// defines — the same parser prompt files use, reused rather than reimplemented, per
/// the format being deliberately file-format-agnostic (a "hole" and a "slot" are the
/// same concept wearing two names for two different features).
enum SnippetRenderer {
    /// Ordered, de-duplicated hole names a composer should collect values for before
    /// rendering — a repeated hole name is one shared value, matching
    /// `PromptSlotParser.slots(in:)`.
    static func renderPlan(snippet: Snippet) -> [String] {
        PromptSlotParser.slots(in: snippet.template)
    }

    /// Substitutes every recognized hole with its supplied value. A hole with no
    /// supplied value is left exactly as written (`{{name}}`), matching
    /// `PromptSlotParser.render`'s "never silently blank an unfilled hole" rule.
    static func render(snippet: Snippet, values: [String: String]) -> String {
        PromptSlotParser.render(snippet.template, values: values)
    }
}

// MARK: - TriggerMatcher

/// Detects when the most recently typed characters end in a registered trigger.
///
/// Pure and stateless beyond its own rolling buffer — no event tap, no AppKit, no
/// notion of a text field or a cursor. The next slice feeds it characters as they
/// arrive from a global key event stream and acts on what it returns; this type only
/// ever sees a `Character` at a time and reports back whether a trigger just completed.
final class TriggerMatcher {
    /// One completed match: which snippet fired, and how many trailing characters of
    /// the buffer its trigger consumed (so a caller can delete exactly that much
    /// typed text before inserting the expansion).
    struct Match: Equatable {
        let snippet: Snippet
        let triggerLength: Int
    }

    private var snippets: [Snippet]
    private var maxTriggerLength: Int
    private var buffer: [Character] = []

    init(snippets: [Snippet] = []) {
        self.snippets = snippets
        self.maxTriggerLength = Self.longestTriggerLength(in: snippets)
    }

    /// Swaps in a fresh snippet set (the store just changed) and re-bounds the buffer
    /// to the new longest trigger, trimming from the front if the bound shrank —
    /// characters older than any trigger could possibly need are simply forgotten,
    /// never treated as a reason to reset the whole match state.
    func updateSnippets(_ snippets: [Snippet]) {
        self.snippets = snippets
        maxTriggerLength = Self.longestTriggerLength(in: snippets)
        if buffer.count > maxTriggerLength {
            buffer.removeFirst(buffer.count - maxTriggerLength)
        }
    }

    /// Appends one typed character, then checks whether the buffer now ends in a
    /// registered trigger. When more than one trigger matches as a suffix (only
    /// possible when they're different lengths — validation forbids two triggers that
    /// are equal case-insensitively, so same-length triggers can never both match the
    /// same suffix), the longest one wins: a caller who registered both `;s` and
    /// `;sig` and just typed `;sig` should expand the more specific one.
    ///
    /// On a match, the buffer is cleared. The characters it just matched are about to
    /// be deleted from the real text field by the caller (replaced with the
    /// expansion), so keeping them around would have this matcher believe on-screen
    /// text is still there that no longer is.
    @discardableResult
    func feed(_ character: Character) -> Match? {
        guard maxTriggerLength > 0 else { return nil }
        buffer.append(character)
        if buffer.count > maxTriggerLength {
            buffer.removeFirst(buffer.count - maxTriggerLength)
        }

        var best: Match?
        for snippet in snippets {
            let triggerChars = Array(snippet.trigger)
            guard triggerChars.count <= buffer.count else { continue }
            guard buffer.suffix(triggerChars.count).elementsEqual(triggerChars) else { continue }
            if best == nil || triggerChars.count > best!.triggerLength {
                best = Match(snippet: snippet, triggerLength: triggerChars.count)
            }
        }

        if let best {
            buffer.removeAll()
            return best
        }
        return nil
    }

    /// Discards everything typed so far without treating it as a match. Callers reset
    /// on focus change (typing resumed in a different field means the buffer no
    /// longer describes what's on screen), on control keys (arrows, delete, etc. —
    /// anything that isn't a plain character insertion breaks the run), and on a
    /// typing timeout.
    func reset() {
        buffer.removeAll()
    }

    private static func longestTriggerLength(in snippets: [Snippet]) -> Int {
        snippets.map(\.trigger.count).max() ?? 0
    }
}

// MARK: - SnippetStore

/// Reads and writes the local, always-present snippet file at a concrete path
/// (normally `~/.aliasbar/snippets.json`) — the source of truth for this machine's
/// snippets, the same role `~/.zshrc` plays for aliases.
///
/// When constructed with a `SharedDocumentStore`, every local write is *also* mirrored
/// into that document's `"snippets"` collection — an upsert on save, a tombstone on
/// delete — following the same dual-write shape `SettingsSyncCoordinator` uses to keep
/// saved presets in the shared document. The mirror is one-directional in this slice:
/// this store is never the thing that reads a shared document's snippets back down
/// onto the local file. Reconciling a change made from another machine is sync-wiring
/// work for whichever later slice actually starts a `SharedDocumentWatcher` for
/// snippets (mirroring how `ClipboardMonitor` shipped its own slice before anything
/// wired it into the running app) — this slice only guarantees the mirror never falls
/// behind what's saved locally.
final class SnippetStore {
    enum RecordCollection {
        static let snippets = "snippets"
    }

    private let localPath: String
    private let sharedStore: SharedDocumentStore?

    init(localPath: String, sharedStore: SharedDocumentStore? = nil) {
        self.localPath = localPath
        self.sharedStore = sharedStore
    }

    /// Every snippet on this machine. A missing or corrupt file reads as empty rather
    /// than failing — matching `PromptUsageCounter`'s tolerance for a file nobody has
    /// written to yet, or one damaged by something outside this app.
    func all() -> [Snippet] {
        Self.load(path: localPath)
    }

    /// Inserts a new snippet or replaces an existing one (matched by `id`), stamping
    /// `modifiedAt` with `now` regardless of whatever the caller's copy already had —
    /// the store, not the caller, owns when a save "happened." Mirrors the write into
    /// the shared document's snippets collection when one was supplied.
    @discardableResult
    func upsert(_ snippet: Snippet, now: Date = Date()) -> Snippet {
        var stored = Self.load(path: localPath)
        var saved = snippet
        saved.modifiedAt = now
        if let index = stored.firstIndex(where: { $0.id == saved.id }) {
            stored[index] = saved
        } else {
            stored.append(saved)
        }
        Self.save(stored, path: localPath)
        _ = try? sharedStore?.upsert(saved, id: saved.id.uuidString,
                                     in: RecordCollection.snippets, modifiedAt: now)
        return saved
    }

    /// Removes a snippet from the local file and, when a shared document is
    /// configured, writes a tombstone for it there too — the record itself is never
    /// deleted from the document (a delete would let a stale concurrent write on
    /// another machine silently resurrect it); it's marked gone instead, the same
    /// tombstone-not-removal rule `SharedDocumentStore` uses everywhere else.
    func delete(id: UUID, now: Date = Date()) {
        var stored = Self.load(path: localPath)
        stored.removeAll { $0.id == id }
        Self.save(stored, path: localPath)
        _ = try? sharedStore?.tombstone(id: id.uuidString, in: RecordCollection.snippets, modifiedAt: now)
    }

    // MARK: Persistence

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

    private static func load(path: String) -> [Snippet] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? decoder.decode([Snippet].self, from: data)) ?? []
    }

    /// Atomic temp-file-then-rename write, matching `PromptUsageCounter`'s pattern for
    /// its own local-only JSON file.
    private static func save(_ snippets: [Snippet], path: String) {
        guard let data = try? encoder.encode(snippets) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let tempPath = directory + "/.aliasbar-snippets-\(UUID().uuidString)"
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

// MARK: - Path resolution

/// Where the local snippet file lives, with an environment override for testability —
/// the same shape `CorePaths.resolvePromptsDirectory` uses for prompts. Kept
/// self-contained in this file rather than added to `AppPaths`/`Model.swift`: those
/// files belong to other in-flight slices, and this resolver has no dependency on
/// anything they define.
enum SnippetPaths {
    static func resolveLocalPath(environmentOverride: String?, homeDirectory: String) -> String {
        if let environmentOverride, !environmentOverride.isEmpty {
            return (environmentOverride as NSString).expandingTildeInPath
        }
        return homeDirectory + "/.aliasbar/snippets.json"
    }
}
