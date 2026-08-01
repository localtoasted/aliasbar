# Changelog

Notable changes to AliasBar. Newest first.

## Unreleased

The bundle version reads 0.3. Everything below has landed since the `v0.2` tag.

### Fixed

- **A delete could report success without deleting.** If your `.zshrc` contained a legacy
  multi-line alias — one whose value is held together by quotes across several physical
  lines — the lines *inside* that value were treated as alias definitions in their own
  right. Deleting one of these phantom aliases rewrote the enclosing alias instead, and the
  app said "Deleted". Every existing guard passed: removing a line from inside a quoted
  string leaves perfectly valid zsh, so the `zsh -n` syntax check had nothing to object to.
  All three places that locate an alias by name now agree on which physical lines are real
  definitions, and they read the same region of the file so they cannot disagree. Where an
  edit genuinely cannot be made safely, you now get an explicit refusal naming the alias
  instead of a false success. (PRE-288)

- **The "this name shadows a command on your PATH" warning could go silent.** Two separate
  causes, both fixed. Names differing only in case from a real binary (`rez` against
  `/usr/bin/Rez`) were not matched, and neither were names involving non-ASCII characters
  where macOS compares filenames more loosely than a plain lowercase comparison does. The
  same defect could also make the warning name the wrong directory — a binary your shell
  would not actually run.

- **Suggested could stop updating, permanently.** If `~/.zsh_history` is a symbolic link
  into a dotfiles repo, the freshness check looked at the link rather than the file it
  points at. Because the link's own timestamp never moves, MANAGE › Suggested stopped
  noticing anything you ran, for as long as the app stayed open — which for a menu-bar app
  is weeks. The same class of bug affected the PATH scan for anyone whose `PATH` contains a
  symlinked directory such as `~/bin -> ~/dotfiles/bin`.

- **Status-bar placement problems are diagnosed again.** The check that detects an icon
  pushed off-screen, hidden under the notch, or swallowed by a menu-bar manager had been
  gated behind a condition that was the opposite of what it needed, so a genuinely
  mis-placed icon was never diagnosed and four of the five automatic rescue positions were
  never tried.

- **Pressing Return always pastes again.** The default Enter action had become conditional,
  and every path that declined to paste did so silently with the palette already dismissed.

- **File pickers block the app again.** Open and Save panels had become window-modal, which
  among other things allowed first-run onboarding to be advanced while its own file panel
  was still open.

- **⌘E on a prompt reads the current registry** rather than a snapshot that could be stale.

### Performance

- **Typing in the Composer is measurably cheaper.** Name validation checks your `PATH` on
  every keystroke; that scan now reads each directory once and re-reads only the
  directories that actually changed, using a single `stat` per directory instead of a call
  that built a fifteen-key dictionary including user- and group-name lookups. Measured over
  a 32-directory `PATH`: 21 µs per directory against 396 µs.

- **The theme is computed once instead of on every read.** Deriving it runs roughly 200
  colour-space conversions, and it was an unmemoized computed property read dozens of times
  per frame region. This is the largest visible rendering win in the release.

- **Conflict detection no longer walks the whole `PATH` per entry.** A 200-entry rc file
  over a 20-directory `PATH` was 4,000 filesystem calls on the way to showing the window.

### Changed

- Prompt and alias status lookups are cached against the registry file's own modification
  time and size, so an install made by another copy of AliasBar or a synced `~/.aliasbar`
  still shows up the next time the pane draws.
- Opening straight to Settings on launch no longer waits on the status item, which it never
  depended on.

### Internal

These do not change what the app does, but they change what a contributor sees.

- **`./test.sh` now runs the SwiftPM test target.** It previously did not, which meant an
  entire XCTest suite covering the shell lexer and the writer's error identities compiled
  nowhere and ran never — `./test.sh` would print "All test suites passed." over a
  regression in either of them. If XCTest is unavailable (Command Line Tools without a full
  Xcode install) the leg is skipped **loudly**, naming the suites that did not run.
- Compiler flags are declared once in `tools/swift-flags.sh` and shared by `build.sh`,
  `test.sh` and `tools/release-cli.sh`. The release build previously used a different
  language mode from the builds that test the same source, so the `ab` CLI could build and
  test clean and then fail at release time.
- `-strict-concurrency=targeted` is enforced on every target; the `ab` CLI builds under the
  full Swift 6 language mode in all three of its builds, including the shipped one.
- The 627-line `AliasWriter.rewrite` is decomposed, and MANAGE's list/detail primitives and
  the appearance-token editor are shared rather than duplicated.
- Test coverage: 2,239 → 2,448 writer assertions, 33 → 101 unit tests, 55 CLI integration
  checks unchanged.

### Known issues

- `ab add --comment` is accepted but the comment is discarded (PRE-289).
- If the managed block contains the same alias name twice, an edit rewrites the first
  occurrence while zsh resolves the last (PRE-290).

## 0.3 — 2026-07-26

Large feature cycle, not separately tagged. Headlines: typed clipboard history with
transforms and secret quarantine, the prompt library with Claude Code delivery, the prompt
inbox and review flow, snippets and inline expansion, file-based settings sync, the
design-token appearance system replacing fixed themes, first-run onboarding with an
auto-update choice, and Sparkle-based updates. `AppState` was split into dedicated
clipboard, inbox and composer state objects.

## 0.2 — 2026-07-25

Initial tagged release.
