import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Model

struct ShellEntry: Identifiable, Hashable {
    enum Kind: String { case alias = "Aliases", function = "Functions" }
    let kind: Kind
    let name: String
    let command: String
    let comment: String?
    var id: String { "\(kind.rawValue)-\(name)" }
}

// MARK: - Parser

enum ZshrcParser {
    static var path: String { NSHomeDirectory() + "/.zshrc" }

    static func parse() -> [ShellEntry] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var entries: [ShellEntry] = []
        let lines = text.components(separatedBy: "\n")
        var pendingComments: [String] = []
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#") {
                pendingComments.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            if line.isEmpty {
                pendingComments.removeAll()
                i += 1
                continue
            }

            if line.hasPrefix("alias ") {
                let rest = String(line.dropFirst("alias ".count))
                if let eq = rest.firstIndex(of: "=") {
                    let name = String(rest[..<eq]).trimmingCharacters(in: .whitespaces)
                    var value = String(rest[rest.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if value.count >= 2,
                       (value.first == "'" && value.last == "'") || (value.first == "\"" && value.last == "\"") {
                        value = String(value.dropFirst().dropLast())
                    }
                    if !name.isEmpty {
                        entries.append(ShellEntry(kind: .alias, name: name, command: value, comment: joined(pendingComments)))
                    }
                }
                pendingComments.removeAll()
                i += 1
                continue
            }

            if let fnName = functionName(in: line) {
                var depth = braceDelta(of: raw)
                var body: [String] = []
                if let braceIdx = raw.firstIndex(of: "{") {
                    let after = raw[raw.index(after: braceIdx)...].trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty && after != "}" { body.append(after) }
                }
                var j = i + 1
                while j < lines.count && depth > 0 {
                    let bodyLine = lines[j]
                    depth += braceDelta(of: bodyLine)
                    if depth > 0 {
                        body.append(bodyLine)
                    } else {
                        let trimmed = bodyLine.trimmingCharacters(in: .whitespaces)
                        if trimmed != "}" && !trimmed.isEmpty { body.append(bodyLine) }
                    }
                    j += 1
                }
                let command = dedent(body).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(ShellEntry(kind: .function, name: fnName, command: command, comment: joined(pendingComments)))
                pendingComments.removeAll()
                i = j
                continue
            }

            pendingComments.removeAll()
            i += 1
        }
        return entries
    }

