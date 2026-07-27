import SwiftUI
import Carbon.HIToolbox

/// Sidebar buckets in MANAGE's shell dialect.
enum Bucket: String, CaseIterable, Identifiable {
    case all, functions, aliases, mostUsed, neverRun, byFile, conflicts, suggested, snippets
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .functions: return "Functions"
        case .aliases: return "Aliases"
        case .mostUsed: return "Most used"
        case .neverRun: return "Never run"
        case .byFile: return "By file"
        case .conflicts: return "Conflicts"
        case .suggested: return "Suggested"
        case .snippets: return "Snippets"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .functions: return "function"
        case .aliases: return "at"
        case .mostUsed: return "flame"
        case .neverRun: return "moon.zzz"
        case .byFile: return "doc.text"
        case .conflicts: return "exclamationmark.triangle"
        case .suggested: return "sparkles"
        case .snippets: return "wand.and.stars"
        }
    }

    /// FIND and BOARD need a header warning only when a bucket removes entries.
    /// MANAGE names every bucket in its sidebar, while `byFile` changes order without
    /// narrowing the pool.
    ///
    /// `suggested` and `snippets` never actually reach FIND or BOARD's header in
    /// practice — their pools are `[AliasSuggestion]` and `[Snippet]`, not
    /// `[RankedEntry]`, so nothing outside MANAGE's own sidebar ever sets `bucket` to
    /// either — but they still answer this the same way `conflicts` or `neverRun`
    /// would, rather than carve out an exception for a case that can't currently
    /// reach here.
    func showsHeaderFilter(in mode: ViewMode) -> Bool {
        mode != .manage && self != .all && self != .byFile
    }
}

/// MANAGE's prompt-dialect sidebar sections — Library, Delivery, Health — parallel
/// to `Bucket` for the shell dialect, but sharing no cases with it: a prompt's
/// Health diagnosis (stale, colliding) has no shell equivalent, and a shell entry's
/// `conflicts` bucket has no prompt equivalent either. Kept as its own type rather
/// than folded into `Bucket` so neither dialect's sidebar can accidentally select a
/// case that means nothing for it.
enum PromptBucket: String, CaseIterable, Identifiable {
    case library, delivery, health, inbox
    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: return "Library"
        case .delivery: return "Delivery"
        case .health: return "Health"
        case .inbox: return "Review"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "text.book.closed"
        case .delivery: return "arrow.up.circle"
        case .health: return "stethoscope"
        case .inbox: return "tray.and.arrow.down"
        }
    }
}

/// What the Composer sheet is currently doing — one target type for both halves
/// (PRE-267) so the sheet, its live validation, and its Save button are all driven
/// by a single piece of state regardless of which kind is selected.
///
/// The alias fields (`name`, `command`) are exactly what the pre-Composer
/// `EditTarget` carried, unchanged in name and meaning — every existing alias-side
/// caller and test keeps reading `.name`/`.command` and gets byte-identical values.
/// `description`/`body`/`deliverToClaudeCode` are new, prompt-only, and sit at their
/// defaults for an alias target.
struct EditTarget: Identifiable {
    enum Mode { case create, edit }
    enum Kind: String { case alias, prompt }

    var kind: Kind = .alias
    let mode: Mode
    var name: String
    /// The alias's shell command. Unused (empty) for `kind == .prompt`.
    var command: String
    /// The prompt's one-line description. Unused (empty) for `kind == .alias`.
    var description: String = ""
    /// The prompt body. Unused (empty) for `kind == .alias`.
    var body: String = ""
    /// Whether "Install as /name in Claude Code" is checked. Unused for `.alias`.
    var deliverToClaudeCode: Bool = false
    /// Advisory flag lines carried from an inbox item into edit-before-approve, so
    /// the sheet can show the same warning `approve` would have required
    /// acknowledging. Empty everywhere else.
    var flagReasons: [String] = []
    /// Explicit full-review acknowledgement for an Inbox item. A flagged Composer
    /// cannot save until this is true, matching direct Inbox approval.
    var reviewAcknowledged = false
    /// The name as it was when editing began, so a rename can delete/replace the old
    /// entry (alias rename via `AliasWriter.Operation.rename`, or a prompt rename via
    /// write-new + `PromptStore.delete(old)`).
    let originalName: String
    /// Whatever prefilled this sheet — a suggestion, history, a no-match query, later
    /// the inbox — carried purely for provenance. Nothing in the save path branches
    /// on it; it exists so a future caller (or a test) can tell how a target arrived.
    var source: String? = nil

    var id: String { "\(kind.rawValue)-\(originalName.isEmpty ? "new" : originalName)" }

    static func create(name: String = "", command: String = "", source: String? = nil) -> EditTarget {
        EditTarget(kind: .alias, mode: .create, name: name, command: command,
                   originalName: "", source: source)
    }
    static func edit(_ entry: ShellEntry) -> EditTarget {
        EditTarget(kind: .alias, mode: .edit, name: entry.name, command: entry.command,
                   originalName: entry.name)
    }

    static func createPrompt(name: String = "", description: String = "", body: String = "",
                             deliverToClaudeCode: Bool = false, source: String? = nil) -> EditTarget {
        EditTarget(kind: .prompt, mode: .create, name: name, command: "",
                   description: description, body: body, deliverToClaudeCode: deliverToClaudeCode,
                   originalName: "", source: source)
    }
    /// `shortcut.deliveryTargets` seeds the checkbox from the prompt file's own
    /// `delivery:` frontmatter — the same source of truth PromptStore already reads —
    /// but the real "is it actually installed" answer, shown as the checkbox's
    /// initial position, comes from the registry a layer up (`beginEditPrompt`
    /// passes it in), since a file can claim `delivery: claude-code` and still be
    /// stale or never actually compiled.
    static func editPrompt(_ shortcut: Shortcut, installed: Bool) -> EditTarget {
        EditTarget(kind: .prompt, mode: .edit, name: shortcut.name, command: "",
                   description: shortcut.description ?? "", body: shortcut.body,
                   deliverToClaudeCode: installed, originalName: shortcut.name)
    }
}

/// Prefill payload for opening the Composer — the packet's single entry point every
/// route into the sheet funnels through: ⌘N, ⌘E on a shell or prompt row, a
/// no-match Enter in either FIND dialect, Suggested's Create/Rename, and later the
/// inbox's edit-before-approve. `body` deliberately covers both an alias's command
/// and a prompt's body — one field, because that is the hook's whole contract.
struct ComposerPrefill {
    var kind: EditTarget.Kind
    var mode: EditTarget.Mode = .create
    var name: String = ""
    var description: String = ""
    var body: String = ""
    var deliverToClaudeCode: Bool = false
    var originalName: String = ""
    var source: String? = nil
    /// Advisory flag lines carried from an inbox item into edit-before-approve, so
    /// the human saving it sees exactly what `approve` would have made them
    /// acknowledge. Empty everywhere else.
    var flagReasons: [String] = []
    var reviewAcknowledged = false
}

/// What the Snippets sheet is currently doing — deliberately its own small type
/// rather than another `EditTarget.Kind` case. The packet is explicit that the
/// Composer is not extended for snippets in v1 (one less kind in ⌘N, and a snippet
/// has no shell/prompt duality to switch between), so it gets its own tiny sheet
/// with its own tiny target instead of growing the Composer's already-two-shaped
/// state a third way.
struct SnippetEditTarget: Identifiable {
    enum Mode { case create, edit }
    let mode: Mode
    var trigger: String
    var template: String
    /// `nil` for a new snippet; the snippet's own id while editing one, so a save
    /// knows which stored record to replace and validation can exclude it from its
    /// own duplicate-trigger check.
    let originalID: UUID?

    var id: String { originalID?.uuidString ?? "new" }

    static func create() -> SnippetEditTarget {
        SnippetEditTarget(mode: .create, trigger: "", template: "", originalID: nil)
    }
    static func edit(_ snippet: Snippet) -> SnippetEditTarget {
        SnippetEditTarget(mode: .edit, trigger: snippet.trigger, template: snippet.template,
                          originalID: snippet.id)
    }
}

/// What FIND is currently searching: your defined aliases and functions, your shell
/// history, or your clipboard. Three sources sharing one surface, not three views —
/// see `AppState.findSource`'s own doc comment for why this replaced a plain
/// history-only flag.
enum FindSource: Equatable {
    case aliases, history, clipboard
}

enum BoardMoveDirection {
    case left, right, up, down
}

/// Pure grid navigation for BOARD while a search is active. The cards keep their
/// positions, but the keyboard cursor only lands on cards that match the query.
enum BoardNavigator {
    static let noSelection = -1

    static func destination(from selection: Int,
                            moving direction: BoardMoveDirection,
                            columns: Int,
                            itemCount: Int,
                            matchingIndices: [Int]) -> Int {
        guard itemCount > 0 else { return noSelection }
        let columns = max(1, columns)
        let eligible = matchingIndices
            .filter { (0..<itemCount).contains($0) }
            .sorted()
        guard !eligible.isEmpty else { return noSelection }
        guard eligible.count > 1 else { return eligible[0] }

        let current = min(max(selection, 0), itemCount - 1)
        switch direction {
        case .right:
            return eligible.first(where: { $0 > current }) ?? eligible[0]
        case .left:
            return eligible.last(where: { $0 < current }) ?? eligible[eligible.count - 1]
        case .up, .down:
            let rows = max(1, (itemCount + columns - 1) / columns)
            let currentRow = current / columns
            let currentColumn = current % columns
            let currentMatches = eligible.contains(current)
            let candidates = eligible.filter { $0 != current }
            guard !candidates.isEmpty else { return current }

            func rowDistance(to index: Int) -> Int {
                let row = index / columns
                let raw: Int
                if direction == .down {
                    raw = (row - currentRow + rows) % rows
                } else {
                    raw = (currentRow - row + rows) % rows
                }
                // Once the cursor is on a match, vertical movement should prefer a
                // different row. If it starts on a dimmed card, a match in that row
                // is the closest useful destination.
                return raw == 0 && currentMatches ? rows : raw
            }

            return candidates.min { lhs, rhs in
                let lhsRowDistance = rowDistance(to: lhs)
                let rhsRowDistance = rowDistance(to: rhs)
                if lhsRowDistance != rhsRowDistance { return lhsRowDistance < rhsRowDistance }
                let lhsColumnDistance = abs((lhs % columns) - currentColumn)
                let rhsColumnDistance = abs((rhs % columns) - currentColumn)
                if lhsColumnDistance != rhsColumnDistance {
                    return lhsColumnDistance < rhsColumnDistance
                }
                return lhs < rhs
            } ?? current
        }
    }
}

/// The single source of truth for what the popover is showing and what the keyboard
/// should do next.
///
/// Filtering lives here rather than inside the views because the keyboard handler needs
/// to know exactly what is on screen in order to move a selection through it. Splitting
/// that across a view and a controller is how off-by-one selection bugs happen.
final class AppState: ObservableObject {
    @Published var mode: ViewMode {
        didSet { normalizeSelectionAfterSurfaceChange() }
    }
    @Published var query = "" {
        didSet { resetSelectionForQuery() }
    }
    /// Whichever list a source is currently navigating — shell/prompt rows, history
    /// commands, or clipboard clips, depending on `findSource`/`mode`. Resetting the
    /// clipboard source's action highlight here, in one place, is what keeps every
    /// route that moves this (arrow keys, a query edit, flipping `findSource` itself)
    /// from having to remember to do it individually.
    @Published var selection = 0 {
        didSet { if findSource == .clipboard { clipActionSelection = nil } }
    }
    @Published var bucket: Bucket = .all {
        didSet { normalizeSelectionAfterSurfaceChange() }
    }
    /// MANAGE's prompt-dialect counterpart to `bucket` — which of Library/Delivery/
    /// Health the sidebar has selected. Independent of `bucket` on purpose: flipping
    /// dialect and flipping back should not have quietly moved the shell sidebar's
    /// own selection.
    @Published var promptBucket: PromptBucket = .library
    /// Which kind of thing FIND currently favors when there isn't enough query yet to
    /// know: `.shell` for a terminal-shaped previous app, `.prompt` for an AI-native
    /// one. Recomputed fresh on every summon by `ContextDetector`; ⇥ flips it by hand
    /// from there, independent of whatever the guess said.
    ///
    /// BOARD reads the same field to decide which deck is on screen — the shell keycap
    /// grid for `.shell`, the prompt card wall for `.prompt` — so opening on "the deck
    /// matching the guess" and flipping decks with the same ⇥ FIND already uses falls
    /// out of sharing one field rather than needing a second one kept in sync with it.
    @Published var dialect: Dialect = .shell {
        didSet { normalizeSelectionAfterSurfaceChange() }
    }
    /// The inference copy the title bar shows, or nil when the guess has nothing worth
    /// saying (an unrecognized app). Frozen at the guess made when the popover opened —
    /// it describes where you came from, not where ⇥ has since taken you.
    @Published private(set) var contextChip: String?
    @Published var editor: EditTarget?
    @Published var toast: String?
    @Published var errorMessage: String?
    /// Set when a write would remove more than the definition asked for. Holds the exact
    /// lines so the user can look at them and decide, rather than being handed a refusal
    /// and told to go edit the file by hand.
    @Published var confirmRemoval: RemovalConfirmation?

    /// What FillInSheet is currently doing: filling in a selected prompt's slots
    /// before it can be delivered. `fill` is the reusable, prompt-agnostic slot
    /// state (`SlotFillState` in FillInSheet.swift) — this wrapper is the only part
    /// that knows it belongs to a prompt specifically, so FillInSheet itself never
    /// has to.
    @Published var fillIn: PromptFillTarget?

    /// The Snippets bucket's own sheet, parallel to `editor` — its own `Esc`/⌘⏎
    /// handling lives alongside `editor`'s and `fillIn`'s in `handleKey`, at the same
    /// "the sheet owns the keyboard while it's up" layer both of those already use.
    @Published var snippetEditor: SnippetEditTarget?

    struct PromptFillTarget: Identifiable {
        let shortcut: Shortcut
        var fill: SlotFillState
        var id: String { shortcut.id }
    }

