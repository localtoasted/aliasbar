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
struct SafeClip: Codable, Equatable {
    struct SourceMetadata: Codable, Equatable {
        let declaredTypes: [String]
        let byteSize: Int
    }

    let content: String
    let detectedAt: Date
    let source: SourceMetadata
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
