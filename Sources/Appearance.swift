import SwiftUI
import AppKit

// MARK: - Colour

/// A colour as the user gave it: eight bits per channel, sRGB, stored as a hex string.
///
/// Deliberately not `Color`. What gets saved to disk and shared between people has to be
/// something a human can read and retype, and `Color` is neither `Codable` in a stable
/// form nor inspectable.
struct HexColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// Accepts `#RRGGBB`, `RRGGBB`, and the three-digit short form. Returns nil rather
    /// than a fallback colour: a typo in an imported preset should be reported, not
    /// silently rendered as black.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }), let value = UInt32(s, radix: 16) else {
            return nil
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        String(format: "#%02X%02X%02X",
               Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    // Encoded as the hex string itself, so a settings file or an exported preset reads
    // like something a person wrote.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = HexColor(hex: raw) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "not a hex colour: \(raw)")
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    /// WCAG relative luminance, which is what contrast ratios are defined against.
    /// Not the same thing as OKLab's L, and not interchangeable with it.
    var luminance: Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(against other: HexColor) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// A colour in OKLCH — lightness, chroma, hue.
///
/// Everything derived is derived here rather than in sRGB. In sRGB, "10% lighter" means
/// something different for every hue: the same nudge that lifts a blue off the ground
/// blows out a yellow. OKLab was built so that equal steps look equal, which is the only
/// property that makes a rule like "text sits at 0.94 lightness" mean anything.
struct Oklch: Equatable {
    var l: Double
    var c: Double
    /// Radians.
    var h: Double

    init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    init(_ rgb: HexColor) {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(rgb.red), g = linear(rgb.green), b = linear(rgb.blue)

        let lp = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let mp = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let sp = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        let l_ = cbrt(lp), m_ = cbrt(mp), s_ = cbrt(sp)

        let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_

        self.l = L
        self.c = (a * a + bb * bb).squareRoot()
        self.h = atan2(bb, a)
    }

    /// Back to sRGB, clamped into gamut. Clamping per channel rather than reducing chroma
    /// is crude, but every colour this produces is a small step from one the user picked,
    /// so nothing travels far enough for the difference to show.
    var rgb: HexColor {
        let a = c * cos(h)
        let b = c * sin(h)

        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b

        let lp = l_ * l_ * l_, mp = m_ * m_ * m_, sp = s_ * s_ * s_

        let r = 4.0767416621 * lp - 3.3077115913 * mp + 0.2309699292 * sp
        let g = -1.2684380046 * lp + 2.6097574011 * mp - 0.3413193965 * sp
        let bl = -0.0041960863 * lp - 0.7034186147 * mp + 1.7076147010 * sp

        func srgb(_ c: Double) -> Double {
            let v = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
            return min(max(v, 0), 1)
        }
        return HexColor(red: srgb(r), green: srgb(g), blue: srgb(bl))
    }

    func with(l: Double? = nil, c: Double? = nil, h: Double? = nil) -> Oklch {
        Oklch(l: l ?? self.l, c: c ?? self.c, h: h ?? self.h)
    }

    /// Rotate the hue by degrees, for deriving a second tint that is clearly a different
    /// thing rather than a slightly different shade of the first.
    func rotated(_ degrees: Double) -> Oklch {
        Oklch(l: l, c: c, h: h + degrees * .pi / 180)
    }
}

// MARK: - What the user picks

enum FontChoice: String, Codable, CaseIterable, Identifiable {
    case sans, serif, mono, rounded
    var id: String { rawValue }

    /// Named by the system face, not by the category. The reference designs use licensed
    /// faces that cannot ship, and saying "Serif" while quietly meaning New York is the
    /// kind of substitution that reads as a bug the first time someone compares.
    var label: String {
        switch self {
        case .sans: return "SF Pro"
        case .serif: return "New York"
        case .mono: return "SF Mono"
        case .rounded: return "SF Rounded"
        }
    }

    var design: Font.Design {
        switch self {
        case .sans: return .default
        case .serif: return .serif
        case .mono: return .monospaced
        case .rounded: return .rounded
        }
    }
}

/// Everything a person can set. Everything else is computed from it.
///
/// The short list is the point. Eight colour wells and a font menu is not customisation,
/// it is a contrast bug waiting to be filed: the likeliest thing anyone builds with a
/// full palette editor is a window they cannot read. What is here is what genuinely
/// changes the character of the thing — the ground it sits on, the colour it points with,
/// the two faces, and how hard its corners are.
struct Appearance: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// The window's ground. Light or dark is inferred from it rather than declared.
    var ground: HexColor
    /// Optional second ground used when macOS is in the other appearance. Nil means the
    /// look is committed to one ground and ignores the system setting.
    var darkGround: HexColor?
    var accent: HexColor
    var aliasTint: HexColor
    var functionTint: HexColor
    var uiFont: FontChoice
    var nameFont: FontChoice
    var cornerRadius: Double
    /// 0 is opaque. Above that the desktop shows through the window's own colour.
    var translucency: Double
    var isBuiltIn: Bool

    /// A copy the user owns, with its own identity. Editing a built-in in place would
    /// mean the name stops describing anything.
    func copy(named newName: String, id newID: String) -> Appearance {
        var copy = self
        copy.id = newID
        copy.name = newName
        copy.isBuiltIn = false
        return copy
    }
}

