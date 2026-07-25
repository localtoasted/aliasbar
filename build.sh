#!/bin/bash
set -euo pipefail

# AliasBar build script
# Compiles Sources/*.swift, assembles AliasBar.app, ad-hoc codesigns, installs to ~/Applications

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
SOURCES=("${PROJECT_DIR}"/Sources/*.swift)
if [ ${#SOURCES[@]} -eq 0 ]; then
    echo "No sources found in ${PROJECT_DIR}/Sources" >&2
    exit 1
fi
swiftc -O -target "${ARCH}-apple-macos13.0" \
    "${SOURCES[@]}" \
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

# Signing identity.
#
# This matters far more than it looks. macOS pins an Accessibility grant to the
# identity of the thing it was granted to. Ad-hoc signing ("-") has no stable
# identity, so the grant is pinned to that exact binary's hash — and every rebuild
# produces a new hash, silently voiding it. The entry stays visible and switched on
# in System Settings while AXIsProcessTrusted() returns false, so the app appears to
# have permission and behaves as though it does not.
#
# Signing with a self-signed certificate instead pins the grant to the certificate,
# which does not change when the code does. Run tools/create-signing-identity.sh once
# and every rebuild after that keeps the permission.
SIGN_IDENTITY="${ALIASBAR_SIGN_IDENTITY:-AliasBar Local Signing}"
# Not `find-identity -p codesigning`: that lists only certificates carrying an explicit
# trust setting, and reports "0 valid identities" for one codesign will use happily.
if security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
    echo "==> Codesigning as ${SIGN_IDENTITY}"
    codesign --force --deep -s "${SIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "==> Ad-hoc codesigning"
    echo "    NOTE: no stable signing identity, so this build voids any Accessibility"
    echo "    permission you granted a previous one. Run tools/create-signing-identity.sh"
    echo "    once to stop that happening."
    codesign --force --deep -s - "${APP_BUNDLE}"
fi

echo "==> Installing to ${INSTALL_PATH}"
mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_PATH}"
cp -R "${APP_BUNDLE}" "${INSTALL_PATH}"

echo "==> Done: ${INSTALL_PATH}"
