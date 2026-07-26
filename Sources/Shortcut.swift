import Foundation

// MARK: - Shortcut

/// What kind of thing a `Shortcut` is. `alias`/`function` come from the shell rc file;
/// `prompt` comes from a file under `~/.aliasbar/prompts`.
enum ShortcutKind: String, Hashable {
    case alias, function, prompt
}

/// Where a prompt is allowed to be handed off to. A prompt with no targets set is
/// inert: it lives in the store but nothing offers it anywhere yet.
enum DeliveryTarget: String, Codable, Hashable, CaseIterable {
    case popover
    case claudeCode = "claude-code"
}

/// The model everything that can be invoked converges on: shell aliases, shell
/// functions, and prompts. It does not replace `ShellEntry` — that stays the parser's
/// native currency, and rewiring `EntryStore` onto `Shortcut` is a later slice's job —
/// it exists so UI that wants to treat "a thing you can run" uniformly has one type to
/// build against instead of two.
///
/// Fields are a union of what an alias/function and a prompt each need; the half that
/// doesn't apply to a given `kind` sits at its default. That is a deliberate simplicity
/// trade: a Swift `enum` with associated values would make illegal states
/// unrepresentable, but every call site that only cares about the shell half (the
/// existing Board/Find UI) would have to switch on kind before touching a single field
/// it already knows how to read off `ShellEntry`. Flat and slightly redundant reads
/// better against the existing code than a payload enum would.
struct Shortcut: Identifiable, Hashable {
    let kind: ShortcutKind
    let name: String
    /// The alias/function command, or the prompt body, depending on `kind`.
    let body: String
    let comment: String?

    /// How many times this has actually been invoked, when the caller has that data on
    /// hand. `Shortcut` never reads history or usage.json itself — nothing here does
    /// I/O — so this defaults to 0 and is meant to be filled in the same way
    /// `RankedEntry` pairs a `ShellEntry` with its use count: by the caller, from
    /// whichever counter matches the kind (`HistoryScanner` for alias/function,
    /// `PromptUsageCounter` for prompt).
    var uses: Int = 0

    // Shell-only. nil/false for prompts.
    let sourceFile: String?
    let line: Int?
    let managed: Bool

    // Prompt-only. Empty/nil for aliases and functions.
    let slots: [String]
    let description: String?
    let deliveryTargets: Set<DeliveryTarget>
    let editedAt: Date?

    var id: String {
        switch kind {
        case .alias, .function:
            return "\(kind.rawValue)-\(name)-\(sourceFile ?? ""):\(line ?? 0)"
        case .prompt:
            // Prompt names are the file's stem and are unique case-insensitively
            // (PromptStore refuses a write that would collide), so the name alone is
            // a stable identity — there is no line/file pair to disambiguate with.
            return "prompt-\(name)"
        }
    }
}

extension Shortcut {
    /// Adapter from the shell parser's native type. `ShellEntry`/`EntryStore` are left
    /// exactly as they are; this only narrows what's already there into the unified
    /// shape.
    init(entry: ShellEntry) {
        self.kind = entry.kind == .alias ? .alias : .function
        self.name = entry.name
        self.body = entry.command
        self.comment = entry.comment
        self.uses = 0
        self.sourceFile = entry.sourceFile
        self.line = entry.line
        self.managed = entry.managed
        self.slots = []
        self.description = nil
        self.deliveryTargets = []
        self.editedAt = nil
    }

    /// Adapter from a stored prompt file.
    init(prompt: Prompt) {
        self.kind = .prompt
        self.name = prompt.name
        self.body = prompt.body
        self.comment = nil
        self.uses = 0
        self.sourceFile = nil
        self.line = nil
        self.managed = false
        self.slots = PromptSlotParser.slots(in: prompt.body)
        self.description = prompt.description
        self.deliveryTargets = prompt.deliveryTargets
        self.editedAt = prompt.editedAt
    }
}
