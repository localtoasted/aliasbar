import SwiftUI
import Carbon.HIToolbox

/// Sidebar buckets in MANAGE.
enum Bucket: String, CaseIterable, Identifiable {
    case all, functions, aliases, mostUsed, neverRun, byFile, conflicts
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
        }
    }

    /// FIND and BOARD need a header warning only when a bucket removes entries.
    /// MANAGE names every bucket in its sidebar, while `byFile` changes order without
    /// narrowing the pool.
    func showsHeaderFilter(in mode: ViewMode) -> Bool {
        mode != .manage && self != .all && self != .byFile
    }
}

/// What the editor sheet is currently doing.
struct EditTarget: Identifiable {
    enum Mode { case create, edit }
    let mode: Mode
    var name: String
    var command: String
    /// The name as it was when editing began, so a rename can delete the old entry.
    let originalName: String
    var id: String { originalName.isEmpty ? "new" : originalName }

    static func create(name: String = "", command: String = "") -> EditTarget {
        EditTarget(mode: .create, name: name, command: command, originalName: "")
    }
    static func edit(_ entry: ShellEntry) -> EditTarget {
        EditTarget(mode: .edit, name: entry.name, command: entry.command,
                   originalName: entry.name)
    }
}

/// What FIND is currently searching: your defined aliases and functions, your shell
/// history, or your clipboard. Three sources sharing one surface, not three views —
/// see `AppState.findSource`'s own doc comment for why this replaced a plain
/// history-only flag.
enum FindSource: Equatable {
    case aliases, history, clipboard
}

/// The single source of truth for what the popover is showing and what the keyboard
/// should do next.
///
/// Filtering lives here rather than inside the views because the keyboard handler needs
/// to know exactly what is on screen in order to move a selection through it. Splitting
/// that across a view and a controller is how off-by-one selection bugs happen.
final class AppState: ObservableObject {
    @Published var mode: ViewMode
    @Published var query = ""
    /// Whichever list a source is currently navigating — shell/prompt rows, history
    /// commands, or clipboard clips, depending on `findSource`/`mode`. Resetting the
    /// clipboard source's action highlight here, in one place, is what keeps every
    /// route that moves this (arrow keys, a query edit, flipping `findSource` itself)
    /// from having to remember to do it individually.
    @Published var selection = 0 {
        didSet { if findSource == .clipboard { clipActionSelection = nil } }
    }
    @Published var bucket: Bucket = .all
    /// Which kind of thing FIND currently favors when there isn't enough query yet to
    /// know: `.shell` for a terminal-shaped previous app, `.prompt` for an AI-native
    /// one. Recomputed fresh on every summon by `ContextDetector`; ⇥ flips it by hand
    /// from there, independent of whatever the guess said.
    ///
    /// BOARD reads the same field to decide which deck is on screen — the shell keycap
    /// grid for `.shell`, the prompt card wall for `.prompt` — so opening on "the deck
    /// matching the guess" and flipping decks with the same ⇥ FIND already uses falls
    /// out of sharing one field rather than needing a second one kept in sync with it.
    @Published var dialect: Dialect = .shell
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
    /// Bumped on every keystroke the window sees, handled or not. Exists for exactly one
    /// consumer: the footer's idle-revealed hints, which hide the moment this moves and
    /// come back after a beat of stillness. A count rather than a timestamp so the view
    /// can watch it with `onChange` and never needs to poll.
    @Published private(set) var keystrokeCount = 0

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

