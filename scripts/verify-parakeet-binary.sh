#!/bin/bash
# Shared guard: assert a built OpenWhisp binary actually has the Parakeet
# (FluidAudio) backend compiled in — unless a lean build was explicitly
# requested (PARAKEET=0). Mirrors scripts/verify-whisperkit-binary.sh and
# exists for the same reason: a stub build is byte-compatible enough to
# package, then fails at runtime with "Parakeet engine isn't available in
# this build." Turn that silent failure into a loud build-time error.
#
# Usage:  verify_parakeet_binary <path-to-binary>
# Requires PARAKEET to be set (or unset → treated as default = on).

verify_parakeet_binary() {
    local binary="$1"

    if [ "${PARAKEET:-1}" != "1" ]; then
        echo "Parakeet verify: skipped (lean build, PARAKEET=0)." >&2
        return 0
    fi

    if [ ! -f "$binary" ]; then
        echo "ERROR: Parakeet verify: binary not found at $binary" >&2
        return 1
    fi

    # Match ONLY the linked module's MANGLED prefix `10FluidAudio` (Swift
    # length-prefixed module name) — NOT the plain string "FluidAudio", which
    # also appears inside OpenWhisp's own symbols (fluidAudioModelsDirectory,
    # installedFluidAudioFolders) even in a stub build. A real build links
    # thousands of FluidAudio symbols; a stub has zero.
    #
    # Count with `grep -c` into a variable (not `grep -q`): -q exits on first
    # match and SIGPIPEs nm under the callers' pipefail. `|| true` absorbs
    # grep's exit-1-on-zero-matches so `set -e` doesn't abort here.
    local count
    count="$(nm "$binary" 2>/dev/null | grep -c "10FluidAudio" || true)"
    if [ "${count:-0}" -gt 0 ]; then
        echo "Parakeet verify: OK ($count FluidAudio symbols in $binary)." >&2
        return 0
    fi

    echo "ERROR: Parakeet verify FAILED — '$binary' has NO FluidAudio symbols." >&2
    echo "       This is a stub build; running it would fail with 'The Parakeet engine" >&2
    echo "       isn't available in this build.' Rebuild without PARAKEET=0 (it's the" >&2
    echo "       default), or set PARAKEET=0 intentionally for a lean build." >&2
    return 1
}
