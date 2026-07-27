import SwiftUI
import AppKit
import Combine

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    /// Both surfaces are built lazily and independently. A view controller belongs to
    /// one window at a time, so they cannot share a host — and in practice a user picks
    /// one style and stays there, so the other is never constructed.
    private var popover: NSPopover?
    private var palette: PaletteController?
    private let settings = AppSettings.shared
    private let store = EntryStore()
    private var state: AppState!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var keyMonitor: Any?
    private var clipboardMonitor: ClipboardMonitor?
    /// Reacts to `clipboardMonitoring` flipping after launch — from Settings, or
    /// from the clipboard source's own empty-state Enable button — so the monitor
    /// starts (or stops) live instead of only ever being decided once at launch.
    private var clipboardMonitoringCancellable: AnyCancellable?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A path configured via the environment on a previous launch has to be promoted
        // to a stored preference, or it disappears the first time the app starts as a
        // login item.
        settings.adoptEnvironmentPathIfUnset()

        state = AppState(store: store, settings: settings)
        state.onDismiss = { [weak self] in self?.closeUI() }
        state.onOpenSettings = { [weak self] in self?.openSettings() }

        // Kick the update cycle off at launch: the scheduled background check has to run
        // whether or not the settings window is ever opened.
        Updater.shared.start()

        makeStatusItem()
        installKeyMonitor()
        HotkeyRecorder.shared.start()
        registerHotkey()

        // Off means AliasBar never reads the clipboard outside of its own
        // deliveries — no monitor gets constructed at all, not merely a disabled one.
        if settings.clipboardMonitoring {
            startClipboardMonitor()
        }
        // Live toggling: flipping the setting on later — from Settings, or from the
        // clipboard source's own empty-state Enable button — starts the monitor
        // right then rather than only at the next launch. `dropFirst()` skips the
        // value this subscription immediately replays on creation, which would
        // otherwise re-run whatever the setting already was at launch a second time.
        clipboardMonitoringCancellable = settings.$clipboardMonitoring
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.startClipboardMonitor()
                } else {
                    self.clipboardMonitor?.stop()
                }
            }

        // Same posture, same reason: off means no CGEventTap is ever created, not
        // merely a disabled one. `ExpansionMonitor.shared` is a singleton (its
        // Settings section observes it live), but `start()` itself is the one
        // place the real tap comes into existence — never called at all here
        // while the setting is off.
        if settings.inlineExpansionEnabled {
            ExpansionMonitor.shared.start()
        }

        NotificationCenter.default.addObserver(
            forName: .aliasBarHotkeyFired, object: nil, queue: .main
        ) { [weak self] _ in self?.summon() }

        // A look with a second ground follows macOS between light and dark. The window is
        // usually closed when the user flips the system setting, so this cannot wait to be
        // noticed at render time.
        settings.systemIsDark = AppSettings.readSystemIsDark()
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.settings.systemIsDark = AppSettings.readSystemIsDark()
        }

        // Worth recording every launch. The app is ad-hoc signed, so every rebuild gets a
        // new code identity and macOS silently stops honouring the Accessibility grant —
        // the entry stays visible in System Settings while `AXIsProcessTrusted` returns
        // false. Without this line that failure is invisible from the outside.
        Diag.log("accessibility trusted=\(Typist.isTrusted) "
                 + "enterAction=\(settings.enterAction.rawValue)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.reportPlacement()
        }

        // Opens itself so a screenshot harness does not have to synthesise a keystroke,
        // which needs Accessibility permission and cannot run over SSH. "history" lands in
        // the history palette; "settings" opens the settings window instead, which is
        // otherwise only reachable by clicking.
        // First run, or a harness asking to pose the flow. The delay exists so the
        // status item settles first and the window does not fight the launch.
        if !settings.onboardingComplete
            || ProcessInfo.processInfo.environment["ALIASBAR_ONBOARDING"] == "1" {
            Diag.log("first run: scheduling onboarding")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openOnboarding()
            }
        }

        let openOnLaunch = ProcessInfo.processInfo.environment["ALIASBAR_OPEN_ON_LAUNCH"]
        if openOnLaunch == "1" || openOnLaunch == "history" || openOnLaunch == "settings" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                if openOnLaunch == "settings" {
                    self?.openSettings()
                    return
                }
                self?.summon()
                if openOnLaunch == "history" { self?.state.enterHistory() }
            }
        }
    }

    // MARK: Clipboard

    /// Constructs (on first call) and starts the clipboard monitor. Safe to call
    /// repeatedly — a monitor that already exists is simply told to `start()` again,
    /// which is itself idempotent (`ClipboardMonitor.start()` tears down any
    /// existing timer before installing a new one).
    private func startClipboardMonitor() {
        if let monitor = clipboardMonitor {
            monitor.start()
            return
        }
        let persistence = ClipboardPersistenceController(settings: settings)
        let monitor = ClipboardMonitor(initialHistory: persistence.loadInitialHistory(),
                                       persistence: persistence)
        clipboardMonitor = monitor
        state.clipboardMonitor = monitor
        monitor.start()
    }

    // MARK: Presentation

    private func makePopover() -> NSPopover {
        let root = RootView(state: state, settings: settings)
            .modifier(AccessibilityRegrantBanner(settings: settings, state: state))
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = hosting
        popover.behavior = .transient
        // The popover's own animation is AppKit's, not ours: it slides from the status
        // item and cannot be curve-matched to anything else. The palette does the real
        // entrance.
        popover.animates = false
        popover.delegate = self
        return popover
    }

    private func makePalette() -> PaletteController {
        // The panel has no frame of its own, so the corner has to come from the content.
        let root = RootView(state: state, settings: settings)
            .modifier(AccessibilityRegrantBanner(settings: settings, state: state))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        let controller = PaletteController(content: hosting)
        controller.onWillClose = { [weak self] in self?.state.presentationWillClose() }
        controller.onClose = { [weak self] in self?.state.editor = nil }
        return controller
    }

    private var isShown: Bool {
        (popover?.isShown ?? false) || (palette?.isShown ?? false)
    }

    private func showUI() {
        state.prepareForShow()
        NSApp.activate(ignoringOtherApps: true)
        switch settings.presentationStyle {
        case .palette:
            let palette = palette ?? makePalette()
            self.palette = palette
            // Read every time rather than at construction: the setting can change while
            // the app is running, and a window that keeps fading after you turned fading
            // off is the bug this line exists to prevent.
            palette.animates = settings.motionLevel != .none
            palette.show()
        case .menuBar:
            guard let button = statusItem.button else { return }
            let popover = popover ?? makePopover()
            self.popover = popover
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Closes both, deliberately. If the style changed while something was open, only
    /// asking the current style to close would strand the other one on screen.
    private func closeUI() {
        state.presentationWillClose()
        popover?.performClose(nil)
        palette?.close()
    }

    // MARK: Status item

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "AliasBarStatusItem"
        statusItem.behavior = []

        if let button = statusItem.button {
            // AliasBar's own mark, drawn as a template image so AppKit tints it correctly
            // in light, dark, and while the menu bar item is highlighted.
            let mark = StatusIcon.make()
            button.image = mark
            button.image?.accessibilityDescription = "AliasBar"
            // Fallback: a blank button is indistinguishable from "never got placed", so
            // guarantee something visible if the image ever fails to render.
            if mark.size.width < 1 { button.title = "\u{003E}_" }
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.isVisible = true
    }

    /// The horizontal band occupied by the camera housing, if this screen has one.
    /// macOS exposes the usable areas either side of it; the notch is the gap between them.
    private func notchBand(on screen: NSScreen?) -> ClosedRange<CGFloat>? {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              left.maxX < right.minX
        else { return nil }
        return left.maxX...right.minX
    }

    private struct Placement {
        var bad: Bool
        var offscreen: Bool
        var underNotch: Bool
        var hidden: Bool
    }

    /// Decides whether the icon is actually drawable.
    ///
    /// Every condition here is deliberately strict. An earlier version treated
    /// off-screen as "no intersection at all" and logged `isVisible` without acting on
    /// it, which meant a hidden item, or one clipped down to a sliver, was reported
    /// healthy. That is precisely the failure this whole mechanism exists to catch, so
    /// the test now demands the complete frame sit inside the drawable region.
    private func placementIsBad() -> Placement {
        guard let window = statusItem.button?.window else {
            return Placement(bad: true, offscreen: false, underNotch: false, hidden: true)
        }
        let frame = window.frame
        let screen = window.screen ?? NSScreen.main
        let screenFrame = screen?.frame ?? .zero
        let band = notchBand(on: screen)

        let hidden = !statusItem.isVisible
        // The whole frame has to be on screen, not merely touching it. A one-pixel
        // overlap is not a usable icon.
        let offscreen = screenFrame.isEmpty || !screenFrame.contains(frame)
        let underNotch = band.map { frame.maxX > $0.lowerBound && frame.minX < $0.upperBound }
            ?? false
        let degenerate = frame.width < 1 || frame.height < 1

        Diag.log("item frame=\(NSStringFromRect(frame)) visible=\(statusItem.isVisible) "
                 + "screen=\(NSStringFromRect(screenFrame)) "
                 + "notchBand=\(band.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "none") "
                 + "offscreen=\(offscreen) underNotch=\(underNotch) hidden=\(hidden) "
                 + "degenerate=\(degenerate)")

        return Placement(bad: hidden || offscreen || underNotch || degenerate,
                         offscreen: offscreen,
                         underNotch: underNotch,
                         hidden: hidden)
    }

    private static let positionKey = "NSStatusItem Preferred Position AliasBarStatusItem"

    /// A newly created status item is not positioned until AppKit gets a run loop turn,
    /// so every measurement has to wait before it means anything. Removing this await
    /// makes every fresh item read as {{0,-42}} and produces a false diagnosis.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    private func reportPlacement() {
        Task { @MainActor in
            await settle()
            guard placementIsBad().bad else {
                Diag.log("OK placement looks good")
                return
            }

            // Rescue: macOS honours a persisted preferred position per autosave name.
            // Nudging it can pull the item out of the notch band.
            for position in [CGFloat(0), 200, 400, 800, 1600] {
                UserDefaults.standard.set(position, forKey: Self.positionKey)
                rebuildStatusItem()
                await settle()
                if !placementIsBad().bad {
                    Diag.log("OK rescue succeeded at preferred position \(position)")
                    return
                }
            }

            UserDefaults.standard.removeObject(forKey: Self.positionKey)
            rebuildStatusItem()
            await settle()

            let result = placementIsBad()
            Diag.log("FAIL placement unrecoverable offscreen=\(result.offscreen) "
                     + "underNotch=\(result.underNotch) hidden=\(result.hidden)")
            warnNotPlaced(reason: result.underNotch
                ? "AliasBar's icon landed underneath the camera notch, where macOS cannot draw it."
                : result.hidden
                ? "macOS is hiding AliasBar's icon."
                : "AliasBar's icon was pushed off the edge of the menu bar.")
        }
    }

    private func rebuildStatusItem() {
        NSStatusBar.system.removeStatusItem(statusItem)
        makeStatusItem()
    }

    private func warnNotPlaced(reason: String) {
        // The alert exists because an unplaceable icon used to mean an unreachable app.
        // It no longer does: with a centred palette on a working hotkey, everything is
        // still reachable, and interrupting launch with a modal would be noise.
        if settings.presentationStyle == .palette && settings.hotkeyEnabled {
            Diag.log("icon unplaced; palette and hotkey remain available, so no warning")
            return
        }
        let alert = NSAlert()
        alert.messageText = "AliasBar is running, but you can't see it"
        alert.informativeText = reason
            + "\n\nYour menu bar is full. Quit or hide another menu bar item (or use a manager like Ice or Bartender) and AliasBar will appear."
            + (settings.hotkeyEnabled
               ? "\n\nYou can still open it with \(settings.hotkey.displayString)."
               : "")
            + "\n\nDetails: ~/Library/Logs/AliasBar-diag.log"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Quit AliasBar")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }

    // MARK: Hotkey

    private func registerHotkey() {
        guard settings.hotkeyEnabled else {
            HotkeyManager.shared.unregister()
            return
        }
        let ok = HotkeyManager.shared.register(settings.hotkey) {
            NotificationCenter.default.post(name: .aliasBarHotkeyFired, object: nil)
        }
        if !ok {
            Diag.log("hotkey \(settings.hotkey.displayString) is already taken by another app")
        }
    }

    /// Opens from the hotkey. Distinct from a click because the app that was in front
    /// has to be remembered before we steal focus, or escape has nowhere to go back to.
    private func summon() {
        if isShown {
            closeUI()
            PreviousApp.restore()
            return
        }
        PreviousApp.remember()
        showUI()
    }

    // MARK: Click

    @objc private func togglePopover(_ sender: Any?) {
        if isShown {
            closeUI()
            return
        }
        PreviousApp.remember()
        showUI()
    }

    func popoverDidClose(_ notification: Notification) {
        state.editor = nil
    }

    func popoverWillClose(_ notification: Notification) {
        state.presentationWillClose()
    }

    // MARK: Keyboard

    /// A *local* monitor: it only sees events already destined for this application, so
    /// it needs no Accessibility permission. It runs ahead of the SwiftUI text field,
    /// which is what lets arrow keys and Enter drive the selection instead of being
    /// swallowed by the search box.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShown else { return event }
            // The settings and onboarding windows have their own text fields and must
            // keep their keys.
            if event.window === self.settingsWindow { return event }
            if event.window === self.onboardingWindow { return event }
            return self.state.handleKey(event) ? nil : event
        }
    }

    // MARK: Settings window

    private func openSettings() {
        closeUI()
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(settings: settings))
        let window = NSWindow(contentViewController: hosting)
        window.title = "AliasBar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Settings changes that affect system registration have to be applied when the
        // window goes away, not polled while it is open.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { [weak self] _ in
            self?.registerHotkey()
        }
    }

    // MARK: First run

    private func openOnboarding() {
        if let window = onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView(settings: settings) { [weak self] in
            self?.onboardingWindow?.close()
        })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to AliasBar"
        // The flow draws its own header, so the title bar dissolves into the themed
        // ground; only the traffic lights remain, because closing *is* a skip path.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Diag.log("first run: onboarding window shown")

        // Completion is recorded on close, whichever way it closed — Finish, Set up
        // later, or the traffic light. There is no path that shows the flow twice.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { [weak self] _ in
            self?.settings.onboardingComplete = true
            // A rebind made in the flow takes effect the same way one made in the
            // settings window does.
            self?.registerHotkey()
            self?.onboardingWindow = nil
        }
    }
}

// MARK: - Entry point

@main
enum AliasBarMain {
    // NSApplication.delegate is weak, so the delegate has to be owned somewhere durable.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
