#!/bin/bash
# Build OpenWhisp, package OpenWhisp.app, and create a distributable DMG.
# Usage:
#   ./build-dmg.sh [debug|release]
#
# Optional:
#   WHISPER_BIN_DIR=/path/to/whisper.cpp/build/bin ./build-dmg.sh
#   LLAMA_BIN_DIR=/path/to/llama.cpp/build/bin ./build-dmg.sh   # bundles the optional built-in LLM

set -euo pipefail

CONFIG="${1:-debug}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="OpenWhisp.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
STAGE_DIR="$BUILD_DIR/dmg-stage"
DMG_PATH="$DIST_DIR/OpenWhisp.dmg"
VOL_NAME="OpenWhisp"
WHISPER_BIN_DIR="${WHISPER_BIN_DIR:-$PROJECT_DIR/third_party/whisper.cpp/build/bin}"
LLAMA_BIN_DIR="${LLAMA_BIN_DIR:-$PROJECT_DIR/third_party/llama.cpp/build/bin}"

echo "=== OpenWhisp Full DMG Build ==="
echo "Config: $CONFIG"
echo "Project: $PROJECT_DIR"

if ! command -v xcrun >/dev/null 2>&1; then
    echo "ERROR: Xcode command line tools not found."
    echo "Install with: xcode-select --install"
    exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
    echo "ERROR: hdiutil not found."
    exit 1
fi

mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo ""
echo "Step 1: Compiling Swift app..."
SWIFT_FILES=$(find "$PROJECT_DIR/OpenWhisp" -name "*.swift" | tr '\n' ' ')

# WhisperKit backend (ON BY DEFAULT; WHISPERKIT=0 for a lean build). Shared with
# build.sh via the same helper so the released DMG includes WhisperKit exactly the
# way a local build does.
# shellcheck source=scripts/whisperkit-link-args.sh
source "$PROJECT_DIR/scripts/whisperkit-link-args.sh"
resolve_whisperkit_args

# Parakeet/FluidAudio streaming backend (MAK-46 spike; OFF by default,
# PARAKEET=1 to include). Shared with build.sh.
# shellcheck source=scripts/fluidaudio-link-args.sh
source "$PROJECT_DIR/scripts/fluidaudio-link-args.sh"
resolve_fluidaudio_args

# Developer instrumentation (OFF by default; INSTRUMENTATION=1 to enable). Shared
# with build.sh. Release DMGs are built without it.
# shellcheck source=scripts/instrumentation-args.sh
source "$PROJECT_DIR/scripts/instrumentation-args.sh"
resolve_instrumentation_args

xcrun swiftc \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -parse-as-library \
    -emit-executable \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Speech \
    -framework Foundation \
    -framework SwiftUI \
    -framework UserNotifications \
    -framework Security \
    -framework CoreAudio \
    -framework CoreGraphics \
    "${WHISPERKIT_ARGS[@]+"${WHISPERKIT_ARGS[@]}"}" \
    "${FLUIDAUDIO_ARGS[@]+"${FLUIDAUDIO_ARGS[@]}"}" \
    "${INSTRUMENTATION_ARGS[@]+"${INSTRUMENTATION_ARGS[@]}"}" \
    $SWIFT_FILES \
    -o "$BUILD_DIR/OpenWhisp"

# Guard: never ship a DMG whose binary is a WhisperKit stub (unless WHISPERKIT=0).
# shellcheck source=scripts/verify-whisperkit-binary.sh
source "$PROJECT_DIR/scripts/verify-whisperkit-binary.sh"
verify_whisperkit_binary "$BUILD_DIR/OpenWhisp"

# Build the openwhisp CLI / MCP adapter (separate SwiftPM executable). Bundled
# into Contents/Helpers and signed inside-out with the hardened runtime below.
echo "Building openwhisp CLI..."
swift build -c release --product openwhisp
CLI_BIN="$(swift build -c release --product openwhisp --show-bin-path)/openwhisp"

echo ""
echo "Step 2: Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/whisper"
mkdir -p "$APP_DIR/Contents/Resources/llama"
mkdir -p "$APP_DIR/Contents/Resources/models"

cp "$BUILD_DIR/OpenWhisp" "$APP_DIR/Contents/MacOS/"
mkdir -p "$APP_DIR/Contents/Helpers"
cp "$CLI_BIN" "$APP_DIR/Contents/Helpers/openwhisp"
cp "$PROJECT_DIR/OpenWhisp/Info.plist" "$APP_DIR/Contents/"

# NOTE: the .entitlements file is a BUILD INPUT (passed to codesign --entitlements
# below), NOT a bundle resource — it's baked into the signature, not read at runtime.
# Don't copy it into Contents/: an unsigned stray file there fails `codesign --verify
# --deep --strict` (and would break notarization).

if [ -d "$PROJECT_DIR/OpenWhisp/Resources" ]; then
    cp -R "$PROJECT_DIR/OpenWhisp/Resources/"* "$APP_DIR/Contents/Resources/"
fi

echo ""
echo "Step 3: Bundling whisper.cpp runtime..."
"$PROJECT_DIR/scripts/bundle-whisper-runtime.sh" "$APP_DIR" "$WHISPER_BIN_DIR"

