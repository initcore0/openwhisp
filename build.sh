#!/bin/bash
# OpenWhisp Build Script
# Usage: ./build.sh [debug|release]

set -e

CONFIG="${1:-debug}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"

echo "=== OpenWhisp Build Script ==="
echo "Config: $CONFIG"
echo "Dir: $PROJECT_DIR"

# Check for Xcode
if ! command -v xcrun &> /dev/null; then
    echo "ERROR: Xcode command line tools not found."
    echo "Install with: xcode-select --install"
    exit 1
fi

# Create build directory
mkdir -p "$BUILD_DIR"

# Generate Xcode project from Swift files
echo ""
echo "Step 1: Compiling Swift files..."

SWIFT_FILES=$(find "$PROJECT_DIR/OpenWhisp" -name "*.swift" | tr '\n' ' ')

# WhisperKit backend. ON BY DEFAULT (it's the default transcription engine); opt
# out with WHISPERKIT=0 for a lean build. The link-args logic is shared with
# build-dmg.sh so the two compile paths never drift. See docs/WHISPERKIT_PILOT.md.
# shellcheck source=scripts/whisperkit-link-args.sh
source "$PROJECT_DIR/scripts/whisperkit-link-args.sh"
resolve_whisperkit_args

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
    "${WHISPERKIT_ARGS[@]}" \
    $SWIFT_FILES \
    -o "$BUILD_DIR/OpenWhisp" \
    2>&1

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Build successful!"
    echo "Output: $BUILD_DIR/OpenWhisp"
    echo ""
    echo "To create an .app bundle, run:"
    echo "  ./package.sh"
else
    echo ""
    echo "✗ Build failed. See errors above."
    exit 1
fi
