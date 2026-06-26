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

# Optional WhisperKit backend (pilot). With WHISPERKIT=1, build the WhisperKit
# dependency as a single static lib and link it in, defining the WHISPERKIT flag
# that activates the real WhisperKitEngine (otherwise it's a stub). Default build
# is unaffected. See docs/WHISPERKIT_PILOT.md.
WHISPERKIT_ARGS=()
if [ "${WHISPERKIT:-0}" = "1" ]; then
    echo "WhisperKit backend: building dependency..."
    WK_VARS="$("$PROJECT_DIR/scripts/build-whisperkit.sh")"
    eval "$WK_VARS"
    if [ -z "$WHISPERKIT_MODULES" ] || [ -z "$WHISPERKIT_LIBDIR" ]; then
        echo "ERROR: WhisperKit build did not produce link paths." >&2
        exit 1
    fi
    WHISPERKIT_ARGS=(
        -D WHISPERKIT
        -I "$WHISPERKIT_MODULES"
        -L "$WHISPERKIT_LIBDIR"
        -lWhisperKitDep
    )
    # Clang module-map flags for C deps (yyjson, etc.); word-split intentionally.
    # shellcheck disable=SC2206
    WHISPERKIT_ARGS+=( $WHISPERKIT_CC_ARGS )
    echo "WhisperKit backend: linking $WHISPERKIT_LIBDIR/libWhisperKitDep.a"
fi

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
