import SwiftUI

// MARK: - MANAGE: prompt dialect's Inbox bucket (PRE-265 UI)

/// `~/.aliasbar/inbox/*.json` reviewed one item at a time — the human half of the
/// ⌘I audit loop. `PromptManageView` owns Library/Delivery/Health; this is the
/// fourth prompt bucket's own list+detail pair, kept in its own file because a
/// review item is a different shape from a `Shortcut` and the trust-critical
/// gating (an item's Approve control only enables once its full body has actually
/// been displayed) doesn't belong mixed in with that view's other three, much
/// simpler buckets.
struct InboxView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme

    var body: some View {
        ManageListDetail {
            inboxList
        } detail: {
            inboxDetail
        }
    }

    // MARK: List

    private var inboxList: some View {
        let rows = state.inboxRows
        return ManageListScrollView(selection: state.selection,
                                    scrollTarget: state.selectedInboxRow?.id) {
            if rows.isEmpty {
                EmptyStateView(symbol: "tray",
                               title: "No suggestions to review",
                               hint: "Build suggestions in Settings, then import the copied JSON.")
                    .padding(.top, 40)
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        inboxRow(row, index: index)
                            .id(row.id)
                    }
                }
                .padding(6)
            }
        }
    }

    @ViewBuilder
    private func inboxRow(_ row: AppState.InboxRow, index: Int) -> some View {
        let selected = state.selection == index
        switch row {
        case .item(let file, let itemIndex):
            if let item = state.itemFor(file: file, index: itemIndex) {
                itemRow(item, selected: selected, index: index)
            }
        case .invalidFile(let url, _):
            invalidFileRow(url, selected: selected, index: index)
        }
    }

    private func itemRow(_ item: PromptInbox.Item, selected: Bool, index: Int) -> some View {
        ManageListRow(selected: selected, onSelect: { state.selection = index }) {
            Image(systemName: item.kind == .prompt ? "text.book.closed" : "at")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.faint)
                .frame(width: 11)
            TypeBadge(type: item.type)
            Text(item.name)
                .font(.system(size: 13, weight: .medium, design: theme.nameDesign))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 2)
            if item.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func invalidFileRow(_ url: URL, selected: Bool, index: Int) -> some View {
        ManageListRow(selected: selected, onSelect: { state.selection = index }) {
            Image(systemName: "doc.badge.exclamationmark")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .foregroundStyle(.orange)
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .medium, design: theme.nameDesign))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 2)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var inboxDetail: some View {
        if let selected = state.selectedInboxItem {
            ItemDetail(state: state, file: selected.file, index: selected.index,
                       item: selected.item, review: selected.review)
                .frame(maxWidth: .infinity)
        } else if case .invalidFile(let url, let reason) = state.selectedInboxRow {
            InvalidFileDetail(state: state, url: url, reason: reason)
                .frame(maxWidth: .infinity)
        } else {
            EmptyStateView(symbol: "tray",
                            title: "Nothing selected",
                            hint: "↑↓ to pick something to review.")
                .frame(maxWidth: .infinity)
        }
    }
}

