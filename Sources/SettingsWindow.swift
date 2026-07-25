import SwiftUI
import ServiceManagement

/// Settings live in their own window, never in the popover.
///
/// The popover has a budget of about a second and a half, and a settings panel inside it
/// competes for exactly the space the results need. Anything the user touches once a
/// month does not belong in the thing they open forty times a day.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var recordingHotkey = false
    @State private var hotkeyError: String?

    private var theme: Theme { Theme.current(settings.themeName) }

    var body: some View {
        TabView {
            behaviourTab
                .tabItem { Label("Behaviour", systemImage: "keyboard") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            contentTab
                .tabItem { Label("Content", systemImage: "doc.text") }
        }
        .frame(width: 470, height: 400)
    }

    // MARK: Behaviour

    private var behaviourTab: some View {
        Form {
            Section {
                Picker("Enter does", selection: $settings.enterAction) {
                    ForEach(EnterAction.allCases) { Text($0.label).tag($0) }
                }
                if settings.enterAction.needsAccessibility {
                    HStack(spacing: 6) {
                        Image(systemName: Typist.isTrusted ? "checkmark.circle.fill"
                                                           : "exclamationmark.triangle.fill")
                            .foregroundStyle(Typist.isTrusted ? .green : .orange)
                        Text(Typist.isTrusted
                             ? "Accessibility permission granted."
                             : "Typing into another app needs Accessibility permission.")
                            .font(.system(size: 10.5))
                        if !Typist.isTrusted {
                            Button("Grant") { Typist.requestTrust() }
                                .controlSize(.small)
                        }
                    }
                }
                Picker("⌘⏎ does", selection: .constant(settings.enterAction.secondary)) {
                    Text(settings.enterAction.secondary.label)
                        .tag(settings.enterAction.secondary)
                }
                .disabled(true)
                .help("The secondary action is always the other half of the pair, so both are always one keystroke away.")

                Picker("Afterwards", selection: $settings.afterAction) {
                    ForEach(AfterAction.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("When you pick an alias")
            }

            Section {
                Toggle("Global hotkey", isOn: $settings.hotkeyEnabled)
                HStack {
                    Text("Shortcut")
                    Spacer()
                    Button {
                        recordingHotkey.toggle()
                        HotkeyRecorder.shared.isRecording = recordingHotkey
                        HotkeyRecorder.shared.onCapture = { combo in
                            recordingHotkey = false
                            HotkeyRecorder.shared.isRecording = false
                            // Since macOS 15.0 a registration must carry a modifier that
                            // is not Shift or Option, or it fails with -9868.
                            guard combo.isRegisterable else {
                                hotkeyError = "Include ⌘ or ⌃. macOS no longer accepts shortcuts built only from ⌥ and ⇧."
                                return
                            }
                            settings.hotkey = combo
                            hotkeyError = HotkeyManager.shared.register(combo) {
                                NotificationCenter.default.post(name: .aliasBarHotkeyFired,
                                                                object: nil)
                            } ? nil : "macOS refused that combination. Try another."
                        }
                    } label: {
                        Text(recordingHotkey ? "Press keys…" : settings.hotkey.displayString)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(minWidth: 80)
                    }
                    .disabled(!settings.hotkeyEnabled)
                }
                if let hotkeyError {
                    Text(hotkeyError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
                Text("Uses the system hotkey API, so AliasBar never sees any keystroke other than this one and needs no permission to register it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Opening AliasBar")
            }

            Section {
                Picker("Opens on", selection: $settings.defaultView) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
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
                if let loginError {
                    Text(loginError).font(.system(size: 10.5)).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Appearance

    private var appearanceTab: some View {
        Form {
            Section {
                Picker("Theme", selection: $settings.themeName) {
                    ForEach(ThemeName.allCases) { name in
                        Text("\(name.label) — \(name.blurb)").tag(name)
                    }
                }
                themePreview
            } header: {
                Text("Theme")
            }

            Section {
                Picker("Board density", selection: $settings.boardDensity) {
                    ForEach(BoardDensity.allCases) { Text($0.label).tag($0) }
                }
                Stepper("Show up to \(settings.resultLimit) results in Find",
                        value: $settings.resultLimit, in: 3...12)
                Text("Find deliberately caps results. Past six or so you are reading a list instead of recognising an answer, which is slower than typing one more character.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var themePreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("@")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.isLight ? Color.white : theme.background)
                    .frame(width: 16, height: 16)
                    .background(theme.aliasTint,
                                in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                Text("gs")
                    .font(.system(size: 13, weight: .semibold, design: theme.nameDesign))
                    .foregroundStyle(theme.text)
                Text("git status, short")
                    .font(.system(size: 10.5, design: theme.bodyDesign))
                    .foregroundStyle(theme.dim)
                Spacer()
            }
            HStack(spacing: 5) {
                Text("$").font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.accent)
                Text("git status -sb")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.dim)
                Spacer()
            }
        }
        .padding(10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 2))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
            .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
        .padding(.vertical, 4)
        .background(theme.background)
    }

    // MARK: Content

    private var contentTab: some View {
        Form {
            Section {
                HStack {
                    TextField("~/.zshrc", text: Binding(
                        get: { settings.rcPathOverride ?? "" },
                        set: { settings.rcPathOverride = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    Button("Choose…") { chooseFile() }
                }
                Text("Currently reading \(ZshrcParser.displayPath). Stored in preferences, so it survives a reboot and applies when AliasBar launches at login.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Shell config")
            }

            Section {
                Toggle("Show aliases", isOn: $settings.showAliases)
                Toggle("Show functions", isOn: $settings.showFunctions)
                Picker("Search matches", selection: $settings.searchScope) {
                    ForEach(SearchScope.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sort by", selection: $settings.sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Text("Usage counts come from ~/.zsh_history, read locally and never written to or sent anywhere. They power ranking and the Never run bucket.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Usage data")
            }
        }
        .formStyle(.grouped)
    }

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
