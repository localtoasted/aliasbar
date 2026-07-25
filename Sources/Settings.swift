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

enum SearchScope: String, CaseIterable, Identifiable {
    case name, nameComment, everything
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name only"
        case .nameComment: return "Name and comment"
        case .everything: return "Name, comment, and command"
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

    private let defaults = UserDefaults.standard

    private enum Key {
        static let enterAction = "enterAction"
        static let afterAction = "afterAction"
        static let defaultView = "defaultView"
        static let searchScope = "searchScope"
        static let sortOrder = "sortOrder"
        static let theme = "theme"
        static let boardDensity = "boardDensity"
        static let rcPath = "rcPathOverride"
        static let showFunctions = "showFunctions"
        static let showAliases = "showAliases"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let resultLimit = "resultLimit"
    }

    // MARK: Behaviour

    @Published var enterAction: EnterAction {
        didSet { defaults.set(enterAction.rawValue, forKey: Key.enterAction) }
    }
    @Published var afterAction: AfterAction {
        didSet { defaults.set(afterAction.rawValue, forKey: Key.afterAction) }
    }
    @Published var defaultView: ViewMode {
        didSet { defaults.set(defaultView.rawValue, forKey: Key.defaultView) }
    }
    @Published var searchScope: SearchScope {
        didSet { defaults.set(searchScope.rawValue, forKey: Key.searchScope) }
    }
    @Published var sortOrder: SortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: Key.sortOrder) }
    }

    // MARK: Appearance

    @Published var themeName: ThemeName {
        didSet { defaults.set(themeName.rawValue, forKey: Key.theme) }
    }
    @Published var boardDensity: BoardDensity {
        didSet { defaults.set(boardDensity.rawValue, forKey: Key.boardDensity) }
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
        didSet { defaults.set(resultLimit, forKey: Key.resultLimit) }
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

    private init() {
        // Reads a stored raw value, falling back when the key is absent or holds a
        // value from an older build. Free-standing rather than a method because `self`
        // is not usable until every stored property is initialized.
        let store = UserDefaults.standard
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
        themeName = decode(Key.theme, ThemeName.slate)
        boardDensity = decode(Key.boardDensity, BoardDensity.comfortable)

        rcPathOverride = store.string(forKey: Key.rcPath)

        // `bool(forKey:)` returns false for an absent key, which would silently hide
        // every entry on first launch. These have to default to true explicitly.
        showFunctions = store.object(forKey: Key.showFunctions) as? Bool ?? true
        showAliases = store.object(forKey: Key.showAliases) as? Bool ?? true
        hotkeyEnabled = store.object(forKey: Key.hotkeyEnabled) as? Bool ?? true
        resultLimit = store.object(forKey: Key.resultLimit) as? Int ?? 6

        if let code = store.object(forKey: Key.hotkeyKeyCode) as? Int,
           let mods = store.object(forKey: Key.hotkeyModifiers) as? Int {
            hotkey = HotkeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods))
        } else {
            hotkey = .fallbackDefault
        }
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
