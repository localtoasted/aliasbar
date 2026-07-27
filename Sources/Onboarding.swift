import SwiftUI
import AppKit

// MARK: - First-run flow

/// Detect, show value, then ask — and nothing else.
///
/// PRE-239 shipped this as four questions up front; PRE-277 added a fifth for updates.
/// The questions themselves are unchanged, only their place in line: `found` runs a
/// silent local scan and leads with what it turned up — counts, a top-5, the
/// graveyard — before the flow asks for a single decision. The rest keeps its order.
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
    @State private var step: OnboardingStep = .found

    // Step 0: found — the silent scan, run once when the window is built, and the
    // three opt-in decisions its screen presents alongside the counts.
    @State private var scan: OnboardingScanResult
    @State private var decisions: OnboardingDecisions

    // Step 1: shortcut
    @State private var recordingHotkey = false
    @State private var hotkeyError: String?
    /// Whether `.aliasBarHotkeyFired` has been observed while this step is showing —
    /// the practice field's confirmation that the combination actually works, not
    /// just that it was accepted when set.
    @State private var hotkeyRehearsed = false
    @State private var hotkeyRehearsalToken: NSObjectProtocol?

    // Step 2: Enter — the callout is shown, not the system dialog, when a paste action
    // is picked. `axPrompted` remembers that the user pressed the button this session,
    // so the callout can acknowledge it instead of asking again.
    @State private var axPrompted = false

    // Step 5: look
    @State private var customising = false
    @State private var savingPreset = false
    @State private var newPresetName = ""
    @State private var presetNotice: String?

    /// Runs the silent local scan once, when the window is built — never again for the
    /// life of this view — and seeds the found-treasure checkboxes from it.
    init(settings: AppSettings, onDone: @escaping () -> Void) {
        self.settings = settings
        self.onDone = onDone
        let result = OnboardingScanner.scan(rcPath: AppPaths.rcPath,
                                            historyPath: AppPaths.historyPath,
                                            claudeDirectoryPath: AppPaths.claudeDirectory)
        _scan = State(initialValue: result)
        _decisions = State(initialValue: .defaults(for: result))
    }

    private static var stepCount: Int { OnboardingStep.allCases.count }

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
                        case .found: foundStep
                        case .shortcut: shortcutStep
                        case .enter: enterStep
                        case .file: fileStep
                        case .updates: updatesStep
                        case .look: lookStep
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
        // Esc is a skip from anywhere in the flow, exactly like the Skip button —
        // `onDone` is the one place completion gets recorded, so this cannot diverge
        // from what clicking Skip or closing the window already do.
        .onExitCommand { onDone() }
    }

    // MARK: Chrome

    private var stepTitle: String {
        switch step {
        case .found: return "Your aliases and prompts"
        case .shortcut: return "Set your shortcut"
        case .enter: return "Choose what Enter does"
        case .file: return "Where your aliases live"
        case .updates: return "Updates"
        case .look: return "Choose a look"
        }
    }

    private var stepIndex: Int { OnboardingStep.allCases.firstIndex(of: step) ?? 0 }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                AliasBarMark(size: 26)
                Text("Welcome to AliasBar")
                    .font(.system(size: 12, weight: .semibold, design: theme.bodyDesign))
                    .foregroundStyle(theme.dim)
                Spacer()
                Text("\(stepIndex + 1) of \(Self.stepCount)")
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
                ForEach(OnboardingStep.allCases, id: \.self) { candidate in
                    Circle()
                        .fill(candidate == step ? theme.accent : theme.rule)
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            Button("Skip") { advance() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.dim)
                .opacity(step == .look ? 0 : 1)
                .accessibilityLabel("Skip this setup step")

            Button(action: advance) {
                Text(step == .look ? "Finish" : "Continue")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(theme.accent,
                                in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
            }
            .liveButton()
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(step == .look
                                ? "Finish setup"
                                : "Continue to next setup step")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func advance() {
        let all = OnboardingStep.allCases
        guard let idx = all.firstIndex(of: step), idx < all.count - 1 else {
            onDone()
            return
        }
        step = all[idx + 1]
    }

    // MARK: Step 0 — found

    /// Bindings into `decisions`, each writing straight through to `settings` on
    /// change — the same write-through-immediately idiom every other step in this
    /// flow already uses (the hotkey commits on capture, Enter's choice commits on
    /// tap), so leaving this screen early loses nothing already ticked.
    private var historyRankingBinding: Binding<Bool> {
        Binding(get: { decisions.historyUsageRanking }, set: {
            decisions.historyUsageRanking = $0
            decisions.apply(to: settings)
        })
    }
    private var claudeFeaturesBinding: Binding<Bool> {
        Binding(get: { decisions.claudeCodePromptFeatures }, set: {
            decisions.claudeCodePromptFeatures = $0
            decisions.apply(to: settings)
        })
    }
    private var clipboardWatchingBinding: Binding<Bool> {
        Binding(get: { decisions.clipboardWatching }, set: {
            decisions.clipboardWatching = $0
            decisions.apply(to: settings)
        })
    }

    private var scanIntroLine: String {
        scan.aliasCount == 0 && scan.functionCount == 0
            ? "No aliases found in your shell config yet."
            : "AliasBar found these in your shell config."
    }

    /// The found-treasure screen: counts, the top-5 "first aha", and the three
    /// opt-in decisions those sources unlock. Everything above the checkboxes is
    /// read-only value — nothing on it is a question.
    private var foundStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(scanIntroLine)
                .font(.system(size: 13, design: theme.bodyDesign))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 22) {
                statTile(value: "\(scan.aliasCount)", label: scan.aliasCount == 1 ? "alias" : "aliases")
                statTile(value: "\(scan.functionCount)",
                        label: scan.functionCount == 1 ? "function" : "functions")
                if scan.neverRunCount > 0 {
                    statTile(value: "\(scan.neverRunCount)", label: "never run", symbol: "moon.zzz")
                }
            }

            if !scan.topUsed.isEmpty {
                SettingsGroup("Most used") {
                    VStack(spacing: 6) {
                        ForEach(Array(scan.topUsed.enumerated()), id: \.element.id) { index, ranked in
                            topUsedRow(ranked, rank: index + 1)
                        }
                    }
                }
            } else {
                NoticeText("Run a few aliases to see your most used.",
                          tone: .info)
            }

            SettingsGroup("Choose what AliasBar uses") {
                SettingsRow("Usage ranking",
                            hint: "Turn off to keep your file order.") {
                    ThemedToggle(isOn: historyRankingBinding, label: "Rank by how often you actually use things")
                }
                SettingsRow("Prompts",
                            hint: scan.claudeCodeDetected
                                ? "Claude Code found. You can install prompts as slash commands."
                                : "Claude Code was not found. Prompts still work in AliasBar.") {
                    ThemedToggle(isOn: claudeFeaturesBinding, label: "Prompts")
                }
                SettingsRow("Clipboard monitoring",
                            hint: "Sensitive clips stay in memory and disappear after about 90 seconds.") {
                    ThemedToggle(isOn: clipboardWatchingBinding, label: "Monitor the clipboard")
                }
            }

            SettingsGroup("Build your library") {
                LibraryBuilderPanel()
            }
        }
    }

    private func statTile(value: String, label: String, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.faint)
                }
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.text)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.faint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    private func topUsedRow(_ ranked: RankedEntry, rank: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.faint)
                .frame(width: 14, alignment: .trailing)
            Text(ranked.name)
                .font(.system(size: 12.5, weight: .semibold, design: theme.nameDesign))
                .foregroundStyle(theme.text)
            Text(ranked.entry.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.dim)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("×\(ranked.uses)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.faint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rank \(rank), \(ranked.name), used \(ranked.uses) times")
    }

    // MARK: Step 1 — shortcut

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Press the shortcut in any app to open AliasBar. Esc returns to your work.")
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
                    Text(recordingHotkey ? "Press your new shortcut."
                                         : "The default is ready.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.text)
                    Text(recordingHotkey ? "Include ⌘ or ⌃."
                                         : "Click to change it.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.faint)
                }
            }

            if let hotkeyError {
                NoticeText(hotkeyError, tone: .warning)
            }

            // The practice field: proof the combination works, not just that macOS
            // accepted it. `.aliasBarHotkeyFired` is the same notification the real
            // summon path listens for, so this confirms the exact thing that will
            // happen every other time this shortcut is pressed.
            HStack(spacing: 7) {
                Image(systemName: hotkeyRehearsed ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(hotkeyRehearsed ? .green : theme.faint)
                Text(hotkeyRehearsed
                    ? "Shortcut works."
                    : "Press \(settings.hotkey.displayString) to test it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.dim)
            }
            .accessibilityLabel(hotkeyRehearsed
                                ? "Shortcut confirmed working"
                                : "Practice: press \(settings.hotkey.displayString) now to confirm it works")

            NoticeText("AliasBar sees this shortcut only. It cannot read your other keystrokes.",
                       tone: .info)
        }
        .onAppear {
            hotkeyRehearsalToken = NotificationCenter.default.addObserver(
                forName: .aliasBarHotkeyFired, object: nil, queue: .main
            ) { _ in hotkeyRehearsed = true }
        }
        .onDisappear {
            if let token = hotkeyRehearsalToken {
                NotificationCenter.default.removeObserver(token)
                hotkeyRehearsalToken = nil
            }
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
                hotkeyError = "Include ⌘ or ⌃."
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
        (.pasteName, "Paste the alias name", "Best for terminals."),
        (.pasteCommand, "Paste the full command", "Best when you want to edit the command first."),
        (.copyName, "Copy", "Paste it yourself with ⌘V. No permission needed."),
    ]

    private var enterStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose what Enter does.")
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
                Text(Typist.isTrusted ? "Accessibility granted."
                                      : "Allow AliasBar to paste")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.text)
            }

            if !Typist.isTrusted {
                VStack(alignment: .leading, spacing: 5) {
                    calloutLine(symbol: "checkmark", tint: .green,
                                text: "AliasBar sends ⌘V to the app you were using.")
                    calloutLine(symbol: "xmark", tint: .orange,
                                text: "AliasBar cannot read or record your typing.")
                }

                HStack(spacing: 8) {
                    ThemedButton(axPrompted ? "Show the macOS prompt again" : "Allow pasting") {
                        axPrompted = true
                        Typist.requestTrust()
                    }
                    .accessibilityLabel(axPrompted
                                        ? "Show the macOS Accessibility permission prompt again"
                                        : "Allow typing by showing the macOS Accessibility permission prompt")
                    Text("Until then, Enter copies instead.")
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
            Text("AliasBar reads your shell config. It writes only when you save an alias.")
                .font(.system(size: 13, design: theme.bodyDesign))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            SettingsGroup("Reading from") {
                Text(ZshrcParser.displayPath)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.text)
                SettingsRow("Use another file",
                            hint: "AliasBar remembers this file.") {
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

            NoticeText("AliasBar reads usage counts from ~/.zsh_history on this Mac.",
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
            Text("AliasBar can check for updates. You choose when to install them.")
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

            NoticeText("Update checks do not include your aliases or personal data.",
                       tone: .info)
        }
    }

    // MARK: Step 5 — the look

    private var lookStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a preset or make your own.")
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
                SettingsRow("Background",
                            hint: "Sets the main background color.") {
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

            SettingsGroup("Save preset") {
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
                        Text("Saved presets appear here and in Settings.")
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
                    Text("AliasBar lost Accessibility permission. Enter will copy until you re-enable AliasBar in System Settings.")
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
