import SwiftUI

// MARK: - Root

struct RootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the window's entrance. Deliberately not gating anything: focus and key
    /// handling do not wait on it, so ⌥⌘A then `gs⏎` lands the paste with the window
    /// still growing.
    @State private var arrived = false
    /// Whether the footer's keyboard hints are showing. They hide the instant a key goes
    /// down and return after a beat of stillness — present when someone is wondering
    /// what to press, invisible while they already know.
    @State private var hintsShown = false
    /// Invalidates any reveal already scheduled. A counter instead of a cancellable
    /// because the codebase schedules with `asyncAfter`, and a stale closure comparing
    /// generations is simpler than a task handle it would only ever cancel.
    @State private var hintGeneration = 0

    private var motion: MotionPlan {
        MotionPlan.resolve(settings.motionLevel, reduceMotion: reduceMotion)
    }
    // The system appearance matters only when the chosen look defines a second ground
    // and the user opted into following it; `settings.theme(systemIsDark:)` decides that.
    //
    // Read from settings rather than from `\.colorScheme`, because the window forces its
    // own scheme below. Reading the value we just set would be a loop with one stable
    // state and it would not be the right one.
    private var theme: Theme { settings.theme(systemIsDark: settings.systemIsDark) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.rule.opacity(0.6)).frame(height: 1)

            Group {
                switch state.mode {
                case .find: FindView(state: state, settings: settings)
                case .board: BoardView(state: state, settings: settings)
                case .manage: ManageView(state: state, settings: settings)
                }
            }
            // Cross-fade rather than cut, and only the body — the header holds the tabs
            // you just clicked, and moving it would pull the ground out from under the
            // pointer.
            .id(state.mode)
            .transition(.opacity)
            .animation(motion(Motion.standard), value: state.mode)
            // Fixed, not merely bounded. Every view fills this and scrolls inside it, so
            // no view can move the window by having more or less to show.
            .frame(height: WindowLayout.bodyHeight)
            .frame(maxWidth: .infinity)

            Rectangle().fill(theme.rule.opacity(0.6)).frame(height: 1)
            footer
        }
        .frame(width: WindowLayout.windowWidth)
        // Tells AppKit which way round this window is, which decides everything we do not
        // draw ourselves: the search field's placeholder, the caret, scrollers, and the
        // sheets. A light look inside a window AppKit believes is dark renders its
        // placeholder in near-white on paper, which is to say not at all.
        .preferredColorScheme(theme.isLight ? .light : .dark)
        .background(background)
        // Grows into place from its top edge rather than out of its centre, because the
        // top edge is where it is anchored and where the eye already is.
        .scaleEffect(arrived || !motion.movesThings ? 1 : 0.98, anchor: .top)
        .opacity(arrived || !motion.fades ? 1 : 0)
        .environment(\.motion, motion)
        .overlay(alignment: .top) { topHighlight }
        .environment(\.theme, theme)
        .overlay(alignment: .bottom) { toast }
        .sheet(item: $state.editor) { _ in
            EditorSheet(state: state).environment(\.theme, theme)
        }
        .sheet(item: $state.confirmRemoval) { confirmation in
            RemovalConfirmSheet(state: state, confirmation: confirmation)
                .environment(\.theme, theme)
        }
        .onAppear {
            searchFocused = true
            enter()
        }
        .onChange(of: state.mode) { _ in searchFocused = true }
        // Re-focus on every open, not just the first. Without this the second summon
        // renders the popover with the field looking focused but swallowing nothing,
        // which is indistinguishable from a broken hotkey.
        .onChange(of: state.showCount) { _ in
            DispatchQueue.main.async { searchFocused = true }
            arrived = false
            enter()
            restartHintClock(hideFirst: false)
        }
        .onAppear { restartHintClock(hideFirst: false) }
        .onChange(of: state.keystrokeCount) { _ in restartHintClock(hideFirst: true) }
    }

    /// Hides the hints (when asked) and books their return after 600ms of stillness.
    ///
    /// Hiding is immediate and fast — a hint still fading while its reader is already
    /// typing is noise. The return uses the entrance curve for the same reason rows do:
    /// nothing is waiting on it.
    private func restartHintClock(hideFirst: Bool) {
        if hideFirst && hintsShown {
            if let animation = motion(Motion.hover) {
                withAnimation(animation) { hintsShown = false }
            } else {
                hintsShown = false
            }
        }
        hintGeneration += 1
        let generation = hintGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard generation == hintGeneration, !hintsShown else { return }
            if let animation = motion(Motion.entrance) {
                withAnimation(animation) { hintsShown = true }
            } else {
                hintsShown = true
            }
        }
    }

    /// Plays the entrance. Focus is already set by the time this runs, so nothing about
    /// the animation can swallow a keystroke.
    private func enter() {
        guard let animation = motion(Motion.windowIn) else { arrived = true; return }
        withAnimation(animation) { arrived = true }
    }

    @ViewBuilder
    private var background: some View {
        if let vibrancy = theme.vibrancy {
            ZStack {
                VisualEffect(material: vibrancy.material)
                theme.background.opacity(vibrancy.tint)
            }
        } else {
            theme.background
        }
    }

    /// A one-pixel highlight along the top edge only.
    ///
    /// The macOS convention is light from above: a surface catches it on its upper lip
    /// and nowhere else. It is the cheapest single thing that separates a window that
    /// looks moulded from one that looks drawn. Dark surfaces only — on paper stock a
    /// white edge is invisible at best and a seam at worst.
    @ViewBuilder
    private var topHighlight: some View {
        if !theme.isLight {
            Rectangle()
                .fill(Color.white.opacity(0.09))
                .frame(height: 1)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                AliasBarMark(size: 25)

                ForEach(ViewMode.allCases) { mode in
                    tab(mode)
                }

                // Not a fourth tab. History is a state FIND can be in, and showing it
                // as a peer of the three views would say otherwise.
                if state.historyMode {
                    // Styled as a badge, not a tab: FIND is still the active view, and
                    // two things wearing the active-tab treatment at once would say the
                    // user is in two places.
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("History")
                            .font(.system(size: 11, weight: .semibold, design: theme.bodyDesign))
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(theme.surface,
                                in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(theme.accent.opacity(0.28), lineWidth: 1))
                    .help("Searching your shell history — ⌘H to go back")
                }

                // Same badge treatment for a non-All bucket, and for the same reason:
                // the bucket now narrows FIND and BOARD too, and a filter that hides
                // things without saying so reads as data loss. MANAGE already names
                // its bucket in the sidebar; history ignores buckets entirely.
                if state.bucket != .all && state.mode != .manage && !state.historyMode {
                    HStack(spacing: 4) {
                        Image(systemName: state.bucket.symbol)
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(state.bucket.label)
                            .font(.system(size: 11, weight: .semibold, design: theme.bodyDesign))
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(theme.surface,
                                in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(theme.accent.opacity(0.28), lineWidth: 1))
                    .help("Showing only \(state.bucket.label.lowercased()) — ⌘↑↓ to change, esc for all")
                }

                Spacer(minLength: 6)

                Text(ZshrcParser.displayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
                    // Without both of these a long path (anything not under ~) pushes
                    // the tabs off the left edge instead of truncating itself.
                    .frame(maxWidth: 190, alignment: .trailing)
                    .layoutPriority(-1)
                    .help(ZshrcParser.path)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.dim)
                TextField(searchPrompt, text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15.5, design: theme.bodyDesign))
                    .foregroundStyle(theme.text)
                    .focused($searchFocused)
                    .onChange(of: state.query) { _ in state.selection = 0 }
                if !state.query.isEmpty {
                    Text("\(state.historyMode ? state.historyResults.count : state.activeList.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 2))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
                    .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1)
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .frame(height: WindowLayout.headerHeight)
    }

    private var searchPrompt: String {
        if state.historyMode { return "Search everything you have run" }
        switch state.mode {
        case .find:
            return state.bucket == .all
                ? "Search aliases and functions"
                : "Search \(state.bucket.label.lowercased())"
        case .board: return "Type to highlight"
        case .manage: return "Filter \(state.bucket.label.lowercased())"
        }
    }

    private func tab(_ mode: ViewMode) -> some View {
        let active = state.mode == mode
        return Text(mode.label)
            .font(.system(size: 12.5, weight: active ? .bold : .medium, design: theme.bodyDesign))
            .foregroundStyle(active ? theme.accent : theme.dim)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(active ? theme.accent.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .strokeBorder(active ? theme.accent.opacity(0.4) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .live { state.mode = mode; state.selection = 0 }
            .help("\(mode.label) — ⌘\(mode == .find ? "1" : mode == .board ? "2" : "3")")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = state.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                // One line, not two. An error arriving must not make the footer taller,
                // because the footer's height is part of the window's.
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(error)
            } else {
                // Idle-revealed: opacity, not presence. The hints keep their layout
                // whether or not they are visible, because the footer's height and the
                // gear's position must not move with the user's typing rhythm.
                Group {
                    if state.historyMode {
                        KeyHint(keys: "⏎", label: "run it")
                        KeyHint(keys: "⌘⏎", label: "make an alias")
                        KeyHint(keys: "⌘H", label: "back")
                    } else {
                        KeyHint(keys: "⏎", label: settings.enterAction.short)
                        KeyHint(keys: "⌘⏎", label: settings.enterAction.secondary.short)
                        // The new movement keys earn their place here over ⌘N: a
                        // shortcut nobody can discover is one nobody uses, and ⌘N is
                        // already on the sidebar button in MANAGE.
                        KeyHint(keys: "⌥←→", label: "views")
                        KeyHint(keys: "⌘↑↓", label: "buckets")
                        KeyHint(keys: "⌘N", label: "new")
                        KeyHint(keys: "⌘H", label: "history")
                    }
                }
                .opacity(hintsShown ? 1 : 0)
                .accessibilityHidden(!hintsShown)
            }

            Spacer()

            Text("\(state.store.functions.count)ƒ \(state.store.aliases.count)@")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.faint)

            Button { state.onOpenSettings?() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 10.5, weight: .semibold))
            }
            .liveButton()
            .foregroundStyle(theme.dim)
            .help("Settings — ⌘,")
        }
        .frame(height: 16)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var toast: some View {
        if let message = state.toast {
            Text(message)
                .font(.system(size: 11, weight: .medium, design: theme.bodyDesign))
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.accent, in: Capsule())
                .padding(.bottom, 44)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}

