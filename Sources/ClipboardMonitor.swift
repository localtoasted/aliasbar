import AppKit
import ImageIO
import Vision

/// Minimal surface `ClipboardMonitor` needs to read a pasteboard. A protocol rather
/// than `NSPasteboard` directly so tests drive a fake and never touch the real
/// system pasteboard.
protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

extension PasteboardReading {
    /// Text-only fakes and pasteboards have no image representation.
    func data(forType type: NSPasteboard.PasteboardType) -> Data? { nil }

    /// The informal but widely honoured convention (1Password, Bitwarden, Terminal's
    /// secure paste, …) apps use to say "this came from a password field." It carries
    /// no value of its own — its mere presence among the declared types is the signal.
    var hasConcealedType: Bool {
        types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ?? false
    }
}

extension NSPasteboard: PasteboardReading {}

// MARK: - Image clips and local OCR

/// One image captured from the clipboard. Image bytes stay in memory and never
/// conform to Codable, so the existing clipboard persistence and sync paths cannot
/// write them by accident.
struct ClipboardImageClip: Identifiable, Equatable {
    enum Payload: Equatable {
        case ready(Data)
        case tooLarge
        case multipleFrames
        case unreadable
    }

    var id: UUID = UUID()
    let detectedAt: Date
    let declaredTypes: [String]
    let byteSize: Int
    let pixelWidth: Int?
    let pixelHeight: Int?
    let payload: Payload

    var data: Data? {
        guard case .ready(let data) = payload else { return nil }
        return data
    }

    var dimensionsLabel: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(pixelWidth)\u{00d7}\(pixelHeight)"
    }

    var listLabel: String {
        switch payload {
        case .ready:
            return dimensionsLabel.map { "Image \($0)" } ?? "Image"
        case .tooLarge:
            return "Image too large"
        case .multipleFrames:
            return "Multi-frame image"
        case .unreadable:
            return "Unreadable image"
        }
    }

    var issueMessage: String? {
        switch payload {
        case .ready:
            return nil
        case .tooLarge:
            return "AliasBar keeps clipboard images up to 16 MB and 24 megapixels for OCR. Copy a smaller image."
        case .multipleFrames:
            return "AliasBar reads one image frame at a time. Copy a single frame."
        case .unreadable:
            return "AliasBar could not read this image. Copy it again as PNG, TIFF, JPEG, HEIC, or GIF."
        }
    }
}

/// The clipboard UI's common row type. Text keeps using `SafeClip`; images have a
/// separate, memory-only payload. Both carry stable capture IDs so every action can
/// use the row the user selected, not whatever is currently on the system clipboard.
enum ClipboardHistoryItem: Identifiable, Equatable {
    case text(SafeClip)
    case image(ClipboardImageClip)

    var id: UUID {
        switch self {
        case .text(let clip): return clip.id
        case .image(let clip): return clip.id
        }
    }

    var detectedAt: Date {
        switch self {
        case .text(let clip): return clip.detectedAt
        case .image(let clip): return clip.detectedAt
        }
    }

    /// Presentation and query text. An image's bytes are never coerced into a string.
    var content: String {
        switch self {
        case .text(let clip): return clip.content
        case .image(let clip): return clip.listLabel
        }
    }

    var textClip: SafeClip? {
        guard case .text(let clip) = self else { return nil }
        return clip
    }

    var imageClip: ClipboardImageClip? {
        guard case .image(let clip) = self else { return nil }
        return clip
    }
}

/// Reads only direct image representations. File URLs are not opened, so selecting
/// an image file in Finder cannot make clipboard monitoring read an unrelated path.
enum ClipboardImageCapture {
    static let maximumRetainedBytes = 16 * 1_024 * 1_024
    static let maximumPixelCount = 24_000_000

