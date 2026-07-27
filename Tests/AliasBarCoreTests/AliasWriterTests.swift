import XCTest

@testable import AliasBarCore

/// A representative slice of the AliasWriter suite, ported to XCTest.
///
/// The full harness is still `Tests/WriterTests.swift`, run by ./test.sh — it links the
/// app's AppState and monitors, which SwiftPM does not build. What lives here is the
/// part that only needs the Foundation core: quoting, validation, and the file-writing
/// contract, including the round-trip through the real zsh binary.
final class AliasWriterQuotingTests: XCTestCase {
    func testPlainCommandIsSingleQuoted() {
        XCTAssertEqual(AliasWriter.quote("git status"), "'git status'")
    }

    func testEmbeddedSingleQuoteIsEscapedAndTheTrailingEmptyPairTrimmed() {
        XCTAssertEqual(AliasWriter.quote("echo 'hi'"), "'echo '\\''hi'\\'")
    }

    func testLeadingQuoteKeepsItsEmptySegment() {
        XCTAssertEqual(AliasWriter.quote("'x"), "''\\''x'")
    }

    func testDoubleQuotesAndDollarSignsAreLiteral() {
        XCTAssertEqual(AliasWriter.quote("echo \"hi\""), "'echo \"hi\"'")
        XCTAssertEqual(AliasWriter.quote("echo $HOME"), "'echo $HOME'")
    }

    func testAliasLineIsTheQuotedCommand() {
        XCTAssertEqual(AliasWriter.aliasLine(name: "gst", command: "git status"),
                       "alias gst='git status'")
    }
}

