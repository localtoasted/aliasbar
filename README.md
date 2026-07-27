![AliasBar](docs/brand/title.png)

**Aliases and prompts. Ready anywhere.**

Press `⌥⌘A` in any app. Find an alias or prompt, then paste it.

![AliasBar showing aliases and prompts side by side](docs/hero.png)

## Aliases and prompts

| Aliases | Prompts |
|---|---|
| Find any alias or shell function. | Save prompts for ChatGPT, Claude, and other apps. |
| See commands, usage, and conflicts. | Add `{{slots}}` for details that change each time. |
| Create and edit aliases safely. | Use any prompt as a Claude Code `/command`. |

AliasBar reads aliases from `~/.zshrc` and prompts from `~/.aliasbar/prompts/`.

## Three views

- **Find** searches aliases and prompts.
- **Board** shows your library as a grid.
- **Manage** lets you edit items and settings.

## Keys

| Key | Action |
|---|---|
| `⌥⌘A` | Open AliasBar |
| type | Search |
| `↑` `↓` or `⌃n` `⌃p` | Move |
| `⏎` | Use the selected item |
| `⌘⏎` | Use its second action |
| `⇥` | Switch between aliases and prompts |
| `⌘1` `⌘2` `⌘3` | Find / Board / Manage |
| `⌘N` `⌘E` | New / edit |
| `esc` | Close and return focus |

## Privacy

- AliasBar stores your data on this Mac.
- Clipboard monitoring and text expansion start off.
- Pasting into other apps requires Accessibility; copying does not.
- AliasBar backs up your shell config before changing its own block.
- Its only network access is an optional update check.

## Install

Requires macOS 13+ and Xcode Command Line Tools.

```sh
git clone https://github.com/localtoasted/aliasbar.git
cd aliasbar
./build.sh --install
open ~/Applications/AliasBar.app
```

To use another shell config:

```sh
ALIASBAR_ZSHRC=~/.config/zsh/.zshrc open ~/Applications/AliasBar.app
```

## Command line

The build includes `.build/ab`:

```sh
.build/ab list
.build/ab search git
.build/ab add gs 'git status -sb'
```

Install only the CLI with Homebrew:

```sh
brew install localtoasted/aliasbar/aliasbar
```

Run `ab help` for all commands.

## Build and test

```sh
./build.sh
./test.sh
```

Built with SwiftUI. No account or background helper.

## Roadmap

- Sourced shell files
- Bash and fish
- Run an alias in a terminal tab

MIT licensed.
