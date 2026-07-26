import SwiftUI

// MARK: - FIND: clipboard source (PRE-247-C/D)

/// FIND's third source: `ClipboardMonitor`'s history, newest first, with a
/// two-pane list+preview layout mirroring `PromptFindPreviewLayout` — left is the
/// clip list (plus the quarantine summary row, when anything is quarantined right
/// now), right is the selected clip's raw content and its `ClipTransformer` actions.
///
/// Three distinct states, each a full-width screen rather than a half-empty pane:
/// monitoring off (teach + one-keypress Enable), monitoring on with nothing
/// captured yet, and monitoring on with something to show.
struct ClipboardFindView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme
    @Namespace private var highlight
    @Environment(\.motion) private var motion

    var body: some View {
        Group {
            if !settings.clipboardMonitoring {
                disabledState
            } else if state.clipboardRows.isEmpty && state.activeQuarantine.isEmpty {
                EmptyStateView(
                    symbol: "doc.on.clipboard",
                    title: state.query.isEmpty
                        ? "Nothing copied yet"
                        : "Nothing matches \"\(state.query)\"",
                    hint: state.query.isEmpty
                        ? "Copy something, anywhere, and it shows up here."
                        : "Esc clears the search.")
            } else {
                HStack(spacing: 0) {
                    list
                        .frame(width: 268, alignment: .top)
                    Rectangle().fill(theme.rule.opacity(0.5)).frame(width: 1)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Monitoring-off empty state

    /// Teaching copy plus one-keypress Enable — flips `clipboardMonitoring` on and
    /// starts the monitor live (`AppState.enableClipboardMonitoring`); `App.swift`'s
    /// observer is what actually constructs and starts `ClipboardMonitor` the
    /// moment the setting changes, so this button never has to know how.
    private var disabledState: some View {
        VStack(spacing: 16) {
            VStack(spacing: 7) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(theme.faint)
                Text("Clipboard watching is off")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.dim)
            }
            VStack(spacing: 5) {
                Text("Watching starts only when you turn it on.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.dim)
                Text("Secret-shaped clips — tokens, keys, passwords — are recognized and held in memory only. They never touch disk, synced or not.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
            }

            Button {
                state.enableClipboardMonitoring()
            } label: {
                HStack(spacing: 6) {
                    Text("⏎")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.onAccent.opacity(0.85))
                    Text("Enable clipboard watching")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.onAccent)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
            }
            .liveButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 24)
    }

    // MARK: List

    private var list: some View {
        let rows = state.clipboardRows
        return ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if !state.activeQuarantine.isEmpty {
                    QuarantineSummaryRow(clips: state.activeQuarantine)
                        .padding(.bottom, 3)
                }
                if state.query.isEmpty {
                    Text("CLIPBOARD")
                        .font(.system(size: 9, weight: .bold))
                        .kerning(0.7)
                        .foregroundStyle(theme.faint)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, clip in
                    ClipRow(clip: clip, selected: state.selection == index, highlight: highlight)
                        .onTapGesture { state.selection = index }
                        .arriving(index)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .animation(motion(Motion.standard), value: state.selection)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            Group {
                if let clip = state.selectedClip {
                    ClipDetailPane(state: state, clip: clip)
                } else {
                    EmptyStateView(symbol: "doc.text.magnifyingglass",
                                   title: "Nothing selected",
                                   hint: "↑↓ to pick a clip to preview.")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Rows

/// One clip: a `ClipKind` badge (when the content is typed), its first line, and
/// its age. Deliberately no command-line `$` prefix like `HistoryRow` — a clip is
/// not necessarily a shell command.
private struct ClipRow: View {
    @Environment(\.theme) private var theme
    let clip: SafeClip
    let selected: Bool
    let highlight: Namespace.ID

    private var trimmed: String {
        clip.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var firstLine: String {
        trimmed.components(separatedBy: .newlines).first ?? trimmed
    }

    private var kind: ClipKind { ClipKind.detect(trimmed) }

    var body: some View {
        HStack(spacing: 8) {
            if let label = kind.shortLabel {
                Text(label)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(theme.accent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: theme.cornerRadius - 1))
            }
            Text(firstLine)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ClipAgeFormatter.string(from: clip.detectedAt))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(theme.faint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if selected {
                SelectionCapsule(radius: theme.cornerRadius + 1, namespace: highlight)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The quarantine summary: a count and reason names only, hover for the distinct
/// reasons — never the content, and never a tap target. This is the one row in
/// the clipboard source that is deliberately not selectable-to-reveal.
private struct QuarantineSummaryRow: View {
    @Environment(\.theme) private var theme
    let clips: [MemoryClip]

    private var reasonList: String {
        // `QuarantineReason` is `Equatable` but not `Hashable`, so dedup by linear
        // scan rather than a `Set` — the list is at most a handful of reasons long.
        var ordered: [SensitiveContentClassifier.QuarantineReason] = []
        for clip in clips where !ordered.contains(clip.reason) {
            ordered.append(clip.reason)
        }
        return ordered.map(\.description).joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.orange)
            Text("\(clips.count) secret-shaped clip\(clips.count == 1 ? "" : "s") quarantined · gone in ~90s")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.dim)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .help(reasonList)
    }
}

// MARK: - Detail pane

/// The selected clip's raw content, plus every transform `ClipTransformer` offers
/// for it. Highlighting `state.clipActionSelection` is drawn here and nowhere
/// else, so Tab's cycling and what the pane shows can never disagree.
private struct ClipDetailPane: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme
    let clip: SafeClip

    private var actions: [ClipAction] { state.clipboardActions }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(ClipAgeFormatter.string(from: clip.detectedAt))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.faint)
                Spacer(minLength: 0)
            }

            CommandText(command: clip.content, lineLimit: nil, size: 12)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay {
                    if state.clipActionSelection == nil {
                        RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                            .strokeBorder(theme.accent.opacity(0.6), lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    state.clipActionSelection = nil
                    state.performClipboardEnter()
                }

            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TRANSFORMS")
                        .font(.system(size: 9, weight: .bold))
                        .kerning(0.7)
                        .foregroundStyle(theme.faint)
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        ClipActionRow(action: action, selected: state.clipActionSelection == index)
                            .onTapGesture {
                                state.clipActionSelection = index
                                state.performClipboardEnter()
                            }
                    }
                }
            }
        }
    }
}

private struct ClipActionRow: View {
    @Environment(\.theme) private var theme
    let action: ClipAction
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(action.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(action.output.replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.dim)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? theme.selectionFill : theme.surface,
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(selected ? theme.selectionStroke : theme.rule.opacity(0.4),
                          lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}

// MARK: - Small helpers

private extension ClipKind {
    /// A short, presentation-only badge for the list row. `nil` for plain text —
    /// undetected content earns no badge rather than a generic "TXT" one nobody
    /// would read as information.
    var shortLabel: String? {
        switch self {
        case .jwt: return "JWT"
        case .epochTimestamp: return "Epoch"
        case .json: return "JSON"
        case .base64: return "Base64"
        case .urlWithQuery: return "URL"
        case .hexColor: return "Color"
        case .filePath: return "Path"
        case .uuid: return "UUID"
        case .plainText: return nil
        }
    }
}

/// Hand-rolled, coarse relative time for a clip's age — reads fine at a glance and
/// needs no locale-aware formatter for "3m ago"/"2h ago" granularity.
private enum ClipAgeFormatter {
    static func string(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86400))d ago"
        }
    }
}
