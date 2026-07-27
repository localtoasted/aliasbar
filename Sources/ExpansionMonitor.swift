import AppKit
import SwiftUI
import CoreGraphics
import Carbon.HIToolbox

// MARK: - ExpansionLogic (pure — testable without a real event tap)

/// Every decision `ExpansionMonitor` makes, factored out as static, injectable
/// functions over plain data. None of this touches `CGEventTapCreate`, `NSWorkspace`,
/// or anything else that needs a live system tap or Accessibility permission — the
/// packet is explicit that the real event tap is "out (human step)" for automated
/// testing, so everything that actually *can* be exercised by a test lives here,
/// and the AppKit class below is as thin a shell around it as possible.
enum ExpansionLogic {
    /// A run of plain typing this old or older no longer describes what's on
    /// screen — the buffer resets rather than risk expanding against characters
    /// that scrolled off, got deleted by hand, or belong to an entirely different
    /// thought.
    static let typingGapSeconds: TimeInterval = 4.0

    static func exceededTypingGap(previous: Date, now: Date, gap: TimeInterval = typingGapSeconds) -> Bool {
        now.timeIntervalSince(previous) > gap
    }

    /// Every key whose *purpose* is navigation or editing rather than inserting a
    /// character — arrows, return, tab, escape, delete, the function-row keys, and
    /// so on. Any of these breaks a run of plain typing, so the buffer they're fed
    /// into no longer means anything and has to reset.
    ///
    /// A versioned, dated list (like `ContextDetector`'s bundle-ID table) rather
    /// than an attempt at an exhaustive keycode enumeration: drift here is expected
    /// and cheap to fix — a missed key merely delays a reset by one buffer entry,
    /// it never expands the wrong thing, since `TriggerMatcher.feed` only ever acts
    /// on the buffer it's actually holding.
    static func isResetKey(keyCode: CGKeyCode) -> Bool {
        let codes: Set<Int> = [
            kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
            kVK_Delete, kVK_ForwardDelete,
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help,
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ]
        return codes.contains(Int(keyCode))
    }

    /// Fail-closed per the frozen posture: whenever the system reports secure input
    /// is active (a password field currently has focus, anywhere), every event is
    /// dropped and the buffer resets, with no exception. Kept as its own tiny
    /// function — despite being one line — so the "when true, always drop" decision
    /// is independently named, injectable, and testable, rather than an inline
    /// `if` a future edit could quietly loosen.
    static func shouldDropAndReset(secureInputEnabled: Bool) -> Bool {
        secureInputEnabled
    }

    // MARK: Self-tagging synthetic events

    /// An arbitrary, distinctive marker written into every event this monitor
    /// synthesizes (backspaces, the paste keystroke, a cancelled retype), and
    /// checked on every *real* keyDown the tap observes so the monitor never
    /// mistakes its own output for the user typing — which would otherwise either
    /// feed a backspace character into the matcher as if it were plain text, or
    /// worse, re-trigger a reset/expansion loop off its own synthesized keystrokes.
    ///
    /// Spells "EXPAND" loosely in hex, purely so a diagnostic dump of a tagged
    /// event's user-data field reads as obviously ours rather than as a stray
    /// number; the value carries no other meaning and nothing decodes it.
    static let syntheticTagValue: Int64 = 0x45585041_4E44

    static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticTagValue)
    }

    static func isSelfSynthesized(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticTagValue
    }

    // MARK: Injection planning

    /// How many backspaces delete exactly the trigger text that just matched, and
    /// nothing more. One backspace per `Character` in the trigger: `TriggerMatcher`
    /// only ever declares a match when the buffer's trailing `Character`s equal the
    /// trigger's `Character`s exactly (case-sensitively), so the on-screen text
    /// removed here is guaranteed to be precisely what was typed, not a guess.
    struct BackspacePlan: Equatable {
        let count: Int
    }

    static func backspacePlan(for match: TriggerMatcher.Match) -> BackspacePlan {
        BackspacePlan(count: match.triggerLength)
    }

    /// What happens after the trigger is deleted: a plain (hole-free) snippet
    /// pastes immediately; a snippet with one or more `{{holes}}` opens the
    /// fill-in sheet instead of guessing at values. `SnippetRenderer.renderPlan`
    /// is the single source of truth for "does this snippet have holes" — the
    /// same ordered-slots computation the fill-in sheet itself asks for — so this
    /// can never disagree with it about which snippets need one.
    enum Action: Equatable {
        case pasteRendered(String)
        case presentHoles
    }

    static func action(for snippet: Snippet) -> Action {
        guard SnippetRenderer.renderPlan(snippet: snippet).isEmpty else { return .presentHoles }
        return .pasteRendered(SnippetRenderer.render(snippet: snippet, values: [:]))
    }

    /// What a cancelled fill-in sheet retypes: the trigger exactly as written.
    /// Always safe to retype verbatim, never a guess — see `backspacePlan`'s same
    /// reasoning: the buffer only ever matches by exact `Character` equality, so
    /// the trigger string this returns is byte-for-byte what was just deleted.
    static func retypeText(for snippet: Snippet) -> String {
        snippet.trigger
    }
}

