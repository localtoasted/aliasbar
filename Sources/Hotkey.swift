import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey.
///
/// Deliberately built on Carbon's `RegisterEventHotKey` rather than
/// `NSEvent.addGlobalMonitorForEvents` or a `CGEventTap`. The event-monitor approaches
/// see every keystroke the user types anywhere, so macOS gates them behind Accessibility
/// or Input Monitoring permission. `RegisterEventHotKey` asks the window server to
/// deliver one specific combination and nothing else, so it needs no permission at all
/// and shows no scary dialog on first launch. For a utility this small, that tradeoff is
/// worth more than the extra flexibility.
///
/// The API is old but not deprecated: it remains the mechanism AppKit itself uses, and it
/// works unchanged on macOS 13 through 15.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onFire: (() -> Void)?

    /// Arbitrary four-char code identifying our hotkey in Carbon's global namespace.
    private let signature: OSType = 0x414C4253 // 'ALBS'
    /// The id of the registration currently in force. Compared against the id carried by
    /// each event so a retired registration cannot fire.
    fileprivate var activeID: UInt32 = 0
    private var idCounter: UInt32 = 0

    private init() {}

    /// (Re)registers the combination.
    ///
    /// A `true` return means only that the registration was accepted. It does **not**
    /// mean the combination is free. From the HIToolbox header: "The same hot key can,
    /// however, be registered by multiple applications." Registering ⌘Space succeeds
    /// with `noErr` even though Spotlight owns it, and `kEventHotKeyExclusive` does not
    /// change that. So there is no such thing as a runtime conflict check here, and the
    /// UI must never claim one combination is taken and another is free.
    @discardableResult
    func register(_ combo: HotkeyCombo, onFire: @escaping () -> Void) -> Bool {
        guard !DesktopInteractionGuard.isActive else { return false }
        guard installHandler() else {
            Diag.log("hotkey event handler could not be installed")
            return false
        }

        // Register the candidate *before* tearing down the working one. Unregistering
        // first means a rejected combination leaves the app with no shortcut at all,
        // which is worst exactly when it matters most: the menu bar icon is hidden and
        // the hotkey is the only way in.
        var candidateRef: EventHotKeyRef?
        let eventID = EventHotKeyID(signature: signature, id: nextHotkeyID())
        let status = RegisterEventHotKey(combo.keyCode,
                                         combo.modifiers,
                                         eventID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &candidateRef)
        guard status == noErr, let candidateRef else {
            Diag.log("hotkey registration failed for \(combo.displayString) status=\(status); "
                     + "keeping the previous shortcut")
            return false
        }

        // The new one is live, so it is now safe to drop the old one.
        if let previous = hotKeyRef { UnregisterEventHotKey(previous) }
        hotKeyRef = candidateRef
        activeID = eventID.id
        self.onFire = onFire
        Diag.log("hotkey registered: \(combo.displayString)")
        return true
    }

    /// Each registration gets a fresh id so the old and new can coexist for the moment
    /// between registering the replacement and retiring the original.
    private func nextHotkeyID() -> UInt32 {
        idCounter += 1
        return idCounter
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Installs the Carbon event handler once. Returns false if it could not be
    /// installed, because in that case a "successful" hotkey registration would never
    /// actually deliver anything and reporting success would be a lie.
    @discardableResult
    private func installHandler() -> Bool {
        guard eventHandler == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        // The callback is a C function pointer and cannot capture context, so `self`
        // travels through userData.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            var firedID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &firedID)
            guard status == noErr, firedID.id == manager.activeID else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { manager.onFire?() }
            return noErr
        }

        let result = InstallEventHandler(GetApplicationEventTarget(),
                                         callback,
                                         1,
                                         &spec,
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         &eventHandler)
        if result != noErr {
            eventHandler = nil
            return false
        }
        return true
    }
}

// MARK: - Focus return

/// Remembers which application was in front so focus can be handed back on dismiss.
///
/// Without this the app you were working in loses focus the moment AliasBar opens, and
/// pressing escape leaves you typing into nothing. Reading and reactivating the frontmost
/// application needs no special permission; only *synthesising keystrokes* into it does.
enum PreviousApp {
    private(set) static var stored: NSRunningApplication?

    static func remember() {
        guard !DesktopInteractionGuard.isActive else { return }
        let front = NSWorkspace.shared.frontmostApplication
        // Ignore ourselves, or reopening while already open would trap focus here.
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            stored = front
        }
    }

    static func restore() {
        guard !DesktopInteractionGuard.isActive else {
            stored = nil
            return
        }
        guard let app = stored else { return }
        app.activate(options: [])
        stored = nil
    }

    /// Restores the remembered app and waits until AppKit reports it as active.
    /// The short sleep is only a polling cadence; activation itself, not elapsed
    /// time, is the readiness signal that permits a synthetic paste.
    @MainActor
    static func restoreAndWaitForActivation(maxPolls: Int = 100) async -> Bool {
        guard !DesktopInteractionGuard.isActive else {
            stored = nil
            return false
        }
        guard let app = stored else { return false }
        stored = nil
        if app.isActive { return true }
        guard app.activate(options: []) else { return false }

        for _ in 0..<maxPolls {
            if app.isActive { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return app.isActive
    }

    static func forget() { stored = nil }
}

// MARK: - Typing into the previous app

/// Synthesises a paste into whatever application is now frontmost.
///
/// This is the one feature that genuinely requires Accessibility permission, which is why
/// it is opt-in via the Enter-action setting rather than the default. `AXIsProcessTrusted`
/// is checked before every attempt so a revoked permission surfaces as a message rather
/// than as keystrokes silently going nowhere.
enum Typist {
    static var isTrusted: Bool {
        !DesktopInteractionGuard.isActive && AXIsProcessTrusted()
    }

    /// Prompts for Accessibility permission, showing the system dialog.
    static func requestTrust() {
        guard !DesktopInteractionGuard.isActive else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Puts `text` on the pasteboard and sends ⌘V to the frontmost app.
    ///
    /// Pasting rather than typing character by character: it is one event instead of
    /// dozens, it cannot be garbled by key-repeat timing, and it handles every character
    /// including ones with no key code on the current layout.
    static func paste(_ text: String) -> Bool {
        guard !DesktopInteractionGuard.isActive else { return false }
        guard isTrusted else { return false }

        PasteboardBroker.write(transient: text)

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