// MARK: - Small shared pieces

struct KeyHint: View {
    @Environment(\.theme) private var theme
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(keys)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.dim)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(theme.rule.opacity(0.6), lineWidth: 0.5))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.faint)
        }
    }
}

struct KindBadge: View {
    @Environment(\.theme) private var theme
    let kind: ShellEntry.Kind
    var size: CGFloat = 18

    var body: some View {
        Text(kind == .function ? "ƒ" : "@")
            .font(.system(size: size * 0.6, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.onTint(for: kind))
            .frame(width: size, height: size)
            .background(theme.tint(for: kind),
                        in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
    }
}

/// The command, rendered as a shell line.
struct CommandText: View {
    @Environment(\.theme) private var theme
    let command: String
    var lineLimit: Int? = 1
    var size: CGFloat = 11.5

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Text("$")
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.accent.opacity(0.85))
            Text(lineLimit == 1
                 ? command.replacingOccurrences(of: "\n", with: " ⏎ ")
                 : command)
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(theme.dim)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: lineLimit != 1)
            Spacer(minLength: 0)
        }
    }
}

struct EmptyStateView: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.faint)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.dim)
            Text(hint)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.faint)
                .multilineTextAlignment(.center)
        }
        // Centred in whatever it is given rather than sized to its text: the body is a
        // fixed height now, and an empty state pinned to the top of it looks like a
        // rendering failure rather than an answer.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

