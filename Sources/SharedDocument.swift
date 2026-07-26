import Foundation

/// A versioned JSON document that can be shared across machines (iCloud, Dropbox, a
/// dotfiles repo) and mutated by more than one process without a lock.
///
/// The rules it holds to, in priority order:
///
/// 1. Never lose either side of a conflicting write. A merge always keeps a decision-
///    per-record, never a whole-file "last save wins".
/// 2. Refuse on anything it does not understand — corrupt JSON, an unknown schema
///    version — rather than guess. Refusing preserves the file exactly as it was.
/// 3. Merges are deterministic: given the same two inputs, every writer computes the
///    same output, with no coordination between them. Per-record `modifiedAt` decides
///    the winner; a tombstone wins a tie; a byte-for-byte tie-break after that
///    guarantees two independent writers still converge on one answer.
/// 4. Every write is atomic: a temp file beside the target, then `rename`.
///
/// This mirrors `AliasWriter`'s philosophy for the same reason: a mistake here can
/// silently drop a record nobody meant to lose.
enum SharedDocumentSchema {
    /// The only schema version this build understands. A document written by a newer
    /// build of AliasBar carries a higher number here, and this build must refuse to
    /// touch it rather than reinterpret or truncate fields it doesn't know about.
    static let current = 1
}

// MARK: - JSON passthrough

/// A JSON value of unknown shape, used only to carry fields this build does not
/// recognize through a read-modify-write cycle untouched.
///
/// Equality (and therefore round-trip fidelity) is structural, not byte-for-byte: a
/// decode → encode → decode cycle is guaranteed to produce an equal tree, not an
/// identical file. Object key order and numeric formatting (`1` vs `1.0`) are not
/// preserved, because JSONEncoder does not preserve them either; nothing this type
/// does could keep that promise.
indirect enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int64)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters. Bool must be tried before Int64/Double, because Foundation's
        // JSONDecoder will happily decode a JSON `1` or `0` as a Bool, which would
        // silently turn a numeric field into a boolean on the next encode. Int64 must
        // then be tried before Double: a whole-number field (a Unix timestamp, a
        // database row id) can easily exceed 2^53, the largest integer a Double can
        // represent exactly, and decoding it as Double first would silently round it
        // to the nearest representable value before this type ever sees it. Int64
        // decoding fails outright on a fractional number (`1.5`), so this never
        // misclassifies an actual float — it only catches values that really are
        // whole numbers.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Settings

/// A leaf value inside `SharedDocument.settings`. Just enough shapes to cover a
/// preferences file; anything structured belongs in a record, not a setting.
enum SettingValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported setting value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    /// A deterministic byte sequence used only to break an exact-`modifiedAt` tie
    /// between two writers who computed different values at the same instant. Any
    /// stable encoding works; what matters is that every writer computes the same one.
    fileprivate var tieBreakBytes: Data {
        (try? JSONEncoder.aliasBarStable.encode(self)) ?? Data()
    }
}

/// One setting and when it was last set. Settings merge per-key, the same as records
/// merge per-id: whichever write has the later `modifiedAt` wins.
struct SettingRecord: Codable, Equatable {
    var value: SettingValue
    var modifiedAt: Date
}

// MARK: - Records

/// One synced record inside a named collection ("presets", "snippets", "clips", ...).
///
/// `payload` is the JSON encoding of the actual record; this type only carries the
/// sync metadata around it, so a new collection kind never has to touch merge logic.
/// `deleted` is a tombstone, not a removal: a deleted record stays in the array (so its
/// `modifiedAt` can keep outrunning a stale concurrent edit) and is only ever hidden
/// from readers, never dropped from the file.
struct SyncedRecord: Codable, Equatable {
    var id: String
    var modifiedAt: Date
    var deleted: Bool
    var payload: Data

    fileprivate var tieBreakBytes: Data { payload }
}

/// Marks a type eligible to be stored as a `SyncedRecord` payload.
///
/// Deliberately just `Codable` plus this marker: the marker exists so a type must opt
/// in on purpose. PRE-247's clipboard types are not given this conformance in this
/// slice — that wiring belongs to whichever later change actually needs clips synced,
/// and should make that call deliberately rather than inherit it for free.
protocol SharedRecordConvertible: Codable {}

// MARK: - Document

/// The full contents of a shared document file.
///
/// `unknownFields` carries any top-level key this build does not recognize (written by
/// a future version, or by a sibling feature this build predates) through untouched.
struct SharedDocument: Codable, Equatable {
    var schema: Int
    var settings: [String: SettingRecord]
    var records: [String: [SyncedRecord]]
    var unknownFields: [String: JSONValue]

