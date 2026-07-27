#!/bin/bash
set -euo pipefail

# AliasBar build script
# Compiles Sources/*.swift and assembles AliasBar.app. Installation is opt-in.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
APP_NAME="AliasBar"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
INSTALL_DIR="${HOME}/Applications"
INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}.app"
INSTALL=false

usage() {
    cat <<EOF
Usage: ./build.sh [--install]

Builds ${APP_BUNDLE}.

Options:
  --install  Replace ${INSTALL_PATH} with the completed build.
  -h, --help Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install)
            INSTALL=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

# Sparkle (auto-updates) is the one binary dependency. It is fetched once from the
# pinned release below, checksum-verified, and cached in .deps/ — never committed.
# The same download also carries the release tools (generate_appcast, sign_update)
# that docs/RELEASING.md uses.
SPARKLE_VERSION="2.9.4"
SPARKLE_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
SPARKLE_DIR="${PROJECT_DIR}/.deps/Sparkle-${SPARKLE_VERSION}"

if [ ! -d "${SPARKLE_DIR}/Sparkle.framework" ]; then
    echo "==> Fetching Sparkle ${SPARKLE_VERSION}"
    mkdir -p "${SPARKLE_DIR}"
    SPARKLE_TAR="${SPARKLE_DIR}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    curl -fsSL -o "${SPARKLE_TAR}" \
        "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    echo "${SPARKLE_SHA256}  ${SPARKLE_TAR}" | shasum -a 256 -c - >/dev/null
    tar -xf "${SPARKLE_TAR}" -C "${SPARKLE_DIR}"
fi

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
    -F "${SPARKLE_DIR}" \
    "${SOURCES[@]}" \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "${BUILD_DIR}/${APP_NAME}"

echo "==> Compiling ab CLI"
# Foundation-only: the core (Model.swift, AliasWriter.swift) plus Sources/CLI, and
# nothing else. No AppKit, no SwiftUI, no Settings/Store/AppState — those pull in
# UserDefaults and app-only state the CLI must never touch.
CLI_SOURCES=("${PROJECT_DIR}"/Sources/CLI/*.swift)
if [ ${#CLI_SOURCES[@]} -eq 0 ]; then
    echo "No sources found in ${PROJECT_DIR}/Sources/CLI" >&2
    exit 1
fi
swiftc -O -target "${ARCH}-apple-macos13.0" \
    "${PROJECT_DIR}/Sources/Model.swift" \
    "${PROJECT_DIR}/Sources/AliasWriter.swift" \
    "${CLI_SOURCES[@]}" \
    -o "${BUILD_DIR}/ab"

echo "==> Assembling app bundle"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
cp -R "${SPARKLE_DIR}/Sparkle.framework" "${APP_BUNDLE}/Contents/Frameworks/"

echo "==> Building app icon"
ICON_SOURCE="${PROJECT_DIR}/Assets/AppIcon.png"
ICONSET="${BUILD_DIR}/AliasBar.iconset"
mkdir -p "${APP_BUNDLE}/Contents/Resources" "${ICONSET}"
for spec in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
    size="${spec%% *}"
    name="${spec#* }"
    sips -z "${size}" "${size}" "${ICON_SOURCE}" --out "${ICONSET}/${name}" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${APP_BUNDLE}/Contents/Resources/AliasBar.icns"

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
    <key>CFBundleIconFile</key>
    <string>AliasBar.icns</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://github.com/localtoasted/aliasbar/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>r4ojp6CWS34l4NYY7OfbAjGVUo0KSGWsyzr7rhPwMTw=</string>
    <!-- On by default; onboarding presents the choice on first run and Settings >
         About keeps it. Setting the key here (either way) also stops Sparkle's own
         consent prompt from arriving "from nowhere" on second launch. -->
    <key>SUEnableAutomaticChecks</key>
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
# Sparkle's nested code (XPC services, Autoupdate, Updater.app) has to be signed
# inside-out per its docs — `--deep` re-signs them in an unspecified order and is
# deprecated besides. Every signature carries `--options runtime`: the helpers ship
# from Sparkle with Hardened Runtime, and notarization requires it on everything —
# a plain re-sign silently strips it. Downloader.xpc additionally preserves its
# shipped entitlements, as Sparkle's signing sequence specifies.
# https://sparkle-project.org/documentation/sandboxing/#code-signing
sign_bundle() {
    local identity="$1"
    local fw="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
    codesign --force --options runtime -s "${identity}" "${fw}/Versions/B/XPCServices/Installer.xpc"
    codesign --force --options runtime --preserve-metadata=entitlements -s "${identity}" "${fw}/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --options runtime -s "${identity}" "${fw}/Versions/B/Autoupdate"
    codesign --force --options runtime -s "${identity}" "${fw}/Versions/B/Updater.app"
    codesign --force --options runtime -s "${identity}" "${fw}"
    # A self-signed or ad-hoc identity has no Apple Team ID. Hardened Runtime's
    # library validation would therefore reject Sparkle even after every nested
    # component is signed with that same local identity. Disable it only for local
    # builds; Developer ID release builds keep library validation enabled.
    if [ "${identity}" = "-" ] || [[ "${identity}" == AliasBar\ Local\ Signing* ]]; then
        codesign --force --options runtime \
            --entitlements "${PROJECT_DIR}/tools/local-signing.entitlements" \
            -s "${identity}" "${APP_BUNDLE}"
    else
        codesign --force --options runtime -s "${identity}" "${APP_BUNDLE}"
    fi
}

if security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
    echo "==> Codesigning as ${SIGN_IDENTITY}"
    sign_bundle "${SIGN_IDENTITY}"
else
    echo "==> Ad-hoc codesigning"
    echo "    NOTE: no stable signing identity, so this build voids any Accessibility"
    echo "    permission you granted a previous one. Run tools/create-signing-identity.sh"
    echo "    once to stop that happening."
    sign_bundle "-"
fi

if [ "${INSTALL}" = true ]; then
    echo "==> Installing to ${INSTALL_PATH}"
    mkdir -p "${INSTALL_DIR}"
    rm -rf "${INSTALL_PATH}"
    cp -R "${APP_BUNDLE}" "${INSTALL_PATH}"
    echo "==> Done: ${INSTALL_PATH}"
else
    echo "==> Done: ${APP_BUNDLE}"
fi
echo "==> ab CLI: ${BUILD_DIR}/ab"