/// The first screen a new user ever sees, so it teaches instead of apologising: one
/// concrete example, the way in, and the key that summons the window — never a bare
/// "nothing here".
private struct TeachingEmptyState: View {
    @Environment(\.theme) private var theme
    /// The summon combo's display string, or nil when the hotkey is disabled.
    let hotkey: String?
    let create: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 7) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(theme.faint)
                Text("Nothing in \(ZshrcParser.displayPath) yet")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.dim)
            }

            // One example, drawn like the row it will become. Seeing `gs → git status`
            // explains an alias faster than any sentence about aliases could.
            HStack(spacing: 8) {
                Text("gs")
                    .font(.system(size: 13, weight: .semibold, design: theme.nameDesign))
                    .kerning(-0.15)
                    .foregroundStyle(theme.text)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.faint)
                Text("git status")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.dim)
                Text("for example")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.faint)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1)
            )

            VStack(spacing: 9) {
                Button(action: create) {
                    HStack(spacing: 6) {
                        Text("⌘N")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.onAccent.opacity(0.85))
                        Text("Write your first alias")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(theme.onAccent)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                }
                .liveButton()

                if let hotkey {
                    Text("\(hotkey) summons this window from anywhere.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.faint)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 24)
    }
}

/// A dead end that does something. The failed query is already the name the user wants,
/// so the row offering to create it is a live control — click or ⏎ — not a hint about a
/// shortcut somewhere else.
private struct NoMatchView: View {
    @Environment(\.theme) private var theme
    let query: String
    let create: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(theme.faint)
                Text("No match for \"\(query)\"")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.dim)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    Text("Create an alias named")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.text)
                    Text(query)
                        .font(.system(size: 12.5, weight: .semibold, design: theme.nameDesign))
                        .kerning(-0.15)
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                    Text("⏎")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.dim)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(theme.rule.opacity(0.6), lineWidth: 0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(theme.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                        .strokeBorder(theme.accent.opacity(0.4), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .live { create() }

                Text("The editor opens with the name filled in.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.faint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 24)
    }
}

// MARK: - FIND

/// The hot path. One answer, large, with the runners-up as compact chips underneath.
///
/// The shape is the argument: the dominant situation is knowing the concept but not the
/// string, so the job is to be confidently right about one thing rather than to present
/// a menu. Anything past the first result is a fallback, and it is drawn like one.
struct FindView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme
    /// One capsule, shared by every row. Only the selected row draws it, so SwiftUI
    /// treats a selection change as the same view moving and slides it there — rather
    /// than one fill switching off and another switching on.
    @Namespace private var highlight
    @Environment(\.motion) private var motion

    var body: some View {
        if state.historyMode { history } else { aliases }
    }

    // MARK: History

    private var history: some View {
        let commands = state.historyResults
        return Group {
            if commands.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath",
                               title: state.query.isEmpty
                                   ? "Nothing readable in \(HistoryScanner.path.hasSuffix(".zsh_history") ? "~/.zsh_history" : "your history file")"
                                   : "Nothing you have run matches \"\(state.query)\"",
                               hint: "⌘H goes back to your aliases.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WHAT YOU HAVE RUN")
                            .font(.system(size: 9, weight: .bold))
                            .kerning(0.7)
                            .foregroundStyle(theme.faint)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 2)

                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            HistoryRow(command: command,
                                       selected: state.selection == index,
                                       suggestion: state.suggestedName(for: command.text),
                                       highlight: highlight)
                                .onTapGesture { state.selection = index; state.run(command) }
                                .arriving(index)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .animation(motion(Motion.standard), value: state.selection)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Aliases

    private var aliases: some View {
        let results = state.results
        return Group {
            if results.isEmpty {
                if state.query.isEmpty {
                    // An empty bucket is not an empty file, and saying the second when
                    // the first is true would send someone to check their zshrc.
                    if state.bucket != .all {
                        EmptyStateView(symbol: state.bucket.symbol,
                                       title: "Nothing in \(state.bucket.label.lowercased())",
                                       hint: "Esc shows everything again.")
                    } else {
                        TeachingEmptyState(hotkey: settings.hotkeyEnabled
                                               ? settings.hotkey.displayString
                                               : nil,
                                           create: { state.editor = .create() })
                    }
                } else {
                    NoMatchView(query: state.query,
                                create: { state.editor = .create(name: state.query) })
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        // At rest there is no answer yet, so nothing gets the primary
                        // treatment. Promoting an arbitrary entry into a big card would
                        // be the interface asserting something it does not know.
                        if state.query.isEmpty {
                            Text(restLabel)
                                .font(.system(size: 9, weight: .bold))
                                .kerning(0.7)
                                .foregroundStyle(theme.faint)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 2)
                        }

                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            Group {
                                if index == 0 && !state.query.isEmpty {
                                    PrimaryResult(entry: entry,
                                                  selected: state.selection == 0,
                                                  conflicts: state.store.conflicts(for: entry.name),
                                                  highlight: highlight)
                                        .onTapGesture { state.selection = 0; activate(entry) }
                                } else {
                                    AlternateRow(entry: entry,
                                                 selected: state.selection == index,
                                                 highlight: highlight)
                                        .onTapGesture { state.selection = index; activate(entry) }
                                }
                            }
                            .arriving(index)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    // The capsule below only travels if the selection change is animated.
                    // Animating the container rather than each caller means every route
                    // into the selection — arrows, typing, a click — moves it the same way.
                    .animation(motion(Motion.standard), value: state.selection)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Names the rest state honestly. With no shell history to rank by, calling the list
    /// "most used" would be a lie — and with a bucket applied, so would any label that
    /// is not the bucket's own name.
    private var restLabel: String {
        if state.bucket != .all { return state.bucket.label.uppercased() }
        return state.store.mostUsed.isEmpty ? "YOUR ALIASES" : "MOST USED"
    }

    private func activate(_ entry: RankedEntry) {
        state.perform(settings.enterAction, on: entry)
    }
}

private struct PrimaryResult: View {
    @Environment(\.theme) private var theme
    let entry: RankedEntry
    let selected: Bool
    let conflicts: [Conflict]
    let highlight: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                KindBadge(kind: entry.entry.kind, size: 24)
                Text(entry.name)
                    .font(.system(size: 21, weight: .semibold, design: theme.nameDesign))
                    .foregroundStyle(theme.text)
                if !conflicts.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help(conflicts.map(\.reason.headline).joined(separator: " · "))
                }
                Spacer(minLength: 4)
                if entry.uses > 0 {
                    Text("\(entry.uses)×")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.faint)
                        .help("Run \(entry.uses) times, per your shell history")
                }
            }

            if let comment = entry.entry.comment {
                Text(comment)
                    .font(.system(size: 13.5, design: theme.bodyDesign))
                    .foregroundStyle(theme.dim)
                    .lineLimit(2)
            }

            CommandText(command: entry.entry.command, lineLimit: 4, size: 13.5)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface,
                            in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 3))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius + 3)
                .strokeBorder(theme.rule.opacity(0.35), lineWidth: 1)
        )
        .background {
            if selected {
                SelectionCapsule(radius: theme.cornerRadius + 3, namespace: highlight)
            }
        }
        .contentShape(Rectangle())
    }
}

