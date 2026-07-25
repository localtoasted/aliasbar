#!/bin/bash
set -euo pipefail

# Runs the AliasWriter test suite. The writer is the only code in AliasBar that
# modifies anything, so it gets exercised against scratch files (never a real
# .zshrc) and round-tripped through the actual zsh binary.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build/tests"
mkdir -p "${BUILD_DIR}"

# The test file uses top-level code, which Swift only allows in a file named main.swift.
cp "${PROJECT_DIR}/Tests/WriterTests.swift" "${BUILD_DIR}/main.swift"

swiftc -target "$(uname -m)-apple-macos13.0" \
    "${PROJECT_DIR}/Sources/Model.swift" \
    "${PROJECT_DIR}/Sources/Settings.swift" \
    "${PROJECT_DIR}/Sources/Theme.swift" \
    "${PROJECT_DIR}/Sources/AliasWriter.swift" \
    "${BUILD_DIR}/main.swift" \
    -o "${BUILD_DIR}/writer-tests"

"${BUILD_DIR}/writer-tests"