    init(schema: Int = SharedDocumentSchema.current,
         settings: [String: SettingRecord] = [:],
         records: [String: [SyncedRecord]] = [:],
         unknownFields: [String: JSONValue] = [:]) {
        self.schema = schema
        self.settings = settings
        self.records = records
        self.unknownFields = unknownFields
    }

    private enum CodingKeys: String, CodingKey { case schema, settings, records }

    /// Coding key for whatever top-level keys `CodingKeys` doesn't name.
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    private static let knownTopLevelKeys: Set<String> = ["schema", "settings", "records"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        settings = try container.decodeIfPresent([String: SettingRecord].self, forKey: .settings) ?? [:]
        records = try container.decodeIfPresent([String: [SyncedRecord]].self, forKey: .records) ?? [:]

        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in dynamic.allKeys where !Self.knownTopLevelKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try dynamic.decode(JSONValue.self, forKey: key)
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(settings, forKey: .settings)
        try container.encode(records, forKey: .records)

        var dynamic = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in unknownFields {
            guard let codingKey = DynamicKey(stringValue: key) else { continue }
            try dynamic.encode(value, forKey: codingKey)
        }
    }
}

extension JSONEncoder {
    /// A shared, deterministically-configured encoder.
    ///
    /// `dateEncodingStrategy` is `.secondsSince1970` rather than `.iso8601` on
    /// purpose: `Date` is a `Double` of seconds internally, and the ISO 8601 string
    /// Foundation emits by default has only whole-second resolution. Two writes in
    /// the same second would then decode back to equal `modifiedAt` values that were
    /// never actually equal, which is exactly the case the tie-break rule exists to
    /// handle correctly — silently losing the sub-second difference would make ties
    /// out of races that were not really ties.
    ///
    /// `.sortedKeys` is not for byte fidelity (round-trip equality is checked
    /// structurally, see `JSONValue`) — it is so two writers merging the same
    /// `SettingValue` or record payload for a tie-break comparison produce identical
    /// bytes for identical values, which is what makes the tie-break in
    /// `SharedDocumentStore.pickWinner` actually converge.
    static let aliasBarStable: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let aliasBarDocument: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

extension JSONDecoder {
    static let aliasBarDocument: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

// MARK: - Store

/// Reads, merges, and atomically writes a `SharedDocument` at a fixed URL.
///
/// Not an actor: like the rest of AliasBar's storage, this is called from the main
/// thread of a single app process. Concurrency this guards against is *external* —
/// another process (a second Mac, a sync daemon, a text editor) replacing the file
/// between this process's read and its write — not internal threading.
final class SharedDocumentStore {
    enum StoreError: LocalizedError {
        case unreadable(String)
        /// The file exists but is not valid JSON, or does not decode as a document.
        /// The original is left exactly as it was; `conflictCopy` is a forensic
        /// snapshot written beside it, in case something else overwrites the original
        /// before a person gets to look at it.
        case corrupt(original: String, conflictCopy: String?, reason: String)
        /// The file decodes fine but declares a schema this build does not understand
        /// (from a newer build, most likely). Handled identically to `.corrupt`:
        /// refuse, snapshot, never touch the original.
        case unknownSchema(found: Int, original: String, conflictCopy: String?)
        case writeFailed(String)
        case backupFailed(String)
        /// The file kept changing out from under every retry. Vanishingly unlikely
        /// outside of a pathological test; surfaced rather than looping forever.
        case tooManyConcurrentWriters

        var errorDescription: String? {
            switch self {
            case .unreadable(let why):
                return "Couldn't read the shared document: \(why)"
            case .corrupt(let original, let copy, let reason):
                let where_ = copy.map { " A copy of the bad file is at \($0)." } ?? ""
                return "\(original) isn't a valid AliasBar document, so nothing was written: \(reason).\(where_)"
            case .unknownSchema(let found, let original, let copy):
                let where_ = copy.map { " A copy is at \($0)." } ?? ""
                return "\(original) is schema \(found), which this build doesn't understand, so nothing was written.\(where_)"
            case .writeFailed(let why):
                return "Couldn't save the shared document: \(why)"
            case .backupFailed(let why):
                return "Couldn't write a safety copy, so nothing was changed: \(why)"
            case .tooManyConcurrentWriters:
                return "The shared document kept changing during the save. Try again."
            }
        }
    }

