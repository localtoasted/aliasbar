import SwiftUI

/// The colour tokens shared by onboarding and the full appearance editor.
struct AppearanceColourRows: View {
    @Binding var appearance: Appearance

    var body: some View {
        Group {
            SettingsRow("Background",
                        hint: "Sets the main background color.") {
                ColourWell(colour: $appearance.ground)
            }
            SettingsRow("Accent", hint: nil) {
                ColourWell(colour: $appearance.accent)
            }
            SettingsRow("Alias colour", hint: nil) {
                ColourWell(colour: $appearance.aliasTint)
            }
            SettingsRow("Function colour", hint: nil) {
                ColourWell(colour: $appearance.functionTint)
            }
        }
    }
}

/// The font and shape tokens shared by onboarding and the full appearance editor.
/// The two surfaces deliberately keep their existing wording at the call site.
struct AppearanceTypeAndShapeRows: View {
    @Environment(\.theme) private var theme
    @Binding var appearance: Appearance
    let nameFontTitle: String
    let nameFontHint: String?
    let translucencyHint: String?

    var body: some View {
        Group {
            SettingsRow("Interface", hint: nil) {
                ThemedSegments(selection: $appearance.uiFont,
                               options: FontChoice.allCases,
                               label: { $0.label })
            }
            SettingsRow(nameFontTitle, hint: nameFontHint) {
                ThemedSegments(selection: $appearance.nameFont,
                               options: FontChoice.allCases,
                               label: { $0.label })
            }
            SettingsRow("Corner radius", hint: nil) {
                HStack(spacing: 8) {
                    Slider(value: $appearance.cornerRadius, in: 0...14, step: 1)
                        .frame(width: 160)
                    Text("\(Int(appearance.cornerRadius))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.dim)
                        .frame(width: 20, alignment: .trailing)
                }
            }
            SettingsRow("Translucency", hint: translucencyHint) {
                HStack(spacing: 8) {
                    Slider(value: $appearance.translucency, in: 0...1)
                        .frame(width: 160)
                    Text("\(Int(appearance.translucency * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.dim)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }
}

enum AppearancePresetNaming {
    static func suggestedName(for appearance: Appearance,
                              among presets: [Appearance]) -> String {
        let base = appearance.isBuiltIn ? "\(appearance.name) mine" : appearance.name
        let taken = Set(presets.map(\.name))
        if !taken.contains(base) { return base }
        for n in 2...99 where !taken.contains("\(base) \(n)") { return "\(base) \(n)" }
        return base
    }
}

/// A colour, editable, shown as the hex the user can copy out.
///
/// The hex field is not decoration. Colours arrive from other places — a brand guide, a
/// terminal theme, a screenshot someone eyedropped — and typing six characters is faster
/// than steering a colour wheel to a value you already know.
struct ColourWell: View {
    @Environment(\.theme) private var theme
    @Binding var colour: HexColor
    @State private var typed: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(
                get: { colour.color },
                set: { newValue in
                    if let converted = NSColor(newValue).usingColorSpace(.sRGB) {
                        colour = HexColor(red: Double(converted.redComponent),
                                          green: Double(converted.greenComponent),
                                          blue: Double(converted.blueComponent))
                    }
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 44)

            TextField("#000000", text: $typed)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text)
                .focused($editing)
                .frame(width: 76)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .strokeBorder(theme.rule.opacity(0.6), lineWidth: 1))
                .onSubmit { commit() }
                .onChange(of: editing) { focused in if !focused { commit() } }
                .onAppear { typed = colour.hex }
                // While the field has focus the user is mid-typing and half a hex string
                // is not a colour; only mirror the well back into it when they are done.
                .onChange(of: colour) { new in if !editing { typed = new.hex } }
        }
    }

    private func commit() {
        if let parsed = HexColor(hex: typed) {
            colour = parsed
        }
        typed = colour.hex
    }
}