    struct RemovalConfirmation: Identifiable {
        let id = UUID()
        /// Every line the edit would delete, verbatim.
        let lines: [String]
        /// The one that does not look like part of the alias being removed.
        let suspect: String
        /// Re-runs the same operation with the collateral check waived.
        let proceed: () -> Void
    }
    /// Bumped on every open. The popover reuses one hosting view for the life of the
    /// app, so `onAppear` fires exactly once and cannot be used to restore focus to the
    /// search field on the second and every subsequent open.
    @Published var showCount = 0
    let store: EntryStore
    let settings: AppSettings

    /// Where `deliver` writes. Always the real system pasteboard in production —
    /// this exists purely as a seam so a test can prove a rendered prompt body
    /// reaches the broker byte-exact without ever touching the actual clipboard.
    /// Swapping it changes nothing about the delivery pipeline itself.
    var pasteboard: PasteboardWriting = NSPasteboard.general

    /// Every prompt on disk, read once per summon in `prepareForShow` — a directory
    /// scan on every keystroke would be felt, the same reasoning `EntryStore` already
    /// applies to shell history.
    private var promptCache: [Prompt] = []
    /// Usage counts for those prompts, loaded alongside them for the same reason.
    private var promptUsageCache: [String: PromptUsageCounter.Entry] = [:]

    /// The local snippet file, source of truth for MANAGE's Snippets bucket and for
    /// `ExpansionMonitor`'s live matcher alike — both read the same path, so there is
    /// never a moment where the UI shows a snippet the running expansion tap doesn't
    /// know about, or vice versa.
    let snippetStore = SnippetStore(localPath: AppPaths.snippetsPath)
    /// Every snippet on this machine, read once per summon like `promptCache` — and
    /// re-read immediately after any CRUD action, so the list never shows stale data
    /// while the popover is still open.
    private var snippetCache: [Snippet] = []

    /// MANAGE's Suggested bucket, read once per summon like `promptCache` — mining
    /// history for repeated commands on every keystroke would be exactly the kind of
    /// per-keystroke file scan `loadHistoryIfNeeded` already exists to avoid.
    /// Refreshed early (not just at the next summon) after anything that could
    /// change it: dismissing one (`ignoreSuggestion`) or saving a new alias
    /// (`commitEditor`), since either can remove a candidate from the list.
    private var suggestionCache: [AliasSuggestion] = []

    /// Set by the app delegate. Lets actions close the popover without the state layer
    /// knowing anything about AppKit.
    var onDismiss: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private var toastWorkItem: DispatchWorkItem?
    private var copyFeedbackDismissWorkItem: DispatchWorkItem?
    /// Invalidates a delayed close whenever the current presentation changes. Merely
    /// cancelling a work item is not enough if it has already been dequeued on the main
    /// queue; the captured generation is the final guard against a stale focus restore.
    private var presentationGeneration: UInt = 0

    /// Keeps the success state visible long enough to register before Close-after-copy
    /// dismisses the palette. A new summon cancels the pending close.
    static let copyFeedbackDismissDelay: TimeInterval = 0.55

    /// Set the moment the one-shot "want the same for your AI prompts?" hint earns
    /// itself, then shown the *next* time the window opens rather than fighting
    /// whatever the delivery that triggered it is already doing to the window (a
    /// paste closes it immediately; a copy's own toast is already occupying this
    /// same channel). `prepareForShow` promotes it into `toast` and clears it, so
    /// it can only ever be shown once no matter how it was queued.
    private var pendingPromptHint: String?

    init(store: EntryStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.mode = settings.defaultView
    }

    // MARK: - Derived content

    /// Everything the current bucket admits, out of everything the user has chosen to
    /// see. View is presentation, bucket is subset: FIND, BOARD and MANAGE all draw
    /// from this, so ⌘↑ ⌘↓ narrow whatever you are looking at instead of taking you
    /// somewhere else.
    private var pool: [RankedEntry] { bucketSubset(of: store.visible(settings)) }

    /// The bucket as a pure membership test. Order is left to the caller: each view
    /// already has its own idea of presentation, and the two buckets that carry an
    /// order of their own (`mostUsed`, `byFile`) reassert it in `bucketEntries`.
    private func bucketSubset(of entries: [RankedEntry]) -> [RankedEntry] {
        switch bucket {
        case .all, .byFile:
            return entries
        case .functions:
            return entries.filter { $0.entry.kind == .function }
        case .aliases:
            return entries.filter { $0.entry.kind == .alias }
        case .mostUsed:
            return entries.filter { $0.uses > 0 }.sorted { $0.uses > $1.uses }
        case .neverRun:
            // Mirrors `EntryStore.neverRun`'s own guard: `entries` already carries
            // zeroed `uses` when history usage ranking is off (`EntryStore.reload`),
            // and without this a plain `uses == 0` filter would call every entry a
            // graveyard resident instead of admitting there's no data to judge by.
            guard settings.historyUsageRankingEnabled else { return [] }
            return entries.filter { $0.uses == 0 }
        case .conflicts:
            let names = Set(store.conflicts.map(\.name))
            return entries.filter { names.contains($0.name) }
        case .suggested, .snippets:
            // Suggested's pool is `[AliasSuggestion]` and Snippets' is `[Snippet]` —
            // neither is `[RankedEntry]` — see `suggestedEntries`/`snippetManageResults`
            // below. `ManageView` routes to its own view entirely for either bucket
            // rather than ever reading `bucketEntries`/`activeList` for it, so this
            // branch exists only to keep the switch exhaustive.
            return []
        }
    }

    /// FIND results, ranked and capped. The cap is the point: a wall of results means
    /// the user has to read, and reading is slower than typing one more character.
    var results: [RankedEntry] {
        let ranked = Ranker.rank(pool, query: query, scope: settings.searchScope)
        // The cap answers "do not make me read a wall of near-misses", which is a claim
        // about searching. At rest nobody is searching: the list is simply what the
        // window contains, and capping it there only leaves the window half empty now
        // that its height is fixed.
        let limit = query.isEmpty
            ? max(settings.resultLimit, WindowLayout.restRows)
            : settings.resultLimit
        return Array(ranked.prefix(limit))
    }

    // MARK: - FIND: shell + prompt union

    /// FIND's pool: the shell entries the current bucket admits, plus every stored
    /// prompt — always both, per the boost-not-wall rule; ranking (`ShortcutRanker`)
    /// is what makes one kind easier to reach, never what removes the other.
    ///
    /// Prompts skip a non-`.all` bucket. A bucket (functions, never-run, conflicts...)
    /// is a shell-specific facet with no meaning for a prompt, so narrowing to one
    /// reads as narrowing to shell, not as hiding prompts on principle.
    private var findPool: [Shortcut] {
        var shortcuts = pool.map { ranked -> Shortcut in
            var shortcut = Shortcut(entry: ranked.entry)
            shortcut.uses = ranked.uses
            return shortcut
        }
        if bucket == .all {
            shortcuts += promptCache.map { prompt -> Shortcut in
                var shortcut = Shortcut(prompt: prompt)
                shortcut.uses = promptUsageCache[prompt.name]?.count ?? 0
                return shortcut
            }
        }
        return shortcuts
    }

    /// FIND's ranked, capped results — the union of shell entries and prompts. The cap
    /// mirrors `results`: don't make the user read more than the window has room for.
    var findResults: [Shortcut] {
        let ranked = ShortcutRanker.rank(findPool, query: query,
                                         scope: settings.searchScope, dialect: dialect)
        let limit = query.isEmpty
            ? max(settings.resultLimit, WindowLayout.restRows)
            : settings.resultLimit
        return Array(ranked.prefix(limit))
    }

    /// FIND's counterpart to `selectedEntry` — the highlighted shortcut, shell or
    /// prompt. Same "no fallback to first" rule: an index that has drifted off the end
    /// of a reranked list should act on nothing, not on whatever slid under it.
    var selectedShortcut: Shortcut? {
        // `selection` means something different in each FIND source now — a row in
        // `findResults` only while `findSource == .aliases`. Without this guard, a
        // selection index that happens to also be in range for `findResults` would
        // silently resolve against the wrong list while browsing history or
        // clipboard, the same class of bug `selectedEntry`'s own guard prevents for
        // BOARD's two decks.
        guard findSource == .aliases else { return nil }
        let list = findResults
        guard list.indices.contains(selection) else { return nil }
        return list[selection]
    }

    /// ⇥ swaps `dialect`, without touching the query: in FIND that changes which kind
    /// of shortcut ranking favors, in BOARD it changes which deck is on screen. A no-op
    /// in MANAGE and in FIND's history mode, neither of which has anything to flip.
    ///
    /// Also a no-op — falling back to plain shell behavior — while
    /// `promptFeaturesEnabled` is off: with nothing prompt-shaped anywhere to flip to,
    /// `dialect` never leaves `.shell`, which is what actually removes the prompt
    /// dialect from FIND/BOARD rather than merely hiding an already-flipped state.
    func flipDialect() {
        guard settings.promptFeaturesEnabled else { return }
        guard (mode == .find && findSource == .aliases) || mode == .board else { return }
        dialect = dialect == .shell ? .prompt : .shell
    }

    /// ⇥ in MANAGE: swap between the shell bucket sidebar (All/Functions/.../
    /// Suggested) and the prompt-dialect sidebar (Library/Delivery/Health), mirroring
    /// FIND's ⇥ flip above. A dedicated function rather than widening `flipDialect`'s
    /// own guard: MANAGE has no `historyMode` to worry about, and keeping the two
    /// call sites separate means each view's flip can be read on its own.
    ///
    /// The prompt library can be off while Inbox still contains alias suggestions.
    /// In that case MANAGE opens the Inbox alone, so generated aliases never become
    /// unreachable just because prompt features are disabled.
    var canOpenPromptManage: Bool {
        settings.promptFeaturesEnabled || inboxPendingCount > 0
    }

    func flipManageDialect() {
        guard canOpenPromptManage else { return }
        guard mode == .manage else { return }
        dialect = dialect == .shell ? .prompt : .shell
        if dialect == .prompt && !settings.promptFeaturesEnabled {
            promptBucket = .inbox
        }
    }

    /// FIND's Enter/⌘⏎, for a shortcut that might be either kind. A shell shortcut is
    /// rebuilt into the `RankedEntry` `perform` already knows how to deliver, so the
    /// shell delivery path is byte-for-byte what it was before FIND grew a second kind
    /// of row.
    ///
    /// A prompt now has three outcomes instead of PRE-259's single copy-and-close:
    /// ⌘⏎ always copies the raw body — slots intact, byte-exact — and records usage;
    /// a plain prompt (no slots) delivers its body through the same broker/paste
    /// pipeline a shell shortcut uses; a slotted prompt opens `FillInSheet` instead
    /// of delivering anything yet, so usage is recorded once, at the moment
    /// something actually goes out, not when Enter is merely pressed.
    func performFind(_ shortcut: Shortcut, secondary: Bool) {
        switch shortcut.kind {
        case .alias, .function:
            guard let entry = shortcut.shellEntry else { return }
            perform(secondary ? settings.enterAction.secondary : settings.enterAction,
                    on: RankedEntry(entry: entry, uses: shortcut.uses))
        case .prompt:
            if secondary {
                deliverPrompt(shortcut, rendered: shortcut.body, raw: true)
                return
            }
            guard shortcut.slots.isEmpty else {
                fillIn = PromptFillTarget(shortcut: shortcut, fill: SlotFillState(slots: shortcut.slots))
                return
            }
            deliverPrompt(shortcut, rendered: shortcut.body, raw: false)
        }
    }

    /// BOARD's Enter on the prompt deck routes through the exact `performFind` flow the
    /// FIND list uses — fill-in sheet for slotted prompts, the shared delivery pipeline
    /// for plain ones — so the two surfaces can never drift apart.
    func performBoardPrompt(_ prompt: Prompt) {
        performFind(Shortcut(prompt: prompt), secondary: false)
    }

    /// Delivers a prompt's rendered text through the exact `deliver` pipeline a
    /// shell shortcut uses — broker write, then either a paste (focus handback and
    /// ⌘V synthesis) or a plain copy, precisely as `enterAction` already decides for
    /// shell entries.
    ///
    /// `enterAction`'s name/command split has no prompt equivalent — a prompt is one
    /// body, not a name-and-command pair — so only its copy/paste half carries over.
    /// `afterAction` (Close vs. Keep it open) is honored the same way it is for a
    /// shell copy: `deliver`'s copy branch calls `finish()`, which reads it; its
    /// paste branch always closes, for the same reason a shell paste always does —
    /// a paste only exists by surrendering focus, so there is nothing "stay open"
    /// could mean here. A raw copy (`raw: true`, ⌘⏎) is always copy-only regardless
    /// of `enterAction`: pasting a body with `{{unfilled}}` slots still in it into
    /// whatever app is focused is never what a raw copy is for.
    private func deliverPrompt(_ shortcut: Shortcut, rendered: String, raw: Bool) {
        let pasting = !raw && (settings.enterAction == .pasteName || settings.enterAction == .pasteCommand)
        deliver(rendered, pasting: pasting,
                toast: raw ? "Copied \(shortcut.name) (raw)" : "Copied \(shortcut.name)")
        PromptUsageCounter.recordUse(of: shortcut.name, path: AppPaths.promptUsagePath)
    }

    /// FillInSheet's Enter/Paste: renders the held slot values into the shortcut's
    /// body and delivers it exactly like a plain (unslotted) prompt would — same
    /// pipeline, same `enterAction`/`afterAction` semantics, same usage recording.
    func confirmFillIn() {
        guard let target = fillIn else { return }
        let rendered = target.fill.rendered(target.shortcut.body)
        fillIn = nil
        deliverPrompt(target.shortcut, rendered: rendered, raw: false)
    }

    /// FillInSheet's Esc: closes it with nothing delivered and nothing recorded.
    /// Usage means "something was actually pasted or copied", and cancelling is
    /// neither.
    func cancelFillIn() {
        fillIn = nil
    }

    // MARK: - Prompt delivery status (Claude Code chip)

    enum PromptDeliveryStatus: Equatable { case installed, stale, notInstalled }