    static let supportedTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("com.compuserve.gif")
    ]

    static func capture(from pasteboard: PasteboardReading, at date: Date) -> ClipboardImageClip? {
        let types = pasteboard.types ?? []
        let declaredImageTypes = supportedTypes.filter(types.contains)
        guard !declaredImageTypes.isEmpty else { return nil }

        let declared = types.map(\.rawValue)
        guard let data = declaredImageTypes.lazy.compactMap({ pasteboard.data(forType: $0) }).first else {
            return ClipboardImageClip(
                detectedAt: date,
                declaredTypes: declared,
                byteSize: 0,
                pixelWidth: nil,
                pixelHeight: nil,
                payload: .unreadable
            )
        }

        guard data.count <= maximumRetainedBytes else {
            return ClipboardImageClip(
                detectedAt: date,
                declaredTypes: declared,
                byteSize: data.count,
                pixelWidth: nil,
                pixelHeight: nil,
                payload: .tooLarge
            )
        }

        let dimensions: (width: Int, height: Int)
        switch metadata(of: data) {
        case .dimensions(let width, let height):
            dimensions = (width, height)
        case .multipleFrames:
            return ClipboardImageClip(
                detectedAt: date,
                declaredTypes: declared,
                byteSize: data.count,
                pixelWidth: nil,
                pixelHeight: nil,
                payload: .multipleFrames
            )
        case .unreadable:
            return ClipboardImageClip(
                detectedAt: date,
                declaredTypes: declared,
                byteSize: data.count,
                pixelWidth: nil,
                pixelHeight: nil,
                payload: .unreadable
            )
        }

        let pixels = UInt64(dimensions.width) * UInt64(dimensions.height)
        guard pixels <= UInt64(maximumPixelCount) else {
            return ClipboardImageClip(
                detectedAt: date,
                declaredTypes: declared,
                byteSize: data.count,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height,
                payload: .tooLarge
            )
        }

        return ClipboardImageClip(
            detectedAt: date,
            declaredTypes: declared,
            byteSize: data.count,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            payload: .ready(data)
        )
    }

    private enum Metadata {
        case dimensions(Int, Int)
        case multipleFrames
        case unreadable
    }

    private static func metadata(of data: Data) -> Metadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return .unreadable
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { return .unreadable }
        guard frameCount == 1 else { return .multipleFrames }
        guard
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return .unreadable }
        return .dimensions(width, height)
    }
}

enum ClipboardImageTextRecognitionError: Error {
    case blockedInTestMode
    case failed
}

protocol ClipboardImageTextRecognitionTask: AnyObject {
    func cancel()
}

protocol ClipboardImageTextRecognizing: AnyObject {
    @discardableResult
    func recognizeText(in data: Data,
                       completion: @escaping (Result<String, ClipboardImageTextRecognitionError>) -> Void)
        -> ClipboardImageTextRecognitionTask
}

/// Apple's on-device text recognizer. Work happens off the main queue and results
/// return on the main queue so AppState can update SwiftUI safely.
final class VisionClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    @discardableResult
    func recognizeText(in data: Data,
                       completion: @escaping (Result<String, ClipboardImageTextRecognitionError>) -> Void)
        -> ClipboardImageTextRecognitionTask {
        let task = VisionClipboardImageTextRecognitionTask(data: data)
        guard !DesktopInteractionGuard.isActive else {
            completion(.failure(.blockedInTestMode))
            return task
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            guard let data = task.begin(request) else { return }

            let result: Result<String, ClipboardImageTextRecognitionError>
            do {
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(data: data, options: [:]).perform([request])

                let observations = request.results ?? []
                let lines = observations
                    .compactMap { observation -> (String, CGRect)? in
                        guard let text = observation.topCandidates(1).first?.string else { return nil }
                        return (text, observation.boundingBox)
                    }
                    .sorted { lhs, rhs in
                        let verticalDifference = abs(lhs.1.maxY - rhs.1.maxY)
                        if verticalDifference > 0.02 { return lhs.1.maxY > rhs.1.maxY }
                        return lhs.1.minX < rhs.1.minX
                    }
                    .map(\.0)
                result = .success(lines.joined(separator: "\n"))
            } catch {
                result = .failure(.failed)
            }

            task.releaseRequest()
            guard !task.isCancelled else { return }
            DispatchQueue.main.async {
                guard !task.isCancelled else { return }
                completion(result)
            }
        }
        return task
    }
}

/// Owns the Vision request so closing, changing selection, or retrying can stop
/// active recognition and release its captured image data promptly.
private final class VisionClipboardImageTextRecognitionTask: ClipboardImageTextRecognitionTask {
    private let lock = NSLock()
    private var pendingData: Data?
    private var request: VNRecognizeTextRequest?
    private var cancelled = false

