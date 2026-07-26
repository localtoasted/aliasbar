import Foundation

// MARK: - The roaming boundary

/// The single explicit table answering "does this setting roam?" — read this before
/// adding a new `AppSettings` property, and point here rather than at tribal knowledge
/// when the interview asks what leaves the machine.
///
/// Frozen per the phase-1 interview's assumption A2: `RoamedKey` is the *entire* set of
/// settings that ever leave this machine when file sync is on. It is exhaustive on its
/// own — nothing reaches `SharedDocumentStore`'s `settings` dictionary under a key this
/// type doesn't name, full stop.
///
/// `LocalOnlyKey` is not load-bearing for any code path; nothing switches on it. It
/// exists so the boundary reads as a closed accounting — every other preference
/// `AppSettings` persists, named once, so a reviewer (or `WriterTests.swift`) can see
/// the closed set rather than infer it from what `RoamedKey` merely doesn't mention.
/// A few properties (`boardDensity`, `motionLevel`, `presentationStyle`,
/// `followsSystemAppearance`, `showFunctions`, `showAliases`) are not named in either
/// list handed down by the interview; they are filed here as local-only until a future
/// revision deliberately moves them — the frozen list is the seven cases in `RoamedKey`
/// plus saved presets, nothing implied beyond that.
enum SettingsSync {
    /// A roamed setting's current value is written into the shared document's
    /// `settings` dictionary under `rawValue`, and is read back the same way.
    enum RoamedKey: String, CaseIterable {
        case appearance
        case searchScope
        case sortOrder
        case defaultView
        case resultLimit
        case enterAction
        case afterAction
    }

    /// Documentation only — see the type's doc comment. Never written to a shared
    /// document under any circumstance.
    enum LocalOnlyKey: String, CaseIterable {
        /// Heads the list on purpose: the setting that turns sync on cannot itself be
        /// a thing sync carries (see `AppSettings.syncFileURL`).
        case syncFileURL
        case rcPathOverride
        case hotkeyKeyCode
        case hotkeyModifiers
        case hotkeyEnabled
        case onboardingComplete
        case hasEverPasted
        case clipboardMonitoring
        case clipboardPersistence
        case clipboardInSyncFile
        case boardDensity
        case motionLevel
        case presentationStyle
        case followsSystemAppearance
        case showFunctions
        case showAliases
    }

    /// Saved presets travel as records (one per preset, keyed by its `id`), not as a
    /// single setting — see `SettingsSyncCoordinator.pushPresets`.
    enum RoamedRecordCollection {
        static let presets = "presets"
    }

    /// The current value of `key`, encoded as a `SettingValue`. `Appearance` is a
    /// struct, so it travels as its own JSON document wrapped in a `.string` — the
    /// settings dictionary only has shapes for string/number/bool, and inventing a
    /// fourth "structured" case there would duplicate what `records` already exists
    /// to hold.
    static func settingValue(for key: RoamedKey, in settings: AppSettings) -> SettingValue? {
        switch key {
        case .appearance:
            guard let data = try? JSONEncoder.aliasBarDocument.encode(settings.appearance),
                  let json = String(data: data, encoding: .utf8)
            else { return nil }
            return .string(json)
        case .searchScope: return .string(settings.searchScope.rawValue)
        case .sortOrder: return .string(settings.sortOrder.rawValue)
        case .defaultView: return .string(settings.defaultView.rawValue)
        case .resultLimit: return .number(Double(settings.resultLimit))
        case .enterAction: return .string(settings.enterAction.rawValue)
        case .afterAction: return .string(settings.afterAction.rawValue)
        }
    }

    /// Applies a decoded value from the shared document onto `settings`. Returns
    /// `false` — and makes no assignment at all — when the decoded value doesn't
    /// actually differ from what's already there, or doesn't decode as this key's
    /// expected shape. That no-op guard is what keeps the reload path from
    /// manufacturing observer churn (and a matching push right back to the document)
    /// every time it re-reads a document that hasn't actually changed for a given key.
    @discardableResult
    static func apply(_ key: RoamedKey, value: SettingValue, to settings: AppSettings) -> Bool {
        switch key {
        case .appearance:
            guard case .string(let json) = value,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder.aliasBarDocument.decode(Appearance.self, from: data)
            else { return false }
            guard decoded != settings.appearance else { return false }
            settings.appearance = decoded
            return true
        case .searchScope:
            guard case .string(let raw) = value, let decoded = SearchScope(rawValue: raw)
            else { return false }
            guard decoded != settings.searchScope else { return false }
            settings.searchScope = decoded
            return true
        case .sortOrder:
            guard case .string(let raw) = value, let decoded = SortOrder(rawValue: raw)
            else { return false }
            guard decoded != settings.sortOrder else { return false }
            settings.sortOrder = decoded
            return true
        case .defaultView:
            guard case .string(let raw) = value, let decoded = ViewMode(rawValue: raw)
            else { return false }
            guard decoded != settings.defaultView else { return false }
            settings.defaultView = decoded
            return true
        case .resultLimit:
            guard case .number(let raw) = value else { return false }
            let decoded = Int(raw)
            guard decoded != settings.resultLimit else { return false }
            settings.resultLimit = decoded
            return true
        case .enterAction:
            guard case .string(let raw) = value, let decoded = EnterAction(rawValue: raw)
            else { return false }
            guard decoded != settings.enterAction else { return false }
            settings.enterAction = decoded
            return true
        case .afterAction:
            guard case .string(let raw) = value, let decoded = AfterAction(rawValue: raw)
            else { return false }
            guard decoded != settings.afterAction else { return false }
            settings.afterAction = decoded
            return true
        }
    }

