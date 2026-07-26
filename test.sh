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
    "${PROJECT_DIR}/Sources/ClipTransforms.swift" \
    "${PROJECT_DIR}/Sources/AliasWriter.swift" \
    -emit-module-path "${BUILD_DIR}/AliasBarCore.swiftmodule"

swiftc -target "$(uname -m)-apple-macos13.0" \
    "${PROJECT_DIR}/Sources/Model.swift" \
    "${PROJECT_DIR}/Sources/AppPaths.swift" \
    "${PROJECT_DIR}/Sources/SensitiveContentClassifier.swift" \
    "${PROJECT_DIR}/Sources/ClipboardCapture.swift" \
    "${PROJECT_DIR}/Sources/ClipTransforms.swift" \
    "${PROJECT_DIR}/Sources/PasteboardBroker.swift" \
    "${PROJECT_DIR}/Sources/ClipboardMonitor.swift" \
    "${PROJECT_DIR}/Sources/Settings.swift" \
    "${PROJECT_DIR}/Sources/Theme.swift" \
    "${PROJECT_DIR}/Sources/Appearance.swift" \
    "${PROJECT_DIR}/Sources/AliasWriter.swift" \
    "${PROJECT_DIR}/Sources/Store.swift" \
    "${PROJECT_DIR}/Sources/Diag.swift" \
    "${PROJECT_DIR}/Sources/Hotkey.swift" \
    "${PROJECT_DIR}/Sources/AppState.swift" \
    "${BUILD_DIR}/main.swift" \
    -o "${BUILD_DIR}/writer-tests"

"${BUILD_DIR}/writer-tests"