    /// One requested change. Kept private: the only public entry points require a
    /// `SharedRecordConvertible` payload (`upsert`) or an explicit tombstone/setting
    /// call, so nothing outside this file can hand `mutate` a raw, unvalidated blob.
    private enum Mutation {
        case upsertRecord(collection: String, id: String, modifiedAt: Date, payload: Data)
        case tombstoneRecord(collection: String, id: String, modifiedAt: Date)
        case setSetting(key: String, value: SettingValue, modifiedAt: Date)
    }

    private let url: URL
    private let maxMergeAttempts = 8

    /// Test-only seam. If set, `mutate` invokes and clears it exactly once, right
    /// after computing the merged document but before the compare-and-rename step —
    /// the exact window a second writer could land in. Production code never sets
    /// this; it exists because a single-threaded synchronous call has no other way
    /// for a test to land a write inside that window.
    static var testRaceHook: (() -> Void)?

    init(url: URL) {
        self.url = url
    }

    // MARK: Read

    /// The document at rest, or a fresh empty one if the file doesn't exist yet — the
    /// same "no file yet is a legitimate starting state" rule `AliasWriter` uses for a
    /// missing `.zshrc`.
    func read() -> Result<SharedDocument, StoreError> {
        do {
            guard let bytes = try Self.readIfExists(url) else {
                return .success(SharedDocument())
            }
            return .success(try Self.decodeValidated(bytes, url: url, preserveConflict: false))
        } catch let error as StoreError {
            return .failure(error)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    // MARK: Mutations

    func upsert<T: SharedRecordConvertible>(_ value: T, id: String, in collection: String,
                                             modifiedAt: Date) throws -> SharedDocument {
        let payload = try JSONEncoder.aliasBarDocument.encode(value)
        return try mutate(.upsertRecord(collection: collection, id: id,
                                        modifiedAt: modifiedAt, payload: payload))
    }

    @discardableResult
    func tombstone(id: String, in collection: String, modifiedAt: Date) throws -> SharedDocument {
        try mutate(.tombstoneRecord(collection: collection, id: id, modifiedAt: modifiedAt))
    }

    @discardableResult
    func setSetting(_ value: SettingValue, forKey key: String, modifiedAt: Date) throws -> SharedDocument {
        try mutate(.setSetting(key: key, value: value, modifiedAt: modifiedAt))
    }

    /// Applies one mutation, merging against whatever is on disk right now.
    ///
    /// The loop is what makes this safe under a concurrent writer: each pass reads
    /// the current file, applies the *same* mutation on top of it, and commits only
    /// if a re-read just before the rename still matches what it first read. A writer
    /// landing inside the narrow window between that final comparison and the rename
    /// itself is still overwritten — closing that fully would need a lock file, and
    /// the realistic concurrent writer here (a sync daemon) redelivers its version as
    /// a later external change anyway. When the comparison does catch a change, the
    /// loop re-applies the same mutation to the new state — which is exactly a
    /// three-way merge, because `apply(_:to:)` resolves each touched record or
    /// setting key by `modifiedAt` rather than overwriting wholesale.
    private func mutate(_ mutation: Mutation) throws -> SharedDocument {
        var attempt = 0
        while true {
            attempt += 1
            guard attempt <= maxMergeAttempts else { throw StoreError.tooManyConcurrentWriters }

            let readBytes = try Self.readIfExists(url)
            let base: SharedDocument
            if let readBytes {
                base = try Self.decodeValidated(readBytes, url: url, preserveConflict: true)
            } else {
                base = SharedDocument()
            }

            let merged = Self.apply(mutation, to: base)
            let newBytes = try JSONEncoder.aliasBarDocument.encode(merged)

            if let hook = Self.testRaceHook {
                Self.testRaceHook = nil
                hook()
            }

            if try commitIfUnchanged(newBytes, expecting: readBytes) {
                return merged
            }
            // Something else wrote to the file between the read above and the
            // compare-and-rename just now. Loop: re-read, re-apply the same
            // mutation on top of the new state, try again.
        }
    }

    /// Writes `newBytes` to a temp sibling, then renames it over `url`, but only if
    /// the file's content still matches `expectedBytes` (by SHA-256, not just
    /// metadata — a same-second, same-size edit can otherwise slip past an mtime
    /// check). Returns whether the commit happened.
    private func commitIfUnchanged(_ newBytes: Data, expecting expectedBytes: Data?) throws -> Bool {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".aliasbar-shared-\(UUID().uuidString)")
        let fm = FileManager.default

        let originalAttributes = try? fm.attributesOfItem(atPath: url.path)

        do {
            try newBytes.write(to: tempURL, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }

        let currentBytes = try? Data(contentsOf: url)
        let expectedHash = expectedBytes.map { SHA256Digest.hexString($0) }
        let currentHash = currentBytes.map { SHA256Digest.hexString($0) }
        guard expectedHash == currentHash else {
            try? fm.removeItem(at: tempURL)
            return false
        }

        if let attributes = originalAttributes {
            var carried: [FileAttributeKey: Any] = [:]
            if let posix = attributes[.posixPermissions] { carried[.posixPermissions] = posix }
            try? fm.setAttributes(carried, ofItemAtPath: tempURL.path)
        }

        if rename(tempURL.path, url.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: tempURL)
            throw StoreError.writeFailed(reason)
        }
        return true
    }

    // MARK: Merge

    /// Applies one mutation on top of `document`, resolving any collision with what's
    /// already there by `modifiedAt`. This is the entire merge algorithm: called once
    /// on a clean read it just adds the change; called again after a concurrent write
    /// was detected, it resolves the collision the same way, so first-write and
    /// merge-on-retry are the same code path.
    private static func apply(_ mutation: Mutation, to document: SharedDocument) -> SharedDocument {
        var doc = document
        switch mutation {
        case .setSetting(let key, let value, let modifiedAt):
            let incoming = SettingRecord(value: value, modifiedAt: modifiedAt)
            if let existing = doc.settings[key] {
                doc.settings[key] = pickWinner(existing: existing, incoming: incoming,
                                               existingModifiedAt: existing.modifiedAt,
                                               incomingModifiedAt: incoming.modifiedAt,
                                               existingIsTombstone: false, incomingIsTombstone: false,
                                               existingTieBytes: existing.value.tieBreakBytes,
                                               incomingTieBytes: incoming.value.tieBreakBytes)
            } else {
                doc.settings[key] = incoming
            }

        case .upsertRecord(let collection, let id, let modifiedAt, let payload):
            let incoming = SyncedRecord(id: id, modifiedAt: modifiedAt, deleted: false, payload: payload)
            doc.records[collection] = mergedList(doc.records[collection] ?? [], upserting: incoming)

        case .tombstoneRecord(let collection, let id, let modifiedAt):
            let incoming = SyncedRecord(id: id, modifiedAt: modifiedAt, deleted: true, payload: Data())
            doc.records[collection] = mergedList(doc.records[collection] ?? [], upserting: incoming)
        }
        return doc
    }

    private static func mergedList(_ list: [SyncedRecord], upserting incoming: SyncedRecord) -> [SyncedRecord] {
        var list = list
        guard let index = list.firstIndex(where: { $0.id == incoming.id }) else {
            list.append(incoming)
            return list
        }
        let existing = list[index]
        list[index] = pickWinner(existing: existing, incoming: incoming,
                                  existingModifiedAt: existing.modifiedAt,
                                  incomingModifiedAt: incoming.modifiedAt,
                                  existingIsTombstone: existing.deleted, incomingIsTombstone: incoming.deleted,
                                  existingTieBytes: existing.tieBreakBytes, incomingTieBytes: incoming.tieBreakBytes)
        return list
    }

    /// The one merge rule, shared by settings and records: later `modifiedAt` wins; at
    /// an exact tie a tombstone wins (a delete should never be silently un-done by a
    /// same-instant edit); at a tie between two live values, the lexicographically
    /// greater encoded byte sequence wins. That last rule only exists so two writers
    /// resolving the same tie *without talking to each other* land on the same value —
    /// any deterministic rule would do, and "which bytes sort higher" is the one that
    /// doesn't need either side to know anything about the other.
    private static func pickWinner<T>(existing: T, incoming: T,
                                      existingModifiedAt: Date, incomingModifiedAt: Date,
                                      existingIsTombstone: Bool, incomingIsTombstone: Bool,
                                      existingTieBytes: Data, incomingTieBytes: Data) -> T {
        if incomingModifiedAt != existingModifiedAt {
            return incomingModifiedAt > existingModifiedAt ? incoming : existing
        }
        if incomingIsTombstone != existingIsTombstone {
            return incomingIsTombstone ? incoming : existing
        }
        if incomingTieBytes == existingTieBytes { return existing }
        return incomingTieBytes.lexicographicallyPrecedes(existingTieBytes) ? existing : incoming
    }

    // MARK: Decode / IO helpers

    private static func readIfExists(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
    }

    /// Decodes and validates `bytes` as a `SharedDocument`. On any failure — invalid
    /// JSON, a decode mismatch, or an unrecognized schema — refuses and (when
    /// `preserveConflict` is set, i.e. this is on the path to a write) writes a
    /// timestamped forensic copy beside the original. The original file itself is
    /// never touched by this function.
    private static func decodeValidated(_ bytes: Data, url: URL, preserveConflict: Bool) throws -> SharedDocument {
        let document: SharedDocument
        do {
            document = try JSONDecoder.aliasBarDocument.decode(SharedDocument.self, from: bytes)
        } catch {
            let copy = preserveConflict ? try? preserveConflictCopy(bytes, near: url) : nil
            throw StoreError.corrupt(original: url.path, conflictCopy: copy,
                                     reason: describeDecodingError(error))
        }
        guard document.schema == SharedDocumentSchema.current else {
            let copy = preserveConflict ? try? preserveConflictCopy(bytes, near: url) : nil
            throw StoreError.unknownSchema(found: document.schema, original: url.path, conflictCopy: copy)
        }
        return document
    }

    private static func describeDecodingError(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .dataCorrupted(let context): return context.debugDescription
            case .keyNotFound(let key, _): return "missing key \"\(key.stringValue)\""
            case .typeMismatch(_, let context): return context.debugDescription
            case .valueNotFound(_, let context): return context.debugDescription
            @unknown default: return decodingError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    /// Writes an untouched copy of the bad file beside itself, timestamped down to
    /// the microsecond plus a UUID so two conflicts in the same run never collide.
    private static func preserveConflictCopy(_ bytes: Data, near url: URL) throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        formatter.timeZone = TimeZone.current
        let stamp = formatter.string(from: Date())
        let unique = UUID().uuidString.lowercased()
        let conflictURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).conflict-\(stamp)-\(unique)")
        do {
            try bytes.write(to: conflictURL, options: .atomic)
        } catch {
            throw StoreError.backupFailed(error.localizedDescription)
        }
        return conflictURL.path
    }
}

// MARK: - Watcher

/// Watches for another process replacing the document file and reports the freshly
/// re-read contents, debounced.
///
/// Watches the **parent directory**, not the file itself: this store's own writes
/// (and any well-behaved sync client's) replace the file via `rename`, which detaches
/// a `DispatchSourceFileSystemObject` opened on the old file descriptor. A directory
/// handle keeps working across any number of its children being replaced.
final class SharedDocumentWatcher {
    typealias ReloadHandler = (Result<SharedDocument, SharedDocumentStore.StoreError>) -> Void