    /// Every sibling `<file>.conflict-*` copy `SharedDocumentStore` has preserved
    /// beside `url`, most recent first (the timestamp in the filename sorts
    /// lexicographically). Purely informational for the Settings UI's warning row —
    /// nothing here reads, merges, or deletes them.
    static func conflictFiles(near url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".conflict-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names
            .filter { $0.hasPrefix(prefix) }
            .sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }
}

/// Presets are exactly the kind of structured, evolving record `SharedRecordConvertible`
/// exists for. This conformance lives here rather than in `Appearance.swift` so the
/// decision to sync presets — and everything that follows from it — stays visible in
/// one file rather than split across the type's home and its sync wiring.
extension Appearance: SharedRecordConvertible {}

// MARK: - Coordinator

/// Owns the live wiring between one `AppSettings` instance and one `SharedDocumentStore`
/// for as long as sync is enabled. `AppSettings.syncFileURL` is the only thing that
/// creates or tears this down; exactly one instance exists per enabled sync session.
///
/// `settings` is held `unowned` rather than `weak`: this coordinator's owner (its
/// `syncFileURL` property) is the same object, so there is never a moment where
/// `settings` outlives the coordinator holding a reference to it, and `weak` would only
/// add an optional nobody needs to unwrap.
final class SettingsSyncCoordinator {
    private unowned let settings: AppSettings
    private let store: SharedDocumentStore
    private let url: URL
    private var watcher: SharedDocumentWatcher?

    /// Set for the duration of writing a remote change onto `settings`. Every roamed
    /// property's `didSet` calls back into `push`/`pushPresets` unconditionally; this
    /// flag is what stops that from immediately writing an external change straight
    /// back to the document as though it were a fresh local edit — a feedback loop that
    /// would otherwise re-stamp every key with a new `modifiedAt` on every reload.
    private var isApplyingRemote = false

    init(settings: AppSettings, url: URL) {
        self.settings = settings
        self.url = url
        self.store = SharedDocumentStore(url: url)
    }

