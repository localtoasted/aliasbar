import SwiftUI

// MARK: - BOARD: prompt deck

/// BOARD's second deck: every stored prompt as a card wall, laid out and filtered by
/// exactly the rules the shell keycap deck already established in `Views.swift` —
/// position is spatial memory, so typing dims rather than reflows, and the whole
/// session's prompt set is on screen from the first frame.
///
/// Kept in its own file rather than folded into `BoardView` because the shell deck is
/// frozen ("EXACTLY as today") and a card is different enough from a keycap that
/// sharing one view body would mean branching on almost every line. `BoardView` only
/// routes to this when `state.dialect == .prompt` — everything else about the shell
/// deck is untouched.
struct PromptBoardView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: PromptCardMetrics.width(for: settings.boardDensity)), spacing: 6)]
    }

    var body: some View {
        let prompts = state.boardPrompts
        VStack(spacing: 0) {
            if prompts.isEmpty {
                EmptyStateView(symbol: "text.book.closed",
                               title: "No prompts yet",
                               hint: "Press ⌘N to create one. Press ⇥ for aliases.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(Array(prompts.enumerated()), id: \.element.name) { index, prompt in
                            PromptCard(prompt: prompt,
                                       selected: state.selection == index,
                                       dimmed: !state.boardPromptMatches(prompt),
                                       usage: state.promptUsage(for: prompt.name),
                                       density: settings.boardDensity,
                                       action: {
                                           state.selection = index
                                           state.performBoardPrompt(prompt)
                                       })
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: .infinity)

                Rectangle().fill(theme.rule.opacity(0.5)).frame(height: 1)
                readout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Fixed-height footer, matching the shell deck's own `readout` exactly — same
    /// reasoning: the selection's detail lives here so nothing in the grid moves as the
    /// selection travels.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let prompt = state.selectedPrompt {
                HStack(spacing: 7) {
                    Image(systemName: "text.book.closed.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 15)
                    Text(prompt.name)
                        .font(.system(size: 12.5, weight: .semibold, design: theme.nameDesign))
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 4)
                    let uses = state.promptUsage(for: prompt.name)
                    if uses > 0 {
                        Text("\(uses)×")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(theme.faint)
                    }
                }
                Text(PromptGist.line(for: prompt))
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
            } else {
                Text("Nothing selected")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.faint)
            }
        }
        .frame(height: 54, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One prompt, drawn as a card rather than a keycap: a name, a two-line gist, and two
/// quiet badges (slot count, usage) instead of a keycap's single line.
private struct PromptCard: View {
    @Environment(\.theme) private var theme
    let prompt: Prompt
    let selected: Bool
    let dimmed: Bool
    let usage: Int
    let density: BoardDensity
    let action: () -> Void

    private var slotCount: Int { PromptSlotParser.slots(in: prompt.body).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(prompt.name)
                    .font(.system(size: density == .dense ? 12 : 13,
                                  weight: .semibold, design: theme.nameDesign))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                if slotCount > 0 {
                    Text("\(slotCount)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(theme.accent.opacity(0.85), in: Capsule())
                        .help("\(slotCount) slot\(slotCount == 1 ? "" : "s") to fill in")
                }
            }
            Text(PromptGist.line(for: prompt))
                .font(.system(size: density == .dense ? 9.5 : 10.5))
                .foregroundStyle(theme.dim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if usage > 0 {
                Text("\(usage)×")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(theme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PromptCardMetrics.height(for: density), alignment: .top)
        .padding(8)
        .background(selected ? theme.selectionFill : theme.surface,
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 2))
        // Same two-shadow treatment as a keycap — a tight contact shadow plus a wide
        // ambient one, matching the premium pass rather than inventing a second style.
        .shadow(color: .black.opacity(theme.isLight ? 0.10 : 0.28), radius: 1.5, y: 1)
        .shadow(color: .black.opacity(theme.isLight ? 0.06 : 0.20), radius: 10, y: 5)
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
                .strokeBorder(selected ? theme.selectionStroke : theme.accent.opacity(0.35),
                              lineWidth: selected ? 1.5 : 1)
        )
        .overlay {
            if !theme.isLight {
                RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .clear],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1)
            }
        }
        // Dimming rather than hiding — the invariant this whole deck exists to prove:
        // the grid never reflows, so position stays learnable exactly like the keycaps.
        .opacity(dimmed ? 0.22 : 1)
        .contentShape(Rectangle())
        .live(pressDrop: 1, action: action)
    }
}
