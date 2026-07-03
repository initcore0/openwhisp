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
    "${INSTRUMENTATION_ARGS[@]+"${INSTRUMENTATION_ARGS[@]}"}" \
    $SWIFT_FILES \
    -o "$BUILD_DIR/OpenWhisp"

echo ""
echo "Step 2: Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/whisper"
mkdir -p "$APP_DIR/Contents/Resources/llama"
mkdir -p "$APP_DIR/Contents/Resources/models"

cp "$BUILD_DIR/OpenWhisp" "$APP_DIR/Contents/MacOS/"
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

# Bundle the optional built-in LLM runtime when it has been built. Guarded so a
# whisper-only release still builds.
rm -rf "$APP_DIR/Contents/Resources/llama"
mkdir -p "$APP_DIR/Contents/Resources/llama"
if [ -x "$LLAMA_BIN_DIR/llama-server" ]; then
    echo ""
    echo "Step 3b: Bundling llama.cpp runtime (built-in LLM)..."
    "$PROJECT_DIR/scripts/bundle-llama-runtime.sh" "$APP_DIR" "$LLAMA_BIN_DIR"
else
    echo "(skipping llama runtime: no llama-server at $LLAMA_BIN_DIR — run scripts/build-llama.sh to include the bundled LLM)"
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
    find "$APP_DIR/Contents/Resources" -type f \( -name "*.dylib" -o -perm -111 \) 2>/dev/null
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
    # profile (local). Build the arg array so the password never appears in `set -x`.
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

    # Submit and block until Apple returns a verdict; --wait fails non-zero if the
    # notarization is rejected (the log URL in the output explains why).
    xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait

    # Staple the ticket so the DMG passes Gatekeeper offline.
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature -v "$DMG_PATH" || true

    echo "✓ Notarized + stapled."
fi

echo ""
echo "✓ Done"
echo "App: $APP_DIR"
echo "DMG: $DMG_PATH"
