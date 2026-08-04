#!/bin/bash
# Shared guard: assert a built OpenWhisp binary actually has the in-repo plugins
# compiled in — unless a lean build was explicitly requested (PLUGINS=0).
#
# Mirrors scripts/verify-whisperkit-binary.sh / verify-parakeet-binary.sh and exists
# for the same reason those do: a build with the surface missing is byte-compatible
# enough to package and ships without complaint, and the failure only shows up as an
# empty Plugins pane in a user's hands.
#
# The specific hazard here is that plugins live OUTSIDE build.sh's `OpenWhisp/` glob,
# in plugins/, and are pulled in by a separate helper. A path typo or a lost `source`
# line drops every plugin while the app still builds and runs perfectly — there is no
# compile error to catch it, because the pure plugin core under OpenWhisp/Services
# compiles either way. That is exactly the dead-wiring failure mode this repo keeps
# hitting, so it gets a build-time assertion rather than a code review.
#
# Usage:  verify_plugins_binary <path-to-binary>
# Requires PLUGINS to be set (or unset → treated as default = on).

verify_plugins_binary() {
    local binary="$1"

    if [ "${PLUGINS:-1}" = "0" ]; then
        echo "Plugins verify: skipped (lean build, PLUGINS=0)." >&2
        return 0
    fi

    if [ ! -f "$binary" ]; then
        echo "ERROR: Plugins verify: binary not found at $binary" >&2
        return 1
    fi

    # Match `MemeGeneratorWindowController` — a type that exists ONLY in
    # plugins/MemeGenerator/, never in OpenWhisp/Services. The pure meme core
    # (MemeAI, MemeCaptionSeeding, …) is compiled even under PLUGINS=0, so matching
    # on "Meme" alone would pass on a lean build and prove nothing.
    #
    # Count with `grep -c` into a variable (not `grep -q`): -q exits on first match
    # and SIGPIPEs nm under the callers' pipefail. `|| true` absorbs grep's
    # exit-1-on-zero-matches so `set -e` doesn't abort here.
    local count
    count="$(nm "$binary" 2>/dev/null | grep -c "MemeGeneratorWindowController" || true)"
    if [ "${count:-0}" -gt 0 ]; then
        echo "Plugins verify: OK ($count plugin symbols in $binary)." >&2
        return 0
    fi

    echo "ERROR: Plugins verify FAILED — '$binary' has NO in-repo plugin symbols." >&2
    echo "       The Plugins pane would be empty and the menu-bar submenu absent." >&2
    echo "       Rebuild without PLUGINS=0 (it's the default), or set PLUGINS=0" >&2
    echo "       intentionally for a lean build. See docs/PLUGINS.md." >&2
    return 1
}
