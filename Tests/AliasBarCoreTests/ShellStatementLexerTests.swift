import XCTest

@testable import AliasBarCore

/// Direct assertions on the state `ShellStatementLexer.scan` carries across lines.
///
/// Everything else in the repo exercises this lexer end to end: a file goes in, a file
/// comes out, and a wrong continuation verdict shows up as a distant byte mismatch in a
/// whole-file diff — if it shows up at all, since `guardSyntax` and `guardCollateral`
/// convert most lexer mistakes into a refusal rather than a wrong file. That makes the
/// existing suites excellent at proving nothing gets corrupted and useless at saying
/// which branch of the lexer moved.
///
/// These tests read the returned `LexState` fields instead. They assert on named
/// properties only — never on the text of any source file — so they survive renames and
/// reformatting and fail exactly where the behavior changed.
final class ShellStatementLexerTests: XCTestCase {
    /// One physical line, from a fresh statement unless a state is handed in.
    private func s(_ line: String,
                   from state: ShellStatementLexer.LexState = ShellStatementLexer.LexState())
        -> ShellStatementLexer.LexState {
        ShellStatementLexer.scan(line, from: state)
    }

    /// A whole statement, one line at a time, as `rangeOfAlias` walks it.
    private func s(lines: [String]) -> ShellStatementLexer.LexState {
        var state = ShellStatementLexer.LexState()
        for line in lines { state = ShellStatementLexer.scan(line, from: state) }
        return state
    }

    // MARK: Continuation — the verdict that decides how many lines an edit spans

    func testACompleteSingleLineStatementDoesNotContinue() {
        for line in [
            "alias a='echo one'",
            "alias a=\"echo one\"",
            "alias a=echo",
            "alias a='echo one' # trailing comment",
            "",
            "# just a comment",
        ] {
            XCTAssertFalse(s(line).continues, "\(line) is a finished statement")
        }
    }

    func testAnUnterminatedSingleQuoteContinues() {
        let state = s("alias a='echo one")
        XCTAssertTrue(state.continues)
        XCTAssertFalse(state.hasUnconsumedHeredoc)
    }

    func testAnUnterminatedDoubleQuoteContinues() {
        XCTAssertTrue(s("alias a=\"echo one").continues)
    }

    func testAClosingQuoteOnALaterLineEndsTheStatement() {
        XCTAssertFalse(s(lines: ["alias a='echo one", "two'"]).continues)
    }

