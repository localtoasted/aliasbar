import SwiftUI
import ServiceManagement

/// Settings live in their own window, never in the popover.
///
/// The popover has a budget of about a second and a half, and a settings panel inside it
/// competes for exactly the space the results need. Anything the user touches once a
/// month does not belong in the thing they open forty times a day.
///
/// The whole window is drawn from the active theme rather than from stock `Form`
/// styling. A settings screen that ignores the theme makes the theme feel like a costume
/// on top of the app instead of the app's actual appearance.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var section: SettingsSection = .behaviour
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var recordingHotkey = false
    @State private var hotkeyError: String?

    private var theme: Theme { Theme.current(settings.themeName) }

    enum SettingsSection: String, CaseIterable, Identifiable {
        case behaviour, appearance, content, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .behaviour: return "Behaviour"
            case .appearance: return "Appearance"
            case .content: return "Content"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .behaviour: return "keyboard"
            case .appearance: return "paintpalette"
            case .content: return "doc.text"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(theme.rule.opacity(0.5)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch section {
                    case .behaviour: behaviourSection
                    case .appearance: appearanceSection
                    case .content: contentSection
                    case .about: aboutSection
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 720, height: 540)
        .background(theme.background)
        .environment(\.theme, theme)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                AliasBarMark(size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("AliasBar")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.text)
                    Text("v0.2")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)

            ForEach(SettingsSection.allCases) { item in
                let active = section == item
                HStack(spacing: 8) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11))
                        .frame(width: 16)
                        .foregroundStyle(active ? theme.accent : theme.dim)
                    Text(item.label)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? theme.text : theme.dim)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(active ? theme.selectionFill : .clear,
                            in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .contentShape(Rectangle())
                .onTapGesture { section = item }
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 186)
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("When you pick an alias") {
                SettingsRow("Enter", hint: "The one that matters. You are usually about to type the alias yourself.") {
                    ThemedPicker(selection: $settings.enterAction,
                                 options: EnterAction.allCases,
                                 label: { $0.label })
                }
                if settings.enterAction.needsAccessibility {
                    PermissionNotice(granted: Typist.isTrusted)
                }
                SettingsRow("Afterwards", hint: nil) {
                    ThemedSegments(selection: $settings.afterAction,
                                   options: AfterAction.allCases,
                                   label: { $0.label })
                }
                SettingsRow("⌘⏎", hint: "Always the other half of the pair, so both are one keystroke away.") {
                    Text(settings.enterAction.secondary.label)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.faint)
                }
            }

            SettingsGroup("Opening AliasBar") {
                SettingsRow("Shortcut", hint: "Uses the system hotkey API, so AliasBar is told only that this one combination fired and never sees any other keystroke. No permission needed.") {
                    HStack(spacing: 8) {
                        Button {
                            recordingHotkey.toggle()
                            HotkeyRecorder.shared.isRecording = recordingHotkey
                            HotkeyRecorder.shared.onCapture = { combo in
                                recordingHotkey = false
                                HotkeyRecorder.shared.isRecording = false
                                guard combo.isRegisterable else {
                                    hotkeyError = "Include ⌘ or ⌃. macOS no longer accepts shortcuts built only from ⌥ and ⇧."
                                    return
                                }
                                // Register first, persist only on success. Storing the
                                // combination up front would leave the preference
                                // claiming a shortcut that never took effect, and the
                                // app would retry that dead combination on every future
                                // launch while the working one stayed unregistered.
                                let ok = HotkeyManager.shared.register(combo) {
                                    NotificationCenter.default.post(name: .aliasBarHotkeyFired,
                                                                    object: nil)
                                }
                                if ok {
                                    settings.hotkey = combo
                                    hotkeyError = nil
                                } else {
                                    hotkeyError = "macOS refused that combination. Still using \(settings.hotkey.displayString)."
                                }
                            }
                        } label: {
                            Text(recordingHotkey ? "Press keys…" : settings.hotkey.displayString)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(recordingHotkey ? theme.accent : theme.text)
                                .frame(minWidth: 96)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(theme.surface,
                                            in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                                    .strokeBorder(recordingHotkey ? theme.accent
                                                                  : theme.rule.opacity(0.7),
                                                  lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!settings.hotkeyEnabled)

                        ThemedToggle(isOn: $settings.hotkeyEnabled, label: "Enabled")
                    }
                }
                if let hotkeyError {
                    NoticeText(hotkeyError, tone: .warning)
                }
            }

            SettingsGroup("Startup") {
                SettingsRow("Opens on", hint: nil) {
                    ThemedSegments(selection: $settings.defaultView,
                                   options: ViewMode.allCases,
                                   label: { $0.label })
                }
                SettingsRow("Launch at login", hint: nil) {
                    ThemedToggle(isOn: $launchAtLogin, label: launchAtLogin ? "On" : "Off")
                        .onChange(of: launchAtLogin) { enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
                if let loginError { NoticeText(loginError, tone: .warning) }
            }
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(ThemeName.allCases) { name in
                        ThemeSwatch(name: name, selected: settings.themeName == name)
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    settings.themeName = name
                                }
                            }
                    }
                }
            }

            SettingsGroup("Layout") {
                SettingsRow("Board density", hint: nil) {
                    ThemedSegments(selection: $settings.boardDensity,
                                   options: BoardDensity.allCases,
                                   label: { $0.label })
                }
                SettingsRow("Results in Find",
                            hint: "Find caps results on purpose. Past six or so you are reading a list instead of recognising an answer, which is slower than typing one more character.") {
                    Stepper(value: $settings.resultLimit, in: 3...12) {
                        Text("\(settings.resultLimit)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.text)
                    }
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: Content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("Shell config") {
                SettingsRow("File",
                            hint: "Stored in preferences, so it survives a reboot and applies when AliasBar launches at login.") {
                    HStack(spacing: 8) {
                        TextField("~/.zshrc", text: Binding(
                            get: { settings.rcPathOverride ?? "" },
                            set: { settings.rcPathOverride = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(theme.surface,
                                    in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(theme.rule.opacity(0.6), lineWidth: 1))

                        ThemedButton("Choose") { chooseFile() }
                    }
                }
                NoticeText("Reading \(ZshrcParser.displayPath)", tone: .info)
            }

            SettingsGroup("What to show") {
                SettingsRow("Include", hint: nil) {
                    HStack(spacing: 8) {
                        ThemedToggle(isOn: $settings.showAliases, label: "Aliases")
                        ThemedToggle(isOn: $settings.showFunctions, label: "Functions")
                    }
                }
                SettingsRow("Search matches", hint: nil) {
                    ThemedPicker(selection: $settings.searchScope,
                                 options: SearchScope.allCases,
                                 label: { $0.label })
                }
                SettingsRow("Sort by", hint: nil) {
                    ThemedPicker(selection: $settings.sortOrder,
                                 options: SortOrder.allCases,
                                 label: { $0.label })
                }
            }

            SettingsGroup("Usage data") {
                NoticeText("Counts come from ~/.zsh_history, read locally and never written to or sent anywhere. They power ranking and the Never run bucket.",
                           tone: .info)
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AliasBarMark(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AliasBar")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(theme.text)
                    Text("Every alias and shell function, one keystroke away.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.dim)
                }
            }

            SettingsGroup("Privacy") {
                NoticeText("AliasBar has no network access of any kind. It reads two files on your disk: your shell config, and your shell history for usage counts. Neither is ever sent anywhere.",
                           tone: .info)
            }

            SettingsGroup("Keyboard") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Self.shortcutReference, id: \.0) { keys, what in
                        HStack(spacing: 10) {
                            Text(keys)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(theme.dim)
                                .frame(width: 76, alignment: .leading)
                            Text(what)
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.dim)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private static let shortcutReference: [(String, String)] = [
        ("⌥⌘A", "open from anywhere"),
        ("↑ ↓ ⌃n ⌃p", "move the selection"),
        ("⏎ / ⌘⏎", "primary and secondary action"),
        ("⌘1 ⌘2 ⌘3", "Find, Board, Manage"),
        ("? ! @ #", "graveyard, conflicts, by file, stats"),
        ("⌘N / ⌘E", "new alias, edit alias"),
        ("esc", "dismiss and hand focus back"),
    ]

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            settings.rcPathOverride = url.path
        }
    }
}

// MARK: - Themed settings components

struct SettingsGroup<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .kerning(0.9)
                .foregroundStyle(theme.faint)
            VStack(alignment: .leading, spacing: 13) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: theme.cornerRadius + 3))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 3)
                .strokeBorder(theme.rule.opacity(0.4), lineWidth: 1))
        }
    }
}