// MARK: - The three

extension Appearance {
    static let builtIns: [Appearance] = [.graphite, .clay, .ultramarine]

    /// Cool near-black with indigo. The default, and the closest to where AliasBar
    /// already was.
    static let graphite = Appearance(
        id: "graphite",
        name: "Graphite",
        ground: HexColor(hex: "#0A0B0D")!,
        darkGround: nil,
        accent: HexColor(hex: "#4B5BC4")!,
        aliasTint: HexColor(hex: "#58CBFA")!,
        functionTint: HexColor(hex: "#EE9BDC")!,
        uiFont: .sans,
        nameFont: .mono,
        cornerRadius: 8,
        translucency: 0.55,
        isBuiltIn: true
    )

    /// Warm paper with terracotta. Every neutral in it carries a yellow bias; there is no
    /// true grey anywhere, which is what stops it reading as "light mode".
    static let clay = Appearance(
        id: "clay",
        name: "Clay",
        ground: HexColor(hex: "#F1EFE7")!,
        darkGround: HexColor(hex: "#191813")!,
        accent: HexColor(hex: "#D2764F")!,
        aliasTint: HexColor(hex: "#3F6B8C")!,
        functionTint: HexColor(hex: "#8C5A33")!,
        uiFont: .serif,
        nameFont: .mono,
        cornerRadius: 5,
        translucency: 0,
        isBuiltIn: true
    )

    /// Stark white, electric blue, and an acid second tint. The most opinionated of the
    /// three and the one that most needs the derived neutrals: its greys are pulled hard
    /// toward the blue, and doing that by hand is where hand-picked palettes go wrong.
    static let ultramarine = Appearance(
        id: "ultramarine",
        name: "Ultramarine",
        ground: HexColor(hex: "#F6F6F6")!,
        darkGround: HexColor(hex: "#0D0D12")!,
        accent: HexColor(hex: "#1414EE")!,
        aliasTint: HexColor(hex: "#1414EE")!,
        functionTint: HexColor(hex: "#E8FA4A")!,
        uiFont: .serif,
        nameFont: .mono,
        cornerRadius: 2,
        translucency: 0,
        isBuiltIn: true
    )
}

// MARK: - Derivation

/// The contrast each derived neutral has to clear against the ground it sits on.
///
/// These are guarantees, not intentions. Whatever ground someone picks — including a
/// mid-grey, which is the hardest case and the one a colour-well UI produces first — text
/// clears 11:1 and the faintest thing on screen still clears 3:1.
enum ContrastTarget {
    static let text = 11.0
    static let dim = 5.5
    static let faint = 3.1
    /// Rules are decoration, not information, and holding them to a text ratio would
    /// make every window look like a spreadsheet.
    static let rule = 1.35
    /// The accent is read as text in several places, so it carries a text-like floor.
    static let accent = 3.4
    /// A filled chip only has to have a visible edge against the ground.
    static let chip = 1.5
}

