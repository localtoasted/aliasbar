import AppKit

// MARK: - Dialect

/// What FIND assumes you are about to reach for: a shell entry (alias/function) or a
/// stored prompt. Never a filter — both kinds are always searchable — only a fixed
/// ordering boost toward whichever one the frontmost app suggests.
enum Dialect: Hashable {
    case shell, prompt
}

// MARK: - Context detection

/// Guesses `Dialect` from the bundle identifier of whatever app was frontmost before
/// AliasBar opened, and produces the one-line copy that explains the guess.
///
/// This is the privacy boundary in full: a bundle ID, looked up in a fixed table, and
/// nothing else. No tab, no window title, no accessibility inspection of any kind —
/// AliasBar cannot see what you were doing in that app, only which app it was. That is
/// deliberately a weaker signal than it could gather, in exchange for never having to
/// say what it looked at.
///
/// The table below is a snapshot, not a live catalog: bundle IDs of terminals, AI
/// clients, and browsers change as those apps ship new versions, and new entrants show
/// up in this business all the time. Treat a wrong or missing guess as this table
/// having drifted, not as a bug in the lookup — the fix is always here, never in the
/// call site.
enum ContextDetector {
    /// Snapshot date for the tables below.
    static let tableVersion = "2026-07-26"

    struct Guess {
        /// nil when the app gives no basis for a guess at all (an unrecognized app) —
        /// distinct from a browser's nil, which has a reason worth stating in `chip`.
        let dialect: Dialect?
        let chip: String?
    }

    /// Shells-in-a-window. A terminal is the strongest signal FIND gets: someone who
    /// just alt-tabbed out of one is about to type a command, not compose a prompt.
    private static let terminals: [String: String] = [
        "com.googlecode.iterm2": "iTerm2",
        "com.apple.Terminal": "Terminal",
        "dev.warp.Warp-Stable": "Warp",
        "net.kovidgoyal.kitty": "kitty",
        "com.github.wez.wezterm": "WezTerm",
        "org.alacritty": "Alacritty",
        "com.mitchellh.ghostty": "Ghostty",
    ]

    /// AI-native surfaces: chat and editor apps whose whole point is prompting a
    /// model, so a prompt is the more likely reach.
    private static let aiNative: [String: String] = [
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.chat": "ChatGPT",
        "com.todesktop.230313mzl4w4u92": "Cursor",
    ]

    /// Browsers give no dialect signal at all — a tab could be either kind of work —
    /// but they are common enough, and the "why don't you know" question predictable
    /// enough, that they earn an explicit chip saying so instead of silence.
    private static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.apple.Safari": "Safari",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Edge",
    ]

    /// The pure core: a bundle ID in, a guess out. Every fixture in this table is
    /// testable through here without touching AppKit or a running process.
    static func guess(forBundleID bundleID: String?) -> Guess {
        guard let bundleID else { return Guess(dialect: nil, chip: nil) }
        if let name = terminals[bundleID] {
            return Guess(dialect: .shell, chip: "over \(name) → shell first")
        }
        if let name = aiNative[bundleID] {
            return Guess(dialect: .prompt, chip: "over \(name) → prompt first")
        }
        if let name = browsers[bundleID] {
            return Guess(dialect: nil, chip: "\(name) — can't see the tab · ⇥ flips")
        }
        return Guess(dialect: nil, chip: nil)
    }

    /// The one real call site: reads the bundle ID off whatever `NSRunningApplication`
    /// AliasBar already remembered as the previously-frontmost app, so nothing else in
    /// this type ever has to ask the system anything itself.
    static func guess(for app: NSRunningApplication?) -> Guess {
        guess(forBundleID: app?.bundleIdentifier)
    }
}

// MARK: - Shortcut ranking (FIND only)