/// Asks zsh itself whether the emitted line defines what was meant.
///
/// The value is read out of `${aliases[...]}` rather than from `alias name` output:
/// `alias` re-quotes in zsh's own canonical form, so comparing that would test
/// cosmetics. The value is what matters.
final class AliasWriterZshOracleTests: XCTestCase {
    private func zshRoundTrip(name: String, command: String) throws -> String {
        let line = AliasWriter.aliasLine(name: name, command: command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "\(line)\nprint -r -- ${aliases[\(name)]}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zsh rejected: \(line)")
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testZshReadsBackExactlyWhatWasMeant() throws {
        for command in [
            "git status",
            "echo 'hi'",
            "echo \"hi\"",
            "echo $HOME",
            "git log --oneline | head -20",
            "cd ~/src && ls -la",
            "printf '%s\\n' one two",
            "grep -R \"needle\" . # with a comment",
            "echo it's fine",
            "echo a;echo b",
            "echo $(date)",
            "awk '{print $1}'",
        ] {
            XCTAssertEqual(try zshRoundTrip(name: "abtest", command: command), command,
                           "round-trip changed the command")
        }
    }

    func testZshAcceptsUnicodeAndBackslashes() throws {
        XCTAssertEqual(try zshRoundTrip(name: "abtest", command: "echo héllo → ✅"),
                       "echo héllo → ✅")
        XCTAssertEqual(try zshRoundTrip(name: "abtest", command: #"echo a\nb"#),
                       #"echo a\nb"#)
    }
}

final class AliasWriterValidationTests: XCTestCase {
    private func validationError(name: String, command: String) -> AliasWriter.WriteError? {
        do {
            try AliasWriter.validate(name: name, command: command)
            return nil
        } catch let error as AliasWriter.WriteError {
            return error
        } catch {
            return nil
        }
    }

    func testOrdinaryNamesAndCommandsValidate() {
        XCTAssertNil(validationError(name: "gst", command: "git status"))
        XCTAssertNil(validationError(name: "g.s", command: "git status"))
        XCTAssertNil(validationError(name: "deploy-prod", command: "make deploy"))
    }

    func testEmptyNameAndCommandAreRejected() {
        guard case .invalidName = validationError(name: "  ", command: "git status") else {
            return XCTFail("a blank name must be rejected")
        }
        guard case .emptyCommand = validationError(name: "gst", command: "   \n ") else {
            return XCTFail("a blank command must be rejected")
        }
    }

    func testMultilineCommandsAreRejected() {
        // A newline would emit a physically multi-line statement held together only by
        // its quotes; a later edit to one line would orphan the rest, and orphaned
        // lines in an rc file run at shell startup.
        guard case .multilineCommand = validationError(name: "gst", command: "git\nstatus") else {
            return XCTFail("a multiline command must be rejected")
        }
    }

    func testNamesNeedingQuotingAreRejected() {
        for name in ["has space", "semi;colon", "quote'd", "star*", "dollar$"] {
            guard case .invalidName = validationError(name: name, command: "echo x") else {
                return XCTFail("\(name) must be rejected as an alias name")
            }
        }
    }

    func testReservedNamesAreRejected() {
        for name in ["if", "function", "while", "alias"] {
            guard case .reservedName = validationError(name: name, command: "echo x") else {
                return XCTFail("\(name) is a zsh reserved word and must be rejected")
            }
        }
    }
}

/// The writing contract, exercised against scratch files only — never a real .zshrc.
final class AliasWriterApplyTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aliasbar-spm-tests-\(UUID().uuidString)")
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

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    func testUpsertCreatesTheManagedBlockAndKeepsExistingContent() throws {
        let path = try scratch("export PATH=/usr/bin\nalias mine='echo mine'\n")
        _ = try AliasWriter.apply(.upsert(name: "gst", command: "git status", comment: nil),
                                  path: path, allEntries: [])

        let after = try read(path)
        XCTAssertTrue(after.contains("alias gst='git status'"))
        XCTAssertTrue(after.contains(ManagedBlock.begin))
        XCTAssertTrue(after.contains(ManagedBlock.end))
        XCTAssertTrue(after.contains("export PATH=/usr/bin"), "untouched content must survive")
        XCTAssertTrue(after.contains("alias mine='echo mine'"))
    }

    func testUpsertOfTheSameNameReplacesRatherThanDuplicates() throws {
        let path = try scratch("")
        _ = try AliasWriter.apply(.upsert(name: "gst", command: "git status", comment: nil),
                                  path: path, allEntries: [])
        _ = try AliasWriter.apply(.upsert(name: "gst", command: "git status --short", comment: nil),
                                  path: path, allEntries: [])

        let after = try read(path)
        XCTAssertTrue(after.contains("alias gst='git status --short'"))
        XCTAssertFalse(after.contains("alias gst='git status'\n"))
        XCTAssertEqual(after.components(separatedBy: "alias gst=").count - 1, 1)
    }

    func testDeleteRemovesOnlyItsOwnLine() throws {
        let path = try scratch("")
        _ = try AliasWriter.apply(.upsert(name: "keep", command: "echo keep", comment: nil),
                                  path: path, allEntries: [])
        _ = try AliasWriter.apply(.upsert(name: "drop", command: "echo drop", comment: nil),
                                  path: path, allEntries: [])
        _ = try AliasWriter.apply(.delete(name: "drop"), path: path, allEntries: [])

        let after = try read(path)
        XCTAssertFalse(after.contains("alias drop="))
        XCTAssertTrue(after.contains("alias keep='echo keep'"))
    }

    func testRenameIsOneOperation() throws {
        let path = try scratch("")
        _ = try AliasWriter.apply(.upsert(name: "old", command: "echo hi", comment: nil),
                                  path: path, allEntries: [])
        _ = try AliasWriter.apply(.rename(from: "old", to: "new", command: "echo hi"),
                                  path: path, allEntries: [])

        let after = try read(path)
        XCTAssertFalse(after.contains("alias old="))
        XCTAssertTrue(after.contains("alias new='echo hi'"))
    }

    func testAnAliasDefinedOutsideTheBlockIsNeverRewritten() throws {
        let path = try scratch("alias gst='someone elses definition'\n")
        let outside = ShellEntry(kind: .alias, name: "gst", command: "someone elses definition",
                                 comment: nil, sourceFile: path, line: 1, managed: false)

        XCTAssertThrowsError(
            try AliasWriter.apply(.upsert(name: "gst", command: "git status", comment: nil),
                                  path: path, allEntries: [outside])
        ) { error in
            guard case AliasWriter.WriteError.definedOutsideBlock = error else {
                return XCTFail("expected definedOutsideBlock, got \(error)")
            }
        }
        XCTAssertEqual(try read(path), "alias gst='someone elses definition'\n",
                       "a refused write must change nothing")
    }

    func testAWriteToASymlinkLandsOnTheRealFile() throws {
        // Plenty of people symlink ~/.zshrc into a dotfiles repo. Renaming a temp file
        // over the link would replace the link with a regular file and quietly detach
        // the config from version control.
        let real = try scratch("alias tracked='echo yes'\n", name: "real")
        let link = sandbox.appendingPathComponent("link-zshrc").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        _ = try AliasWriter.apply(.upsert(name: "viaLink", command: "echo linked", comment: nil),
                                  path: link, allEntries: [])

        var isLink = stat()
        XCTAssertEqual(lstat(link, &isLink), 0)
        XCTAssertEqual(isLink.st_mode & S_IFMT, S_IFLNK, "the symlink itself must survive")
        XCTAssertTrue(try read(real).contains("alias viaLink='echo linked'"))
        XCTAssertTrue(try read(real).contains("alias tracked='echo yes'"))
    }

    func testMalformedMarkersAreRefusedRatherThanGuessedAt() throws {
        let path = try scratch("""
        \(ManagedBlock.begin)
        alias a='1'
        \(ManagedBlock.begin)
        alias b='2'
        \(ManagedBlock.end)
        """)
        let before = try read(path)

        XCTAssertThrowsError(
            try AliasWriter.apply(.upsert(name: "c", command: "echo c", comment: nil),
                                  path: path, allEntries: [])
        )
        XCTAssertEqual(try read(path), before, "a refused write must change nothing")
    }

    func testWhatTheWriterEmitsIsWhatItReadsBack() throws {
        let path = try scratch("")
        let commands = [
            "gst": "git status",
            "quoted": "echo it's \"fine\" && ls | grep x",
            "piped": "git log --oneline | head -20",
        ]
        for (name, command) in commands {
            _ = try AliasWriter.apply(.upsert(name: name, command: command, comment: nil),
                                      path: path, allEntries: [])
        }

        // Two readers, two jobs. The parser strips one layer of quotes and leaves the
        // '\'' escaping in place, so it is asked only what it is for — which names exist
        // and whether they sit inside the managed block. Recovering the exact command is
        // the writer's own reader's job.
        let entries = ZshrcParser.parse(path: path).entries
        let recovered = try AliasWriter.managedAliases(
            in: read(path).components(separatedBy: "\n"))

        for (name, command) in commands {
            XCTAssertEqual(entries.first(where: { $0.name == name })?.managed, true,
                           "\(name) should be inside the managed block")
            XCTAssertEqual(recovered.first(where: { $0.name == name })?.command, command,
                           "\(name) did not survive the round-trip")
        }
    }
}
