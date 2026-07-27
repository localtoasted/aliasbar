import XCTest

@testable import AliasBarCore

/// Pins *which* refusal fires, not merely that one fired.
///
/// `rangeOfAlias` ends with three guards in a fixed order — `unsupportedHeredocDelimiter`,
/// then `hasUnconsumedHeredoc`, then `continues` — and the order is load-bearing: it is
/// what decides the sentence the user reads about their own shell config. Every other
/// suite in this repo asserts refusal-versus-success, so swapping two of those guards
/// changes the message on ~/.zshrc and ships green.
///
/// Each fixture below is built so that more than one guard would fire on it, and each
/// assertion names the case *and* the reason string. Reorder the guards and these fail.
/// Each fixture also asserts the file on disk is byte-for-byte unchanged, because a
/// refusal that still wrote something would be the worse bug.
final class AliasWriterErrorIdentityTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aliasbar-error-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func scratch(_ contents: String, name: String = "zshrc") throws -> String {
        let path = sandbox.appendingPathComponent("\(name)-\(UUID().uuidString)").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Runs the operation, requires it to throw, hands the error to `check`, and proves
    /// the file was left exactly as it was found.
    private func refusal(_ operation: AliasWriter.Operation,
                         on contents: String,
                         file: StaticString = #filePath,
                         line: UInt = #line,
                         check: (AliasWriter.WriteError) -> Void) throws {
        let path = try scratch(contents)
        XCTAssertThrowsError(try AliasWriter.apply(operation, path: path, allEntries: []),
                             "the edit had to be refused",
                             file: file, line: line) { error in
            guard let writeError = error as? AliasWriter.WriteError else {
                return XCTFail("expected an AliasWriter.WriteError, got \(error)",
                               file: file, line: line)
            }
            check(writeError)
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), contents,
                       "a refused edit must leave the file byte-for-byte unchanged",
                       file: file, line: line)
    }

    // MARK: Guard 1 — unsupported heredoc delimiter

    /// `$'…'` is quote-removal syntax the scanner does not model, so the terminator
    /// cannot be located the way zsh would and the span's extent is untrustworthy.
    ///
    /// All three guards would fire on this fixture: the unsupported delimiter also
    /// counts as unconsumed heredoc input, which in turn forces `continues`. Only the
    /// first guard produces this sentence.
    func testUnsupportedHeredocDelimiterRefusesWithItsOwnReason() throws {
        let contents = """
        \(ManagedBlock.begin)
        alias doomed=cat <<$'E'
        payload
        E
        \(ManagedBlock.end)

        """
        try refusal(.delete(name: "doomed"), on: contents) { error in
            guard case .wouldBreakSyntax(let why) = error else {
                return XCTFail("an unsupported heredoc delimiter must be .wouldBreakSyntax, got \(error)")
            }
            XCTAssertTrue(why.contains("heredoc delimiter this app cannot parse"),
                          "the unsupported-delimiter guard must be the one that fired, not the "
                              + "unconsumed-heredoc guard or the never-terminated guard: \(why)")
        }
    }

    /// The same guard on an upsert rather than a delete — the refusal belongs to the
    /// span computation, so it must not depend on which operation asked for the span.
    func testUnsupportedHeredocDelimiterAlsoRefusesAnUpsert() throws {
        let contents = """
        \(ManagedBlock.begin)
        alias doomed=cat <<$'E'
        payload
        E
        \(ManagedBlock.end)

        """
        try refusal(.upsert(name: "doomed", command: "echo replaced", comment: nil),
                    on: contents) { error in
            guard case .wouldBreakSyntax(let why) = error else {
                return XCTFail("an unsupported heredoc delimiter must be .wouldBreakSyntax, got \(error)")
            }
            XCTAssertTrue(why.contains("heredoc delimiter this app cannot parse"), why)
        }
    }

    // MARK: Guard 2 — unconsumed heredoc

    /// A heredoc whose terminator never arrives before the end marker. The delimiter
    /// itself is perfectly ordinary, so guard 1 stays quiet; `continues` is true as
    /// well, so hoisting guard 3 above this one would change the message.
    func testUnconsumedHeredocRefusesWithItsOwnReason() throws {
        let contents = """
        \(ManagedBlock.begin)
        alias doomed=cat <<EOF
        payload
        \(ManagedBlock.end)

        """
        try refusal(.delete(name: "doomed"), on: contents) { error in
            guard case .wouldBreakSyntax(let why) = error else {
                return XCTFail("an unconsumed heredoc must be .wouldBreakSyntax, got \(error)")
            }
            XCTAssertTrue(why.contains("unconsumed heredoc input"),
                          "the unconsumed-heredoc guard must be the one that fired, not the "
                              + "never-terminated guard: \(why)")
        }
    }

    // MARK: Guard 3 — never terminated

    /// A quote still open at the end marker. Nothing heredoc-related is in play, so
    /// this is the only fixture the third guard owns — and it is a *different*
    /// WriteError case, which is what makes the whole ordering observable.
    func testUnterminatedQuoteRefusesAsMalformedMarkers() throws {
        let contents = """
        \(ManagedBlock.begin)
        alias doomed='never closed
        \(ManagedBlock.end)

        """
        try refusal(.delete(name: "doomed"), on: contents) { error in
            guard case .malformedMarkers(let why) = error else {
                return XCTFail("a statement running past the end marker must be "
                                   + ".malformedMarkers, got \(error)")
            }
            XCTAssertTrue(why.contains("never terminated"), why)
        }
    }

    // MARK: renameSourceMissing, both routes

    /// A rename whose source is gone but whose block exists takes the guard inside
    /// `rewriteExistingBlock`, after the destination lookup.
    func testRenameWithMissingSourceInsideAnExistingBlockIsRenameSourceMissing() throws {
        let contents = """
        \(ManagedBlock.begin)
        alias other='echo other'
        \(ManagedBlock.end)

        """
        try refusal(.rename(from: "ghost", to: "revenant", command: "echo x"),
                    on: contents) { error in
            guard case .renameSourceMissing(let name) = error else {
                return XCTFail("a missing rename source must be .renameSourceMissing, got \(error)")
            }
            XCTAssertEqual(name, "ghost", "the error must name the source, not the destination")
        }
    }

    /// The same refusal from the other route: no managed block at all, which reaches
    /// `rewriteWithoutBlock`. Both routes have to agree, or a stale rename would look
    /// like a no-op on one of them.
    func testRenameWithNoManagedBlockAtAllIsRenameSourceMissing() throws {
        let contents = "export PATH=/usr/bin\nalias mine='echo mine'\n"
        try refusal(.rename(from: "ghost", to: "revenant", command: "echo x"),
                    on: contents) { error in
            guard case .renameSourceMissing(let name) = error else {
                return XCTFail("a missing rename source must be .renameSourceMissing, got \(error)")
            }
            XCTAssertEqual(name, "ghost")
        }
    }

    // MARK: The control

    /// The negative control for all of the above: an ordinary edit to the same shape of
    /// file must still succeed, so a fixture that started refusing for an unrelated
    /// reason cannot pass this suite by accident.
    func testAnOrdinaryEditOnTheSameShapeOfFileStillSucceeds() throws {
        let path = try scratch("""
        \(ManagedBlock.begin)
        alias doomed=cat <<EOF
        payload
        EOF
        \(ManagedBlock.end)

        """)
        _ = try AliasWriter.apply(.upsert(name: "fresh", command: "echo fresh", comment: nil),
                                  path: path, allEntries: [])
        let after = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(after.contains("alias fresh='echo fresh'"))
        XCTAssertTrue(after.contains("alias doomed=cat <<EOF"), "the heredoc must survive untouched")
    }
}