extension Theme {
    /// Builds the render-time tokens from the handful of things the user chose.
    ///
    /// The split is the whole design: `Appearance` is what a person sets and what gets
    /// saved, `Theme` is what the views read, and nothing in between is stored. Change
    /// the derivation and every saved preset picks it up.
    static func derive(from appearance: Appearance, dark systemIsDark: Bool = false) -> Theme {
        let groundHex = (systemIsDark ? appearance.darkGround : nil) ?? appearance.ground
        let ground = Oklch(groundHex)
        let accent = Oklch(appearance.accent)
        let isLight = groundHex.luminance > 0.35

        // Neutrals are pulled toward the accent's hue rather than left as true greys. It
        // is the cheapest thing that makes a palette read as one palette: a warm ground
        // with cold grey text looks like two designs sharing a window.
        let hue = accent.h
        let neutralChroma = min(accent.c * 0.22, 0.022)

        // Some grounds cannot carry the targets at all. A mid-grey tops out around 5.3:1
        // against anything, and asking for 11 there does not fail loudly — it quietly
        // returns the same near-black for text, dim, and faint alike, collapsing the
        // hierarchy into one colour. When the ceiling is lower than the ask, the whole
        // ladder is compressed to fit under it instead, so the three stay distinguishable
        // even where they cannot all be comfortable.
        let scale = Self.contrastScale(against: groundHex)

        func solve(_ target: Double, chroma: Double) -> HexColor {
            Self.lightness(forContrast: Self.scaled(target, by: scale),
                           against: groundHex, hue: hue, chroma: chroma)
        }

        let text = solve(ContrastTarget.text, chroma: neutralChroma * 0.5)
        let dim = solve(ContrastTarget.dim, chroma: neutralChroma)
        let faint = solve(ContrastTarget.faint, chroma: neutralChroma)
        let rule = solve(ContrastTarget.rule, chroma: neutralChroma * 1.4)

        // Surface lifts off the ground in both directions — a card is nearer the light
        // than the page it sits on whether the page is paper or slate.
        let surface = ground
            .with(l: min(ground.l + (isLight ? 0.028 : 0.05), 1),
                  c: min(ground.c + neutralChroma * 0.5, 0.04))
            .rgb

        // An accent picked for a dark ground is often too dark to read on a light one and
        // vice versa. Nudging its lightness — never its hue — keeps the colour the user
        // chose while making it legible where they put it.
        // The accent is held to a text-like ratio because it is drawn as text — tab
        // labels, the shell prompt, the history badge.
        let usableAccent = Self.legible(appearance.accent, on: groundHex,
                                        minimum: ContrastTarget.accent)
        // The two tints are held to far less, because they are fills with their own glyph
        // on top rather than marks read against the ground. Holding a chip to a reading
        // ratio is how an acid yellow ends up rendered as olive: the requirement it has to
        // meet is "you can see where the chip ends", not "you can read it".
        let alias = Self.legible(appearance.aliasTint, on: groundHex,
                                 minimum: ContrastTarget.chip)
        let function = Self.legible(appearance.functionTint, on: groundHex,
                                    minimum: ContrastTarget.chip)

        func onTint(_ colour: HexColor) -> Color {
            Self.wantsDarkGlyph(over: colour) ? Color(red: 0.06, green: 0.06, blue: 0.07) : .white
        }

        return Theme(
            background: groundHex.color,
            surface: surface.color,
            rule: rule.color,
            text: text.color,
            dim: dim.color,
            faint: faint.color,
            accent: usableAccent.color,
            aliasTint: alias.color,
            functionTint: function.color,
            onAccent: onTint(usableAccent),
            onAliasTint: onTint(alias),
            onFunctionTint: onTint(function),
            cornerRadius: appearance.cornerRadius,
            isLight: isLight,
            bodyDesign: appearance.uiFont.design,
            nameDesign: appearance.nameFont.design,
            vibrancy: appearance.translucency > 0.01
                ? Vibrancy(material: isLight ? .sheet : .hudWindow,
                           tint: 1 - appearance.translucency * 0.32)
                : nil
        )
    }

    /// The best contrast any colour can reach against this ground, in whichever direction
    /// has more room. Pure black and pure white are the two extremes available, so one of
    /// them is always the answer.
    static func reachableContrast(against ground: HexColor) -> Double {
        max(ground.contrast(against: HexColor(red: 0, green: 0, blue: 0)),
            ground.contrast(against: HexColor(red: 1, green: 1, blue: 1)))
    }

