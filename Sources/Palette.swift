import SwiftUI
import AppKit

// MARK: - The panel

/// A borderless floating panel that hosts the same UI the popover does.
///
/// A popover has to hang off the status item, so it inherits every one of the status
/// item's problems: on a full menu bar the item lands under the notch or off the edge,
/// and the whole `placementIsBad` rescue exists to cope with that. A panel is positioned
/// by us, on a screen we pick, and none of that applies.
final class PalettePanel: NSPanel {
    /// A borderless window is not key-eligible by default, which would leave the search
    /// field visibly focused but swallowing nothing.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// While true, a content-size change keeps the *top* edge where it is instead of the
    /// bottom one. The list shrinks as you type; AppKit's default would walk the whole
    /// window up the screen on every keystroke.
    var anchorsTop = true

    override func setContentSize(_ size: NSSize) {
        guard anchorsTop, isVisible else {
            super.setContentSize(size)
            return
        }
        let top = frame.maxY
        super.setContentSize(size)
        var moved = frame
        moved.origin.y = top - moved.height
        super.setFrame(moved, display: true)
    }
}

// MARK: - Controller

/// Owns the palette window and decides where it opens.
final class PaletteController: NSObject, NSWindowDelegate {
    private var panel: PalettePanel?
    private let content: NSViewController
    /// Called when the window goes away for any reason, including the user clicking off
    /// it. The delegate uses this to reset transient state, exactly as `popoverDidClose`
    /// did.
    var onClose: () -> Void = {}

    init(content: NSViewController) {
        self.content = content
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Sizing has to happen before positioning, or the first open is placed using the
        // previous run's height.
        panel.layoutIfNeeded()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        onClose()
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                                 styleMask: [.borderless],
                                 backing: .buffered,
                                 defer: false)
        panel.contentViewController = content
        panel.delegate = self
        panel.level = .floating
        // Follow the user to whatever space or full-screen app they are in. A palette
        // that only opens on the desktop you launched it from is useless.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        return panel
    }

    /// Centred horizontally, and set high — the top edge sits a fifth of the way down.
    ///
    /// Vertically centred looks wrong for anything that grows a list downward: the
    /// window drifts as results filter, and long lists run off the bottom.
    private func position(_ panel: PalettePanel) {
        let screen = Self.focusedScreen()
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - visible.height * 0.20 - size.height
        panel.setFrame(NSRect(x: x.rounded(), y: max(visible.minY, y).rounded(),
                              width: size.width, height: size.height),
                       display: false)
    }

    /// The screen the user is looking at. The mouse is the only signal available from a
    /// global hotkey: our app is not frontmost, so `NSScreen.main` reports whichever
    /// screen the *other* app's key window happens to be on, which is often stale.
    private static func focusedScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: Dismissal

    func windowDidResignKey(_ notification: Notification) {
        // A sheet takes key away from its parent. Closing here would tear the editor out
        // from under the user mid-edit.
        guard panel?.attachedSheet == nil else { return }
        close()
    }
}
