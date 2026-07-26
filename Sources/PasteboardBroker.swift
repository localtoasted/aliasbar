import AppKit

/// Minimal surface `PasteboardBroker` needs from a pasteboard. Matches
/// `NSPasteboard`'s own method signatures exactly, so `extension NSPasteboard:
/// PasteboardWriting {}` below costs nothing — and so tests can hand the broker a
/// fake that never touches the real system pasteboard.
protocol PasteboardWriting: AnyObject {
    var changeCount: Int { get }
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    func string(forType type: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboard: PasteboardWriting {}

/// The only place in the app that writes to a pasteboard.
///
/// Every write records the `changeCount` it produced as our own. That is the one
/// signal `ClipboardMonitor` has to tell "we just delivered an alias" from "the user
/// copied something while we weren't looking" — without it, every paste and every
/// preset export would show back up in clipboard history as if the user had copied
/// it themselves.
enum PasteboardBroker {
    /// What a pasteboard held right before a transient write, kept only long enough
    /// to hand back to `restoreUserContent`.
    struct Snapshot {
        let string: String?
    }

    /// changeCounts we produced, keyed by pasteboard identity. Keying by identity
    /// (rather than one global set) means a test's fake pasteboard can never collide
    /// with another test's, or with `NSPasteboard.general`, whose counts persist for
    /// the app's whole run.
    private static var selfWriteChangeCounts: [ObjectIdentifier: Set<Int>] = [:]

    /// Writes `transient` to `pasteboard` and remembers the changeCount it produced.
    @discardableResult
    static func write(transient: String, to pasteboard: PasteboardWriting = NSPasteboard.general) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(transient, forType: .string)
        let count = pasteboard.changeCount
        record(count, on: pasteboard)
        return count
    }

    /// True when `changeCount` is one this broker produced itself, on `pasteboard`.
    static func isSelfWrite(changeCount: Int, on pasteboard: PasteboardWriting = NSPasteboard.general) -> Bool {
        selfWriteChangeCounts[ObjectIdentifier(pasteboard)]?.contains(changeCount) ?? false
    }

    /// Captures `pasteboard`'s current string content, to hand to `restoreUserContent`
    /// once whatever transient write follows is done with it.
    static func snapshot(of pasteboard: PasteboardWriting = NSPasteboard.general) -> Snapshot {
        Snapshot(string: pasteboard.string(forType: .string))
    }

    /// Restores `snapshot`, but only if `pasteboard`'s changeCount is still exactly
    /// `expected` — proof that nothing external wrote to the pasteboard between the
    /// transient write `expected` came from and now. If the user copied something new
    /// in the meantime, restoring would clobber it, so this quietly does nothing
    /// instead of guessing.
    @discardableResult
    static func restoreUserContent(
        _ snapshot: Snapshot,
        ifStillChangeCount expected: Int,
        on pasteboard: PasteboardWriting = NSPasteboard.general
    ) -> Bool {
        guard pasteboard.changeCount == expected else { return false }
        pasteboard.clearContents()
        if let string = snapshot.string {
            pasteboard.setString(string, forType: .string)
        }
        record(pasteboard.changeCount, on: pasteboard)
        return true
    }

    private static func record(_ count: Int, on pasteboard: PasteboardWriting) {
        selfWriteChangeCounts[ObjectIdentifier(pasteboard), default: []].insert(count)
    }
}
