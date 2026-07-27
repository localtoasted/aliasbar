import Foundation

/// Pure, bounded secret-shape detection for text that may cross a persistence boundary.
///
/// A match means "quarantine this content", not "this credential is valid". The API
/// deliberately returns only a stable reason: it never stores or echoes matched bytes.
enum SensitiveContentClassifier {
    enum QuarantineReason: String, CaseIterable, Equatable, Sendable, CustomStringConvertible {
        /// Set by the capture layer, never by `quarantineReason(in:)` itself: the
        /// pasteboard declared `org.nspasteboard.ConcealedType` before any text was
        /// inspected. Lives here so every quarantine reason — text-shaped or not —
        /// shares one type.
        case concealedPasteboardType = "concealed-pasteboard-type"
        case oversizedContent = "oversized-content"
        case privateKey = "private-key"
        case awsAccessKeyID = "aws-access-key-id"
        case awsSecretAccessKey = "aws-secret-access-key"
        case githubToken = "github-token"
        case gitlabToken = "gitlab-token"
        case slackToken = "slack-token"
        case anthropicAPIKey = "anthropic-api-key"
        case openAIAPIKey = "openai-api-key"
        case stripeSecretKey = "stripe-secret-key"
        case googleAPIKey = "google-api-key"
        case environmentSecret = "environment-secret"
        case databaseCredentialURL = "database-credential-url"
        case signedJWT = "signed-jwt"
        case highEntropyString = "high-entropy-string"

        var description: String {
            switch self {
            case .concealedPasteboardType:
                return "Copied from a concealed field (e.g. a password manager)"
            case .oversizedContent:
                return "Content exceeds the offline inspection limit"
            case .privateKey:
                return "Private-key material"
            case .awsAccessKeyID:
                return "AWS access key ID"
            case .awsSecretAccessKey:
                return "AWS secret access key"
            case .githubToken:
                return "GitHub authentication token"
            case .gitlabToken:
                return "GitLab authentication token"
            case .slackToken:
                return "Slack authentication token"
            case .anthropicAPIKey:
                return "Anthropic API key"
            case .openAIAPIKey:
                return "OpenAI API key"
            case .stripeSecretKey:
                return "Stripe secret key"
            case .googleAPIKey:
                return "Google API key"
            case .environmentSecret:
                return "Secret-shaped environment assignment"
            case .databaseCredentialURL:
                return "Database URL containing credentials"
            case .signedJWT:
                return "Signed JSON Web Token"
            case .highEntropyString:
                return "High-entropy credential-shaped string"
            }
        }
    }

    /// Reviewable policy bounds. Vendor prefixes come from their first-party docs;
    /// body-length and entropy floors are deliberately local quarantine policy.
    enum Thresholds {
        static let maximumInputBytes = 1_048_576
        static let minimumVendorTokenBodyBytes = 16
        static let maximumVendorTokenBytes = 512
        static let maximumStructuredCandidateBytes = 4_096
        static let minimumEnvironmentSecretBytes = 8
        static let minimumJWTSignatureBytes = 16
        static let minimumHighEntropyBytes = 48
        static let maximumEntropyCandidateBytes = 512
        static let minimumHighEntropyBitsPerByte = 4.5
        static let minimumHighEntropyCharacterClasses = 3
        static let minimumHexEntropyBytes = 64
        static let minimumHexEntropyBitsPerByte = 3.5
        static let minimumHexUniqueBytes = 12
    }