/// One well-formed item's review pane. The trust-critical contract: unflagged
/// items are marked viewed by `.onAppear`; FLAGGED items are marked viewed only by
/// the explicit control below the complete body, so selection alone can never
/// satisfy the flag gate. The Approve button reads that recorded fact back through
/// `state.selectedInboxItemCanApprove` rather than trusting its own click.
private struct ItemDetail: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme
    let file: URL
    let index: Int
    let item: PromptInbox.Item
    let review: AppState.InboxFileReview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if item.isFlagged { flagBanner }
                switch item.type {
                case .new: bodySection
                case .update: updateDiff
                case .merge: mergeSummary
                }
                if let error = state.errorMessage {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.isFlagged && !review.viewedInFull.contains(index) {
                    Button {
                        state.markInboxItemViewed(file: file, index: index)
                    } label: {
                        Label("I reviewed this \(item.kind.label)", systemImage: "checkmark.seal")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 7).strokeBorder(.orange.opacity(0.6)))
                    .accessibilityLabel("Confirm you have read the full flagged item")
                }
                actions
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        // Fires once, the first time this specific item's pane is actually laid
        // out — never on a mere selection-index reuse, since `AppState.InboxRow`
        // gives every item a stable identity SwiftUI can key `.onAppear` against.
        .onAppear {
            // Flagged items require the explicit control above — appearing on
            // screen is not reading.
            if !item.isFlagged { state.markInboxItemViewed(file: file, index: index) }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            InboxKindBadge(kind: item.kind)
            TypeBadge(type: item.type)
            Text(item.name)
                .font(.system(size: 17, weight: .semibold, design: theme.nameDesign))
                .foregroundStyle(theme.text)
            Spacer()
        }
    }

    @ViewBuilder
    private var flagBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(item.flags.enumerated()), id: \.offset) { _, flag in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(flag.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
    }

    private var descriptionLine: some View {
        Group {
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11.5, design: theme.bodyDesign))
                    .foregroundStyle(theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The plain, complete body — never `lineLimit`, never truncated. This is the
    /// text `.onAppear` above certifies as "actually displayed": nothing about this
    /// view hides any of it behind a preview.
    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            descriptionLine
            Text(item.body)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.dim)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.35), lineWidth: 1))
        }
    }

    /// The old→new diff a proposed update shows: two columns, the existing
    /// prompt's current body on the left and the proposal's full body on the
    /// right. Plain text side by side rather than a line-level diff algorithm —
    /// the packet calls for "simple two-column text", and a prompt body is prose,
    /// not code, where a line-diff would fragment more than it would clarify.
    private var updateDiff: some View {
        VStack(alignment: .leading, spacing: 8) {
            descriptionLine
            HStack(alignment: .top, spacing: 8) {
                diffColumn(title: "CURRENT", text: state.inboxUpdateOldBody(for: item) ?? "(not found; renamed or removed)")
                diffColumn(title: "PROPOSED", text: item.body, highlighted: true)
            }
        }
    }

    private func diffColumn(title: String, text: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(theme.faint)
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.dim)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(highlighted ? theme.accent.opacity(0.10) : theme.surface,
                            in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .strokeBorder(theme.rule.opacity(0.35), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The merged-away names plus the survivor's own new body — no diff here since
    /// there's no single "old" version to diff against, only several.
    private var mergeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            descriptionLine
            VStack(alignment: .leading, spacing: 3) {
                Text("MERGES AWAY")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(theme.faint)
                ForEach(item.merges, id: \.self) { name in
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(theme.faint)
                        Text(name)
                            .font(.system(size: 11.5, design: theme.nameDesign))
                            .foregroundStyle(theme.dim)
                    }
                }
            }
            Text(item.body)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.dim)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.35), lineWidth: 1))
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            actionButton("Approve", "checkmark.circle.fill", prominent: true,
                        enabled: state.selectedInboxItemCanApprove) {
                state.approveInboxItem(file: file, index: index)
            }
            .help(item.isFlagged && !review.viewedInFull.contains(index)
                  ? "Flagged items have to be viewed in full before they can be approved."
                  : "")
            actionButton("Edit and approve", "pencil", prominent: false, enabled: true) {
                state.editInboxItem(file: file, index: index)
            }
            actionButton("Discard", "trash", prominent: false, enabled: true) {
                state.discardInboxItem(file: file, index: index)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(_ title: String, _ symbol: String, prominent: Bool, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(prominent ? theme.onAccent : theme.dim)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(prominent ? theme.accent : theme.surface,
                        in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(prominent ? .clear : theme.rule.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct InboxKindBadge: View {
    @Environment(\.theme) private var theme
    let kind: PromptInbox.ItemKind

    var body: some View {
        Label(kind == .prompt ? "PROMPT" : "ALIAS",
              systemImage: kind == .prompt ? "text.book.closed" : "at")
            .font(.system(size: 8, weight: .bold))
            .kerning(0.35)
            .foregroundStyle(theme.dim)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A file that failed `PromptInbox.scan` entirely — nothing to review item by
/// item, only the parse failure and a whole-file Discard.
private struct InvalidFileDetail: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme
    let url: URL
    let reason: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "doc.badge.exclamationmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(url.lastPathComponent)
                        .font(.system(size: 17, weight: .semibold, design: theme.nameDesign))
                        .foregroundStyle(theme.text)
                    Spacer()
                }
                InfoBanner(text: "This file couldn't be read as an inbox proposal: \(reason). "
                           + "Nothing in it was applied, and nothing else in your inbox was affected.")
                Button(action: { state.discardInboxFile(url) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 9, weight: .semibold))
                        Text("Discard this file").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(theme.dim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }
}

/// The item-type badge — new / update / merge — shared between the list row and
/// the detail header so the two can never disagree about what an item is.
private struct TypeBadge: View {
    @Environment(\.theme) private var theme
    let type: PromptInbox.ItemType

    private var symbol: String {
        switch type {
        case .new: return "plus.circle.fill"
        case .update: return "arrow.triangle.2.circlepath"
        case .merge: return "arrow.triangle.merge"
        }
    }

    private var label: String {
        switch type {
        case .new: return "NEW"
        case .update: return "UPDATE"
        case .merge: return "MERGE"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(label).font(.system(size: 8, weight: .bold)).kerning(0.4)
        }
        .foregroundStyle(theme.accent)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}
