#!/bin/bash
# Build VoiceNote, package VoiceNote.app, and create a distributable DMG.
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
APP_NAME="VoiceNote.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
STAGE_DIR="$BUILD_DIR/dmg-stage"
DMG_PATH="$DIST_DIR/VoiceNote.dmg"
VOL_NAME="VoiceNote"
WHISPER_BIN_DIR="${WHISPER_BIN_DIR:-$HOME/whisper.cpp/build/bin}"

echo "=== VoiceNote Full DMG Build ==="
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
SWIFT_FILES=$(find "$PROJECT_DIR/VoiceNote" -name "*.swift" | tr '\n' ' ')

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
    $SWIFT_FILES \
    -o "$BUILD_DIR/VoiceNote"

echo ""
echo "Step 2: Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/whisper"
mkdir -p "$APP_DIR/Contents/Resources/models"

cp "$BUILD_DIR/VoiceNote" "$APP_DIR/Contents/MacOS/"
cp "$PROJECT_DIR/VoiceNote/Info.plist" "$APP_DIR/Contents/"

if [ -f "$PROJECT_DIR/VoiceNote/VoiceNote.entitlements" ]; then
    cp "$PROJECT_DIR/VoiceNote/VoiceNote.entitlements" "$APP_DIR/Contents/"
fi

if [ -d "$PROJECT_DIR/VoiceNote/Resources" ]; then
    cp -R "$PROJECT_DIR/VoiceNote/Resources/"* "$APP_DIR/Contents/Resources/"
fi

echo ""
echo "Step 3: Bundling whisper.cpp runtime..."
"$PROJECT_DIR/scripts/bundle-whisper-runtime.sh" "$APP_DIR" "$WHISPER_BIN_DIR"

echo ""
echo "Step 4: Signing app bundle..."
if [ -f "$PROJECT_DIR/VoiceNote/VoiceNote.entitlements" ]; then
    codesign --force --deep --sign - --entitlements "$PROJECT_DIR/VoiceNote/VoiceNote.entitlements" "$APP_DIR"
else
    codesign --force --deep --sign - "$APP_DIR"
fi
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
