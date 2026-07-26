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
2. **Build**: `./build.sh`. The bundle lands in `.build/AliasBar.app` (and installs to
   `~/Applications`).
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
(PRE-242): sign with it in `build.sh` (`ALIASBAR_SIGN_IDENTITY`), notarize the zip
(`xcrun notarytool submit --wait` + `xcrun stapler staple`), and release as above.
Nothing in the update pipeline changes.
