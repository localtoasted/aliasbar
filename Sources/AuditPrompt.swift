import Foundation

/// Generates the ⌘I "audit my prompts" text — a prompt a human hands to an AI agent
/// (Claude Code locally, or any web chat) so it can review the existing prompt library
/// and propose new/updated/merged prompts back as strict JSON, for a human to accept
/// or reject one item at a time in `PromptInbox`.
///
/// `generate` builds this fresh from whatever library is passed in — there is no
/// static template with a manifest spliced into it — so a prompt that already exists
/// can never be silently missing from what the agent is told about. That property is
/// what the tests hold this file to.
enum AuditPrompt {
    /// Where the agent should put its answer, matching the two places PRE-265's
    /// inbox has to work from: an agent with its own filesystem access, or a web
    /// chat that can only reply in its own window.
    enum Ending {
        /// The agent can write files directly (Claude Code, Codex, etc.): told to
        /// write its JSON straight into the untrusted inbox for later review.
        case localAgent
        /// A web chat with no filesystem access: told to reply with one JSON code
        /// block a human copies out by hand into the inbox.
        case web
    }

    /// Body characters kept in the manifest digest before truncating with an
    /// ellipsis — enough to recognize the prompt, not so much that a library of any
    /// real size makes the generated prompt unwieldy.
    private static let digestLength = 200

    static func generate(library: [Prompt], ending: Ending) -> String {
        var out = "You are auditing an existing library of reusable prompts for AliasBar.\n\n"
        out += "## Existing library\n\n"
        if library.isEmpty {
            out += "(The library is currently empty. There is nothing to avoid re-suggesting.)\n\n"
        } else {
            for prompt in library.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                out += manifestLine(for: prompt) + "\n"
            }
            out += "\n"
        }
        out += instructions
        out += "\n\n"
        out += endingText(ending)
        return out
    }

    /// One manifest row: name, description (or a stand-in noting it has none), and a
    /// one-line digest of the body. Kept as plain text rather than JSON — this whole
    /// document is a prompt for an AI reader, not a machine-parsed format.
    private static func manifestLine(for prompt: Prompt) -> String {
        let description = prompt.description ?? "(no description)"
        return "- \(prompt.name) — \(description) — \(digest(of: prompt.body))"
    }

    private static func digest(of body: String) -> String {
        let collapsed = body
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        guard collapsed.count > digestLength else { return collapsed }
        let cut = collapsed.index(collapsed.startIndex, offsetBy: digestLength)
        return String(collapsed[..<cut]) + "…"
    }

    private static let instructions = """
    ## Your task

    Review the library above against how these prompts are actually used, and propose \
    changes. Follow these rules exactly:

    1. Never re-suggest a prompt that already exists in the library above — matching by \
    name or by near-identical purpose — even under a slightly different name.
    2. If a prompt's usage has drifted from what it currently says, propose an update: \
    the item must carry both the existing prompt's name (as "replaces") and the full new \
    body, so the change is reviewable rather than a bare replacement.
    3. If two or more existing prompts are near-duplicates of each other, propose merging \
    them into one survivor rather than leaving both in place.
    4. Output STRICT JSON matching this schema, and nothing else besides what the output \
    instructions below ask for — no prose outside the required output, no markdown fences \
    unless the ending below specifically asks for one:

    {
      "items": [
        {
          "type": "new" | "update" | "merge",
          "name": "the prompt's name — letters, digits, - and _ only",
          "description": "optional one-line description",
          "body": "the full prompt body",
          "replaces": "for type=update only: the existing prompt name this replaces",
          "merges": ["for type=merge only: the existing prompt names being merged into this survivor"]
        }
      ]
    }

    Every item you propose is reviewed and decided on individually by a human before \
    anything is written to the real library — nothing you produce here is applied \
    automatically, and no batch of items is accepted or rejected as a group.
    """

    private static func endingText(_ ending: Ending) -> String {
        switch ending {
        case .localAgent:
            return """
            ## Output

            Write your JSON to a new file at `~/.aliasbar/inbox/<short-descriptive-name>.json` \
            (creating the `inbox` directory first if it doesn't exist yet). Choose a filename \
            that won't collide with anything already in that directory. Don't write anywhere \
            else, and don't modify any existing file in that directory.
            """
        case .web:
            return """
            ## Output

            Reply with exactly one JSON code block containing your proposal, matching the \
            schema above, and nothing else in your reply.
            """
        }
    }
}
