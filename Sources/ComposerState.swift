import SwiftUI

/// The Composer sheet (PRE-267): what it currently has open, every route that opens
/// it, and the as-you-type validation both halves show.
///
/// Split out of `AppState` so the one entry point and its two validators sit
/// together. Committing an edit still lives on `AppState` alongside the shell
/// writer and the prompt store it drives — this object owns opening and checking,
/// not saving — so `editor` is reached from there through a forwarding accessor.
final class ComposerState: ObservableObject {
    /// The state that owns this. `unowned` rather than `weak` because `AppState`
    /// holds this object for its entire life, so it can never be the one that goes
    /// away first.
    private unowned let app: AppState

    init(app: AppState) {
        self.app = app
    }

    /// What the Composer sheet currently has open, or nil when it is closed.
    @Published var editor: EditTarget?

    /// The Composer's one entry point. Every route that opens the sheet — ⌘N,
    /// Suggested's Create/Rename, `promoteToAlias`, a no-match Enter in either FIND
    /// dialect, ⌘E on a prompt row, and later the inbox's edit-before-approve —
    /// funnels a `ComposerPrefill` through here rather than constructing `EditTarget`
    /// directly, so every one of them agrees about what "prefilled" means.
    func openComposer(prefill: ComposerPrefill) {
        guard prefill.kind != .prompt || app.settings.promptFeaturesEnabled else {
            app.errorMessage = "Turn on prompts before creating one."
            return
        }
        // Only `editInboxItem` ever wants this set, and it sets it itself right
        // after calling this function — so any other route into the Composer
        // clears whatever a previous, possibly-abandoned inbox edit left behind,
        // and can never have a later save misattributed to it.
        if prefill.source != "inbox" { app.inbox.pendingInboxEdit = nil }
        switch prefill.kind {
        case .alias:
            editor = EditTarget(kind: .alias, mode: prefill.mode, name: prefill.name,
                                command: prefill.body, flagReasons: prefill.flagReasons,
                                reviewAcknowledged: prefill.reviewAcknowledged,
                                originalName: prefill.originalName, source: prefill.source)
        case .prompt:
            editor = EditTarget(kind: .prompt, mode: prefill.mode, name: prefill.name,
                                command: "", description: prefill.description, body: prefill.body,
                                deliverToClaudeCode: prefill.deliverToClaudeCode,
                                flagReasons: prefill.flagReasons,
                                reviewAcknowledged: prefill.reviewAcknowledged,
                                originalName: prefill.originalName, source: prefill.source)
        }
    }

    /// The Kind segmented control: "always switchable", but switching mid-edit can't
    /// continue as an edit of the thing you had open — a shell alias and a prompt
    /// share no identity to hand off, so this converts the sheet to a fresh `.create`
    /// for the new kind. Only the name carries across: a shell command and a prompt
    /// body are different enough content that silently reinterpreting one as the
    /// other would be more confusing than starting the new kind's field empty.
    func switchComposerKind(to kind: EditTarget.Kind) {
        guard let target = editor, target.kind != kind else { return }
        // Changing kind creates a different item. If this sheet came from Inbox, the
        // original suggestion must remain pending instead of following the new item
        // into a save and being archived as approved.
        let leavesInboxEdit = target.source == "inbox"
        if leavesInboxEdit { app.inbox.pendingInboxEdit = nil }
        let source = leavesInboxEdit ? nil : target.source
        let flagReasons = leavesInboxEdit ? [] : target.flagReasons
        let reviewAcknowledged = leavesInboxEdit ? false : target.reviewAcknowledged
        app.errorMessage = nil
        switch kind {
        case .alias:
            editor = EditTarget(kind: .alias, mode: .create, name: target.name,
                                command: "", flagReasons: flagReasons,
                                reviewAcknowledged: reviewAcknowledged,
                                originalName: "", source: source)
        case .prompt:
            editor = EditTarget(kind: .prompt, mode: .create, name: target.name,
                                command: "", flagReasons: flagReasons,
                                reviewAcknowledged: reviewAcknowledged,
                                originalName: "", source: source)
        }
    }

    /// ⌘E on a prompt row (FIND, BOARD's prompt deck, MANAGE's prompt dialect) — the
    /// prompt-kind counterpart to `beginEdit` below. A prompt file has no "outside
    /// AliasBar's block" concept the way a hand-written alias does — the whole file
    /// belongs to whoever wrote it, exactly as `PromptStore.write` already assumes —
    /// so there is no refusal branch to mirror `beginEdit`'s.
    func beginEditPrompt(_ shortcut: Shortcut) {
        guard shortcut.kind == .prompt else { return }
        let installed = app.promptDeliveryStatus(for: shortcut) != .notInstalled
        editor = .editPrompt(shortcut, installed: installed)
    }

