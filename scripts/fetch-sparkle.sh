#!/bin/bash
# Fetch the official prebuilt Sparkle 2 release artifact at a PINNED version with
# SHA-256 verification, and extract it into build/sparkle/. The binary is NOT
# vendored into git (build/ is gitignored) — this script materializes it on
# demand, mirroring how the other dependency helpers materialize their builds.
#
# Sparkle is ON BY DEFAULT (the app ships with auto-update). Opt out with
# SPARKLE=0 for a lean build without the framework — see scripts/sparkle-link-args.sh.
#
# Output (printed as KEY=VALUE for callers to eval):
#   SPARKLE_FRAMEWORK=<path to the extracted Sparkle.framework>
#   SPARKLE_BIN=<path to bin/ with generate_keys, sign_update, generate_appcast>
#
# The prebuilt tarball ships a universal (x86_64+arm64) Sparkle.framework plus
# the signing tools, so there's nothing to compile — just download + verify +
# extract, cached so repeat builds are instant.
set -euo pipefail

# --- Pinned version + checksum ------------------------------------------------
# Bump both together; get the new checksum from
#   shasum -a 256 Sparkle-<version>.tar.xz
SPARKLE_VERSION="2.9.4"
SPARKLE_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="$PROJECT_DIR/build/sparkle/$SPARKLE_VERSION"
TARBALL="$CACHE_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
EXTRACT_DIR="$CACHE_DIR/extracted"
FRAMEWORK="$EXTRACT_DIR/Sparkle.framework"
BIN_DIR="$EXTRACT_DIR/bin"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

emit() {
    echo "SPARKLE_FRAMEWORK=$(printf %q "$FRAMEWORK")"
    echo "SPARKLE_BIN=$(printf %q "$BIN_DIR")"
}

# Fast path: already extracted + verified in a previous run.
if [ -d "$FRAMEWORK" ] && [ -x "$BIN_DIR/sign_update" ]; then
    echo "Sparkle $SPARKLE_VERSION: cached at $EXTRACT_DIR" >&2
    emit
    exit 0
fi

mkdir -p "$CACHE_DIR"

# --- Download (idempotent) ----------------------------------------------------
if [ ! -f "$TARBALL" ]; then
    echo "Sparkle $SPARKLE_VERSION: downloading $URL" >&2
    curl -fsSL -o "$TARBALL" "$URL"
fi

# --- Verify checksum BEFORE extracting ----------------------------------------
ACTUAL_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$SPARKLE_SHA256" ]; then
    echo "ERROR: Sparkle tarball checksum mismatch!" >&2
    echo "  expected: $SPARKLE_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA" >&2
    echo "  Refusing to use an unverified Sparkle. Delete $TARBALL and retry, or" >&2
    echo "  bump SPARKLE_SHA256 in this script if you intentionally changed the version." >&2
    rm -f "$TARBALL"
    exit 1
fi
echo "Sparkle $SPARKLE_VERSION: checksum OK" >&2

# --- Extract ------------------------------------------------------------------
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar -xJf "$TARBALL" -C "$EXTRACT_DIR"

if [ ! -d "$FRAMEWORK" ] || [ ! -x "$BIN_DIR/sign_update" ]; then
    echo "ERROR: extracted Sparkle is missing Sparkle.framework or bin/sign_update." >&2
    exit 1
fi

echo "Sparkle $SPARKLE_VERSION: extracted to $EXTRACT_DIR" >&2
emit
