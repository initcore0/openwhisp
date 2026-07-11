#!/bin/bash
# Shared helper: resolve the swiftc flags that link the Parakeet (FluidAudio)
# backend.
#
# OFF BY DEFAULT while MAK-46 is a spike — opt in with PARAKEET=1. Sourced by
# both build.sh and build-dmg.sh so the two compile paths never drift on how
# FluidAudio is linked. Mirrors scripts/whisperkit-link-args.sh. See
# docs/PARAKEET_SPIKE.md.
#
# Usage (source, don't exec):
#   source "$PROJECT_DIR/scripts/fluidaudio-link-args.sh"
#   resolve_fluidaudio_args        # populates the FLUIDAUDIO_ARGS array
#   xcrun swiftc ... "${FLUIDAUDIO_ARGS[@]}" ...
#
# Requires PROJECT_DIR to be set by the caller.

resolve_fluidaudio_args() {
    FLUIDAUDIO_ARGS=()
    if [ "${PARAKEET:-0}" != "1" ]; then
        return 0
    fi

    echo "Parakeet backend: building FluidAudio dependency..." >&2
    local fa_vars
    fa_vars="$("$PROJECT_DIR/scripts/build-fluidaudio.sh")"
    eval "$fa_vars"
    if [ -z "${FLUIDAUDIO_MODULES:-}" ] || [ -z "${FLUIDAUDIO_LIBDIR:-}" ]; then
        echo "ERROR: FluidAudio build did not produce link paths." >&2
        exit 1
    fi
    FLUIDAUDIO_ARGS=(
        -D PARAKEET
        -I "$FLUIDAUDIO_MODULES"
        -L "$FLUIDAUDIO_LIBDIR"
        -lFluidAudioDep
        -lc++
    )
    # Clang module-map flags for C deps; word-split intentionally.
    # shellcheck disable=SC2206
    FLUIDAUDIO_ARGS+=( $FLUIDAUDIO_CC_ARGS )
    echo "Parakeet backend: linking $FLUIDAUDIO_LIBDIR/libFluidAudioDep.a" >&2
}