    /// The Composer footer's destination line(s) — "always shows the destination...
    /// real resolved path, abbreviated". Pulled out as its own pure function, the
    /// same way `PromptGist.line(for:)` is, so the exact text is testable without
    /// instantiating `ComposerSheet`.
    func composerDestination(for target: EditTarget) -> [String] {
        switch target.kind {
        case .alias:
            return ["→ managed block in \(ZshrcParser.displayPath)",
                    "Everything outside that block is left alone, and a timestamped backup is written first."]
        case .prompt:
            let name = target.name.isEmpty ? "name" : target.name
            let promptsDir = (AppPaths.promptsDirectory as NSString).abbreviatingWithTildeInPath
            var lines = ["→ \(promptsDir)/\(name).md"]
            if target.deliverToClaudeCode {
                let commandsDir = (AppPaths.claudeCommandsDirectory as NSString).abbreviatingWithTildeInPath
                lines.append("+ \(commandsDir)/\(name).md")
            }
            lines.append("A timestamped backup is written first, and the original is recoverable if this replaces something.")
            return lines
        }
    }

    // MARK: Live validation

    /// One line of as-you-type feedback for the alias half of the Composer.
    /// `blocking` mirrors a refusal `AliasWriter.apply` would actually raise at Save
    /// time (so the packet's "gs already defined at .zshrc:41" fact shows up before
    /// the user gets that far); `advisory` is a conflict `AliasWriter` itself doesn't
    /// care about (shadowing a PATH binary, an existing function of the same name),
    /// shown only once nothing blocking already owns the line.
    struct ComposerValidation { var blocking: String?; var advisory: String? }

    /// - Parameter searchPaths: overrides the real PATH lookup for the shadow-binary
    ///   advisory, the same seam `ConflictDetector.isShadowed` already exposes for
    ///   `SuggestionEngine`'s name dedup — kept hermetic for tests, real PATH in the app.
    func composerAliasValidation(name: String, command: String, originalName: String,
                                 searchPaths: [String]? = nil) -> ComposerValidation {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return ComposerValidation() }

        do {
            try AliasWriter.validate(name: trimmedName, command: command)
        } catch let error as AliasWriter.WriteError {
            return ComposerValidation(blocking: error.errorDescription)
        } catch {
            return ComposerValidation(blocking: error.localizedDescription)
        }

        // The exact fact `AliasWriter.apply` would refuse on, phrased tersely for a
        // line that updates on every keystroke rather than a hard Save-time refusal.
        if let clash = app.store.ranked.first(where: { $0.name == trimmedName && !$0.entry.managed }) {
            let file = (clash.entry.sourceFile as NSString).lastPathComponent
            return ComposerValidation(
                blocking: "\(trimmedName) is defined outside the managed block at \(file):\(clash.entry.line), so AliasBar can't edit it.")
        }

        if app.store.ranked.contains(where: { $0.name == trimmedName && $0.entry.kind == .function }) {
            return ComposerValidation(advisory: "A function named \(trimmedName) already exists. The alias will take priority.")
        }
        if ConflictDetector.isShadowed(trimmedName, searchPaths: searchPaths) {
            return ComposerValidation(advisory: "\(trimmedName) shadows a command on your PATH.")
        }
        return ComposerValidation()
    }

    /// The prompt half's counterpart. `blocking` is an existing-prompt collision
    /// (case-insensitive) against a name that is not the one being edited; a builtin
    /// slash-command shadow is always `advisory` — `PromptCompiler` itself never
    /// blocks on it, and neither does this.
    func composerPromptValidation(name: String, originalName: String) -> ComposerValidation {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ComposerValidation() }
        guard PromptStore.isValidName(trimmed) else {
            return ComposerValidation(blocking: "\"\(trimmed)\" isn't a usable prompt name. Use letters, digits, - and _ with no spaces.")
        }
        if let existing = app.promptCache.first(where: { $0.name.lowercased() == trimmed.lowercased() }),
           existing.name != originalName {
            return ComposerValidation(blocking: "A prompt named \"\(existing.name)\" already exists.")
        }
        if BuiltinSlashCommands.collides(name: trimmed) != nil {
            return ComposerValidation(
                advisory: "\(BuiltinSlashCommands.version) already defines /\(trimmed). Installing this prompt shadows the built-in command.")
        }
        return ComposerValidation()
    }
}
