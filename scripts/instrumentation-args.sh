#!/bin/bash
# Shared helper: resolve the swiftc flags that enable developer instrumentation.
#
# Instrumentation (timing signposts + console timing lines) is OFF BY DEFAULT —
# consumer builds compile NONE of it. Enable with INSTRUMENTATION=1, which defines
# OPENWHISP_INSTRUMENTATION; the gated code (see Instrumentation.swift) is then
# compiled in, and is a no-op everywhere otherwise.
#
# Sourced by both build.sh and build-dmg.sh so the two compile paths never drift.
# Requires PROJECT_DIR to be set by the caller.

resolve_instrumentation_args() {
    INSTRUMENTATION_ARGS=()
    if [ "${INSTRUMENTATION:-0}" = "1" ]; then
        INSTRUMENTATION_ARGS=( -D OPENWHISP_INSTRUMENTATION )
        echo "Instrumentation: ENABLED (timing signposts + console logs)" >&2
    fi
}
