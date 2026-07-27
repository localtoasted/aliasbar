import SwiftUI

// MARK: - MANAGE: Snippets bucket (PRE-251)

/// The shell sidebar's Snippets bucket: list + detail for `SnippetStore`'s
/// contents, parallel to `SuggestedManageView` in shape (its own dedicated view,
/// since a `Snippet` fits neither `[RankedEntry]` nor `Shortcut`). Reused
/// conventions throughout — row/detail styling matches `PromptManageView` and
/// `SuggestedManageView` — but every helper here is its own, not imported from
/// either: small, self-contained view code, not a shared component.
struct SnippetManageView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme
    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: 0) {
            snippetList
            Rectangle().fill(theme.rule.opacity(0.5)).frame(width: 1)
            snippetDetail
        }
    }

    // MARK: List

    private var snippetList: some View {
        let results = state.snippetManageResults
        return VStack(spacing: 0) {
            newSnippetButton
            ScrollViewReader { proxy in
                ScrollView {
                    if results.isEmpty {
                        EmptyStateView(symbol: "wand.and.stars",
                                       title: state.query.isEmpty
                                           ? "No snippets yet"
                                           : "Nothing matches \"\(state.query)\"",
                                       hint: "⌘N creates one. Turn on inline expansion in "
                                           + "Settings → Expansion to have triggers expand "
                                           + "as you type, anywhere.")
                            .padding(.top, 32)
                    } else {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, snippet in
                                snippetRow(snippet, index: index)
                                    .id(snippet.id)
                            }
                        }
                        .padding(6)
                    }
                }
                .onChange(of: state.selection) { _ in
                    guard let selected = state.selectedSnippet else { return }
                    withAnimation(motion.selectionScroll) { proxy.scrollTo(selected.id, anchor: .center) }
                }
            }
        }
        .frame(width: 224)
    }

    private var newSnippetButton: some View {
        Button(action: { state.beginCreateSnippet() }) {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("New snippet").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
        }
        .buttonStyle(.plain)
        .padding(8)
        .help("New snippet. Press ⌘N.")
    }

    private func snippetRow(_ snippet: Snippet, index: Int) -> some View {
        let selected = state.selection == index
        return HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .foregroundStyle(theme.accent.opacity(0.85))
            Text(snippet.trigger)
                .font(.system(size: 13, weight: .medium, design: theme.nameDesign))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(selected ? theme.selectionFill : .clear,
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .contentShape(Rectangle())
        .live { state.selection = index }
    }

    // MARK: Detail

    @ViewBuilder
    private var snippetDetail: some View {
        if let snippet = state.selectedSnippet {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.accent)
                        Text(snippet.trigger)
                            .font(.system(size: 17, weight: .semibold, design: theme.nameDesign))
                            .foregroundStyle(theme.text)
                        Spacer()
                        actionButton("Edit", "pencil", prominent: false) {
                            state.beginEditSnippet(snippet)
                        }
                    }

                    styledTemplate(snippet.template)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.dim)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                            .strokeBorder(theme.rule.opacity(0.35), lineWidth: 1))

                    metaRow("Holes", holesSummary(snippet.template))
                    metaRow("Edited", Self.editedDateFormatter.string(from: snippet.modifiedAt))

                    InfoBanner(text: "Turn on inline expansion in Settings > Expansion. "
                               + "AliasBar skips password and secure fields.")

                    actionButton("Delete", "trash", prominent: false) {
                        state.deleteSnippet(snippet)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
        } else {
            EmptyStateView(symbol: "wand.and.stars",
                            title: "Nothing selected",
                            hint: "↑↓ to pick a snippet.")
                .frame(maxWidth: .infinity)
        }
    }

    /// The same span-driven highlighting `PromptManageView`'s Library detail and
    /// `PromptFindView`'s preview use — built from `PromptSlotParser.scan`, the
    /// one grammar both prompts' `{{slots}}` and snippets' `{{holes}}` share, so
    /// none of these three previews can ever disagree about what counts as one.
    private func styledTemplate(_ template: String) -> Text {
        PromptSlotParser.scan(template).reduce(Text("")) { acc, span in
            switch span {
            case .literal(let text):
                return acc + Text(text)
            case .slot(let name):
                return acc + Text("{{\(name)}}").foregroundColor(theme.accent).fontWeight(.semibold)
            }
        }
    }

    private func holesSummary(_ template: String) -> String {
        let holes = PromptSlotParser.slots(in: template)
        return holes.isEmpty ? "none" : holes.joined(separator: ", ")
    }

    private static let editedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.faint)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.dim)
            Spacer(minLength: 0)
        }
    }

    private func actionButton(_ title: String, _ symbol: String, prominent: Bool,
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
    }
}

// MARK: - Snippet create/edit sheet

/// The "small sheet" the packet calls for — not the Composer, deliberately (v1
/// keeps snippets Manage-owned, one less kind in ⌘N). Shares the Composer's visual
/// shape (a labeled field, a themed body editor, live validation, Cancel/Save) but
/// is its own view over its own tiny `SnippetEditTarget`, not a third `EditTarget`
/// kind.
struct SnippetEditorSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case trigger }

    var body: some View {
        if let binding = Binding($state.snippetEditor) {
            let target = binding.wrappedValue
            VStack(alignment: .leading, spacing: 12) {
                Text(target.mode == .create ? "New snippet" : "Edit snippet")
                    .font(.system(size: 14, weight: .bold, design: theme.bodyDesign))
                    .foregroundStyle(theme.text)

                triggerField(binding)
                templateEditor(binding)
                slotSummary(target.template)
                liveValidation(target)

                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { state.snippetEditor = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { state.commitSnippetEditor() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!state.canSaveSnippet(target))
                }
            }
            .padding(16)
            .frame(width: 380)
            .background(theme.background)
            .onAppear { focusedField = .trigger }
        }
    }

    private func triggerField(_ binding: Binding<SnippetEditTarget>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("TRIGGER")
                .font(.system(size: 9, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(theme.faint)
            TextField("", text: binding.trigger)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
                .focused($focusedField, equals: .trigger)
        }
    }

    private func templateEditor(_ binding: Binding<SnippetEditTarget>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("TEMPLATE")
                .font(.system(size: 9, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(theme.faint)
            // The exact same editor the prompt Composer uses, `{{hole}}` highlighting
            // and all — it knows nothing about prompts specifically, so a snippet's
            // template is just another body to it.
            PromptBodyEditor(text: binding.template,
                             accentColor: NSColor(theme.accent),
                             textColor: NSColor(theme.text),
                             font: .monospacedSystemFont(ofSize: 12.5, weight: .regular))
                .frame(minHeight: 110, maxHeight: 170)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func slotSummary(_ template: String) -> some View {
        let holes = PromptSlotParser.slots(in: template)
        if !holes.isEmpty {
            HStack(spacing: 4) {
                ForEach(holes, id: \.self) { hole in
                    Text("{{\(hole)}}")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(theme.accent.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func liveValidation(_ target: SnippetEditTarget) -> some View {
        if let error = state.snippetTriggerValidation(trigger: target.trigger, excluding: target.originalID) {
            Text(error.errorDescription ?? "")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if target.template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("A snippet needs a template to expand into.")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