// MARK: - ExpansionMonitor (AppKit — owns the real CGEventTap)

/// Watches for a snippet trigger being typed anywhere on the Mac and expands it —
/// the one feature in this app that reads keystrokes outside its own window, which
/// is why every rule below is written to fail closed rather than merely "usually
/// work":
///
/// - The tap itself is never created while `AppSettings.inlineExpansionEnabled` is
///   false — not merely disabled, *never constructed* (see `start()`/`stop()` and
///   `isTapActiveForTesting`).
/// - It listens (`.listenOnly`), never intercepts: normal typing is never at risk
///   of being altered or dropped by a bug in this class, because this class never
///   owns the original keystroke.
/// - Every event is checked against `IsSecureEventInputEnabled()` before anything
///   else; true means drop and reset, unconditionally.
/// - Nothing this class observes is ever written to disk, logged verbatim, or kept
///   longer than `TriggerMatcher`'s own bounded rolling buffer already keeps it.
/// - If the system disables the tap (a timeout callback, or the user revoking
///   Accessibility while it's running) this fails closed: the tap tears itself
///   down and the persisted setting flips back off, so the toggle the user sees
///   in Settings always matches whether anything is actually watching.
final class ExpansionMonitor: ObservableObject {
    static let shared = ExpansionMonitor()

    enum Status: Equatable {
        /// The setting is off, or has never been turned on this launch. No tap
        /// exists in this state — see `isTapActiveForTesting`.
        case off
        /// The setting is on, but macOS has not granted Accessibility, so no tap
        /// could be created. Nothing is watched.
        case needsAccessibility
        /// A real tap is live and watching for triggers.
        case active
        /// The tap was created but the system later disabled it (timeout, or a
        /// revoked permission) — this monitor tore it down and flipped the
        /// setting off in response, rather than pretend it's still watching.
        case tapFailed
    }

    @Published private(set) var status: Status = .off

    private let matcher = TriggerMatcher()
    private let snippetStore: SnippetStore
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastEventAt = Date.distantPast
    private var workspaceObserver: NSObjectProtocol?
    private var activeFillIn: ExpansionFillInController?

    /// Exposed purely so a structural test can prove the tap is never constructed
    /// while the feature is off — the exact shape `ClipboardMonitor`'s own tests
    /// use for its `recordedChangeCountForTesting`-style seams.
    var isTapActiveForTesting: Bool { eventTap != nil }

    init(snippetStore: SnippetStore = SnippetStore(localPath: AppPaths.snippetsPath)) {
        self.snippetStore = snippetStore
    }

    /// Re-reads every snippet from disk and hands the fresh set to the matcher.
    /// Safe to call at any time, tap running or not — it only ever touches
    /// in-memory matcher state. Called on every start and after every snippet
    /// create/edit/delete from the Manage UI, so the running tap is never stale.
    func refreshSnippets() {
        matcher.updateSnippets(snippetStore.all())
    }

    /// Creates and enables the real tap. A no-op if one is already running
    /// (idempotent, so a caller doesn't have to track whether it already called
    /// this once) and fails closed — `status = .needsAccessibility`, no tap
    /// created — when Accessibility isn't granted yet.
    func start() {
        guard eventTap == nil else { return }
        guard !DesktopInteractionGuard.isActive else { return }
        // The callers are gated on this too, but the "never observes anything while
        // off" claim belongs to this type, not to caller discipline: a third caller
        // added later cannot accidentally start the tap with the setting off.
        guard AppSettings.shared.inlineExpansionEnabled else { return }
        guard Typist.isTrusted else {
            status = .needsAccessibility
            return
        }
        refreshSnippets()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<ExpansionMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    monitor.handle(type: type, event: event)
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status = .tapFailed
            Diag.log("expansion: CGEvent tap creation failed even though Accessibility is trusted")
            return
        }

