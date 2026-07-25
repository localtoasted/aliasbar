import SwiftUI
import AppKit

/// The tokens the views actually read.
///
/// Nothing constructs one of these by hand any more. A `Theme` is derived from an
/// `Appearance` — the handful of things the user picked — and the derivation lives in
/// `Appearance.swift`. Keeping the two apart is what makes contrast a guarantee rather
/// than a hope: the values that have to hold a ratio are computed, and the values the
/// user chose are the ones they chose.
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
    /// Contrasting colours for anything drawn on top of a filled accent or tint.
    var onAccent: Color
    var onAliasTint: Color
    var onFunctionTint: Color
    var cornerRadius: CGFloat
    /// Derived from the ground's luminance, not declared. A user who picks a pale ground
    /// gets the light treatment without having to also tell us it is light.
    var isLight: Bool
    /// Body font design. Names and commands can use different faces.
    var bodyDesign: Font.Design
    var nameDesign: Font.Design

    /// How much of the desktop shows through, and which system material carries it.
    ///
    /// This is the difference between a surface that belongs to macOS and one pasted on
    /// top of it: the window picks up whatever is behind it, and the theme colour becomes
    /// a tint over that rather than an opaque fill. Nil when the user set translucency to
    /// zero — a look committed to being a printed page should not have a desktop showing
    /// through it.
    var vibrancy: Vibrancy? = nil

    struct Vibrancy {
        var material: NSVisualEffectView.Material
        /// Alpha the theme's own background is painted at, over the material.
        var tint: Double
    }

    func tint(for kind: ShellEntry.Kind) -> Color {
        kind == .function ? functionTint : aliasTint
    }

    /// Glyph colour for something drawn *on* a tint — the kind badge, mainly.
    ///
    /// It cannot follow the ground's lightness, which is what it used to do. A user is
    /// free to pick an acid yellow tint on a white ground, and white-on-acid-yellow is
    /// not a subtle failure; it is an invisible glyph. These ask the tint itself.
    func onTint(for kind: ShellEntry.Kind) -> Color {
        kind == .function ? onFunctionTint : onAliasTint
    }

    /// Selection fill. Light grounds need a wash rather than a glow.
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
    /// The header is fixed too, for the same reason the body is. It looks content-sized,
    /// but a serif interface face is a fraction taller than a sans one, and a look that
    /// changed the window's height by a point when you switched typeface would be exactly
    /// the thing this was supposed to stop.
    static let headerHeight: CGFloat = 93
    /// The area between the header rule and the footer rule. Header and footer are fixed
    /// by their own content, so fixing this fixes the window.
    /// Sized so the whole window still clears the Dock at the 20%-from-top position on a
    /// 1280 × 800 display, the smallest ground worth designing for.
    static let bodyHeight: CGFloat = 420
    /// How many keys BOARD fits across at a given key width.
    ///
    /// Computable rather than measured because the window is a fixed width now: the grid
    /// is adaptive, but it is adapting to a width nothing can change. This is what makes
    /// ↑ ↓ move by a row in BOARD instead of by one key.
    static func boardColumns(keyWidth: CGFloat, spacing: CGFloat = 6,
                             padding: CGFloat = 10) -> Int {
        let available = windowWidth - padding * 2
        return max(1, Int((available + spacing) / (keyWidth + spacing)))
    }

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
    static let defaultValue = Theme.derive(from: .graphite)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
