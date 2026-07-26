import Foundation

// MARK: - Detection

/// What a piece of clipboard text looks like, in a fixed, documented priority order.
/// Detection is heuristic by nature — the goal is "probably useful to offer a
/// transform for," not proof.
enum ClipKind: Equatable {
    case jwt
    case epochTimestamp
    case json
    case base64
    case urlWithQuery
    case hexColor
    case filePath
    case uuid
    case plainText

    /// `content` should already be trimmed of surrounding whitespace — callers decide
    /// that once rather than each detector repeating it.
    static func detect(_ content: String) -> ClipKind {
        if isJWT(content) { return .jwt }
        if isEpochTimestamp(content) { return .epochTimestamp }
        if isJSON(content) { return .json }
        if isBase64Candidate(content) { return .base64 }
        if isURLWithQuery(content) { return .urlWithQuery }
        if isHexColor(content) { return .hexColor }
        if isFilePath(content) { return .filePath }
        if isUUID(content) { return .uuid }
        return .plainText
    }

    private static func isJWT(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              let headerData = ClipTransformer.decodeBase64URL(String(parts[0])),
              let payloadData = ClipTransformer.decodeBase64URL(String(parts[1])),
              (try? JSONSerialization.jsonObject(with: headerData)) is [String: Any],
              (try? JSONSerialization.jsonObject(with: payloadData)) is [String: Any]
        else { return false }
        return true
    }

    /// Exactly 10 (seconds) or 13 (milliseconds) ASCII digits — the two epoch
    /// granularities anything copied from a log, a database row, or `date +%s`/`%s%3N`
    /// is likely to be in. A shorter or longer run of digits is left as plain text
    /// rather than guessed at.
    private static func isEpochTimestamp(_ s: String) -> Bool {
        guard s.count == 10 || s.count == 13 else { return false }
        return s.allSatisfy(\.isASCII) && s.allSatisfy { $0.isNumber }
    }

    private static func isJSON(_ s: String) -> Bool {
        guard let first = s.first, let last = s.last else { return false }
        guard (first == "{" && last == "}") || (first == "[" && last == "]") else { return false }
        guard let data = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Deliberately excludes anything starting with `/` or `~`: those are also valid
    /// base64 alphabet characters (`/` is), so an absolute or home-relative file path
    /// like `/usr/bin/xyz` would otherwise decode "successfully" as base64 garbage
    /// and pre-empt the file-path detector that runs later in this chain.
    private static func isBase64Candidate(_ s: String) -> Bool {
        guard s.count >= 8, s.count % 4 == 0 else { return false }
        guard let first = s.first, first != "/", first != "~" else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard s.allSatisfy({ allowed.contains($0) }) else { return false }
        let paddingCount = s.reversed().prefix(while: { $0 == "=" }).count
        guard paddingCount <= 2, !s.dropLast(paddingCount).contains("=") else { return false }
        return Data(base64Encoded: s) != nil
    }

    private static func isURLWithQuery(_ s: String) -> Bool {
        guard let components = URLComponents(string: s),
              let scheme = components.scheme, !scheme.isEmpty,
              let items = components.queryItems, !items.isEmpty
        else { return false }
        return true
    }

    private static func isHexColor(_ s: String) -> Bool {
        guard s.hasPrefix("#") else { return false }
        let hex = s.dropFirst()
        guard [3, 6, 8].contains(hex.count) else { return false }
        return hex.allSatisfy(\.isHexDigit)
    }

    /// No disk access — this is a shape check only. An absolute path or a
    /// `~`/`~/...` form, on one line, is treated as path-shaped. Bare `~` (length 1)
    /// is a valid case on its own, so the length floor only applies to the `/` and
    /// `~/` prefixes, where length 1 means "just a slash" — not a meaningful path.
    private static func isFilePath(_ s: String) -> Bool {
        guard !s.contains("\n"), !s.contains("\t") else { return false }
        if s == "~" { return true }
        guard s.hasPrefix("/") || s.hasPrefix("~/") else { return false }
        return s.count > 1
    }

    private static func isUUID(_ s: String) -> Bool {
        s.count == 36 && UUID(uuidString: s) != nil
    }
}

// MARK: - Actions

/// One offered transform of a clip's content: a label for the UI and the text a
/// click would put on the clipboard (or into the paste target).
struct ClipAction: Equatable {
    let title: String
    let output: String
}

/// Pure, bounded, crash-proof transforms over typed clipboard content. Every
/// function here fails toward "no actions" — malformed input is never an error, it is
/// silently uninteresting.
enum ClipTransformer {
    /// How many times base64 decoding re-detects and re-transforms its own output.
    /// Bounded so a pathological chain of nested base64 cannot recurse unboundedly.
    static let maxRecursionDepth = 3

