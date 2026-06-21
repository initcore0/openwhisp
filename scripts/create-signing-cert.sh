#!/bin/bash
# Create a STABLE self-signed code-signing certificate in the login keychain,
# so every OpenWhisp build is signed with the same identity. macOS ties TCC
# permissions (Microphone, Accessibility, Input Monitoring) to the signing
# identity, so a stable cert means permissions survive rebuilds instead of being
# re-requested every time (which is what ad-hoc `codesign --sign -` causes).
#
# Idempotent: if the certificate already exists, it does nothing.
#
# NOTE: this is a *self-signed* cert. It fixes the re-prompt problem on YOUR
# machine. It does NOT make the app trusted on other machines — for that you need
# an Apple Developer ID certificate + notarization.
#
# Usage: scripts/create-signing-cert.sh

set -euo pipefail

CERT_NAME="OpenWhisp Self-Signed"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "✓ Code-signing certificate '$CERT_NAME' already exists."
    exit 0
fi

echo "=== Creating self-signed code-signing certificate: '$CERT_NAME' ==="
echo "macOS will ask for your login password and may prompt to allow keychain access."

# Build a certificate request config for a code-signing (1.3.6.1.5.5.7.3.3) cert.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CONF="$WORK/cert.conf"
cat > "$CONF" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $CERT_NAME
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$CONF" >/dev/null 2>&1

# Bundle key+cert into a PKCS#12. Use -legacy + a password: modern OpenSSL's
# default PKCS#12 cipher is rejected by macOS `security import`.
P12="$WORK/identity.p12"
P12PASS="openwhisp"
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$P12" -passout "pass:$P12PASS" -name "$CERT_NAME" >/dev/null 2>&1

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# -T /usr/bin/codesign lets codesign use the key without an interactive prompt each time.
security import "$P12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign

# codesign will NOT use a self-signed cert until it is trusted for code signing.
# This requires admin rights, so it prompts for your password (one time).
echo ""
echo ">>> Granting code-signing trust to the certificate (needs your password)..."
sudo security add-trusted-cert -d -r trustRoot \
    -p codeSign -k /Library/Keychains/System.keychain "$WORK/cert.pem"

echo ""
echo "✓ Created '$CERT_NAME'. Verify with:"
echo "    security find-identity -v -p codesigning"
echo ""
echo "Now rebuild: ./package.sh  (it will use this identity automatically)."