    func testATrailingBackslashContinues() {
        XCTAssertTrue(s(#"alias a=x \"#).continues)
    }

    func testABackslashInsideACommentDoesNotContinue() {
        // The backslash sits inside a comment, where it is inert — and the root `;`
        // already ended the alias command. Reading this as a continuation is the
        // over-deletion route that took the next alias with it.
        XCTAssertFalse(s(#"alias a=x;# c \"#).continues)
    }

    func testABackslashAfterACommentWithNoRootSeparatorStillDoesNotContinue() {
        XCTAssertFalse(s(#"alias a='x' # c \"#).continues)
    }

    func testARootSeparatorEndsTheStatementEvenWithSyntaxAfterIt() {
        // Once `;` has ended the alias command, later text on the same physical line
        // must not extend the removal span.
        XCTAssertFalse(s("alias a=x; echo two").continues)
        XCTAssertFalse(s("alias a=x | grep two").continues)
        XCTAssertFalse(s("alias a=x && echo two").continues)
    }

    func testAnEscapedQuoteDoesNotOpenAString() {
        XCTAssertFalse(s(#"alias a=\'"#).continues)
    }

    func testABackslashInsideSingleQuotesIsLiteralSoTheNextQuoteCloses() {
        // In single quotes a backslash is just a backslash: the apostrophe right
        // after it closes the string rather than being escaped.
        XCTAssertFalse(s(#"alias a='x\'"#).continues)
    }

    // MARK: Frames — nesting kind and depth

    func testCommandSubstitutionPushesACommandFrame() {
        let state = s("alias a=$(f")
        XCTAssertEqual(state.frames.count, 2)
        XCTAssertEqual(state.frames.last?.kind, .command)
        XCTAssertEqual(state.frames.last?.delimiterDepth, 1)
        XCTAssertTrue(state.continues)
    }

    func testArithmeticSubstitutionPushesOneFrameAtDepthTwo() {
        let state = s("alias a=$((1+")
        XCTAssertEqual(state.frames.count, 2)
        XCTAssertEqual(state.frames.last?.kind, .arithmetic)
        XCTAssertEqual(state.frames.last?.delimiterDepth, 2)
    }

    func testParameterExpansionPushesAParameterFrame() {
        let state = s("alias a=${x")
        XCTAssertEqual(state.frames.count, 2)
        XCTAssertEqual(state.frames.last?.kind, .parameter)
        XCTAssertEqual(state.frames.last?.delimiterDepth, 1)
    }

    func testProcessSubstitutionPushesAProcessFrameInBothDirections() {
        for line in ["alias a=cat <(f", "alias a=tee >(f"] {
            let state = s(line)
            XCTAssertEqual(state.frames.count, 2, line)
            XCTAssertEqual(state.frames.last?.kind, .process, line)
            XCTAssertEqual(state.frames.last?.delimiterDepth, 1, line)
        }
    }

    func testABacktickPushesABacktickFrameAndItsPartnerPopsIt() {
        let open = s("alias a=`f")
        XCTAssertEqual(open.frames.count, 2)
        XCTAssertEqual(open.frames.last?.kind, .backtick)
        XCTAssertTrue(open.continues)

        let closed = s("alias a=`f`")
        XCTAssertEqual(closed.frames.count, 1)
        XCTAssertFalse(closed.continues)
    }

    func testProcessSubstitutionIsNotSyntaxInsideDoubleQuotes() {
        // `<(` is only process substitution in an unquoted command context. Inside a
        // double-quoted string it is two ordinary characters.
        let state = s("alias a=\"cat <(f\"")
        XCTAssertEqual(state.frames.count, 1)
        XCTAssertFalse(state.continues)
    }

    func testAnInnerParenDoesNotCloseAnArithmeticFrameEarly() {
        // `$(( (1+2) ` — the inner pair adjusts the same count, so the frame is still
        // open at end of line.
        let state = s("alias a=$(( (1+2)")
        XCTAssertEqual(state.frames.count, 2)
        XCTAssertEqual(state.frames.last?.kind, .arithmetic)
        XCTAssertEqual(state.frames.last?.delimiterDepth, 2)
        XCTAssertTrue(state.continues)
    }

    func testAnInnerBraceDoesNotCloseAParameterFrameEarly() {
        let state = s("alias a=${x:-${y}")
        XCTAssertEqual(state.frames.count, 2)
        XCTAssertEqual(state.frames.last?.kind, .parameter)
        XCTAssertEqual(state.frames.last?.delimiterDepth, 1)
        XCTAssertTrue(state.continues)
    }

    func testABalancedArithmeticExpressionPopsBackToRoot() {
        let state = s("alias a=$((1+2))")
        XCTAssertEqual(state.frames.count, 1)
        XCTAssertFalse(state.continues)
    }

    func testABalancedParameterExpansionPopsBackToRoot() {
        XCTAssertEqual(s("alias a=${x:-y}").frames.count, 1)
        XCTAssertFalse(s("alias a=${x:-y}").continues)
    }

    func testQuotesInsideASubstitutionDoNotCloseQuotesOutsideIt() {
        // Each frame owns its own quote state.
        let state = s("alias a=$(echo 'inner'")
        XCTAssertEqual(state.frames.count, 2)
        XCTAssertEqual(state.frames.last?.quote, .unquoted)
        XCTAssertEqual(state.frames.first?.quote, .unquoted)
        XCTAssertTrue(state.continues)
    }

    func testAnUnterminatedQuoteInsideASubstitutionIsCarriedOnItsOwnFrame() {
        let state = s("alias a=$(echo 'inner")
        XCTAssertEqual(state.frames.count, 2)
        XCTAssertEqual(state.frames.last?.quote, .single)
        XCTAssertEqual(state.frames.first?.quote, .unquoted)
    }

    func testACommentInsideASubstitutionEndsTheLineButNotTheSubstitution() {
        let state = s(lines: ["alias a=$(echo one # note", "two)"])
        XCTAssertEqual(state.frames.count, 1)
        XCTAssertFalse(state.continues)
    }

    func testAHashIsNotACommentInArithmeticOrParameterContexts() {
        // `16#ff` is a radix, and `${#x}` is a length operator. Treating either as a
        // comment would end the line early and truncate the span.
        XCTAssertEqual(s("alias a=$((16#ff").frames.last?.kind, .arithmetic)
        XCTAssertTrue(s("alias a=$((16#ff").continues)
        XCTAssertFalse(s("alias a=$((16#ff))").continues)
        XCTAssertFalse(s("alias a=${#x}").continues)
    }

    func testAHashMidWordIsNotACommentAtRoot() {
        // A `#` only starts a comment at a word boundary.
        XCTAssertFalse(s("alias a=x#y").continues)
        XCTAssertEqual(s("alias a=x#y").frames.count, 1)
    }

    // MARK: Heredocs — the accounting that must never balance by accident

    func testAHeredocOperatorRecordsOneUnresolvedHeredoc() {
        let state = s("alias a=cat <<EOF")
        XCTAssertEqual(state.unresolvedHeredocs, 1)
        XCTAssertTrue(state.hasUnconsumedHeredoc)
        XCTAssertTrue(state.continues)
        XCTAssertEqual(state.frames.last?.activeHeredoc?.delimiter, "EOF")
        XCTAssertFalse(state.unsupportedHeredocDelimiter)
    }

    func testTheTerminatorLineClearsTheActiveHeredocAndDecrementsTheCount() {
        let state = s(lines: ["alias a=cat <<EOF", "payload", "EOF"])
        XCTAssertEqual(state.unresolvedHeredocs, 0)
        XCTAssertNil(state.frames.last?.activeHeredoc)
        XCTAssertFalse(state.hasUnconsumedHeredoc)
        XCTAssertFalse(state.continues)
    }

    func testAnAlmostMatchingTerminatorDoesNotCloseTheHeredoc() {
        let state = s(lines: ["alias a=cat <<EOF", "EOFX", "  EOF"])
        XCTAssertEqual(state.unresolvedHeredocs, 1)
        XCTAssertTrue(state.hasUnconsumedHeredoc)
        XCTAssertTrue(state.continues)
    }

    func testADashHeredocStripsLeadingTabsFromTheTerminator() {
        let stripped = s(lines: ["alias a=cat <<-EOF", "payload", "\t\tEOF"])
        XCTAssertEqual(stripped.unresolvedHeredocs, 0)
        XCTAssertFalse(stripped.continues)

        // Without the dash the same tabbed terminator does not match.
        let notStripped = s(lines: ["alias a=cat <<EOF", "payload", "\tEOF"])
        XCTAssertEqual(notStripped.unresolvedHeredocs, 1)
        XCTAssertTrue(notStripped.continues)
    }

    func testAQuotedDelimiterHasItsQuotesRemoved() {
        for opener in ["'EOF'", "\"EOF\""] {
            let state = s(lines: ["alias a=cat <<\(opener)", "payload", "EOF"])
            XCTAssertEqual(state.unresolvedHeredocs, 0, opener)
            XCTAssertFalse(state.continues, opener)
        }
    }

    func testTwoHeredocsOnOneLineAreBothAccountedFor() {
        let opened = s("alias a=cat <<ONE <<TWO")
        XCTAssertEqual(opened.unresolvedHeredocs, 2)
        XCTAssertEqual(opened.frames.last?.activeHeredoc?.delimiter, "ONE")
        XCTAssertEqual(opened.frames.last?.pendingHeredocs.count, 1)

        let half = s(lines: ["alias a=cat <<ONE <<TWO", "ONE"])
        XCTAssertEqual(half.unresolvedHeredocs, 1)
        XCTAssertEqual(half.frames.last?.activeHeredoc?.delimiter, "TWO")
        XCTAssertTrue(half.continues)

        let whole = s(lines: ["alias a=cat <<ONE <<TWO", "ONE", "TWO"])
        XCTAssertEqual(whole.unresolvedHeredocs, 0)
        XCTAssertFalse(whole.continues)
    }

    func testHeredocsSurviveARootSeparatorOnTheSameLine() {
        // The shell reads heredoc bodies after the newline, so a `;` before the
        // operator must not let the span end while payload is still outstanding.
        let state = s("alias a=x; cat <<EOF")
        XCTAssertEqual(state.unresolvedHeredocs, 1)
        XCTAssertTrue(state.continues, "outstanding payload has to keep the span open")
    }

    func testADollarQuotedDelimiterIsUnsupportedAndPoisonsTheSpanForever() {
        let state = s(#"alias a=cat <<$'E'"#)
        XCTAssertTrue(state.unsupportedHeredocDelimiter)
        XCTAssertTrue(state.hasUnconsumedHeredoc)
        XCTAssertEqual(state.unresolvedHeredocs, 1)

        // Never cleared: no later line, not even a plausible terminator, may make the
        // span look completable.
        let later = s(lines: [#"alias a=cat <<$'E'"#, "payload", "E"])
        XCTAssertTrue(later.unsupportedHeredocDelimiter)
        XCTAssertTrue(later.hasUnconsumedHeredoc)
        XCTAssertTrue(later.continues)
    }

    func testOtherUnsupportedDelimiterFormsAreAlsoRefused() {
        for line in [
            #"alias a=cat <<`E`"#,      // backtick: identity depends on execution
            #"alias a=cat <<$(E)"#,     // command substitution as the delimiter word
            #"alias a=cat <<${E}"#,     // parameter expansion as the delimiter word
            #"alias a=cat <<E(F)"#,     // parentheses are not a safe word boundary
            #"alias a=cat <<'E"#,       // quote still open at the newline
            "alias a=cat <<",           // no delimiter word at all
            #"alias a=cat <<E\"#,       // backslash continues the word onto the next line
        ] {
            XCTAssertTrue(s(line).unsupportedHeredocDelimiter, line)
            XCTAssertTrue(s(line).hasUnconsumedHeredoc, line)
        }
    }

    func testAHereStringIsNotAHeredoc() {
        for line in ["alias a=cat <<<'x'", "alias a=cat <<<word", "alias a=cat <<<\"x\""] {
            let state = s(line)
            XCTAssertFalse(state.hasUnconsumedHeredoc, line)
            XCTAssertEqual(state.unresolvedHeredocs, 0, line)
            XCTAssertFalse(state.unsupportedHeredocDelimiter, line)
            XCTAssertFalse(state.continues, line)
        }
    }

    func testUnconsumedHeredocIsIndependentOfContinuation() {
        // `hasUnconsumedHeredoc` is the fail-safe: it is derived from the counter and
        // the frames, not from `continues`, so a lost frame cannot make outstanding
        // payload disappear from the completion test.
        var state = ShellStatementLexer.LexState()
        state.unresolvedHeredocs = 1
        XCTAssertTrue(state.hasUnconsumedHeredoc)
        XCTAssertFalse(state.continues)

        var invalid = ShellStatementLexer.LexState()
        invalid.heredocStateInvalid = true
        XCTAssertTrue(invalid.hasUnconsumedHeredoc)
    }

    func testAnUnbalancedTerminatorMarksTheHeredocStateInvalid() {
        // A terminator arriving with nothing outstanding means the accounting has
        // diverged from the file; the state says so rather than going negative.
        var state = ShellStatementLexer.LexState()
        state.frames[0].activeHeredoc = ShellStatementLexer.Heredoc(delimiter: "EOF",
                                                                    stripsTabs: false)
        let after = ShellStatementLexer.scan("EOF", from: state)
        XCTAssertTrue(after.heredocStateInvalid)
        XCTAssertTrue(after.hasUnconsumedHeredoc)
    }

    func testHeredocBodyLinesAreOpaque() {
        // Inside a heredoc body nothing is shell syntax: an unmatched quote or paren
        // in the payload must not open a frame or a string.
        let state = s(lines: ["alias a=cat <<EOF", "it's $(unbalanced '", "EOF"])
        XCTAssertEqual(state.frames.count, 1)
        XCTAssertEqual(state.frames.last?.quote, .unquoted)
        XCTAssertEqual(state.unresolvedHeredocs, 0)
        XCTAssertFalse(state.continues)
    }

    // MARK: Case arms — the reason `)` does not always close a frame

    func testCasePhaseWalksAwaitingInThenPatternThenBody() {
        let awaiting = s("alias a=$(case $x")
        XCTAssertEqual(awaiting.frames.last?.cases, [.awaitingIn])

        let pattern = s(lines: ["alias a=$(case $x in"])
        XCTAssertEqual(pattern.frames.last?.cases, [.pattern])

        let body = s(lines: ["alias a=$(case $x in", "  one)"])
        XCTAssertEqual(body.frames.last?.cases, [.body])
        XCTAssertEqual(body.frames.count, 2, "an arm's `)` must not close the substitution")

        let nextArm = s(lines: ["alias a=$(case $x in", "  one) echo one;;"])
        XCTAssertEqual(nextArm.frames.last?.cases, [.pattern])

        let done = s(lines: ["alias a=$(case $x in", "  one) echo one;;", "  esac)"])
        XCTAssertEqual(done.frames.count, 1, "esac then `)` must close the substitution")
        XCTAssertFalse(done.continues)
    }

    func testAParenthesizedCaseArmDoesNotAddDepth() {
        // zsh accepts both `word)` and `(word)`. The optional opening paren belongs to
        // the pattern grammar, not to the substitution's structural depth.
        let state = s(lines: ["alias a=$(case $x in", "  (one) echo one;;", "  esac)"])
        XCTAssertEqual(state.frames.count, 1)
        XCTAssertFalse(state.continues)
    }

    func testAnUnclosedCaseKeepsTheSubstitutionOpen() {
        let state = s(lines: ["alias a=$(case $x in", "  one) echo one;;"])
        XCTAssertEqual(state.frames.count, 2)
        XCTAssertTrue(state.continues)
    }

    func testCaseIsOnlyRecognizedAtACommandBoundary() {
        // `echo case` is an argument, not the start of a case statement.
        let state = s("alias a=$(echo case in")
        XCTAssertEqual(state.frames.last?.cases, [])
    }

    // MARK: Entering state is carried, not rebuilt

    func testScanResumesFromTheStateItWasGiven() {
        let first = s("alias a=$(echo 'inner")
        let second = ShellStatementLexer.scan("still inner", from: first)
        XCTAssertEqual(second.frames.count, 2)
        XCTAssertEqual(second.frames.last?.quote, .single)
        XCTAssertTrue(second.continues)

        let third = ShellStatementLexer.scan("done')", from: second)
        XCTAssertEqual(third.frames.count, 1)
        XCTAssertFalse(third.continues)
    }

    func testAnEmptyFrameStackIsRepairedToRoot() {
        var broken = ShellStatementLexer.LexState()
        broken.frames = []
        let state = ShellStatementLexer.scan("alias a='echo one'", from: broken)
        XCTAssertEqual(state.frames.count, 1)
        XCTAssertEqual(state.frames.first?.kind, .root)
        XCTAssertFalse(state.continues)
    }
}