    init(data: Data) {
        pendingData = data
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Moves the retained clipboard data into the worker only when work actually
    /// starts. Cancelling a queued task clears it before the queue runs.
    func begin(_ request: VNRecognizeTextRequest) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            request.cancel()
            pendingData = nil
            return nil
        }
        self.request = request
        let data = pendingData
        pendingData = nil
        return data
    }

    func releaseRequest() {
        lock.lock()
        request = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        pendingData = nil
        let request = request
        self.request = nil
        lock.unlock()
        request?.cancel()
    }
}

enum ClipboardOCRText {
    /// OCR can return CRLF, CR, or LF depending on the source. Composer stores LF.
    /// Trimming applies only to the outside; indentation and blank lines inside stay.
    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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
    /// Image bytes are deliberately session-only. They never reach `persistence`.
    private(set) var imageHistory: [ClipboardImageClip] = []
    /// One ordering for both payload types. IDs remain fixed from capture through UI
    /// selection and OCR, even when newer clips arrive.
    private var itemOrder: [UUID] = []
    let quarantine: QuarantineStore

    var items: [ClipboardHistoryItem] {
        var textByID: [UUID: SafeClip] = [:]
        for clip in history { textByID[clip.id] = clip }
        var imageByID: [UUID: ClipboardImageClip] = [:]
        for clip in imageHistory { imageByID[clip.id] = clip }
        return itemOrder.compactMap { id in
            if let text = textByID[id] { return .text(text) }
            if let image = imageByID[id] { return .image(image) }
            return nil
        }
    }

