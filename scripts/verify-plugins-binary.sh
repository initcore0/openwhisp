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

# Assert the STARTER PLUGIN PACK (MAK-101) actually landed in an assembled .app.
#
# The pack rides package.sh's existing `cp -R OpenWhisp/Resources/* Contents/Resources/`
# rather than having a bundling step of its own, which is one fewer script that can stop
# copying — but it is also exactly the kind of implicit dependency that breaks silently
# when someone rewrites that copy to be selective. The symptom would be a Plugins pane
# with the "Starter plugins" section quietly absent, which is invisible in CI.
#
# NOT gated on PLUGINS. `PLUGINS=0` drops the COMPILED plugin surfaces; starter plugins
# are script plugins the host executes itself, so they ship and work in a lean build too.
# Skipping this check under PLUGINS=0 would let the pack vanish from exactly the build
# configuration that has nothing else to fall back on.
#
# Usage:  verify_starter_pack <path-to-.app>
verify_starter_pack() {
    local app="$1"
    local pack="$app/Contents/Resources/StarterPlugins"

    if [ ! -d "$pack" ]; then
        echo "ERROR: Starter pack verify FAILED — no $pack in the bundle." >&2
        echo "       Settings → Plugins would offer no starter plugins at all." >&2
        echo "       package.sh copies OpenWhisp/Resources/* into Contents/Resources;" >&2
        echo "       check that copy and that OpenWhisp/Resources/StarterPlugins exists." >&2
        return 1
    fi

    # Every entry must carry a manifest.json — a folder without one is skipped silently
    # by PluginStarterPack.offerings, so an empty-handed copy would look like success.
    local count=0
    local dir
    for dir in "$pack"/*/; do
        [ -f "$dir/manifest.json" ] || continue
        count=$((count + 1))
    done

    if [ "$count" -eq 0 ]; then
        echo "ERROR: Starter pack verify FAILED — $pack has no plugin folders." >&2
        return 1
    fi

    # Declared scripts must survive the copy EXECUTABLE. A stripped exec bit installs a
    # plugin that fails the moment the user speaks to it, with a message about chmod. The
    # app restores the bit on install, but a non-executable source means the repo itself
    # is wrong, and that should fail here rather than in a user's hands.
    local script
    while IFS= read -r script; do
        if [ ! -x "$script" ]; then
            echo "ERROR: Starter pack verify FAILED — '$script' is not executable." >&2
            echo "       Run: chmod +x on the source under OpenWhisp/Resources/StarterPlugins." >&2
            return 1
        fi
    done < <(find "$pack" -name "*.sh")

    echo "Starter pack verify: OK ($count starter plugin(s) in the bundle)." >&2
    return 0
}
