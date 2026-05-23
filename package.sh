#!/bin/bash
# Package VoiceNote as .app bundle
# Usage: ./package.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="VoiceNote.app"
APP_DIR="$BUILD_DIR/$APP_NAME"

# Build first if binary doesn't exist
if [ ! -f "$BUILD_DIR/VoiceNote" ]; then
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
cp "$BUILD_DIR/VoiceNote" "$APP_DIR/Contents/MacOS/"

# Copy Info.plist
cp "$PROJECT_DIR/VoiceNote/Info.plist" "$APP_DIR/Contents/"

# Copy packaged resources
if [ -d "$PROJECT_DIR/VoiceNote/Resources" ]; then
    cp -R "$PROJECT_DIR/VoiceNote/Resources/"* "$APP_DIR/Contents/Resources/"
fi

# Bundle whisper.cpp runtime binaries and dylibs when available.
WHISPER_BIN_DIR="${WHISPER_BIN_DIR:-$HOME/whisper.cpp/build/bin}"
"$PROJECT_DIR/scripts/bundle-whisper-runtime.sh" "$APP_DIR" "$WHISPER_BIN_DIR"

# Copy entitlements
if [ -f "$PROJECT_DIR/VoiceNote/VoiceNote.entitlements" ]; then
    cp "$PROJECT_DIR/VoiceNote/VoiceNote.entitlements" "$APP_DIR/Contents/"
fi

# Code sign (ad-hoc)
echo "Signing with ad-hoc certificate..."
codesign --force --deep --sign - "$APP_DIR"

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
echo "  2. Let VoiceNote download the selected model into Application Support"
