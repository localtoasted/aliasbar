# AliasBar `>_`

**Every alias and shell function you've ever written, one keystroke away.**

You wrote the perfect alias six months ago. Now you're grepping `.zshrc` trying to remember what you called it.

That's the actual problem: an alias is a compression artifact, and the key to retrieving it is your memory of having made it. Compression outpaces recall. AliasBar hits `⌥⌘A`, you type two letters, and the name lands in your terminal.

![AliasBar](docs/launch.gif)

## Three views, no more

**Find** — the default, and the one you'll live in. Search field already focused, results ranked exact name → prefix → substring → comment → command, with how often you've actually run each one breaking ties. Capped at six on purpose: past that you're reading a list, and reading is slower than typing one more character.

**Board** — every alias at once as a keycap grid. Names are two to four characters, so a list shows eight where a grid shows fifty. Typing *dims* non-matches instead of removing them, so the grid never reflows and you can learn where things live.

**Manage** — sidebar, list, detail. Buckets for functions, aliases, most used, **never run**, by file, and **conflicts**. This is where you find out that alias you wrote in 2023 has never once been executed.

![Board and Manage](docs/manage.png)

## What it tells you that you didn't know

- **The graveyard** — everything you've defined and never actually run, from your real shell history.
- **Conflicts** — the same name defined twice (zsh keeps the last one, the earlier ones are dead code), an alias shadowing a real binary on your `PATH` (*"why is `ls` weird on this machine?"*), or an alias and a function fighting over a name (the alias always wins).

## Completely mouseless

| | |
|---|---|
| `⌥⌘A` | open from anywhere |
| type | filter |
| `↑` `↓` or `⌃n` `⌃p` | move |
| `⏎` | primary action |
| `⌘⏎` | the other one |
| `⌘1` `⌘2` `⌘3` | Find / Board / Manage |
| `?` `!` `@` `#` | jump straight to graveyard / conflicts / by file / stats |
| `⌘N` `⌘E` | new alias, edit alias |
| `⌘,` | settings |
| `esc` | dismiss **and hand focus back to the app you came from** |

**No permission prompts for any of that.** The global hotkey uses the system hotkey API, so AliasBar is told only that one specific combination fired — never any other keystroke. Auto-paste and inline expansion (below) are the two features that do need a permission; both ask for it, and both stay off — actually off, nothing constructed — until you grant it.

## Enter does what you tell it to

By default, picking an alias **types it straight into whatever you were doing** — terminal, editor, wherever focus returns. That's the point: you were about to type it yourself.

It's a setting, because this is a developer tool:

- **Enter** — type the name, type the command, copy the name, or copy the command
- **Afterwards** — close, or stay open
- Plus: default view, search scope, sort order, board density, result cap, which of aliases/functions to show, and the rc file path

Auto-paste needs Accessibility permission. Without it AliasBar copies instead and says so, so it never silently does nothing.

## Writing aliases

`⌘N` writes into a marked block in your rc file:

```sh
# >>> aliasbar managed block >>>
# Edited by AliasBar. Anything outside these markers is never touched.
alias gs='git status -sb'
# <<< aliasbar managed block <<<
```

This is the only code in AliasBar that modifies anything, so it's the part that's actually tested:

- Only ever rewrites between its own markers. Every byte outside is preserved.
- Atomic — temp file, then `rename`. An interrupted write can't leave you with half a `.zshrc`.
- Timestamped backup before every write, permissions preserved.
- Refuses to write at all if the markers are duplicated, unbalanced, or reversed, rather than guessing.
- Won't touch a name defined outside its block. It tells you where that definition is instead.
- Validates names and quotes commands correctly, including embedded single quotes.

61 tests cover it, including round-trips through the real `zsh` binary. Run them with `./test.sh`.

## Snippets & inline expansion

Manage → Snippets holds short triggers (`;sig`, `;addr`, whatever you like) that expand into a saved template, with `{{holes}}` for the parts that change — the same double-brace grammar the prompt side of the app uses for its own `{{slots}}`.

By itself, a snippet is just something stored. **Inline expansion** — typing a trigger anywhere on the Mac and having it expand automatically, in whatever app has focus — is a separate, off-by-default toggle in Settings → Expansion. Turn it on and AliasBar watches a rolling buffer no longer than your longest trigger, compared against your snippets in memory as each character arrives. It is never written to disk. It is never watched at all while the toggle is off — not a disabled watcher sitting idle, nothing constructed. And it fails closed: a password field or anything else macOS marks as secure input is always excluded, checked before every keystroke with no setting of its own; if the underlying watcher itself is ever interrupted by the system, expansion turns back off rather than carry on in some half-working state.

Expanding a trigger deletes exactly what you typed and pastes the result the same way an alias delivery does — through the clipboard, with whatever was already there restored right after. A snippet with holes opens a small fill-in prompt first; cancelling it retypes the trigger exactly as written, so you're always left exactly where you were.

## Themes

Graphite, Clay, or Ultramarine.

## Why it's small

Swift and SwiftUI hosted in an AppKit `NSStatusItem` popover. Zero dependencies, no Electron, no helper daemons, **no network access at all**. It reads two files on your disk: your rc file, and `~/.zsh_history` for usage counts. Neither is ever written to or sent anywhere.

## It tells you when macOS hides it

On a full menu bar, especially on notched MacBooks, macOS will silently place a new status item under the camera housing where it cannot be drawn. AliasBar measures its own position against the drawable region at launch, tries to reposition itself, and if it still can't get a visible slot it *says so* instead of running invisibly forever. Diagnostics land in `~/Library/Logs/AliasBar-diag.log`.

## Install

Requires macOS 13+ and Xcode Command Line Tools.

```sh
git clone https://github.com/localtoasted/aliasbar.git
cd aliasbar
./build.sh --install
open ~/Applications/AliasBar.app
```

`build.sh` compiles `Sources/*.swift` and assembles a signed app at
`.build/AliasBar.app` without changing `~/Applications`. Pass `--install` to replace
`~/Applications/AliasBar.app` with the completed build.

Just want `ab`, the command-line tool, without the menu-bar app? Install it via Homebrew:

```sh
brew install localtoasted/aliasbar/aliasbar
```

## Configuration

AliasBar reads `~/.zshrc` by default. Point it elsewhere in Settings → Content, or seed it on first launch:

```sh
ALIASBAR_ZSHRC=~/.config/zsh/.zshrc open ~/Applications/AliasBar.app
```

The chosen path is stored in preferences, so it survives a reboot and applies when AliasBar launches at login. (An environment variable alone would not: a login item doesn't inherit the environment of the session that registered it.)

## Roadmap

- [ ] Sourced-file support (`source ~/.aliases`)
- [ ] Bash and fish
- [ ] Run an alias directly in a terminal tab

## License

MIT
