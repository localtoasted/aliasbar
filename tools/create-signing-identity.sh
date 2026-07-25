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
# Run this once. No password, no prompt: codesign will use a self-signed certificate
# sitting in the login keychain without needing an explicit trust setting, which is the
# step most instructions for this include and which turns out not to be required.

NAME="${1:-AliasBar Local Signing}"

# `security find-identity -p codesigning` only lists certificates with explicit trust
# settings, so it reports "0 valid identities" for one that codesign will happily use.
# Asking the keychain whether the certificate exists is the question that matters.
if security find-certificate -c "${NAME}" >/dev/null 2>&1; then
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

# A passphrase is required, not optional: `security import` fails MAC verification on a
# PKCS#12 built with an empty one. It is a throwaway for a file that exists for the next
# two lines and is deleted on exit.
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -out "${WORK}/identity.p12" \
    -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" -passout "pass:${PASS}" 2>/dev/null

KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

echo "==> Importing into your login keychain"
# -T /usr/bin/codesign lets codesign use the key without prompting on every build.
security import "${WORK}/identity.p12" -k "${KEYCHAIN}" -P "${PASS}" -T /usr/bin/codesign >/dev/null

echo
if security find-certificate -c "${NAME}" >/dev/null 2>&1; then
    echo "==> Done. '${NAME}' is ready."
    echo
    echo "Next, and this part is necessary exactly once:"
    echo "  1. tccutil reset Accessibility com.localtoasted.aliasbar"
    echo "  2. ./build.sh"
    echo "  3. Open AliasBar, pick an alias, and allow Accessibility when asked."
    echo
    echo "Every rebuild after that keeps the permission."
else
    echo "==> The import did not take. Open Keychain Access and check whether"
    echo "    '${NAME}' landed under login > My Certificates."
    exit 1
fi
