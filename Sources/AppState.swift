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

/// The single source of truth for what the popover is showing and what the keyboard
/// should do next.
///
/// Filtering lives here rather than inside the views because the keyboard handler needs
/// to know exactly what is on screen in order to move a selection through it. Splitting
/// that across a view and a controller is how off-by-one selection bugs happen.
final class AppState: ObservableObject {
    @Published var mode: ViewMode
    @Published var query = ""
    @Published var selection = 0
    @Published var bucket: Bucket = .all
    @Published var editor: EditTarget?
    @Published var toast: String?
    @Published var errorMessage: String?
    /// Set when a write would remove more than the definition asked for. Holds the exact
    /// lines so the user can look at them and decide, rather than being handed a refusal
    /// and told to go edit the file by hand.
    @Published var confirmRemoval: RemovalConfirmation?

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

    private var pool: [RankedEntry] { store.visible(settings) }

    /// FIND results, ranked and capped. The cap is the point: a wall of results means
    /// the user has to read, and reading is slower than typing one more character.
    var results: [RankedEntry] {
        let ranked = Ranker.rank(pool, query: query, scope: settings.searchScope)
        return Array(ranked.prefix(settings.resultLimit))
    }

    // MARK: - History

    /// FIND, but searching everything you have ever run instead of everything you have
    /// defined. Not a fourth view: the same surface, a different pool.
    @Published var historyMode = false {
        didSet { selection = 0; historyMemoQuery = nil }
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

    /// Initials of the first few real words: `git status -sb` suggests `gs`.
    ///
    /// Flags and environment assignments are skipped — they are the part that varies, so
    /// they are the part that makes a bad name.
    func suggestedName(for command: String) -> String {
        let words = command.split(separator: " ").map(String.init)
            .filter { !$0.hasPrefix("-") && !$0.contains("=") && $0 != "sudo" }
        guard !words.isEmpty else { return "" }

        func clean(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        // Tried in order, longest-lived first. A collision should push toward a name
        // that is still readable rather than straight to a numbered one — `gs` taken
        // should suggest `gis`, not `gs2`.
        var candidates: [String] = []
        candidates.append(clean(words.prefix(3).compactMap { $0.first.map(String.init) }.joined()))
        if words.count >= 2 {
            candidates.append(clean(String(words[0].prefix(2)) + String(words[1].prefix(1))))
            candidates.append(clean(String(words[0].prefix(2)) + String(words[1].prefix(2))))
        }
        candidates.append(clean(String(words[0].prefix(4))))

        let taken = Set(store.ranked.map(\.name))
        let usable = candidates.filter { $0.count >= 2 }
        for candidate in usable where !taken.contains(candidate) { return candidate }

        guard let base = usable.first else { return "" }
        for suffix in 2...9 where !taken.contains(base + String(suffix)) {
            return base + String(suffix)
        }
        return base
    }

    /// BOARD shows everything, always. Typing dims rather than removes, so the grid
    /// keeps its shape and muscle memory survives.
    var boardEntries: [RankedEntry] {
        store.sorted(pool, by: settings.sortOrder)
    }

    func boardMatches(_ entry: RankedEntry) -> Bool {
        Ranker.matches(entry, query: query, scope: settings.searchScope)
    }

    var bucketEntries: [RankedEntry] {
        let entries: [RankedEntry]
        switch bucket {
        case .all: entries = pool
        case .functions: entries = store.functions
        case .aliases: entries = store.aliases
        case .mostUsed: entries = store.mostUsed
        case .neverRun: entries = store.neverRun
        case .byFile: entries = store.sorted(pool, by: .fileOrder)
        case .conflicts: entries = store.conflictedEntries
        }
        guard !query.isEmpty else {
            return bucket == .mostUsed || bucket == .byFile
                ? entries
                : store.sorted(entries, by: settings.sortOrder)
        }
        return Ranker.rank(entries, query: query, scope: settings.searchScope)
    }

    /// The list the selection cursor is currently moving through.
    var activeList: [RankedEntry] {
        switch mode {
        case .find: return results
        case .board: return boardEntries
        case .manage: return bucketEntries
        }
    }

    /// The selected entry, or nil when the selection no longer points at anything.
    ///
    /// Deliberately does **not** fall back to the first item. The selection is an index
    /// into a list that reloads whenever the rc file changes, so after an edit the same
    /// index can name a different alias. Silently substituting `list.first` would mean
    /// Enter acts on something the user never highlighted. Better to do nothing.
    var selectedEntry: RankedEntry? {
        let list = activeList
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
        showCount += 1
    }

    func clampSelection() {
        let count = historyMode ? historyResults.count : activeList.count
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
                return true
            }
            if event.keyCode == UInt16(kVK_Return) && event.modifierFlags.contains(.command) {
                commitEditor()
                return true
            }
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let control = flags.contains(.control)

        switch Int(event.keyCode) {
        case kVK_Escape:
            // One step back before one step out. Escaping straight to the desktop from
            // history would make the view feel like a trapdoor.
            if historyMode {
                historyMode = false
                return true
            }
            dismiss(restoringFocus: true)
            return true

        case kVK_ANSI_H where command:
            if historyMode { historyMode = false } else { enterHistory() }
            return true

        case kVK_Return where historyMode:
            guard let entry = selectedHistory else { return true }
            if command { promoteToAlias(entry) } else { run(entry) }
            return true

        case kVK_DownArrow:
            move(by: 1)
            return true

        case kVK_UpArrow:
            move(by: -1)
            return true

        case kVK_LeftArrow where mode == .board:
            move(by: -1)
            return true

        case kVK_RightArrow where mode == .board:
            move(by: 1)
            return true

        case kVK_Return:
            guard let entry = selectedEntry else { return true }
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
            if let entry = selectedEntry { beginEdit(entry.entry) }
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
        // character. Typing `?` mid-query should search for a question mark.
        if query.isEmpty, !historyMode, !command, !control,
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
        let count = historyMode ? historyResults.count : activeList.count
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
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(payload, forType: .string)
            show(toast: toast)
            finish()

        case true:
            guard Typist.isTrusted else {
                // Never fail silently and never lose the user's action: put it on the
                // clipboard anyway, so the worst case is one extra ⌘V.
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(payload, forType: .string)
                show(toast: "Copied. Allow Accessibility to paste automatically.")
                Typist.requestTrust()
                finish()
                return
            }
            // The target app has to be frontmost before the keystroke is sent, so the
            // popover closes and focus is handed back first, and the paste goes out a
            // beat later once that has actually taken effect.
            onDismiss?()
            PreviousApp.restore()
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
