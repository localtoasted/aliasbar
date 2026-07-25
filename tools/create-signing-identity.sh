#!/bin/bash
set -euo pipefail

# Creates a self-signed code-signing certificate so AliasBar keeps its Accessibility
# permission across rebuilds.
#
# The problem this solves: macOS pins an Accessibility grant to the identity of the
# binary it was granted to. An ad-hoc signature has no stable identity, so the grant is
# pinned to that build's hash and the next build voids it — while System Settings goes
# on showing AliasBar as allowed. The result is an app that looks permitted and behaves
# as though it is not, and a permission prompt appearing on what should be an ordinary
# keystroke.
#
# A self-signed certificate gives the bundle a fixed identity. The grant attaches to the
# certificate, and the certificate does not change when the code does.
#
# Run this once. It will ask for your login keychain password when it adds the trust
# setting — that is macOS asking, not this script, and nothing here reads it.

NAME="${1:-AliasBar Local Signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${NAME}"; then
    echo "==> '${NAME}' already exists. Nothing to do."
    echo "    Rebuild with ./build.sh and it will be used automatically."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "==> Generating a 10-year self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" -days 3650 \
    -subj "/CN=${NAME}" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2>/dev/null

openssl pkcs12 -export -out "${WORK}/identity.p12" \
    -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" -passout pass: 2>/dev/null

KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

echo "==> Importing into your login keychain"
# -T /usr/bin/codesign lets codesign use the key without prompting on every build.
security import "${WORK}/identity.p12" -k "${KEYCHAIN}" -P "" -T /usr/bin/codesign >/dev/null

echo "==> Marking it trusted for code signing (macOS will ask for your password)"
security add-trusted-cert -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "${NAME}"; then
    echo "==> Done. '${NAME}' is ready."
    echo
    echo "Next, and this part is necessary exactly once:"
    echo "  1. tccutil reset Accessibility com.localtoasted.aliasbar"
    echo "  2. ./build.sh"
    echo "  3. Open AliasBar, pick an alias, and allow Accessibility when asked."
    echo
    echo "Every rebuild after that keeps the permission."
else
    echo "==> The certificate was created but is not yet valid for code signing."
    echo "    Open Keychain Access, find '${NAME}' under login > My Certificates,"
    echo "    Get Info > Trust, and set 'Code Signing' to 'Always Trust'."
fi