/// Ranks FIND's pool — the shell entries plus the whole prompt library — as one
/// ordered list.
///
/// Two scoring regimes share one pool, because the two kinds of thing being searched
/// have different fields worth matching: shell entries by name/comment/command exactly
/// as `Ranker` already scores them, prompts by name/description/body. Below two typed
/// characters, `dialect` gets first look — the guess is doing the useful work of
/// surfacing the likely kind without hiding the other one; at two or more, the guess
/// steps aside and lets relevance decide on its own, because by then the user's own
/// keystrokes know more than the frontmost app did.
enum ShortcutRanker {
    /// `Shortcut`'s shell-shaped fields, scored through `Ranker.shellFieldScore` —
    /// the exact same numeric ladder (500_000 down to 100_000) `Ranker` itself uses
    /// for `ShellEntry`, which is what lets a mixed shell+prompt list sort as one
    /// ladder instead of two that happen to interleave. One scoring implementation,
    /// shared rather than duplicated: this used to keep its own copy of the same five
    /// numbers, which was one edit away from silently drifting out of sync with
    /// `Ranker`'s.
    private static func shellTier(_ shortcut: Shortcut, query: String, scope: SearchScope) -> Int? {
        Ranker.shellFieldScore(name: shortcut.name.lowercased(),
                              comment: (shortcut.comment ?? "").lowercased(),
                              command: shortcut.body.lowercased(),
                              query: query, scope: scope)
    }

    /// Prompts have no `scope` setting of their own — that control is about which
    /// shell fields a search is allowed to reach into, and a prompt's description and
    /// body aren't shell fields — so a prompt is always matched across all three of
    /// its fields regardless of what `scope` says.
    private static func promptTier(_ shortcut: Shortcut, query: String) -> Int? {
        let name = shortcut.name.lowercased()
        let description = (shortcut.description ?? "").lowercased()
        let body = shortcut.body.lowercased()

        if name == query { return 500_000 }
        if name.hasPrefix(query) { return 400_000 }
        if name.contains(query) { return 300_000 }
        if description.contains(query) { return 200_000 }
        if body.contains(query) { return 100_000 }

        return nil
    }

    private static func matchesDialect(_ shortcut: Shortcut, _ dialect: Dialect) -> Bool {
        switch dialect {
        case .shell: return shortcut.kind == .alias || shortcut.kind == .function
        case .prompt: return shortcut.kind == .prompt
        }
    }

    /// `pool` is every shortcut FIND is allowed to show — shell and prompt alike,
    /// unfiltered by dialect. An empty query returns the whole pool in the same rest
    /// order `Ranker.rank` uses (usage, then name), with the dialect boost applied on
    /// top the same as any other query length under two characters.
    static func rank(_ pool: [Shortcut],
                     query: String,
                     scope: SearchScope,
                     dialect: Dialect) -> [Shortcut] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        // "Two typed letters override the guess": at zero or one, the boost still
        // applies; at two, it stops.
        let boostActive = q.count < 2

        let scored: [(Shortcut, Int)]
        if q.isEmpty {
            scored = pool.map { ($0, 0) }
        } else {
            scored = pool.compactMap { shortcut -> (Shortcut, Int)? in
                let tier: Int?
                switch shortcut.kind {
                case .alias, .function: tier = shellTier(shortcut, query: q, scope: scope)
                case .prompt: tier = promptTier(shortcut, query: q)
                }
                return tier.map { (shortcut, $0) }
            }
        }

        return scored.sorted { lhs, rhs in
            if boostActive {
                let lhsBoost = matchesDialect(lhs.0, dialect)
                let rhsBoost = matchesDialect(rhs.0, dialect)
                if lhsBoost != rhsBoost { return lhsBoost }
            }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.uses != rhs.0.uses { return lhs.0.uses > rhs.0.uses }
            // Shorter names win at equal relevance, matching `Ranker`.
            if lhs.0.name.count != rhs.0.name.count {
                return lhs.0.name.count < rhs.0.name.count
            }
            return lhs.0.name < rhs.0.name
        }.map(\.0)
    }
}