    /// Aligns with `SensitiveContentClassifier.Thresholds.maximumInputBytes`: content
    /// this large is skipped entirely at capture time, not truncated and not even
    /// handed to the classifier. A multi-megabyte clip is never clipboard-history
    /// material, and reading it into memory on every poll would be its own cost.
    static let byteCap = SensitiveContentClassifier.Thresholds.maximumInputBytes
    private static let historyCap = 200
    /// Images are much larger than text. Keep a short session window and a hard
    /// byte budget even when every individual image is below the capture limit.
    static let imageHistoryCap = 12
    static let imageHistoryByteBudget = 32 * 1_024 * 1_024

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
        self.lastChangeCount = DesktopInteractionGuard.blocks(pasteboard)
            ? 0
            : pasteboard.changeCount
        self.history = initialHistory
        self.itemOrder = initialHistory.map(\.id)
        self.persistence = persistence
    }

    func start() {
        stop()
        guard !DesktopInteractionGuard.blocks(pasteboard) else { return }
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
        guard !DesktopInteractionGuard.blocks(pasteboard) else { return }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        // Our own delivery — a paste, a copy, a preset export — must never loop back
        // into history as though the user had copied it.
        guard !PasteboardBroker.isSelfWrite(changeCount: count, on: pasteboard) else { return }
        let now = clock()
        let content = pasteboard.string(forType: .string)

        // Concealed content is rejected before image bytes are read. A concealed
        // image-only or oversized copy gets a generic marker in the memory-only
        // quarantine row, so secret payloads cannot bypass the text retention cap.
        if pasteboard.hasConcealedType {
            let quarantinedContent = content.flatMap {
                $0.utf8.count <= Self.byteCap ? $0 : nil
            } ?? "Clipboard item"
            routeText(quarantinedContent,
                      declaredTypes: pasteboard.types?.map(\.rawValue) ?? [],
                      now: now, concealed: true)
            return
        }

        // An image can also carry an alternate string (often a source URL). A
        // secret-shaped alternate string wins and quarantines the whole capture
        // before any image data is retained.
        let declaresImage = pasteboard.types?.contains {
            ClipboardImageCapture.supportedTypes.contains($0)
        } ?? false
        if declaresImage, let content,
           content.utf8.count <= Self.byteCap,
           SensitiveContentClassifier.quarantineReason(in: content) != nil {
            routeText(content, declaredTypes: pasteboard.types?.map(\.rawValue) ?? [],
                      now: now, concealed: false)
            return
        }

        if let image = ClipboardImageCapture.capture(from: pasteboard, at: now) {
            appendImageToHistory(image)
            return
        }

        guard let content else { return }

        let byteSize = content.utf8.count
        guard byteSize <= Self.byteCap else { return }

        routeText(content, declaredTypes: pasteboard.types?.map(\.rawValue) ?? [],
                  now: now, concealed: false)
    }

    private func routeText(_ content: String, declaredTypes: [String], now: Date,
                           concealed: Bool) {
        let clip = CapturedClip(
            content: content,
            declaredTypes: declaredTypes,
            byteSize: content.utf8.count,
            capturedAt: now,
            concealed: concealed
        )

        switch ClipIngestor.decide(clip, now: now) {
        case .persist(let safeClip):
            appendToHistory(safeClip)
        case .quarantine(let memoryClip):
            quarantine.add(memoryClip)
        }
    }

    private func appendToHistory(_ clip: SafeClip) {
        if case .text(let first)? = items.first, first.content == clip.content { return }
        history.insert(clip, at: 0)
        itemOrder.insert(clip.id, at: 0)
        trimHistoryToCap()
        persistence?.historyChanged(history)
    }

    private func appendImageToHistory(_ clip: ClipboardImageClip) {
        if case .image(let first)? = items.first,
           let firstData = first.data, let clipData = clip.data,
           firstData == clipData {
            return
        }
        imageHistory.insert(clip, at: 0)
        itemOrder.insert(clip.id, at: 0)
        trimImageHistoryToBudget()
        let removedText = trimHistoryToCap()
        if removedText { persistence?.historyChanged(history) }
    }

    /// Removes a selected image once its OCR text proves sensitive. The recognized
    /// text follows the same memory-only quarantine policy as sensitive copied text;
    /// the source image bytes are dropped immediately.
    @discardableResult
    func quarantineImage(id: UUID, recognizedText: String,
                         reason: SensitiveContentClassifier.QuarantineReason) -> Bool {
        guard let index = imageHistory.firstIndex(where: { $0.id == id }) else { return false }
        imageHistory.remove(at: index)
        itemOrder.removeAll { $0 == id }
        quarantine.add(MemoryClip(
            content: recognizedText,
            reason: reason,
            expiresAt: clock().addingTimeInterval(QuarantineStore.expiryInterval)
        ))
        return true
    }

    /// Returns whether a text clip was evicted, which is the only case an image-only
    /// capture needs to tell the persistence controller about.
    @discardableResult
    private func trimHistoryToCap() -> Bool {
        var removedText = false
        while itemOrder.count > Self.historyCap, let id = itemOrder.popLast() {
            if let index = history.firstIndex(where: { $0.id == id }) {
                history.remove(at: index)
                removedText = true
            } else if let index = imageHistory.firstIndex(where: { $0.id == id }) {
                imageHistory.remove(at: index)
            }
        }
        return removedText
    }

    private func trimImageHistoryToBudget() {
        var encodedBytes = imageHistory.reduce(0) { $0 + ($1.data?.count ?? 0) }
        while imageHistory.count > Self.imageHistoryCap
                || encodedBytes > Self.imageHistoryByteBudget,
              let oldest = imageHistory.last {
            imageHistory.removeLast()
            itemOrder.removeAll { $0 == oldest.id }
            encodedBytes -= oldest.data?.count ?? 0
        }
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

    /// Turning persistence OFF means the bytes leave the disk, not merely that new
    /// ones stop arriving: the local file is deleted, and any clips already mirrored
    /// into the sync document are tombstoned so other Macs drop them too. Static and
    /// path-parameterized because the toggle can be flipped while no monitor (and so
    /// no controller instance) exists at all.
    static func purgeDiskCopies(clipsPath: String = AppPaths.clipsPath,
                                syncFileURL: URL?) {
        try? FileManager.default.removeItem(atPath: clipsPath)
        if let syncFileURL {
            ClipboardSyncMirror.reconcile([], into: SharedDocumentStore(url: syncFileURL))
        }
    }

    func historyChanged(_ history: [SafeClip]) {
        guard settings.clipboardPersistence else { return }
        ClipboardHistoryStore.save(history, path: clipsPath)
        guard settings.clipboardInSyncFile, let syncURL = settings.syncFileURL else { return }
        ClipboardSyncMirror.reconcile(Array(history.prefix(ClipboardHistoryStore.cap)),
                                      into: SharedDocumentStore(url: syncURL))
    }
}