    /// Returns the first stable quarantine reason in a fixed, documented priority order.
    static func quarantineReason(in content: String) -> QuarantineReason? {
        let inspected = content.utf8.prefix(Thresholds.maximumInputBytes + 1)
        guard inspected.count <= Thresholds.maximumInputBytes else {
            return .oversizedContent
        }

        let bytes = Array(inspected)
        if containsPrivateKeyBoundary(bytes) {
            return .privateKey
        }
        if containsAWSAccessKeyID(bytes) {
            return .awsAccessKeyID
        }
        if containsPrefixedToken(bytes, prefixes: githubPrefixes) {
            return .githubToken
        }
        if containsPrefixedToken(bytes, prefixes: gitlabPrefixes) {
            return .gitlabToken
        }
        if containsPrefixedToken(bytes, prefixes: slackPrefixes) {
            return .slackToken
        }
        // Anthropic before OpenAI, and not reorderable: `sk-ant-` is also a valid `sk-`
        // match, so the more specific vendor has to be asked first or every Anthropic key
        // reports as an OpenAI one.
        if containsPrefixedToken(bytes, prefixes: anthropicPrefixes) {
            return .anthropicAPIKey
        }
        if containsPrefixedToken(bytes, prefixes: openAIPrefixes) {
            return .openAIAPIKey
        }
        if containsPrefixedToken(bytes, prefixes: stripePrefixes) {
            return .stripeSecretKey
        }
        if containsGoogleAPIKey(bytes) {
            return .googleAPIKey
        }
        if containsCredentialDatabaseURL(bytes) {
            return .databaseCredentialURL
        }
        if containsSignedJWT(bytes) {
            return .signedJWT
        }
        if let reason = assignmentReason(in: content) {
            return reason
        }
        if containsHighEntropyCandidate(bytes) {
            return .highEntropyString
        }
        return nil
    }

    // MARK: - Provider prefixes

    private static let githubPrefixes = [
        "github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
    ].map { Array($0.utf8) }

    private static let gitlabPrefixes = [
        "_gitlab_session=", "glagent-", "glffct-", "glsoat-", "glrtr-",
        "glpat-", "gloas-", "gldt-", "glrt-", "glcbt-", "glptt-", "glft-",
        "glimt-", "glwt-",
    ].map { Array($0.utf8) }

    private static let slackPrefixes = [
        "xoxe.xoxb-", "xoxe.xoxp-", "xoxb-", "xoxp-", "xwfp-", "xapp-", "xoxe-",
    ].map { Array($0.utf8) }

    private static let anthropicPrefixes = [
        "sk-ant-",
    ].map { Array($0.utf8) }

    /// Covers the project-scoped `sk-proj-` form too: the body scan runs past the extra
    /// segment, so one prefix is enough and stays right if OpenAI adds another segment.
    private static let openAIPrefixes = [
        "sk-",
    ].map { Array($0.utf8) }

    /// Live secret and restricted keys only. Test keys (`sk_test_`, `rk_test_`) are
    /// published in Stripe's own docs and pasted around deliberately — quarantining them
    /// would train the user to ignore quarantine.
    private static let stripePrefixes = [
        "sk_live_", "rk_live_",
    ].map { Array($0.utf8) }

    /// Google API keys are fixed-width: `AIza` plus 35 URL-safe base64 characters.
    /// Length is the whole signal — the body is not distinctive enough on its own, and at
    /// 39 bytes it also falls under the generic entropy floor.
    private static func containsGoogleAPIKey(_ bytes: [UInt8]) -> Bool {
        let prefix = Array("AIza".utf8)
        let total = 39
        var index = 0
        while index + total <= bytes.count {
            guard matches(bytes, at: index, prefix: prefix) else {
                index += 1
                continue
            }

            let end = index + total
            let body = bytes[(index + prefix.count)..<end]
            if body.allSatisfy(isBase64URLByte),
               hasTokenBoundary(bytes, before: index, after: end),
               // `-` and `_` are body characters but not identifier bytes, so the
               // boundary check alone would accept a longer key truncated at 39.
               end == bytes.count || !isBase64URLByte(bytes[end]) {
                return true
            }
            index += 1
        }
        return false
    }

    private static func containsAWSAccessKeyID(_ bytes: [UInt8]) -> Bool {
        for prefix in [Array("AKIA".utf8), Array("ASIA".utf8)] {
            var index = 0
            while index + 20 <= bytes.count {
                guard matches(bytes, at: index, prefix: prefix) else {
                    index += 1
                    continue
                }

                let end = index + 20
                let body = bytes[(index + prefix.count)..<end]
                if body.allSatisfy(isUppercaseLetterOrDigit),
                   hasTokenBoundary(bytes, before: index, after: end) {
                    return true
                }
                index += 1
            }
        }
        return false
    }

