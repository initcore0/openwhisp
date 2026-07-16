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
done < <(find "$PROJECT_DIR/OpenWhisp" -name "*.swift" -not -path "*/SyncLoopback/*")
# SyncLoopback/ is a standalone SwiftPM executable target (the sync loopback
# harness). Its main.swift has top-level executable code + an OpenWhispCore import,
# so it must NOT be folded into the mac app's single-module glob.

# Stamp the build with its git commit (shown in Settings › Advanced) — the
# generated file lives in build/, outside the source glob, and is regenerated
# every build.
# shellcheck source=scripts/generate-build-info.sh
source "$PROJECT_DIR/scripts/generate-build-info.sh"
SWIFT_FILES+=("$(generate_build_info "$BUILD_DIR")")

# WhisperKit backend. ON BY DEFAULT (it's the default transcription engine); opt
# out with WHISPERKIT=0 for a lean build. The link-args logic is shared with
# build-dmg.sh so the two compile paths never drift. See docs/WHISPERKIT_PILOT.md.
# shellcheck source=scripts/whisperkit-link-args.sh
source "$PROJECT_DIR/scripts/whisperkit-link-args.sh"
resolve_whisperkit_args

# Parakeet/FluidAudio streaming backend (MAK-46). ON by default; opt out with
# PARAKEET=0 ./build.sh for a lean build. See docs/PARAKEET.md.
# shellcheck source=scripts/fluidaudio-link-args.sh
source "$PROJECT_DIR/scripts/fluidaudio-link-args.sh"
resolve_fluidaudio_args

# Sparkle auto-update framework (MAK-56). ON by default; opt out with
# SPARKLE=0 ./build.sh for a lean build (all Sparkle code is #if SPARKLE gated).
# The link-args logic is shared with build-dmg.sh so the two compile paths never
# drift. See docs/AUTO_UPDATE.md.
# shellcheck source=scripts/sparkle-link-args.sh
source "$PROJECT_DIR/scripts/sparkle-link-args.sh"
resolve_sparkle_args
# Dev-only extra rpath: the shared args carry just the in-bundle rpath
# (@executable_path/../Frameworks), which only resolves once package.sh copies
# the framework into an .app — leaving the bare build/OpenWhisp binary unable
# to launch (dyld: Library not loaded: @rpath/Sparkle.framework). Point a second
# rpath at the extracted framework so the dev binary runs in place. build-dmg.sh
# deliberately does NOT get this: shipped binaries carry no local paths.
if [ -n "${SPARKLE_FRAMEWORK:-}" ]; then
    SPARKLE_ARGS+=( -Xlinker -rpath -Xlinker "$(dirname "$SPARKLE_FRAMEWORK")" )
fi

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
    "${FLUIDAUDIO_ARGS[@]+"${FLUIDAUDIO_ARGS[@]}"}" \
    "${SPARKLE_ARGS[@]+"${SPARKLE_ARGS[@]}"}" \
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