    /// Whether `shortcut` — always a prompt — is currently a Claude Code slash
    /// command in good standing on this Mac: registered in `PromptCompiler`'s
    /// registry AND still byte-identical to what compiling its *current* content
    /// would produce.
    ///
    /// A registry entry alone isn't enough to claim "✓ installed": the prompt file
    /// can be edited after it was last compiled, and a chip claiming the installed
    /// command reflects the prompt in front of you when it no longer does would be
    /// worse than no chip at all. `.stale` covers exactly that drift; `.notInstalled`
    /// covers both "never compiled" and "the registry itself can't be read" — either
    /// way there is nothing on this Mac to point to.
    static func promptDeliveryStatus(for shortcut: Shortcut, registryPath: String) -> PromptDeliveryStatus {
        guard shortcut.kind == .prompt,
              case .ok(let installed) = PromptCompiler.installedCommands(registryPath: registryPath),
              let entry = installed.first(where: { $0.name == shortcut.name })
        else { return .notInstalled }
        let expected = SHA256Digest.hex(
            PromptCompiler.render(description: shortcut.description, body: shortcut.body))
        return entry.sha256 == expected ? .installed : .stale
    }

    /// Instance-side convenience over the static `promptDeliveryStatus(for:registryPath:)`
    /// above, always against the real registry — the one MANAGE's Delivery bucket
    /// (an instance context) reads. Tests call the static form directly against a
    /// fixture path; nothing here duplicates its logic.
    func promptDeliveryStatus(for shortcut: Shortcut) -> PromptDeliveryStatus {
        Self.promptDeliveryStatus(for: shortcut, registryPath: AppPaths.compiledRegistryPath)
    }

    /// Whether the prompt library is completely empty — the one fact FIND's prompt
    /// dialect, MANAGE's Library bucket, and BOARD's prompt deck each check before
    /// showing the ⌘I hint in their own empty state, so the check itself can never
    /// drift between the three call sites.
    var promptLibraryEmpty: Bool { promptCache.isEmpty }

    /// Setup help only: once the user closes it, no prompt-empty surface may bring it
    /// back. Keeping the policy here prevents FIND and MANAGE from drifting.
    var showsPromptLibraryHint: Bool {
        settings.promptFeaturesEnabled
            && promptLibraryEmpty
            && !settings.hasDismissedPromptLibraryHint
    }

    func dismissPromptLibraryHint() {
        settings.hasDismissedPromptLibraryHint = true
    }

    /// The consistent ⌘I hint shown in every "no prompts yet" empty state — worded
    /// once here so FIND's prompt dialect, MANAGE's Library bucket, and BOARD's
    /// prompt deck can never drift on what pressing it actually does.
    static let promptLibraryEmptyHint =
        "⌘I copies a library review prompt. Run it in ChatGPT or Claude, then review the suggestions here."

    // MARK: - Manage: prompt dialect (Library / Delivery / Health)

    /// Every stored prompt as a `Shortcut`, usage filled in — the same adapter
    /// `findPool` builds, so MANAGE's prompt dialect never disagrees with FIND about
    /// what a prompt "is" or how often it's been used.
    private var promptShortcuts: [Shortcut] {
        promptCache.map { prompt -> Shortcut in
            var shortcut = Shortcut(prompt: prompt)
            shortcut.uses = promptUsageCache[prompt.name]?.count ?? 0
            return shortcut
        }
    }

    /// One diagnosis Health surfaces for a prompt. A prompt can carry more than one
    /// at once (a stale prompt can also collide with a builtin).
    struct PromptHealthIssue: Identifiable, Equatable {
        enum Kind: Equatable {
            case stale
            case builtinCollision
            /// The other prompt's name, exactly as it differs only by case.
            case duplicateName(String)
        }
        let kind: Kind
        var id: String {
            switch kind {
            case .stale: return "stale"
            case .builtinCollision: return "builtin"
            case .duplicateName(let other): return "dup-\(other)"
            }
        }

        var headline: String {
            switch kind {
            // Exact copy, per spec — never reworded, so a test asserting this string
            // is also asserting the app never accidentally implies cross-machine
            // knowledge it doesn't have.
            case .stale: return "not used on this Mac in 90+ days"
            case .builtinCollision: return "Shadows a Claude Code builtin"
            case .duplicateName(let other): return "Collides with \"\(other)\""
            }
        }

        var detail: String {
            switch kind {
            // Exact machine-scoped copy — usage is per-machine (like shell history),
            // so this can only ever describe *this* Mac, never claim anything about
            // any other machine the same prompt file might also live on.
            case .stale:
                return "Usage is tracked per Mac. You may use this prompt elsewhere."
            case .builtinCollision:
                return "\(BuiltinSlashCommands.version) already defines this as a built-in command. Installing anyway still works; it just shadows the builtin."
            case .duplicateName(let other):
                return "\"\(other)\" is the same name except for case, which most filesystems treat as one file. Rename one of them."
            }
        }
    }

    /// 90 days, per the interview's frozen copy for staleness. A local `let` rather
    /// than buried in `isPromptStale` so a test asserting the boundary reads the same
    /// number the check does.
    static let promptStaleThreshold: TimeInterval = 90 * 24 * 60 * 60

    /// Whether a prompt last used at `lastUsed` (nil if never, on this Mac) hasn't
    /// been used in 90+ days.
    ///
    /// A prompt with no usage record at all is *not* automatically stale: without a
    /// last-used date there is nothing to measure 90 days against, and a prompt
    /// authored an hour ago that hasn't been run yet is new, not neglected. When the
    /// prompt file itself records an `edited` date (frontmatter, app-managed), that
    /// stands in for "how long has this existed with no use" instead; a hand-written
    /// prompt with neither signal is simply never flagged stale — false silence over
    /// false alarm.
    static func isPromptStale(lastUsed: Date?, editedAt: Date?, now: Date = Date()) -> Bool {
        if let lastUsed {
            return now.timeIntervalSince(lastUsed) >= promptStaleThreshold
        }
        guard let editedAt else { return false }
        return now.timeIntervalSince(editedAt) >= promptStaleThreshold
    }

    /// Every Health diagnosis `shortcut` currently carries, against the full prompt
    /// library and this Mac's usage record. Collisions are relative to every *other*
    /// stored prompt, so this takes the whole library rather than reading
    /// `promptShortcuts` directly — that, plus taking `usage` explicitly instead of
    /// reading `promptUsageCache`, keeps the whole diagnosis independently testable
    /// against fixtures with a fake clock.
    static func promptHealthIssues(for shortcut: Shortcut, library: [Shortcut],
                                   usage: [String: PromptUsageCounter.Entry],
                                   now: Date = Date()) -> [PromptHealthIssue] {
        var issues: [PromptHealthIssue] = []
        if isPromptStale(lastUsed: usage[shortcut.name]?.lastUsed, editedAt: shortcut.editedAt, now: now) {
            issues.append(PromptHealthIssue(kind: .stale))
        }
        if BuiltinSlashCommands.collides(name: shortcut.name) != nil {
            issues.append(PromptHealthIssue(kind: .builtinCollision))
        }
        for other in library
        where other.name != shortcut.name && other.name.lowercased() == shortcut.name.lowercased() {
            issues.append(PromptHealthIssue(kind: .duplicateName(other.name)))
        }
        return issues
    }

    func promptHealthIssues(for shortcut: Shortcut) -> [PromptHealthIssue] {
        Self.promptHealthIssues(for: shortcut, library: promptShortcuts, usage: promptUsageCache)
    }

    /// MANAGE's prompt-dialect pool, filtered to whatever `promptBucket` admits.
    /// Library is everything; Delivery is everything too (it presents installed and
    /// not-installed prompts as two sections of the same list, rather than hiding
    /// one); Health narrows to prompts actually carrying a diagnosis.
    private var promptBucketSubset: [Shortcut] {
        switch promptBucket {
        case .library, .delivery:
            return promptShortcuts
        case .health:
            let library = promptShortcuts
            return library.filter {
                !Self.promptHealthIssues(for: $0, library: library, usage: promptUsageCache).isEmpty
            }
        case .inbox:
            // InboxView owns this bucket's real pool (`inboxRows`, below) — never
            // read through here. Kept only so the switch stays exhaustive.
            return []
        }
    }

    /// MANAGE's prompt-dialect list: `promptBucketSubset`, ranked and narrowed by
    /// `query` through the exact same `ShortcutRanker` FIND's union already uses —
    /// name/description/body matching for a pure-prompt pool reduces to prompt
    /// ranking, and the "boost" half of `rank` is inert here since every row already
    /// matches `.prompt`.
    var promptManageResults: [Shortcut] {
        ShortcutRanker.rank(promptBucketSubset, query: query, scope: settings.searchScope, dialect: .prompt)
    }

    /// MANAGE's prompt-dialect counterpart to `selectedEntry`/`selectedShortcut` — no
    /// fallback to the first row for the same reason those two don't: an index left
    /// over from a reranked list should point at nothing rather than whatever slid
    /// underneath it.
    var selectedPromptManageShortcut: Shortcut? {
        let list = promptManageResults
        guard list.indices.contains(selection) else { return nil }
        return list[selection]
    }

