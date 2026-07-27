import XCTest

@testable import AliasBarCore

/// The classifier decides whether a copied clip is allowed to be persisted at all, so
/// its false negatives are the expensive direction. This is the representative slice;
/// the exhaustive provider table lives in Tests/WriterTests.swift.
final class SensitiveContentClassifierTests: XCTestCase {
    private func reason(_ content: String) -> SensitiveContentClassifier.QuarantineReason? {
        SensitiveContentClassifier.quarantineReason(in: content)
    }

    // Bodies long enough to trip the provider-token length floors, built here rather
    // than pasted so nothing in this file looks like a real credential.
    private let tokenBody = String(repeating: "A1b2C3d4", count: 5)

    func testOrdinaryContentIsNotQuarantined() {
        XCTAssertNil(reason("git status"))
        XCTAssertNil(reason("the quick brown fox jumps over the lazy dog"))
        XCTAssertNil(reason("こんにちは、AliasBar。これは普通のメモです。"))
        XCTAssertNil(reason(""))
    }

    func testProviderTokensAreCaught() {
        XCTAssertEqual(reason("ghp_\(tokenBody)"), .githubToken)
        XCTAssertEqual(reason("sk-ant-api03-\(tokenBody)"), .anthropicAPIKey)
        XCTAssertEqual(reason("AKIAIOSFODNN7EXAMPLE"), .awsAccessKeyID)
    }

    func testAPrivateKeyBoundaryIsCaught() {
        XCTAssertEqual(reason("-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n"), .privateKey)
    }

    func testATokenSurroundedByUnicodeCannotHide() {
        XCTAssertEqual(reason("🔐ghp_\(tokenBody)🔐"), .githubToken)
    }

    func testFullWidthLookalikesAreNotTreatedAsTokens() {
        XCTAssertNil(reason("ｇｈｐ_shortbody"))
    }

    func testACredentialBearingDatabaseURLIsCaught() {
        XCTAssertEqual(reason("postgres://admin:hunter2@db.example.com:5432/app"),
                       .databaseCredentialURL)
    }

    func testOversizedInputFailsClosed() {
        // Inspection is bounded, so anything past the bound is quarantined rather than
        // waved through unread.
        let limit = SensitiveContentClassifier.Thresholds.maximumInputBytes
        XCTAssertNil(reason(String(repeating: "a", count: limit)))
        XCTAssertEqual(reason(String(repeating: "a", count: limit + 1)), .oversizedContent)
    }

    func testATokenAtTheVeryTailOfABoundedInputIsStillFound() {
        let limit = SensitiveContentClassifier.Thresholds.maximumInputBytes
        let token = "ghp_\(tokenBody)"
        let padded = String(repeating: " ", count: limit - token.utf8.count) + token
        XCTAssertEqual(reason(padded), .githubToken)
    }
}

/// Clip badges: the detector runs on every clipboard entry, and precedence between
/// overlapping shapes (a JWT is also base64-ish, an epoch is also a number) is the
/// part worth pinning.
final class ClipKindTests: XCTestCase {
    private let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ"
        + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

    func testAJWTWinsOverBase64() {
        XCTAssertEqual(ClipKind.detect(jwt), .jwt)
    }

    func testEpochTimestampsAreBoundedByDigitCount() {
        XCTAssertEqual(ClipKind.detect("1700000000"), .epochTimestamp)
        XCTAssertEqual(ClipKind.detect("1700000000000"), .epochTimestamp)
        XCTAssertNotEqual(ClipKind.detect("17000000000"), .epochTimestamp)
    }

    func testStructuredShapesAreDetected() {
        XCTAssertEqual(ClipKind.detect(#"{"a":1}"#), .json)
        XCTAssertEqual(ClipKind.detect("[1,2,3]"), .json)
        XCTAssertEqual(ClipKind.detect("SGVsbG8gV29ybGQh"), .base64)
        XCTAssertEqual(ClipKind.detect("#4B5BC4"), .hexColor)
    }

    func testAQueryStringIsWhatMakesAURLInteresting() {
        XCTAssertEqual(ClipKind.detect("https://example.com/path?a=1&b=2"), .urlWithQuery)
        XCTAssertNotEqual(ClipKind.detect("https://example.com/path"), .urlWithQuery)
    }

    func testProseFallsThroughToPlainText() {
        XCTAssertEqual(ClipKind.detect("just a note to myself"), .plainText)
    }
}
