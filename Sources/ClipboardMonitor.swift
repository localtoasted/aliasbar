import AppKit

/// Minimal surface `ClipboardMonitor` needs to read a pasteboard. A protocol rather
/// than `NSPasteboard` directly so tests drive a fake and never touch the real
/// system pasteboard.
protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
}

extension PasteboardReading {
    /// The informal but widely honoured convention (1Password, Bitwarden, Terminal's
    /// secure paste, …) apps use to say "this came from a password field." It carries
    /// no value of its own — its mere presence among the declared types is the signal.
    var hasConcealedType: Bool {
        types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ?? false
    }
}

extension NSPasteboard: PasteboardReading {}

/// Polls `NSPasteboard.general` for new content and routes every genuinely external
/// change through `ClipIngestor.decide` — the single gate between a pasteboard read
/// and anything durable (see `ClipboardCapture.swift`).
///
/// A timer, not a notification: `NSPasteboard` has no change notification of its own.
/// Polling `changeCount` is the standard, documented way every clipboard-history
/// utility on macOS detects a copy.
final class ClipboardMonitor {
    /// Safe clips, newest first, capped, deduped against the immediately preceding
    /// entry — copying the same thing twice in a row (a common accident) should not
    /// produce two history rows.
    private(set) var history: [SafeClip] = []
    let quarantine: QuarantineStore

    /// Aligns with `SensitiveContentClassifier.Thresholds.maximumInputBytes`: content
    /// this large is skipped entirely at capture time, not truncated and not even
    /// handed to the classifier. A multi-megabyte clip is never clipboard-history
    /// material, and reading it into memory on every poll would be its own cost.
    static let byteCap = SensitiveContentClassifier.Thresholds.maximumInputBytes
    private static let historyCap = 200

    // Needs `PasteboardWriting` too, not just `PasteboardReading`: checking whether a
    // changeCount is our own self-write (`PasteboardBroker.isSelfWrite(on:)`) has to
    // name the exact same pasteboard instance the broker wrote to. `NSPasteboard`
    // satisfies both by construction; a test fake must as well.
    private let pasteboard: PasteboardReading & PasteboardWriting
    private let clock: () -> Date
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    /// Told about every change to `history`. `nil` (the default) is the "never
    /// persist" no-op every existing test in this suite exercises unchanged — only
    /// `App.swift`'s production wiring ever supplies a real one.
    private let persistence: ClipboardPersisting?

    init(
        pasteboard: PasteboardReading & PasteboardWriting = NSPasteboard.general,
        quarantine: QuarantineStore = QuarantineStore(),
        clock: @escaping () -> Date = Date.init,
        pollInterval: TimeInterval = 0.4,
        initialHistory: [SafeClip] = [],
        persistence: ClipboardPersisting? = nil
    ) {
        self.pasteboard = pasteboard
        self.quarantine = quarantine
        self.clock = clock
        self.pollInterval = pollInterval
        // Whatever is already on the pasteboard at construction time is not a change
        // we witnessed — only a difference from here on counts as a capture.
        self.lastChangeCount = pasteboard.changeCount
        self.history = initialHistory
        self.persistence = persistence
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Quarantined clips still alive right now. Exposed rather than reaching into
    /// `quarantine` directly so callers always see expiry evaluated against this
    /// monitor's own clock.
    var activeQuarantine: [MemoryClip] {
        quarantine.active(now: clock())
    }

    /// One check for a pasteboard change. Called by the timer; also called directly
    /// by tests so a check never has to wait on `Timer` firing for real.
    func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        // Our own delivery — a paste, a copy, a preset export — must never loop back
        // into history as though the user had copied it.
        guard !PasteboardBroker.isSelfWrite(changeCount: count, on: pasteboard) else { return }
        guard let content = pasteboard.string(forType: .string) else { return }

        let byteSize = content.utf8.count
        guard byteSize <= Self.byteCap else { return }

        let clip = CapturedClip(
            content: content,
            declaredTypes: pasteboard.types?.map(\.rawValue) ?? [],
            byteSize: byteSize,
            capturedAt: clock(),
            concealed: pasteboard.hasConcealedType
        )

        switch ClipIngestor.decide(clip, now: clock()) {
        case .persist(let safeClip):
            appendToHistory(safeClip)
        case .quarantine(let memoryClip):
            quarantine.add(memoryClip)
        }
    }

    private func appendToHistory(_ clip: SafeClip) {
        if history.first?.content == clip.content { return }
        history.insert(clip, at: 0)
        if history.count > Self.historyCap {
            history.removeLast(history.count - Self.historyCap)
        }
        persistence?.historyChanged(history)
    }
}

// MARK: - Persistence (PRE-247-C/D)

/// What `ClipboardMonitor` calls after every change to `history`, kept behind a
/// protocol so this file never has to name `AppSettings`, `AppPaths`, or
/// `SharedDocumentStore` directly — every existing test in this suite constructs a
/// `ClipboardMonitor` with no `persistence:` argument at all and keeps working
/// unchanged, because `nil` (the default) touches no disk, ever.
protocol ClipboardPersisting: AnyObject {
    func historyChanged(_ history: [SafeClip])
}

/// The one place `clipboardPersistence` and `clipboardInSyncFile` are read for the
/// clipboard source. Constructing this does no I/O by itself; only `historyChanged`
/// does, and only when `clipboardPersistence` is actually on right now — the single
/// gate the "zero clipboard bytes written anywhere while off" invariant depends on.
final class ClipboardPersistenceController: ClipboardPersisting {
    /// `unowned`, matching `SettingsSyncCoordinator`'s reasoning: this controller's
    /// owner (the `ClipboardMonitor` `App.swift` builds it for) never outlives
    /// `settings` — `AppSettings.shared` lives for the process's whole run.
    private unowned let settings: AppSettings
    private let clipsPath: String

    init(settings: AppSettings, clipsPath: String = AppPaths.clipsPath) {
        self.settings = settings
        self.clipsPath = clipsPath
    }

    /// What the monitor should seed `history` with at construction time — empty
    /// unless persistence is on *right now*, regardless of whether a file exists on
    /// disk from an earlier session where it used to be. The setting is the one
    /// question that decides whether disk is ever consulted at all.
    func loadInitialHistory() -> [SafeClip] {
        guard settings.clipboardPersistence else { return [] }
        return ClipboardHistoryStore.load(path: clipsPath)
    }

    func historyChanged(_ history: [SafeClip]) {
        guard settings.clipboardPersistence else { return }
        ClipboardHistoryStore.save(history, path: clipsPath)
        guard settings.clipboardInSyncFile, let syncURL = settings.syncFileURL else { return }
        ClipboardSyncMirror.reconcile(Array(history.prefix(ClipboardHistoryStore.cap)),
                                      into: SharedDocumentStore(url: syncURL))
    }
}
