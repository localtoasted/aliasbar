import SwiftUI
import AppKit

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let settings = AppSettings.shared
    private let store = EntryStore()
    private var state: AppState!
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A path configured via the environment on a previous launch has to be promoted
        // to a stored preference, or it disappears the first time the app starts as a
        // login item.
        settings.adoptEnvironmentPathIfUnset()

        state = AppState(store: store, settings: settings)
        state.onDismiss = { [weak self] in self?.closePopover() }
        state.onOpenSettings = { [weak self] in self?.openSettings() }

        makeStatusItem()
        makePopover()
        installKeyMonitor()
        HotkeyRecorder.shared.start()
        registerHotkey()

        NotificationCenter.default.addObserver(
            forName: .aliasBarHotkeyFired, object: nil, queue: .main
        ) { [weak self] _ in self?.summon() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.reportPlacement()
        }
    }

    private func makePopover() {
        let hosting = NSHostingController(rootView: RootView(state: state, settings: settings))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
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
        if popover.isShown {
            closePopover()
            PreviousApp.restore()
            return
        }
        PreviousApp.remember()
        showPopover()
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
            return
        }
        PreviousApp.remember()
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        state.prepareForShow()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        state.editor = nil
    }

    // MARK: Keyboard

    /// A *local* monitor: it only sees events already destined for this application, so
    /// it needs no Accessibility permission. It runs ahead of the SwiftUI text field,
    /// which is what lets arrow keys and Enter drive the selection instead of being
    /// swallowed by the search box.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            // The settings window has its own text fields and must keep its keys.
            if event.window === self.settingsWindow { return event }
            return self.state.handleKey(event) ? nil : event
        }
    }

    // MARK: Settings window

    private func openSettings() {
        closePopover()
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
