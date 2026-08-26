#!/bin/bash
# Package OpenWhisp as .app bundle
# Usage: ./package.sh [--install]
#
# With --install (or INSTALL=1), after packaging it replaces the copy in
# /Applications with the fresh build: quits the running app, copies the new
# bundle, and relaunches. Off by default so plain packaging / CI is unaffected.

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="OpenWhisp.app"
APP_DIR="$BUILD_DIR/$APP_NAME"

INSTALL="${INSTALL:-0}"
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
    esac
done

# ALWAYS rebuild — never reuse whatever binary happens to be in build/. Reusing a
# stale binary once packaged a WHISPERKIT=0 lint-build stub as a "real" app, which
# ran but failed at runtime ("WhisperKit backend isn't available in this build").
# Pass through WHISPERKIT so a deliberate lean build still works.
echo "Building fresh binary (rm stale + build.sh)..."
rm -f "$BUILD_DIR/OpenWhisp"
# Packaged .apps are installed and used for real — build optimized (build.sh
# with no argument is a debug/-Onone build, meant for the dev loop).
"$PROJECT_DIR/build.sh" release

# Guard: refuse to package a stub (missing WhisperKit) unless WHISPERKIT=0 was
# explicitly requested. Turns the silent "stub shipped" failure into a build error.
# shellcheck source=scripts/verify-whisperkit-binary.sh
source "$PROJECT_DIR/scripts/verify-whisperkit-binary.sh"
verify_whisperkit_binary "$BUILD_DIR/OpenWhisp"
# Same guard for the Parakeet backend (also on by default; PARAKEET=0 opts out).
# shellcheck source=scripts/verify-parakeet-binary.sh
source "$PROJECT_DIR/scripts/verify-parakeet-binary.sh"
verify_parakeet_binary "$BUILD_DIR/OpenWhisp"
# Same guard for the in-repo plugins (on by default; PLUGINS=0 opts out). Plugins
# live outside build.sh's OpenWhisp/ glob, so a broken source list drops them all
# with no compile error — see docs/PLUGINS.md.
# shellcheck source=scripts/verify-plugins-binary.sh
source "$PROJECT_DIR/scripts/verify-plugins-binary.sh"
verify_plugins_binary "$BUILD_DIR/OpenWhisp"

# Build the openwhisp CLI + MCP adapter (a separate SwiftPM executable, so it
# never picks up the GUI app's `main`). Bundled into Contents/Helpers below; the
# app's --deep code-sign seals it for local dev. (build-dmg.sh signs it with the
# hardened runtime + strict-verify for notarized release.)
echo "Building openwhisp CLI..."
swift build -c release --product openwhisp
CLI_BIN="$(swift build -c release --product openwhisp --show-bin-path)/openwhisp"

# Clean old bundle
rm -rf "$APP_DIR"

# Create app structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources/whisper"
mkdir -p "$APP_DIR/Contents/Resources/llama"
mkdir -p "$APP_DIR/Contents/Resources/models"

# Copy binary
cp "$BUILD_DIR/OpenWhisp" "$APP_DIR/Contents/MacOS/"

# Bundle the openwhisp CLI / MCP adapter alongside the app.
mkdir -p "$APP_DIR/Contents/Helpers"
cp "$CLI_BIN" "$APP_DIR/Contents/Helpers/openwhisp"

# Copy Info.plist
cp "$PROJECT_DIR/OpenWhisp/Info.plist" "$APP_DIR/Contents/"

# Copy packaged resources. This carries the starter plugin pack (MAK-101) at
# Resources/StarterPlugins — `-p` preserves the mode bits so a starter plugin's script
# arrives executable rather than needing the app to repair it on install.
if [ -d "$PROJECT_DIR/OpenWhisp/Resources" ]; then
    cp -Rp "$PROJECT_DIR/OpenWhisp/Resources/"* "$APP_DIR/Contents/Resources/"
fi

# The starter pack must actually be in the bundle. It has no bundling step of its own
# (it rides the copy above), so a selective rewrite of that copy would drop it silently.
verify_starter_pack "$APP_DIR"

# Bundle whisper.cpp runtime binaries and dylibs when available.
WHISPER_BIN_DIR="${WHISPER_BIN_DIR:-$PROJECT_DIR/third_party/whisper.cpp/build/bin}"
"$PROJECT_DIR/scripts/bundle-whisper-runtime.sh" "$APP_DIR" "$WHISPER_BIN_DIR"

