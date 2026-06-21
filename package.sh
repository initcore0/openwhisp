#!/bin/bash
# Package OpenWhisp as .app bundle
# Usage: ./package.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="OpenWhisp.app"
APP_DIR="$BUILD_DIR/$APP_NAME"

# Build first if binary doesn't exist
if [ ! -f "$BUILD_DIR/OpenWhisp" ]; then
    echo "Binary not found. Building first..."
    ./build.sh
fi

# Clean old bundle
rm -rf "$APP_DIR"

# Create app structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources/whisper"
mkdir -p "$APP_DIR/Contents/Resources/models"

# Copy binary
cp "$BUILD_DIR/OpenWhisp" "$APP_DIR/Contents/MacOS/"

# Copy Info.plist
cp "$PROJECT_DIR/OpenWhisp/Info.plist" "$APP_DIR/Contents/"

# Copy packaged resources
if [ -d "$PROJECT_DIR/OpenWhisp/Resources" ]; then
    cp -R "$PROJECT_DIR/OpenWhisp/Resources/"* "$APP_DIR/Contents/Resources/"
fi

# Bundle whisper.cpp runtime binaries and dylibs when available.
WHISPER_BIN_DIR="${WHISPER_BIN_DIR:-$PROJECT_DIR/third_party/whisper.cpp/build/bin}"
"$PROJECT_DIR/scripts/bundle-whisper-runtime.sh" "$APP_DIR" "$WHISPER_BIN_DIR"

# Copy entitlements
if [ -f "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements" ]; then
    cp "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements" "$APP_DIR/Contents/"
fi

# Code sign. Prefer a stable signing identity so TCC permissions (Microphone,
# Accessibility, Input Monitoring) survive rebuilds. Priority:
#   1) SIGN_IDENTITY env var (e.g. a "Developer ID Application: ..." cert)
#   2) the self-signed "OpenWhisp Self-Signed" cert (scripts/create-signing-cert.sh)
#   3) ad-hoc ("-") — works, but re-prompts for permissions every build
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "OpenWhisp Self-Signed"; then
    SIGN_IDENTITY="OpenWhisp Self-Signed"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    echo "Signing ad-hoc (permissions WILL be re-requested each build)."
    echo "  Tip: run scripts/create-signing-cert.sh once for a stable identity."
else
    echo "Signing with identity: $SIGN_IDENTITY"
fi

ENTITLEMENTS_ARGS=()
if [ -f "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements" ]; then
    ENTITLEMENTS_ARGS=(--entitlements "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements")
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "${ENTITLEMENTS_ARGS[@]}" "$APP_DIR"

echo ""
echo "✓ App bundle created: $APP_DIR"
echo ""
echo "Run with:"
echo "  open $APP_DIR"
echo ""
echo "Packaged whisper runtime:"
ls -1 "$APP_DIR/Contents/Resources/whisper" 2>/dev/null || true
echo ""
echo "Before first use:"
echo "  1. Grant microphone/accessibility/input monitoring permissions"
echo "  2. Let OpenWhisp download the selected model into Application Support"