# Bundle the built-in LLM runtime. The app DEFAULTS to the "On this Mac
# (built-in)" AI provider, so a release DMG without llama-server ships a broken
# built-in AI (every refine fails with "built-in model unavailable") — hard-fail
# release builds that lack it. Dev builds may still skip it, loudly.
rm -rf "$APP_DIR/Contents/Resources/llama"
mkdir -p "$APP_DIR/Contents/Resources/llama"
if [ -x "$LLAMA_BIN_DIR/llama-server" ]; then
    echo ""
    echo "Step 3b: Bundling llama.cpp runtime (built-in LLM)..."
    "$PROJECT_DIR/scripts/bundle-llama-runtime.sh" "$APP_DIR" "$LLAMA_BIN_DIR"
elif [ "$CONFIG" = "release" ]; then
    echo "ERROR: no llama-server at $LLAMA_BIN_DIR."
    echo "The built-in AI provider is the app default; a release DMG must include it."
    echo "Run scripts/build-llama.sh first."
    exit 1
else
    echo "WARNING: skipping llama runtime (no llama-server at $LLAMA_BIN_DIR)."
    echo "The built-in AI provider will be unavailable in this build — run scripts/build-llama.sh to include it."
fi

echo ""
echo "Step 4: Signing app bundle..."
# Identity selection. Priority:
#   1) SIGN_IDENTITY env (e.g. "Developer ID Application: Name (TEAMID)")
#   2) an installed Developer ID Application cert (auto-detected) — enables
#      hardened runtime + notarization (see NOTARIZE below)
#   3) the self-signed "OpenWhisp Self-Signed" cert (stable TCC across rebuilds)
#   4) ad-hoc ("-")
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    # `|| true`: a no-match grep exits 1, which would abort under `set -euo pipefail`.
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    DEV_ID_LINE="$(printf '%s\n' "$IDENTITIES" | grep "Developer ID Application" | head -1 || true)"
    if [ -n "$DEV_ID_LINE" ]; then
        # Extract the quoted cert name, e.g. Developer ID Application: Name (TEAMID)
        SIGN_IDENTITY="$(printf '%s' "$DEV_ID_LINE" | sed -E 's/.*"(.*)".*/\1/')"
    elif printf '%s\n' "$IDENTITIES" | grep -q "OpenWhisp Self-Signed"; then
        SIGN_IDENTITY="OpenWhisp Self-Signed"
    fi
fi
[ -z "$SIGN_IDENTITY" ] && SIGN_IDENTITY="-"
echo "  Using identity: $SIGN_IDENTITY"

# A real Developer ID identity gets the hardened runtime + a secure timestamp,
# which notarization REQUIRES. Ad-hoc and self-signed certs can't timestamp and
# aren't notarizable, so they sign plainly (unchanged behavior for local dev).
HARDENED_ARGS=()
case "$SIGN_IDENTITY" in
    "Developer ID Application"*) HARDENED_ARGS=(--options runtime --timestamp) ;;
esac

ENTITLEMENTS_ARGS=()
if [ -f "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements" ]; then
    ENTITLEMENTS_ARGS=(--entitlements "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements")
fi

# Sign INSIDE-OUT. `--deep` is unreliable with the hardened runtime (it can skip
# nested Mach-O and mis-apply flags), so sign the bundled dylibs and helper
# executables (whisper-server/-cli, llama-server) individually first, then the app.
# Nested code takes the hardened runtime but NOT the app entitlements.
NESTED=()
while IFS= read -r f; do NESTED+=("$f"); done < <(
    find "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers" -type f \( -name "*.dylib" -o -perm -111 \) 2>/dev/null
)
if [ "${#NESTED[@]}" -gt 0 ]; then
    echo "  Signing ${#NESTED[@]} nested libraries/executables..."
    for f in "${NESTED[@]}"; do
        codesign --force "${HARDENED_ARGS[@]+"${HARDENED_ARGS[@]}"}" --sign "$SIGN_IDENTITY" "$f"
    done
fi

codesign --force "${HARDENED_ARGS[@]+"${HARDENED_ARGS[@]}"}" --sign "$SIGN_IDENTITY" "${ENTITLEMENTS_ARGS[@]+"${ENTITLEMENTS_ARGS[@]}"}" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo ""
echo "Step 5: Staging DMG..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo ""
echo "Step 6: Creating compressed DMG..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo ""
echo "Step 7: Verifying DMG..."
hdiutil verify "$DMG_PATH"

