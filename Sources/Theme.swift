import SwiftUI
import AppKit

/// The five looks from the design round, kept as themes rather than as separate
/// architectures. Each one commits to a distinct material: a printed ledger, a
/// blueprint, a library index card, a dictionary page, a phosphor terminal.
enum ThemeName: String, CaseIterable, Identifiable {
    case slate, phosphor, ledger, blueprint, index, dictionary, system
    var id: String { rawValue }

    var label: String {
        switch self {
        case .slate: return "Slate"
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
        case .slate: return "Clean, quiet, modern"
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

    /// How much of the desktop shows through, and which system material carries it.
    ///
    /// This is the difference between a surface that belongs to macOS and one pasted on
    /// top of it: the window picks up whatever is behind it, and the theme colour becomes
    /// a tint over that rather than an opaque fill.
    ///
    /// Deliberately absent on the paper themes. Ledger, Index, and Dictionary each commit
    /// to a physical stock, and a sheet of paper you can see the desktop through is not a
    /// subtler version of that idea — it is a different, incoherent one.
    var vibrancy: Vibrancy? = nil

    struct Vibrancy {
        var material: NSVisualEffectView.Material
        /// Alpha the theme's own background is painted at, over the material.
        var tint: Double
    }

    static func current(_ name: ThemeName) -> Theme {
        switch name {
        case .slate:
            // The default. Near-black tinted toward blue rather than pure grey, a single
            // indigo accent, and one clear step between text, dim, and faint. Names stay
            // monospaced because they are things you type; everything else is the system
            // sans, which reads far better at small sizes than a terminal face does.
            return Theme(
                background: Color(red: 0.043, green: 0.047, blue: 0.055),
                surface: Color(red: 0.086, green: 0.094, blue: 0.110),
                rule: Color(red: 0.212, green: 0.227, blue: 0.263),
                text: Color(red: 0.949, green: 0.957, blue: 0.973),
                dim: Color(red: 0.612, green: 0.639, blue: 0.702),
                faint: Color(red: 0.408, green: 0.435, blue: 0.502),
                accent: Color(red: 0.416, green: 0.451, blue: 0.902),
                aliasTint: Color(red: 0.416, green: 0.451, blue: 0.902),
                functionTint: Color(red: 0.541, green: 0.361, blue: 0.859),
                cornerRadius: 6,
                isLight: false,
                bodyDesign: .default,
                nameDesign: .monospaced,
                usesMaterial: false,
                vibrancy: Vibrancy(material: .hudWindow, tint: 0.78)
            )

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
                usesMaterial: false,
                // A CRT is glass with a lit phosphor layer behind it, so it takes the
                // most transparency of any theme here without losing what it is.
                vibrancy: Vibrancy(material: .underWindowBackground, tint: 0.72)
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
                usesMaterial: false,
                vibrancy: Vibrancy(material: .hudWindow, tint: 0.82)
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

/// The system's own blur, sampling whatever is behind the window.
///
/// SwiftUI's `.ultraThinMaterial` blurs what is behind it *within the window*, which over
/// a transparent background is nothing at all. Only `NSVisualEffectView` with
/// `.behindWindow` blending reaches past the window to the desktop.
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // `.followsWindowActiveState` would drain the blur the moment focus moves to a
        // sheet, which is exactly when the window is most on show.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The window's dimensions, which do not depend on what is in it.
///
/// One size for every view, and the same size whether a search matched forty things or
/// two. A window that appears under your gaze and is read in under a second has to be
/// still; a two-result search leaving empty space below is the cheaper cost. Everything
/// that used to change the window's height — switching views, filtering, entering
/// history — now scrolls inside a fixed body instead.
enum WindowLayout {
    /// A compromise, deliberately. Manage is cramped at 520 because three panes need the
    /// room, and Find at 780 is a lot of air around two-character names. One size that is
    /// slightly generous for one view beats two sizes that are each perfect.
    static let windowWidth: CGFloat = 660
    /// The area between the header rule and the footer rule. Header and footer are fixed
    /// by their own content, so fixing this fixes the window.
    /// Sized so the whole window still clears the Dock at the 20%-from-top position on a
    /// 1280 × 800 display, the smallest ground worth designing for.
    static let bodyHeight: CGFloat = 420
    /// How many rows the body holds at rest. Roughly what fits in `bodyHeight`; the list
    /// scrolls past it rather than being clipped, so being a row out is harmless.
    static let restRows = 10
}

/// Motion for everything that moves. One curve, used everywhere.
///
/// Ease-out-quint: fast at the start, decelerating hard. No spring, no overshoot — real
/// objects settle rather than bounce, and bounce is the tell of a UI designed in 2019.
enum Motion {
    static let standard = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    /// Entrance is allowed to be slower than response; nothing is waiting on it.
    static let entrance = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.28)
    /// Rows arrive in sequence rather than all at once, capped so a long list does not
    /// turn the reveal into a wait.
    static func stagger(_ index: Int) -> Animation {
        entrance.delay(Double(min(index, 8)) * 0.02)
    }
}

/// Fades and lifts a row into place, offset by its position in the list.
///
/// Keyed on identity, not on the list: a row that survives a keystroke does not replay
/// its entrance, so typing filters the list without the surviving rows flickering.
struct Arriving: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    @State private var arrived = false

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived ? 0 : 4)
            .onAppear {
                guard !reduceMotion else { arrived = true; return }
                withAnimation(Motion.stagger(index)) { arrived = true }
            }
    }
}

extension View {
    func arriving(_ index: Int) -> some View { modifier(Arriving(index: index)) }
}

/// Reads the current theme once and hands it down, so views never touch Settings
/// directly for appearance.
private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.current(.slate)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
