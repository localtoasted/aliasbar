import SwiftUI

// MARK: - Root

struct RootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @FocusState private var searchFocused: Bool

    private var theme: Theme { Theme.current(settings.themeName) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.rule.opacity(0.6)).frame(height: 1)

            Group {
                switch state.mode {
                case .find: FindView(state: state, settings: settings)
                case .board: BoardView(state: state, settings: settings)
                case .manage: ManageView(state: state, settings: settings)
                }
            }
            .frame(maxWidth: .infinity)

            Rectangle().fill(theme.rule.opacity(0.6)).frame(height: 1)
            footer
        }
        .frame(width: state.mode == .manage ? 620 : 440)
        .background(background)
        .environment(\.theme, theme)
        .overlay(alignment: .bottom) { toast }
        .sheet(item: $state.editor) { _ in
            EditorSheet(state: state).environment(\.theme, theme)
        }
        .onAppear { searchFocused = true }
        .onChange(of: state.mode) { _ in searchFocused = true }
        // Re-focus on every open, not just the first. Without this the second summon
        // renders the popover with the field looking focused but swallowing nothing,
        // which is indistinguishable from a broken hotkey.
        .onChange(of: state.showCount) { _ in
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    @ViewBuilder
    private var background: some View {
        if theme.usesMaterial {
            Rectangle().fill(.ultraThinMaterial)
        } else {
            theme.background
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Text(">_")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(theme.isLight ? Color.white : theme.background)
                    .frame(width: 22, height: 20)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: theme.cornerRadius))

                ForEach(ViewMode.allCases) { mode in
                    tab(mode)
                }

                Spacer(minLength: 6)

                Text(ZshrcParser.displayPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
                    // Without both of these a long path (anything not under ~) pushes
                    // the tabs off the left edge instead of truncating itself.
                    .frame(maxWidth: 150, alignment: .trailing)
                    .layoutPriority(-1)
                    .help(ZshrcParser.path)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.dim)
                TextField(searchPrompt, text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: theme.bodyDesign))
                    .foregroundStyle(theme.text)
                    .focused($searchFocused)
                    .onChange(of: state.query) { _ in state.selection = 0 }
                if !state.query.isEmpty {
                    Text("\(state.activeList.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 2))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
                    .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1)
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    private var searchPrompt: String {
        switch state.mode {
        case .find: return "Search aliases and functions"
        case .board: return "Type to highlight"
        case .manage: return "Filter \(state.bucket.label.lowercased())"
        }
    }

    private func tab(_ mode: ViewMode) -> some View {
        let active = state.mode == mode
        return Text(mode.label)
            .font(.system(size: 11, weight: active ? .bold : .medium, design: theme.bodyDesign))
            .foregroundStyle(active ? theme.accent : theme.dim)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(active ? theme.accent.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .strokeBorder(active ? theme.accent.opacity(0.4) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { state.mode = mode; state.selection = 0 }
            .help("\(mode.label) — ⌘\(mode == .find ? "1" : mode == .board ? "2" : "3")")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = state.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
            } else {
                KeyHint(keys: "⏎", label: settings.enterAction.short)
                KeyHint(keys: "⌘⏎", label: settings.enterAction.secondary.short)
                KeyHint(keys: "⌘N", label: "new")
                if state.mode != .manage { KeyHint(keys: "?", label: "graveyard") }
            }

            Spacer()

            Text("\(state.store.functions.count)ƒ \(state.store.aliases.count)@")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.faint)

            Button { state.onOpenSettings?() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 10.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dim)
            .help("Settings — ⌘,")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var toast: some View {
        if let message = state.toast {
            Text(message)
                .font(.system(size: 11, weight: .medium, design: theme.bodyDesign))
                .foregroundStyle(theme.isLight ? Color.white : theme.background)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.accent, in: Capsule())
                .padding(.bottom, 44)
                .transition(.opacity)
        }
    }
}

// MARK: - Small shared pieces

struct KeyHint: View {
    @Environment(\.theme) private var theme
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(keys)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.dim)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(theme.rule.opacity(0.6), lineWidth: 0.5))
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(theme.faint)
        }
    }
}

struct KindBadge: View {
    @Environment(\.theme) private var theme
    let kind: ShellEntry.Kind
    var size: CGFloat = 18

