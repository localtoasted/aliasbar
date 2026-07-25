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

    /// While true, a content-size change keeps the window's top edge and horizontal
    /// centre where they are, rather than its bottom-left corner.
    ///
    /// Both halves are load-bearing. The list shrinks as you type, and AppKit's default
    /// would walk the window up the screen on every keystroke. The width changes too —
    /// Manage is wider than Find — and without re-centring the window would grow out to
    /// the right and sit off-centre for the rest of the session.
    var anchorsTop = true

    override func setContentSize(_ size: NSSize) {
        guard anchorsTop, isVisible else {
            super.setContentSize(size)
            return
        }
        let top = frame.maxY
        let centre = frame.midX
        super.setContentSize(size)
        var moved = frame
        moved.origin.y = top - moved.height
        moved.origin.x = (centre - moved.width / 2).rounded()
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

    /// Whether the window itself is allowed to fade. Set from settings before each show,
    /// because the panel's own animation and the SwiftUI entrance are two separate things
    /// and wiring one while forgetting the other is exactly how half a fade ships.
    var animates = true

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.alphaValue = 1
        // Sizing has to happen before positioning, and it has to be forced rather than
        // waited for. Left to itself the hosting controller reports its real size a beat
        // *after* the window is placed, so the window is centred at its placeholder
        // width and then grows out to the right of centre.
        panel.layoutIfNeeded()
        if let view = panel.contentViewController?.view {
            let fitting = view.fittingSize
            if fitting.width > 1, fitting.height > 1 { panel.setContentSize(fitting) }
        }
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel, animates, panel.isVisible else {
            panel?.orderOut(nil)
            onClose()
            return
        }
        // Fade, then order out. Leaving is faster than arriving — nobody wants to watch a
        // dismissal, and the window is usually already behind whatever regained focus.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1
            self?.onClose()
        }
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0,
                                                     width: WindowLayout.windowWidth,
                                                     height: WindowLayout.bodyHeight),
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
        let wanted = visible.maxY - visible.height * 0.20 - size.height
        // On a short screen the fifth-of-the-way-down rule would put the bottom edge under
        // the Dock. Slide up rather than clip, and stop at the top of the visible area so
        // a window taller than the screen loses its bottom rather than its search field.
        let lowest = visible.minY + 12
        let highest = max(visible.maxY - size.height, visible.minY)
        let y = min(max(wanted, lowest), highest)
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(),
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
