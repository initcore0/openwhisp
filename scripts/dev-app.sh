#!/bin/bash
# Contributor dev loop for the mac app target (MAK-65).
#
# Builds the app via the DEV-ONLY SwiftPM manifest at AppPackage/Package.swift —
# incremental compilation (only the file you touched recompiles) and the same
# module SourceKit-LSP / Xcode index, so autocomplete + breakpoints work on
# AppState and the app-only services. This is the fast edit→compile loop; it is
# NOT the release path (that stays ./build.sh + ./package.sh).
#
# Usage:
#   scripts/dev-app.sh            # incremental debug build (lean engines)
#   scripts/dev-app.sh -c release # release-config incremental build
#
# The dev build is LEAN (stub engines, no Sparkle) — it type-checks and links
# the whole app module without the WhisperKit/FluidAudio/Sparkle native deps,
# which is all you need while iterating on app/UI code. To run the real app with
# real engines, use ./build.sh (glob) or ./package.sh (.app bundle).

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PKG="$PROJECT_DIR/AppPackage"

# Regenerate BuildInfo.swift INTO the dev package's source dir (gitignored). It
# lives here — not in ../OpenWhisp — so build.sh's own source glob never picks up
# a duplicate BuildInfo. Reuses the shared generator so the two paths can't drift.
# shellcheck source=generate-build-info.sh
source "$PROJECT_DIR/scripts/generate-build-info.sh"
generate_build_info "$APP_PKG/Sources/OpenWhispApp" >/dev/null

echo "=== OpenWhisp dev build (incremental, lean engines) ==="
echo "Manifest: $APP_PKG/Package.swift"
cd "$APP_PKG"
swift build "$@"
echo ""
echo "✓ Incremental build done. (Release binary: ./build.sh — .app: ./package.sh)"