    var body: some View {
        Text(kind == .function ? "ƒ" : "@")
            .font(.system(size: size * 0.6, weight: .bold, design: .monospaced))
            .foregroundStyle(theme.isLight ? Color.white : theme.background)
            .frame(width: size, height: size)
            .background(theme.tint(for: kind),
                        in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
    }
}

/// The command, rendered as a shell line.
struct CommandText: View {
    @Environment(\.theme) private var theme
    let command: String
    var lineLimit: Int? = 1
    var size: CGFloat = 11.5

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Text("$")
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.accent.opacity(0.85))
            Text(lineLimit == 1
                 ? command.replacingOccurrences(of: "\n", with: " ⏎ ")
                 : command)
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(theme.dim)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: lineLimit != 1)
            Spacer(minLength: 0)
        }
    }
}

struct EmptyStateView: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.faint)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.dim)
            Text(hint)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.faint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

// MARK: - FIND

/// The hot path. One answer, large, with the runners-up as compact chips underneath.
///
/// The shape is the argument: the dominant situation is knowing the concept but not the
/// string, so the job is to be confidently right about one thing rather than to present
/// a menu. Anything past the first result is a fallback, and it is drawn like one.
struct FindView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme

    var body: some View {
        let results = state.results
        Group {
            if results.isEmpty {
                if state.query.isEmpty {
                    EmptyStateView(symbol: "doc.text.magnifyingglass",
                                   title: "Nothing in \(ZshrcParser.displayPath)",
                                   hint: "Press ⌘N to write your first alias.")
                } else {
                    EmptyStateView(symbol: "magnifyingglass",
                                   title: "No match for \"\(state.query)\"",
                                   hint: "⌘N turns this into a new alias.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        // At rest there is no answer yet, so nothing gets the primary
                        // treatment. Promoting an arbitrary entry into a big card would
                        // be the interface asserting something it does not know.
                        if state.query.isEmpty {
                            Text(restLabel)
                                .font(.system(size: 9, weight: .bold))
                                .kerning(0.7)
                                .foregroundStyle(theme.faint)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 2)
                        }

                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            if index == 0 && !state.query.isEmpty {
                                PrimaryResult(entry: entry,
                                              selected: state.selection == 0,
                                              conflicts: state.store.conflicts(for: entry.name))
                                    .onTapGesture { state.selection = 0; activate(entry) }
                            } else {
                                AlternateRow(entry: entry, selected: state.selection == index)
                                    .onTapGesture { state.selection = index; activate(entry) }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                }
                .frame(maxHeight: 380)
            }
        }
    }

    /// Names the rest state honestly. With no shell history to rank by, calling the list
    /// "most used" would be a lie.
    private var restLabel: String {
        state.store.mostUsed.isEmpty ? "YOUR ALIASES" : "MOST USED"
    }

    private func activate(_ entry: RankedEntry) {
        state.perform(settings.enterAction, on: entry)
    }
}

private struct PrimaryResult: View {
    @Environment(\.theme) private var theme
    let entry: RankedEntry
    let selected: Bool
    let conflicts: [Conflict]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                KindBadge(kind: entry.entry.kind, size: 20)
                Text(entry.name)
                    .font(.system(size: 17, weight: .semibold, design: theme.nameDesign))
                    .foregroundStyle(theme.text)
                if !conflicts.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(conflicts.map(\.reason.headline).joined(separator: " · "))
                }
                Spacer(minLength: 4)
                if entry.uses > 0 {
                    Text("\(entry.uses)×")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.faint)
                        .help("Run \(entry.uses) times, per your shell history")
                }
            }

            if let comment = entry.entry.comment {
                Text(comment)
                    .font(.system(size: 11.5, design: theme.bodyDesign))
                    .foregroundStyle(theme.dim)
                    .lineLimit(2)
            }

            CommandText(command: entry.entry.command, lineLimit: 4, size: 12)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface,
                            in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? theme.selectionFill : theme.surface.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 3))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius + 3)
                .strokeBorder(selected ? theme.selectionStroke : theme.rule.opacity(0.35),
                              lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
    }
}

private struct AlternateRow: View {
    @Environment(\.theme) private var theme
    let entry: RankedEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            KindBadge(kind: entry.entry.kind, size: 15)
            Text(entry.name)
                .font(.system(size: 12.5, weight: .medium, design: theme.nameDesign))
                .foregroundStyle(theme.text)
            Text(entry.entry.comment ?? entry.entry.command
                    .replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(.system(size: 10.5, design: theme.bodyDesign))
                .foregroundStyle(theme.faint)
                .lineLimit(1)
            Spacer(minLength: 4)
            if entry.uses > 0 {
                Text("\(entry.uses)×")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(theme.faint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? theme.selectionFill : .clear,
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                .strokeBorder(selected ? theme.selectionStroke : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - BOARD

/// Every alias at once, as a keycap grid.
///
/// Alias names are two to four characters, so a list wastes the screen: it shows eight
/// where a grid shows fifty. Typing dims non-matches instead of removing them, which
/// keeps every key in the same place forever. That stability is the whole point: it is
/// what lets you learn where things are instead of re-reading a list that reshuffles on
/// every keystroke.
struct BoardView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: settings.boardDensity.keyWidth), spacing: 6)]
    }

