import SwiftUI

// MARK: - FIND: prompt-dialect two-pane layout (PRE-260)

/// Wraps FIND's existing result list with a preview pane on the right — entered
/// only when `state.dialect == .prompt`. Shell dialect keeps the single-pane list
/// from PRE-259 exactly as it is; `FindView.aliases` in Views.swift is the one call
/// site that decides which of the two this becomes.
///
/// `listContent` is FIND's own list, passed in whole and unmodified: this type owns
/// none of the rows, the selection, or the keyboard handling behind them, only what
/// appears beside them.
struct PromptFindPreviewLayout<ListContent: View>: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme
    let listContent: ListContent

    var body: some View {
        VStack(spacing: 0) {
            // The union pool means this layout can be showing while the library
            // itself has nothing in it yet — the list beside this banner is full of
            // shell entries, not prompts. Reusing `InfoBanner` (PromptManageView.swift)
            // rather than a full empty state: shell results are still genuinely
            // useful here, so this never replaces them, only sits above them.
            if state.showsPromptLibraryHint {
                DismissibleInfoBanner(text: AppState.promptLibraryEmptyHint,
                                      onDismiss: state.dismissPromptLibraryHint)
                    .padding(10)
            }
            HStack(spacing: 0) {
                listContent
                    .frame(width: 268, alignment: .top)
                Rectangle().fill(theme.rule.opacity(0.5)).frame(width: 1)
                PromptDetailPane(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The right-hand pane: a preview of whatever `state.selectedShortcut` currently is,
/// or an empty state when nothing qualifies — the same "no fallback to first" rule
/// the rest of FIND already follows for its selection.
private struct PromptDetailPane: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            Group {
                if let shortcut = state.selectedShortcut {
                    switch shortcut.kind {
                    case .prompt:
                        PromptPreview(state: state, shortcut: shortcut)
                    case .alias, .function:
                        ShellMinimalPreview(state: state, shortcut: shortcut)
                    }
                } else {
                    EmptyStateView(symbol: "text.book.closed",
                                   title: "Nothing selected",
                                   hint: "↑↓ to pick something to preview.")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A prompt's full detail: the body with its `{{slot}}` occurrences picked out, and
/// two chips underneath — whether it is live as a Claude Code slash command on this
/// Mac, and how often it has actually been used here.
private struct PromptPreview: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme
    let shortcut: Shortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(shortcut.name)
                    .font(.system(size: 16, weight: .semibold, design: theme.nameDesign))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 0)
                PinButton(pinned: state.isPinned(shortcut), name: shortcut.name) {
                    state.togglePin(shortcut)
                }
            }

            if let description = shortcut.description {
                Text(description)
                    .font(.system(size: 12, design: theme.bodyDesign))
                    .foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            styledBody
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.dim)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.35), lineWidth: 1))

            HStack(spacing: 6) {
                if status == .installed {
                    chip("✓ /\(shortcut.name) in Claude Code", symbol: "checkmark.circle.fill")
                }
                chip(usageText, symbol: "clock.arrow.circlepath")
                Spacer(minLength: 0)
            }

            SelectedActionHints(
                primaryKeys: "⏎",
                primaryLabel: state.settings.enterAction.needsAccessibility
                    ? "paste prompt"
                    : "copy prompt",
                secondaryKeys: "⌘⏎",
                secondaryLabel: "copy raw")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Built from `PromptSlotParser.scan`'s spans, never a regex re-scan of the same
    /// grammar — the one thing this view must never disagree with the parser about
    /// is what counts as a slot.
    private var styledBody: Text {
        PromptSlotParser.scan(shortcut.body).reduce(Text("")) { acc, span in
            switch span {
            case .literal(let text):
                return acc + Text(text)
            case .slot(let name):
                // `Text`'s per-run `.foregroundStyle(_:)` needs macOS 14; this
                // deploys to 13, so `.foregroundColor` (still fully functional,
                // merely superseded) is what a concatenated `Text` segment can
                // color itself with here.
                return acc + Text("{{\(name)}}").foregroundColor(theme.accent).fontWeight(.semibold)
            }
        }
    }

    /// Uses AppState's refresh-scoped registry/hash snapshot, shared with MANAGE and
    /// refreshed on summon and every AliasBar-owned prompt delivery mutation.
    private var status: AppState.PromptDeliveryStatus {
        state.promptDeliveryStatus(for: shortcut)
    }

    private var usageText: String {
        shortcut.uses > 0 ? "used ×\(shortcut.uses) on this Mac" : "not used yet on this Mac"
    }

    private func chip(_ text: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(theme.dim)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
    }
}

/// A shell entry's detail, deliberately minimal — this pane exists so selecting a
/// shell row while the layout is in its two-pane, prompt-favoring shape doesn't
/// leave the right side blank, not to rebuild shell's own presentation. That stays
/// `PrimaryResult`/`AlternateRow`'s job.
private struct ShellMinimalPreview: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme
    let shortcut: Shortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                KindBadge(kind: shortcut.kind == .function ? .function : .alias, size: 18)
                Text(shortcut.name)
                    .font(.system(size: 16, weight: .semibold, design: theme.nameDesign))
                    .foregroundStyle(theme.text)
                Spacer(minLength: 0)
                if shortcut.kind == .alias {
                    PinButton(pinned: state.isPinned(shortcut), name: shortcut.name) {
                        state.togglePin(shortcut)
                    }
                }
            }

            CommandText(command: shortcut.body, lineLimit: nil, size: 12)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))

            if let sourceFile = shortcut.sourceFile, let line = shortcut.line {
                Text("\((sourceFile as NSString).abbreviatingWithTildeInPath):\(line)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.faint)
            }

            SelectedActionHints(
                primaryKeys: "⏎",
                primaryLabel: state.settings.enterAction.short,
                secondaryKeys: "⌘⏎",
                secondaryLabel: state.settings.enterAction.secondary.short)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
