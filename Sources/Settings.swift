import SwiftUI
import Carbon.HIToolbox

// MARK: - Setting value types

/// What Enter does to the selected entry.
///
/// This is a setting rather than a hardcoded behaviour because in the dominant use case
/// the user is standing in a terminal about to type the alias themselves, so they want
/// the *name*, not the expansion. v0.1 always copied the command, which is the wrong
/// answer roughly half the time.
enum EnterAction: String, CaseIterable, Identifiable {
    case copyName, copyCommand, pasteName, pasteCommand
    var id: String { rawValue }

    var label: String {
        switch self {
        case .copyName: return "Copy the alias name"
        case .copyCommand: return "Copy the full command"
        case .pasteName: return "Type the alias name into the app behind"
        case .pasteCommand: return "Type the full command into the app behind"
        }
    }

    var short: String {
        switch self {
        case .copyName: return "copy name"
        case .copyCommand: return "copy command"
        case .pasteName: return "type name"
        case .pasteCommand: return "type command"
        }
    }

    /// The paste variants synthesise keystrokes into another application, which macOS
    /// gates behind Accessibility permission.
    var needsAccessibility: Bool {
        self == .pasteName || self == .pasteCommand
    }

    /// What ⌘⏎ should do, given this primary action: the other half of the pair.
    var secondary: EnterAction {
        switch self {
        case .copyName: return .copyCommand
        case .copyCommand: return .copyName
        case .pasteName: return .pasteCommand
        case .pasteCommand: return .pasteName
        }
    }
}

enum AfterAction: String, CaseIterable, Identifiable {
    case close, stayOpen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .close: return "Close the window"
        case .stayOpen: return "Keep it open"
        }
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case find, board, manage
    var id: String { rawValue }

    var label: String {
        switch self {
        case .find: return "Find"
        case .board: return "Board"
        case .manage: return "Manage"
        }
    }

    var symbol: String {
        switch self {
        case .find: return "magnifyingglass"
        case .board: return "square.grid.3x3.fill"
        case .manage: return "slider.horizontal.3"
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case usage, alphabetical, fileOrder
    var id: String { rawValue }
    var label: String {
        switch self {
        case .usage: return "Most used first"
        case .alphabetical: return "Alphabetical"
        case .fileOrder: return "Order in the file"
        }
    }
}

/// Where the window appears when you summon it.
enum PresentationStyle: String, CaseIterable, Identifiable {
    /// Centred on the screen you are working on, like Spotlight.
    case palette
    /// Hanging off the menu bar icon.
    case menuBar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .palette: return "Centred on screen"
        case .menuBar: return "Attached to the menu bar icon"
        }
    }
    var detail: String {
        switch self {
        case .palette:
            return "Opens in the middle of whichever screen your pointer is on. Unaffected by a full menu bar."
        case .menuBar:
            return "Opens as a popover under the AliasBar icon. Needs room in the menu bar to be reachable by mouse."
        }
    }
}

/// How much motion the app is allowed.
///
/// Separate from the system's Reduce Motion, which is honoured unconditionally and is not
/// a preference. This is for the person whose machine is busy, or who simply does not want
/// it — and who should not have to change a system-wide accessibility setting to say so.
enum MotionLevel: String, CaseIterable, Identifiable {
    /// Everything: transforms, stagger, the window growing into place.
    case full
    /// Fades only. Nothing moves or scales, nothing waits its turn.
    case reduced
    /// Instant.
    case none

    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: return "Full"
        case .reduced: return "Reduced"
        case .none: return "None"
        }
    }
}

enum BoardDensity: String, CaseIterable, Identifiable {
    case comfortable, dense
    var id: String { rawValue }
    var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .dense: return "Dense"
        }
    }
    var keyWidth: CGFloat { self == .dense ? 70 : 88 }
    var keyHeight: CGFloat { self == .dense ? 40 : 48 }
}

// MARK: - Hotkey