    /// Delivery's Install action: compiles `shortcut` into a real Claude Code slash
    /// command via the real registry. `CompileError`'s messages are already
    /// user-grade, so they surface in `errorMessage` verbatim rather than reworded.
    /// A builtin-collision warning never blocks the install — it's advisory, exactly
    /// as `PromptCompiler` documents — it only changes which toast is shown.
    func installPrompt(_ shortcut: Shortcut) {
        guard shortcut.kind == .prompt else { return }
        do {
            let result = try PromptCompiler.compile(name: shortcut.name,
                                                     description: shortcut.description,
                                                     body: shortcut.body,
                                                     commandsDir: AppPaths.claudeCommandsDirectory,
                                                     registryPath: AppPaths.compiledRegistryPath)
            errorMessage = nil
            if result.builtinCollision != nil {
                show(toast: "Installed /\(shortcut.name). It shadows a Claude Code built-in.")
            } else {
                show(toast: "Installed /\(shortcut.name) in Claude Code")
            }
        } catch let error as PromptCompiler.CompileError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delivery's Uninstall action, for a prompt currently `.installed` or `.stale`.
    /// Same verbatim-error-surfacing rule as `installPrompt`.
    func uninstallPrompt(_ shortcut: Shortcut) {
        guard shortcut.kind == .prompt else { return }
        do {
            _ = try PromptCompiler.uninstall(name: shortcut.name,
                                             commandsDir: AppPaths.claudeCommandsDirectory,
                                             registryPath: AppPaths.compiledRegistryPath)
            errorMessage = nil
            show(toast: "Uninstalled /\(shortcut.name) from Claude Code")
        } catch let error as PromptCompiler.CompileError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Health's Reveal action for a stale or colliding prompt — the "Edit/view
    /// action" the packet calls for in place of anything destructive. Opens Finder
    /// with the prompt's file selected; editing the prompt itself stays a job for
    /// whatever editor the user already keeps `~/.aliasbar/prompts` open in.
    func revealPromptFile(_ shortcut: Shortcut) {
        guard !DesktopInteractionGuard.isActive else { return }
        guard shortcut.kind == .prompt else { return }
        let url = URL(fileURLWithPath: AppPaths.promptsDirectory).appendingPathComponent("\(shortcut.name).md")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Manage: Suggested (history-mined alias suggestions)

    /// Recomputes `suggestionCache` from history, existing aliases, and the ignore
    /// store. Called at `prepareForShow` and again after anything that could change
    /// membership: dismissing a suggestion or saving a new alias.
    private func refreshSuggestions() {
        // Suggested is mined from raw shell history same as `EntryStore`'s usage
        // counts are — a different signal (whole commands, not per-name counts) but
        // the same "history usage ranking" toggle governs both, so disabling it empties
        // this bucket exactly the way it empties the graveyard.
        guard settings.historyUsageRankingEnabled else {
            suggestionCache = []
            return
        }
        suggestionCache = SuggestionEngine.suggest(
            history: AppPaths.historyPath,
            existingEntries: store.ranked.map(\.entry),
            ignores: SuggestionIgnoreStore.all(path: AppPaths.suggestionIgnoresPath))
    }

    /// MANAGE's Suggested bucket: `suggestionCache`, narrowed by `query` against the
    /// two things a person would actually type to find one — the name it would take,
    /// or the command it stands in for. `SuggestionEngine`'s own count-desc/name-asc
    /// order is left untouched rather than re-ranked by match strength: "most worth
    /// aliasing first" is the point of that order, not just a tiebreak.
    var suggestedEntries: [AliasSuggestion] {
        guard !query.isEmpty else { return suggestionCache }
        let q = query.lowercased()
        return suggestionCache.filter {
            $0.proposedName.lowercased().contains(q) || $0.command.lowercased().contains(q)
        }
    }

    var selectedSuggestion: AliasSuggestion? {
        let list = suggestedEntries
        guard list.indices.contains(selection) else { return nil }
        return list[selection]
    }

    /// Suggested's Create action: opens the alias editor prefilled with the
    /// suggestion's proposed name and full command, rather than writing directly —
    /// same reasoning as `promoteToAlias` for a history line: a suggested name is a
    /// guess, and naming is the part a person should own. The editor's name field is
    /// already the one that receives initial focus regardless of mode (see
    /// `EditorSheet`), so Rename below needs no separate focus-targeting of its own —
    /// it differs from Create only in what it's *for*, not in what it does.
    func createFromSuggestion(_ suggestion: AliasSuggestion) {
        openComposer(prefill: ComposerPrefill(kind: .alias, name: suggestion.proposedName,
                                              body: suggestion.command, source: "suggestion"))
    }

    /// Same editor as `createFromSuggestion`. Kept as its own named entry point
    /// (rather than one "Create" button doing double duty) because the two Manage
    /// detail-pane actions read differently even though they open identically: "Create"
    /// says the guessed name is fine, "Rename" says it isn't — the editor answers both
    /// the same way, by putting the name field in front of you before it saves anything.
    func renameFromSuggestion(_ suggestion: AliasSuggestion) {
        openComposer(prefill: ComposerPrefill(kind: .alias, name: suggestion.proposedName,
                                              body: suggestion.command, source: "suggestion"))
    }

    /// Suggested's Ignore action: records the full command as dismissed and
    /// refreshes the list immediately, rather than waiting for the popover's next
    /// summon to reflect it.
    func ignoreSuggestion(_ suggestion: AliasSuggestion) {
        _ = SuggestionIgnoreStore.ignore(suggestion.command, path: AppPaths.suggestionIgnoresPath)
        refreshSuggestions()
        clampSelection()
    }

    // MARK: - Manage: Snippets

    /// Re-reads `snippetCache` from `snippetStore` and pushes the fresh set into
    /// `ExpansionMonitor`'s live trigger matcher, so a snippet just saved or deleted
    /// from the UI is immediately what a keystroke can expand — not just what the
    /// next popover summon happens to show. Called at `prepareForShow` and again
    /// after every create/edit/delete.
    private func refreshSnippetCache() {
        snippetCache = snippetStore.all()
        ExpansionMonitor.shared.refreshSnippets()
    }

    /// MANAGE's Snippets bucket: `snippetCache`, narrowed by `query` against the two
    /// things worth searching — the trigger itself and the template it expands to —
    /// then ordered by trigger. No usage-based ranking exists for a snippet (there is
    /// no usage counter for one, unlike a prompt or an alias), so alphabetical is the
    /// whole ordering rule, not a tiebreak under something else.
    var snippetManageResults: [Snippet] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? snippetCache : snippetCache.filter {
            $0.trigger.lowercased().contains(q) || $0.template.lowercased().contains(q)
        }
        return filtered.sorted {
            $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending
        }
    }

    /// MANAGE's Snippets counterpart to `selectedSuggestion`/`selectedPromptManageShortcut`
    /// — no fallback to the first row, for the same "an index that has drifted off
    /// the end of a reranked list should point at nothing" reason neither of those
    /// falls back either.
    var selectedSnippet: Snippet? {
        let list = snippetManageResults
        guard list.indices.contains(selection) else { return nil }
        return list[selection]
    }

    func beginCreateSnippet() {
        snippetEditor = .create()
    }

    func beginEditSnippet(_ snippet: Snippet) {
        snippetEditor = .edit(snippet)
    }

    /// The Snippets sheet's live validation — read by `SnippetEditorSheet` on every
    /// keystroke, exactly the way `composerAliasValidation`/`composerPromptValidation`
    /// drive the Composer's own live feedback.
    func snippetTriggerValidation(trigger: String, excluding id: UUID?) -> SnippetTriggerValidation.TriggerError? {
        if case .failure(let error) = SnippetTriggerValidation.validate(trigger, against: snippetCache, excluding: id) {
            return error
        }
        return nil
    }

    /// Whether `target` is currently save-able: a valid, non-colliding trigger and a
    /// non-empty template. The Save button's `disabled` state reads this directly,
    /// same pattern as the Composer's `canSave`.
    func canSaveSnippet(_ target: SnippetEditTarget) -> Bool {
        guard !target.template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return snippetTriggerValidation(trigger: target.trigger, excluding: target.originalID) == nil
    }

    /// Saves whatever `snippetEditor` currently holds. A no-op (rather than a crash
    /// or a silently-wrong write) if the target somehow fails validation by the time
    /// this runs — the Save button is disabled in that state, but ⌘⏎ reaches this
    /// too, and a keyboard shortcut racing ahead of a disabled button is not a reason
    /// to write anyway.
    func commitSnippetEditor() {
        guard let target = snippetEditor, canSaveSnippet(target) else { return }
        let snippet = Snippet(id: target.originalID ?? UUID(), trigger: target.trigger, template: target.template)
        _ = snippetStore.upsert(snippet)
        refreshSnippetCache()
        snippetEditor = nil
        show(toast: "Saved \(snippet.trigger)")
    }

    /// Deletes a snippet outright — no collateral-removal confirmation the way an
    /// alias delete needs, since a snippet is one JSON record with nothing else
    /// riding along with it (unlike a line in a hand-edited `.zshrc`).
    func deleteSnippet(_ snippet: Snippet) {
        snippetStore.delete(id: snippet.id)
        refreshSnippetCache()
        clampSelection()
    }

    // MARK: - Inbox (PRE-265 UI)

    /// One inbox file's live review state. `PromptInbox`'s own API is deliberately
    /// file-level (a file only ever leaves the live inbox as a whole, via
    /// `markDone`/`discardFile`), so tracking "which items in this file have I
    /// already decided, and which have I actually looked at" is squarely this UI
    /// layer's job, kept entirely in memory for the life of this session — nothing
    /// here is ever written to disk on its own.
    struct InboxFileReview {
        let url: URL
        var items: [PromptInbox.Item]
        /// Per-item decision, index-aligned with `items`. Absent (nil) means still
        /// pending.
        var decisions: [Int: InboxItemDecision] = [:]
        /// Which items have actually had their full body displayed at least once.
        /// This is the fact behind `acknowledgedFlags: true` — `approveInboxItem`
        /// derives that argument from this set on every call, so passing `true`
        /// down into `PromptInbox.approve` is never a formality it could fake by
        /// just clicking fast. Populated only by `markInboxItemViewed`, which the
        /// detail view calls from its own `onAppear` once the item's complete,
        /// untruncated body has actually been laid out on screen.
        var viewedInFull: Set<Int> = []

        var isFullyDecided: Bool { items.indices.allSatisfy { decisions[$0] != nil } }
    }

    enum InboxItemDecision: Equatable {
        case approved
        case discarded
    }

    /// One row the Inbox bucket's list shows: either a decidable item out of a
    /// file that parsed cleanly, or a whole file that didn't parse at all — the two
    /// things `PromptInbox.scan` can produce (`.ok`'s items, `.invalid`'s file-level
    /// refusal). An `.invalid` file has nothing to review item-by-item, so it only
    /// ever offers a whole-file Discard.
    enum InboxRow: Identifiable, Equatable {
        case item(file: URL, index: Int)
        case invalidFile(url: URL, reason: String)

        var id: String {
            switch self {
            case .item(let file, let index): return "inbox-item-\(file.path)#\(index)"
            case .invalidFile(let url, _): return "inbox-invalid-\(url.path)"
            }
        }
    }

    /// Every well-formed inbox file's review state, keyed by file URL — rebuilt at
    /// `prepareForShow` (the packet's "summon-time scan is the honest cadence": no
    /// filesystem watcher). `@Published` because `markInboxItemViewed` mutates it
    /// without otherwise touching any other published field, and the Approve
    /// button's enabled state has to react to exactly that change.
    @Published private var inboxReviews: [URL: InboxFileReview] = [:]
    /// The `.invalid` files from the same scan, separately — there's no item list
    /// inside one of these to track decisions for.
    @Published private var invalidInboxFiles: [(url: URL, reason: String)] = []
    /// Set by `editInboxItem` just before opening the Composer, so a successful
    /// save can mark the originating inbox item handled without `commitPromptEditor`
    /// otherwise knowing anything about the inbox. Cleared whenever a *different*
    /// composer session opens, and on Esc, so it can never attach to the wrong save.
    private var pendingInboxEdit: (file: URL, index: Int)?

    /// Re-scans `~/.aliasbar/inbox` from disk. Existing review state for a file
    /// that's still there (same URL, same item count) is preserved rather than
    /// reset — a file only disappears from `inboxReviews` once `markDone` has
    /// actually moved it out of the live inbox, so a file still present between two
    /// summons is still mid-review, not a fresh one.
    private func refreshInbox() {
        let directory = URL(fileURLWithPath: AppPaths.inboxDirectory)
        var reviews: [URL: InboxFileReview] = [:]
        var invalid: [(url: URL, reason: String)] = []
        for file in PromptInbox.scan(inboxDirectory: directory).files {
            switch file {
            case .ok(let url, let items, _):
                guard !items.isEmpty else { continue }
                if let existing = inboxReviews[url], existing.items.count == items.count {
                    reviews[url] = existing
                } else {
                    reviews[url] = InboxFileReview(url: url, items: items)
                }
            case .invalid(let url, let reason):
                invalid.append((url, reason))
            }
        }
        inboxReviews = reviews
        invalidInboxFiles = invalid
    }

    /// Every pending row Inbox's list shows, deterministically ordered by filename
    /// so the list doesn't reshuffle between renders. A decided item drops out
    /// immediately rather than lingering with a "done" badge — once every item in a
    /// file is decided the whole file leaves the inbox via `markDone`, so there's
    /// nothing left in `inboxReviews` for it to linger in.
    var inboxRows: [InboxRow] {
        var rows: [InboxRow] = []
        for (url, review) in inboxReviews.sorted(by: { $0.key.lastPathComponent < $1.key.lastPathComponent }) {
            for index in review.items.indices where review.decisions[index] == nil {
                if !settings.promptFeaturesEnabled && review.items[index].kind != .alias {
                    continue
                }
                rows.append(.item(file: url, index: index))
            }
        }
        if settings.promptFeaturesEnabled {
            for invalid in invalidInboxFiles.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
                rows.append(.invalidFile(url: invalid.url, reason: invalid.reason))
            }
        }
        return rows
    }

    /// The sidebar's Inbox badge — every pending item plus every file that needs a
    /// human to at least look at why it didn't parse.
    var inboxPendingCount: Int { inboxRows.count }

    var selectedInboxRow: InboxRow? {
        guard promptBucket == .inbox else { return nil }
        let rows = inboxRows
        guard rows.indices.contains(selection) else { return nil }
        return rows[selection]
    }

    /// The concrete item behind `selectedInboxRow`, bundled with its file's review
    /// state — nil whenever nothing is selected, or the selection names an
    /// `.invalidFile` row (which has no single item to bundle).
    var selectedInboxItem: (file: URL, index: Int, item: PromptInbox.Item, review: InboxFileReview)? {
        guard case .item(let file, let index) = selectedInboxRow,
              let review = inboxReviews[file], review.items.indices.contains(index)
        else { return nil }
        return (file, index, review.items[index], review)
    }

    /// The item at `file`/`index`, for rendering any `.item` row in the list — not
    /// just the selected one, which is what `selectedInboxItem` is for.
    func itemFor(file: URL, index: Int) -> PromptInbox.Item? {
        guard let review = inboxReviews[file], review.items.indices.contains(index) else { return nil }
        return review.items[index]
    }

    /// Whether the currently selected item's Approve control may actually be
    /// pressed — the one place this gate is decided, so the view never has to
    /// reconstruct the "flagged and never viewed in full" rule itself.
    var selectedInboxItemCanApprove: Bool {
        guard let selected = selectedInboxItem else { return false }
        return !selected.item.isFlagged || selected.review.viewedInFull.contains(selected.index)
    }

    /// For an `.update` item, the existing prompt's current body — the "old" half
    /// of the side-by-side diff the detail pane shows. Reads the live library
    /// (`promptCache`, refreshed at `prepareForShow` and after any write), so a
    /// prompt edited since the audit ran shows its *current* body, not a stale one.
    func inboxUpdateOldBody(for item: PromptInbox.Item) -> String? {
        guard item.kind == .prompt, item.type == .update, let replaces = item.replaces else { return nil }
        return promptCache.first { $0.name.lowercased() == replaces.lowercased() }?.body
    }

    /// Marks item `index` of `file` as viewed. For unflagged items the detail
    /// pane's `onAppear` calls this on selection; for FLAGGED items nothing calls it
    /// except the explicit "I've read the full item" control that sits below the
    /// complete body in the scroll flow — selection alone never satisfies the flag
    /// gate. This is the only place `viewedInFull` is ever set, which is what makes
    /// `acknowledgedFlags: true` a fact `approveInboxItem` reads back rather than a
    /// formality any caller could assert.
    func markInboxItemViewed(file: URL, index: Int) {
        guard var review = inboxReviews[file], review.items.indices.contains(index),
              !review.viewedInFull.contains(index)
        else { return }
        review.viewedInFull.insert(index)
        inboxReviews[file] = review
    }

    /// Approves `item` at `file`/`index` into the real prompt library via
    /// `PromptInbox.approve`. Refuses as that function documents when the item is
    /// flagged and `viewedInFull` doesn't cover it — this call site is the only one
    /// that ever passes `acknowledgedFlags:`, and it always derives that value from
    /// `viewedInFull` rather than hardcoding `true`.
    func approveInboxItem(file: URL, index: Int) {
        guard var review = inboxReviews[file], review.items.indices.contains(index),
              review.decisions[index] == nil
        else { return }
        let item = review.items[index]
        guard settings.promptFeaturesEnabled || item.kind == .alias else {
            errorMessage = "Turn on prompts to approve this item."
            return
        }
        let acknowledged = review.viewedInFull.contains(index)
        do {
            let result: PromptInbox.ApproveResult
            switch item.kind {
            case .prompt:
                result = try PromptInbox.approve(
                    item, existingLibrary: promptCache,
                    promptsDirectory: URL(fileURLWithPath: AppPaths.promptsDirectory),
                    acknowledgedFlags: acknowledged)
                loadPromptCache()
            case .alias:
                result = try PromptInbox.approveAlias(
                    item,
                    existingEntries: store.ranked.map(\.entry),
                    rcPath: ZshrcParser.path,
                    acknowledgedFlags: acknowledged)
                store.reload()
                refreshSuggestions()
            }
            review.decisions[index] = .approved
            inboxReviews[file] = review
            errorMessage = nil
            show(toast: "Approved \(result.name)")
            finishInboxFileIfDone(file)
        } catch let error as PromptInbox.ApproveError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Discards item `index` of `file` — `PromptInbox.discard` itself is a
    /// documented no-op (there's nothing on disk to undo for an item never
    /// written), so the only real work here is recording the decision and, once
    /// that completes the file, moving it out of the live inbox.
    func discardInboxItem(file: URL, index: Int) {
        guard var review = inboxReviews[file], review.items.indices.contains(index),
              review.decisions[index] == nil
        else { return }
        PromptInbox.discard(review.items[index])
        review.decisions[index] = .discarded
        inboxReviews[file] = review
        show(toast: "Discarded \(review.items[index].name)")
        finishInboxFileIfDone(file)
    }

    /// Discards an entire file without deciding it item by item — the action an
    /// `.invalidFile` row offers (there's nothing else to do with one), and also
    /// available for a well-formed file a human decides isn't worth reviewing at
    /// all.
    func discardInboxFile(_ url: URL) {
        _ = try? PromptInbox.discardFile(at: url)
        inboxReviews.removeValue(forKey: url)
        invalidInboxFiles.removeAll { $0.url == url }
        clampSelection()
    }

    /// Edit-before-approve: opens the Composer prefilled from the item, tagged
    /// `source: "inbox"` so a successful Composer save marks the originating item
    /// handled once the save actually succeeds — the item is never touched here,
    /// before the human has decided anything.
    func editInboxItem(file: URL, index: Int) {
        guard let review = inboxReviews[file], review.items.indices.contains(index) else { return }
        let item = review.items[index]
        guard settings.promptFeaturesEnabled || item.kind == .alias else {
            errorMessage = "Turn on prompts to edit this item."
            return
        }
        let kind: EditTarget.Kind = item.kind == .prompt ? .prompt : .alias
        openComposer(prefill: ComposerPrefill(kind: kind, name: item.name,
                                              description: item.description ?? "",
                                              body: item.body, source: "inbox",
                                              flagReasons: item.flags.map(\.detail),
                                              reviewAcknowledged: review.viewedInFull.contains(index)))
        pendingInboxEdit = (file, index)
    }

    /// Called once an inbox-sourced Composer edit has written its item. This counts as
    /// an approval for lifecycle purposes because a human reviewed it, changed it,
    /// and it now lives in the real library, so it
    /// counts toward the file's completion exactly like `approveInboxItem` does.
    private func markInboxItemHandled(file: URL, index: Int) {
        guard var review = inboxReviews[file], review.items.indices.contains(index),
              review.decisions[index] == nil
        else { return }
        review.decisions[index] = .approved
        inboxReviews[file] = review
        finishInboxFileIfDone(file)
    }

    /// Once every item in `file` has a decision, the file itself leaves the live
    /// inbox via `markDone` — there is no separate "you're done, close it out"
    /// action a human has to remember to take.
    private func finishInboxFileIfDone(_ file: URL) {
        guard let review = inboxReviews[file], review.isFullyDecided else { return }
        _ = try? PromptInbox.markDone(file)
        inboxReviews.removeValue(forKey: file)
    }

    /// The one place `promptCache`/`promptUsageCache` are ever loaded — at summon
    /// (`prepareForShow`), after an inbox approval, and after a Composer prompt save.
    /// `promptFeaturesEnabled` off means an empty pool rather than a skipped scan: the
    /// requirement is "the prompt pool is empty" everywhere it's read (`findPool`,
    /// `promptShortcuts`, `promptLibraryEmpty`, the Inbox badge), and emptying the
    /// cache here is what makes every one of those true without a conditional at each
    /// of their call sites.
    private func loadPromptCache() {
        defer {
            if mode == .board { normalizeSelectionAfterSurfaceChange() }
        }
        guard settings.promptFeaturesEnabled else {
            promptCache = []
            promptUsageCache = [:]
            return
        }
        let promptsDirectory = URL(fileURLWithPath: AppPaths.promptsDirectory)
        promptCache = PromptStore.scan(directory: promptsDirectory).prompts
        promptUsageCache = PromptUsageCounter.all(path: AppPaths.promptUsagePath)
    }

    // MARK: - History

    // MARK: - Find source

    /// FIND, but searching everything you have ever run, or your clipboard, instead
    /// of everything you have defined. Not a fourth (or fifth) view: the same
    /// surface, a different pool — the audit's own framing, and the reason this
    /// replaced a plain history-only flag once clipboard became a second alternate
    /// source rather than inventing its own boolean beside it.
    @Published var findSource: FindSource = .aliases {
        didSet { selection = 0; historyMemoQuery = nil; clipActionSelection = nil }
    }

    /// Compatibility read for every call site that predates the three-way source
    /// (Views.swift's history chrome, `?`'s prefix-bucket guard, etc.) and only ever
    /// needed "is history the thing showing" as a yes/no. Kept as a computed alias
    /// rather than rewritten everywhere at once, so this slice's diff stays inside
    /// the clipboard/Find-source regions instead of touching every existing
    /// `historyMode` call site. `findSource`'s own `didSet` above does the resetting
    /// either route needs, so routing the setter through it costs nothing.
    var historyMode: Bool {
        get { findSource == .history }
        set { findSource = newValue ? .history : .aliases }
    }

    private var historyCache: [HistoryScanner.Command] = []
    private var historyStamp: Date?
    private var historyMemoQuery: String?
    private var historyMemo: [HistoryScanner.Command] = []

    /// Re-reads the history file only when it has actually changed.
    ///
    /// A long-lived shell history is megabytes, and this runs on the main thread on the
    /// way to showing a window. Re-parsing it on every open would be felt.
    private func loadHistoryIfNeeded() {
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: HistoryScanner.path))?[.modificationDate] as? Date
        guard historyCache.isEmpty || modified != historyStamp else { return }
        historyCache = HistoryScanner.commands()
        historyStamp = modified
        historyMemoQuery = nil
    }