    private static func containsPrefixedToken(
        _ bytes: [UInt8],
        prefixes: [[UInt8]]
    ) -> Bool {
        for prefix in prefixes {
            var index = 0
            while index + prefix.count <= bytes.count {
                guard matches(bytes, at: index, prefix: prefix),
                      index == 0 || !isIdentifierByte(bytes[index - 1]) else {
                    index += 1
                    continue
                }

                var end = index + prefix.count
                while end < bytes.count,
                      end - index < Thresholds.maximumVendorTokenBytes,
                      isVendorTokenByte(bytes[end]) {
                    end += 1
                }

                let bodyCount = end - index - prefix.count
                let overLimit = end < bytes.count && isVendorTokenByte(bytes[end])
                if bodyCount >= Thresholds.minimumVendorTokenBodyBytes, !overLimit {
                    return true
                }
                index += 1
            }
        }
        return false
    }

    // MARK: - Private keys

    private static let privateKeySuffix = Array("PRIVATE KEY".utf8)
    private static let pgpPrivateKeyLabel = Array("PGP PRIVATE KEY BLOCK".utf8)
    private static let pemBoundarySuffix = Array("-----".utf8)

    private static func containsPrivateKeyBoundary(_ bytes: [UInt8]) -> Bool {
        let begin = Array("-----BEGIN ".utf8)
        var index = 0

        while index + begin.count < bytes.count {
            guard matches(bytes, at: index, prefix: begin) else {
                index += 1
                continue
            }

            let labelStart = index + begin.count
            var labelEnd = labelStart
            while labelEnd < bytes.count, labelEnd - labelStart <= 64 {
                if matches(bytes, at: labelEnd, prefix: pemBoundarySuffix) {
                    break
                }
                guard isPEMLabelByte(bytes[labelEnd]) else { break }
                labelEnd += 1
            }

            let label = bytes[labelStart..<labelEnd]
            if matches(bytes, at: labelEnd, prefix: pemBoundarySuffix),
               (label.elementsEqual(pgpPrivateKeyLabel)
                   || (label.count >= privateKeySuffix.count
                       && label.suffix(privateKeySuffix.count)
                           .elementsEqual(privateKeySuffix))) {
                return true
            }
            index += 1
        }
        return false
    }

    // MARK: - Secret-shaped assignments

    private static let secretNameSuffixes = [
        "PASSWORD", "PASSWD", "PASSPHRASE", "SECRET", "TOKEN", "API_KEY",
        "APIKEY", "ACCESS_KEY", "SECRET_ACCESS_KEY", "PRIVATE_KEY",
        "CLIENT_SECRET", "CLIENT_KEY", "AUTH_TOKEN", "BEARER_TOKEN",
    ]

    private static let placeholderValues: Set<String> = [
        "changeme", "dummy", "example", "none", "null", "placeholder",
        "replaceme", "secret", "test", "todo", "yourkeyhere", "yourtokenhere",
        "yourpasswordhere",
    ]

