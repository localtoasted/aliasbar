# Releasing an AliasBar update

AliasBar updates itself with [Sparkle 2](https://sparkle-project.org). The feed is a
static `appcast.xml` served from GitHub Releases — no backend. Every update is signed
with an EdDSA key; the public half lives in `Info.plist` (`SUPublicEDKey`, written by
`build.sh`), the private half lives in the release manager's macOS Keychain and must
never enter the repo.

## One-time setup (per release machine)

The signing key was generated with Sparkle's `generate_keys` and stored in the login
Keychain (item: "Private key for signing Sparkle updates"). To sign releases from
another machine, export it with `generate_keys -x private-key-file` on the machine
that has it, move it over something encrypted, and import with `generate_keys -f`.
The tools ship in the same Sparkle download `build.sh` caches: `.deps/Sparkle-<version>/bin/`.

## Cutting a release

1. **Bump the version** in `build.sh`'s Info.plist heredoc: `CFBundleShortVersionString`
   (marketing, e.g. `0.3`) and `CFBundleVersion` (monotonic integer — Sparkle compares
   this one). Also bump the `v0.x` string in `SettingsWindow.swift`'s sidebar footer.
2. **Build**: `./build.sh`. The bundle lands in `.build/AliasBar.app` without changing
   `~/Applications`. Pass `--install` only when you also want to replace the local
   installed copy.
3. **Archive**: `ditto -c -k --sequesterRsrc --keepParent .build/AliasBar.app AliasBar-<version>.zip`
   (`ditto` preserves the code signature; plain `zip` does not).
4. **Sign + appcast**: put the zip in an otherwise-empty directory (Sparkle scans the
   whole directory; old zips in it are fine too and produce delta-capable feeds), then
   `.deps/Sparkle-*/bin/generate_appcast <that-directory>`. It pulls the private key
   from the Keychain, signs the archive, and writes `appcast.xml` with the EdDSA
   signature embedded. Edit the enclosure `url` in `appcast.xml` to the versioned
   download URL: `https://github.com/localtoasted/aliasbar/releases/download/v<version>/AliasBar-<version>.zip`.
5. **Publish**: create the GitHub release `v<version>` with **both** assets — the zip
   and `appcast.xml`. The feed URL baked into the app is
   `https://github.com/localtoasted/aliasbar/releases/latest/download/appcast.xml`,
   which always resolves to the newest release's copy, so every release must carry an
   up-to-date `appcast.xml`.
6. **Verify**: run the *previous* build, Settings → About → Check now, and confirm it
   offers and installs the new version.

## What does not work yet (PRE-242)

Local builds are signed with the self-signed "AliasBar Local Signing" certificate (or
ad-hoc). Sparkle's EdDSA check passes regardless, and updates install fine on a machine
that already trusts the app — but for anyone else, Gatekeeper will refuse the first
install of a non-notarized download, and Sparkle requires the update's code signature
to be valid for the identity it ships under. Once the Developer ID certificate exists
(PRE-242): sign with it in `build.sh` (`ALIASBAR_SIGN_IDENTITY`), then notarize —
submit the zip (`xcrun notarytool submit AliasBar-<version>.zip --wait`), staple the
ticket to the **.app** (`xcrun stapler staple AliasBar.app` — a zip cannot be stapled
directly), and re-create the distribution zip from the stapled app before uploading.
Release as above; nothing in the update pipeline changes.

## CLI release + Homebrew tap

`ab` ships independently of the app: its own GitHub release asset, its own Homebrew
tap, its own version (`abCLIVersion` in `Sources/CLI/ABMain.swift`, not the app's
`CFBundleShortVersionString`). No Sparkle, no code signing, no notarization — it's a
small unsigned binary, and Homebrew's own install flow is the trust boundary.

### One-time setup

1. **Create the tap repo**: a real GitHub repo named `localtoasted/homebrew-aliasbar`
   (the `homebrew-` prefix is Homebrew's tap-naming convention — it's what makes
   `brew install localtoasted/aliasbar/aliasbar` resolvable at all), containing one
   file: `Formula/aliasbar.rb`.
2. The first time you cut a CLI release (below), `tools/release-cli.sh` templates a
   `Formula/aliasbar.rb` in *this* repo (gitignored — it's a build output, not source).
   Copy that file into the tap repo at the same path, commit, and push. Every
   subsequent release repeats just this copy-commit-push step — nothing about the tap
   repo's structure changes.

### Per-release steps

1. **Bump the version**: edit `abCLIVersion` in `Sources/CLI/ABMain.swift` (e.g. to
   `0.4.0`) and commit. `tools/release-cli.sh` refuses to build unless the compiled
   binary's `ab --version` matches the version you give it, so this step can't be
   silently skipped.
2. **Build + package**:
   ```sh
   tools/release-cli.sh 0.4.0
   ```
   This builds a release `ab` (universal arm64+x86_64 via `lipo` when cross-compiling
   the x86_64 slice succeeds on the build machine, arm64-only with a printed note
   otherwise), runs the exact same CLI integration checks `test.sh` runs — against
   this binary instead of a debug build — packages
   `release/ab-0.4.0-macos.tar.gz` (binary + `LICENSE` + a short usage README), prints
   its sha256, and templates `Formula/aliasbar.rb` from `Formula/aliasbar.rb.template`
   with that version and hash filled in. Refuses on a dirty git tree. Idempotent: rerun
   it as many times as you want, for the same or a different version — both outputs
   are gitignored and get overwritten cleanly each run.
3. **Publish the GitHub release**:
   ```sh
   gh release create v0.4.0 release/ab-0.4.0-macos.tar.gz \
       --title "ab v0.4.0" --notes "..."
   ```
   (This can be the same tag/release an app update goes out under, or its own —
   they're independent artifacts.)
4. **Update the tap**: copy the templated `Formula/aliasbar.rb` into the
   `localtoasted/homebrew-aliasbar` repo at `Formula/aliasbar.rb`, commit, push.
5. **Verify**:
   ```sh
   brew tap localtoasted/aliasbar          # first time only, per machine
   brew install localtoasted/aliasbar/aliasbar
   # or, upgrading an existing install:
   brew upgrade localtoasted/aliasbar/aliasbar
   ab --version                            # should print "ab 0.4.0"
   ```

`tools/release-cli.sh` only ever writes inside this repo's working tree — the GitHub
release and the tap push are deliberate, separate, manual steps.
