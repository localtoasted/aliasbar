import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

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
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var expansionMonitor = ExpansionMonitor.shared
    // Behaviour, unless a harness asked for another section. The appearance section is
    // otherwise four clicks and a keystroke away from a cold launch, which is four clicks
    // more than a screenshot script can manage without Accessibility permission.
    @State private var section: SettingsSection =
        SettingsSection(rawValue: ProcessInfo.processInfo.environment["ALIASBAR_SETTINGS_SECTION"] ?? "")
        ?? .behaviour
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var recordingHotkey = false
    @State private var hotkeyError: String?
    @State private var savingPreset = false
    @State private var renaming = false
    @State private var newPresetName = ""
    @State private var transferNotice: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: Theme { settings.theme(systemIsDark: settings.systemIsDark) }

    // MARK: Appearance editing

    /// Edits the working copy in place. Every knob writes through this, so none of them
    /// has to know that a preset was ever involved.
    private func binding<T>(_ path: WritableKeyPath<Appearance, T>) -> Binding<T> {
        Binding(
            get: { settings.appearance[keyPath: path] },
            set: { settings.appearance[keyPath: path] = $0 }
        )
    }

    /// True when the working copy no longer matches any preset — the state where "Save
    /// as…" is the only thing keeping the user's changes.
    private var isEditedCopy: Bool {
        !settings.allPresets.contains(settings.appearance)
    }

    private var suggestedPresetName: String {
        let base = settings.appearance.isBuiltIn
            ? "\(settings.appearance.name) mine"
            : settings.appearance.name
        let taken = Set(settings.allPresets.map(\.name))
        if !taken.contains(base) { return base }
        for n in 2...99 where !taken.contains("\(base) \(n)") { return "\(base) \(n)" }
        return base
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let saved = settings.appearance.copy(named: name, id: UUID().uuidString)
        settings.savedPresets.append(saved)
        settings.appearance = saved
        savingPreset = false
        transferNotice = nil
    }

    /// One field, shared by saving and renaming: the same shape asking for the same
    /// thing, and two of them on screen at once would be a puzzle rather than a choice.
    private var presetNameField: some View {
        TextField("Name", text: $newPresetName)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(theme.text)
            .frame(width: 150)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.rule.opacity(0.6), lineWidth: 1))
    }

    /// Where the current look sits among the user's own. -1 when it is a built-in or an
    /// unsaved edit, which is what disables the reorder buttons.
    private var presetIndex: Int {
        settings.savedPresets.firstIndex { $0.id == settings.appearance.id } ?? -1
    }

    private func renamePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = settings.savedPresets.firstIndex(where: {
            $0.id == settings.appearance.id
        }) else { return }
        settings.savedPresets[index].name = name
        settings.appearance.name = name
        renaming = false
    }

    private func move(by offset: Int) {
        let index = presetIndex
        let target = index + offset
        guard index >= 0, target >= 0, target < settings.savedPresets.count else { return }
        settings.savedPresets.swapAt(index, target)
    }

    private func deletePreset() {
        let id = settings.appearance.id
        settings.savedPresets.removeAll { $0.id == id }
        settings.appearance = Appearance.builtIns.first ?? .graphite
    }

    private func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let imported = PresetTransfer.importing(text, id: UUID().uuidString) else {
            transferNotice = "The clipboard does not hold an AliasBar look."
            return
        }
        settings.savedPresets.append(imported)
        settings.appearance = imported
        transferNotice = "Added “\(imported.name)”."
    }

    enum SettingsSection: String, CaseIterable, Identifiable {
        case behaviour, appearance, content, clipboard, sync, expansion, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .behaviour: return "Behaviour"
            case .appearance: return "Appearance"
            case .content: return "Content"
            case .clipboard: return "Clipboard"
            case .sync: return "Sync"
            case .expansion: return "Expansion"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .behaviour: return "keyboard"
            case .appearance: return "paintpalette"
            case .content: return "doc.text"
            case .clipboard: return "doc.on.clipboard"
            case .sync: return "arrow.triangle.2.circlepath"
            case .expansion: return "wand.and.stars"
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
                    case .clipboard: clipboardSection
                    case .sync: syncSection
                    case .expansion: expansionSection
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
        .environment(\.motion, MotionPlan.resolve(settings.motionLevel,
                                                  reduceMotion: reduceMotion))
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
                        .font(.system(size: 11, weight: .semibold))
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
                .live { section = item }
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 186)
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("Alias actions") {
                SettingsRow("Enter", hint: "Choose what Enter does.") {
                    ThemedPicker(selection: $settings.enterAction,
                                 options: EnterAction.allCases,
                                 label: { $0.label })
                }
                if settings.enterAction.needsAccessibility {
                    PermissionNotice(granted: Typist.isTrusted)
                }
                // For the paste actions this choice does not exist: a paste can only
                // land after the window has closed and handed focus back, so offering
                // "Keep it open" there would be a lie. The control greys out instead
                // of disappearing — the setting is remembered and applies again the
                // moment Enter goes back to copying.
                SettingsRow("After copying",
                            hint: settings.enterAction.needsAccessibility
                                ? "Pasting closes AliasBar so focus returns to the previous app."
                                : nil) {
                    ThemedSegments(selection: $settings.afterAction,
                                   options: AfterAction.allCases,
                                   label: { $0.label })
                        .disabled(settings.enterAction.needsAccessibility)
                        .opacity(settings.enterAction.needsAccessibility ? 0.45 : 1)
                }
                SettingsRow("⌘⏎", hint: "Uses the alternate action.") {
                    Text(settings.enterAction.secondary.label)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.faint)
                }
            }

            SettingsGroup("Opening AliasBar") {
                SettingsRow("Shortcut", hint: "AliasBar sees this shortcut only. No permission needed.") {
                    HStack(spacing: 8) {
                        Button {
                            recordingHotkey.toggle()
                            HotkeyRecorder.shared.isRecording = recordingHotkey
                            HotkeyRecorder.shared.onCapture = { combo in
                                recordingHotkey = false
                                HotkeyRecorder.shared.isRecording = false
                                guard combo.isRegisterable else {
                                    hotkeyError = "Include ⌘ or ⌃."
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
                SettingsRow("Window position", hint: settings.presentationStyle.detail) {
                    ThemedPicker(selection: $settings.presentationStyle,
                                 options: PresentationStyle.allCases,
                                 label: { $0.label })
                }
            }

            SettingsGroup("Startup") {
                SettingsRow("Opens on", hint: nil) {
                    ThemedSegments(selection: $settings.defaultView,
                                   options: ViewMode.allCases,
                                   label: { $0.label })
                }
                SettingsRow("Starts with", hint: "You can switch libraries with ⇥.") {
                    Picker("Default library", selection: $settings.defaultLibrary) {
                        ForEach(DefaultLibrary.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Default library")
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
            SettingsGroup("Presets") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(settings.allPresets) { preset in
                        ThemeSwatch(appearance: preset,
                                    systemIsDark: settings.systemIsDark,
                                    selected: settings.appearance.id == preset.id
                                        && settings.appearance == preset,
                                    action: {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            settings.appearance = preset
                                        }
                                    })
                    }
                }
                if isEditedCopy {
                    // Says what a checkmark's absence would otherwise leave the user to
                    // infer: their changes are live but unnamed, and picking another
                    // preset will lose them.
                    NoticeText("Unsaved preset changes.", tone: .info)
                }
                HStack(spacing: 8) {
                    ThemedButton(savingPreset ? "Cancel" : "Save as…") {
                        savingPreset.toggle()
                        renaming = false
                        newPresetName = suggestedPresetName
                    }
                    if !settings.appearance.isBuiltIn && !savingPreset {
                        ThemedButton(renaming ? "Cancel" : "Rename") {
                            renaming.toggle()
                            newPresetName = settings.appearance.name
                        }
                    }
                    if renaming && !savingPreset {
                        presetNameField
                        ThemedButton("Rename") { renamePreset() }
                    }
                    if savingPreset {
                        presetNameField
                        ThemedButton("Save") { savePreset() }
                    } else if !settings.appearance.isBuiltIn && !renaming {
                        ThemedButton("Delete") { deletePreset() }
                        // Presets wrap across a grid rather than stacking, so "up" and
                        // "down" would name nothing the user can see. Earlier and later
                        // are true wherever a row happens to break.
                        ThemedButton("Move earlier") { move(by: -1) }
                            .disabled(presetIndex == 0)
                        ThemedButton("Move later") { move(by: 1) }
                            .disabled(presetIndex == settings.savedPresets.count - 1)
                    }
                    Spacer(minLength: 0)
                    ThemedButton("Copy") {
                        PasteboardBroker.write(transient: PresetTransfer.export(settings.appearance))
                        transferNotice = "Preset copied."
                    }
                    ThemedButton("Paste") { importFromClipboard() }
                }
                if let transferNotice {
                    NoticeText(transferNotice, tone: transferNotice.hasPrefix("Copied")
                               || transferNotice.hasPrefix("Added") ? .info : .warning)
                }
            }

            SettingsGroup("Colour") {
                SettingsRow("Background",
                            hint: "Sets the main background color.") {
                    ColourWell(colour: binding(\.ground))
                }
                SettingsRow("Accent", hint: nil) { ColourWell(colour: binding(\.accent)) }
                SettingsRow("Alias colour", hint: nil) { ColourWell(colour: binding(\.aliasTint)) }
                SettingsRow("Function colour", hint: nil) {
                    ColourWell(colour: binding(\.functionTint))
                }
                SettingsRow("Match macOS appearance",
                            hint: settings.appearance.darkGround == nil
                                ? "This preset has one appearance."
                                : "Uses the dark background in Dark Mode.") {
                    ThemedToggle(isOn: $settings.followsSystemAppearance,
                                 label: settings.followsSystemAppearance ? "On" : "Off")
                        .disabled(settings.appearance.darkGround == nil)
                }
                // Warning and danger colours are deliberately absent. If they were
                // tintable someone would eventually make a warning invisible, and it
                // would be the conflict one.
                NoticeText("Warnings always use orange.", tone: .info)
            }

            SettingsGroup("Type and shape") {
                SettingsRow("Interface", hint: nil) {
                    ThemedSegments(selection: binding(\.uiFont),
                                   options: FontChoice.allCases,
                                   label: { $0.label })
                }
                SettingsRow("Item names", hint: "Uses system fonts.") {
                    ThemedSegments(selection: binding(\.nameFont),
                                   options: FontChoice.allCases,
                                   label: { $0.label })
                }
                SettingsRow("Corner radius", hint: nil) {
                    HStack(spacing: 8) {
                        Slider(value: binding(\.cornerRadius), in: 0...14, step: 1)
                            .frame(width: 160)
                        Text("\(Int(settings.appearance.cornerRadius))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.dim)
                            .frame(width: 20, alignment: .trailing)
                    }
                }
                SettingsRow("Translucency", hint: "At 0%, the window is opaque.") {
                    HStack(spacing: 8) {
                        Slider(value: binding(\.translucency), in: 0...1)
                            .frame(width: 160)
                        Text("\(Int(settings.appearance.translucency * 100))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.dim)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            SettingsGroup("Motion") {
                SettingsRow("Animation",
                            hint: "Reduced keeps fades but removes movement. macOS Reduce Motion takes priority.") {
                    ThemedSegments(selection: $settings.motionLevel,
                                   options: MotionLevel.allCases,
                                   label: { $0.label })
                }
            }

            SettingsGroup("Layout") {
                SettingsRow("Board density", hint: nil) {
                    ThemedSegments(selection: $settings.boardDensity,
                                   options: BoardDensity.allCases,
                                   label: { $0.label })
                }
                SettingsRow("Results in Find", hint: "Maximum results shown while searching.") {
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
            SettingsGroup("Aliases") {
                SettingsRow("File",
                            hint: "AliasBar remembers this file.") {
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

            SettingsGroup("Visible items") {
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

            SettingsGroup("Build your library") {
                LibraryBuilderPanel()
            }

            SettingsGroup("Usage data") {
                NoticeText("AliasBar reads ~/.zsh_history on this Mac to rank aliases and show unused ones.",
                           tone: .info)
            }
        }
    }

    // MARK: Clipboard

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("Clipboard monitoring") {
                SettingsRow("Monitor clipboard",
                            hint: "Sensitive clips stay in memory and never sync or save to disk.") {
                    ThemedToggle(isOn: $settings.clipboardMonitoring,
                                 label: settings.clipboardMonitoring ? "On" : "Off")
                }
            }

            SettingsGroup("Clipboard history") {
                SettingsRow("Keep history after quitting",
                            hint: "Saves up to 200 clips in ~/.aliasbar/clips.json. Sensitive clips are excluded. Turning this off deletes the saved history.") {
                    ThemedToggle(isOn: $settings.clipboardPersistence,
                                 label: settings.clipboardPersistence ? "On" : "Off")
                }
                SettingsRow("Sync clipboard history",
                            hint: settings.clipboardPersistence
                                ? "Adds saved clips to your sync file. Its folder may sync through another service."
                                : "Turn on ‘Keep history after quitting’ first.") {
                    ThemedToggle(isOn: $settings.clipboardInSyncFile,
                                 label: settings.clipboardInSyncFile ? "On" : "Off")
                        .disabled(!settings.clipboardPersistence)
                        .opacity(settings.clipboardPersistence ? 1 : 0.45)
                }
            }

            SettingsGroup("Sensitive clips") {
                NoticeText("AliasBar hides passwords, tokens, and other sensitive clips. It keeps only the reason in memory for about 90 seconds, then removes it. Sensitive content never reaches disk or sync.",
                           tone: .info)
            }
        }
    }

    // MARK: Sync

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("Sync") {
                SettingsRow("Sync settings and presets",
                            hint: "Choose a JSON file in iCloud Drive, Dropbox, or a dotfiles repo.") {
                    ThemedToggle(isOn: Binding(
                        get: { settings.syncFileURL != nil },
                        set: { on in
                            if on {
                                if settings.syncFileURL == nil { chooseNewSyncFile() }
                            } else {
                                settings.syncFileURL = nil
                            }
                        }
                    ), label: settings.syncFileURL != nil ? "On" : "Off")
                }
                if let url = settings.syncFileURL {
                    SettingsRow("File", hint: nil) {
                        HStack(spacing: 8) {
                            Text(url.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.dim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 260, alignment: .leading)
                            ThemedButton("Choose existing…") { chooseExistingSyncFile() }
                            ThemedButton("Choose new…") { chooseNewSyncFile() }
                        }
                    }
                    if let syncError = settings.syncError {
                        NoticeText(syncError, tone: .warning)
                    }
                    let conflicts = SettingsSync.conflictFiles(near: url)
                    if !conflicts.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            NoticeText("\(conflicts.count) conflict \(conflicts.count == 1 ? "copy" : "copies") saved next to the sync file. All versions remain on disk.",
                                       tone: .warning)
                            ThemedButton("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting(conflicts)
                            }
                        }
                    }
                }
            }

            SettingsGroup("Synced") {
                NoticeText("Appearance, presets, search options, startup view, result limit, and Enter actions.",
                           tone: .info)
            }
            SettingsGroup("Not synced") {
                NoticeText("File locations, hotkey, login setting, permissions, window position, clipboard options, and usage counts. Clipboard history and snippets require their own sync options.",
                           tone: .info)
            }
        }
    }

    // MARK: Expansion

    private var expansionSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup("Text expansion") {
                SettingsRow("Enable",
                            hint: "Expand snippet triggers as you type. AliasBar watches only enough text to match a trigger and does not save it.") {
                    ThemedToggle(isOn: $settings.inlineExpansionEnabled,
                                 label: settings.inlineExpansionEnabled ? "On" : "Off")
                        .onChange(of: settings.inlineExpansionEnabled) { enabled in
                            if enabled {
                                ExpansionMonitor.shared.start()
                            } else {
                                ExpansionMonitor.shared.stop()
                            }
                        }
                }
                if expansionMonitor.status != .off {
                    expansionStatusNotice
                }
                NoticeText("AliasBar ignores password fields and other secure inputs.",
                           tone: .info)
            }

            SettingsGroup("Snippets") {
                NoticeText("Create snippets in Manage → Snippets. Use {{holes}} for text you fill in each time.",
                           tone: .info)
            }
        }
    }

    @ViewBuilder
    private var expansionStatusNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: expansionStatusSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(expansionStatusColor)
            Text(expansionStatusText)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            if expansionMonitor.status == .needsAccessibility {
                ThemedButton("Grant") { Typist.requestTrust() }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(expansionStatusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
    }

    private var expansionStatusSymbol: String {
        switch expansionMonitor.status {
        case .active: return "checkmark.circle.fill"
        case .needsAccessibility, .tapFailed: return "exclamationmark.triangle.fill"
        case .off: return "circle"
        }
    }

    private var expansionStatusColor: Color {
        switch expansionMonitor.status {
        case .active: return .green
        case .needsAccessibility, .tapFailed: return .orange
        case .off: return .gray
        }
    }

    private var expansionStatusText: String {
        switch expansionMonitor.status {
        case .active:
            return "Watching for triggers. Accessibility is granted."
        case .needsAccessibility:
            return "Allow Accessibility to use text expansion."
        case .tapFailed:
            return "Text expansion stopped. Turn it off and on to retry."
        case .off:
            return ""
        }
    }

    private func chooseNewSyncFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "aliasbar-sync.json"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            settings.syncFileURL = url
        }
    }

    private func chooseExistingSyncFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            settings.syncFileURL = url
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
                    Text("Aliases and prompts, one shortcut away.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.dim)
                }
            }

            SettingsGroup("Updates") {
                SettingsRow("Automatic", hint: "Checks for updates in the background. You choose when to install them.") {
                    ThemedToggle(isOn: $updater.automaticallyChecksForUpdates,
                                 label: "Check for updates automatically")
                }
                SettingsRow("Manual", hint: nil) {
                    ThemedButton("Check now") { updater.checkForUpdates() }
                }
            }

            SettingsGroup("Privacy") {
                NoticeText("AliasBar keeps aliases, prompts, snippets, usage data, and clipboard history on this Mac. It writes Claude Code commands only when you install one. The only network access is checking for and downloading updates.",
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
        .liveButton()
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
                .font(.system(size: 9.5, weight: .semibold))
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
                .font(.system(size: 11, weight: .semibold))
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

/// A colour, editable, shown as the hex the user can copy out.
///
/// The hex field is not decoration. Colours arrive from other places — a brand guide, a
/// terminal theme, a screenshot someone eyedropped — and typing six characters is faster
/// than steering a colour wheel to a value you already know.
struct ColourWell: View {
    @Environment(\.theme) private var theme
    @Binding var colour: HexColor
    @State private var typed: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(
                get: { colour.color },
                set: { newValue in
                    if let converted = NSColor(newValue).usingColorSpace(.sRGB) {
                        colour = HexColor(red: Double(converted.redComponent),
                                          green: Double(converted.greenComponent),
                                          blue: Double(converted.blueComponent))
                    }
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 44)

            TextField("#000000", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text)
                .focused($editing)
                .frame(width: 76)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .strokeBorder(theme.rule.opacity(0.6), lineWidth: 1))
                .onSubmit { commit() }
                .onChange(of: editing) { focused in if !focused { commit() } }
                .onAppear { typed = colour.hex }
                // While the field has focus the user is mid-typing and half a hex string
                // is not a colour; only mirror the well back into it when they are done.
                .onChange(of: colour) { new in if !editing { typed = new.hex } }
        }
    }

    private func commit() {
        if let parsed = HexColor(hex: typed) {
            colour = parsed
        }
        typed = colour.hex
    }
}

/// Live preview of a look, rendered in that look rather than described in words.
struct ThemeSwatch: View {
    @Environment(\.theme) private var current
    let appearance: Appearance
    let systemIsDark: Bool
    let selected: Bool
    let action: () -> Void

    private var t: Theme { Theme.derive(from: appearance, dark: systemIsDark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("@")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.onAliasTint)
                    .frame(width: 14, height: 14)
                    .background(t.aliasTint, in: RoundedRectangle(cornerRadius: t.cornerRadius))
                Text("gs")
                    .font(.system(size: 11.5, weight: .semibold, design: t.nameDesign))
                    .foregroundStyle(t.text)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
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

            Text(appearance.name)
                .font(.system(size: 10.5, weight: .semibold, design: t.bodyDesign))
                .foregroundStyle(t.text)
            Text(appearance.isBuiltIn ? "Built in" : "Yours")
                .font(.system(size: 9))
                .foregroundStyle(t.faint)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: t.cornerRadius + 3).fill(t.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: t.cornerRadius + 3)
                .strokeBorder(selected ? current.accent : current.rule.opacity(0.45),
                              lineWidth: selected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .live(action: action)
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
