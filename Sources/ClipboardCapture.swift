import Foundation

// MARK: - Capture

/// What was actually read off the pasteboard, before any decision is made about it.
///
/// Never Codable: a captured clip may hold a secret, and the whole point of the ingest
/// gate below is that secret-shaped content is never given a serialization path.
struct CapturedClip {
    let content: String
    /// UTI-style pasteboard type identifiers as declared by the source app.
    let declaredTypes: [String]
    let byteSize: Int
    let capturedAt: Date
    /// True when `org.nspasteboard.ConcealedType` was present. Apps (1Password, Bitwarden,
    /// Terminal's secure paste, etc.) set this to say "this came from a password field" —
    /// it is a stronger signal than anything text-shape heuristics can infer.
    let concealed: Bool

    init(
        content: String,
        declaredTypes: [String],
        byteSize: Int? = nil,
        capturedAt: Date,
        concealed: Bool = false
    ) {
        self.content = content
        self.declaredTypes = declaredTypes
        self.byteSize = byteSize ?? content.utf8.count
        self.capturedAt = capturedAt
        self.concealed = concealed
    }
}

/// A clip cleared to live on disk. This is the only clip type in this file that is
/// Codable — persistence is the exception, not the default, for clipboard content.
struct SafeClip: Codable, Equatable, Identifiable {
    struct SourceMetadata: Codable, Equatable {
        let declaredTypes: [String]
        let byteSize: Int
    }

    let content: String
    let detectedAt: Date
    let source: SourceMetadata
    /// Stable per-capture identity. Doubles as `Identifiable`'s `id` for the
    /// clipboard source's list views, and as the key `ClipboardSyncMirror` upserts
    /// and tombstones records by. Defaulted so every existing call site —
    /// `ClipIngestor.decide`, every fixture in this test suite — keeps compiling
    /// unchanged, while every clip still gets its own fresh, genuinely unique id.
    ///
    /// `var`, not `let`: a `let` with an inline default value is a documented
    /// Codable-synthesis trap — the compiler-generated `init(from:)` would keep the
    /// fresh default forever and silently never decode the stored id back, since a
    /// `let` cannot be assigned a second time. `var` costs nothing here (nothing
    /// ever mutates it after capture) and is what makes the round trip real.
    var id: UUID = UUID()
}

/// A clip the classifier (or the concealed-type short-circuit) refused to persist.
/// Held in memory only, for exactly long enough that a user who copied the wrong thing
/// a moment ago can still see what happened — never written to disk, never Codable.
struct MemoryClip {
    let content: String
    let reason: SensitiveContentClassifier.QuarantineReason
    let expiresAt: Date
}

// MARK: - Ingest routing

enum ClipIngestDecision {
    case persist(SafeClip)
    case quarantine(MemoryClip)
}

/// The single gate between a pasteboard read and anything durable. Every routing
/// decision goes through `decide` — there is no other path to `SafeClip`.
enum ClipIngestor {
    /// Detection fails toward quarantine: a concealed pasteboard type is decided before
    /// the classifier ever sees the text, and a decision the classifier cannot make
    /// (`nil`) is the only way to reach `.persist`.
    static func decide(_ clip: CapturedClip, now: Date) -> ClipIngestDecision {
        if clip.concealed {
            return .quarantine(MemoryClip(
                content: clip.content,
                reason: .concealedPasteboardType,
                expiresAt: now.addingTimeInterval(QuarantineStore.expiryInterval)
            ))
        }

        if let reason = SensitiveContentClassifier.quarantineReason(in: clip.content) {
            return .quarantine(MemoryClip(
                content: clip.content,
                reason: reason,
                expiresAt: now.addingTimeInterval(QuarantineStore.expiryInterval)
            ))
        }

        return .persist(SafeClip(
            content: clip.content,
            detectedAt: now,
            source: SafeClip.SourceMetadata(
                declaredTypes: clip.declaredTypes,
                byteSize: clip.byteSize
            )
        ))
    }
}

// MARK: - Quarantine store

/// Scratch space for quarantined clips, nothing more: memory-only, no export, no search,
/// no Codable conformance anywhere near it. A plain class rather than an actor because
/// the app this backs is single-threaded on the main run loop; an actor here would just
/// add hop overhead for no isolation benefit. If AliasBar ever calls into this from a
/// background queue, that assumption needs revisiting.
final class QuarantineStore {
    static let expiryInterval: TimeInterval = 90

    private let clock: () -> Date
    private var clips: [MemoryClip] = []

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    func add(_ clip: MemoryClip) {
        clips.append(clip)
    }