    static func actions(for content: String, now: Date = Date(), timeZone: TimeZone = .current) -> [ClipAction] {
        actions(for: content, now: now, timeZone: timeZone, depth: 0)
    }

    private static func actions(
        for content: String, now: Date, timeZone: TimeZone, depth: Int
    ) -> [ClipAction] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        switch ClipKind.detect(trimmed) {
        case .jwt: return jwtActions(trimmed, now: now, timeZone: timeZone)
        case .epochTimestamp: return epochActions(trimmed, now: now, timeZone: timeZone)
        case .json: return jsonActions(trimmed)
        case .base64: return base64Actions(trimmed, now: now, timeZone: timeZone, depth: depth)
        case .urlWithQuery: return urlActions(trimmed)
        case .hexColor: return hexColorActions(trimmed)
        case .filePath: return filePathActions(trimmed)
        case .uuid: return uuidActions(trimmed)
        case .plainText: return []
        }
    }

    // MARK: JWT

    private static func jwtActions(_ content: String, now: Date, timeZone: TimeZone) -> [ClipAction] {
        let parts = content.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = decodeBase64URL(String(parts[0])),
              let payloadData = decodeBase64URL(String(parts[1])),
              let headerPretty = prettyJSONString(headerData),
              let payloadPretty = prettyJSONString(payloadData)
        else { return [] }

        var out = [
            ClipAction(title: "Decoded header", output: headerPretty),
            ClipAction(title: "Decoded payload", output: payloadPretty),
        ]

        if let claims = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] {
            for claim in ["iat", "nbf", "exp"] {
                guard let seconds = numericValue(claims[claim]) else { continue }
                let date = Date(timeIntervalSince1970: seconds)
                out.append(ClipAction(
                    title: "\(claim) (\(isoUTC(date)))",
                    output: "\(isoUTC(date)) UTC · \(relativeDescription(date, now: now))"
                ))
            }
        }
        return out
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: Epoch timestamps

    private static func epochActions(_ content: String, now: Date, timeZone: TimeZone) -> [ClipAction] {
        guard let raw = Double(content) else { return [] }
        let seconds = content.count == 13 ? raw / 1000 : raw
        let date = Date(timeIntervalSince1970: seconds)
        return [
            ClipAction(title: "UTC", output: isoUTC(date)),
            ClipAction(title: "Local (\(timeZone.identifier))", output: isoLocal(date, timeZone: timeZone)),
            ClipAction(title: "Relative", output: relativeDescription(date, now: now)),
        ]
    }

    // MARK: JSON

    private static func jsonActions(_ content: String) -> [ClipAction] {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        var out: [ClipAction] = []
        if let pretty = prettyJSONString(data) {
            out.append(ClipAction(title: "Pretty-print", output: pretty))
        }
        if let minified = minifiedJSONString(data) {
            out.append(ClipAction(title: "Minify", output: minified))
        }
        if let dict = object as? [String: Any] {
            out.append(ClipAction(title: "Top-level keys", output: dict.keys.sorted().joined(separator: "\n")))
        }
        return out
    }

    // MARK: Base64 (recursive)

    private static func base64Actions(
        _ content: String, now: Date, timeZone: TimeZone, depth: Int
    ) -> [ClipAction] {
        guard let data = Data(base64Encoded: content),
              let decodedText = String(data: data, encoding: .utf8), !decodedText.isEmpty
        else { return [] }

        var out = [ClipAction(title: "Decoded (base64)", output: decodedText)]
        guard depth < maxRecursionDepth else { return out }

        let nested = actions(for: decodedText, now: now, timeZone: timeZone, depth: depth + 1)
        out.append(contentsOf: nested.map {
            ClipAction(title: "decoded → \($0.title)", output: $0.output)
        })
        return out
    }

    // MARK: URL with query

    private static let trackerParameterNames: Set<String> = [
        "fbclid", "gclid", "igshid", "mc_eid", "ref",
    ]