struct SettingsRow<Control: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let hint: String?
    @ViewBuilder let control: Control

    init(_ title: String, hint: String?, @ViewBuilder control: () -> Control) {
        self.title = title
        self.hint = hint
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.text)
                    .frame(width: 116, alignment: .leading)
                control
                Spacer(minLength: 0)
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 128)
            }
        }
    }
}

/// A dropdown drawn from the theme rather than from the system picker chrome.
struct ThemedPicker<T: Hashable & Identifiable>: View {
    @Environment(\.theme) private var theme
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button(label(option)) { selection = option }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label(selection))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.faint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.rule.opacity(0.6), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Segmented control for two- and three-way choices.
struct ThemedSegments<T: Hashable & Identifiable>: View {
    @Environment(\.theme) private var theme
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let active = selection == option
                Text(label(option))
                    .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? theme.text : theme.dim)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(active ? theme.selectionFill : .clear,
                                in: RoundedRectangle(cornerRadius: theme.cornerRadius - 1))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = option }
            }
        }
        .padding(2)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(theme.rule.opacity(0.6), lineWidth: 1))
    }
}

struct ThemedToggle: View {
    @Environment(\.theme) private var theme
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? theme.accent : theme.rule.opacity(0.55))
                    .frame(width: 30, height: 17)
                Circle()
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .padding(.horizontal, 2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.dim)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.13)) { isOn.toggle() } }
    }
}