# Bundle the optional llama.cpp runtime (the built-in refinement LLM) when it has
# been built. Guarded so a whisper-only / CI build (no llama submodule or no
# llama build) still packages successfully. The rm -rf clears any stale partial
# bundle from a previous run.
rm -rf "$APP_DIR/Contents/Resources/llama"
mkdir -p "$APP_DIR/Contents/Resources/llama"
LLAMA_BIN_DIR="${LLAMA_BIN_DIR:-$PROJECT_DIR/third_party/llama.cpp/build/bin}"
if [ -x "$LLAMA_BIN_DIR/llama-server" ]; then
    "$PROJECT_DIR/scripts/bundle-llama-runtime.sh" "$APP_DIR" "$LLAMA_BIN_DIR"
else
    echo "WARNING: skipping llama runtime (no llama-server at $LLAMA_BIN_DIR)."
    echo "The built-in AI provider (the app default) will be unavailable in this build — run scripts/build-llama.sh to include it."
fi

# Bundle Sparkle.framework (auto-update, MAK-56) into Contents/Frameworks. The
# framework was fetched by build.sh above; re-resolve its path here (a cheap
# cache hit). No-op on a SPARKLE=0 lean build. Ad-hoc for local dev — the app's
# --deep sign below reseals it.
# shellcheck source=scripts/sparkle-link-args.sh
source "$PROJECT_DIR/scripts/sparkle-link-args.sh"
resolve_sparkle_args
"$PROJECT_DIR/scripts/bundle-sparkle-framework.sh" "$APP_DIR" "${SPARKLE_FRAMEWORK:-}"

# Copy entitlements
if [ -f "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements" ]; then
    cp "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements" "$APP_DIR/Contents/"
fi

# Code sign. Prefer a stable signing identity so TCC permissions (Microphone,
# Accessibility, Input Monitoring) survive rebuilds. Priority:
#   1) SIGN_IDENTITY env var (e.g. a "Developer ID Application: ..." cert)
#   2) the self-signed "OpenWhisp Self-Signed" cert (scripts/create-signing-cert.sh)
#   3) ad-hoc ("-") — works, but re-prompts for permissions every build
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "OpenWhisp Self-Signed"; then
    SIGN_IDENTITY="OpenWhisp Self-Signed"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    echo "Signing ad-hoc (permissions WILL be re-requested each build)."
    echo "  Tip: run scripts/create-signing-cert.sh once for a stable identity."
else
    echo "Signing with identity: $SIGN_IDENTITY"
fi

ENTITLEMENTS_ARGS=()
if [ -f "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements" ]; then
    ENTITLEMENTS_ARGS=(--entitlements "$PROJECT_DIR/OpenWhisp/OpenWhisp.entitlements")
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "${ENTITLEMENTS_ARGS[@]}" "$APP_DIR"

echo ""
echo "✓ App bundle created: $APP_DIR"
echo ""
echo "Run with:"
echo "  open $APP_DIR"
echo ""
echo "Packaged whisper runtime:"
ls -1 "$APP_DIR/Contents/Resources/whisper" 2>/dev/null || true
echo ""
echo "Packaged llama runtime (built-in LLM, optional):"
ls -1 "$APP_DIR/Contents/Resources/llama" 2>/dev/null || true
echo ""
echo "Before first use:"
echo "  1. Grant microphone/accessibility/input monitoring permissions"
echo "  2. Let OpenWhisp download the selected model into Application Support"

# Optional: replace the installed copy in /Applications with this fresh build.
if [ "$INSTALL" = "1" ]; then
    INSTALLED="/Applications/$APP_NAME"
    echo ""
    echo "Installing to $INSTALLED ..."
    # Quit a running copy (and any lingering whisper-server it spawned) so the
    # bundle isn't in use while we replace it.
    osascript -e 'quit app "OpenWhisp"' 2>/dev/null || true
    sleep 1
    pkill -f "$INSTALLED/Contents/MacOS/OpenWhisp" 2>/dev/null || true
    pkill -f "$INSTALLED/Contents/Resources/whisper/whisper-server" 2>/dev/null || true
    pkill -f "$INSTALLED/Contents/Resources/llama/llama-server" 2>/dev/null || true
    sleep 1
    rm -rf "$INSTALLED"
    # ditto preserves the bundle's signature/attributes (unlike a plain cp -R).
    ditto "$APP_DIR" "$INSTALLED"
    # Verify the runtimes actually landed — a silent partial install is how a
    # working app turns into "built-in model unavailable" with no clue why.
    for rel in "Contents/Resources/whisper/whisper-cli" "Contents/Resources/llama/llama-server"; do
        if [ -x "$APP_DIR/$rel" ] && [ ! -x "$INSTALLED/$rel" ]; then
            echo "ERROR: $rel didn't survive the copy to $INSTALLED — install incomplete."
            exit 1
        fi
    done
    echo "Installed. Relaunching..."
    open "$INSTALLED"
fi