    /// Set by the app delegate. Lets actions close the popover without the state layer
    /// knowing anything about AppKit.
    var onDismiss: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private var toastWorkItem: DispatchWorkItem?

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
            return entries.filter { $0.uses == 0 }
        case .conflicts:
            let names = Set(store.conflicts.map(\.name))
            return entries.filter { names.contains($0.name) }
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
    func flipDialect() {
        guard (mode == .find && findSource == .aliases) || mode == .board else { return }
        dialect = dialect == .shell ? .prompt : .shell
        selection = 0
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
        editor = .create(name: suggestedName(for: command.text), command: command.text)
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

    /// The count `move`, `clampSelection`, and the header's live counter share: FIND's
    /// own shell+prompt union while in FIND, BOARD's prompt deck while BOARD is showing
    /// it, `activeList`'s count everywhere else.
    var activeCount: Int {
        if mode == .find { return findResults.count }
        if mode == .board && dialect == .prompt { return boardPrompts.count }
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
        if mode == .board && dialect == .prompt { return nil }
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
        guard list.indices.contains(selection) else { return nil }
        return list[selection]
    }

    /// Re-points the selection at `id` after the underlying list has changed, so an
    /// edit or a reload keeps the highlight on the same alias rather than on whatever
    /// slid into that row.
    private func restoreSelection(to id: String?) {
        guard let id else { clampSelection(); return }
        if let index = activeList.firstIndex(where: { $0.id == id }) {
            selection = index
        } else {
            clampSelection()
        }
    }

    // MARK: - Lifecycle

    /// Called every time the popover opens.
    func prepareForShow() {
        store.reload()
        errorMessage = store.loadError
        mode = settings.defaultView
        historyMode = false
        query = ""
        selection = 0
        editor = nil

        // The one place dialect is ever guessed: from the app that was frontmost right
        // before this summon, which `PreviousApp.remember()` already captured on the
        // way in. No new tracking, and no look at anything but that app's bundle ID.
        let guess = ContextDetector.guess(for: PreviousApp.stored)
        dialect = guess.dialect ?? .shell
        contextChip = guess.chip

        let promptsDirectory = URL(fileURLWithPath: AppPaths.promptsDirectory)
        promptCache = PromptStore.scan(directory: promptsDirectory).prompts
        promptUsageCache = PromptUsageCounter.all(path: AppPaths.promptUsagePath)

        showCount += 1
    }

    func clampSelection() {
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
        // Counted before any routing: "the user is typing" includes keys the search
        // field will consume and keys nothing consumes.
        keystrokeCount += 1

        // The editor sheet owns the keyboard while it is up, apart from escape.
        if editor != nil {
            if event.keyCode == UInt16(kVK_Escape) {
                editor = nil
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
                selection = 0
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
                if !query.isEmpty { editor = .create(name: query) }
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

        // ⇥ flips the dialect boost in FIND's aliases source and the deck in BOARD,
        // instead of cycling the view — MANAGE keeps ⇥ as a view switch below, since
        // it has no dialect to flip.
        case kVK_Tab where (mode == .find && findSource == .aliases) || mode == .board:
            flipDialect()
            return true

        // The clipboard source has no dialect to flip — ⇥ instead cycles the detail
        // pane's highlight through the clip itself and its transform actions, the
        // same "Tab/Shift-Tab cycles fields" shape `FillInSheet` already uses.
        case kVK_Tab where mode == .find && findSource == .clipboard:
            cycleClipboardAction(forward: !flags.contains(.shift))
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
            move(by: boardColumns)
            return true

        case kVK_UpArrow where mode == .board:
            move(by: -boardColumns)
            return true

        case kVK_LeftArrow where mode == .board:
            move(by: -1)
            return true

        case kVK_RightArrow where mode == .board:
            move(by: 1)
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
                if !query.isEmpty { editor = .create(name: query) }
                return true
            }
            perform(command ? settings.enterAction.secondary : settings.enterAction, on: entry)
            return true

        case kVK_ANSI_N where control:
            move(by: 1)
            return true

        case kVK_ANSI_P where control:
            move(by: -1)
            return true

        case kVK_ANSI_1 where command:
            switchTo(.find); return true
        case kVK_ANSI_2 where command:
            switchTo(.board); return true
        case kVK_ANSI_3 where command:
            switchTo(.manage); return true

        case kVK_ANSI_N where command:
            editor = .create()
            return true

        case kVK_ANSI_E where command:
            // FIND's selection is a `Shortcut`, which might be a prompt — those have
            // no shell-file identity for `beginEdit` to touch, and no editor of their
            // own yet, so ⌘E on one is a quiet no-op rather than a crash or a
            // mis-targeted edit.
            if mode == .find {
                if let entry = selectedShortcut?.shellEntry { beginEdit(entry) }
            } else if let entry = selectedEntry {
                beginEdit(entry.entry)
            }
            return true

        case kVK_ANSI_Comma where command:
            onOpenSettings?()
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

    private func switchTo(_ newMode: ViewMode) {
        mode = newMode
        // History is a state of FIND, so leaving FIND leaves it.
        historyMode = false
        selection = 0
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
        let all = Bucket.allCases
        guard let idx = all.firstIndex(of: bucket) else { return }
        bucket = all[(idx + delta + all.count) % all.count]
        selection = 0
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
            finish()

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
                errorMessage = "Needs Accessibility to paste — copied instead, ⌘V to use it."
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

    private func finish() {
        if settings.afterAction == .close {
            dismiss(restoringFocus: true)
        }
    }

    func dismiss(restoringFocus: Bool) {
        onDismiss?()
        if restoringFocus { PreviousApp.restore() }
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

    func commitEditor() {
        commitEditor(confirmed: false)
    }

    private func commitEditor(confirmed: Bool) {
        guard let target = editor else { return }
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
            // Follow the alias that was just written, by name, rather than leaving the
            // cursor on whatever row index it happened to occupy before the reload.
            restoreSelection(to: activeList.first { $0.name == name }?.id)
            show(toast: "Saved \(name). Run `source \(ZshrcParser.displayPath)` to use it now.")
        } catch let error as AliasWriter.WriteError {
            // Replacing a definition removes the old lines, so an edit can take collateral
            // exactly like a delete can. Same treatment: show what goes, let the user call it.
            if case .collateralDamage(let lines, let suspect) = error {
                confirmRemoval = RemovalConfirmation(lines: lines, suspect: suspect) { [weak self] in
                    self?.commitEditor(confirmed: true)
                }
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
