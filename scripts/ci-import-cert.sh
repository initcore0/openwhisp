#!/bin/bash
# Import a Developer ID Application certificate into a temporary keychain on a CI
# runner, so codesign can use it for the duration of the job. Idempotent-ish: it
# (re)creates a dedicated keychain and adds it to the search list.
#
# Inputs (env):
#   MACOS_CERT_P12_BASE64   base64 of the exported .p12 (cert + private key)
#   MACOS_CERT_PASSWORD     the .p12 export password
#   KEYCHAIN_PASSWORD       a throwaway password for the temp keychain (any value)
#
# On success, prints the Developer ID identity name to stdout (so the workflow can
# capture it into SIGN_IDENTITY). The runner is ephemeral, so no teardown is needed;
# the keychain dies with the VM.
set -euo pipefail

: "${MACOS_CERT_P12_BASE64:?MACOS_CERT_P12_BASE64 is required}"
: "${MACOS_CERT_PASSWORD:?MACOS_CERT_PASSWORD is required}"
: "${KEYCHAIN_PASSWORD:?KEYCHAIN_PASSWORD is required}"

KEYCHAIN="$RUNNER_TEMP/openwhisp-signing.keychain-db"
CERT_PATH="$RUNNER_TEMP/openwhisp-cert.p12"

echo "$MACOS_CERT_P12_BASE64" | base64 --decode > "$CERT_PATH"

# Fresh keychain, unlocked, with a long lock timeout so it stays usable all job.
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

# Import the cert + key. -A would allow ALL apps; scope to the tools that need it.
security import "$CERT_PATH" \
    -k "$KEYCHAIN" \
    -P "$MACOS_CERT_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Let codesign use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

# Put our keychain first in the search list (keep the login/system ones too).
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | sed 's/"//g')

rm -f "$CERT_PATH"

# Emit the identity name so the caller can set SIGN_IDENTITY from it.
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
if [ -z "$IDENTITY" ]; then
    echo "ERROR: no Developer ID Application identity found in the imported keychain." >&2
    security find-identity -v -p codesigning "$KEYCHAIN" >&2 || true
    exit 1
fi
echo "$IDENTITY"