    private static func assignmentReason(in content: String) -> QuarantineReason? {
        for rawLine in content.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export") {
                let remainder = line.dropFirst("export".count)
                if let first = remainder.first, first == " " || first == "\t" {
                    line = String(remainder.drop {
                        $0 == " " || $0 == "\t"
                    })
                }
            }

            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<separator])
                .trimmingCharacters(in: .whitespaces)
            guard isEnvironmentName(name) else { continue }

            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" || first == "'"),
               first == last {
                value.removeFirst()
                value.removeLast()
            }

            guard !value.isEmpty, !isPlaceholder(value) else { continue }
            let upperName = name.uppercased()
            let valueBytes = Array(value.utf8)

            if upperName == "AWS_ACCESS_KEY_ID",
               valueBytes.count == 20,
               containsAWSAccessKeyID(valueBytes) {
                return .awsAccessKeyID
            }
            if upperName == "AWS_SECRET_ACCESS_KEY",
               valueBytes.count == 40,
               valueBytes.allSatisfy(isBase64Byte) {
                return .awsSecretAccessKey
            }
            if isSecretEnvironmentName(upperName),
               valueBytes.count >= Thresholds.minimumEnvironmentSecretBytes {
                return .environmentSecret
            }
        }
        return nil
    }

    private static func isEnvironmentName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, isASCIILetter(first) || first == 95 else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            isASCIILetter($0) || isDigit($0) || $0 == 95
        }
    }

    private static func isSecretEnvironmentName(_ upperName: String) -> Bool {
        secretNameSuffixes.contains {
            upperName == $0 || upperName.hasSuffix("_\($0)")
        }
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("${") && trimmed.hasSuffix("}") {
            return isEnvironmentName(String(trimmed.dropFirst(2).dropLast()))
        }
        if trimmed.hasPrefix("$"),
           isEnvironmentName(String(trimmed.dropFirst())) {
            return true
        }
        let normalized = trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
        return placeholderValues.contains(normalized)
    }

    // MARK: - Credential-bearing database URLs

    private static let databaseSchemes = [
        ("postgresql", Array("postgresql://".utf8)),
        ("postgres", Array("postgres://".utf8)),
        ("mysqlx", Array("mysqlx://".utf8)),
        ("mysql", Array("mysql://".utf8)),
    ]

    private static func containsCredentialDatabaseURL(_ bytes: [UInt8]) -> Bool {
        for (scheme, prefix) in databaseSchemes {
            var index = 0
            while index + prefix.count <= bytes.count {
                guard matchesASCIICaseInsensitive(bytes, at: index, prefix: prefix),
                      index == 0 || !isIdentifierByte(bytes[index - 1]) else {
                    index += 1
                    continue
                }

                var end = index + prefix.count
                while end < bytes.count,
                      end - index <= Thresholds.maximumStructuredCandidateBytes,
                      !isURLTerminator(bytes[end]) {
                    end += 1
                }
                guard end - index <= Thresholds.maximumStructuredCandidateBytes else {
                    index += 1
                    continue
                }

                let candidate = String(decoding: bytes[index..<end], as: UTF8.self)
                if let components = URLComponents(string: candidate),
                   components.scheme?.lowercased() == scheme,
                   let host = components.host, !host.isEmpty {
                    let hasUserInfoPassword =
                        !(components.user ?? "").isEmpty
                        && !(components.password ?? "").isEmpty
                    let hasPasswordParameter = components.queryItems?.contains {
                        ["password", "passwd", "pwd"].contains($0.name.lowercased())
                            && !($0.value ?? "").isEmpty
                    } ?? false
                    if hasUserInfoPassword || hasPasswordParameter {
                        return true
                    }
                }
                index += 1
            }
        }
        return false
    }

    // MARK: - Signed JWTs

    private static func containsSignedJWT(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            guard isJWTByte(bytes[index]) else {
                index += 1
                continue
            }

            let start = index
            while index < bytes.count, isJWTByte(bytes[index]) {
                index += 1
            }
            let candidate = bytes[start..<index]
            if candidate.count <= Thresholds.maximumStructuredCandidateBytes,
               isStructurallySignedJWT(candidate) {
                return true
            }
        }
        return false
    }

    private static func isStructurallySignedJWT(_ candidate: ArraySlice<UInt8>) -> Bool {
        let parts = candidate.split(separator: 46, omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty }),
              let headerData = decodeBase64URL(parts[0]),
              let claimsData = decodeBase64URL(parts[1]),
              let signatureData = decodeBase64URL(parts[2]),
              signatureData.count >= Thresholds.minimumJWTSignatureBytes,
              let header = try? JSONSerialization.jsonObject(with: headerData),
              let headerObject = header as? [String: Any],
              let algorithm = headerObject["alg"] as? String,
              !algorithm.isEmpty,
              algorithm.caseInsensitiveCompare("none") != .orderedSame,
              let claims = try? JSONSerialization.jsonObject(with: claimsData),
              claims is [String: Any] else {
            return false
        }
        return true
    }

    private static func decodeBase64URL(_ bytes: ArraySlice<UInt8>) -> Data? {
        guard !bytes.isEmpty,
              bytes.allSatisfy(isBase64URLByte),
              bytes.count % 4 != 1 else {
            return nil
        }

        var encoded = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: encoded)
    }

    // MARK: - Generic high entropy

    private static func containsHighEntropyCandidate(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            guard isEntropyCandidateByte(bytes[index]) else {
                index += 1
                continue
            }

            let start = index
            while index < bytes.count, isEntropyCandidateByte(bytes[index]) {
                index += 1
            }
            let end = index
            guard end - start >= Thresholds.minimumHighEntropyBytes else { continue }

            let step = Thresholds.maximumEntropyCandidateBytes
                - Thresholds.minimumHighEntropyBytes + 1
            var windowStart = start
            while windowStart < end {
                let windowEnd = min(
                    windowStart + Thresholds.maximumEntropyCandidateBytes,
                    end
                )
                let candidate = bytes[windowStart..<windowEnd]
                if isHighEntropy(candidate) || isHighEntropyHex(candidate) {
                    return true
                }
                if windowEnd == end { break }
                windowStart += step
            }
        }
        return false
    }

    private static func isHighEntropy(_ candidate: ArraySlice<UInt8>) -> Bool {
        guard candidate.count >= Thresholds.minimumHighEntropyBytes else {
            return false
        }

        var classes = 0
        if candidate.contains(where: isUppercaseLetter) { classes += 1 }
        if candidate.contains(where: isLowercaseLetter) { classes += 1 }
        if candidate.contains(where: isDigit) { classes += 1 }
        if candidate.contains(where: isEntropySymbol) { classes += 1 }
        guard classes >= Thresholds.minimumHighEntropyCharacterClasses else {
            return false
        }
        return shannonEntropy(candidate) >= Thresholds.minimumHighEntropyBitsPerByte
    }

    private static func isHighEntropyHex(_ candidate: ArraySlice<UInt8>) -> Bool {
        guard candidate.count >= Thresholds.minimumHexEntropyBytes,
              candidate.allSatisfy(isHexByte),
              Set(candidate).count >= Thresholds.minimumHexUniqueBytes else {
            return false
        }
        return shannonEntropy(candidate) >= Thresholds.minimumHexEntropyBitsPerByte
    }

    private static func shannonEntropy(_ bytes: ArraySlice<UInt8>) -> Double {
        var counts = [Int](repeating: 0, count: 128)
        for byte in bytes {
            counts[Int(byte)] += 1
        }

        let total = Double(bytes.count)
        return counts.reduce(0.0) { entropy, count in
            guard count > 0 else { return entropy }
            let probability = Double(count) / total
            return entropy - probability * log2(probability)
        }
    }

    // MARK: - ASCII helpers

    private static func matches(
        _ bytes: [UInt8],
        at index: Int,
        prefix: [UInt8]
    ) -> Bool {
        guard index >= 0, index + prefix.count <= bytes.count else { return false }
        return bytes[index..<(index + prefix.count)].elementsEqual(prefix)
    }

    private static func matchesASCIICaseInsensitive(
        _ bytes: [UInt8],
        at index: Int,
        prefix: [UInt8]
    ) -> Bool {
        guard index >= 0, index + prefix.count <= bytes.count else { return false }
        for offset in prefix.indices {
            let candidate = bytes[index + offset]
            let expected = prefix[offset]
            if candidate == expected { continue }
            guard isASCIILetter(candidate),
                  candidate | 32 == expected | 32 else {
                return false
            }
        }
        return true
    }

    private static func hasTokenBoundary(
        _ bytes: [UInt8],
        before start: Int,
        after end: Int
    ) -> Bool {
        (start == 0 || !isIdentifierByte(bytes[start - 1]))
            && (end == bytes.count || !isIdentifierByte(bytes[end]))
    }

    private static func isURLTerminator(_ byte: UInt8) -> Bool {
        byte <= 32 || [34, 39, 40, 41, 44, 59, 60, 62, 91, 93, 123, 125].contains(byte)
    }

    private static func isPEMLabelByte(_ byte: UInt8) -> Bool {
        isUppercaseLetter(byte) || isDigit(byte) || byte == 32 || byte == 45
    }

    private static func isVendorTokenByte(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || isDigit(byte) || [45, 46, 95].contains(byte)
    }

    private static func isJWTByte(_ byte: UInt8) -> Bool {
        isBase64URLByte(byte) || byte == 46
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || isDigit(byte) || byte == 45 || byte == 95
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || isDigit(byte) || [43, 47, 61].contains(byte)
    }

    private static func isEntropyCandidateByte(_ byte: UInt8) -> Bool {
        isBase64Byte(byte) || byte == 45 || byte == 95
    }

    private static func isEntropySymbol(_ byte: UInt8) -> Bool {
        [43, 45, 47, 61, 95].contains(byte)
    }

    private static func isHexByte(_ byte: UInt8) -> Bool {
        isDigit(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || isDigit(byte) || byte == 95
    }

    private static func isUppercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        isUppercaseLetter(byte) || isDigit(byte)
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        isUppercaseLetter(byte) || isLowercaseLetter(byte)
    }

    private static func isUppercaseLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte)
    }

    private static func isLowercaseLetter(_ byte: UInt8) -> Bool {
        (97...122).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}
