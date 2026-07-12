#!/bin/bash
# Fixture-driven self-test for scripts/gen-appcast.sh (MAK-56).
#
# Generates a throwaway EdDSA keypair, signs a dummy "DMG", runs the appcast
# generator, and asserts the output is well-formed XML carrying the right
# version/build/length/enclosure-url and a signature that VERIFIES against the
# throwaway key. No secrets, no network — safe to run locally and in CI.
#
# Exits non-zero on any failure.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[test-gen-appcast] fetching Sparkle tools..."
# Reuse the pinned fetch so we get the matching generate_keys/sign_update.
eval "$("$PROJECT_DIR/scripts/fetch-sparkle.sh")"
SIGN_TOOL="$SPARKLE_BIN/sign_update"
GEN_KEYS="$SPARKLE_BIN/generate_keys"

fail() { echo "[test-gen-appcast] FAIL: $*" >&2; exit 1; }

# --- Throwaway keypair (file-only, never touches the real Keychain account) ---
# Use a unique account name so it can't collide with a developer's real key, and
# export the seed to a file for the generator + verify.
ACCOUNT="openwhisp-test-$$"
SEED="$WORK/seed.txt"
"$GEN_KEYS" --account "$ACCOUNT" >/dev/null 2>&1 || true
"$GEN_KEYS" --account "$ACCOUNT" -x "$SEED" >/dev/null 2>&1 \
    || fail "could not export throwaway private key (keychain access?)"
PRIV="$(cat "$SEED")"
[ -n "$PRIV" ] || fail "empty throwaway private key"

# --- Dummy DMG ----------------------------------------------------------------
DMG="$WORK/OpenWhisp.dmg"
head -c 8192 /dev/urandom > "$DMG"
EXPECTED_LEN="$(stat -f%z "$DMG" 2>/dev/null || stat -c%s "$DMG")"

# --- Generate the appcast -----------------------------------------------------
OUT="$WORK/appcast.xml"
TAG="v9.9.9+123"
URL="https://github.com/initcore0/openwhisp/releases/download/$TAG/OpenWhisp.dmg"
NOTES="https://github.com/initcore0/openwhisp/releases/tag/$TAG"
SPARKLE_ED_PRIVATE_KEY="$PRIV" "$PROJECT_DIR/scripts/gen-appcast.sh" \
    --version 9.9.9 \
    --build 123 \
    --dmg "$DMG" \
    --url "$URL" \
    --notes-link "$NOTES" \
    --sign-tool "$SIGN_TOOL" \
    --changelog "$PROJECT_DIR/docs/changelog/changelog.json" \
    --out "$OUT"

# --- Assertions ---------------------------------------------------------------
command -v xmllint >/dev/null 2>&1 && { xmllint --noout "$OUT" || fail "appcast is not well-formed XML"; }

python3 - "$OUT" "$EXPECTED_LEN" "$URL" <<'PY' || fail "structural assertions failed"
import sys, xml.etree.ElementTree as ET
path, expected_len, expected_url = sys.argv[1], sys.argv[2], sys.argv[3]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(path).getroot()
items = root.findall(".//item")
assert len(items) == 1, f"expected 1 item, got {len(items)}"
item = items[0]
enc = item.find("enclosure")
assert enc is not None, "missing enclosure"
assert enc.get("url") == expected_url, f"enclosure url mismatch: {enc.get('url')}"
assert enc.get("length") == expected_len, f"length mismatch: {enc.get('length')} != {expected_len}"
sig = enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
assert sig, "missing sparkle:edSignature"
assert item.find("sparkle:shortVersionString", ns).text == "9.9.9"
assert item.find("sparkle:version", ns).text == "123"
assert enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}version") == "123"
print("structure OK")
PY

# --- Signature must verify against the throwaway key --------------------------
SIG="$(python3 -c "import re,sys; print(re.search(r'sparkle:edSignature=\"([^\"]+)\"', open(sys.argv[1]).read()).group(1))" "$OUT")"
printf '%s' "$PRIV" | "$SIGN_TOOL" --ed-key-file - --verify "$DMG" "$SIG" \
    || fail "signature did not verify against the signing key"

# Clean up the throwaway keychain item so repeated runs don't accumulate keys.
security delete-generic-password -s "https://sparkle-project.org" -a "$ACCOUNT" >/dev/null 2>&1 || true

echo "[test-gen-appcast] PASS — appcast well-formed, structured, and signature verifies."
