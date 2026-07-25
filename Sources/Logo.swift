import SwiftUI
import AppKit

/// The AliasBar mark.
///
/// The idea: an alias is a short name standing in for a long command. So the mark is a
/// prompt caret pointing at a bar that is deliberately *shorter* than the one above it.
/// Long command in, short name out. It reads as a terminal prompt at a glance and as a
/// compression symbol on a second look, and it survives being drawn at 16pt in a menu
/// bar, which is where it actually has to work.
///
/// Drawn rather than shipped as an asset so it inherits the active theme and stays crisp
/// at any size, including in the status bar as a template image.
struct AliasBarMark: View {
    var size: CGFloat = 32
    /// Overrides the theme accent, for contexts that need a fixed colour.
    var tint: Color?
    var monochrome = false

    @Environment(\.theme) private var theme

    private var accent: Color { tint ?? theme.accent }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    monochrome
                        ? AnyShapeStyle(Color.clear)
                        : AnyShapeStyle(LinearGradient(
                            colors: [accent, accent.opacity(0.72)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                )

            MarkGlyph()
                .stroke(monochrome ? Color.primary : Color.white,
                        style: StrokeStyle(lineWidth: size * 0.088,
                                           lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.56, height: size * 0.44)
        }
        .frame(width: size, height: size)
    }
}

/// The glyph itself, in a unit box: a caret, a long rule, and a short rule beneath it.
struct MarkGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()

        // The caret: >
        path.move(to: CGPoint(x: w * 0.02, y: h * 0.06))
        path.addLine(to: CGPoint(x: w * 0.34, y: h * 0.38))
        path.addLine(to: CGPoint(x: w * 0.02, y: h * 0.70))

        // The long rule: the command you wrote.
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.24))
        path.addLine(to: CGPoint(x: w * 1.00, y: h * 0.24))

        // The short rule: the name it compresses to.
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.76))
        path.addLine(to: CGPoint(x: w * 0.80, y: h * 0.76))

        return path
    }
}

// MARK: - Menu bar rendering

enum StatusIcon {
    /// Renders the mark as a template image for the menu bar.
    ///
    /// A template image is drawn by AppKit in whatever colour the menu bar needs, which
    /// is the only way to look right in both light and dark and while the bar is
    /// highlighted. That means it must be pure alpha, so the glyph is stroked in black
    /// with no background plate.
    static func make(height: CGFloat = 17) -> NSImage {
        let width = height * 1.18
        let image = NSImage(size: NSSize(width: width, height: height))

        image.lockFocus()
        defer { image.unlockFocus() }

        let glyphWidth = width * 0.86
        let glyphHeight = height * 0.62
        let originX = (width - glyphWidth) / 2
        let originY = (height - glyphHeight) / 2

        let path = NSBezierPath()
        let w = glyphWidth
        let h = glyphHeight

        // AppKit's origin is bottom-left, so the vertical positions are mirrored
        // relative to the SwiftUI shape above.
        path.move(to: NSPoint(x: originX + w * 0.02, y: originY + h * 0.94))
        path.line(to: NSPoint(x: originX + w * 0.32, y: originY + h * 0.50))
        path.line(to: NSPoint(x: originX + w * 0.02, y: originY + h * 0.06))

        path.move(to: NSPoint(x: originX + w * 0.48, y: originY + h * 0.76))
        path.line(to: NSPoint(x: originX + w * 1.00, y: originY + h * 0.76))

        path.move(to: NSPoint(x: originX + w * 0.48, y: originY + h * 0.20))
        path.line(to: NSPoint(x: originX + w * 0.78, y: originY + h * 0.20))

        path.lineWidth = max(1.4, height * 0.105)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.black.setStroke()
        path.stroke()

        image.isTemplate = true
        return image
    }
}

// MARK: - App icon

enum AppIconRenderer {
    /// Renders the mark at a given pixel size for use as an .icns source.
    ///
    /// Kept in the app rather than as a checked-in binary so the icon can never drift
    /// from the mark shown inside the UI.
    static func render(size: CGFloat, scale: CGFloat = 1) -> Data? {
        let pixel = size * scale
        let view = NSHostingView(
            rootView: AliasBarMark(size: pixel, tint: Color(red: 0.416, green: 0.451, blue: 0.902))
                .environment(\.theme, Theme.current(.slate))
        )
        view.frame = NSRect(x: 0, y: 0, width: pixel, height: pixel)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
