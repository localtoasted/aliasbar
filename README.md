# AliasBar `>_`

**Every alias and shell function you've ever written, one click away in your macOS menu bar.**

You know the drill: you wrote the perfect alias six months ago, and now you're grepping your `.zshrc` to remember what you called it. AliasBar puts your entire shell vocabulary in the menu bar — searchable, copyable, always fresh.

<!-- screenshot: docs/screenshot.png (add after first build) -->

## Features

- **`>_` in your menu bar** — no dock icon, no window clutter. Pure menu bar app; live counts of functions and aliases sit in the dropdown footer.
- **Real parsing, not `alias` output** — reads `~/.zshrc` directly, so it catches both `alias name='…'` one-liners *and* full `name() { … }` function blocks, including multi-line bodies.
- **It tells you when macOS hides it** — on a full menu bar (especially on notched MacBooks) macOS will silently place a new status item under the camera housing, where it cannot be drawn. AliasBar checks its own position at launch, tries to reposition itself, and if it still can't get a visible slot it says so instead of running invisibly forever.
- **Your comments become docs** — the `# comment` above a definition shows up as its description. Your `.zshrc` was self-documenting all along.
- **Instant search** — the dropdown opens with the search field focused. Type to filter by name, command text, or comment.
- **Click to expand** — long commands truncate to one line; click any row to see the full body in a code block, with text selection enabled.
- **One-click copy** — hover a row, hit the copy button, paste anywhere.
- **Never stale** — re-parses `~/.zshrc` every single time the dropdown opens (plus a manual Refresh button, for the skeptics).
- **Launch at login** — one toggle in settings, via Apple's `SMAppService`. No LaunchAgent hacks.
- **Grouped** — functions (`ƒ`) and aliases (`@`) get their own sections with counts.

## Why it's tiny

One Swift file. Zero dependencies. SwiftUI views hosted in an AppKit `NSStatusItem` popover. No Electron, no helper daemons, no network access — it literally just reads one file on your disk when you click it.

## Configuration

By default AliasBar reads `~/.zshrc`. If your zsh config lives elsewhere, point it there:

```sh
ALIASBAR_ZSHRC=~/.config/zsh/.zshrc open ~/Applications/AliasBar.app
```

Placement diagnostics are written to `~/Library/Logs/AliasBar-diag.log`.

## Install

Requires macOS 13+ and Xcode Command Line Tools.

```sh
git clone https://github.com/localtoasted/aliasbar.git
cd aliasbar
./build.sh
open ~/Applications/AliasBar.app
```

`build.sh` compiles `main.swift`, assembles a proper `.app` bundle (ad-hoc signed), and installs it to `~/Applications`.

## Roadmap

- [ ] Sourced-file support (`source ~/.aliases` etc.)
- [ ] Bash / fish support
- [ ] Global hotkey to open the dropdown
- [ ] Click-to-run in a terminal tab

## License

MIT