        // A tap with no run loop source attached would never actually receive an
        // event — a silent, invisible failure mode that would leave `status`
        // claiming `.active` while nothing is watched. Failing closed here means
        // that can never happen: either both exist together, or neither does.
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            status = .tapFailed
            Diag.log("expansion: could not create a run loop source for the tap")
            return
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lastEventAt = .distantPast
        status = .active
        installWorkspaceObserver()
        Diag.log("expansion: tap started")
    }

    /// Tears everything down: disables and drops the tap, removes the run loop
    /// source, stops watching for app switches, and resets the matcher's buffer.
    /// Safe to call when nothing is running.
    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        matcher.reset()
        removeWorkspaceObserver()
        activeFillIn = nil
        if status == .active { status = .off }
    }

    private func installWorkspaceObserver() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.matcher.reset()
        }
    }

    private func removeWorkspaceObserver() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Diag.log("expansion: tap disabled by the system (\(type.rawValue)); failing closed")
            failClosed()
            return
        }
        guard type == .keyDown else { return }
        guard !ExpansionLogic.isSelfSynthesized(event) else { return }

        let now = Date()
        defer { lastEventAt = now }

        guard !ExpansionLogic.shouldDropAndReset(secureInputEnabled: IsSecureEventInputEnabled()) else {
            matcher.reset()
            return
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if ExpansionLogic.isResetKey(keyCode: keyCode) {
            matcher.reset()
            return
        }

        // ⌘- or ⌃-modified keys are shortcuts, never character composition on any
        // keyboard layout (unlike ⌥, which composes accented characters on many
        // layouts and must keep flowing through to `keyboardGetUnicodeString`
        // below untouched) — they break a run of plain typing the same way a
        // reset key does.
        let flags = event.flags.intersection([.maskCommand, .maskControl])
        if !flags.isEmpty {
            matcher.reset()
            return
        }

        if ExpansionLogic.exceededTypingGap(previous: lastEventAt, now: now) {
            matcher.reset()
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }

        for character in String(utf16CodeUnits: chars, count: Int(length)) {
            if let match = matcher.feed(character) {
                inject(match: match)
            }
        }
    }

    /// The system disabled the tap out from under us (it happens after a long
    /// stall in this process, or when Accessibility is revoked mid-session).
    /// Fails closed rather than silently going quiet: tears the tap down, and
    /// flips the persisted setting off too, so Settings' toggle always tells the
    /// truth about whether anything is actually watching — the user has to
    /// notice and re-enable it, rather than believe it's still on.
    private func failClosed() {
        stop()
        status = .tapFailed
        AppSettings.shared.inlineExpansionEnabled = false
    }

    // MARK: Injection

    private func inject(match: TriggerMatcher.Match) {
        // Defensive re-check: `start()` required Accessibility to create the tap,
        // but revocation can happen at any point after that, and synthesizing
        // keystrokes we can't actually deliver is worse than doing nothing.
        guard Typist.isTrusted else {
            matcher.reset()
            return
        }
        let plan = ExpansionLogic.backspacePlan(for: match)
        synthesizeBackspaces(count: plan.count)

        switch ExpansionLogic.action(for: match.snippet) {
        case .pasteRendered(let text):
            pasteRendered(text)
        case .presentHoles:
            presentFillIn(for: match.snippet)
        }
    }

    private func synthesizeBackspaces(count: Int) {
        guard count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            else { continue }
            ExpansionLogic.tag(down)
            ExpansionLogic.tag(up)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Delivers `text` exactly the way `Typist.paste` delivers an alias command —
    /// broker write, then a synthesized ⌘V — except the pre-existing clipboard
    /// content is snapshotted first and restored a beat later via
    /// `PasteboardBroker`'s changeCount guard, so a trigger typed anywhere never
    /// permanently clobbers whatever the user had actually copied.
    private func pasteRendered(_ text: String) {
        let snapshot = PasteboardBroker.snapshot()
        let expectedChangeCount = PasteboardBroker.write(transient: text)
        synthesizePaste()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PasteboardBroker.restoreUserContent(snapshot, ifStillChangeCount: expectedChangeCount)
        }
    }

    private func synthesizePaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        ExpansionLogic.tag(down)
        ExpansionLogic.tag(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Types `text` back into whatever field currently has focus, one `Character`
    /// at a time via `keyboardSetUnicodeString` on an otherwise-inert key event —
    /// the standard way to synthesize arbitrary Unicode text via `CGEvent`,
    /// avoiding any per-event string-length limit by never asking one event to
    /// carry more than a single `Character`. Used only for `retypeTrigger` below.
    private func synthesizeText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for character in text {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            let units = Array(String(character).utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            ExpansionLogic.tag(down)
            ExpansionLogic.tag(up)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func presentFillIn(for snippet: Snippet) {
        let slots = SnippetRenderer.renderPlan(snippet: snippet)
        let controller = ExpansionFillInController()
        activeFillIn = controller
        controller.show(
            snippet: snippet,
            slots: slots,
            onConfirm: { [weak self] rendered in
                self?.pasteRendered(rendered)
                self?.activeFillIn = nil
            },
            onCancel: { [weak self] in
                self?.retypeTrigger(for: snippet)
                self?.activeFillIn = nil
            }
        )
    }

    /// Esc — or any other way the fill-in panel goes away without confirming —
    /// restores nothing on the pasteboard (nothing was ever written to it) and
    /// retypes the trigger exactly as it was, leaving the user precisely where
    /// they were before the expansion started.
    private func retypeTrigger(for snippet: Snippet) {
        synthesizeText(ExpansionLogic.retypeText(for: snippet))
    }
}

// MARK: - Fill-in panel (holds the FillInSheet while some other app is frontmost)

/// Hosts the existing, prompt-agnostic `FillInSheet` in a small centered panel of
/// its own — independent of the main palette/popover, which usually isn't even
/// open when a trigger expands, since inline expansion fires while any app on the
/// Mac is frontmost.
///
/// A normal titled `NSPanel` rather than a borderless one: it needs to become key
/// and accept real keyboard input into the sheet's fields, and "small centered
/// panel" is exactly what the packet asks for, not a chromeless overlay.
final class ExpansionFillInController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    /// Guards against the sheet's own dismissal (`orderOut`, which resigns key
    /// status) re-triggering `windowDidResignKey` as if the user had clicked away
    /// — whichever of confirm/cancel runs first is the only one that ever runs.
    private var finished = false
    private var pendingCancel: (() -> Void)?

    func show(snippet: Snippet, slots: [String],
              onConfirm: @escaping (String) -> Void,
              onCancel: @escaping () -> Void) {
        guard !DesktopInteractionGuard.isActive else { return }
        pendingCancel = onCancel
        let hostView = ExpansionFillInHostView(
            snippet: snippet, slots: slots,
            onConfirm: { [weak self] rendered in self?.finish { onConfirm(rendered) } },
            onCancel: { [weak self] in self?.finish { onCancel() } }
        )
        let hosting = NSHostingController(rootView: hostView)
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable]
        panel.title = "Fill in \u{201C}\(snippet.trigger)\u{201D}"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Runs exactly once. Clears the delegate before closing the panel so the
    /// `orderOut` below can never itself re-enter here through `windowDidResignKey`.
    private func finish(_ action: () -> Void) {
        guard !finished else { return }
        finished = true
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        pendingCancel = nil
        action()
    }

    /// Losing key status any way other than pressing Cancel or Paste — clicking
    /// into another window, ⌘-Tabbing away — is treated the same as Esc: nothing
    /// is delivered, and the trigger is retyped. Leaving the panel open,
    /// unreachable, floating over whatever the user moved on to would be worse
    /// than the (deliberately conservative) choice to treat any dismissal as a
    /// cancellation.
    func windowDidResignKey(_ notification: Notification) {
        guard !finished else { return }
        finish { self.pendingCancel?() }
    }
}

/// The SwiftUI content `ExpansionFillInController` hosts: owns the one piece of
/// state `FillInSheet` needs (`SlotFillState`) and renders/confirms/cancels through
/// it exactly the way `AppState.fillIn`'s handling does in the main window —
/// `FillInSheet` itself still knows nothing about snippets specifically.
private struct ExpansionFillInHostView: View {
    let snippet: Snippet
    @State private var fill: SlotFillState
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    init(snippet: Snippet, slots: [String], onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.snippet = snippet
        self._fill = State(initialValue: SlotFillState(slots: slots))
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        FillInSheet(
            title: "Fill in \u{201C}\(snippet.trigger)\u{201D}",
            state: $fill,
            render: { $0.rendered(snippet.template) },
            onConfirm: { onConfirm(fill.rendered(snippet.template)) },
            onCancel: onCancel
        )
        .environment(\.theme, AppSettings.shared.theme(systemIsDark: AppSettings.shared.systemIsDark))
    }
}
