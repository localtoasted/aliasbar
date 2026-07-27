import SwiftUI

/// FIND's clipboard source: the clip list, the transform-action highlight, and the
/// image-OCR path that turns a screenshot into a prompt draft.
///
/// Split out of `AppState` because it is one self-contained source among three, not
/// because it is independent of the rest — the selection index, the live query and
/// the delivery pipeline all still live on `AppState`, reached through `app`. The
/// only thing that moved is ownership of the clipboard's own state.
@preconcurrency @MainActor
final class ClipboardState: ObservableObject {
    /// The state that owns this. `unowned` rather than `weak` because `AppState`
    /// holds this object for its entire life, so it can never be the one that goes
    /// away first.
    private unowned let app: AppState

    init(app: AppState) {
        self.app = app
    }

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

    /// Local image OCR. Tests replace this with a deterministic fake, so they never
    /// invoke Vision or read the system clipboard.
    var clipboardImageTextRecognizer: ClipboardImageTextRecognizing =
        VisionClipboardImageTextRecognizer()
    @Published private(set) var clipboardImageOCRClipID: UUID?
    private var clipboardImageOCRRequestID: UUID?
    private var clipboardImageOCRTask: ClipboardImageTextRecognitionTask?

    /// FIND's clipboard rows: text plus session-only images, newest first, exactly
    /// as the monitor orders them, optionally narrowed by the live
    /// query (plain substring match — a recency list, not a ranked search, so there
    /// is nothing here for `Ranker` to do).
    var clipboardRows: [ClipboardHistoryItem] {
        let all = clipboardMonitor?.items ?? []
        guard !app.query.isEmpty else { return all }
        let needle = app.query.lowercased()
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
    var selectedClip: ClipboardHistoryItem? {
        guard app.findSource == .clipboard else { return nil }
        let rows = clipboardRows
        guard rows.indices.contains(app.selection) else { return nil }
        return rows[app.selection]
    }

    /// The transform actions offered for whatever clip is selected right now. The
    /// detail pane and the keyboard handler both read this rather than each calling
    /// `ClipTransformer.actions` themselves, so Tab's cycling and what the pane
    /// draws can never disagree about how many actions there are.
    var clipboardActions: [ClipAction] {
        guard let clip = selectedClip?.textClip else { return [] }
        return ClipTransformer.actions(for: clip.content)
    }

    /// Switches into the clipboard source and makes sure there is something to
    /// show. The mirror of `enterHistory()` — same shape, same reason: FIND's third
    /// source, not a fourth view.
    func enterClipboard() {
        app.mode = .find
        app.findSource = .clipboard
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
        guard let item = selectedClip else { return }
        guard let clip = item.textClip else {
            app.errorMessage = "Use Save as prompt to read text from this image."
            return
        }
        let pasting = app.settings.enterAction == .pasteName || app.settings.enterAction == .pasteCommand
        if let index = clipActionSelection, clipboardActions.indices.contains(index) {
            let action = clipboardActions[index]
            app.deliver(action.output, pasting: pasting,
                        toast: "Copied clipboard action: \(action.title)")
        } else {
            app.deliver(clip.content, pasting: pasting, toast: "Copied clipboard item")
        }
    }

    /// The clipboard source's empty-state Enable action — flips the setting on;
    /// `AppDelegate`'s observer (`App.swift`) is what actually starts the monitor
    /// live and hands this state a `ClipboardMonitor` moments later.
    func enableClipboardMonitoring() {
        app.settings.clipboardMonitoring = true
    }

    // MARK: - Clip to Composer

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
    func createFromSelectedClip(kind: EditTarget.Kind, expectedID: UUID? = nil) {
        guard let item = selectedClip else { return }
        guard expectedID == nil || item.id == expectedID else {
            app.errorMessage = "The clipboard selection changed. Select the item again."
            return
        }
        guard kind != .prompt || app.settings.promptFeaturesEnabled else {
            app.errorMessage = "Turn on prompts to save this clip as a prompt."
            return
        }

        if let image = item.imageClip {
            guard kind == .prompt else {
                app.errorMessage = "Save image text as a prompt."
                return
            }
            createPromptFromSelectedImage(image)
            return
        }

        guard let clip = item.textClip else { return }
        guard let safe = Self.clipboardDraft(clip.content, for: kind) else {
            app.errorMessage = kind == .alias
                ? "This clip is not a safe one-line alias command."
                : "This clip cannot be used as a prompt."
            return
        }
        app.errorMessage = nil
        app.openComposer(prefill: ComposerPrefill(kind: kind, body: safe,
                                                  source: "selected-clipboard-clip"))
    }

    private func createPromptFromSelectedImage(_ image: ClipboardImageClip) {
        guard let data = image.data else {
            app.errorMessage = image.issueMessage ?? "AliasBar could not read this image."
            return
        }

        cancelClipboardImageOCR()
        let requestID = UUID()
        clipboardImageOCRRequestID = requestID
        clipboardImageOCRClipID = image.id
        app.errorMessage = nil

        let task = clipboardImageTextRecognizer.recognizeText(in: data) { [weak self] result in
            let finish = {
                guard let self, self.clipboardImageOCRRequestID == requestID else { return }
                self.clipboardImageOCRRequestID = nil
                self.clipboardImageOCRClipID = nil
                self.clipboardImageOCRTask = nil

                switch result {
                case .failure:
                    self.app.errorMessage = "AliasBar could not read text from this image."

                case .success(let recognized):
                    let text = ClipboardOCRText.normalize(recognized)
                    guard !text.isEmpty else {
                        self.app.errorMessage = "AliasBar found no readable text in this image."
                        return
                    }

                    guard text.utf8.count <= 65_536 else {
                        self.app.errorMessage = "The text in this image is too long for a prompt."
                        return
                    }

                    if let reason = SensitiveContentClassifier.quarantineReason(in: text) {
                        _ = self.clipboardMonitor?.quarantineImage(
                            id: image.id, recognizedText: text, reason: reason)
                        self.objectWillChange.send()
                        self.app.errorMessage = "AliasBar removed this image from clipboard history because its text may contain a secret."
                        return
                    }

                    self.app.errorMessage = nil
                    self.app.openComposer(prefill: ComposerPrefill(
                        kind: .prompt,
                        body: text,
                        source: "selected-clipboard-image"
                    ))
                }
            }

            if Thread.isMainThread {
                finish()
            } else {
                Task { @MainActor in finish() }
            }
        }
        if clipboardImageOCRRequestID == requestID {
            clipboardImageOCRTask = task
        } else {
            // A synchronous recognizer (used by tests) may already have completed.
            task.cancel()
        }
    }

    func cancelClipboardImageOCR() {
        clipboardImageOCRTask?.cancel()
        clipboardImageOCRTask = nil
        clipboardImageOCRRequestID = nil
        clipboardImageOCRClipID = nil
    }
}
