#!/bin/bash
# Shared helper: resolve the swiftc flags that link the WhisperKit backend.
#
# WhisperKit is ON BY DEFAULT (it's the default transcription engine). Opt out with
# WHISPERKIT=0 for a lean build without the CoreML dependency. Sourced by both
# build.sh and build-dmg.sh so the two compile paths never drift on how WhisperKit
# is linked. See docs/WHISPERKIT_PILOT.md.
#
# Usage (source, don't exec):
#   source "$PROJECT_DIR/scripts/whisperkit-link-args.sh"
#   resolve_whisperkit_args        # populates the WHISPERKIT_ARGS array
#   xcrun swiftc ... "${WHISPERKIT_ARGS[@]}" ...
#
# Requires PROJECT_DIR to be set by the caller.

resolve_whisperkit_args() {
    WHISPERKIT_ARGS=()
    if [ "${WHISPERKIT:-1}" != "1" ]; then
        echo "WhisperKit backend: disabled (WHISPERKIT=0) — lean build." >&2
        return 0
    fi

    echo "WhisperKit backend: building dependency..." >&2
    local wk_vars
    wk_vars="$("$PROJECT_DIR/scripts/build-whisperkit.sh")"
    eval "$wk_vars"
    if [ -z "${WHISPERKIT_MODULES:-}" ] || [ -z "${WHISPERKIT_LIBDIR:-}" ]; then
        echo "ERROR: WhisperKit build did not produce link paths." >&2
        exit 1
    fi
    WHISPERKIT_ARGS=(
        -D WHISPERKIT
        -I "$WHISPERKIT_MODULES"
        -L "$WHISPERKIT_LIBDIR"
        -lWhisperKitDep
    )
    # Clang module-map flags for C deps (yyjson, etc.); word-split intentionally.
    # shellcheck disable=SC2206
    WHISPERKIT_ARGS+=( $WHISPERKIT_CC_ARGS )
    echo "WhisperKit backend: linking $WHISPERKIT_LIBDIR/libWhisperKitDep.a" >&2
}