/// One command out of your shell history.
///
/// Reads as a terminal line rather than as a list row, because that is what it is — the
/// command is shown in full, monospaced, with the count carried quietly at the end.
private struct HistoryRow: View {
    @Environment(\.theme) private var theme
    let command: HistoryScanner.Command
    let selected: Bool
    /// The alias name ⌘↩ would propose. Shown only on the selected row: on every row it
    /// would be noise, and on none of them the shortcut is invisible.
    let suggestion: String
    let highlight: Namespace.ID

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("$")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.accent.opacity(0.7))
            Text(command.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask(
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 24)
                    }
                )
            if selected && !suggestion.isEmpty {
                Text("⌘↩ \(suggestion)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.accent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            }
            Text("\(command.count)×")
                .font(.system(size: 9.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(theme.faint)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if selected {
                SelectionCapsule(radius: theme.cornerRadius + 1, namespace: highlight)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The travelling selection highlight.
///
/// Exactly one of these exists at a time. Giving it a stable identity across rows is
/// what lets it slide instead of blink; the effect is the thing people describe as
/// feeling expensive without being able to name it.
private struct SelectionCapsule: View {
    @Environment(\.theme) private var theme
    let radius: CGFloat
    let namespace: Namespace.ID

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(theme.selectionFill)
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(theme.selectionStroke, lineWidth: 1.5))
            .matchedGeometryEffect(id: "selection", in: namespace)
    }
}

private struct AlternateRow: View {
    @Environment(\.theme) private var theme
    let entry: RankedEntry
    let selected: Bool
    let highlight: Namespace.ID

    var body: some View {
        HStack(spacing: 8) {
            KindBadge(kind: entry.entry.kind, size: 18)
            Text(entry.name)
                .font(.system(size: 14.5, weight: .medium, design: theme.nameDesign))
                // Monospaced faces set loose by default. Names here are shell tokens read
                // as single units, and a touch of negative tracking makes them cohere.
                .kerning(-0.15)
                .foregroundStyle(theme.text)
                .layoutPriority(1)
            Text(entry.entry.comment ?? entry.entry.command
                    .replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(.system(size: 12.5, design: theme.bodyDesign))
                .foregroundStyle(theme.dim.opacity(0.72))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Fades the tail instead of chopping it with an ellipsis. Taking the
                // width from a fixed-width gradient rather than a proportional stop
                // keeps the fade the same length on every row, and on a short command
                // it falls over empty space and does nothing.
                .mask(
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 24)
                    }
                )
            if entry.uses > 0 {
                Text("\(entry.uses)×")
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(theme.faint)
                    // A fixed trailing column, so the counts line up down the list
                    // instead of ragging with the length of each command.
                    .frame(width: 34, alignment: .trailing)
            } else {
                Spacer().frame(width: 34)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            if selected {
                SelectionCapsule(radius: theme.cornerRadius + 1, namespace: highlight)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - BOARD

/// Every alias at once, as a keycap grid.
///
/// Alias names are two to four characters, so a list wastes the screen: it shows eight
/// where a grid shows fifty. Typing dims non-matches instead of removing them, which
/// keeps every key in the same place forever. That stability is the whole point: it is
/// what lets you learn where things are instead of re-reading a list that reshuffles on
/// every keystroke.
struct BoardView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: settings.boardDensity.keyWidth), spacing: 6)]
    }

    var body: some View {
        let entries = state.boardEntries
        VStack(spacing: 0) {
            if entries.isEmpty {
                if state.bucket != .all {
                    EmptyStateView(symbol: state.bucket.symbol,
                                   title: "Nothing in \(state.bucket.label.lowercased())",
                                   hint: "Esc shows everything again.")
                } else {
                    EmptyStateView(symbol: "square.grid.3x3",
                                   title: "Nothing to show",
                                   hint: "⌘N writes your first alias.")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            Keycap(entry: entry,
                                   selected: state.selection == index,
                                   dimmed: !state.boardMatches(entry),
                                   density: settings.boardDensity,
                                   action: {
                                       state.selection = index
                                       state.perform(settings.enterAction, on: entry)
                                   })
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: .infinity)

                Rectangle().fill(theme.rule.opacity(0.5)).frame(height: 1)
                readout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Fixed-height footer. The focused key's details go here rather than inline so
    /// nothing in the grid moves as the selection travels.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let entry = state.selectedEntry {
                HStack(spacing: 7) {
                    KindBadge(kind: entry.entry.kind, size: 15)
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: .semibold, design: theme.nameDesign))
                        .foregroundStyle(theme.text)
                    if let comment = entry.entry.comment {
                        Text(comment)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.dim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if entry.uses > 0 {
                        Text("\(entry.uses)×")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(theme.faint)
                    }
                }
                CommandText(command: entry.entry.command, lineLimit: 1, size: 11)
            } else {
                Text("Nothing selected")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.faint)
            }
        }
        .frame(height: 54, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct Keycap: View {
    @Environment(\.theme) private var theme
    let entry: RankedEntry
    let selected: Bool
    let dimmed: Bool
    let density: BoardDensity
    let action: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            Text(entry.name)
                .font(.system(size: density == .dense ? 12.5 : 14.5,
                              weight: .semibold, design: theme.nameDesign))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if density == .comfortable && entry.uses > 0 {
                Text("\(entry.uses)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(theme.faint)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: density.keyHeight)
        .background(selected ? theme.selectionFill : theme.surface,
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 2))
        // Two shadows, not one: a tight contact shadow that says the key is sitting on
        // the surface, and a wide ambient one that says the whole thing is lit from
        // somewhere. A single mid-blur drop shadow is the most recognisable tell of
        // generated UI work, and it reads flat because nothing in the world casts one.
        .shadow(color: .black.opacity(theme.isLight ? 0.10 : 0.28), radius: 1.5, y: 1)
        .shadow(color: .black.opacity(theme.isLight ? 0.06 : 0.20), radius: 10, y: 5)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
                .strokeBorder(selected ? theme.selectionStroke
                                       : theme.tint(for: entry.entry.kind).opacity(0.35),
                              lineWidth: selected ? 1.5 : 1)
        )
        // The lit upper lip, matching the window's. On a keycap it is doing the literal
        // job it was invented for.
        .overlay {
            if !theme.isLight {
                RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .clear],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1)
            }
        }
        // Dimming rather than hiding: the grid never reflows, so position stays learnable.
        .opacity(dimmed ? 0.22 : 1)
        .contentShape(Rectangle())
        // A key travels when you press it. One point is enough to feel and small enough
        // that a grid of fifty does not look like it is breathing.
        .live(pressDrop: 1, action: action)
    }
}

