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
    private let hotkeyID: UInt32 = 1

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
        unregister()
        self.onFire = onFire

        installHandlerIfNeeded()

        let eventID = EventHotKeyID(signature: signature, id: hotkeyID)
        let status = RegisterEventHotKey(combo.keyCode,
                                         combo.modifiers,
                                         eventID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotKeyRef)
        if status != noErr {
            Diag.log("hotkey registration failed for \(combo.displayString) status=\(status)")
            hotKeyRef = nil
            return false
        }
        Diag.log("hotkey registered: \(combo.displayString)")
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
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
            guard status == noErr, firedID.id == manager.hotkeyID else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { manager.onFire?() }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(),
                            callback,
                            1,
                            &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandler)
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
        let front = NSWorkspace.shared.frontmostApplication
        // Ignore ourselves, or reopening while already open would trap focus here.
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            stored = front
        }
    }

    static func restore() {
        guard let app = stored else { return }
        app.activate(options: [])
        stored = nil
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
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts for Accessibility permission, showing the system dialog.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Puts `text` on the pasteboard and sends ⌘V to the frontmost app.
    ///
    /// Pasting rather than typing character by character: it is one event instead of
    /// dozens, it cannot be garbled by key-repeat timing, and it handles every character
    /// including ones with no key code on the current layout.
    static func paste(_ text: String) -> Bool {
        guard isTrusted else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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
