#!/bin/bash
# Build the FluidAudio dependency (Parakeet/CoreML streaming ASR) into a single
# static library + module dir, so build.sh's PARAKEET=1 path can link it into
# the raw-swiftc app build. Mirrors scripts/build-whisperkit.sh. See
# docs/PARAKEET_SPIKE.md.
#
# Output (printed as KEY=VALUE for build.sh to eval):
#   FLUIDAUDIO_MODULES=<dir with FluidAudio.swiftmodule>
#   FLUIDAUDIO_LIBDIR=<dir with libFluidAudioDep.a>
#   FLUIDAUDIO_CC_ARGS=<-Xcc flags for any C-module dependencies>
set -e

DEP_DIR="$(cd "$(dirname "$0")/../third_party/fluidaudio-dep" && pwd)"
cd "$DEP_DIR"

# Resolve + build the static product (libFluidAudioDep.a bundles FluidAudio and
# all its dependencies into one archive). Release for speed/size.
swift build -c release >&2

BIN="$(swift build -c release --show-bin-path)"
LIB="$BIN/libFluidAudioDep.a"
MODULES="$BIN/Modules"

if [ ! -f "$LIB" ]; then
    echo "ERROR: $LIB not found — FluidAudio build failed." >&2
    exit 1
fi

# Pass ONLY C-module maps to the app's swiftc (Swift targets' maps are already
# covered by -I Modules; re-passing them causes "redefinition of module").
# Heuristic shared with build-whisperkit.sh: Swift-generated maps reference a
# *-Swift.h header; pure C maps don't. FluidAudio's C/C++ wrapper targets
# (MachTaskSelfWrapper, FastClusterWrapper) are covered by this.
# $BIN holds Swift targets' generated maps; the C/C++ wrapper targets'
# (FastClusterWrapper, MachTaskSelfWrapper) hand-written maps live in the
# checkout under Sources/*/include — the app's swiftc must see those too.
CC_ARGS=""
while IFS= read -r mm; do
    if ! grep -q "Swift.h" "$mm" 2>/dev/null; then
        CC_ARGS="$CC_ARGS -Xcc -fmodule-map-file=$mm"
    fi
done < <(find "$BIN" "$DEP_DIR/.build/checkouts/FluidAudio/Sources" -name "module.modulemap" 2>/dev/null)

# Emit as shell-quoted assignments so build.sh can `eval` them safely.
echo "FLUIDAUDIO_MODULES=$(printf %q "$MODULES")"
echo "FLUIDAUDIO_LIBDIR=$(printf %q "$BIN")"
echo "FLUIDAUDIO_CC_ARGS=$(printf %q "${CC_ARGS# }")"
