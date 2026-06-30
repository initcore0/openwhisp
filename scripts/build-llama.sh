#!/bin/bash
# Build the bundled llama.cpp submodule (third_party/llama.cpp).
# Produces llama-server under third_party/llama.cpp/build/bin, which
# package.sh / build-dmg.sh then bundle into the .app under Resources/llama.
#
# This is SEPARATE from build.sh (the Swift app) and build-whisper.sh — the
# bundled LLM is opt-in, so a whisper-only / CI build never needs to run this.
#
# Usage: scripts/build-llama.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LLAMA_DIR="$PROJECT_DIR/third_party/llama.cpp"

if [ ! -e "$LLAMA_DIR/CMakeLists.txt" ]; then
    echo "ERROR: llama.cpp submodule not found at $LLAMA_DIR"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found. Install it (e.g. 'brew install cmake')."
    exit 1
fi

echo "=== Building llama.cpp ($(cd "$LLAMA_DIR" && git describe --tags --always 2>/dev/null || echo unknown)) ==="

# GGML_METAL=ON (NOT the deprecated LLAMA_METAL, which only warns and silently
# yields a CPU-only build). GGML_METAL_EMBED_LIBRARY bakes the Metal shaders into
# the binary so there is no stray .metallib to bundle. LLAMA_CURL=OFF so the
# server does not link a Homebrew libcurl that would dyld-fail on user machines
# (we download weights ourselves via ModelDownloader).
# LLAMA_OPENSSL=OFF: the server only ever serves plain HTTP on loopback, so it
# does not need HTTPS — and leaving it ON links Homebrew's OpenSSL, which would
# dyld-fail on user machines without Homebrew.
cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_CURL=OFF \
    -DLLAMA_OPENSSL=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$LLAMA_DIR/build" -j --config Release --target llama-server

SERVER_BIN="$LLAMA_DIR/build/bin/llama-server"
if [ ! -x "$SERVER_BIN" ]; then
    echo "ERROR: llama-server not produced at $SERVER_BIN"
    exit 1
fi

# Assertion: llama-server must not link a non-system libcurl (would dyld-fail on
# user machines that lack the Homebrew lib).
if otool -L "$SERVER_BIN" | grep -i curl | grep -qv '^[[:space:]]*/usr/lib/'; then
    echo "ERROR: llama-server links a non-system libcurl:"
    otool -L "$SERVER_BIN" | grep -i curl
    echo "Rebuild with -DLLAMA_CURL=OFF (already set; check the cmake cache)."
    exit 1
fi

# Assertion: no non-system OpenSSL link (Homebrew libssl/libcrypto would
# dyld-fail on user machines). Built with LLAMA_OPENSSL=OFF.
if otool -L "$SERVER_BIN" | grep -iE 'ssl|crypto' | grep -qv '^[[:space:]]*/usr/lib/'; then
    echo "ERROR: llama-server links a non-system OpenSSL:"
    otool -L "$SERVER_BIN" | grep -iE 'ssl|crypto'
    echo "Rebuild with -DLLAMA_OPENSSL=OFF (clear the cmake cache first)."
    exit 1
fi

# Assertion: Metal must be embedded (no loose .metallib left to bundle).
if find "$LLAMA_DIR/build" -name '*.metallib' | grep -q .; then
    echo "ERROR: a .metallib was produced — Metal was not embedded."
    echo "Ensure -DGGML_METAL_EMBED_LIBRARY=ON took effect."
    exit 1
fi

echo ""
echo "✓ llama.cpp built. Binaries:"
ls -1 "$LLAMA_DIR/build/bin/" 2>/dev/null | grep -E "llama-(server|cli)" || true
