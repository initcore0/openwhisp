#!/bin/bash
# Create a distributable VoiceNote DMG.
# Usage: ./create-dmg.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$BUILD_DIR/VoiceNote.app"
STAGE_DIR="$BUILD_DIR/dmg-stage"
DMG_PATH="$DIST_DIR/VoiceNote.dmg"
VOL_NAME="VoiceNote"

echo "=== VoiceNote DMG Builder ==="

echo ""
echo "Step 1: Building app bundle..."
"$PROJECT_DIR/package.sh"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App bundle not found at $APP_PATH"
    exit 1
fi

echo ""
echo "Step 2: Staging DMG contents..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

echo ""
echo "Step 3: Creating compressed DMG..."
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo ""
echo "Step 4: Verifying DMG..."
hdiutil verify "$DMG_PATH"

echo ""
echo "✓ DMG created: $DMG_PATH"
echo ""
echo "Transfer this file to another Mac, open it, then drag VoiceNote.app to Applications."
