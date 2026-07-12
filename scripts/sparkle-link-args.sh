#!/bin/bash
# Shared helper: resolve the swiftc flags that link the Sparkle auto-update
# framework (MAK-56).
#
# Sparkle is ON BY DEFAULT (the app ships with auto-update). Opt out with
# SPARKLE=0 for a lean build without the framework and without the update UI
# (all Sparkle references are guarded by `#if SPARKLE`). Sourced by both
# build.sh and build-dmg.sh so the two compile paths never drift on how Sparkle
# is linked. Mirrors scripts/whisperkit-link-args.sh and fluidaudio-link-args.sh.
# See docs/AUTO_UPDATE.md.
#
# Usage (source, don't exec):
#   source "$PROJECT_DIR/scripts/sparkle-link-args.sh"
#   resolve_sparkle_args          # populates the SPARKLE_ARGS array + SPARKLE_FRAMEWORK
#   xcrun swiftc ... "${SPARKLE_ARGS[@]}" ...
#
# On success it also sets SPARKLE_FRAMEWORK to the extracted Sparkle.framework so
# the packaging step can copy it into Contents/Frameworks.
#
# Requires PROJECT_DIR to be set by the caller.

resolve_sparkle_args() {
    SPARKLE_ARGS=()
    SPARKLE_FRAMEWORK=""
    if [ "${SPARKLE:-1}" != "1" ]; then
        echo "Sparkle auto-update: disabled (SPARKLE=0) — lean build." >&2
        return 0
    fi

    echo "Sparkle auto-update: fetching framework..." >&2
    local sp_vars
    sp_vars="$("$PROJECT_DIR/scripts/fetch-sparkle.sh")"
    eval "$sp_vars"
    if [ -z "${SPARKLE_FRAMEWORK:-}" ] || [ ! -d "$SPARKLE_FRAMEWORK" ]; then
        echo "ERROR: Sparkle fetch did not produce a framework path." >&2
        exit 1
    fi
    local framework_dir
    framework_dir="$(dirname "$SPARKLE_FRAMEWORK")"
    SPARKLE_ARGS=(
        -D SPARKLE
        -F "$framework_dir"
        -framework Sparkle
        # Runtime search path: the framework is copied into the app bundle's
        # Contents/Frameworks by package.sh / build-dmg.sh.
        -Xlinker -rpath -Xlinker "@executable_path/../Frameworks"
    )
    echo "Sparkle auto-update: linking $SPARKLE_FRAMEWORK" >&2
}
