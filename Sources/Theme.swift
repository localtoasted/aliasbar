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
    /// The fixed area below the header. Every view scrolls inside this height, so search
    /// results and view changes never resize the window.
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
    /// The window arriving. Shorter than a row's entrance — it is the thing you are
    /// waiting for, not decoration around it.
    static let windowIn = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.14)
    /// Leaving is faster than arriving. Nobody wants to watch a dismissal.
    static let windowOut = Animation.easeOut(duration: 0.09)
    /// Hover and press want to feel like contact rather than like animation.
    static let hover = Animation.easeOut(duration: 0.09)
    static let press = Animation.easeOut(duration: 0.06)
    /// Rows arrive in sequence rather than all at once, capped so a long list does not
    /// turn the reveal into a wait.
    static func stagger(_ index: Int) -> Animation {
        entrance.delay(Double(min(index, 8)) * 0.02)
    }
}

/// How much of that motion is actually allowed right now.
///
/// Two independent sources, and they are not the same kind of thing. The system's Reduce
/// Motion is an accessibility setting and is obeyed without asking. `MotionLevel` is the
/// user's own preference. Whichever is more restrictive wins.
///
/// Everything animated asks this rather than reaching for `Motion` directly, which is what
/// keeps the off switch honest: there is one place to forget, and it is this one.
struct MotionPlan {
    var level: MotionLevel = .full

    /// Transforms — scale, offset, travel. The first thing to go.
    var movesThings: Bool { level == .full }
    /// Fades survive "Reduced": a cross-fade carries the same information as a slide and
    /// costs nothing to watch.
    var fades: Bool { level != .none }

    /// The animation to use, or nil for "apply it instantly".
    func callAsFunction(_ base: Animation) -> Animation? {
        level == .none ? nil : base
    }

    /// Stagger collapses to a plain entrance at Reduced — a queue of fades is still a
    /// queue, and waiting is the part people object to.
    func stagger(_ index: Int) -> Animation? {
        switch level {
        case .full: return Motion.stagger(index)
        case .reduced: return Motion.entrance
        case .none: return nil
        }
    }

    /// Resolves the user's setting against the system's, taking the stricter of the two.
    static func resolve(_ level: MotionLevel, reduceMotion: Bool) -> MotionPlan {
        guard reduceMotion else { return MotionPlan(level: level) }
        return MotionPlan(level: level == .none ? .none : .reduced)
    }
}

private struct MotionPlanKey: EnvironmentKey {
    static let defaultValue = MotionPlan()
}

extension EnvironmentValues {
    var motion: MotionPlan {
        get { self[MotionPlanKey.self] }
        set { self[MotionPlanKey.self] = newValue }
    }
}

/// Fades and lifts a row into place, offset by its position in the list.
///
/// Keyed on identity, not on the list: a row that survives a keystroke does not replay
/// its entrance, so typing filters the list without the surviving rows flickering.
struct Arriving: ViewModifier {
    @Environment(\.motion) private var motion
    let index: Int
    @State private var arrived = false

    func body(content: Content) -> some View {
        content
            .opacity(arrived || !motion.fades ? 1 : 0)
            .offset(y: arrived || !motion.movesThings ? 0 : 4)
            .onAppear {
                guard let animation = motion.stagger(index) else { arrived = true; return }
                withAnimation(animation) { arrived = true }
            }
    }
}

extension View {
    func arriving(_ index: Int) -> some View { modifier(Arriving(index: index)) }

    /// Makes a control answer the pointer *and* do its job. A thing that does not respond
    /// to a hover reads as a picture of a control; a thing that responds and then swallows
    /// the click is worse.
    ///
    /// The action belongs here rather than in a separate `onTapGesture` behind it. Two
    /// independent gestures on one view means arbitration, and arbitration means the one
    /// that resolves first — a press detector — wins and the tap never fires. That shipped
    /// once already.
    func live(pressDrop: CGFloat = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) { self }
            .buttonStyle(LiveButtonStyle(pressDrop: pressDrop))
    }

    /// Hover and press feedback for something that is already a `Button` and owns its own
    /// gesture — a `ButtonStyle` cannot be applied to a plain view, and a plain view cannot
    /// be given press feedback without an action to hang it on.
    func liveButton(pressDrop: CGFloat = 0) -> some View {
        buttonStyle(LiveButtonStyle(pressDrop: pressDrop))
    }
}

/// The single control treatment: hover, press, and activation as one thing.
///
/// A `ButtonStyle` rather than a gesture, because `configuration.isPressed` is the press
/// state the button already tracks. Nothing competes with anything.
struct LiveButtonStyle: ButtonStyle {
    /// How far the surface travels when pressed. A keycap travels; a settings row does not.
    var pressDrop: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, pressDrop: pressDrop)
    }

    /// A real view rather than a bare modifier chain, because hover is `@State` and a
    /// `ButtonStyle` is recreated on every render.
    private struct Surface: View {
        let configuration: Configuration
        let pressDrop: CGFloat
        @Environment(\.motion) private var motion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .brightness(brightness)
                .scaleEffect(motion.movesThings && configuration.isPressed ? 0.985 : 1)
                .offset(y: motion.movesThings && configuration.isPressed ? pressDrop : 0)
                .animation(motion(configuration.isPressed ? Motion.press : Motion.hover),
                           value: configuration.isPressed)
                .animation(motion(Motion.hover), value: hovering)
                .onHover { hovering = $0 }
        }

        /// Brightness rather than an overlay, so it works over a material, a paper ground,
        /// and a tinted keycap without any of them needing to know about it.
        private var brightness: Double {
            guard motion.fades else { return 0 }
            if configuration.isPressed { return -0.04 }
            return hovering ? 0.06 : 0
        }
    }
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
