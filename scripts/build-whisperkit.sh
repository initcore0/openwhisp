#!/bin/bash
# Build the WhisperKit dependency (and its whole transitive tree) into a single
# static library + module dir, so build.sh's WHISPERKIT=1 path can link it into
# the raw-swiftc app build. See docs/WHISPERKIT_PILOT.md.
#
# Output (printed as KEY=VALUE for build.sh to eval):
#   WHISPERKIT_MODULES=<dir with WhisperKit.swiftmodule>
#   WHISPERKIT_LIBDIR=<dir with libWhisperKitDep.a>
#   WHISPERKIT_CC_ARGS=<-Xcc flags for the C-module dependencies (e.g. yyjson)>
set -e

DEP_DIR="$(cd "$(dirname "$0")/../third_party/whisperkit-dep" && pwd)"
cd "$DEP_DIR"

# Resolve + build the static product (libWhisperKitDep.a bundles WhisperKit and
# all its dependencies into one archive). Release for speed/size.
swift build -c release >&2

BIN="$(swift build -c release --show-bin-path)"
LIB="$BIN/libWhisperKitDep.a"
MODULES="$BIN/Modules"

if [ ! -f "$LIB" ]; then
    echo "ERROR: $LIB not found — WhisperKit build failed." >&2
    exit 1
fi

# Some transitive deps are C modules (e.g. yyjson) whose Clang module maps the
# app's swiftc invocation must see. Pass ONLY the C-module maps: Swift targets'
# maps are already covered by -I Modules and re-passing them causes "redefinition
# of module" errors. Heuristic: Swift-generated maps reference a *-Swift.h header;
# pure C maps don't. Version-robust (no hardcoded module list).
CC_ARGS=""
while IFS= read -r mm; do
    if ! grep -q "Swift.h" "$mm" 2>/dev/null; then
        CC_ARGS="$CC_ARGS -Xcc -fmodule-map-file=$mm"
    fi
done < <(find "$BIN" -name "module.modulemap" 2>/dev/null)
# yyjson's headers live in the checkout, referenced relatively by its map.
YYJSON_SRC="$DEP_DIR/.build/checkouts/yyjson/src"
[ -d "$YYJSON_SRC" ] && CC_ARGS="$CC_ARGS -Xcc -I$YYJSON_SRC"

# Emit as shell-quoted assignments so build.sh can `eval` them safely (the
# CC_ARGS value contains spaces and must stay a single quoted string).
echo "WHISPERKIT_MODULES=$(printf %q "$MODULES")"
echo "WHISPERKIT_LIBDIR=$(printf %q "$BIN")"
echo "WHISPERKIT_CC_ARGS=$(printf %q "${CC_ARGS# }")"