    private static func joined(_ comments: [String]) -> String? {
        let s = comments.joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    private static func functionName(in line: String) -> String? {
        // name() {   |   function name() {   |   function name {
        if let match = line.range(of: #"^(?:function\s+)?([A-Za-z0-9_.:@+-]+)\s*\(\s*\)\s*\{"#, options: .regularExpression) {
            var header = String(line[match])
            if header.hasPrefix("function") { header = String(header.dropFirst("function".count)) }
            if let paren = header.firstIndex(of: "(") {
                return String(header[..<paren]).trimmingCharacters(in: .whitespaces)
            }
        }
        if let match = line.range(of: #"^function\s+([A-Za-z0-9_.:@+-]+)\s*\{"#, options: .regularExpression) {
            let header = String(line[match]).dropFirst("function".count)
            if let brace = header.firstIndex(of: "{") {
                return String(header[..<brace]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func braceDelta(of line: String) -> Int {
        var delta = 0
        for ch in line {
            if ch == "{" { delta += 1 }
            if ch == "}" { delta -= 1 }
        }
        return delta
    }

    private static func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }
        guard let minIndent = indents.min(), minIndent > 0 else { return lines }
        return lines.map { line in
            line.count >= minIndent ? String(line.dropFirst(minIndent)) : line
        }
    }
}

// MARK: - Store

final class EntryStore: ObservableObject {
    @Published var entries: [ShellEntry] = []
    init() { reload() }
    func reload() { entries = ZshrcParser.parse() }
    var aliases: [ShellEntry] { entries.filter { $0.kind == .alias } }
    var functions: [ShellEntry] { entries.filter { $0.kind == .function } }
}

// MARK: - Theme

enum Theme {
    static let accentGreen = Color(red: 0.35, green: 0.85, blue: 0.45)
    static let functionTint = Color(red: 0.65, green: 0.55, blue: 1.0)
    static let aliasTint = Color(red: 0.35, green: 0.75, blue: 1.0)

    static func badgeGradient(for kind: ShellEntry.Kind) -> LinearGradient {
        let base = kind == .function ? functionTint : aliasTint
        return LinearGradient(colors: [base.opacity(0.95), base.opacity(0.65)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Row

struct EntryRow: View {
    let entry: ShellEntry
    @State private var expanded = false
    @State private var copied = false
    @State private var hovering = false

    private var badgeSymbol: String { entry.kind == .function ? "ƒ" : "@" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 9) {
                Text(badgeSymbol)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Theme.badgeGradient(for: entry.kind))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    if let comment = entry.comment {
                        Text(comment)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 1)
                    }
                }

                Spacer(minLength: 4)

                Button(action: copy) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(copied ? Theme.accentGreen : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(hovering ? 0.08 : 0),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Copy command")
                .opacity(hovering || copied ? 1 : 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }

            if expanded {
                HStack(alignment: .top, spacing: 6) {
                    Text("$")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accentGreen)
                    Text(entry.command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            } else {
                HStack(spacing: 6) {
                    Text("$")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accentGreen.opacity(0.8))
                    Text(entry.command.replacingOccurrences(of: "\n", with: " ⏎ "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 29)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(hovering ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { expanded.toggle() } }
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hovering = h } }
        .help(entry.command)
        .padding(.horizontal, 6)
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.command, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }
}

// MARK: - Main dropdown

struct ContentView: View {
    @ObservedObject var store: EntryStore
    @State private var query = ""
    @State private var showSettings = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var loginItemError: String?
    @FocusState private var searchFocused: Bool

    private func matches(_ e: ShellEntry) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return e.name.lowercased().contains(q)
            || e.command.lowercased().contains(q)
            || (e.comment?.lowercased().contains(q) ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            if showSettings { settings; Divider().opacity(0.5) }
            footer
        }
        .frame(width: 400)
        .background(.ultraThinMaterial)
        .onAppear {
            store.reload()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.reload()
            searchFocused = true
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(">_")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        LinearGradient(colors: [Color(red: 0.18, green: 0.2, blue: 0.25),
                                                Color(red: 0.08, green: 0.09, blue: 0.12)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
                Text("AliasBar")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text("~/.zshrc")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search aliases & functions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                let functions = store.functions.filter(matches)
                let aliases = store.aliases.filter(matches)

                if functions.isEmpty && aliases.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: store.entries.isEmpty ? "doc.questionmark" : "magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text(store.entries.isEmpty ? "Nothing found in ~/.zshrc" : "No matches")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }

                if !functions.isEmpty { section(title: "Functions", tint: Theme.functionTint, entries: functions) }
                if !aliases.isEmpty { section(title: "Aliases", tint: Theme.aliasTint, entries: aliases) }
            }
            .padding(.vertical, 5)
        }
        .frame(minHeight: 120, maxHeight: 440)
    }

    @ViewBuilder
    private func section(title: String, tint: Color, entries: [ShellEntry]) -> some View {
        Section {
            ForEach(entries) { EntryRow(entry: $0) }
        } header: {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .kerning(0.8)
                Text("\(entries.count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(tint.opacity(0.16), in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(.regularMaterial)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: launchAtLogin) { newValue in
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    loginItemError = nil
                } catch {
                    loginItemError = error.localizedDescription
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
            if let err = loginItemError {
                Text(err).font(.system(size: 10)).foregroundStyle(.red)
            }
            Text("Re-reads ~/.zshrc every time the dropdown opens. Click a row to expand · hover for copy.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { withAnimation { store.reload() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                }
                .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Re-read ~/.zshrc now")

            Spacer()

            Text("\(store.functions.count) ƒ · \(store.aliases.count) @")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)

            Spacer()

            Button { withAnimation(.easeOut(duration: 0.15)) { showSettings.toggle() } } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(showSettings ? Color.primary : Color.secondary)
            .help("Settings")

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit AliasBar")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - App

@main
struct AliasBarApp: App {
    @StateObject private var store = EntryStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            Text(">_ \(store.entries.count)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}
