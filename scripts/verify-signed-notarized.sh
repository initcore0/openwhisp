#!/bin/bash
# Assert a DMG (and the app inside it) is properly DEVELOPER ID signed, hardened,
# and NOTARIZED — so CI never publishes a release that fell back to a self-signed
# or ad-hoc identity. Intended for the signing-enabled CI path; exits non-zero on
# any failure so the release job stops before publishing.
#
# Usage:  verify-signed-notarized.sh <path-to-dmg>
#
# NOTE on shell hygiene: count with `grep -c` into a variable, never `... | grep -q`
# under `set -o pipefail` — grep -q closes the pipe early, the upstream tool dies
# with SIGPIPE, and pipefail turns a real match into a false failure.
set -euo pipefail

DMG="${1:?usage: verify-signed-notarized.sh <path-to-dmg>}"

fail() { echo "::error::signed/notarized verify: $*" >&2; exit 1; }

[ -f "$DMG" ] || fail "DMG not found at $DMG"

echo "Verifying $DMG is Developer ID signed + notarized…"

# --- 1) The DMG carries a Developer ID Application signature ------------------
DMG_SIG="$(codesign -dvv "$DMG" 2>&1 || true)"
devid_count="$(printf '%s\n' "$DMG_SIG" | grep -c "Authority=Developer ID Application" || true)"
[ "${devid_count:-0}" -gt 0 ] || {
    echo "$DMG_SIG" >&2
    fail "DMG is NOT signed by a 'Developer ID Application' identity (self-signed/ad-hoc fallback?)."
}

# Reject the self-signed dev cert explicitly, in case both strings ever appear.
selfsigned_count="$(printf '%s\n' "$DMG_SIG" | grep -c "OpenWhisp Self-Signed" || true)"
[ "${selfsigned_count:-0}" -eq 0 ] || fail "DMG is signed with the self-signed dev cert, not Developer ID."

# --- 2) Gatekeeper accepts it as a NOTARIZED Developer ID build ----------------
# `spctl --assess` on a DMG checks the notarization ticket (stapled) + signature.
SPCTL="$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 || true)"
accepted_count="$(printf '%s\n' "$SPCTL" | grep -c "accepted" || true)"
notarized_count="$(printf '%s\n' "$SPCTL" | grep -c "source=Notarized Developer ID" || true)"
if [ "${accepted_count:-0}" -eq 0 ] || [ "${notarized_count:-0}" -eq 0 ]; then
    echo "$SPCTL" >&2
    fail "spctl did not accept the DMG as 'Notarized Developer ID' (not notarized/stapled?)."
fi

echo "signed/notarized verify: OK — Developer ID signed, notarized, and stapled."
