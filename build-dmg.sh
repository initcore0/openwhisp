#!/bin/bash
# Build OpenWhisp, package OpenWhisp.app, and create a distributable DMG.
# Usage:
#   ./build-dmg.sh [debug|release]
#
# Optional:
#   WHISPER_BIN_DIR=/path/to/whisper.cpp/build/bin ./build-dmg.sh

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
mkdir -p "$APP_DIR/Contents/Resources/models"

cp "$BUILD_DIR/OpenWhisp" "$APP_DIR/Contents/MacOS/"
cp "$PROJECT_DIR/OpenWhisp/Info.plist" "$APP_DIR/Contents/"

if [ -f "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements" ]; then
    cp "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements" "$APP_DIR/Contents/"
fi

if [ -d "$PROJECT_DIR/OpenWhisp/Resources" ]; then
    cp -R "$PROJECT_DIR/OpenWhisp/Resources/"* "$APP_DIR/Contents/Resources/"
fi

echo ""
echo "Step 3: Bundling whisper.cpp runtime..."
"$PROJECT_DIR/scripts/bundle-whisper-runtime.sh" "$APP_DIR" "$WHISPER_BIN_DIR"

echo ""
echo "Step 4: Signing app bundle..."
# Prefer a stable identity (SIGN_IDENTITY env, else the self-signed OpenWhisp cert)
# so TCC permissions survive rebuilds; fall back to ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "OpenWhisp Self-Signed"; then
    SIGN_IDENTITY="OpenWhisp Self-Signed"
fi
[ -z "$SIGN_IDENTITY" ] && SIGN_IDENTITY="-"
echo "  Using identity: $SIGN_IDENTITY"
ENTITLEMENTS_ARGS=()
if [ -f "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements" ]; then
    ENTITLEMENTS_ARGS=(--entitlements "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements")
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "${ENTITLEMENTS_ARGS[@]}" "$APP_DIR"
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

echo ""
echo "✓ Done"
echo "App: $APP_DIR"
echo "DMG: $DMG_PATH"