// MARK: - MANAGE

/// The cold path, where browsing is the correct behaviour rather than a failure.
struct ManageView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(theme.rule.opacity(0.5)).frame(width: 1)
            list
            Rectangle().fill(theme.rule.opacity(0.5)).frame(width: 1)
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Bucket.allCases) { bucket in
                bucketRow(bucket)
            }
            Spacer()
            Button { state.editor = .create() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text("New alias").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
            }
            .buttonStyle(.plain)
            .help("New alias — ⌘N")
        }
        .padding(8)
        // Narrower than it was, because the window is. The two fixed panes give up what
        // they can spare so the detail pane — the one holding a whole command — keeps a
        // usable width at 660.
        .frame(width: 172)
    }

    private func bucketRow(_ bucket: Bucket) -> some View {
        let active = state.bucket == bucket
        let count = countFor(bucket)
        return HStack(spacing: 6) {
            Image(systemName: bucket.symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .foregroundStyle(active ? theme.accent : theme.dim)
            Text(bucket.label)
                .font(.system(size: 13, weight: active ? .semibold : .regular,
                              design: theme.bodyDesign))
                .foregroundStyle(active ? theme.text : theme.dim)
            Spacer(minLength: 2)
            Text("\(count)")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(bucket == .conflicts && count > 0 ? .orange : theme.faint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(active ? theme.selectionFill : .clear,
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
        .contentShape(Rectangle())
        .live { state.bucket = bucket; state.selection = 0 }
    }

    private func countFor(_ bucket: Bucket) -> Int {
        switch bucket {
        case .all: return state.store.ranked.count
        case .functions: return state.store.functions.count
        case .aliases: return state.store.aliases.count
        case .mostUsed: return state.store.mostUsed.count
        case .neverRun: return state.store.neverRun.count
        case .byFile: return state.store.byFile.count
        case .conflicts: return state.store.conflicts.count
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(state.bucketEntries.enumerated()), id: \.element.id) { index, entry in
                        manageRow(entry, index: index)
                            .id(entry.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: state.selection) { _ in
                guard let entry = state.selectedEntry else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(entry.id, anchor: .center) }
            }
        }
        .frame(width: 224)
    }

    private func manageRow(_ entry: RankedEntry, index: Int) -> some View {
        let selected = state.selection == index
        return HStack(spacing: 6) {
            KindBadge(kind: entry.entry.kind, size: 14)
            Text(entry.name)
                .font(.system(size: 13, weight: .medium, design: theme.nameDesign))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 2)
            if entry.entry.managed {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.accent.opacity(0.7))
                    .help("Written by AliasBar, so it can be edited here")
            }
            if entry.uses > 0 {
                Text("\(entry.uses)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.faint)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(selected ? theme.selectionFill : .clear,
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .contentShape(Rectangle())
        .live { state.selection = index }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = state.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        KindBadge(kind: entry.entry.kind, size: 18)
                        Text(entry.name)
                            .font(.system(size: 17, weight: .semibold, design: theme.nameDesign))
                            .foregroundStyle(theme.text)
                        Spacer()
                    }

                    if let comment = entry.entry.comment {
                        Text(comment)
                            .font(.system(size: 11.5, design: theme.bodyDesign))
                            .foregroundStyle(theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    CommandText(command: entry.entry.command, lineLimit: nil, size: 13)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surface,
                                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))

                    ForEach(state.store.conflicts(for: entry.name)) { conflict in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.orange)
                                Text(conflict.reason.headline)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(theme.text)
                            }
                            Text(conflict.reason.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                    }

                    metadata(entry)

                    // Two rows rather than one. Four labelled buttons do not fit across a
                    // 262pt pane, and a row that silently truncates "Copy command" to
                    // "Copy com…" is worse than a row that wraps on purpose.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            detailButton("Copy name", "doc.on.doc") {
                                state.perform(.copyName, on: entry)
                            }
                            detailButton("Copy command", "terminal") {
                                state.perform(.copyCommand, on: entry)
                            }
                            Spacer(minLength: 0)
                        }
                        if entry.entry.managed {
                            HStack(spacing: 6) {
                                detailButton("Edit", "pencil") { state.beginEdit(entry.entry) }
                                detailButton("Delete", "trash") { state.delete(entry.entry) }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack {
                EmptyStateView(symbol: state.bucket == .conflicts ? "checkmark.seal" : "tray",
                               title: state.bucket == .conflicts
                                   ? "No conflicts"
                                   : "Nothing in \(state.bucket.label.lowercased())",
                               hint: state.bucket == .neverRun
                                   ? "Everything you've defined has been used at least once."
                                   : "Pick another bucket on the left.")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func metadata(_ entry: RankedEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            metaRow("Source", "\(entry.entry.sourceDisplayName):\(entry.entry.line)")
            metaRow("Runs", entry.uses == 0
                    ? "never, per your shell history"
                    : "\(entry.uses)×")
            metaRow("Managed", entry.entry.managed
                    ? "yes, AliasBar can edit this"
                    : "no, hand-written")
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(theme.faint)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(theme.dim)
            Spacer(minLength: 0)
        }
    }

    private func detailButton(_ title: String, _ symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dim)
    }
}

// MARK: - Editor

struct EditorSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.editor?.mode == .create ? "New alias" : "Edit alias")
                .font(.system(size: 14, weight: .bold, design: theme.bodyDesign))
                .foregroundStyle(theme.text)

            if let binding = Binding($state.editor) {
                field("Name", binding.name, mono: true, focused: true)
                field("Command", binding.command, mono: true, focused: false)
            }

            Text("Saved into AliasBar's managed block in \(ZshrcParser.displayPath). Everything outside that block is left alone, and a timestamped backup is written first.")
                .font(.system(size: 10))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            if let error = state.errorMessage {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { state.editor = nil; state.errorMessage = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { state.commitEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.editor?.name.isEmpty ?? true
                              || state.editor?.command.isEmpty ?? true)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(theme.background)
        .onAppear { nameFocused = true }
    }

    private func field(_ label: String, _ text: Binding<String>,
                       mono: Bool, focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(theme.faint)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: mono ? .monospaced : theme.bodyDesign))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.surface,
                            in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
                .focused($nameFocused, equals: focused)
        }
    }
}

