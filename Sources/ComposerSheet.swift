import SwiftUI
import AppKit

// MARK: - Composer (PRE-267)

/// The one ⌘N sheet for creating or editing both an alias and a prompt.
///
/// This supersedes the old alias-only `EditorSheet` entirely rather than living
/// beside it — the two shared almost everything (a name field, a Cancel/Save row,
/// Esc/⌘⏎ handled one level up in `AppState.handleKey`), and forking the view would
/// have meant every future fix to that shared shell landing in only one of them.
/// The alias half below is the old sheet's exact fields and exact Save-disabled
/// rule, just drawn by a function instead of a whole second struct — its behavior
/// is unchanged, only its container is new.
///
/// Functions never appear here (frozen ruling A6): the Kind control only ever
/// offers alias | prompt, and ⌘E on a function keeps the existing read-only toast
/// from `AppState.beginEdit` rather than opening this sheet at all.
struct ComposerSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, secondary }

    var body: some View {
        if let binding = Binding($state.editor) {
            let target = binding.wrappedValue
            VStack(alignment: .leading, spacing: 12) {
                Text(title(for: target))
                    .font(.system(size: 14, weight: .bold, design: theme.bodyDesign))
                    .foregroundStyle(theme.text)

                // Hidden rather than disabled while `promptFeaturesEnabled` is off:
                // with no prompt dialect anywhere else in the app, offering a
                // reachable-but-blocked "Prompt" segment here would be the one place
                // that still let someone create a prompt file the rest of the app
                // claims doesn't exist.
                if state.settings.promptFeaturesEnabled {
                    kindPicker(target)
                }

                if !target.flagReasons.isEmpty {
                    inboxFlagBanner(binding)
                }

                switch target.kind {
                case .alias: aliasFields(binding)
                case .prompt: promptFields(binding)
                }

                destinationFooter(target)

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
                        .disabled(!canSave(target))
                }
            }
            .padding(16)
            .frame(width: target.kind == .prompt ? 460 : 380)
            .background(theme.background)
            .onAppear { focusedField = .name }
        }
    }

    private func title(for target: EditTarget) -> String {
        switch (target.kind, target.mode) {
        case (.alias, .create): return "New alias"
        case (.alias, .edit): return "Edit alias"
        case (.prompt, .create): return "New prompt"
        case (.prompt, .edit): return "Edit prompt"
        }
    }

    private func canSave(_ target: EditTarget) -> Bool {
        guard target.flagReasons.isEmpty || target.reviewAcknowledged else { return false }
        switch target.kind {
        case .alias:
            return !target.name.isEmpty && !target.command.isEmpty
        case .prompt:
            return !target.name.isEmpty
                && !target.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: Kind control

    /// "Always switchable" — even mid-edit. Routed through `AppState.switchComposerKind`
    /// rather than writing `binding.kind` directly: switching kind while editing an
    /// existing alias or prompt can't continue as an edit of that specific thing (the
    /// two share no identity to hand off), and the state layer is where that
    /// create-vs-edit conversion is decided and tested.
    private func kindPicker(_ target: EditTarget) -> some View {
        Picker("", selection: Binding(
            get: { target.kind },
            set: { state.switchComposerKind(to: $0) }
        )) {
            Text("Alias").tag(EditTarget.Kind.alias)
            Text("Prompt").tag(EditTarget.Kind.prompt)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: Alias half — unchanged from the pre-Composer EditorSheet

    private func aliasFields(_ binding: Binding<EditTarget>) -> some View {
        let target = binding.wrappedValue
        let validation = state.composerAliasValidation(name: target.name, command: target.command,
                                                        originalName: target.originalName)
        return VStack(alignment: .leading, spacing: 10) {
            field("Name", binding.name, mono: true, field: .name)
            field("Command", binding.command, mono: true, field: .secondary)
            liveValidation(validation)
        }
    }

    // MARK: Prompt half

    private func promptFields(_ binding: Binding<EditTarget>) -> some View {
        let target = binding.wrappedValue
        let validation = state.composerPromptValidation(name: target.name, originalName: target.originalName)
        return VStack(alignment: .leading, spacing: 10) {
            field("Name", binding.name, mono: true, field: .name)
            field("Description", binding.description, mono: false, field: .secondary)
            bodyEditor(binding)
            slotSummary(target.body)
            deliveryToggle(binding)
            liveValidation(validation)
        }
    }

    /// Edit and approve carries Inbox flags into both Composer kinds. The edit path
    /// must show the same warning as direct approval.
    private func inboxFlagBanner(_ binding: Binding<EditTarget>) -> some View {
        let target = binding.wrappedValue
        return VStack(alignment: .leading, spacing: 3) {
            Label("Review before saving", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            ForEach(target.flagReasons, id: \.self) { reason in
                Text(reason).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Toggle("I reviewed this \(target.kind.rawValue)", isOn: binding.reviewAcknowledged)
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.top, 3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(.orange.opacity(0.1)))
        .accessibilityLabel("Review this Inbox item before saving")
    }

    private func bodyEditor(_ binding: Binding<EditTarget>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("BODY")
                .font(.system(size: 9, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(theme.faint)
            PromptBodyEditor(text: binding.body,
                             accentColor: NSColor(theme.accent),
                             textColor: NSColor(theme.text),
                             font: .monospacedSystemFont(ofSize: 12.5, weight: .regular))
                .frame(minHeight: 130, maxHeight: 190)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
        }
    }

    /// A chip per unique `{{slot}}` — `PromptSlotParser.slots`, never a second scan of
    /// the body, so this can never disagree with the highlighting inside the editor
    /// above about what counts as a slot.
    @ViewBuilder
    private func slotSummary(_ body: String) -> some View {
        let slots = PromptSlotParser.slots(in: body)
        if !slots.isEmpty {
            HStack(spacing: 4) {
                ForEach(slots, id: \.self) { slot in
                    Text("{{\(slot)}}")
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

    private func deliveryToggle(_ binding: Binding<EditTarget>) -> some View {
        let name = binding.wrappedValue.name
        return Toggle(isOn: binding.deliverToClaudeCode) {
            Text("Install as /\(name.isEmpty ? "name" : name) in Claude Code")
                .font(.system(size: 11.5, design: theme.bodyDesign))
                .foregroundStyle(theme.text)
        }
        .toggleStyle(.checkbox)
        .help("The prompt stays in AliasBar. Turn this on to add a Claude Code slash command.")
    }

    @ViewBuilder
    private func liveValidation(_ validation: AppState.ComposerValidation) -> some View {
        if let blocking = validation.blocking {
            Text(blocking)
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let advisory = validation.advisory {
            Text(advisory)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer: destination

    /// "Always shows the destination" — real resolved paths, abbreviated. The lines
    /// themselves come from `AppState.composerDestination(for:)`, the one place
    /// their exact text is decided (and tested); this only draws them.
    private func destinationFooter(_ target: EditTarget) -> some View {
        let lines = state.composerDestination(for: target)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                // A path line always starts with the arrow or the "also delivered to"
                // plus — anything else is the explanatory sentence underneath them.
                let isPath = line.hasPrefix("→") || line.hasPrefix("+")
                Text(line)
                    .font(.system(size: 10, design: isPath ? .monospaced : .default))
                    .foregroundStyle(isPath ? theme.dim : theme.faint)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Shared field

    private func field(_ label: String, _ text: Binding<String>, mono: Bool, field: Field) -> some View {
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
                .focused($focusedField, equals: field)
        }
    }
}

// MARK: - PromptBodyEditor

/// A body editor for prompts with `{{slot}}` occurrences colored live, as you type.
///
/// Built directly on `NSTextView` rather than SwiftUI's `TextEditor`, which has no
/// way to color individual runs of its own text on the OS versions this app
/// targets. Highlighting is driven by `PromptSlotParser.scan` — never a second regex
/// pass — so the Composer can never disagree with FIND's preview or Manage's
/// Library detail about what counts as a slot.
struct PromptBodyEditor: NSViewRepresentable {
    @Binding var text: String
    var accentColor: NSColor
    var textColor: NSColor
    var font: NSFont

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = font
        textView.textColor = textColor
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.string = text
        context.coordinator.apply(to: textView, text: text)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // Only pushed when the text differs from what the view already holds — every
        // keystroke's own round trip through `@Binding` must not overwrite the view
        // (which would reset the caret and the undo stack); an external replacement
        // (a fresh prefill opening the sheet with different content) does need to land.
        if textView.string != text {
            textView.string = text
            context.coordinator.apply(to: textView, text: text)
        } else {
            // Colors alone can go stale (a theme change) without the text itself
            // changing — reapplied unconditionally since it's cheap for a prompt-sized
            // body.
            context.coordinator.apply(to: textView, text: text)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptBodyEditor
        init(parent: PromptBodyEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            apply(to: textView, text: textView.string)
        }

        /// Recolors `{{slot}}` runs in place via the text storage, which preserves the
        /// caret and selection — replacing `textView.string` wholesale on every
        /// keystroke would reset both and break undo.
        func apply(to textView: NSTextView, text: String) {
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: (text as NSString).length)
            storage.beginEditing()
            storage.removeAttribute(.foregroundColor, range: full)
            storage.addAttribute(.font, value: parent.font, range: full)
            storage.addAttribute(.foregroundColor, value: parent.textColor, range: full)

            // Slot names are constrained to ASCII (`PromptSlotParser.isSlotNameCharacter`),
            // so `name.count + 4` (the `{{`/`}}` delimiters) is exactly that span's
            // UTF-16 length — the same unit `NSRange` counts in — with no risk of the
            // literal-segment/slot-segment offsets drifting apart the way they could
            // for a non-ASCII literal measured only in Swift `Character`s.
            var offset = 0
            for span in PromptSlotParser.scan(text) {
                switch span {
                case .literal(let literal):
                    offset += (literal as NSString).length
                case .slot(let name):
                    let length = name.count + 4
                    let range = NSRange(location: offset, length: length)
                    if range.location + range.length <= full.length {
                        storage.addAttribute(.foregroundColor, value: parent.accentColor, range: range)
                    }
                    offset += length
                }
            }
            storage.endEditing()
        }
    }
}