struct HotkeyCombo: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32

    /// Default launch key: ⌥⌘A.
    ///
    /// Picked from an audit of the tools a developer is most likely to have running.
    /// ⌥⌘A is unbound in Spotlight, Raycast, Alfred, VS Code, Xcode, iTerm2, Ghostty,
    /// JetBrains, Docker, tmux, Chrome and DevTools, Slack, Notion, 1Password,
    /// CleanShot, Rectangle, and Magnet. Its one collision is Finder's Edit > Deselect
    /// All, which is a menu key equivalent and so only applies while Finder is
    /// frontmost. It is also the rare case where the ergonomic pick and the mnemonic
    /// pick agree: ⌥ and ⌘ are an adjacent thumb roll, and A is for alias.
    static let fallbackDefault = HotkeyCombo(keyCode: UInt32(kVK_ANSI_A),
                                             modifiers: UInt32(optionKey | cmdKey))

    /// macOS 15.0 requires every hotkey registration to include at least one modifier
    /// that is not Shift or Option. Combinations built only from ⌥ and ⇧ fail with
    /// -9868 (eventInternalErr), so they are rejected before they are ever stored.
    var isRegisterable: Bool {
        modifiers & UInt32(cmdKey | controlKey) != 0
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-",
            kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        ]
        return map[Int(keyCode)] ?? "key \(keyCode)"
    }

    /// Translates an AppKit modifier flag set into the Carbon mask the hotkey API wants.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }
}

// MARK: - Store

