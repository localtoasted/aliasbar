#!/bin/bash
set -euo pipefail

# AliasBar build script
# Compiles main.swift, assembles AliasBar.app, ad-hoc codesigns, installs to ~/Applications

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
APP_NAME="AliasBar"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
INSTALL_DIR="${HOME}/Applications"
INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}.app"

echo "==> Cleaning build dir"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "==> Compiling ${APP_NAME}"
ARCH="$(uname -m)"
swiftc -O -parse-as-library -target "${ARCH}-apple-macos13.0" \
    "${PROJECT_DIR}/main.swift" \
    -o "${BUILD_DIR}/${APP_NAME}"

echo "==> Assembling app bundle"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.localtoasted.aliasbar</string>
    <key>CFBundleName</key>
    <string>AliasBar</string>
    <key>CFBundleExecutable</key>
    <string>AliasBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesigning"
codesign --force --deep -s - "${APP_BUNDLE}"

echo "==> Installing to ${INSTALL_PATH}"
mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_PATH}"
cp -R "${APP_BUNDLE}" "${INSTALL_PATH}"

echo "==> Done: ${INSTALL_PATH}"