    /// Pruning happens as a side effect of asking, not on a background timer — there is
    /// no thread here to run one. Pass `now` explicitly in tests; callers in the app can
    /// omit it and get the store's own clock.
    @discardableResult
    func active(now: Date? = nil) -> [MemoryClip] {
        let reference = now ?? clock()
        clips.removeAll { $0.expiresAt <= reference }
        return clips
    }

    func clear() {
        clips.removeAll()
    }
}

// MARK: - Local persistence (PRE-247-C/D)

/// Local, opt-in persistence of `ClipboardMonitor`'s history to
/// `~/.aliasbar/clips.json` — concrete-path API, exactly like `PromptUsageCounter`:
/// tolerant of a missing or corrupt file (reads as empty rather than failing), and
/// every write is atomic (temp file + rename).
///
/// This type does no gating of its own: `load`/`save` are only ever called by
/// `ClipboardPersistenceController` (`ClipboardMonitor.swift`), which is the one
/// place `clipboardPersistence` is read — so "is persistence actually on" only ever
/// has one answer in the whole app, and only `SafeClip`s (never `MemoryClip`s or
/// `CapturedClip`s, neither of which is even `Encodable`) ever reach this file.
enum ClipboardHistoryStore {
    /// Matches `ClipboardMonitor.historyCap` — enforced again here so a corrupt or
    /// hand-edited file larger than the cap can never blow it back up in memory.
    static let cap = 200

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

    /// Newest-first, exactly as `ClipboardMonitor.history` stores them. A missing or
    /// corrupt file reads as empty — a lost clipboard history is an inconvenience,
    /// never something worth crashing or refusing to launch over.
    static func load(path: String) -> [SafeClip] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let decoded = (try? decoder.decode([SafeClip].self, from: data)) ?? []
        return Array(decoded.prefix(cap))
    }

    /// Writes `clips`, capped, atomically. Never throws: a failed save here should
    /// never interrupt whatever triggered it — a copy, a poll tick.
    static func save(_ clips: [SafeClip], path: String) {
        let capped = Array(clips.prefix(cap))
        guard let data = try? encoder.encode(capped) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let tempPath = directory + "/.aliasbar-clips-\(UUID().uuidString)"
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

// MARK: - Sync mirror (PRE-247-C/D)

/// Presets and clips both travel through `SharedDocumentStore`'s generic
/// per-collection dual-write pattern (see `SettingsSyncCoordinator.pushPresets` in
/// `SettingsSync.swift`) — this is that same shape, applied to `SafeClip`.
/// Conformance lives here, beside `SafeClip` itself, for the same reason
/// `SettingsSync.swift` keeps `Appearance`'s conformance beside its own sync wiring:
/// the decision to sync a type should be visible in one place.
extension SafeClip: SharedRecordConvertible {}

enum ClipboardSyncCollection {
    static let clips = "clips"
}

/// Reconciles a local, already-capped clip history against the shared document's
/// "clips" collection: whole-collection reconciliation, exactly like
/// `SettingsSyncCoordinator.pushPresets` — upsert anything local that's new or
/// changed, tombstone anything the document still lists live that a cap eviction (or
/// a setting flip) has since dropped locally. There is no merge-on-enable step here,
/// unlike settings/presets: clips are a rolling recency window, not a durable
/// preference, so "the document's clips collection eventually mirrors whatever is in
/// the local history file" is the whole contract.
enum ClipboardSyncMirror {
    static func reconcile(_ clips: [SafeClip], into store: SharedDocumentStore) {
        let now = Date()
        let existing: [SyncedRecord]
        if case .success(let doc) = store.read() {
            existing = doc.records[ClipboardSyncCollection.clips] ?? []
        } else {
            existing = []
        }

        let localIDs = Set(clips.map { $0.id.uuidString })
        for clip in clips {
            let id = clip.id.uuidString
            let currentRecord = existing.first { $0.id == id && !$0.deleted }
            let decodedCurrent = currentRecord.flatMap {
                try? JSONDecoder.aliasBarDocument.decode(SafeClip.self, from: $0.payload)
            }
            guard decodedCurrent != clip else { continue }
            _ = try? store.upsert(clip, id: id, in: ClipboardSyncCollection.clips, modifiedAt: now)
        }

        for record in existing where !record.deleted && !localIDs.contains(record.id) {
            _ = try? store.tombstone(id: record.id, in: ClipboardSyncCollection.clips, modifiedAt: now)
        }
    }
}
