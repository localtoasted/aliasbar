#!/bin/bash
set -euo pipefail

# Runs the shared-core and AliasWriter test suite. Writer checks use scratch files
# (never a real .zshrc) and round-trip through the actual zsh binary.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build/tests"
# SWIFT_CONCURRENCY_FLAGS + SWIFT_CLI_LANGUAGE_FLAGS. One declaration, shared with
# build.sh and tools/release-cli.sh so the checks cannot drift between them.
source "${PROJECT_DIR}/tools/swift-flags.sh"
mkdir -p "${BUILD_DIR}"

# The tests call real delivery paths. Never let a trusted developer machine turn a
# fixture into a system-clipboard write, Accessibility prompt, focus change, or
# synthesized Command-V.
export ALIASBAR_TEST_MODE=1

# The test file uses top-level code, which Swift only allows in a file named main.swift.
cp "${PROJECT_DIR}/Tests/WriterTests.swift" "${BUILD_DIR}/main.swift"

# Prove the reusable seam compiles without any app-owned source.
swiftc "${SWIFT_CONCURRENCY_FLAGS[@]}" -parse-as-library -emit-module \
    -module-name AliasBarCore \
    -target "$(uname -m)-apple-macos13.0" \
    "${PROJECT_DIR}/Sources/Model.swift" \
    "${PROJECT_DIR}/Sources/ContentHash.swift" \
    "${PROJECT_DIR}/Sources/SensitiveContentClassifier.swift" \
    "${PROJECT_DIR}/Sources/ClipboardCapture.swift" \
    "${PROJECT_DIR}/Sources/ClipTransforms.swift" \
    "${PROJECT_DIR}/Sources/AliasWriter.swift" \
    "${PROJECT_DIR}/Sources/Shortcut.swift" \
    "${PROJECT_DIR}/Sources/PromptStore.swift" \
    "${PROJECT_DIR}/Sources/PromptCompiler.swift" \
    "${PROJECT_DIR}/Sources/AuditPrompt.swift" \
    "${PROJECT_DIR}/Sources/PromptInbox.swift" \
    "${PROJECT_DIR}/Sources/SharedDocument.swift" \
    "${PROJECT_DIR}/Sources/SnippetCore.swift" \
    "${PROJECT_DIR}/Sources/SuggestionEngine.swift" \
    -emit-module-path "${BUILD_DIR}/AliasBarCore.swiftmodule"

swiftc "${SWIFT_CONCURRENCY_FLAGS[@]}" -target "$(uname -m)-apple-macos13.0" \
    "${PROJECT_DIR}/Sources/Model.swift" \
    "${PROJECT_DIR}/Sources/AppPaths.swift" \
    "${PROJECT_DIR}/Sources/ContentHash.swift" \
    "${PROJECT_DIR}/Sources/SensitiveContentClassifier.swift" \
    "${PROJECT_DIR}/Sources/ClipboardCapture.swift" \
    "${PROJECT_DIR}/Sources/ClipTransforms.swift" \
    "${PROJECT_DIR}/Sources/PasteboardBroker.swift" \
    "${PROJECT_DIR}/Sources/ClipboardMonitor.swift" \
    "${PROJECT_DIR}/Sources/ExpansionMonitor.swift" \
    "${PROJECT_DIR}/Sources/Settings.swift" \
    "${PROJECT_DIR}/Sources/Theme.swift" \
    "${PROJECT_DIR}/Sources/Appearance.swift" \
    "${PROJECT_DIR}/Sources/AliasWriter.swift" \
    "${PROJECT_DIR}/Sources/Shortcut.swift" \
    "${PROJECT_DIR}/Sources/PromptStore.swift" \
    "${PROJECT_DIR}/Sources/PromptCompiler.swift" \
    "${PROJECT_DIR}/Sources/AuditPrompt.swift" \
    "${PROJECT_DIR}/Sources/PromptInbox.swift" \
    "${PROJECT_DIR}/Sources/SuggestionEngine.swift" \
    "${PROJECT_DIR}/Sources/SharedDocument.swift" \
    "${PROJECT_DIR}/Sources/SettingsSync.swift" \
    "${PROJECT_DIR}/Sources/SnippetCore.swift" \
    "${PROJECT_DIR}/Sources/OnboardingScan.swift" \
    "${PROJECT_DIR}/Sources/Store.swift" \
    "${PROJECT_DIR}/Sources/Diag.swift" \
    "${PROJECT_DIR}/Sources/Hotkey.swift" \
    "${PROJECT_DIR}/Sources/DialectContext.swift" \
    "${PROJECT_DIR}/Sources/FillInSheet.swift" \
    "${PROJECT_DIR}/Sources/AppState.swift" \
    "${PROJECT_DIR}/Sources/ClipboardState.swift" \
    "${PROJECT_DIR}/Sources/InboxState.swift" \
    "${PROJECT_DIR}/Sources/ComposerState.swift" \
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
# These exercise the compiled `ab` binary as a subprocess. The checks themselves live
# in tools/cli-integration-tests.sh, shared with tools/release-cli.sh so a release
# binary is held to the exact same behavioral contract as every commit's test run.
# ---------------------------------------------------------------------------
echo
echo "Building ab CLI"

CLI_BUILD_DIR="${PROJECT_DIR}/.build/cli-tests"
mkdir -p "${CLI_BUILD_DIR}"
# SWIFT_CLI_LANGUAGE_FLAGS on top of the shared set, matching build.sh's `ab` target:
# this source list is Foundation-only and compiles clean under the Swift 6 language
# mode, so the run that proves the CLI's behavior also proves it under that mode.
swiftc "${SWIFT_CONCURRENCY_FLAGS[@]}" "${SWIFT_CLI_LANGUAGE_FLAGS[@]}" \
    -target "$(uname -m)-apple-macos13.0" \
    "${PROJECT_DIR}/Sources/Model.swift" \
    "${PROJECT_DIR}/Sources/AliasWriter.swift" \
    "${PROJECT_DIR}"/Sources/CLI/*.swift \
    -o "${CLI_BUILD_DIR}/ab"
AB_BIN="${CLI_BUILD_DIR}/ab"

echo
echo "2. ab CLI"
source "${PROJECT_DIR}/tools/cli-integration-tests.sh"
cli_status=0
run_cli_integration_tests "${AB_BIN}" || cli_status=$?

# ---------------------------------------------------------------------------
echo
echo "$(printf -- '-%.0s' {1..60})"
if [ "${swift_status}" -eq 0 ] && [ "${cli_status}" -eq 0 ]; then
    echo "All test suites passed."
    exit 0
else
    echo "Some tests failed (writer-tests exit=${swift_status}, ab CLI exit=${cli_status})."
    exit 1
fi
