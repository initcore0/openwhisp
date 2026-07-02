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

# Collect sources into an array so paths with spaces survive (no word-splitting).
SWIFT_FILES=()
while IFS= read -r f; do
    SWIFT_FILES+=("$f")
done < <(find "$PROJECT_DIR/OpenWhisp" -name "*.swift")

# WhisperKit backend. ON BY DEFAULT (it's the default transcription engine); opt
# out with WHISPERKIT=0 for a lean build. The link-args logic is shared with
# build-dmg.sh so the two compile paths never drift. See docs/WHISPERKIT_PILOT.md.
# shellcheck source=scripts/whisperkit-link-args.sh
source "$PROJECT_DIR/scripts/whisperkit-link-args.sh"
resolve_whisperkit_args

# Developer instrumentation (timing signposts + console logs). OFF by default;
# INSTRUMENTATION=1 ./build.sh defines OPENWHISP_INSTRUMENTATION. Shared with build-dmg.sh.
# shellcheck source=scripts/instrumentation-args.sh
source "$PROJECT_DIR/scripts/instrumentation-args.sh"
resolve_instrumentation_args

# swiftc runs inside the if condition so set -e doesn't abort before the
# failure branch can report.
if xcrun swiftc \
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
    "${INSTRUMENTATION_ARGS[@]+"${INSTRUMENTATION_ARGS[@]}"}" \
    "${SWIFT_FILES[@]}" \
    -o "$BUILD_DIR/OpenWhisp" \
    2>&1
then
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
