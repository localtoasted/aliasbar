import SwiftUI
import AppKit

// MARK: - First-run flow

/// The five questions worth answering before first use, and nothing else.
///
/// This app exists to save seconds, so the flow is built to be left: every step has a
/// working default, every step can be skipped, and closing the window at any point is a
/// legitimate way to finish. Whatever ends it, it is recorded as complete and never
/// shown again — a setup screen that reappears is a bug report waiting to happen.
///
/// The one thing the flow is *not* casual about is the Accessibility permission. The
/// macOS dialog must always arrive as the answer to a button the user just pressed,
/// with the explanation already on screen — never from nowhere.
struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    /// Closes the window. Completion itself is recorded by the window's close observer,
    /// so there is exactly one place that marks the flow done.
    var onDone: () -> Void

    @ObservedObject private var updater = Updater.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0

    // Step 1: shortcut
    @State private var recordingHotkey = false
    @State private var hotkeyError: String?

    // Step 2: Enter — the callout is shown, not the system dialog, when a paste action
    // is picked. `axPrompted` remembers that the user pressed the button this session,
    // so the callout can acknowledge it instead of asking again.
    @State private var axPrompted = false

    // Step 5: look
    @State private var customising = false
    @State private var savingPreset = false
    @State private var newPresetName = ""
    @State private var presetNotice: String?

    private static let stepCount = 5

    private var theme: Theme { settings.theme(systemIsDark: settings.systemIsDark) }
    private var motion: MotionPlan {
        MotionPlan.resolve(settings.motionLevel, reduceMotion: reduceMotion)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    Group {
                        switch step {
                        case 0: shortcutStep
                        case 1: enterStep
                        case 2: fileStep
                        case 3: updatesStep
                        default: lookStep
                        }
                    }
                    .transition(.opacity)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(motion(Motion.standard), value: step)

            Rectangle().fill(theme.rule.opacity(0.6)).frame(height: 1)
            footer
        }
        .frame(width: 660, height: 560)
        .background(theme.background)
        .preferredColorScheme(theme.isLight ? .light : .dark)
        .environment(\.theme, theme)
        .environment(\.motion, motion)
    }

    // MARK: Chrome

    private var stepTitle: String {
        switch step {
        case 0: return "One keystroke, from anywhere"
        case 1: return "What Enter does"
        case 2: return "Where your aliases live"
        case 3: return "Staying up to date"
        default: return "Pick a look"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                AliasBarMark(size: 26)
                Text("Welcome to AliasBar")
                    .font(.system(size: 12, weight: .semibold, design: theme.bodyDesign))
                    .foregroundStyle(theme.dim)
                Spacer()
                Text("\(step + 1) of \(Self.stepCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.faint)
            }
            Text(stepTitle)
                .font(.system(size: 23, weight: .bold, design: theme.bodyDesign))
                .foregroundStyle(theme.text)
        }
        .padding(.top, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Set up later") { onDone() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.faint)
                .accessibilityLabel("Set up later")

            Spacer()

            HStack(spacing: 5) {
                ForEach(0..<Self.stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == step ? theme.accent : theme.rule)
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            Button("Skip") { advance() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
                .opacity(step == Self.stepCount - 1 ? 0 : 1)
                .accessibilityLabel("Skip this setup step")

            Button(action: advance) {
                Text(step == Self.stepCount - 1 ? "Finish" : "Continue")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(theme.accent,
                                in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
            }
            .liveButton()
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(step == Self.stepCount - 1
                                ? "Finish setup"
                                : "Continue to next setup step")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func advance() {
        if step >= Self.stepCount - 1 {
            onDone()
        } else {
            step += 1
        }
    }

    // MARK: Step 1 — shortcut

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Press it in any app and AliasBar appears over your work, ready to search. Escape hands focus straight back.")
                .font(.system(size: 13, design: theme.bodyDesign))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Button {
                    startRecording(!recordingHotkey)
                } label: {
                    Text(recordingHotkey ? "Press keys…" : settings.hotkey.displayString)
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .foregroundStyle(recordingHotkey ? theme.accent : theme.text)
                        .frame(minWidth: 150)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(theme.surface,
                                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 2))
                        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
                            .strokeBorder(recordingHotkey ? theme.accent : theme.rule.opacity(0.7),
                                          lineWidth: recordingHotkey ? 1.5 : 1))
                }
                .liveButton(pressDrop: 1)
                .accessibilityLabel(recordingHotkey
                                    ? "Stop recording keyboard shortcut"
                                    : "Change keyboard shortcut, currently \(settings.hotkey.displayString)")

                VStack(alignment: .leading, spacing: 4) {
                    Text(recordingHotkey ? "Recording — press the combination you want."
                                         : "This works as it is.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.text)
                    Text(recordingHotkey ? "Include ⌘ or ⌃."
                                         : "Click the key to choose a different one.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.faint)
                }
            }

            if let hotkeyError {
                NoticeText(hotkeyError, tone: .warning)
            }

            NoticeText("The shortcut uses the system hotkey API: macOS tells AliasBar that this one combination fired and nothing else. It never sees any other keystroke, and needs no permission.",
                       tone: .info)
        }
    }

    private func startRecording(_ recording: Bool) {
        recordingHotkey = recording
        HotkeyRecorder.shared.isRecording = recording
        guard recording else { return }
        HotkeyRecorder.shared.onCapture = { combo in
            recordingHotkey = false
            HotkeyRecorder.shared.isRecording = false
            guard combo.isRegisterable else {
                hotkeyError = "Include ⌘ or ⌃. macOS no longer accepts shortcuts built only from ⌥ and ⇧."
                return
            }
            // Register first, persist only on success — the same rule the settings
            // window follows, and for the same reason: a stored combination that never
            // took effect would be retried, dead, on every future launch.
            let ok = HotkeyManager.shared.register(combo) {
                NotificationCenter.default.post(name: .aliasBarHotkeyFired, object: nil)
            }
            if ok {
                settings.hotkey = combo
                hotkeyError = nil
            } else {
                hotkeyError = "macOS refused that combination. Still using \(settings.hotkey.displayString)."
            }
        }
    }

    // MARK: Step 2 — Enter, and the permission it may need

    /// The three choices offered here. `copyName` stands in for both copy variants;
    /// the full four-way split lives in Settings for whoever wants it.
    private static let enterChoices: [(EnterAction, String, String)] = [
        (.pasteName, "Type the alias name into the app behind",
         "You are usually standing in a terminal about to type it yourself — AliasBar types it for you."),
        (.pasteCommand, "Type the full command",
         "The whole expansion lands where you were working."),
        (.copyName, "Copy to the clipboard",
         "Nothing is typed anywhere. Paste it yourself with ⌘V. Needs no permission."),
    ]

    private var enterStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You searched, you found it, you pressed Enter. Then what?")
                .font(.system(size: 13, design: theme.bodyDesign))
                .foregroundStyle(theme.dim)

            VStack(spacing: 8) {
                ForEach(Self.enterChoices, id: \.0) { action, title, detail in
                    choiceRow(selected: settings.enterAction == action,
                              title: title, detail: detail,
                              badge: action == .pasteName ? "Default" : nil) {
                        settings.enterAction = action
                    }
                }
            }

            if settings.enterAction.needsAccessibility {
                accessibilityCallout
            }
        }
    }

    private func choiceRow(selected: Bool, title: String, detail: String,
                           badge: String?, choose: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(selected ? theme.accent : theme.faint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium, design: theme.bodyDesign))
                        .foregroundStyle(theme.text)
                    if let badge {
                        Text(badge.uppercased())
                            .font(.system(size: 8.5, weight: .bold))
                            .kerning(0.6)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(theme.accent.opacity(0.5), lineWidth: 1))
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(selected ? theme.selectionFill : theme.surface.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 2))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
            .strokeBorder(selected ? theme.selectionStroke : theme.rule.opacity(0.4),
                          lineWidth: 1))
        .contentShape(Rectangle())
        .live(action: choose)
        .accessibilityLabel(title)
    }

    /// The in-app explanation that always precedes the macOS Accessibility dialog.
    ///
    /// Two lists, deliberately: what pressing Allow grants, and what it can never be
    /// used for. The system prompt appears only from the button below, so it always
    /// arrives as an answer rather than an ambush.
    private var accessibilityCallout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: Typist.isTrusted ? "checkmark.circle.fill" : "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Typist.isTrusted ? .green : theme.accent)
                Text(Typist.isTrusted ? "Accessibility is granted — typing works."
                                      : "Typing into another app needs one permission")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.text)
            }

            if !Typist.isTrusted {
                VStack(alignment: .leading, spacing: 5) {
                    calloutLine(symbol: "checkmark", tint: .green,
                                text: "What it does: sends a single ⌘V into the app you were just in. That is the entire use.")
                    calloutLine(symbol: "xmark", tint: .orange,
                                text: "What it never does: read, watch, or record your keystrokes. The shortcut uses a separate API that only reports its own combination.")
                }

                HStack(spacing: 8) {
                    ThemedButton(axPrompted ? "Show the macOS prompt again" : "Allow — show the macOS prompt") {
                        axPrompted = true
                        Typist.requestTrust()
                    }
                    .accessibilityLabel(axPrompted
                                        ? "Show the macOS Accessibility permission prompt again"
                                        : "Allow typing by showing the macOS Accessibility permission prompt")
                    Text("Until it’s granted, Enter copies instead — nothing breaks.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.faint)
                }
            }
        }
        .padding(13)
        .background(theme.surface.opacity(0.7),
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 2))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
            .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
    }

    private func calloutLine(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 3 — the file

    private var fileStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AliasBar reads your aliases and functions from your shell config. It never writes to it unless you edit an alias yourself.")
                .font(.system(size: 13, design: theme.bodyDesign))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            SettingsGroup("Reading from") {
                Text(ZshrcParser.displayPath)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.text)
                SettingsRow("Elsewhere?",
                            hint: "Stored in preferences, so it survives a reboot and applies when AliasBar launches at login.") {
                    HStack(spacing: 8) {
                        TextField("~/.zshrc", text: Binding(
                            get: { settings.rcPathOverride ?? "" },
                            set: { settings.rcPathOverride = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .frame(width: 240)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(theme.surface,
                                    in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(theme.rule.opacity(0.6), lineWidth: 1))

                        ThemedButton("Choose…") { chooseFile() }
                            .accessibilityLabel("Choose aliases file")
                    }
                }
            }

            NoticeText("Usage counts come from ~/.zsh_history, read locally and never sent anywhere.",
                       tone: .info)
        }
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

    // MARK: Step 4 — updates

    /// The choice Sparkle would otherwise ask for with its own dialog on second launch.
    /// Asking here instead keeps the promise the rest of the flow makes: every prompt
    /// arrives with its explanation already on screen. The toggle drives the same
    /// setting as Settings > About — on by default, and honoured even if this flow is
    /// closed without reaching this step.
    private var updatesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AliasBar can check its release feed in the background and offer new versions when they appear. Nothing installs without asking you first.")
                .font(.system(size: 13, design: theme.bodyDesign))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            SettingsGroup("Automatic updates") {
                SettingsRow("Background checks",
                            hint: "You can change this any time in Settings > About.") {
                    ThemedToggle(isOn: $updater.automaticallyChecksForUpdates,
                                 label: "Check for updates automatically")
                }
            }

            NoticeText("The check sends nothing about you or your aliases — it only fetches the release feed. Downloads happen only when you accept an update.",
                       tone: .info)
        }
    }

    // MARK: Step 5 — the look

    private var lookStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Three looks, drawn live. One click and you’re done — or open the same controls Settings has and make your own.")
                .font(.system(size: 13, design: theme.bodyDesign))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ForEach(Appearance.builtIns) { preset in
                    MiniPalettePreview(appearance: preset,
                                       systemIsDark: settings.systemIsDark,
                                       selected: settings.appearance.id == preset.id) {
                        withAnimation(motion(Motion.standard)) {
                            settings.appearance = preset
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                ThemedButton(customising ? "Hide the controls" : "Customise") {
                    withAnimation(motion(Motion.standard)) { customising.toggle() }
                }
                .accessibilityLabel(customising
                                    ? "Hide appearance controls"
                                    : "Customise appearance")
                Spacer()
            }

            if customising {
                inlineTokenEditor
            }
        }
    }

    /// Edits the working copy in place — the same write-through binding the settings
    /// window uses, against the same store, so "Customise" here *is* the token editor
    /// and not a copy of it.
    private func binding<T>(_ path: WritableKeyPath<Appearance, T>) -> Binding<T> {
        Binding(
            get: { settings.appearance[keyPath: path] },
            set: { settings.appearance[keyPath: path] = $0 }
        )
    }

    private var inlineTokenEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup("Colour") {
                SettingsRow("Ground",
                            hint: "Text, rules, and the greys are computed from this and the accent, at contrast ratios that hold whatever you pick.") {
                    ColourWell(colour: binding(\.ground))
                }
                SettingsRow("Accent", hint: nil) { ColourWell(colour: binding(\.accent)) }
                SettingsRow("Alias colour", hint: nil) { ColourWell(colour: binding(\.aliasTint)) }
                SettingsRow("Function colour", hint: nil) {
                    ColourWell(colour: binding(\.functionTint))
                }
            }

            SettingsGroup("Type and shape") {
                SettingsRow("Interface", hint: nil) {
                    ThemedSegments(selection: binding(\.uiFont),
                                   options: FontChoice.allCases,
                                   label: { $0.label })
                }
                SettingsRow("Alias names", hint: nil) {
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
                SettingsRow("Translucency", hint: nil) {
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

            SettingsGroup("Keep it") {
                HStack(spacing: 8) {
                    if savingPreset {
                        TextField("Name", text: $newPresetName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.text)
                            .frame(width: 150)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(theme.surface,
                                        in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                                .strokeBorder(theme.rule.opacity(0.6), lineWidth: 1))
                            .onSubmit { savePreset() }
                        ThemedButton("Save") { savePreset() }
                            .accessibilityLabel("Save appearance preset")
                        ThemedButton("Cancel") { savingPreset = false }
                            .accessibilityLabel("Cancel saving appearance preset")
                    } else {
                        ThemedButton("Save as a preset…") {
                            savingPreset = true
                            newPresetName = suggestedPresetName
                        }
                        .accessibilityLabel("Save appearance as a preset")
                        Text("Named looks appear alongside the built-in three, here and in Settings.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.faint)
                    }
                }
                if let presetNotice {
                    NoticeText(presetNotice, tone: .info)
                }
            }
        }
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
        presetNotice = "Saved “\(name)”."
    }
}

// MARK: - Live look preview

/// A miniature of the actual palette window, rendered in the candidate look.
///
/// Not a swatch strip: the question the user is answering is "what will the window I
/// summon forty times a day look like", so the preview is that window — ground, search
/// field, a selected row, the kind chips — drawn from the same derived `Theme` the real
/// one uses. Vibrancy is the one thing not reproduced; a blur needs a desktop behind it,
/// and a fake one would misrepresent exactly the thing it exists to show.
struct MiniPalettePreview: View {
    @Environment(\.theme) private var current
    let appearance: Appearance
    let systemIsDark: Bool
    let selected: Bool
    let choose: () -> Void

    private var t: Theme { Theme.derive(from: appearance, dark: systemIsDark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                // The search field, mid-search.
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(t.dim)
                    Text("gs")
                        .font(.system(size: 9, design: t.bodyDesign))
                        .foregroundStyle(t.text)
                    Spacer(minLength: 0)
                    Text("2")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(t.faint)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(t.surface, in: RoundedRectangle(cornerRadius: t.cornerRadius * 0.6))
                .overlay(RoundedRectangle(cornerRadius: t.cornerRadius * 0.6)
                    .strokeBorder(t.rule.opacity(0.5), lineWidth: 0.5))

                miniRow(chip: "@", chipFill: t.aliasTint, onChip: t.onAliasTint,
                        name: "gs", command: "git status -sb", isSelected: true)
                miniRow(chip: "ƒ", chipFill: t.functionTint, onChip: t.onFunctionTint,
                        name: "gsw", command: "git switch \"$1\"", isSelected: false)
            }
            .padding(7)
            .background(t.background, in: RoundedRectangle(cornerRadius: t.cornerRadius * 0.8))
            .overlay(RoundedRectangle(cornerRadius: t.cornerRadius * 0.8)
                .strokeBorder(t.rule.opacity(0.7), lineWidth: 0.5))

            HStack(spacing: 6) {
                Text(appearance.name)
                    .font(.system(size: 11.5, weight: .semibold, design: t.bodyDesign))
                    .foregroundStyle(current.text)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(current.accent)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current.surface.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: current.cornerRadius + 3))
        .overlay(RoundedRectangle(cornerRadius: current.cornerRadius + 3)
            .strokeBorder(selected ? current.accent : current.rule.opacity(0.45),
                          lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .live(pressDrop: 1, action: choose)
        .accessibilityLabel("\(appearance.name) appearance")
    }

    private func miniRow(chip: String, chipFill: Color, onChip: Color,
                         name: String, command: String, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            Text(chip)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(onChip)
                .frame(width: 12, height: 12)
                .background(chipFill, in: RoundedRectangle(cornerRadius: t.cornerRadius * 0.5))
            Text(name)
                .font(.system(size: 9, weight: .semibold, design: t.nameDesign))
                .foregroundStyle(t.text)
            Text(command)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(t.dim)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(isSelected ? t.selectionFill : .clear,
                    in: RoundedRectangle(cornerRadius: t.cornerRadius * 0.6))
        .overlay(RoundedRectangle(cornerRadius: t.cornerRadius * 0.6)
            .strokeBorder(isSelected ? t.selectionStroke : .clear, lineWidth: 0.5))
    }
}

// MARK: - Lost-permission banner

/// Warns when a previously working Accessibility grant has been silently voided.
///
/// The ad-hoc-signing failure this exists for: macOS pins the grant to the binary's
/// hash, a rebuild changes the hash, and `AXIsProcessTrusted()` starts returning false
/// while System Settings still shows AliasBar enabled. The user did nothing and paste
/// stopped working. `hasEverPasted` is what separates that case from "never granted",
/// which gets the gentler in-flow treatment instead of a warning.
///
/// Applied around the palette content from `App` so the views file does not have to
/// know about it.
struct AccessibilityRegrantBanner: ViewModifier {
    @ObservedObject var settings: AppSettings
    /// Observed so the check reruns every time the window is summoned — a grant fixed
    /// in System Settings while the palette was closed clears the banner on next open.
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme

    private var lost: Bool {
        settings.enterAction.needsAccessibility
            && settings.hasEverPasted
            && !Typist.isTrusted
    }

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if lost {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text("macOS dropped AliasBar’s permission to type — it does this when the app is rebuilt. Enter copies instead until it’s back: flip AliasBar off and on under Accessibility.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    ThemedButton("Re-grant") {
                        Typist.requestTrust()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .accessibilityLabel("Re-grant Accessibility permission")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .background(theme.background)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.rule.opacity(0.6)).frame(height: 1)
                }
            }
        }
    }
}
