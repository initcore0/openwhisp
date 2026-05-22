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

# Copy binary
cp "$BUILD_DIR/VoiceNote" "$APP_DIR/Contents/MacOS/"

# Copy Info.plist
cp "$PROJECT_DIR/VoiceNote/Info.plist" "$APP_DIR/Contents/"

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
echo "Before first use, install whisper.cpp:"
echo "  1. Install whisper.cpp (see README.md)"
echo "  2. Download a model to ~/whisper.cpp/models/"
echo "  3. Grant microphone access in System Settings"
