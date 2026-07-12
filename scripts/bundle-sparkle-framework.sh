#!/bin/bash
# Copy Sparkle.framework into an .app bundle's Contents/Frameworks and, when a
# real signing identity is given, re-sign every nested component INNERMOST-FIRST
# with the hardened runtime — the order notarization requires for a Developer ID
# build. Shared by package.sh (ad-hoc, local dev) and build-dmg.sh (release).
#
# Sparkle ships pre-signed by the Sparkle project, but a Developer-ID app must
# re-sign the framework and its nested helpers (XPCServices, Autoupdate,
# Updater.app) under its own identity + hardened runtime or notarization/
# Gatekeeper rejects the mismatched inner code. `--deep` is unreliable with the
# hardened runtime, so we sign each piece explicitly (mirrors the inside-out
# signing build-dmg.sh already does for the whisper/llama helpers).
#
# Usage:
#   bundle-sparkle-framework.sh <APP_DIR> <SPARKLE_FRAMEWORK> [SIGN_IDENTITY] [HARDENED...]
#
#   APP_DIR            the .app bundle
#   SPARKLE_FRAMEWORK  path to the extracted Sparkle.framework (from fetch-sparkle.sh)
#   SIGN_IDENTITY      optional; if omitted or "-", signs ad-hoc without hardening
#   HARDENED...        optional extra codesign flags (e.g. --options runtime --timestamp)
#
# No-op (with a clear log line) when SPARKLE_FRAMEWORK is empty — that's the
# SPARKLE=0 lean build, where there's nothing to bundle.
set -euo pipefail

APP_DIR="${1:?usage: bundle-sparkle-framework.sh <APP_DIR> <SPARKLE_FRAMEWORK> [SIGN_IDENTITY] [HARDENED...]}"
SPARKLE_FRAMEWORK="${2:-}"
SIGN_IDENTITY="${3:-}"
shift $(( $# < 3 ? $# : 3 )) || true
HARDENED_ARGS=("$@")

if [ -z "$SPARKLE_FRAMEWORK" ] || [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "Sparkle: no framework to bundle (SPARKLE=0 lean build) — skipping." >&2
    exit 0
fi

FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
DEST="$FRAMEWORKS_DIR/Sparkle.framework"

echo "Sparkle: copying framework into $FRAMEWORKS_DIR" >&2
rm -rf "$DEST"
# -R preserves the versioned-framework symlinks (Versions/Current, etc.).
cp -R "$SPARKLE_FRAMEWORK" "$DEST"

# Ad-hoc / no identity: leave Sparkle's own signature in place. package.sh's
# subsequent `codesign --deep --sign -` reseals the whole bundle for local dev.
if [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Sparkle: no Developer ID identity — leaving framework signature for the app's --deep ad-hoc reseal." >&2
    exit 0
fi

echo "Sparkle: re-signing nested components with '$SIGN_IDENTITY' (hardened, innermost-first)..." >&2
V="$DEST/Versions/Current"

# Innermost-first. XPC services and the Updater.app are self-contained bundles;
# sign their inner Mach-O then the bundle, then Autoupdate, then the framework.
sign() { codesign --force "${HARDENED_ARGS[@]+"${HARDENED_ARGS[@]}"}" --sign "$SIGN_IDENTITY" "$@"; }

# XPC services (each is a bundle with a single Mach-O executable inside).
for xpc in "$V/XPCServices/"*.xpc; do
    [ -e "$xpc" ] || continue
    sign "$xpc"
done

# The Updater.app (a nested app bundle) and its executable.
if [ -d "$V/Updater.app" ]; then
    sign "$V/Updater.app/Contents/MacOS/Updater"
    sign "$V/Updater.app"
fi

# The Autoupdate helper executable.
[ -e "$V/Autoupdate" ] && sign "$V/Autoupdate"

# Finally the framework itself (this seals the versioned bundle).
sign "$DEST"

echo "Sparkle: nested signing complete." >&2
