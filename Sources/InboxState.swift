import SwiftUI

/// MANAGE's Review bucket (PRE-265 UI): the live, in-memory review state for every
/// file sitting in `~/.aliasbar/inbox`, and the approve/discard/edit decisions a
/// human makes against it.
///
/// Split out of `AppState` so the inbox's own bookkeeping — which items are decided,
/// which have actually been read in full — lives in one object rather than as a
/// stripe through a 3,000-line class. The surrounding state it acts on (the prompt
/// library cache, the shell store, the toast channel, the Composer) still belongs to
/// `AppState` and is reached through `app`.
final class InboxState: ObservableObject {
    /// The state that owns this. `unowned` rather than `weak` because `AppState`
    /// holds this object for its entire life, so it can never be the one that goes
    /// away first.
    private unowned let app: AppState

    init(app: AppState) {
        self.app = app
    }

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
    var pendingInboxEdit: (file: URL, index: Int)?

    /// Re-scans `~/.aliasbar/inbox` from disk. Existing review state for a file
    /// that's still there (same URL, same item count) is preserved rather than
    /// reset — a file only disappears from `inboxReviews` once `markDone` has
    /// actually moved it out of the live inbox, so a file still present between two
    /// summons is still mid-review, not a fresh one.
    func refreshInbox() {
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
                if !app.settings.promptFeaturesEnabled && review.items[index].kind != .alias {
                    continue
                }
                rows.append(.item(file: url, index: index))
            }
        }
        if app.settings.promptFeaturesEnabled {
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
        guard app.promptBucket == .inbox else { return nil }
        let rows = inboxRows
        guard rows.indices.contains(app.selection) else { return nil }
        return rows[app.selection]
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
        return app.promptCache.first { $0.name.lowercased() == replaces.lowercased() }?.body
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
        guard app.settings.promptFeaturesEnabled || item.kind == .alias else {
            app.errorMessage = "Turn on prompts to approve this item."
            return
        }
        let acknowledged = review.viewedInFull.contains(index)
        do {
            let result: PromptInbox.ApproveResult
            switch item.kind {
            case .prompt:
                result = try PromptInbox.approve(
                    item, existingLibrary: app.promptCache,
                    promptsDirectory: URL(fileURLWithPath: AppPaths.promptsDirectory),
                    acknowledgedFlags: acknowledged)
                app.loadPromptCache()
            case .alias:
                result = try PromptInbox.approveAlias(
                    item,
                    existingEntries: app.store.ranked.map(\.entry),
                    rcPath: ZshrcParser.path,
                    acknowledgedFlags: acknowledged)
                app.store.reload()
                app.refreshSuggestions()
            }
            review.decisions[index] = .approved
            inboxReviews[file] = review
            app.errorMessage = nil
            app.show(toast: "Approved \(result.name)")
            finishInboxFileIfDone(file)
        } catch let error as PromptInbox.ApproveError {
            app.errorMessage = error.errorDescription
        } catch {
            app.errorMessage = error.localizedDescription
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
        app.show(toast: "Discarded \(review.items[index].name)")
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
        app.clampSelection()
    }

    /// Edit-before-approve: opens the Composer prefilled from the item, tagged
    /// `source: "inbox"` so a successful Composer save marks the originating item
    /// handled once the save actually succeeds — the item is never touched here,
    /// before the human has decided anything.
    func editInboxItem(file: URL, index: Int) {
        guard let review = inboxReviews[file], review.items.indices.contains(index) else { return }
        let item = review.items[index]
        guard app.settings.promptFeaturesEnabled || item.kind == .alias else {
            app.errorMessage = "Turn on prompts to edit this item."
            return
        }
        let kind: EditTarget.Kind = item.kind == .prompt ? .prompt : .alias
        app.openComposer(prefill: ComposerPrefill(kind: kind, name: item.name,
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
    func markInboxItemHandled(file: URL, index: Int) {
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
}