    private let store: SharedDocumentStore
    private let queue: DispatchQueue
    private let onReload: ReloadHandler
    private let debounceInterval: TimeInterval
    private let directoryPath: String

    private var source: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1
    private var pendingReload: DispatchWorkItem?

    init(url: URL, queue: DispatchQueue = .main, debounceInterval: TimeInterval = 0.5,
         onReload: @escaping ReloadHandler) {
        self.store = SharedDocumentStore(url: url)
        self.queue = queue
        self.debounceInterval = debounceInterval
        self.onReload = onReload
        self.directoryPath = url.deletingLastPathComponent().path
    }

    /// Test-only convenience: share a store the test already has, instead of a URL.
    init(store: SharedDocumentStore, directoryPath: String, queue: DispatchQueue = .main,
         debounceInterval: TimeInterval = 0.5, onReload: @escaping ReloadHandler) {
        self.store = store
        self.queue = queue
        self.debounceInterval = debounceInterval
        self.onReload = onReload
        self.directoryPath = directoryPath
    }

    enum WatchError: LocalizedError {
        case cannotOpenDirectory(String)
        var errorDescription: String? {
            switch self {
            case .cannotOpenDirectory(let path): return "Couldn't watch \(path) for changes."
            }
        }
    }

    func start() throws {
        stop()
        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else { throw WatchError.cannotOpenDirectory(directoryPath) }
        directoryDescriptor = fd

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link],
            queue: queue)
        newSource.setEventHandler { [weak self] in self?.scheduleReload() }
        newSource.setCancelHandler { close(fd) }
        source = newSource
        newSource.resume()
    }

    func stop() {
        pendingReload?.cancel()
        pendingReload = nil
        source?.cancel()
        source = nil
        directoryDescriptor = -1
    }

    /// Coalesces a burst of filesystem events (a `rename`-based replace is typically
    /// two or three) into a single reload, fired `debounceInterval` after the last one.
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onReload(self.store.read())
        }
        pendingReload = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    deinit { stop() }
}