struct ThemedButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .strokeBorder(theme.rule.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct NoticeText: View {
    @Environment(\.theme) private var theme
    enum Tone { case info, warning }
    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 9.5))
                .foregroundStyle(tone == .warning ? .orange : theme.faint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(tone == .warning ? .orange : theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct PermissionNotice: View {
    @Environment(\.theme) private var theme
    let granted: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(granted ? .green : .orange)
            Text(granted
                 ? "Accessibility granted. AliasBar can type into other apps."
                 : "Typing into another app needs Accessibility. Until it's granted, AliasBar copies instead.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            if !granted {
                ThemedButton("Grant") { Typist.requestTrust() }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background((granted ? Color.green : Color.orange).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius))
    }
}

/// Live preview of a theme, rendered in that theme rather than described in words.
struct ThemeSwatch: View {
    @Environment(\.theme) private var current
    let name: ThemeName
    let selected: Bool

    private var t: Theme { Theme.current(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("@")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.isLight ? Color.white : t.background)
                    .frame(width: 14, height: 14)
                    .background(t.aliasTint, in: RoundedRectangle(cornerRadius: t.cornerRadius))
                Text("gs")
                    .font(.system(size: 11.5, weight: .semibold, design: t.nameDesign))
                    .foregroundStyle(t.text)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(t.accent)
                }
            }
            HStack(spacing: 4) {
                Text("$")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.accent)
                Text("git status -sb")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(t.dim)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(t.surface, in: RoundedRectangle(cornerRadius: t.cornerRadius))

            Text(name.label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(t.text)
            Text(name.blurb)
                .font(.system(size: 9))
                .foregroundStyle(t.faint)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: t.cornerRadius + 3)
                .fill(t.usesMaterial ? AnyShapeStyle(.ultraThinMaterial)
                                     : AnyShapeStyle(t.background))
        )
        .overlay(
            RoundedRectangle(cornerRadius: t.cornerRadius + 3)
                .strokeBorder(selected ? current.accent : current.rule.opacity(0.45),
                              lineWidth: selected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Hotkey recording

/// Captures the next key combination the user presses while the settings window is
/// showing the recorder. Uses a *local* monitor, which sees only this app's events and
/// therefore needs no permission.
final class HotkeyRecorder {
    static let shared = HotkeyRecorder()
    var isRecording = false
    var onCapture: ((HotkeyCombo) -> Void)?
    private var monitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            let mods = HotkeyCombo.carbonModifiers(from: event.modifierFlags)
            // A bare key with no modifier would fire constantly during normal typing.
            guard mods != 0 else { return nil }
            self.onCapture?(HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods))
            return nil
        }
    }
}

extension Notification.Name {
    static let aliasBarHotkeyFired = Notification.Name("aliasBarHotkeyFired")
}
