#!/bin/bash
set -euo pipefail

# Runs the shared-core and AliasWriter test suite. Writer checks use scratch files
# (never a real .zshrc) and round-trip through the actual zsh binary.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build/tests"
mkdir -p "${BUILD_DIR}"

# The test file uses top-level code, which Swift only allows in a file named main.swift.
cp "${PROJECT_DIR}/Tests/WriterTests.swift" "${BUILD_DIR}/main.swift"

# Prove the reusable seam compiles without any app-owned source.
swiftc -parse-as-library -emit-module \
    -module-name AliasBarCore \
    -target "$(uname -m)-apple-macos13.0" \
    "${PROJECT_DIR}/Sources/Model.swift" \
    "${PROJECT_DIR}/Sources/SensitiveContentClassifier.swift" \
    "${PROJECT_DIR}/Sources/ClipboardCapture.swift" \
    "${PROJECT_DIR}/Sources/AliasWriter.swift" \
    -emit-module-path "${BUILD_DIR}/AliasBarCore.swiftmodule"

swiftc -target "$(uname -m)-apple-macos13.0" \
    "${PROJECT_DIR}/Sources/Model.swift" \
    "${PROJECT_DIR}/Sources/AppPaths.swift" \
    "${PROJECT_DIR}/Sources/SensitiveContentClassifier.swift" \
    "${PROJECT_DIR}/Sources/ClipboardCapture.swift" \
    "${PROJECT_DIR}/Sources/Settings.swift" \
    "${PROJECT_DIR}/Sources/Theme.swift" \
    "${PROJECT_DIR}/Sources/Appearance.swift" \
    "${PROJECT_DIR}/Sources/AliasWriter.swift" \
    "${PROJECT_DIR}/Sources/SharedDocument.swift" \
    "${PROJECT_DIR}/Sources/Store.swift" \
    "${PROJECT_DIR}/Sources/Diag.swift" \
    "${PROJECT_DIR}/Sources/Hotkey.swift" \
    "${PROJECT_DIR}/Sources/AppState.swift" \
    "${BUILD_DIR}/main.swift" \
    -o "${BUILD_DIR}/writer-tests"

# Captured rather than let `set -e` abort here: the CLI integration section below
# still needs to run (and report) even when this suite fails, so the two results can
# be combined into one final exit code at the bottom of the script.
swift_status=0
"${BUILD_DIR}/writer-tests" || swift_status=$?

# ---------------------------------------------------------------------------
# ab CLI integration tests
#
# These exercise the compiled `ab` binary as a subprocess against scratch HOME-style
# fixtures — a temp rc file and a temp history file, pointed to via ALIASBAR_ZSHRC and
# ALIASBAR_HISTORY exactly as a real user's environment would. Never a real ~/.zshrc
# or ~/.zsh_history, matching the rest of this suite.
# ---------------------------------------------------------------------------
echo
echo "Building ab CLI"

