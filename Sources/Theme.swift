import SwiftUI

/// The five looks from the design round, kept as themes rather than as separate
/// architectures. Each one commits to a distinct material: a printed ledger, a
/// blueprint, a library index card, a dictionary page, a phosphor terminal.
enum ThemeName: String, CaseIterable, Identifiable {
    case phosphor, ledger, blueprint, index, dictionary, system
    var id: String { rawValue }

    var label: String {
        switch self {
        case .phosphor: return "Phosphor"
        case .ledger: return "Ledger"
        case .blueprint: return "Blueprint"
        case .index: return "Index"
        case .dictionary: return "Dictionary"
        case .system: return "System"
        }
    }

    var blurb: String {
        switch self {
        case .phosphor: return "Green CRT terminal"
        case .ledger: return "Ruled accounting paper"
        case .blueprint: return "Cyanotype technical drawing"
        case .index: return "Library card catalogue"
        case .dictionary: return "Typeset reference page"
        case .system: return "Follows macOS light and dark"
        }
    }
}

struct Theme {
    var background: Color
    var surface: Color
    var rule: Color
    var text: Color
    var dim: Color
    var faint: Color
    var accent: Color
    var aliasTint: Color
    var functionTint: Color
    var cornerRadius: CGFloat
    /// True for the themes built on paper stock, which read better in light appearance.
    var isLight: Bool
    /// Body font design. The mono-first themes use it for names and commands alike.
    var bodyDesign: Font.Design
    var nameDesign: Font.Design
    /// Whether the popover paints its own background or lets the system material show.
    var usesMaterial: Bool

    static func current(_ name: ThemeName) -> Theme {
        switch name {
        case .phosphor:
            return Theme(
                background: Color(red: 0.043, green: 0.063, blue: 0.051),
                surface: Color(red: 0.075, green: 0.106, blue: 0.086),
                rule: Color(red: 0.22, green: 0.42, blue: 0.28),
                text: Color(red: 0.72, green: 0.98, blue: 0.78),
                dim: Color(red: 0.45, green: 0.72, blue: 0.52),
                faint: Color(red: 0.30, green: 0.50, blue: 0.36),
                accent: Color(red: 0.38, green: 0.95, blue: 0.50),
                aliasTint: Color(red: 0.45, green: 0.92, blue: 0.62),
                functionTint: Color(red: 0.70, green: 0.95, blue: 0.42),
                cornerRadius: 3,
                isLight: false,
                bodyDesign: .monospaced,
                nameDesign: .monospaced,
                usesMaterial: false
            )

        case .ledger:
            return Theme(
                background: Color(red: 0.976, green: 0.965, blue: 0.937),
                surface: Color(red: 0.996, green: 0.992, blue: 0.976),
                rule: Color(red: 0.78, green: 0.80, blue: 0.72),
                text: Color(red: 0.13, green: 0.13, blue: 0.11),
                dim: Color(red: 0.42, green: 0.42, blue: 0.38),
                faint: Color(red: 0.62, green: 0.62, blue: 0.57),
                accent: Color(red: 0.62, green: 0.16, blue: 0.16),
                aliasTint: Color(red: 0.20, green: 0.32, blue: 0.55),
                functionTint: Color(red: 0.55, green: 0.30, blue: 0.10),
                cornerRadius: 2,
                isLight: true,
                bodyDesign: .monospaced,
                nameDesign: .monospaced,
                usesMaterial: false
            )

        case .blueprint:
            return Theme(
                background: Color(red: 0.055, green: 0.145, blue: 0.290),
                surface: Color(red: 0.086, green: 0.196, blue: 0.365),
                rule: Color(red: 0.35, green: 0.55, blue: 0.78),
                text: Color(red: 0.90, green: 0.94, blue: 1.0),
                dim: Color(red: 0.64, green: 0.76, blue: 0.92),
                faint: Color(red: 0.44, green: 0.58, blue: 0.78),
                accent: Color(red: 1.0, green: 0.85, blue: 0.35),
                aliasTint: Color(red: 0.55, green: 0.82, blue: 1.0),
                functionTint: Color(red: 1.0, green: 0.80, blue: 0.55),
                cornerRadius: 0,
                isLight: false,
                bodyDesign: .monospaced,
                nameDesign: .monospaced,
                usesMaterial: false
            )

        case .index:
            return Theme(
                background: Color(red: 0.988, green: 0.976, blue: 0.941),
                surface: Color(red: 1.0, green: 0.996, blue: 0.980),
                rule: Color(red: 0.85, green: 0.72, blue: 0.66),
                text: Color(red: 0.16, green: 0.14, blue: 0.13),
                dim: Color(red: 0.45, green: 0.40, blue: 0.38),
                faint: Color(red: 0.68, green: 0.62, blue: 0.58),
                accent: Color(red: 0.78, green: 0.28, blue: 0.24),
                aliasTint: Color(red: 0.22, green: 0.40, blue: 0.52),
                functionTint: Color(red: 0.52, green: 0.34, blue: 0.52),
                cornerRadius: 4,
                isLight: true,
                bodyDesign: .default,
                nameDesign: .monospaced,
                usesMaterial: false
            )

        case .dictionary:
            return Theme(
                background: Color(red: 0.992, green: 0.988, blue: 0.976),
                surface: Color(red: 1.0, green: 1.0, blue: 0.996),
                rule: Color(red: 0.80, green: 0.78, blue: 0.74),
                text: Color(red: 0.09, green: 0.09, blue: 0.09),
                dim: Color(red: 0.38, green: 0.38, blue: 0.37),
                faint: Color(red: 0.60, green: 0.60, blue: 0.58),
                accent: Color(red: 0.15, green: 0.15, blue: 0.15),
                aliasTint: Color(red: 0.30, green: 0.30, blue: 0.30),
                functionTint: Color(red: 0.48, green: 0.44, blue: 0.40),
                cornerRadius: 2,
                isLight: true,
                bodyDesign: .serif,
                nameDesign: .serif,
                usesMaterial: false
            )

        case .system:
            return Theme(
                background: Color.clear,
                surface: Color.primary.opacity(0.06),
                rule: Color.primary.opacity(0.12),
                text: Color.primary,
                dim: Color.secondary,
                faint: Color.secondary.opacity(0.6),
                accent: Color(red: 0.35, green: 0.85, blue: 0.45),
                aliasTint: Color(red: 0.35, green: 0.75, blue: 1.0),
                functionTint: Color(red: 0.65, green: 0.55, blue: 1.0),
                cornerRadius: 8,
                isLight: false,
                bodyDesign: .default,
                nameDesign: .monospaced,
                usesMaterial: true
            )
        }
    }

    func tint(for kind: ShellEntry.Kind) -> Color {
        kind == .function ? functionTint : aliasTint
    }

    /// Selection fill. Paper themes need a wash rather than a glow.
    var selectionFill: Color {
        isLight ? accent.opacity(0.14) : accent.opacity(0.20)
    }

    var selectionStroke: Color {
        accent.opacity(isLight ? 0.55 : 0.75)
    }
}

/// Reads the current theme once and hands it down, so views never touch Settings
/// directly for appearance.
private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.current(.phosphor)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