/// UserDefaults-backed settings. A single shared instance because the popover, the
/// settings window, and the parser all need to agree, and there is no scenario where
/// two differing copies would be correct.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Where settings are stored.
    ///
    /// `ALIASBAR_DEFAULTS_SUITE` redirects them into a named suite instead of the
    /// standard domain. The screenshot and video harnesses drive a real `AppSettings`
    /// to pose the UI, and every property has a `didSet` that persists — so without
    /// this they would silently rewrite the actual user's theme, result cap, and rc
    /// path. That is not hypothetical: it happened while building v0.2.
    static let store: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["ALIASBAR_DEFAULTS_SUITE"],
           !suite.isEmpty,
           let scratch = UserDefaults(suiteName: suite) {
            return scratch
        }
        return UserDefaults.standard
    }()

    private let defaults: UserDefaults

    private enum Key {
        static let enterAction = "enterAction"
        static let afterAction = "afterAction"
        static let defaultView = "defaultView"
        static let searchScope = "searchScope"
        static let sortOrder = "sortOrder"
        static let appearance = "appearance"
        static let savedPresets = "savedPresets"
        static let followsSystemAppearance = "followsSystemAppearance"
        static let boardDensity = "boardDensity"
        static let motionLevel = "motionLevel"
        static let presentationStyle = "presentationStyle"
        static let rcPath = "rcPathOverride"
        static let showFunctions = "showFunctions"
        static let showAliases = "showAliases"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let resultLimit = "resultLimit"
        static let onboardingComplete = "onboardingComplete"
        static let hasEverPasted = "hasEverPasted"
        static let historyUsageRankingEnabled = "historyUsageRankingEnabled"
        static let promptFeaturesEnabled = "promptFeaturesEnabled"
        static let hasShownPromptHint = "hasShownPromptHint"
        static let clipboardMonitoring = "clipboardMonitoring"
        static let clipboardPersistence = "clipboardPersistence"
        static let clipboardInSyncFile = "clipboardInSyncFile"
        static let syncFileURL = "syncFileURL"
        static let inlineExpansionEnabled = "inlineExpansionEnabled"
    }

    // MARK: Behaviour

    @Published var enterAction: EnterAction {
        didSet {
            defaults.set(enterAction.rawValue, forKey: Key.enterAction)
            syncCoordinator?.push(.enterAction)
        }
    }
    @Published var afterAction: AfterAction {
        didSet {
            defaults.set(afterAction.rawValue, forKey: Key.afterAction)
            syncCoordinator?.push(.afterAction)
        }
    }
    @Published var defaultView: ViewMode {
        didSet {
            defaults.set(defaultView.rawValue, forKey: Key.defaultView)
            syncCoordinator?.push(.defaultView)
        }
    }
    @Published var searchScope: SearchScope {
        didSet {
            defaults.set(searchScope.rawValue, forKey: Key.searchScope)
            syncCoordinator?.push(.searchScope)
        }
    }
    @Published var sortOrder: SortOrder {
        didSet {
            defaults.set(sortOrder.rawValue, forKey: Key.sortOrder)
            syncCoordinator?.push(.sortOrder)
        }
    }

    // MARK: Appearance

    /// The look currently in use. Always a *working copy*: picking a preset copies its
    /// values in, and every subsequent tweak edits this rather than the preset. That is
    /// what lets someone start from Clay, change the accent, and still have Clay mean
    /// Clay tomorrow.
    @Published var appearance: Appearance {
        didSet {
            persist(appearance, forKey: Key.appearance)
            syncCoordinator?.push(.appearance)
        }
    }

    /// Looks the user saved. The built-in three are not in here — they are code, they
    /// cannot be edited, and they cannot be deleted.
    @Published var savedPresets: [Appearance] {
        didSet {
            persist(savedPresets, forKey: Key.savedPresets)
            syncCoordinator?.pushPresets()
        }
    }

    /// When true and the current look defines a second ground, the window follows macOS
    /// between light and dark.
    @Published var followsSystemAppearance: Bool {
        didSet { defaults.set(followsSystemAppearance, forKey: Key.followsSystemAppearance) }
    }

    /// Whether macOS is currently in dark mode. Not persisted — it is a reading, not a
    /// setting. `App` keeps it current; the initial value is read at launch.
    @Published var systemIsDark: Bool = AppSettings.readSystemIsDark()

    static func readSystemIsDark() -> Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Every look available to pick, built-ins first.
    var allPresets: [Appearance] { Appearance.builtIns + savedPresets }

    /// The theme the views render, resolved against the system appearance if the look
    /// opted into following it.
    func theme(systemIsDark: Bool) -> Theme {
        Theme.derive(from: appearance,
                     dark: followsSystemAppearance && appearance.darkGround != nil && systemIsDark)
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
    @Published var boardDensity: BoardDensity {
        didSet { defaults.set(boardDensity.rawValue, forKey: Key.boardDensity) }
    }
    @Published var motionLevel: MotionLevel {
        didSet { defaults.set(motionLevel.rawValue, forKey: Key.motionLevel) }
    }
    @Published var presentationStyle: PresentationStyle {
        didSet { defaults.set(presentationStyle.rawValue, forKey: Key.presentationStyle) }
    }

    // MARK: Content

    /// Persisted rc path. Durable across launches, unlike the environment variable,
    /// which a login item does not inherit.
    @Published var rcPathOverride: String? {
        didSet {
            if let value = rcPathOverride, !value.isEmpty {
                defaults.set(value, forKey: Key.rcPath)
            } else {
                defaults.removeObject(forKey: Key.rcPath)
            }
        }
    }
    @Published var showFunctions: Bool {
        didSet { defaults.set(showFunctions, forKey: Key.showFunctions) }
    }
    @Published var showAliases: Bool {
        didSet { defaults.set(showAliases, forKey: Key.showAliases) }
    }
    @Published var resultLimit: Int {
        didSet {
            defaults.set(resultLimit, forKey: Key.resultLimit)
            syncCoordinator?.push(.resultLimit)
        }
    }

    // MARK: First run

    /// Whether the first-run flow has been finished *or* dismissed. Either counts:
    /// it is shown once, and closing it halfway is a decision, not an accident to
    /// be corrected by showing it again.
    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Key.onboardingComplete) }
    }

    /// Whether a paste has ever actually been delivered. This is what separates
    /// "never granted Accessibility" from "the grant was silently voided by a
    /// rebuild" — only the second deserves a warning banner.
    @Published var hasEverPasted: Bool {
        didSet { defaults.set(hasEverPasted, forKey: Key.hasEverPasted) }
    }

    /// One of onboarding's three found-treasure checkboxes: whether usage counts
    /// from shell history are allowed to influence ranking. On by default. Not yet
    /// consulted anywhere — the same "declare now, wire later" pattern
    /// `clipboardPersistence` already shipped with; a later slice gates
    /// `EntryStore`'s ranking behind it.
    @Published var historyUsageRankingEnabled: Bool {
        didSet { defaults.set(historyUsageRankingEnabled, forKey: Key.historyUsageRankingEnabled) }
    }
    /// The second found-treasure checkbox: whether the AI-native side of the app
    /// (the prompt dialect, Claude Code delivery) is something this user wants
    /// surfaced at all. Onboarding pre-checks it only when its scan actually finds
    /// `~/.claude`; the stored default here is `true` so an upgrade that skips
    /// onboarding entirely does not silently switch existing prompt features off.
    /// Like `historyUsageRankingEnabled`, not yet consulted anywhere.
    @Published var promptFeaturesEnabled: Bool {
        didSet { defaults.set(promptFeaturesEnabled, forKey: Key.promptFeaturesEnabled) }
    }

    /// Whether the post-onboarding "want the same for your AI prompts? ⌘I" hint has
    /// already fired once. Same one-shot shape as `hasEverPasted`: a fact recorded
    /// the moment it happens, checked before it is ever shown again.
    @Published var hasShownPromptHint: Bool {
        didSet { defaults.set(hasShownPromptHint, forKey: Key.hasShownPromptHint) }
    }

    // MARK: Clipboard

    /// Whether `ClipboardMonitor` polls the pasteboard at all. On by default — off
    /// means AliasBar never reads the clipboard outside of its own deliveries.
    @Published var clipboardMonitoring: Bool {
        didSet { defaults.set(clipboardMonitoring, forKey: Key.clipboardMonitoring) }
    }
    /// Whether safe clips are written to disk. Off by default: when on,
    /// `ClipboardMonitor`'s history is persisted to `~/.aliasbar/clips.json` (see
    /// `ClipboardPersistenceController`); when off, clipboard content only ever
    /// lives in memory for the life of the app, and nothing under `~/.aliasbar`
    /// records a single byte of it.
    @Published var clipboardPersistence: Bool {
        didSet { defaults.set(clipboardPersistence, forKey: Key.clipboardPersistence) }
    }
    /// Whether persisted clips are also mirrored into the Sync file's "clips"
    /// collection (see `ClipboardSyncMirror`). Off by default, and meaningless while
    /// `clipboardPersistence` is off — there is nothing local yet to mirror.
    @Published var clipboardInSyncFile: Bool {
        didSet { defaults.set(clipboardInSyncFile, forKey: Key.clipboardInSyncFile) }
    }

    // MARK: Inline expansion

    /// Whether `ExpansionMonitor` runs a `CGEventTap` watching for snippet triggers at
    /// all. Off by default — the trust posture this whole feature is built on: no tap
    /// is ever created while this is false, not merely a disabled one sitting idle.
    /// Toggling it live starts or stops the real tap (see `SettingsView`'s Expansion
    /// section); this property only ever records the user's choice.
    @Published var inlineExpansionEnabled: Bool {
        didSet { defaults.set(inlineExpansionEnabled, forKey: Key.inlineExpansionEnabled) }
    }

    // MARK: Sync

    /// Where settings and presets roam to, if anywhere. `nil` means sync is off.
    ///
    /// LOCAL-ONLY (see `SettingsSync` for the full roaming boundary): this value could
    /// never itself be a roamed setting without contradiction — a shared document
    /// telling a second machine where sync lives on the *first* machine's disk is
    /// nonsense, and would make turning sync on somewhere new overwrite the very path
    /// that got it there.
    @Published var syncFileURL: URL? {
        didSet {
            persistSyncFileURL()
            // Reassigning the same path (e.g. SwiftUI re-publishing an unchanged
            // binding) must not tear down and rebuild the coordinator, which would
            // otherwise force a spurious re-merge on every redundant write.
            guard syncFileURL?.path != oldValue?.path else { return }
            syncCoordinator?.stop()
            syncCoordinator = nil
            syncError = nil
            activateSyncCoordinatorIfConfigured()
        }
    }

    /// The last problem enabling or reloading sync ran into, if any. Deliberately not
    /// persisted: a fresh launch gets a fresh chance rather than carrying a stale
    /// banner from a file that has since been fixed or moved.
    @Published var syncError: String?

    /// Owns the live read/merge/write/watch wiring for as long as `syncFileURL` is set.
    /// Not `@Published` — nothing renders from this directly, only from the settings it
    /// mutates and from `syncError`.
    private var syncCoordinator: SettingsSyncCoordinator?

    private func persistSyncFileURL() {
        if let value = syncFileURL, !value.path.isEmpty {
            defaults.set(value.path, forKey: Key.syncFileURL)
        } else {
            defaults.removeObject(forKey: Key.syncFileURL)
        }
    }

    /// Builds and starts the coordinator if `syncFileURL` is set. The one path both
    /// "sync was already on at the previous launch" (called once at the end of `init`,
    /// since property observers do not fire for values set during initialization) and
    /// "the user just turned sync on or repointed it" (called from `syncFileURL`'s
    /// `didSet`) go through, so enabling sync behaves identically either way.
    private func activateSyncCoordinatorIfConfigured() {
        guard let url = syncFileURL else { return }
        let coordinator = SettingsSyncCoordinator(settings: self, url: url)
        syncCoordinator = coordinator
        coordinator.enableAndStart()
    }

    /// Re-reads the sync file right now and applies it, without waiting for the
    /// debounced filesystem watcher. A no-op when sync is off. Exposed so tests (and a
    /// manual "check now" affordance) don't have to depend on real filesystem event
    /// timing to observe an external change landing.
    func reloadSyncNow() {
        syncCoordinator?.reloadNow()
    }

    // MARK: Hotkey

    @Published var hotkey: HotkeyCombo {
        didSet {
            defaults.set(Int(hotkey.keyCode), forKey: Key.hotkeyKeyCode)
            defaults.set(Int(hotkey.modifiers), forKey: Key.hotkeyModifiers)
        }
    }
    @Published var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled) }
    }

    /// `defaults` defaults to the shared, environment-aware store (see `AppSettings.store`)
    /// so `AppSettings.shared` behaves exactly as before. Tests pass an isolated
    /// `UserDefaults(suiteName:)` instance instead, so each test case gets a fresh
    /// `AppSettings` unentangled from the process-wide singleton — `.shared` can only
    /// ever be constructed once, which a sync feature with real merge/seed/reload
    /// state machines needs to exercise far more than once per test run.
    init(defaults: UserDefaults = AppSettings.store) {
        self.defaults = defaults
        // Reads a stored raw value, falling back when the key is absent or holds a
        // value from an older build. Free-standing rather than a method because `self`
        // is not usable until every stored property is initialized.
        let store = defaults
        func decode<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            guard let raw = store.string(forKey: key), let value = T(rawValue: raw) else {
                return fallback
            }
            return value
        }

        // Pasting straight into whatever regains focus is the default: the whole point
        // is that you are standing in a terminal about to type the alias yourself, so
        // landing the text there beats landing it on the clipboard. Falls back to
        // copying, with a prompt, when Accessibility permission is not granted.
        enterAction = decode(Key.enterAction, EnterAction.pasteName)
        afterAction = decode(Key.afterAction, AfterAction.close)
        defaultView = decode(Key.defaultView, ViewMode.find)
        searchScope = decode(Key.searchScope, SearchScope.everything)
        sortOrder = decode(Key.sortOrder, SortOrder.usage)
        // A look stored by an older build, or by a build with a different set of fields,
        // decodes to nil and falls back rather than refusing to launch. Appearance is not
        // worth crashing over.
        func decodeJSON<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = store.data(forKey: key),
                  let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return value
        }
        appearance = decodeJSON(Key.appearance, Appearance.graphite)
        savedPresets = decodeJSON(Key.savedPresets, [Appearance]())
        // Off by default. Picking Clay should give you Clay, not its dark variant because
        // macOS happens to be dark this evening — two of the three looks are built on a
        // light ground and choosing one is a choice, not an accident to be corrected.
        followsSystemAppearance = store.object(forKey: Key.followsSystemAppearance) as? Bool ?? false
        boardDensity = decode(Key.boardDensity, BoardDensity.comfortable)
        motionLevel = decode(Key.motionLevel, MotionLevel.full)
        // Centred by default. The menu bar popover is the fallback, not the other way
        // round: on a laptop with a full menu bar the icon is not reliably placed, and
        // the hotkey is how this gets opened in practice anyway.
        presentationStyle = decode(Key.presentationStyle, PresentationStyle.palette)

        rcPathOverride = store.string(forKey: Key.rcPath)

        // `bool(forKey:)` returns false for an absent key, which would silently hide
        // every entry on first launch. These have to default to true explicitly.
        showFunctions = store.object(forKey: Key.showFunctions) as? Bool ?? true
        showAliases = store.object(forKey: Key.showAliases) as? Bool ?? true
        hotkeyEnabled = store.object(forKey: Key.hotkeyEnabled) as? Bool ?? true
        onboardingComplete = store.object(forKey: Key.onboardingComplete) as? Bool ?? false
        hasEverPasted = store.object(forKey: Key.hasEverPasted) as? Bool ?? false
        historyUsageRankingEnabled = store.object(forKey: Key.historyUsageRankingEnabled) as? Bool ?? true
        promptFeaturesEnabled = store.object(forKey: Key.promptFeaturesEnabled) as? Bool ?? true
        hasShownPromptHint = store.object(forKey: Key.hasShownPromptHint) as? Bool ?? false
        resultLimit = store.object(forKey: Key.resultLimit) as? Int ?? 6

        // Off until the user turns it on. Watching the clipboard is this product's
        // trust wedge; starting the read silently on launch would undercut it.
        clipboardMonitoring = store.object(forKey: Key.clipboardMonitoring) as? Bool ?? false
        clipboardPersistence = store.object(forKey: Key.clipboardPersistence) as? Bool ?? false
        clipboardInSyncFile = store.object(forKey: Key.clipboardInSyncFile) as? Bool ?? false

        // Off until the user turns it on, for the same reason clipboard monitoring is:
        // a global keystroke tap is this feature's trust wedge, and starting it
        // silently on launch would undercut the whole point of asking first.
        inlineExpansionEnabled = store.object(forKey: Key.inlineExpansionEnabled) as? Bool ?? false

        if let path = store.string(forKey: Key.syncFileURL), !path.isEmpty {
            syncFileURL = URL(fileURLWithPath: path)
        } else {
            syncFileURL = nil
        }

        if let code = store.object(forKey: Key.hotkeyKeyCode) as? Int,
           let mods = store.object(forKey: Key.hotkeyModifiers) as? Int {
            hotkey = HotkeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods))
        } else {
            hotkey = .fallbackDefault
        }

        // Property observers do not fire for values assigned during `init`, so a
        // `syncFileURL` carried over from a previous launch would otherwise sit there
        // inert with no coordinator ever built for it. This is the one call site for
        // that — `syncFileURL`'s own `didSet` calls the same method for every later
        // change, so "sync was already on" and "sync was just turned on" both start
        // the coordinator through identical code.
        activateSyncCoordinatorIfConfigured()
    }

    /// One-time migration: if the user launched with ALIASBAR_ZSHRC set and has no
    /// persisted path yet, adopt the environment value so their configuration survives
    /// the next reboot instead of silently reverting to ~/.zshrc.
    func adoptEnvironmentPathIfUnset() {
        guard rcPathOverride == nil,
              let env = ProcessInfo.processInfo.environment["ALIASBAR_ZSHRC"],
              !env.isEmpty
        else { return }
        rcPathOverride = env
    }
}
