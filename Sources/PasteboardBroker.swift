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

/// Hard boundary between automated tests and the live desktop.
///
/// The test binary exercises the same delivery methods as the app. On a developer Mac
/// that has already granted Accessibility, those methods can otherwise write fixture
/// text to the real clipboard and synthesize Command-V into whichever app is focused.
/// `test.sh` sets this flag before the binary starts; direct test-binary runs set it in
/// their top-level harness as a second line of defense.
enum DesktopInteractionGuard {
    static let environmentKey = "ALIASBAR_TEST_MODE"

    static var isActive: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    static func blocks(_ pasteboard: PasteboardWriting) -> Bool {
        isActive && pasteboard === NSPasteboard.general
    }
}

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

    /// changeCounts we produced, keyed by pasteboard identity, newest last, capped to
    /// the most recent `maxRecordedChangeCounts` per key.
    ///
    /// Keying by identity (rather than one global set) means a test's fake pasteboard
    /// can never collide with another test's, or with `NSPasteboard.general`, whose
    /// counts persist for the app's whole run — but `ObjectIdentifier` is a pointer
    /// value, and AppKit is free to recycle a deallocated pasteboard's address for an
    /// unrelated object later. Without a cap, a long-running app session would both
    /// grow this dictionary forever (a leak: every distinct pasteboard the app has
    /// ever touched, including short-lived test fakes, stays keyed here) and risk a
    /// recycled identity inheriting a stale, unrelated set of "self-written" counts.
    /// Keeping only the last few counts per key bounds the leak and keeps a stale
    /// identity's history small enough to be harmless even if it is reused.
    private static let maxRecordedChangeCounts = 8
    private static var selfWriteChangeCounts: [ObjectIdentifier: [Int]] = [:]

    /// Writes `transient` to `pasteboard` and remembers the changeCount it produced.
    @discardableResult
    static func write(transient: String, to pasteboard: PasteboardWriting = NSPasteboard.general) -> Int {
        // Tests may use any number of in-memory pasteboards, but the user's real one
        // is never a valid test target.
        guard !DesktopInteractionGuard.blocks(pasteboard) else {
            return 0
        }
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

    /// Test-only: how many changeCounts are currently recorded for `pasteboard`, so a
    /// test can prove the bound holds without reaching into private storage.
    static func recordedChangeCountForTesting(on pasteboard: PasteboardWriting) -> Int {
        selfWriteChangeCounts[ObjectIdentifier(pasteboard)]?.count ?? 0
    }

    /// Test-only: clears every recorded self-write changeCount for every pasteboard
    /// identity this process has ever seen.
    ///
    /// `ObjectIdentifier`-keyed tracking is a memory address, and production's
    /// `NSPasteboard.general` identity never gets freed and reallocated mid-run —
    /// but a test suite constructing many short-lived `PasteboardWriting` fakes in
    /// a tight sequence can have a later fake's allocation land at the exact
    /// address an earlier, already-deallocated fake used, which would then
    /// spuriously "inherit" that earlier fake's recorded self-writes. A test that
    /// constructs a fresh fake and cares about self-write detection being correct
    /// from a clean slate should call this first.
    static func resetForTesting() {
        selfWriteChangeCounts.removeAll()
    }

    /// Captures `pasteboard`'s current string content, to hand to `restoreUserContent`
    /// once whatever transient write follows is done with it.
    static func snapshot(of pasteboard: PasteboardWriting = NSPasteboard.general) -> Snapshot {
        guard !DesktopInteractionGuard.blocks(pasteboard) else { return Snapshot(string: nil) }
        return Snapshot(string: pasteboard.string(forType: .string))
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
        guard !DesktopInteractionGuard.blocks(pasteboard) else { return false }
        guard pasteboard.changeCount == expected else { return false }
        pasteboard.clearContents()
        if let string = snapshot.string {
            pasteboard.setString(string, forType: .string)
        }
        record(pasteboard.changeCount, on: pasteboard)
        return true
    }

    private static func record(_ count: Int, on pasteboard: PasteboardWriting) {
        var counts = selfWriteChangeCounts[ObjectIdentifier(pasteboard), default: []]
        counts.removeAll { $0 == count }
        counts.append(count)
        if counts.count > maxRecordedChangeCounts {
            counts.removeFirst(counts.count - maxRecordedChangeCounts)
        }
        selfWriteChangeCounts[ObjectIdentifier(pasteboard)] = counts
    }
}