    var body: some View {
        let entries = state.boardEntries
        VStack(spacing: 0) {
            if entries.isEmpty {
                EmptyStateView(symbol: "square.grid.3x3",
                               title: "Nothing to show",
                               hint: "⌘N writes your first alias.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            Keycap(entry: entry,
                                   selected: state.selection == index,
                                   dimmed: !state.boardMatches(entry),
                                   density: settings.boardDensity)
                                .onTapGesture {
                                    state.selection = index
                                    state.perform(settings.enterAction, on: entry)
                                }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 320)

                Rectangle().fill(theme.rule.opacity(0.5)).frame(height: 1)
                readout
            }
        }
    }

    /// Fixed-height footer. The focused key's details go here rather than inline so
    /// nothing in the grid moves as the selection travels.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let entry = state.selectedEntry {
                HStack(spacing: 7) {
                    KindBadge(kind: entry.entry.kind, size: 15)
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: .semibold, design: theme.nameDesign))
                        .foregroundStyle(theme.text)
                    if let comment = entry.entry.comment {
                        Text(comment)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.dim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if entry.uses > 0 {
                        Text("\(entry.uses)×")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(theme.faint)
                    }
                }
                CommandText(command: entry.entry.command, lineLimit: 1, size: 11)
            } else {
                Text("Nothing selected")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.faint)
            }
        }
        .frame(height: 44, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct Keycap: View {
    @Environment(\.theme) private var theme
    let entry: RankedEntry
    let selected: Bool
    let dimmed: Bool
    let density: BoardDensity

    var body: some View {
        VStack(spacing: 1) {
            Text(entry.name)
                .font(.system(size: density == .dense ? 11 : 12.5,
                              weight: .semibold, design: theme.nameDesign))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if density == .comfortable && entry.uses > 0 {
                Text("\(entry.uses)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(theme.faint)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: density.keyHeight)
        .background(selected ? theme.selectionFill : theme.surface,
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 2))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius + 2)
                .strokeBorder(selected ? theme.selectionStroke
                                       : theme.tint(for: entry.entry.kind).opacity(0.35),
                              lineWidth: selected ? 1.5 : 1)
        )
        // Dimming rather than hiding: the grid never reflows, so position stays learnable.
        .opacity(dimmed ? 0.22 : 1)
        .contentShape(Rectangle())
    }
}

// MARK: - MANAGE

/// The cold path, where browsing is the correct behaviour rather than a failure.
struct ManageView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(theme.rule.opacity(0.5)).frame(width: 1)
            list
            Rectangle().fill(theme.rule.opacity(0.5)).frame(width: 1)
            detail
        }
        .frame(height: 400)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Bucket.allCases) { bucket in
                bucketRow(bucket)
            }
            Spacer()
            Button { state.editor = .create() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text("New alias").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(theme.isLight ? Color.white : theme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
            }
            .buttonStyle(.plain)
            .help("New alias — ⌘N")
        }
        .padding(8)
        .frame(width: 158)
    }

    private func bucketRow(_ bucket: Bucket) -> some View {
        let active = state.bucket == bucket
        let count = countFor(bucket)
        return HStack(spacing: 6) {
            Image(systemName: bucket.symbol)
                .font(.system(size: 10))
                .frame(width: 14)
                .foregroundStyle(active ? theme.accent : theme.dim)
            Text(bucket.label)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular,
                              design: theme.bodyDesign))
                .foregroundStyle(active ? theme.text : theme.dim)
            Spacer(minLength: 2)
            Text("\(count)")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(bucket == .conflicts && count > 0 ? .orange : theme.faint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(active ? theme.selectionFill : .clear,
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
        .contentShape(Rectangle())
        .onTapGesture { state.bucket = bucket; state.selection = 0 }
    }

    private func countFor(_ bucket: Bucket) -> Int {
        switch bucket {
        case .all: return state.store.ranked.count
        case .functions: return state.store.functions.count
        case .aliases: return state.store.aliases.count
        case .mostUsed: return state.store.mostUsed.count
        case .neverRun: return state.store.neverRun.count
        case .byFile: return state.store.byFile.count
        case .conflicts: return state.store.conflicts.count
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(state.bucketEntries.enumerated()), id: \.element.id) { index, entry in
                        manageRow(entry, index: index)
                            .id(entry.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: state.selection) { _ in
                guard let entry = state.selectedEntry else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(entry.id, anchor: .center) }
            }
        }
        .frame(width: 200)
    }

    private func manageRow(_ entry: RankedEntry, index: Int) -> some View {
        let selected = state.selection == index
        return HStack(spacing: 6) {
            KindBadge(kind: entry.entry.kind, size: 14)
            Text(entry.name)
                .font(.system(size: 11.5, weight: .medium, design: theme.nameDesign))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 2)
            if entry.entry.managed {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.accent.opacity(0.7))
                    .help("Written by AliasBar, so it can be edited here")
            }
            if entry.uses > 0 {
                Text("\(entry.uses)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.faint)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(selected ? theme.selectionFill : .clear,
                    in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture { state.selection = index }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = state.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        KindBadge(kind: entry.entry.kind, size: 18)
                        Text(entry.name)
                            .font(.system(size: 15, weight: .semibold, design: theme.nameDesign))
                            .foregroundStyle(theme.text)
                        Spacer()
                    }

                    if let comment = entry.entry.comment {
                        Text(comment)
                            .font(.system(size: 11.5, design: theme.bodyDesign))
                            .foregroundStyle(theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    CommandText(command: entry.entry.command, lineLimit: nil, size: 11.5)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surface,
                                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))

                    ForEach(state.store.conflicts(for: entry.name)) { conflict in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                                Text(conflict.reason.headline)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(theme.text)
                            }
                            Text(conflict.reason.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                    }

                    metadata(entry)

                    HStack(spacing: 6) {
                        detailButton("Copy name", "doc.on.doc") {
                            state.perform(.copyName, on: entry)
                        }
                        detailButton("Copy command", "terminal") {
                            state.perform(.copyCommand, on: entry)
                        }
                        Spacer()
                        if entry.entry.managed {
                            detailButton("Edit", "pencil") { state.beginEdit(entry.entry) }
                            detailButton("Delete", "trash") { state.delete(entry.entry) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack {
                EmptyStateView(symbol: state.bucket == .conflicts ? "checkmark.seal" : "tray",
                               title: state.bucket == .conflicts
                                   ? "No conflicts"
                                   : "Nothing in \(state.bucket.label.lowercased())",
                               hint: state.bucket == .neverRun
                                   ? "Everything you've defined has been used at least once."
                                   : "Pick another bucket on the left.")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func metadata(_ entry: RankedEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            metaRow("Source", "\(entry.entry.sourceDisplayName):\(entry.entry.line)")
            metaRow("Runs", entry.uses == 0
                    ? "never, per your shell history"
                    : "\(entry.uses)×")
            metaRow("Managed", entry.entry.managed
                    ? "yes, AliasBar can edit this"
                    : "no, hand-written")
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(theme.faint)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(theme.dim)
            Spacer(minLength: 0)
        }
    }

    private func detailButton(_ title: String, _ symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dim)
    }
}

// MARK: - Editor

struct EditorSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.theme) private var theme
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.editor?.mode == .create ? "New alias" : "Edit alias")
                .font(.system(size: 14, weight: .bold, design: theme.bodyDesign))
                .foregroundStyle(theme.text)

            if let binding = Binding($state.editor) {
                field("Name", binding.name, mono: true, focused: true)
                field("Command", binding.command, mono: true, focused: false)
            }

            Text("Saved into AliasBar's managed block in \(ZshrcParser.displayPath). Everything outside that block is left alone, and a timestamped backup is written first.")
                .font(.system(size: 10))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            if let error = state.errorMessage {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { state.editor = nil; state.errorMessage = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { state.commitEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.editor?.name.isEmpty ?? true
                              || state.editor?.command.isEmpty ?? true)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(theme.usesMaterial ? AnyView(Rectangle().fill(.ultraThinMaterial))
                                       : AnyView(theme.background))
        .onAppear { nameFocused = true }
    }

    private func field(_ label: String, _ text: Binding<String>,
                       mono: Bool, focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(theme.faint)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: mono ? .monospaced : theme.bodyDesign))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.surface,
                            in: RoundedRectangle(cornerRadius: theme.cornerRadius + 1))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 1)
                    .strokeBorder(theme.rule.opacity(0.5), lineWidth: 1))
                .focused($nameFocused, equals: focused)
        }
    }
}
