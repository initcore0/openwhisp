#!/bin/bash
# Build the bundled whisper.cpp submodule (third_party/whisper.cpp).
# Produces whisper-cli and whisper-server under third_party/whisper.cpp/build/bin,
# which package.sh / build-dmg.sh then bundle into the .app.
#
# Usage: scripts/build-whisper.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_DIR="$PROJECT_DIR/third_party/whisper.cpp"

if [ ! -e "$WHISPER_DIR/CMakeLists.txt" ]; then
    echo "ERROR: whisper.cpp submodule not found at $WHISPER_DIR"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found. Install it (e.g. 'brew install cmake')."
    exit 1
fi

echo "=== Building whisper.cpp ($(cd "$WHISPER_DIR" && git describe --tags --always 2>/dev/null || echo unknown)) ==="
cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$WHISPER_DIR/build" -j --config Release --target whisper-cli whisper-server

echo ""
echo "✓ whisper.cpp built. Binaries:"
ls -1 "$WHISPER_DIR/build/bin/" 2>/dev/null | grep -E "whisper-(cli|server)" || true
