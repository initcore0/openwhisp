#!/bin/bash
# Shared guard: assert a built OpenWhisp binary actually has the WhisperKit backend
# compiled in — unless a lean build was explicitly requested (WHISPERKIT=0).
#
# Why this exists: WhisperKit is the default engine, but a stub build (WHISPERKIT=0,
# used for lint checks) is byte-compatible enough to package and run — it just fails
# at runtime with "WhisperKit backend isn't available in this build." Packaging a
# stale stub binary once shipped a broken app to a tester. This turns that silent
# failure into a loud build-time error.
#
# Usage:  verify_whisperkit_binary <path-to-binary>
# Requires WHISPERKIT to be set (or unset → treated as default = on).

verify_whisperkit_binary() {
    local binary="$1"

    if [ "${WHISPERKIT:-1}" != "1" ]; then
        echo "WhisperKit verify: skipped (lean build, WHISPERKIT=0)." >&2
        return 0
    fi

    if [ ! -f "$binary" ]; then
        echo "ERROR: WhisperKit verify: binary not found at $binary" >&2
        return 1
    fi

    # Match ONLY the linked dependency's own module, `ArgmaxCore` — NOT "WhisperKit",
    # which also appears as OpenWhisp's own type/method names (WhisperKitBridge,
    # isWhisperKit, whisperKitModelRow, …) and is present even in a stub build. A real
    # build links thousands of ArgmaxCore symbols; a stub has zero.
    if nm "$binary" 2>/dev/null | grep -q "ArgmaxCore"; then
        echo "WhisperKit verify: OK (backend is compiled into $binary)." >&2
        return 0
    fi

    echo "ERROR: WhisperKit verify FAILED — '$binary' has NO ArgmaxCore symbols." >&2
    echo "       This is a stub build; running it would fail with 'WhisperKit backend" >&2
    echo "       isn't available in this build.' Rebuild without WHISPERKIT=0 (it's the" >&2
    echo "       default), or set WHISPERKIT=0 intentionally for a lean build." >&2
    return 1
}
