import SwiftUI

// MARK: - MANAGE: prompt dialect (Library / Delivery / Health) — PRE-262

/// The list+detail pair MANAGE shows in place of the shell buckets' `list`/`detail`
/// whenever `state.dialect == .prompt`. `ManageView` in Views.swift only decides
/// *whether* this appears — everything about what it looks like and does lives here.
struct PromptManageView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme

    var body: some View {
        ManageListDetail {
            promptList
        } detail: {
            promptDetail
        }
    }

    // MARK: List

    private var promptList: some View {
        let results = state.promptManageResults
        return ManageListScrollView(selection: state.selection,
                                    scrollTarget: state.selectedPromptManageShortcut?.id) {
            if results.isEmpty {
                VStack(spacing: 10) {
                    EmptyStateView(symbol: emptySymbol,
                                   title: emptyTitle,
                                   hint: emptyHint)
                        .padding(.top, 40)
                    if showsEmptyLibraryHint {
                        DismissibleInfoBanner(text: AppState.promptLibraryEmptyHint,
                                              onDismiss: state.dismissPromptLibraryHint)
                            .padding(.horizontal, 8)
                    }
                }
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, shortcut in
                        promptManageRow(shortcut, index: index)
                            .id(shortcut.id)
                    }
                }
                .padding(6)
            }
        }
    }

    private var emptySymbol: String {
        state.promptBucket == .health ? "checkmark.seal" : state.promptBucket.symbol
    }

    private var emptyTitle: String {
        switch state.promptBucket {
        case .library: return state.query.isEmpty ? "No prompts yet" : "Nothing matches \"\(state.query)\""
        case .delivery: return state.query.isEmpty ? "No prompts yet" : "Nothing matches \"\(state.query)\""
        case .health: return "No prompt issues"
        case .inbox:
            // Unreachable: `ManageView` routes `.inbox` to `InboxView` before this
            // type ever renders — kept only so the switch stays exhaustive.
            return ""
        }
    }

    private var emptyHint: String {
        "⇥ shows your shell aliases instead."
    }

    /// Setup guidance belongs beside the empty state, but it has its own close control
    /// and disappears everywhere after that control is used.
    private var showsEmptyLibraryHint: Bool {
        state.query.isEmpty && state.promptBucket != .health && state.showsPromptLibraryHint
    }

    private func promptManageRow(_ shortcut: Shortcut, index: Int) -> some View {
        let selected = state.selection == index
        return ManageListRow(selected: selected, onSelect: { state.selection = index }) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .foregroundStyle(theme.accent.opacity(0.85))
            Text(shortcut.name)
                .font(.system(size: 13, weight: .medium, design: theme.nameDesign))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            if shortcut.isPinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .accessibilityLabel("Pinned")
            }
            Spacer(minLength: 2)
            rowTrailer(shortcut)
        }
    }

    /// The one piece of context worth a glance from the list alone, without opening
    /// the detail pane — which piece depends on which bucket you're looking at.
    @ViewBuilder
    private func rowTrailer(_ shortcut: Shortcut) -> some View {
        switch state.promptBucket {
        case .library:
            if shortcut.uses > 0 {
                Text("\(shortcut.uses)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.faint)
            }
        case .delivery:
            let status = state.promptDeliveryStatus(for: shortcut)
            if status != .notInstalled {
                Image(systemName: status == .installed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status == .installed ? theme.accent : .orange)
            }
        case .health:
            let count = state.promptHealthIssues(for: shortcut).count
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange)
        case .inbox:
            // Unreachable — see `emptyTitle`'s matching comment.
            EmptyView()
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var promptDetail: some View {
        if let shortcut = state.selectedPromptManageShortcut {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header(shortcut)
                    switch state.promptBucket {
                    case .library: libraryDetail(shortcut)
                    case .delivery: deliveryDetail(shortcut)
                    case .health: healthDetail(shortcut)
                    case .inbox:
                        // Unreachable — see `emptyTitle`'s matching comment.
                        EmptyView()
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
        } else {
            EmptyStateView(symbol: "text.book.closed",
                            title: "Nothing selected",
                            hint: "↑↓ to pick a prompt.")
                .frame(maxWidth: .infinity)
        }
    }

    private func header(_ shortcut: Shortcut) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(shortcut.name)
                .font(.system(size: 17, weight: .semibold, design: theme.nameDesign))
                .foregroundStyle(theme.text)
            Spacer()
            PinButton(pinned: state.isPinned(shortcut), name: shortcut.name) {
                state.togglePin(shortcut)
            }
            // Present in every bucket, including Health: an Edit/view action is
            // explicitly fine even for a stale-only or colliding-only diagnosis — it's
            // the destructive actions Health withholds, never this one. ⌘E does the
            // same thing from the keyboard.
            ManageActionButton("Edit", "pencil", style: .standard) {
                state.beginEditPrompt(shortcut)
            }
        }
    }

    // --- Library --------------------------------------------------------------

    private func libraryDetail(_ shortcut: Shortcut) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description = shortcut.description {
                Text(description)
                    .font(.system(size: 11.5, design: theme.bodyDesign))
                    .foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            styledBody(shortcut.body)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.dim)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.35), lineWidth: 1))

            ManageMetaRow("Slots", shortcut.slots.isEmpty ? "none" : shortcut.slots.joined(separator: ", "))
            ManageMetaRow("Edited", shortcut.editedAt.map(Self.editedDateFormatter.string) ?? "unknown")
            ManageMetaRow("Usage", shortcut.uses == 0 ? "never, on this Mac" : "\(shortcut.uses)× on this Mac")
        }
    }

    /// The same span-driven highlighting `PromptFindView`'s preview uses — built
    /// straight from `PromptSlotParser.scan`, never a second regex scan of the same
    /// grammar, so the two previews can never disagree about what counts as a slot.
    private func styledBody(_ body: String) -> Text {
        PromptSlotParser.scan(body).reduce(Text("")) { acc, span in
            switch span {
            case .literal(let text):
                return acc + Text(text)
            case .slot(let name):
                return acc + Text("{{\(name)}}").foregroundColor(theme.accent).fontWeight(.semibold)
            }
        }
    }

    private static let editedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    // --- Delivery ---------------------------------------------------------------

    private func deliveryDetail(_ shortcut: Shortcut) -> some View {
        let status = state.promptDeliveryStatus(for: shortcut)
        return VStack(alignment: .leading, spacing: 10) {
            InfoBanner(text: "Saving a prompt does not install it in Claude Code. "
                       + "Install it here when you want a slash command.")

            switch status {
            case .notInstalled:
                Text(shortcut.uses > 0
                     ? "Used ×\(shortcut.uses) on this Mac. Install /\(shortcut.name) in Claude Code?"
                     : "Not installed in Claude Code.")
                    .font(.system(size: 12, design: theme.bodyDesign))
                    .foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                ManageActionButton("Install as /\(shortcut.name)", "arrow.up.circle.fill", style: .prominent) {
                    state.installPrompt(shortcut)
                }
                collisionAdvisory(for: shortcut.name)

            case .installed:
                Label("Installed as /\(shortcut.name) in Claude Code", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.accent)
                ManageActionButton("Uninstall", "arrow.down.circle", style: .standard) {
                    state.uninstallPrompt(shortcut)
                }

            case .stale:
                Label("Prompt changed after /\(shortcut.name) was installed",
                      systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                HStack(spacing: 6) {
                    ManageActionButton("Reinstall (overwrite)", "arrow.triangle.2.circlepath", style: .prominent) {
                        state.installPrompt(shortcut)
                    }
                    ManageActionButton("Uninstall", "arrow.down.circle", style: .standard) {
                        state.uninstallPrompt(shortcut)
                    }
                }
                collisionAdvisory(for: shortcut.name)
            }

            if let error = state.errorMessage {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A builtin-name shadow is advisory only — `PromptCompiler` never blocks on it —
    /// so this is a quiet note near the install action, not a warning banner of its
    /// own.
    @ViewBuilder
    private func collisionAdvisory(for name: String) -> some View {
        if BuiltinSlashCommands.collides(name: name) != nil {
            Text("\(BuiltinSlashCommands.version) already defines /\(name). Installing this prompt shadows the built-in command.")
                .font(.system(size: 10))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // --- Health -------------------------------------------------------------

    private func healthDetail(_ shortcut: Shortcut) -> some View {
        let issues = state.promptHealthIssues(for: shortcut)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text(issue.headline)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.text)
                    }
                    Text(issue.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
            }

            // Deliberately no delete/uninstall action here: a stale-only or
            // colliding-only diagnosis is a "worth a look", never a "worth removing"
            // — the packet is explicit that Health never offers anything destructive.
            ManageActionButton("Reveal in Finder", "folder", style: .standard) {
                state.revealPromptFile(shortcut)
            }
        }
    }
}

// MARK: - MANAGE: Suggested (history-mined alias suggestions) — PRE-262 shell-side

/// The shell sidebar's Suggested bucket: `SuggestionEngine`'s output (PRE-264's
/// core), presented the mirror image of the shell graveyard buckets — where
/// `neverRun` says "you never run this, delete it?", this says "you use this
/// constantly, make it an alias."
struct SuggestedManageView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme

    var body: some View {
        ManageListDetail {
            suggestionList
        } detail: {
            suggestionDetail
        }
    }

    private var suggestionList: some View {
        let results = state.suggestedEntries
        return ManageListScrollView(selection: state.selection,
                                    scrollTarget: state.selectedSuggestion?.id) {
            if results.isEmpty {
                // `state.suggestedEntries` is unconditionally empty while
                // `historyUsageRankingEnabled` is off (`refreshSuggestions`'s own
                // guard), so the reason worth stating changes too — this isn't
                // "nothing repeats yet", it's "nothing is being mined at all".
                EmptyStateView(symbol: "sparkles",
                               title: !settings.historyUsageRankingEnabled
                                   ? "History-based suggestions are off"
                                   : (state.query.isEmpty
                                       ? "Nothing repeats often enough yet"
                                       : "Nothing matches \"\(state.query)\""),
                               hint: !settings.historyUsageRankingEnabled
                                   ? "Turn on history usage ranking in Settings to mine your shell history for repeats."
                                   : "A command has to show up 5+ times, at 2+ words, to qualify.")
                    .padding(.top, 40)
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, suggestion in
                        suggestionRow(suggestion, index: index)
                            .id(suggestion.id)
                    }
                }
                .padding(6)
            }
        }
    }

    private func suggestionRow(_ suggestion: AliasSuggestion, index: Int) -> some View {
        let selected = state.selection == index
        return ManageListRow(selected: selected, onSelect: { state.selection = index }) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .foregroundStyle(theme.accent.opacity(0.85))
            Text(suggestion.proposedName)
                .font(.system(size: 13, weight: .medium, design: theme.nameDesign))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text("\(suggestion.count)×")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.faint)
        }
    }

    @ViewBuilder
    private var suggestionDetail: some View {
        if let suggestion = state.selectedSuggestion {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.accent)
                        Text(suggestion.proposedName)
                            .font(.system(size: 17, weight: .semibold, design: theme.nameDesign))
                            .foregroundStyle(theme.text)
                        Spacer()
                    }

                    // Mirrors the shell graveyard's framing: `neverRun` says "you
                    // never run this, delete it?" — this is that sentence's opposite.
                    Text("Used \(suggestion.count) times. Create an alias?")
                        .font(.system(size: 11.5, design: theme.bodyDesign))
                        .foregroundStyle(theme.dim)

                    CommandText(command: suggestion.command, lineLimit: nil, size: 12)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))

                    InfoBanner(text: "AliasBar found this command in your shell history. "
                               + "Ignore hides the suggestion.")

                    HStack(spacing: 6) {
                        ManageActionButton("Create", "plus.circle.fill", style: .prominent) {
                            state.createFromSuggestion(suggestion)
                        }
                        ManageActionButton("Rename", "pencil", style: .standard) {
                            state.renameFromSuggestion(suggestion)
                        }
                        ManageActionButton("Ignore", "eye.slash", style: .standard) {
                            state.ignoreSuggestion(suggestion)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("The name and command are ready. Save to create the alias.")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.faint)

                    Spacer(minLength: 0)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
        } else {
            EmptyStateView(symbol: "sparkles",
                            title: "Nothing selected",
                            hint: "↑↓ to pick a suggestion.")
                .frame(maxWidth: .infinity)
        }
    }

}

// MARK: - Shared: the local-only/read-only note

/// A quiet inline note, not a modal warning — the convention this codebase already
/// uses for "here's context worth knowing before you act" (see the conflict-lines
/// callout in `ManageView.detail` and the disclaimer line in `EditorSheet`, Views.swift).
/// Reused across Delivery, Health, and Suggested so the three surfaces this slice
/// adds all say "this is local, this is machine-scoped, nothing has left your
/// control" in exactly the same visual voice.
struct InfoBanner: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.dim)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
    }
}

/// Setup help with an explicit, durable exit. This is separate from `InfoBanner`
/// because delivery and safety notices are part of the current task; the empty-library
/// review CTA is not.
struct DismissibleInfoBanner: View {
    @Environment(\.theme) private var theme
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.faint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dim)
            .accessibilityLabel("Dismiss library setup hint")
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
            .strokeBorder(theme.rule.opacity(0.45), lineWidth: 1))
    }
}
