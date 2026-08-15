#!/usr/bin/env bash
#
# Creates a self-signed code-signing certificate in your login keychain, once.
#
# Why this exists: macOS keys the Accessibility permission to an app's code
# signature. Ad-hoc signing ("-") produces a new identity on every build, so every
# rebuild silently revokes the grant and the app goes blind — it keeps running, keeps
# logging app names, and stops seeing window titles, with no error anywhere.
#
# Signing with a stable identity fixes that: grant Accessibility once and it survives
# rebuilds. This certificate is for local development only. It is not a Developer ID,
# it cannot notarise, and nobody else can run the resulting app without Gatekeeper
# complaining — that still needs the $99/yr Apple Developer Program.
#
# Run once:  ./scripts/make-signing-identity.sh
# Then:      ./scripts/build-app.sh    (picks the identity up automatically)
#
set -euo pipefail

IDENTITY_NAME="AI-slap Local Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

if security find-identity -v -p codesigning | grep -q "${IDENTITY_NAME}"; then
    echo "==> '${IDENTITY_NAME}' already exists. Nothing to do."
    echo "    Build with: ./scripts/build-app.sh"
    exit 0
fi

echo "==> Generating a self-signed code-signing certificate"

cat > "${WORK_DIR}/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = ${IDENTITY_NAME}

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "${WORK_DIR}/key.pem" \
    -out "${WORK_DIR}/cert.pem" \
    -config "${WORK_DIR}/openssl.cnf" 2>/dev/null

# OpenSSL 3 defaults to AES-256-CBC with a SHA-256 MAC, which macOS's importer
# rejects outright ("MAC verification failed during PKCS12 import"). -legacy produces
# the older RC2/3DES format it can actually read. LibreSSL — what /usr/bin/openssl is
# on a stock Mac — writes that format already and has no such flag, hence the fallback.
# An empty passphrase also fails the same way, so use a throwaway one.
P12_PASSPHRASE="aislap-import"

if ! openssl pkcs12 -export -legacy \
        -inkey "${WORK_DIR}/key.pem" \
        -in "${WORK_DIR}/cert.pem" \
        -name "${IDENTITY_NAME}" \
        -passout "pass:${P12_PASSPHRASE}" \
        -out "${WORK_DIR}/identity.p12" 2>/dev/null
then
    openssl pkcs12 -export \
        -inkey "${WORK_DIR}/key.pem" \
        -in "${WORK_DIR}/cert.pem" \
        -name "${IDENTITY_NAME}" \
        -passout "pass:${P12_PASSPHRASE}" \
        -out "${WORK_DIR}/identity.p12" 2>/dev/null
fi

echo "==> Importing into your login keychain"
echo "    macOS may ask for your login password — that's the keychain, not sudo."

# -T authorises codesign to use the key without prompting on every build.
security import "${WORK_DIR}/identity.p12" \
    -k "${KEYCHAIN}" \
    -P "${P12_PASSPHRASE}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Stops the "codesign wants to sign using key" dialog appearing on each build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "" "${KEYCHAIN}" >/dev/null 2>&1 || \
    echo "    (Could not set the partition list — you may get one prompt per build.)"

echo "==> Trusting it for code signing"
# User trust domain, so this needs no administrator rights.
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "${KEYCHAIN}" \
    "${WORK_DIR}/cert.pem" 2>/dev/null || {
        echo
        echo "    Could not set trust automatically. Do it by hand, once:"
        echo "      1. Open Keychain Access → login → Certificates"
        echo "      2. Double-click '${IDENTITY_NAME}'"
        echo "      3. Expand Trust, set 'Code Signing' to 'Always Trust'"
        echo
    }

if security find-identity -v -p codesigning | grep -q "${IDENTITY_NAME}"; then
    echo "==> Done. '${IDENTITY_NAME}' is ready."
    echo
    echo "    Next: ./scripts/build-app.sh"
    echo "    You will need to grant Accessibility one final time after the next"
    echo "    build — the signature changes once, from ad-hoc to this identity."
    echo "    After that it sticks."
else
    echo "!!  The identity was not created. See the messages above."
    exit 1
fi