    private static func urlActions(_ content: String) -> [ClipAction] {
        guard var components = URLComponents(string: content),
              let items = components.queryItems, !items.isEmpty
        else { return [] }

        let table = items.map { item -> String in
            let value = item.value.flatMap { $0.removingPercentEncoding } ?? (item.value ?? "")
            return "\(item.name) = \(value)"
        }.joined(separator: "\n")
        var out = [ClipAction(title: "Parameters", output: table)]

        let stripped = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackerParameterNames.contains(name)
        }
        if stripped.count != items.count {
            components.queryItems = stripped.isEmpty ? nil : stripped
            if let strippedString = components.string {
                out.append(ClipAction(title: "Strip trackers", output: strippedString))
            }
        }
        return out
    }

    // MARK: Hex color

    private static func hexColorActions(_ content: String) -> [ClipAction] {
        guard let (r, g, b, a) = parseHexColor(content) else { return [] }
        let alpha = Double(a) / 255
        let hasAlpha = a != 255

        let rgbTitle = hasAlpha ? "rgba()" : "rgb()"
        let rgbOutput = hasAlpha
            ? "rgba(\(r), \(g), \(b), \(formatDecimal(alpha, places: 2)))"
            : "rgb(\(r), \(g), \(b))"

        let (h, s, l) = rgbToHSL(r: r, g: g, b: b)
        let hslTitle = hasAlpha ? "hsla()" : "hsl()"
        let hslOutput = hasAlpha
            ? "hsla(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%, \(formatDecimal(alpha, places: 2)))"
            : "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"

        let (ll, cc, hh) = rgbToOKLCH(r: r, g: g, b: b)
        let oklchOutput = "oklch(\(formatDecimal(ll, places: 3)) \(formatDecimal(cc, places: 3)) \(Int(hh.rounded())))"

        return [
            ClipAction(title: rgbTitle, output: rgbOutput),
            ClipAction(title: hslTitle, output: hslOutput),
            ClipAction(title: "oklch()", output: oklchOutput),
        ]
    }

    // MARK: File path

    private static func filePathActions(_ content: String) -> [ClipAction] {
        let expanded = (content as NSString).expandingTildeInPath
        var out = [ClipAction(title: "POSIX path", output: content)]
        if let encoded = expanded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            out.append(ClipAction(title: "file:// URL", output: "file://" + encoded))
        }
        out.append(ClipAction(title: "Shell-escaped", output: shellEscape(content)))
        return out
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: UUID

    private static func uuidActions(_ content: String, now: Date = Date()) -> [ClipAction] {
        guard let uuid = UUID(uuidString: content) else { return [] }
        let bytes = uuid.uuid
        let version = (bytes.6 & 0xF0) >> 4

        var out = [
            ClipAction(title: "Version", output: "v\(version)"),
            ClipAction(title: "Variant", output: variantDescription(bytes.8)),
        ]

        if version == 1, let timestamp = v1Timestamp(bytes) {
            out.append(ClipAction(title: "Embedded timestamp", output: isoUTC(timestamp)))
        } else if version == 7 {
            out.append(ClipAction(title: "Embedded timestamp", output: isoUTC(v7Timestamp(bytes))))
        }

        // Always a fresh random v4, deliberately never a same-version regenerate: a
        // v1/v7 "sibling" built from a nearby timestamp would look temporally adjacent
        // to the original without actually being so, which is a lie no UI copy could
        // fully disclaim.
        out.append(ClipAction(title: "Sibling (fresh v4)", output: UUID().uuidString))
        return out
    }

    private static func variantDescription(_ byte8: UInt8) -> String {
        if byte8 & 0x80 == 0 { return "NCS backward compatible" }
        if byte8 & 0x40 == 0 { return "RFC 4122" }
        if byte8 & 0x20 == 0 { return "Microsoft backward compatible" }
        return "Reserved for future use"
    }

    /// UUID v1 packs a 60-bit count of 100ns intervals since 1582-10-15 across
    /// time_low/time_mid/time_hi_and_version (the latter with its top nibble masked
    /// off, since that nibble holds the version). `gregorianOffsetIn100ns` is the
    /// standard constant (used identically by, e.g., Python's `uuid` module) for the
    /// interval between that epoch and the Unix epoch.
    private static func v1Timestamp(_ bytes: uuid_t) -> Date? {
        let timeLow = UInt64(bytes.0) << 24 | UInt64(bytes.1) << 16 | UInt64(bytes.2) << 8 | UInt64(bytes.3)
        let timeMid = UInt64(bytes.4) << 8 | UInt64(bytes.5)
        let timeHi = UInt64(bytes.6 & 0x0F) << 8 | UInt64(bytes.7)
        let intervals100ns = (timeHi << 48) | (timeMid << 32) | timeLow
        let gregorianOffsetIn100ns: UInt64 = 0x01B2_1DD2_1381_4000
        guard intervals100ns >= gregorianOffsetIn100ns else { return nil }
        let seconds = Double(intervals100ns - gregorianOffsetIn100ns) / 10_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    /// UUID v7 packs a 48-bit big-endian Unix millisecond timestamp in its first 6
    /// bytes.
    private static func v7Timestamp(_ bytes: uuid_t) -> Date {
        let ms = UInt64(bytes.0) << 40 | UInt64(bytes.1) << 32 | UInt64(bytes.2) << 24
            | UInt64(bytes.3) << 16 | UInt64(bytes.4) << 8 | UInt64(bytes.5)
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    // MARK: - Shared helpers

    fileprivate static func decodeBase64URL(_ s: String) -> Data? {
        guard !s.isEmpty else { return nil }
        var encoded = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: encoded)
    }

    private static func prettyJSONString(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    private static func minifiedJSONString(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let minified = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: minified, encoding: .utf8)
    }

    private static func isoUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func isoLocal(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// Hand-rolled rather than `RelativeDateTimeFormatter`, so results are exactly
    /// reproducible in tests regardless of locale or OS version.
    private static func relativeDescription(_ date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        let future = interval >= 0
        let seconds = abs(interval)

        let value: Int
        let unit: String
        switch seconds {
        case ..<60: (value, unit) = (Int(seconds), "second")
        case ..<3600: (value, unit) = (Int(seconds / 60), "minute")
        case ..<86400: (value, unit) = (Int(seconds / 3600), "hour")
        case ..<(86400 * 30): (value, unit) = (Int(seconds / 86400), "day")
        case ..<(86400 * 365): (value, unit) = (Int(seconds / (86400 * 30)), "month")
        default: (value, unit) = (Int(seconds / (86400 * 365)), "year")
        }
        let plural = value == 1 ? unit : "\(unit)s"
        return future ? "in \(value) \(plural)" : "\(value) \(plural) ago"
    }

    private static func formatDecimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: Hex color parsing + math

    private static func parseHexColor(_ s: String) -> (r: Int, g: Int, b: Int, a: Int)? {
        let hex = Array(s.dropFirst())
        func byte(_ hi: Character, _ lo: Character) -> Int? {
            guard let h = hi.hexDigitValue, let l = lo.hexDigitValue else { return nil }
            return h * 16 + l
        }
        switch hex.count {
        case 3:
            guard let r = hex[0].hexDigitValue, let g = hex[1].hexDigitValue, let b = hex[2].hexDigitValue
            else { return nil }
            return (r * 17, g * 17, b * 17, 255)
        case 6:
            guard let r = byte(hex[0], hex[1]), let g = byte(hex[2], hex[3]), let b = byte(hex[4], hex[5])
            else { return nil }
            return (r, g, b, 255)
        case 8:
            guard let r = byte(hex[0], hex[1]), let g = byte(hex[2], hex[3]), let b = byte(hex[4], hex[5]),
                  let a = byte(hex[6], hex[7])
            else { return nil }
            return (r, g, b, a)
        default:
            return nil
        }
    }

    private static func rgbToHSL(r: Int, g: Int, b: Int) -> (h: Double, s: Double, l: Double) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxV = max(rf, gf, bf), minV = min(rf, gf, bf)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l) }

        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        if maxV == rf {
            h = (gf - bf) / d + (gf < bf ? 6 : 0)
        } else if maxV == gf {
            h = (bf - rf) / d + 2
        } else {
            h = (rf - gf) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    /// sRGB → linear → OKLab → OKLCH, using Björn Ottosson's published matrices.
    private static func rgbToOKLCH(r: Int, g: Int, b: Int) -> (l: Double, c: Double, h: Double) {
        func toLinear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let rl = toLinear(Double(r) / 255)
        let gl = toLinear(Double(g) / 255)
        let bl = toLinear(Double(b) / 255)

        let l = 0.4122214708 * rl + 0.5363325363 * gl + 0.0514459929 * bl
        let m = 0.2119034982 * rl + 0.6806995451 * gl + 0.1073969566 * bl
        let s = 0.0883024619 * rl + 0.2817188376 * gl + 0.6299787005 * bl

        let l_ = cbrt(l)
        let m_ = cbrt(m)
        let s_ = cbrt(s)

        let bigL = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let bigA = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let bigB = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_

        let c = sqrt(bigA * bigA + bigB * bigB)
        var h = atan2(bigB, bigA) * 180 / .pi
        if h < 0 { h += 360 }
        return (bigL, c, h)
    }
}