// MARK: - Removal confirmation

/// Shown when a delete would take more than the alias asked for.
///
/// The writer can prove a line is safe to remove, but it cannot know whether the extra
/// thing sharing that line still matters to you. So instead of refusing and telling you to
/// go edit the file by hand, it shows the exact lines. A person reads
/// `alias gs='git status'; echo hi` and knows instantly whether that `echo` is load
/// bearing, which is a judgement no amount of shell parsing can make for them.
struct RemovalConfirmSheet: View {
    @ObservedObject var state: AppState
    let confirmation: AppState.RemovalConfirmation
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("This removes more than one thing")
                    .font(.system(size: 15, weight: .semibold, design: theme.bodyDesign))
                    .foregroundStyle(theme.text)
                Text(blurb)
                    .font(.system(size: 12, design: theme.bodyDesign))
                    .foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(confirmation.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(isSuspect(line) ? theme.text : theme.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(isSuspect(line) ? theme.accent.opacity(0.18) : Color.clear)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 180)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1)
            )

            Text("A timestamped backup is written either way, so this is reversible.")
                .font(.system(size: 11, design: theme.bodyDesign))
                .foregroundStyle(theme.faint)

            HStack(spacing: 9) {
                Spacer()
                Button("Cancel") { state.confirmRemoval = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Delete all \(confirmation.lines.count)") { confirmation.proceed() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(theme.background)
    }

    private var blurb: String {
        let n = confirmation.lines.count
        return "\(n) line\(n == 1 ? "" : "s") would be deleted from your shell config. "
            + "AliasBar can't tell whether the highlighted part still matters to you."
    }

    private func isSuspect(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == confirmation.suspect
    }
}