    /// How much of the intended ladder this ground can actually carry. 1 means all of it.
    static func contrastScale(against ground: HexColor) -> Double {
        let reach = reachableContrast(against: ground)
        guard reach < ContrastTarget.text else { return 1 }
        return max((reach - 1) / (ContrastTarget.text - 1), 0.05)
    }

    /// Compresses a target toward 1 — no contrast at all — by the given factor, so the
    /// gaps between the targets shrink in proportion rather than one of them swallowing
    /// the others.
    static func scaled(_ target: Double, by scale: Double) -> Double {
        1 + (target - 1) * scale
    }

    /// Whether something drawn on top of this colour should be dark rather than white.
    ///
    /// A user can pick an acid yellow tint on a white ground, and white-on-acid-yellow is
    /// not a subtle failure — it is an invisible glyph. The threshold sits where a mid
    /// tone stops carrying white text.
    static func wantsDarkGlyph(over colour: HexColor) -> Bool { colour.luminance > 0.45 }

    /// Binary-searches OKLab lightness for the first value clearing `target` against the
    /// ground, moving away from the ground rather than toward a fixed light or dark.
    ///
    /// A mid-grey ground is the case that decides the direction: there, "text" has to
    /// commit to going darker or lighter, and whichever side has more headroom wins.
    static func lightness(forContrast target: Double, against ground: HexColor,
                          hue: Double, chroma: Double) -> HexColor {
        let groundL = Oklch(ground).l
        // Which way has more room. On a ground light enough to sit near white, down is
        // the only direction that can reach a high ratio at all.
        let goDark = groundL > 0.5

        var low = goDark ? 0.0 : groundL
        var high = goDark ? groundL : 1.0
        var best = Oklch(l: goDark ? 0 : 1, c: chroma, h: hue).rgb

        // Twenty steps resolves lightness far finer than eight bits per channel can
        // represent, so this is exact for the purpose.
        for _ in 0..<20 {
            let mid = (low + high) / 2
            let candidate = Oklch(l: mid, c: chroma, h: hue).rgb
            if candidate.contrast(against: ground) >= target {
                best = candidate
                // Keep the least extreme value that still clears the bar: text that is
                // pure white when it did not need to be looks cheap.
                if goDark { low = mid } else { high = mid }
            } else {
                if goDark { high = mid } else { low = mid }
            }
        }
        return best
    }

    /// Nudges a chosen colour's lightness until it is readable on the ground, leaving its
    /// hue and chroma alone. The user picked a colour; this does not pick a different one.
    static func legible(_ colour: HexColor, on ground: HexColor, minimum: Double) -> HexColor {
        // Returned unchanged rather than round-tripped. The trip through OKLCH and back
        // is lossless to about one part in 255, and "about" is the wrong word to attach
        // to a colour the user typed in by hand.
        if colour.contrast(against: ground) >= minimum { return colour }
        var candidate = Oklch(colour)
        let goDark = Oklch(ground).l > 0.5
        for _ in 0..<40 {
            candidate = candidate.with(l: min(max(candidate.l + (goDark ? -0.02 : 0.02), 0), 1))
            if candidate.rgb.contrast(against: ground) >= minimum { break }
            if candidate.l <= 0 || candidate.l >= 1 { break }
        }
        return candidate.rgb
    }
}

// MARK: - Sharing

/// Presets travel as a short text block, because the people who will share these already
/// share dotfiles and nobody is going to build a gallery for a menu bar utility.
enum PresetTransfer {
    static func export(_ appearance: Appearance) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(appearance),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Imported presets always arrive as somebody else's copy: a new identity, and never
    /// built-in, so an import can never overwrite one of the three.
    static func importing(_ text: String, id: String) -> Appearance? {
        guard let data = text.data(using: .utf8),
              var decoded = try? JSONDecoder().decode(Appearance.self, from: data) else {
            return nil
        }
        decoded.id = id
        decoded.isBuiltIn = false
        if decoded.name.trimmingCharacters(in: .whitespaces).isEmpty { decoded.name = "Imported" }
        return decoded
    }
}