    /// Runs the enable-time merge-or-seed decision, then starts watching for external
    /// changes. Called exactly once, right after `AppSettings` creates this instance.
    func enableAndStart() {
        mergeOrSeedOnEnable()
        startWatching()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: Local -> document

    /// Writes one roamed setting's current value into the document, stamped with the
    /// current time. Called from that setting's `didSet` in `AppSettings`.
    func push(_ key: SettingsSync.RoamedKey) {
        guard !isApplyingRemote else { return }
        guard let value = SettingsSync.settingValue(for: key, in: settings) else { return }
        _ = try? store.setSetting(value, forKey: key.rawValue, modifiedAt: Date())
    }

    /// Reconciles the document's `presets` collection against `settings.savedPresets`
    /// right now: upserts anything local that's new or changed, tombstones anything the
    /// document still lists live that no longer exists locally. Whole-collection
    /// reconciliation rather than diffing the specific edit that just happened, because
    /// `savedPresets` is one array with insert/rename/delete/reorder all going through
    /// the same `didSet` — reconciling is simpler than teaching every call site to
    /// describe its own diff, and the per-record unchanged-check below keeps a reorder
    /// (which touches every index but no content) from bumping every record's
    /// `modifiedAt` regardless.
    func pushPresets() {
        guard !isApplyingRemote else { return }
        let now = Date()
        let existing: [SyncedRecord]
        if case .success(let doc) = store.read() {
            existing = doc.records[SettingsSync.RoamedRecordCollection.presets] ?? []
        } else {
            existing = []
        }

        for preset in settings.savedPresets {
            let currentRecord = existing.first { $0.id == preset.id && !$0.deleted }
            let decodedCurrent = currentRecord.flatMap {
                try? JSONDecoder.aliasBarDocument.decode(Appearance.self, from: $0.payload)
            }
            guard decodedCurrent != preset else { continue }
            _ = try? store.upsert(preset, id: preset.id,
                                  in: SettingsSync.RoamedRecordCollection.presets, modifiedAt: now)
        }

        let localIDs = Set(settings.savedPresets.map(\.id))
        for record in existing where !record.deleted && !localIDs.contains(record.id) {
            _ = try? store.tombstone(id: record.id,
                                     in: SettingsSync.RoamedRecordCollection.presets, modifiedAt: now)
        }
    }

    // MARK: Enable-time merge

    /// "If file exists and valid → merge (doc wins by modifiedAt); if absent → seed
    /// from current settings." Local `AppSettings` values don't carry a per-key
    /// `modifiedAt` of their own (`UserDefaults` isn't versioned), so "doc wins" is
    /// implemented as: whatever the document already has for a roamed key or a preset
    /// id is adopted outright, and only keys/presets the document doesn't have yet are
    /// filled in from local — which is both what "seed from current settings" reduces
    /// to when the document is empty, and the only reading of "doc wins" that doesn't
    /// require inventing a local timestamp that was never actually recorded.
    private func mergeOrSeedOnEnable() {
        guard case .success(let doc) = store.read() else {
            // Unreadable, corrupt, or a future schema version at the chosen path:
            // nothing safe to merge from and nothing safe to overwrite. Local settings
            // and the file are both left exactly as they were; `syncError` carries the
            // reason to the Settings UI.
            settings.syncError = "Couldn't enable sync at that file: it isn't a valid AliasBar sync document, so nothing was read or written. Choose a different file, or a new one."
            return
        }
        let hasExistingContent = !doc.settings.isEmpty
            || !(doc.records[SettingsSync.RoamedRecordCollection.presets]?.isEmpty ?? true)
        if hasExistingContent {
            applyRemoteSettings(doc.settings,
                                presetRecords: doc.records[SettingsSync.RoamedRecordCollection.presets] ?? [])
        } else {
            for key in SettingsSync.RoamedKey.allCases { push(key) }
            pushPresets()
        }
        settings.syncError = nil
    }

    // MARK: Document -> local

    /// Re-reads the document right now and applies it. The watcher calls this after its
    /// debounce; `AppSettings.reloadSyncNow()` calls it directly so tests (and a manual
    /// "check now" affordance) don't depend on real filesystem event timing.
    func reloadNow() {
        switch store.read() {
        case .success(let doc):
            applyRemoteSettings(doc.settings,
                                presetRecords: doc.records[SettingsSync.RoamedRecordCollection.presets] ?? [])
            settings.syncError = nil
        case .failure(let error):
            settings.syncError = error.errorDescription
        }
    }

    private func applyRemoteSettings(_ remote: [String: SettingRecord], presetRecords: [SyncedRecord]) {
        isApplyingRemote = true
        var keysMissingFromDoc: [SettingsSync.RoamedKey] = []
        for key in SettingsSync.RoamedKey.allCases {
            if let record = remote[key.rawValue] {
                SettingsSync.apply(key, value: record.value, to: settings)
            } else {
                keysMissingFromDoc.append(key)
            }
        }
        applyPresetRecords(presetRecords)
        isApplyingRemote = false

        // Anything the document didn't have — a key from before this feature existed
        // on this Mac, or a preset created here before the document ever saw it — gets
        // seeded up now that pushing is safe again (the guard above only suppresses
        // pushes made *while* applying a remote change).
        for key in keysMissingFromDoc { push(key) }
        pushPresets()
    }

    private func applyPresetRecords(_ records: [SyncedRecord]) {
        var updated = settings.savedPresets
        var changed = false
        for record in records {
            if record.deleted {
                if let index = updated.firstIndex(where: { $0.id == record.id }) {
                    updated.remove(at: index)
                    changed = true
                }
                continue
            }
            guard let decoded = try? JSONDecoder.aliasBarDocument.decode(Appearance.self, from: record.payload)
            else { continue }
            if let index = updated.firstIndex(where: { $0.id == record.id }) {
                if updated[index] != decoded {
                    updated[index] = decoded
                    changed = true
                }
            } else {
                updated.append(decoded)
                changed = true
            }
        }
        // Only assign (and so only trigger `savedPresets`'s didSet) when something
        // genuinely changed — otherwise every reload of an unchanged document would
        // re-publish an identical array and needlessly churn any observer of it.
        if changed { settings.savedPresets = updated }
    }

    // MARK: Watching

    private func startWatching() {
        let newWatcher = SharedDocumentWatcher(url: url) { [weak self] _ in
            self?.reloadNow()
        }
        watcher = newWatcher
        try? newWatcher.start()
    }
}