CLI_BUILD_DIR="${PROJECT_DIR}/.build/cli-tests"
mkdir -p "${CLI_BUILD_DIR}"
swiftc -target "$(uname -m)-apple-macos13.0" \
    "${PROJECT_DIR}/Sources/Model.swift" \
    "${PROJECT_DIR}/Sources/AliasWriter.swift" \
    "${PROJECT_DIR}"/Sources/CLI/*.swift \
    -o "${CLI_BUILD_DIR}/ab"
AB_BIN="${CLI_BUILD_DIR}/ab"

CLI_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/aliasbar-cli-tests-XXXXXX")"
trap 'rm -rf "${CLI_SANDBOX}"' EXIT

cli_pass=0
cli_fail=0
cli_check() {
    local label="$1"; shift
    if "$@"; then
        cli_pass=$((cli_pass + 1))
        echo "  ok   ${label}"
    else
        cli_fail=$((cli_fail + 1))
        echo "  FAIL ${label}"
    fi
}
contains() { [[ "$1" == *"$2"* ]]; }
not_contains() { [[ "$1" != *"$2"* ]]; }
status_is() { [ "${AB_STATUS}" -eq "$1" ]; }
out_is_empty() { [ -z "${AB_OUT}" ]; }
out_starts_with_bracket() { [ "${AB_OUT:0:1}" = "[" ]; }
out_first_line_is() { [ "$(printf '%s\n' "${AB_OUT}" | head -1)" = "$1" ]; }
out_line_count_is() { [ "$(printf '%s\n' "${AB_OUT}" | wc -l | tr -d ' ')" -eq "$1" ]; }
backup_file_exists() { compgen -G "${RC_FILE}.aliasbar-backup-*" > /dev/null; }
rc_still_parses() { zsh -n "${RC_FILE}"; }

# Runs `ab` with $ALIASBAR_ZSHRC/$ALIASBAR_HISTORY set to the sandbox fixtures below.
# Captures stdout/stderr/exit code into AB_OUT/AB_ERR/AB_STATUS without tripping
# `set -e` on the (frequently intentional, e.g. refusal) nonzero exits.
call_ab() {
    AB_STATUS=0
    AB_OUT="$(ALIASBAR_ZSHRC="${RC_FILE}" ALIASBAR_HISTORY="${HISTORY_FILE}" \
        "${AB_BIN}" "$@" 2>"${CLI_SANDBOX}/stderr")" || AB_STATUS=$?
    AB_ERR="$(cat "${CLI_SANDBOX}/stderr")"
}

echo
echo "2. ab CLI"

# --- Fixtures -----------------------------------------------------------
# One hand-written alias outside the managed block (so `add`/refusal-on-clash has
# something to hit), one managed alias with a comment (so `search` has a comment to
# match against), and a history file with distinct, chronologically ordered commands
# (oldest first — HistoryScanner's "most recent" is the highest file position).
RC_FILE="${CLI_SANDBOX}/rc"
cat > "${RC_FILE}" <<'RCEOF'
alias ll='ls -la'

# >>> aliasbar managed block >>>
# Edited by AliasBar. Anything outside these markers is never touched.
# shorthand for git status
alias gs='git status'
# <<< aliasbar managed block <<<
RCEOF

HISTORY_FILE="${CLI_SANDBOX}/history"
cat > "${HISTORY_FILE}" <<'HISTEOF'
ls -la
git status
git log --oneline -5
docker ps -a
npm run build
HISTEOF

# --- list -----------------------------------------------------------------
call_ab list
cli_check "list exits 0" status_is 0
cli_check "list marks the managed alias with *" contains "${AB_OUT}" $'*gs\tgit status'
cli_check "list includes the unmanaged alias unmarked" contains "${AB_OUT}" $'ll\tls -la'

call_ab list --json
cli_check "list --json exits 0" status_is 0
cli_check "list --json is a JSON array" out_starts_with_bracket
cli_check "list --json includes gs with managed:true" contains "${AB_OUT}" '"managed":true'
cli_check "list --json includes gs's comment" contains "${AB_OUT}" '"shorthand for git status"'

# --- search -----------------------------------------------------------------
call_ab search git
cli_check "search by comment finds gs" contains "${AB_OUT}" "gs"
cli_check "search by comment excludes ll" not_contains "${AB_OUT}" "ll"

call_ab search nonexistentquery
cli_check "search with no matches exits 0" status_is 0
cli_check "search with no matches has empty output" out_is_empty

# --- add ------------------------------------------------------------------
call_ab add gs2 "echo hello" --comment "test alias"
cli_check "add succeeds" status_is 0
cli_check "add reports the destination" contains "${AB_OUT}" "Wrote gs2"
cli_check "add reports a backup" contains "${AB_OUT}" "backup:"
cli_check "add creates a backup file" backup_file_exists
cli_check "rc file still parses after add" rc_still_parses
call_ab list
cli_check "the new alias shows up in list" contains "${AB_OUT}" $'*gs2\techo hello'

call_ab add ll "echo hi"
cli_check "add refuses a name defined outside the managed block" status_is 3
cli_check "the refusal names the clash" contains "${AB_ERR}" "outside AliasBar's managed block"

call_ab add if "echo hi"
cli_check "add refuses a reserved word" status_is 3

call_ab add onlyname
cli_check "add with a missing command argument is a usage error" status_is 2

call_ab list --file "${CLI_SANDBOX}"
cli_check "an existing unreadable file (a directory) exits 5" status_is 5

# --- last -------------------------------------------------------------------
call_ab last 3
cli_check "last 3 exits 0" status_is 0
cli_check "last 3 orders newest first" out_first_line_is "npm run build"
cli_check "last 3 prints exactly 3 lines" out_line_count_is 3

call_ab last 0
cli_check "last with n=0 is a usage error" status_is 2

# --- promote ----------------------------------------------------------------
call_ab promote
cli_check "promote (default n=1) exits 0" status_is 0
cli_check "promote reports the suggested name" contains "${AB_OUT}" "Promoted history #1 to nrb"
cli_check "rc file still parses after promote" rc_still_parses
call_ab list
cli_check "the promoted alias is in the managed block" contains "${AB_OUT}" $'*nrb\tnpm run build'

call_ab promote 2 --name mydeploy
cli_check "promote with --name uses the override" contains "${AB_OUT}" "Promoted history #2 to mydeploy"
call_ab list
cli_check "the overridden name is used, not a suggestion" contains "${AB_OUT}" $'*mydeploy\tdocker ps -a'

call_ab promote 99
cli_check "promote past the end of history has nothing to do" status_is 4

echo
echo "  ${cli_pass} passed, ${cli_fail} failed"

# ---------------------------------------------------------------------------
echo
echo "$(printf -- '-%.0s' {1..60})"
if [ "${swift_status}" -eq 0 ] && [ "${cli_fail}" -eq 0 ]; then
    echo "All test suites passed."
    exit 0
else
    echo "Some tests failed (writer-tests exit=${swift_status}, ab CLI failures=${cli_fail})."
    exit 1
fi