    var historyResults: [HistoryScanner.Command] {
        if historyMemoQuery == query { return historyMemo }
        let scored: [(HistoryScanner.Command, Int)] = historyCache.compactMap { command in
            guard let score = HistoryScanner.score(query, in: command.text) else { return nil }
            return (command, score)
        }
        let ordered = scored.sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            if left.0.count != right.0.count { return left.0.count > right.0.count }
            return left.0.lastSeen > right.0.lastSeen
        }
        // A longer list than FIND's, deliberately. You know your own aliases by name; you
        // are scanning history to recognise something, and recognition needs candidates.
        let results = Array(ordered.prefix(max(settings.resultLimit, 8)).map(\.0))
        historyMemoQuery = query
        historyMemo = results
        return results
    }

    /// Switches into history and makes sure there is something to show.
    func enterHistory() {
        mode = .find
        historyMode = true
        loadHistoryIfNeeded()
    }

    var selectedHistory: HistoryScanner.Command? {
        let list = historyResults
        guard list.indices.contains(selection) else { return nil }
        return list[selection]
    }

    /// Turns something you have run into something you can run by name.
    ///
    /// The whole point of the history view: you find the command you have typed forty
    /// times, and one keystroke later it is an alias. Opens the editor rather than
    /// writing directly, because the name is a guess and naming is the part a person
    /// should own.
    func promoteToAlias(_ command: HistoryScanner.Command) {
        openComposer(prefill: ComposerPrefill(kind: .alias, name: suggestedName(for: command.text),
                                              body: command.text, source: "history"))
    }

    func suggestedName(for command: String) -> String {
        AliasNameSuggester.suggest(
            for: command,
            takenNames: Set(store.ranked.map(\.name))
        )
    }

    // MARK: - Clipboard source

    /// Set by the app delegate once a `ClipboardMonitor` exists — nil until
    /// clipboard monitoring has been started at least once this run (`App.swift`
    /// never constructs one while the setting is off, matching `historyMode`'s
    /// "not a fourth view" framing: there is nothing to browse until there is
    /// something watching). `@Published` so FIND's clipboard source redraws the
    /// moment monitoring gets turned on live, rather than only at the next summon.
    @Published var clipboardMonitor: ClipboardMonitor?

    /// Which transform action is highlighted in the clipboard source's detail pane,
    /// or nil for "the clip itself". Tab/Shift-Tab cycles through
    /// `[nil, action0, action1, ...]` — the same field-cycling shape
    /// `FillInSheet.SlotFillState.advance` already uses for slots, applied here to
    /// transform actions instead. Reset whenever the clip selection or the find
    /// source changes (see `selection` and `findSource`'s own `didSet`s), never left
    /// to a caller to remember.
    @Published var clipActionSelection: Int?

    /// FIND's clipboard rows: `ClipboardMonitor`'s SafeClip history, newest first,
    /// exactly as the monitor already orders it, optionally narrowed by the live
    /// query (plain substring match — a recency list, not a ranked search, so there
    /// is nothing here for `Ranker` to do).
    var clipboardRows: [SafeClip] {
        let all = clipboardMonitor?.history ?? []
        guard !query.isEmpty else { return all }
        let needle = query.lowercased()
        return all.filter { $0.content.lowercased().contains(needle) }
    }

    /// Quarantined clips still alive right now, reason-only — the clipboard
    /// source's summary row reads this directly rather than reaching into
    /// `clipboardMonitor` itself, so the row and the monitor's own clock can never
    /// silently disagree about what's still active.
    var activeQuarantine: [MemoryClip] {
        clipboardMonitor?.activeQuarantine ?? []
    }

    /// FIND's clipboard counterpart to `selectedHistory`/`selectedShortcut` — same
    /// "no fallback to first" rule, and nil outside the clipboard source so a
    /// selection index left over from another source's list can never be misread
    /// as a clip.
    var selectedClip: SafeClip? {
        guard findSource == .clipboard else { return nil }
        let rows = clipboardRows
        guard rows.indices.contains(selection) else { return nil }
        return rows[selection]
    }

    /// The transform actions offered for whatever clip is selected right now. The
    /// detail pane and the keyboard handler both read this rather than each calling
    /// `ClipTransformer.actions` themselves, so Tab's cycling and what the pane
    /// draws can never disagree about how many actions there are.
    var clipboardActions: [ClipAction] {
        guard let clip = selectedClip else { return [] }
        return ClipTransformer.actions(for: clip.content)
    }

    /// Switches into the clipboard source and makes sure there is something to
    /// show. The mirror of `enterHistory()` — same shape, same reason: FIND's third
    /// source, not a fourth view.
    func enterClipboard() {
        mode = .find
        findSource = .clipboard
    }

    /// Tab/Shift-Tab inside the clipboard source: cycles the detail pane's
    /// highlight through "the clip itself" (nil) and each of its transform actions,
    /// wrapping at both ends.
    func cycleClipboardAction(forward: Bool) {
        let actions = clipboardActions
        guard !actions.isEmpty else { clipActionSelection = nil; return }
        let count = actions.count + 1 // +1 slot for "the clip itself"
        let current = (clipActionSelection ?? -1) + 1 // shift nil to slot 0
        let next = ((current + (forward ? 1 : -1)) % count + count) % count
        clipActionSelection = next == 0 ? nil : next - 1
    }

    /// Enter/⌘⏎ while the clipboard source is showing: delivers whatever is
    /// highlighted — the clip's own content, or the selected transform's output —
    /// through the exact same broker/paste pipeline every other Enter in this file
    /// uses, so clipboard delivery honors `enterAction`'s copy/paste half and
    /// `afterAction` identically to a shell or prompt result.
    func performClipboardEnter() {
        guard let clip = selectedClip else { return }
        let pasting = settings.enterAction == .pasteName || settings.enterAction == .pasteCommand
        if let index = clipActionSelection, clipboardActions.indices.contains(index) {
            let action = clipboardActions[index]
            deliver(action.output, pasting: pasting, toast: "Copied \(action.title)")
        } else {
            deliver(clip.content, pasting: pasting, toast: "Copied clip")
        }
    }

    /// The clipboard source's empty-state Enable action — flips the setting on;
    /// `AppDelegate`'s observer (`App.swift`) is what actually starts the monitor
    /// live and hands this state a `ClipboardMonitor` moments later.
    func enableClipboardMonitoring() {
        settings.clipboardMonitoring = true
    }

    /// BOARD shows the whole pool, always. Typing dims rather than removes, so the grid
    /// keeps its shape and muscle memory survives. The bucket is different: it changes
    /// what the pool *is*, so a bucketed board genuinely has fewer keys.
    var boardEntries: [RankedEntry] {
        store.sorted(pool, by: bucket == .byFile ? .fileOrder : settings.sortOrder)
    }

    func boardMatches(_ entry: RankedEntry) -> Bool {
        Ranker.matches(entry, query: query, scope: settings.searchScope)
    }

    /// BOARD's second deck: every stored prompt, always — the direct counterpart to
    /// `boardEntries`, and for the same reason. `promptCache` is already in the stable
    /// name order `PromptStore.scan` returns, so no further sort happens here; a bucket
    /// has no meaning for a prompt (see `Shortcut`'s doc comment on the same point), so
    /// unlike `boardEntries` this ignores `bucket` entirely rather than narrowing to
    /// nothing the moment a shell-only bucket is selected.
    var boardPrompts: [Prompt] { promptCache }

    /// Whether `prompt` matches the live query, for the prompt deck's dim-not-remove
    /// behaviour — `boardMatches`'s counterpart. Checks name, description, and body; a
    /// pure membership test with no ranking, since BOARD's grid never reorders.
    func boardPromptMatches(_ prompt: Prompt) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if prompt.name.lowercased().contains(q) { return true }
        if let description = prompt.description, description.lowercased().contains(q) { return true }
        return prompt.body.lowercased().contains(q)
    }

    /// Full-grid indices that remain lit under the current BOARD query.
    var boardMatchingIndices: [Int] {
        switch dialect {
        case .shell:
            let entries = boardEntries
            return entries.indices.filter { boardMatches(entries[$0]) }
        case .prompt:
            let prompts = boardPrompts
            return prompts.indices.filter { boardPromptMatches(prompts[$0]) }
        }
    }

    /// Query edits reset every list to its first row. BOARD keeps nonmatches in place,
    /// so its first selectable row is the first lit card instead. A search with no
    /// matches has no actionable selection; it must never leave a dim card armed.
    func resetSelectionForQuery() {
        guard mode == .board else { selection = 0; return }
        selection = boardMatchingIndices.first ?? BoardNavigator.noSelection
    }

    /// Keeps BOARD's keyboard target aligned with the deck currently on screen after
    /// a view, bucket, or dialect transition. Query edits deliberately use the same
    /// first-match rule through `resetSelectionForQuery`.
    private func normalizeSelectionAfterSurfaceChange() {
        guard mode == .board else { selection = 0; return }
        selection = boardMatchingIndices.first ?? BoardNavigator.noSelection
    }

    /// Mouse activation goes through the same match gate as Enter. The view also
    /// disables dim cards, but the state guard is the authority and keeps programmatic
    /// callers from acting on a card hidden by the current search.
    func activateBoardEntry(at index: Int) {
        guard mode == .board, dialect == .shell else { return }
        let entries = boardEntries
        guard entries.indices.contains(index), boardMatches(entries[index]) else {
            normalizeSelectionAfterSurfaceChange()
            return
        }
        selection = index
        perform(settings.enterAction, on: entries[index])
    }

    /// Prompt-deck counterpart to `activateBoardEntry(at:)`.
    func activateBoardPrompt(at index: Int) {
        guard mode == .board, dialect == .prompt else { return }
        let prompts = boardPrompts
        guard prompts.indices.contains(index), boardPromptMatches(prompts[index]) else {
            normalizeSelectionAfterSurfaceChange()
            return
        }
        selection = index
        performBoardPrompt(prompts[index])
    }

    /// A prompt card's usage badge, from the same cache FIND's union pool reads.
    func promptUsage(for name: String) -> Int {
        promptUsageCache[name]?.count ?? 0
    }

    var bucketEntries: [RankedEntry] {
        guard !query.isEmpty else {
            switch bucket {
            case .mostUsed: return pool
            case .byFile: return store.sorted(pool, by: .fileOrder)
            default: return store.sorted(pool, by: settings.sortOrder)
            }
        }
        return Ranker.rank(pool, query: query, scope: settings.searchScope)
    }

    /// The list the selection cursor is currently moving through.
    ///
    /// Kept `[RankedEntry]` for BOARD and MANAGE, which never gained a second kind of
    /// row. FIND did — see `findResults` — so `activeList.count` for FIND undercounts
    /// once prompts are in the mix; `activeCount` below is what actually tracks the
    /// cursor and the header's live counter.
    var activeList: [RankedEntry] {
        switch mode {
        case .find: return results
        case .board: return boardEntries
        case .manage: return bucketEntries
        }
    }

    /// The count `move`, `clampSelection`, and the header's live counter share:
    /// FIND's own shell+prompt union while in FIND, BOARD's prompt deck while BOARD is
    /// showing it, MANAGE's own dispatch below while in MANAGE, `activeList`'s count
    /// everywhere else.
    var activeCount: Int {
        if mode == .find { return findResults.count }
        if mode == .board && dialect == .prompt { return boardPrompts.count }
        if mode == .manage { return manageActiveCount }
        return activeList.count
    }

    /// MANAGE's own cursor width. The prompt dialect (Library/Delivery/Health) and
    /// the Suggested bucket each hold a list shape — `Shortcut` or `AliasSuggestion`
    /// — that doesn't fit `[RankedEntry]`, so they size the keyboard cursor here
    /// instead of through `activeList`, which stays `bucketEntries` for every other
    /// shell bucket exactly as it always has.
    private var manageActiveCount: Int {
        if dialect == .prompt {
            // Inbox holds its own list shape (`InboxRow`), same reasoning as
            // Suggested's `[AliasSuggestion]` just below.
            if promptBucket == .inbox { return inboxRows.count }
            return promptManageResults.count
        }
        if bucket == .suggested { return suggestedEntries.count }
        if bucket == .snippets { return snippetManageResults.count }
        return activeList.count
    }

    /// What `move(by:)` and `clampSelection()` (and the header's live counter) are
    /// actually walking through right now — `activeCount`'s three-way counterpart
    /// now that FIND has three sources instead of one flag. Outside FIND,
    /// `findSource` is always `.aliases` (`switchTo` resets it on the way out, via
    /// `historyMode = false`'s compatibility setter), so this reduces to plain
    /// `activeCount` for BOARD and MANAGE exactly as it always did.
    var navigableCount: Int {
        switch findSource {
        case .history: return historyResults.count
        case .clipboard: return clipboardRows.count
        case .aliases: return activeCount
        }
    }

    /// The number beside an active search. BOARD keeps nonmatches in the grid, so its
    /// useful count is the number of lit cards rather than the deck's total size.
    var searchMatchCount: Int {
        if mode == .board,
           !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return boardMatchingIndices.count
        }
        return navigableCount
    }

    /// The selected entry, or nil when the selection no longer points at anything.
    ///
    /// Deliberately does **not** fall back to the first item. The selection is an index
    /// into a list that reloads whenever the rc file changes, so after an edit the same
    /// index can name a different alias. Silently substituting `list.first` would mean
    /// Enter acts on something the user never highlighted. Better to do nothing.
    ///
    /// Also nil whenever BOARD is showing its prompt deck: `activeList` still yields
    /// `boardEntries` regardless of `dialect` (nothing else needs it to change), so
    /// without this guard the same selection index would silently resolve against the
    /// shell grid sitting underneath a screen that's actually showing prompt cards.
    /// `selectedPrompt` is that deck's own counterpart.
    var selectedEntry: RankedEntry? {
        if mode == .board {
            guard dialect == .shell else { return nil }
            let list = boardEntries
            guard list.indices.contains(selection), boardMatches(list[selection]) else { return nil }
            return list[selection]
        }
        // MANAGE's prompt side renders Prompt, Health, Delivery, or Inbox rows. Its
        // shell bucket remains cached underneath that surface, but must never resolve
        // into an actionable selection while those rows are on screen.
        guard !(mode == .manage && dialect == .prompt) else { return nil }
        let list = activeList
        guard list.indices.contains(selection) else { return nil }
        return list[selection]
    }

    /// BOARD's prompt-deck counterpart to `selectedEntry` — nil in every mode/deck
    /// combination except BOARD-showing-prompts, and nil there too once the selection
    /// has drifted off the end of `boardPrompts`, for the same "no fallback to first"
    /// reason `selectedEntry` gives.
    var selectedPrompt: Prompt? {
        guard mode == .board, dialect == .prompt else { return nil }
        let list = boardPrompts
        guard list.indices.contains(selection), boardPromptMatches(list[selection]) else { return nil }
        return list[selection]
    }

    /// Re-points the selection at `id` after the underlying list has changed, so an
    /// edit or a reload keeps the highlight on the same alias rather than on whatever
    /// slid into that row.
    private func restoreSelection(to id: String?) {
        if mode == .board {
            let entries = boardEntries
            if dialect == .shell,
               let id,
               let index = entries.firstIndex(where: { $0.id == id }),
               boardMatches(entries[index]) {
                selection = index
            } else {
                normalizeSelectionAfterSurfaceChange()
            }
            return
        }
        guard let id else { clampSelection(); return }
        if let index = activeList.firstIndex(where: { $0.id == id }) {
            selection = index
        } else {
            clampSelection()
        }
    }

    // MARK: - Lifecycle

    /// Cancels delayed work tied to the presentation that is going away. The app
    /// delegate calls this before every AppKit close path, including click-away and
    /// Settings, so an old copy toast cannot later close a newer window or restore
    /// focus over it.
    func presentationWillClose() {
        invalidatePendingCopyDismissal()
    }

    /// Opens Settings through one state-owned route so its close cannot leave delayed
    /// copy feedback alive behind the Settings window.
    func requestOpenSettings() {
        presentationWillClose()
        onOpenSettings?()
    }

    private func invalidatePendingCopyDismissal() {
        presentationGeneration &+= 1
        copyFeedbackDismissWorkItem?.cancel()
        copyFeedbackDismissWorkItem = nil
    }

    /// Called every time the popover opens.
    func prepareForShow() {
        invalidatePendingCopyDismissal()
        store.reload()
        errorMessage = store.loadError
        mode = settings.defaultView
        historyMode = false
        query = ""
        selection = 0
        editor = nil
        snippetEditor = nil

        // Automatic keeps the context-aware behavior older installs already had.
        // A fixed choice wins, while a matching context chip may still explain it.
        let guess = ContextDetector.guess(for: PreviousApp.stored)
        if settings.promptFeaturesEnabled {
            if let fixed = settings.defaultLibrary.fixedDialect {
                dialect = fixed
                contextChip = guess.dialect == nil || guess.dialect == fixed ? guess.chip : nil
            } else {
                dialect = settings.defaultLibrary.resolvedDialect(context: guess.dialect)
                contextChip = guess.chip
            }
        } else {
            dialect = .shell
            contextChip = nil
        }

        loadPromptCache()
        refreshSuggestions()
        refreshSnippetCache()
        refreshInbox()
        normalizeSelectionAfterSurfaceChange()

        if let hint = pendingPromptHint {
            pendingPromptHint = nil
            show(toast: hint)
        }

        showCount += 1
    }

    func clampSelection() {
        if mode == .board {
            if !boardMatchingIndices.contains(selection) {
                normalizeSelectionAfterSurfaceChange()
            }
            return
        }
        let count = navigableCount
        if count == 0 { selection = 0 }
        else if selection >= count { selection = count - 1 }
        else if selection < 0 { selection = 0 }
    }

    // MARK: - Keyboard

    /// Handles a key event. Returns true when consumed, so the caller knows to swallow it.
    ///
    /// This runs from a *local* event monitor, which sees only events destined for this
    /// app and therefore needs no permission. A global monitor would need Accessibility.
    func handleKey(_ event: NSEvent) -> Bool {
        // The editor sheet owns the keyboard while it is up, apart from escape.
        if editor != nil {
            if event.keyCode == UInt16(kVK_Escape) {
                editor = nil
                pendingInboxEdit = nil
                return true
            }
            if event.keyCode == UInt16(kVK_Return) && event.modifierFlags.contains(.command) {
                commitEditor()
                return true
            }
            return false
        }

        // Same shape as the editor guard above: FillInSheet owns the keyboard while
        // it is up. Esc is handled here, at the one place Esc is already handled for
        // every other sheet; Tab/Shift-Tab between fields and Enter-to-confirm are
        // native SwiftUI focus/submit behavior inside the sheet itself, so everything
        // else falls through unconsumed.
        if fillIn != nil {
            if event.keyCode == UInt16(kVK_Escape) {
                cancelFillIn()
                return true
            }
            return false
        }

        // Same shape again: the Snippets sheet owns the keyboard while it is up.
        if snippetEditor != nil {
            if event.keyCode == UInt16(kVK_Escape) {
                snippetEditor = nil
                return true
            }
            if event.keyCode == UInt16(kVK_Return) && event.modifierFlags.contains(.command) {
                commitSnippetEditor()
                return true
            }
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let option = flags.contains(.option)

        switch Int(event.keyCode) {
        case kVK_Escape:
            // One step back before one step out. Escaping straight to the desktop from
            // history or the clipboard would make the view feel like a trapdoor.
            if findSource != .aliases {
                findSource = .aliases
                return true
            }
            // A non-All bucket is a second thing to be inside of, so it is the second
            // thing escape steps out of — but only where the bucket is a modifier. In
            // MANAGE the bucket is the place itself, named in the sidebar; escape
            // there still means leave, exactly as it always has.
            if bucket != .all && mode != .manage {
                bucket = .all
                return true
            }
            dismiss(restoringFocus: true)
            return true

        case kVK_ANSI_H where command:
            if historyMode { historyMode = false } else { enterHistory() }
            return true

        // Mirrors ⌘H's toggle exactly, for the clipboard source. ⌘K rather than a
        // letter tied to "clipboard" itself (⌘C is universally "copy the current
        // text selection", which several detail-pane fields in this very source
        // rely on via `.textSelection(.enabled)` — reusing it here would fight
        // muscle memory instead of extending it) — ⌘K is the "jump to something
        // else" mnemonic several command-palette-style apps already share.
        case kVK_ANSI_K where command:
            if findSource == .clipboard { findSource = .aliases } else { enterClipboard() }
            return true

        case kVK_Return where historyMode:
            guard let entry = selectedHistory else { return true }
            if command { promoteToAlias(entry) } else { run(entry) }
            return true

        // The clipboard source's rows are `SafeClip`s, not a `Shortcut` or a
        // `RankedEntry`, so its Enter goes through `performClipboardEnter` rather
        // than either of the paths below.
        case kVK_Return where findSource == .clipboard:
            performClipboardEnter()
            return true

        // FIND's rows are the shell+prompt union, so its Enter goes through
        // `performFind` rather than the RankedEntry-only path below.
        case kVK_Return where mode == .find:
            guard let shortcut = selectedShortcut else {
                // A dead-end search is one keystroke from being a new shortcut's name.
                // Shell dialect keeps its exact pre-existing alias-creation behavior;
                // the prompt dialect gets the same courtesy for prompts.
                if !query.isEmpty {
                    openComposer(prefill: ComposerPrefill(kind: dialect == .prompt ? .prompt : .alias,
                                                          name: query, source: "find-no-match"))
                }
                return true
            }
            performFind(shortcut, secondary: command)
            return true

        // BOARD's prompt deck has its own Enter target — a card, not a `RankedEntry` —
        // so it routes here rather than through the generic case below. Same interim
        // contract PRE-259/260 established for FIND's prompt rows: no ⌘⏎ distinction
        // yet, just copy the raw body and close.
        case kVK_Return where mode == .board && dialect == .prompt:
            guard let prompt = selectedPrompt else { return true }
            performBoardPrompt(prompt)
            return true

        // Prompt MANAGE surfaces own explicit controls. Return must not fall through
        // to the shell-only handler below and act on a cached alias row that is hidden
        // behind Library, Delivery, Health, or Review.
        case kVK_Return where mode == .manage && dialect == .prompt:
            return true

        // ⇥ flips the dialect boost in FIND's aliases source and the deck in BOARD,
        // instead of cycling the view — MANAGE keeps ⇥ as a view switch below, since
        // it has no dialect to flip.
        case kVK_Tab where (mode == .find && findSource == .aliases) || mode == .board:
            if settings.promptFeaturesEnabled {
                flipDialect()
            } else {
                // No prompt features means no dialect to flip; ⇥ falls back to its
                // pre-prompt-platform meaning so the key never dead-ends.
                cycleView(backwards: flags.contains(.shift))
            }
            return true

        // The clipboard source has no dialect to flip — ⇥ instead cycles the detail
        // pane's highlight through the clip itself and its transform actions, the
        // same "Tab/Shift-Tab cycles fields" shape `FillInSheet` already uses.
        case kVK_Tab where mode == .find && findSource == .clipboard:
            cycleClipboardAction(forward: !flags.contains(.shift))
            return true

        // MANAGE's own ⇥ flip, mirroring FIND's immediately above.
        case kVK_Tab where mode == .manage:
            if canOpenPromptManage {
                flipManageDialect()
            } else {
                cycleView(backwards: flags.contains(.shift))
            }
            return true

        // Buckets are the folders, and ⌘↑ ⌘↓ walk them the way ⌘↑ walks Finder's — in
        // place, whichever view you are in. The view is how you look; the bucket is
        // what you are looking at.
        case kVK_UpArrow where command:
            cycleBucket(by: -1)
            return true

        case kVK_DownArrow where command:
            cycleBucket(by: 1)
            return true

        // ⌥← ⌥→ change view, everywhere, always. Plain ← → are left alone in FIND and
        // MANAGE because the search field is permanently focused and a caret you cannot
        // move is worse than a shortcut you have to reach for.
        case kVK_LeftArrow where option:
            cycleView(backwards: true)
            return true

        case kVK_RightArrow where option:
            cycleView(backwards: false)
            return true

        // BOARD is a grid, so its arrows move in two dimensions: a row at a time
        // vertically, a key at a time horizontally. Nothing collides with ⌥ — that is
        // still the view switch here as everywhere else.
        case kVK_DownArrow where mode == .board:
            moveBoard(.down)
            return true

        case kVK_UpArrow where mode == .board:
            moveBoard(.up)
            return true

        case kVK_LeftArrow where mode == .board:
            moveBoard(.left)
            return true

        case kVK_RightArrow where mode == .board:
            moveBoard(.right)
            return true

        case kVK_DownArrow:
            move(by: 1)
            return true

        case kVK_UpArrow:
            move(by: -1)
            return true

        case kVK_Return:
            guard let entry = selectedEntry else {
                // A dead-end search is one keystroke from being a new alias's name, so
                // Return on "no match" opens the editor with the name already filled in.
                if !query.isEmpty {
                    openComposer(prefill: ComposerPrefill(kind: .alias, name: query, source: "no-match"))
                }
                return true
            }
            perform(command ? settings.enterAction.secondary : settings.enterAction, on: entry)
            return true

        case kVK_ANSI_N where control:
            if mode == .board { moveBoard(.right) } else { move(by: 1) }
            return true

        case kVK_ANSI_P where control:
            if mode == .board { moveBoard(.left) } else { move(by: -1) }
            return true

        case kVK_ANSI_1 where command:
            switchTo(.find); return true
        case kVK_ANSI_2 where command:
            switchTo(.board); return true
        case kVK_ANSI_3 where command:
            switchTo(.manage); return true

        // The Snippets bucket has no Composer kind to speak of (it isn't extended
        // there by design) — ⌘N inside it opens the dedicated Snippets sheet instead,
        // so ⌘N does *something* useful no matter which MANAGE bucket you're in.
        // Checked ahead of the generic ⌘N case below, which would otherwise open the
        // (shell-dialect) Composer for a new alias while looking at Snippets.
        case kVK_ANSI_N where command && mode == .manage && dialect == .shell && bucket == .snippets:
            beginCreateSnippet()
            return true

        // Default kind follows `dialect` — the same field FIND/BOARD already use for
        // "which kind is this session favoring" — and the Composer's own Kind control
        // stays switchable from there regardless of which one this opened on.
        case kVK_ANSI_N where command:
            let kind: EditTarget.Kind = settings.promptFeaturesEnabled && dialect == .prompt
                ? .prompt
                : .alias
            openComposer(prefill: ComposerPrefill(kind: kind))
            return true

        case kVK_ANSI_E where command:
            switch mode {
            case .find:
                // FIND's selection is a `Shortcut`, which might be either kind — route
                // to whichever edit path matches it rather than assuming shell.
                if let shortcut = selectedShortcut {
                    if shortcut.kind == .prompt {
                        beginEditPrompt(shortcut)
                    } else if let entry = shortcut.shellEntry {
                        beginEdit(entry)
                    }
                }
            case .board:
                if dialect == .prompt {
                    if let prompt = selectedPrompt { beginEditPrompt(Shortcut(prompt: prompt)) }
                } else if let entry = selectedEntry {
                    beginEdit(entry.entry)
                }
            case .manage:
                if dialect == .prompt {
                    if let shortcut = selectedPromptManageShortcut { beginEditPrompt(shortcut) }
                } else if bucket == .snippets {
                    if let snippet = selectedSnippet { beginEditSnippet(snippet) }
                } else if let entry = selectedEntry {
                    beginEdit(entry.entry)
                }
            }
            return true

        case kVK_ANSI_Comma where command:
            requestOpenSettings()
            return true

        // ⌘I anywhere in the palette: copies the audit prompt. ⌥⌘I picks the
        // local-agent ending (write straight to the inbox) over the default web
        // ending (paste into a chat window) — the one modifier this shortcut reads.
        case kVK_ANSI_I where command:
            copyAuditPrompt(ending: option ? .localAgent : .web)
            return true

        case kVK_Tab:
            cycleView(backwards: flags.contains(.shift))
            return true

        default:
            break
        }

        // Prefix keys jump straight into a MANAGE bucket, but only as the first
        // character, and only while searching aliases — `?` typed into history or
        // the clipboard should search for a literal question mark, not jump away.
        if query.isEmpty, findSource == .aliases, !command, !control,
           let chars = event.charactersIgnoringModifiers {
            if let target = Self.prefixBucket(for: chars) {
                mode = .manage
                // Every prefix-jump target is a shell bucket, so this always means
                // "show me the shell sidebar" — without this, jumping in from
                // MANAGE's prompt dialect would set `bucket` correctly but leave the
                // prompt sidebar on screen, since that's what `dialect` still says.
                dialect = .shell
                bucket = target
                selection = 0
                return true
            }
        }
        return false
    }

    static func prefixBucket(for characters: String) -> Bucket? {
        switch characters {
        case "?": return .neverRun
        case "!": return .conflicts
        case "@": return .byFile
        case "#": return .mostUsed
        default: return nil
        }
    }

    private func move(by delta: Int) {
        let count = navigableCount
        guard count > 0 else { selection = 0; return }
        // Wraps, because in a capped list the fastest way to the last item is up.
        selection = ((selection + delta) % count + count) % count
    }

    func moveBoard(_ direction: BoardMoveDirection) {
        let count = dialect == .prompt ? boardPrompts.count : boardEntries.count
        guard count > 0 else { selection = BoardNavigator.noSelection; return }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            switch direction {
            case .left: move(by: -1)
            case .right: move(by: 1)
            case .up: move(by: -boardColumns)
            case .down: move(by: boardColumns)
            }
            return
        }

        selection = BoardNavigator.destination(from: selection,
                                               moving: direction,
                                               columns: boardColumns,
                                               itemCount: count,
                                               matchingIndices: boardMatchingIndices)
    }

    func switchTo(_ newMode: ViewMode) {
        // History is a state of FIND, so leaving FIND leaves it.
        historyMode = false
        // Set the surface last. `historyMode = false` resets selection as part of the
        // source transition; BOARD then gets the final word and chooses a lit card.
        mode = newMode
    }

    /// Columns for whichever deck BOARD is showing. The prompt deck's cards are wider
    /// than a keycap, so it fits fewer columns at the same density — `WindowLayout`'s
    /// column math doesn't change, only which width it's handed.
    var boardColumns: Int {
        switch dialect {
        case .shell:
            return WindowLayout.boardColumns(keyWidth: settings.boardDensity.keyWidth)
        case .prompt:
            return WindowLayout.boardColumns(keyWidth: PromptCardMetrics.width(for: settings.boardDensity))
        }
    }

    /// Walks the buckets in place. Every view draws from the bucketed pool, so this
    /// narrows what you are looking at without moving you; the header chip (and in
    /// MANAGE, the sidebar) says where you have landed.
    private func cycleBucket(by delta: Int) {
        // Buckets slice your aliases, not your history or your clipboard. Reaching
        // for one while looking at either is a statement that you are done with it.
        if findSource != .aliases { findSource = .aliases }
        // MANAGE's prompt dialect has its own sidebar (Library/Delivery/Health), so
        // ⌘↑↓ there walks `PromptBucket`, not the shell `Bucket` list — the same
        // split FIND and BOARD never need, since neither has replaced its sidebar.
        if mode == .manage, dialect == .prompt {
            if !settings.promptFeaturesEnabled {
                promptBucket = .inbox
                selection = 0
                return
            }
            let all = PromptBucket.allCases
            guard let idx = all.firstIndex(of: promptBucket) else { return }
            promptBucket = all[(idx + delta + all.count) % all.count]
            selection = 0
            return
        }
        let all = Bucket.allCases
        guard let idx = all.firstIndex(of: bucket) else { return }
        bucket = all[(idx + delta + all.count) % all.count]
    }

    private func cycleView(backwards: Bool) {
        let all = ViewMode.allCases
        guard let idx = all.firstIndex(of: mode) else { return }
        let next = (idx + (backwards ? -1 : 1) + all.count) % all.count
        switchTo(all[next])
    }

    // MARK: - Actions

    func perform(_ action: EnterAction, on entry: RankedEntry) {
        let payload = (action == .copyName || action == .pasteName)
            ? entry.entry.name
            : entry.entry.command
        let pasting = action == .pasteName || action == .pasteCommand
        deliver(payload,
                pasting: pasting,
                toast: action == .copyName ? "Copied \(entry.name)" : "Copied command")
        queuePromptHintIfEarned()
    }

    /// Onboarding deliberately never mentions the prompt side of the app up front —
    /// no mode picker, dialects are discovered via ⇥. Instead, the first successful
    /// alias recall after setup earns a one-time nudge toward it. Same one-shot
    /// shape `hasEverPasted` uses: check, act, record, never again.
    private func queuePromptHintIfEarned() {
        guard settings.onboardingComplete,
              settings.promptFeaturesEnabled,
              !settings.hasShownPromptHint
        else { return }
        settings.hasShownPromptHint = true
        pendingPromptHint = "Press ⇥ for prompts."
    }

    /// A history command goes out by the same route an alias command would.
    ///
    /// It has no name to paste, so the name/command half of the preference does not
    /// apply — only the copy/paste half does.
    func run(_ command: HistoryScanner.Command) {
        deliver(command.text,
                pasting: settings.enterAction == .pasteName
                    || settings.enterAction == .pasteCommand,
                toast: "Copied command")
    }

    /// Puts a string where the user asked for it: the clipboard, or straight into
    /// whatever regains focus.
    private func deliver(_ payload: String, pasting: Bool, toast: String) {
        switch pasting {
        case false:
            PasteboardBroker.write(transient: payload, to: pasteboard)
            show(toast: toast)
            finishAfterCopyFeedback()

        case true:
            Diag.log("deliver: pasting \(payload.count) chars, "
                     + "accessibility trusted=\(Typist.isTrusted)")
            guard Typist.isTrusted else {
                // Never fail silently and never lose the user's action: put it on the
                // clipboard anyway, so the worst case is one extra ⌘V.
                PasteboardBroker.write(transient: payload, to: pasteboard)
                // Deliberately no `finish()`. Closing here is what made this look like
                // the app doing nothing at all: the window carrying the only explanation
                // went away in the same frame the explanation was written to it, and the
                // system prompt that appeared instead had no visible cause. When we could
                // not do what was asked, the window stays up and says so.
                errorMessage = "Accessibility is off. Copied instead; press ⌘V to paste."
                Typist.requestTrust()
                return
            }
            // The target app has to be frontmost before the keystroke is sent, so the
            // popover closes and focus is handed back first, and the paste goes out a
            // beat later once that has actually taken effect.
            //
            // Deliberately not `finish()`: "Keep it open" cannot apply here. A paste
            // exists only by surrendering focus, and summoning the window back after
            // the paste would steal focus from the app the user just pasted into —
            // exactly where they are about to keep typing. So paste modes always
            // close, and the Afterwards setting says so instead of pretending.
            onDismiss?()
            PreviousApp.restore()
            // Recorded here, at the moment a paste is actually possible — it is what
            // lets a later `AXIsProcessTrusted() == false` be read as a *lost* grant
            // rather than one never given.
            settings.hasEverPasted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                _ = Typist.paste(payload)
            }
        }
    }

    private func finishAfterCopyFeedback() {
        guard settings.afterAction == .close else { return }
        invalidatePendingCopyDismissal()
        let generation = presentationGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.copyFeedbackDismissWorkItem = nil
            self.dismiss(restoringFocus: true)
        }
        copyFeedbackDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copyFeedbackDismissDelay,
                                      execute: work)
    }

    func dismiss(restoringFocus: Bool) {
        invalidatePendingCopyDismissal()
        onDismiss?()
        if restoringFocus { PreviousApp.restore() }
    }

    // MARK: - ⌘I: audit prompt (PRE-265)

    /// ⌘I anywhere in the palette: builds the audit prompt fresh from the live
    /// prompt library — `AuditPrompt.generate` is documented never to have a static
    /// template, so this always reflects whatever `promptCache` currently holds —
    /// and copies it. Always copy-only, regardless of `enterAction`, the same way a
    /// raw ⌘⏎ copy is: this text is meant for pasting into a chat window, never for
    /// pasting into whatever app was frontmost.
    func copyAuditPrompt(ending: AuditPrompt.Ending) {
        // Inert while the prompt side of the app is switched off — nothing to audit,
        // and no inbox for a `.localAgent` ending to write into.
        guard settings.promptFeaturesEnabled else { return }
        let text = AuditPrompt.generate(library: promptCache, ending: ending)
        PasteboardBroker.write(transient: text, to: pasteboard)
        show(toast: "Audit prompt copied. Paste it into ChatGPT or Claude.")
    }

    // MARK: - Composer (PRE-267)

    /// Pure suitability policy for explicit selected-clip prefills. The shared secret
    /// classifier blocks credentials. Alias commands must fit the writer's one-line
    /// contract, while prompts may keep their original whitespace and line breaks.
    static func clipboardDraft(_ text: String, for kind: EditTarget.Kind) -> String? {
        guard SensitiveContentClassifier.quarantineReason(in: text) == nil else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch kind {
        case .alias:
            guard trimmed.utf8.count <= 4_096,
                  !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
            guard (try? AliasWriter.validate(name: "clipboard-draft", command: trimmed)) != nil else {
                return nil
            }
            return trimmed
        case .prompt:
            guard text.utf8.count <= 65_536 else { return nil }
            return text
        }
    }

    /// Starts a new item from the clip currently selected inside AliasBar. Plain New
    /// never reads the system clipboard; this action is the only clipboard-to-Composer
    /// path, and its source is visible in the clipboard view before the user chooses it.
    func createFromSelectedClip(kind: EditTarget.Kind) {
        guard let clip = selectedClip else { return }
        guard kind != .prompt || settings.promptFeaturesEnabled else {
            errorMessage = "Turn on prompts to save this clip as a prompt."
            return
        }
        guard let safe = Self.clipboardDraft(clip.content, for: kind) else {
            errorMessage = kind == .alias
                ? "This clip is not a safe one-line alias command."
                : "This clip cannot be used as a prompt."
            return
        }
        errorMessage = nil
        openComposer(prefill: ComposerPrefill(kind: kind, body: safe,
                                              source: "selected-clipboard-clip"))
    }

    /// The Composer's one entry point. Every route that opens the sheet — ⌘N,
    /// Suggested's Create/Rename, `promoteToAlias`, a no-match Enter in either FIND
    /// dialect, ⌘E on a prompt row, and later the inbox's edit-before-approve —
    /// funnels a `ComposerPrefill` through here rather than constructing `EditTarget`
    /// directly, so every one of them agrees about what "prefilled" means.
    func openComposer(prefill: ComposerPrefill) {
        guard prefill.kind != .prompt || settings.promptFeaturesEnabled else {
            errorMessage = "Turn on prompts before creating one."
            return
        }
        // Only `editInboxItem` ever wants this set, and it sets it itself right
        // after calling this function — so any other route into the Composer
        // clears whatever a previous, possibly-abandoned inbox edit left behind,
        // and can never have a later save misattributed to it.
        if prefill.source != "inbox" { pendingInboxEdit = nil }
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
        if leavesInboxEdit { pendingInboxEdit = nil }
        let source = leavesInboxEdit ? nil : target.source
        let flagReasons = leavesInboxEdit ? [] : target.flagReasons
        let reviewAcknowledged = leavesInboxEdit ? false : target.reviewAcknowledged
        errorMessage = nil
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
        let installed = Self.promptDeliveryStatus(for: shortcut, registryPath: AppPaths.compiledRegistryPath) != .notInstalled
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
        if let clash = store.ranked.first(where: { $0.name == trimmedName && !$0.entry.managed }) {
            let file = (clash.entry.sourceFile as NSString).lastPathComponent
            return ComposerValidation(
                blocking: "\(trimmedName) is defined outside the managed block at \(file):\(clash.entry.line), so AliasBar can't edit it.")
        }

        if store.ranked.contains(where: { $0.name == trimmedName && $0.entry.kind == .function }) {
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
        if let existing = promptCache.first(where: { $0.name.lowercased() == trimmed.lowercased() }),
           existing.name != originalName {
            return ComposerValidation(blocking: "A prompt named \"\(existing.name)\" already exists.")
        }
        if BuiltinSlashCommands.collides(name: trimmed) != nil {
            return ComposerValidation(
                advisory: "\(BuiltinSlashCommands.version) already defines /\(trimmed). Installing this prompt shadows the built-in command.")
        }
        return ComposerValidation()
    }

    // MARK: - Editing

    func beginEdit(_ entry: ShellEntry) {
        guard entry.kind == .alias else {
            show(toast: "AliasBar edits aliases, not functions")
            return
        }
        guard entry.managed else {
            show(toast: "\(entry.name) lives outside AliasBar's block")
            return
        }
        editor = .edit(entry)
    }

    /// - Parameter now: the moment the prompt half stamps `edited` with, on a real
    ///   content change. Defaults to the real clock; a test can pass a fixed instant
    ///   so two saves inside the same wall-clock second still produce distinguishable
    ///   timestamps, the same seam `PromptUsageCounter.recordUse` and
    ///   `isPromptStale` already expose for exactly that reason.
    func commitEditor(now: Date = Date()) {
        commitEditor(confirmed: false, now: now)
    }

    private func commitEditor(confirmed: Bool, now: Date = Date()) {
        guard let target = editor else { return }
        guard target.kind != .prompt || settings.promptFeaturesEnabled else {
            errorMessage = "Turn on prompts before saving."
            return
        }
        guard target.flagReasons.isEmpty || target.reviewAcknowledged else {
            errorMessage = "Review the full item before saving it."
            return
        }
        switch target.kind {
        case .alias: commitAliasEditor(target, confirmed: confirmed)
        case .prompt: commitPromptEditor(target, now: now)
        }
    }

    /// Exactly `commitEditor`'s body before the Composer existed — untouched logic,
    /// only renamed and reached through the kind switch above, so the alias half's
    /// validation behavior stays byte-for-byte what it always was.
    private func commitAliasEditor(_ target: EditTarget, confirmed: Bool) {
        let name = target.name.trimmingCharacters(in: .whitespaces)
        let command = target.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = ZshrcParser.path
        let entries = store.ranked.map(\.entry)

        do {
            // A rename is one operation. Doing it as delete-then-insert means the second
            // half can fail on a clash, a permission change, a full disk, or a
            // concurrent edit, leaving the alias gone under both names.
            let isRename = target.mode == .edit
                && target.originalName != name
                && !target.originalName.isEmpty
            let operation: AliasWriter.Operation = isRename
                ? .rename(from: target.originalName, to: name, command: command)
                : .upsert(name: name, command: command, comment: nil)
            _ = try AliasWriter.apply(operation, path: path, allEntries: entries,
                                      confirmedCollateral: confirmed)
            confirmRemoval = nil
            editor = nil
            errorMessage = nil
            store.reload()
            // A newly-saved alias may cover a command Suggested was still proposing
            // (exact match, or the suggestion is this alias's command plus trailing
            // args) — refreshed here so it drops out immediately rather than lingering
            // until the next summon.
            refreshSuggestions()
            // Follow the alias that was just written, by name, rather than leaving the
            // cursor on whatever row index it happened to occupy before the reload.
            restoreSelection(to: activeList.first { $0.name == name }?.id)

            if target.source == "inbox", let pending = pendingInboxEdit {
                markInboxItemHandled(file: pending.file, index: pending.index)
                pendingInboxEdit = nil
            }
            show(toast: "Saved \(name). Run `source \(ZshrcParser.displayPath)` to use it now.")
        } catch let error as AliasWriter.WriteError {
            // Replacing a definition removes the old lines, so an edit can take collateral
            // exactly like a delete can. Same treatment: show what goes, let the user call it.
            if case .collateralDamage(let lines, let suspect) = error {
                confirmRemoval = RemovalConfirmation(lines: lines, suspect: suspect) { [weak self] in
                    self?.commitAliasEditor(target, confirmed: true)
                }
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// One shared formatter for the prompt frontmatter's `edited:` stamp. A local
    /// static rather than reaching into `PromptFrontmatter`'s own (private) one:
    /// `ISO8601DateFormatter`'s default options are what `PromptFrontmatter.edited`
    /// already parses with, so a value written here reads back unchanged.
    private static let promptEditedFormatter = ISO8601DateFormatter()

    /// Prompt → `PromptStore.write`. Unlike the alias half, there is no collateral
    /// check, no zsh syntax guard, and no "outside the block" concept — a prompt
    /// file is either the one AliasBar is about to write or it doesn't exist yet.
    private func commitPromptEditor(_ target: EditTarget, now: Date = Date()) {
        let name = target.name.trimmingCharacters(in: .whitespaces)
        let description = target.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = target.body

        guard PromptStore.isValidName(name) else {
            errorMessage = "\"\(name)\" isn't a usable prompt name. Use letters, digits, - and _ with no spaces."
            return
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "A prompt needs a body."
            return
        }
        guard !description.contains("\n"), !description.contains("\r") else {
            errorMessage = "A prompt description must fit on one line."
            return
        }
        // Case-insensitive collision against every OTHER prompt already on disk —
        // blocking for a genuinely new name, never for editing yourself.
        if let clash = promptCache.first(where: { $0.name.lowercased() == name.lowercased() }),
           clash.name != target.originalName {
            errorMessage = "A prompt named \"\(clash.name)\" already exists."
            return
        }

        let directory = URL(fileURLWithPath: AppPaths.promptsDirectory)
        let isRename = target.mode == .edit && target.originalName != name && !target.originalName.isEmpty
        let existing: Prompt? = target.mode == .edit
            ? (try? PromptStore.read(url: directory.appendingPathComponent("\(target.originalName).md")).get())
            : nil

        // `edited` is stamped only when the actual content changed — flipping just
        // the delivery checkbox, or saving an untouched prompt again, must not make
        // a healthy prompt look freshly edited to `promptHealthIssues`' staleness
        // check.
        let contentChanged = existing.map {
            $0.description != (description.isEmpty ? nil : description) || $0.body != body
        } ?? true

        var frontmatter = existing?.frontmatter ?? PromptFrontmatter.empty()
        frontmatter = description.isEmpty
            ? frontmatter.removingEntry(for: "description")
            : frontmatter.setting("description", to: description)
        // "popover" is always-on and implicit (every prompt is always reachable from
        // FIND/BOARD), so only Claude Code delivery is worth recording here.
        frontmatter = target.deliverToClaudeCode
            ? frontmatter.setting("delivery", to: PromptFrontmatter.deliveryValue([.claudeCode]))
            : frontmatter.removingEntry(for: "delivery")
        if contentChanged {
            frontmatter = frontmatter.setting("edited", to: Self.promptEditedFormatter.string(from: now))
        }

        let prompt = Prompt(name: name, frontmatter: frontmatter, body: body)

        do {
            // A case-only rename of the same prompt ("foo" -> "Foo") has to delete the
            // old file BEFORE writing the new one: `PromptStore.write`'s case-collision
            // guard would otherwise see the not-yet-removed old file on disk and refuse
            // the new one, since a case-insensitive filesystem cannot hold both at
            // once. Every other rename writes first, matching the packet's documented
            // order, so a failed write never destroys the original.
            let caseOnlyRename = isRename && target.originalName.lowercased() == name.lowercased()
            if caseOnlyRename {
                // Not `try?`: if this delete fails, the write below trips the
                // case-collision guard and blames the user's own prompt. Better to
                // name the real failure.
                _ = try PromptStore.delete(name: target.originalName, from: directory)
            }
            _ = try PromptStore.write(prompt: prompt, to: directory)
            if isRename && !caseOnlyRename {
                _ = try PromptStore.delete(name: target.originalName, from: directory)
            }
        } catch let error as PromptStore.WriteError {
            errorMessage = error.errorDescription
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        errorMessage = nil
        editor = nil

        // Edit-before-approve: the save just above landed in the real library, so
        // the inbox item this Composer session originated from (if any) is handled
        // — counted the same as an approval for the file's completion.
        if target.source == "inbox", let pending = pendingInboxEdit {
            markInboxItemHandled(file: pending.file, index: pending.index)
            pendingInboxEdit = nil
        }

        let registryPath = AppPaths.compiledRegistryPath
        let commandsDir = AppPaths.claudeCommandsDirectory

        // Rename safety: the old slash-command name (if any) no longer corresponds to
        // anything, so it comes down regardless of the new delivery checkbox state.
        if isRename, case .ok(let installed) = PromptCompiler.installedCommands(registryPath: registryPath),
           installed.contains(where: { $0.name == target.originalName }) {
            _ = try? PromptCompiler.uninstall(name: target.originalName, commandsDir: commandsDir,
                                              registryPath: registryPath)
        }

        if target.deliverToClaudeCode {
            do {
                _ = try PromptCompiler.compile(name: name, description: description.isEmpty ? nil : description,
                                               body: body, commandsDir: commandsDir, registryPath: registryPath)
            } catch let error as PromptCompiler.CompileError {
                // The prompt itself is already saved — a compile failure surfaces but
                // never looks like the save failed.
                errorMessage = error.errorDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        } else if case .ok(let installed) = PromptCompiler.installedCommands(registryPath: registryPath),
                  installed.contains(where: { $0.name == name }) {
            _ = try? PromptCompiler.uninstall(name: name, commandsDir: commandsDir, registryPath: registryPath)
        }

        show(toast: "Saved \(name)")

        // Refreshed immediately so FIND/BOARD/MANAGE see the change without waiting
        // for the next summon — the same reasoning `commitAliasEditor` reloads
        // `store` right after a successful write.
        loadPromptCache()
    }

    func delete(_ entry: ShellEntry) {
        guard entry.managed else {
            show(toast: "\(entry.name) lives outside AliasBar's block")
            return
        }
        delete(entry, confirmed: false)
    }

    private func delete(_ entry: ShellEntry, confirmed: Bool) {
        do {
            _ = try AliasWriter.apply(.delete(name: entry.name),
                                      path: ZshrcParser.path,
                                      allEntries: store.ranked.map(\.entry),
                                      confirmedCollateral: confirmed)
            confirmRemoval = nil
            store.reload()
            clampSelection()
            show(toast: "Deleted \(entry.name)")
        } catch let error as AliasWriter.WriteError {
            // The one error worth asking about rather than reporting. Everything else is
            // a genuine refusal the user cannot resolve by insisting.
            if case .collateralDamage(let lines, let suspect) = error {
                confirmRemoval = RemovalConfirmation(lines: lines, suspect: suspect) { [weak self] in
                    self?.delete(entry, confirmed: true)
                }
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Toast

    func show(toast message: String) {
        toastWorkItem?.cancel()
        toast = message
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}

// MARK: - Prompt deck support

/// Sizing for BOARD's prompt cards, kept beside `AppState.boardColumns` (the one place
/// that reads it) rather than in `PromptBoardView.swift` — that file is SwiftUI-only
/// and isn't part of the state-layer test target, while `AppState.swift` already is.
enum PromptCardMetrics {
    /// A card carries a name, a two-line gist, and two small badges — meaningfully
    /// wider than a keycap, which is exactly why "fewer tiles per screen than keycaps"
    /// is the expected, honest trade for the prompt deck.
    static func width(for density: BoardDensity) -> CGFloat {
        density == .dense ? 148 : 172
    }

    static func height(for density: BoardDensity) -> CGFloat {
        density == .dense ? 72 : 86
    }
}

/// The description-or-first-line fallback a prompt card (and its BOARD readout) shows.
/// Pulled out as its own pure function, rather than computed inline in the view, so the
/// fallback rule is testable at the state layer and the card can never disagree with
/// itself about what a prompt's gist is.
enum PromptGist {
    static func line(for prompt: Prompt) -> String {
        if let description = prompt.description, !description.isEmpty { return description }
        for rawLine in prompt.body.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "No description"
    }
}
