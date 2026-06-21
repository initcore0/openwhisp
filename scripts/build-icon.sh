#!/bin/bash
# Generate OpenWhisp's app icon: render all sizes (make-icon.swift) and compile
# into OpenWhisp/Resources/AppIcon.icns. Reproducible, no external dependencies.
#
# Usage: scripts/build-icon.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/AppIcon.iconset"
OUT="$PROJECT_DIR/OpenWhisp/Resources/AppIcon.icns"

echo "=== Rendering icon PNGs ==="
swift "$PROJECT_DIR/scripts/make-icon.swift" "$ICONSET"

echo "=== Compiling .icns ==="
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"

echo "=== Installing menu-bar template glyph ==="
TRAY_SRC="$(dirname "$ICONSET")"
RES="$PROJECT_DIR/OpenWhisp/Resources"
for f in MenuBarIcon.png MenuBarIcon@2x.png MenuBarIcon@3x.png; do
    cp "$TRAY_SRC/$f" "$RES/$f"
done

echo ""
echo "✓ Wrote $OUT"
echo "✓ Installed MenuBarIcon@{1,2,3}x.png in $RES"
ls -la "$OUT" "$RES"/MenuBarIcon*.png