# Optional: notarize + staple the DMG so Gatekeeper opens it with no warning on
# other Macs. OFF by default; enable with NOTARIZE=1. Needs a Developer ID identity
# (above) plus notary credentials, supplied one of two ways:
#
#   (a) Local — a stored notarytool keychain profile (NOTARY_PROFILE, default
#       "openwhisp-notary"), created once with:
#         xcrun notarytool store-credentials "openwhisp-notary" \
#           --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW
#
#   (b) CI — direct credentials via env: NOTARY_APPLE_ID + NOTARY_TEAM_ID +
#       NOTARY_PASSWORD (an app-specific password). Takes precedence when set, so no
#       keychain profile is needed on an ephemeral runner.
if [ "${NOTARIZE:-0}" = "1" ]; then
    echo ""
    echo "Step 8: Notarizing DMG..."

    case "$SIGN_IDENTITY" in
        "Developer ID Application"*) : ;;
        *)
            echo "ERROR: NOTARIZE=1 needs a Developer ID Application identity, but signed with '$SIGN_IDENTITY'." >&2
            echo "       Install your Developer ID cert (see docs) or pass SIGN_IDENTITY=..." >&2
            exit 1
            ;;
    esac

    # Choose the notarytool credential source: direct env creds (CI) or a keychain
    # profile (local). Note: with direct creds the password is passed on the
    # notarytool command line (briefly visible to `ps` on the machine; notarytool
    # has no @env: syntax). Acceptable on an ephemeral single-tenant CI runner —
    # prefer the keychain profile on shared/local machines. Never enable `set -x`
    # around this block; it would print the password.
    NOTARY_ARGS=()
    if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
        echo "  Using direct notary credentials (Apple ID: $NOTARY_APPLE_ID)"
        NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
    else
        NOTARY_PROFILE="${NOTARY_PROFILE:-openwhisp-notary}"
        echo "  Using keychain profile: $NOTARY_PROFILE"
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    fi

    # The DMG itself must be signed with the same Developer ID before submission.
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

    # Submit and block until Apple returns a verdict. We capture the JSON and assert
    # status == "Accepted" BEFORE stapling, rather than trusting the exit code alone.
    # Why: a rejected/Invalid submission that still exits 0 (or an "Accepted" we
    # misread) would otherwise fall through to stapling and surface as a confusing
    # "Record not found" / Error 65 — the exact mis-diagnosis behind wrong-cert reports
    # (e.g. signing with an Apple Distribution cert instead of Developer ID). Parsing
    # the real status turns that into a clear, actionable failure + the notary log.
    echo "Submitting to Apple notary service..."
    SUBMIT_JSON="$(xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait --output-format json)" || true
    echo "$SUBMIT_JSON"
    NOTARY_STATUS="$(printf '%s' "$SUBMIT_JSON" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null \
        || printf '%s' "$SUBMIT_JSON" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    SUBMISSION_ID="$(printf '%s' "$SUBMIT_JSON" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null \
        || printf '%s' "$SUBMIT_JSON" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

    if [ "$NOTARY_STATUS" != "Accepted" ]; then
        echo "ERROR: notarization did not succeed (status: ${NOTARY_STATUS:-unknown})." >&2
        if [ -n "$SUBMISSION_ID" ]; then
            echo "Fetching the notary log for $SUBMISSION_ID:" >&2
            xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" >&2 || true
        fi
        echo "Common cause: signing with the wrong certificate type — you need a" >&2
        echo "'Developer ID Application' cert (NOT Apple Development / Apple Distribution)." >&2
        exit 1
    fi
    echo "Notarization Accepted (id: ${SUBMISSION_ID:-unknown})."

    # Staple the ticket so the DMG passes Gatekeeper OFFLINE. Notarization has
    # already succeeded above; stapling just embeds the ticket. But the ticket
    # propagates to Apple's CDN a little AFTER notarytool returns "Accepted", so an
    # immediate staple often fails with "Record not found" / "The staple and
    # validate action failed! Error 65" — a transient race, not a real error.
    # Retry with backoff until the ticket is available.
    echo "Stapling notarization ticket..."
    STAPLE_ATTEMPTS="${STAPLE_ATTEMPTS:-8}"
    STAPLE_DELAY="${STAPLE_DELAY:-15}"   # seconds; grows each attempt
    stapled=0
    attempt=1
    while [ "$attempt" -le "$STAPLE_ATTEMPTS" ]; do
        if xcrun stapler staple "$DMG_PATH"; then
            stapled=1
            break
        fi
        if [ "$attempt" -lt "$STAPLE_ATTEMPTS" ]; then
            wait_s=$(( STAPLE_DELAY * attempt ))
            echo "  Staple attempt $attempt/$STAPLE_ATTEMPTS failed (ticket may still be propagating); retrying in ${wait_s}s..."
            sleep "$wait_s"
        fi
        attempt=$(( attempt + 1 ))
    done

    if [ "$stapled" -ne 1 ]; then
        echo "ERROR: stapling failed after $STAPLE_ATTEMPTS attempts." >&2
        echo "       The DMG IS notarized (Gatekeeper will verify it online on first" >&2
        echo "       launch), but the ticket isn't embedded for offline checks. Re-run" >&2
        echo "       'xcrun stapler staple \"$DMG_PATH\"' in a few minutes once the" >&2
        echo "       ticket propagates — no rebuild/re-notarize needed." >&2
        exit 1
    fi

    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature -v "$DMG_PATH" || true

    echo "✓ Notarized + stapled."
fi

echo ""
echo "✓ Done"
echo "App: $APP_DIR"
echo "DMG: $DMG_PATH"
