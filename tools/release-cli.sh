#!/bin/bash
set -euo pipefail

# Builds a release `ab` binary, packages it as a tarball, and templates the Homebrew
# formula for it. Publishing (the GitHub release, the tap repo push) is NOT this
# script's job — see docs/RELEASING.md's "CLI release + Homebrew tap" section for the
# commands that do that with what this script produces.
#
# Idempotent: safe to re-run for the same (or a different) version. Every run rebuilds
# from a clean .build/release-cli and overwrites its own output (release/ and
# Formula/aliasbar.rb — both gitignored); it never accumulates state across runs and
# never touches git itself.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

usage() {
    cat <<EOF
Usage: tools/release-cli.sh <version>

  <version>   e.g. 0.4.0. Names the tarball and fills in the Homebrew formula. Must
              match the abCLIVersion constant in Sources/CLI/ABMain.swift (what
              \`ab --version\` prints) — a mismatch fails the build so a forgotten
              version bump can't ship silently.

Produces (both gitignored — never committed):
  release/ab-<version>-macos.tar.gz   the binary + LICENSE + a short usage README
  Formula/aliasbar.rb                 templated from Formula/aliasbar.rb.template

Refuses on a dirty git working tree: uncommitted changes make "what got released"
ambiguous, and this script's whole point is a build that traces back to one commit.
EOF
}

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi
VERSION="$1"

# --- Refuse on a dirty tree ---------------------------------------------------
# --untracked-files=no: an untracked scratch file lying around isn't what "dirty"
# means here, and it's irrelevant to what this exact commit's release would contain.
# Uncommitted changes to tracked files are the thing that makes the release ambiguous.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "release-cli.sh: refusing to release from a dirty git tree — commit or stash first." >&2
    git status --short >&2
    exit 1
fi
COMMIT="$(git rev-parse --short HEAD)"

# --- Build ---------------------------------------------------------------------
WORK_DIR="${PROJECT_DIR}/.build/release-cli"
RELEASE_DIR="${PROJECT_DIR}/release"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}" "${RELEASE_DIR}"

# Same Foundation-only source list build.sh uses for `ab`: Model.swift + AliasWriter.swift
# (the core) plus everything in Sources/CLI. No AppKit, no SwiftUI, no Settings/AppState.
CLI_CORE_SOURCES=(
    "${PROJECT_DIR}/Sources/Model.swift"
    "${PROJECT_DIR}/Sources/AliasWriter.swift"
)
CLI_SOURCES=("${PROJECT_DIR}"/Sources/CLI/*.swift)
SWIFT_CONCURRENCY_FLAGS=(
    -warn-concurrency
    -strict-concurrency=targeted
)

build_arch() {
    local arch="$1" out="$2"
    swiftc -O "${SWIFT_CONCURRENCY_FLAGS[@]}" -target "${arch}-apple-macos13.0" \
        "${CLI_CORE_SOURCES[@]}" "${CLI_SOURCES[@]}" \
        -o "${out}"
}

echo "==> Building arm64 slice"
build_arch arm64 "${WORK_DIR}/ab-arm64"

UNIVERSAL=true
echo "==> Building x86_64 slice"
# swiftc can cross-compile this on an arm64 host because the macOS SDK ships both
# architectures' libraries; it isn't guaranteed on every machine (older Xcode, a
# stripped-down CLT install), so a failure here is a fallback, not an error.
if build_arch x86_64 "${WORK_DIR}/ab-x86_64" 2>"${WORK_DIR}/x86_64-build.log"; then
    lipo -create -output "${WORK_DIR}/ab" "${WORK_DIR}/ab-arm64" "${WORK_DIR}/ab-x86_64"
    echo "    universal (arm64 + x86_64) binary built via lipo"
else
    UNIVERSAL=false
    cp "${WORK_DIR}/ab-arm64" "${WORK_DIR}/ab"
    echo "    x86_64 cross-compile failed on this machine — shipping arm64-only."
    echo "    (see docs/RELEASING.md's note on this; an Intel Mac, or an arm64 Mac"
    echo "    with a fuller Xcode install, can produce a true universal binary)"
    sed 's/^/    x86_64 build log: /' "${WORK_DIR}/x86_64-build.log" >&2 || true
fi
AB_BIN="${WORK_DIR}/ab"
chmod +x "${AB_BIN}"
echo "    $(file "${AB_BIN}")"

# --- Version check ---------------------------------------------------------------
echo "==> Checking ab --version against ${VERSION}"
BUILT_VERSION="$("${AB_BIN}" --version)"
if [ "${BUILT_VERSION}" != "ab ${VERSION}" ]; then
    echo "release-cli.sh: built binary reports '${BUILT_VERSION}', expected 'ab ${VERSION}'." >&2
    echo "    Bump abCLIVersion in Sources/CLI/ABMain.swift to ${VERSION}, commit, and retry." >&2
    exit 1
fi

# --- Integration checks -----------------------------------------------------------
# The exact same checks test.sh runs against its debug build, run here against the
# binary about to be packaged — a release build gets no lower bar than any commit.
echo "==> Running CLI integration checks against the release binary"
source "${PROJECT_DIR}/tools/cli-integration-tests.sh"
if ! run_cli_integration_tests "${AB_BIN}"; then
    echo "release-cli.sh: CLI integration checks failed against the release binary — refusing to package." >&2
    exit 1
fi

# --- Package -----------------------------------------------------------------------
PACKAGE_NAME="ab-${VERSION}-macos"
STAGE_DIR="${WORK_DIR}/stage/${PACKAGE_NAME}"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
cp "${AB_BIN}" "${STAGE_DIR}/ab"
cp "${PROJECT_DIR}/LICENSE" "${STAGE_DIR}/LICENSE"
cat > "${STAGE_DIR}/README.md" <<EOF
# ab ${VERSION}

The AliasBar command-line tool: manage your shell aliases from the terminal, sharing
its config parsing and writing logic with the AliasBar menu-bar app —
https://github.com/localtoasted/aliasbar. Built from commit ${COMMIT}.

## Install

Put \`ab\` somewhere on your \$PATH:

    sudo install -m 755 ab /usr/local/bin/ab

(Homebrew users: \`brew install localtoasted/aliasbar/aliasbar\` does this for you.)

## Usage

    ab list [--json]
    ab search <query> [--json]
    ab add <name> <command> [--comment <text>] [--force-collateral]
    ab last [n] [--json]
    ab promote [n] [--name <name>] [--force-collateral] [--json]
    ab --version

Run \`ab help\` for the full usage text, including path resolution rules
(--file / \$ALIASBAR_ZSHRC / ~/.zshrc) and exit codes.

MIT licensed — see LICENSE.
EOF

TARBALL="${RELEASE_DIR}/${PACKAGE_NAME}.tar.gz"
rm -f "${TARBALL}"
# -s to avoid absolute paths / owner metadata differing between machines; cd into the
# stage's parent so the tarball's top-level entry is the package dir, not its full path.
tar -czf "${TARBALL}" -C "$(dirname "${STAGE_DIR}")" "$(basename "${STAGE_DIR}")"

SHA256="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"

# --- Template the formula ----------------------------------------------------------
FORMULA_TEMPLATE="${PROJECT_DIR}/Formula/aliasbar.rb.template"
FORMULA_OUT="${PROJECT_DIR}/Formula/aliasbar.rb"
sed -e "s/{{VERSION}}/${VERSION}/g" -e "s/{{SHA256}}/${SHA256}/g" \
    "${FORMULA_TEMPLATE}" > "${FORMULA_OUT}"

echo
echo "==> Done."
echo "    Tarball:  ${TARBALL}"
echo "    sha256:   ${SHA256}"
echo "    Formula:  ${FORMULA_OUT}"
if [ "${UNIVERSAL}" = false ]; then
    echo "    NOTE: arm64-only build — not a universal binary (see above)."
fi
echo
echo "Next: docs/RELEASING.md's \"CLI release + Homebrew tap\" section (gh release create,"
echo "then copy Formula/aliasbar.rb into the localtoasted/homebrew-aliasbar tap repo)."
