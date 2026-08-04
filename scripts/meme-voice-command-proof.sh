#!/usr/bin/env bash
# Runtime proof for the v10 plugin voice-command route (spike/plugin-system).
#
# ## Why this exists
#
# `swift test` proves the ROUTER — which instructions match, which don't. It cannot
# prove the pipeline ever REACHES the router: the refine path lives on AppState,
# which the core test target doesn't compile. Every wiring bug this project has hit
# (see the wiring-review lessons) passed its unit tests while the live gate was dead.
#
# So this drives the shipping binary. `AppMain.startRefineRouteProbe` calls the SAME
# `PluginHost.routeVoiceCommand` that `AppState.deliverFinalText` calls the moment a
# mid-dictation refine finalizes, with the same (instruction, content) pair — only
# the source of those two strings differs (env vars instead of the mic).
#
# ## Cases
#
#   case1  — selection is the material ("create a meme based on that" + content)
#   case2  — the spoken remainder is ("create a meme expanding brain: …", no content)
#   nearmiss — "create a memo about …" must NOT route; it logs a normal refine
#
# Usage: scripts/meme-voice-command-proof.sh [case1|case2|nearmiss|all]
#
# Requires: PLUGINS=1 ./build.sh, and the meme plugin ENABLED in Settings → Plugins.
# Runs the WORKTREE binary only — it never touches an installed /Applications copy.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/build/voice-proof}"
SETTLE="${OPENWHISP_MEME_PROBE_SECONDS:-75}"
DELAY="${OPENWHISP_MEME_PROBE_DELAY:-6}"

[ -x "$ROOT/build/OpenWhisp" ] || {
    echo "✗ no binary at $ROOT/build/OpenWhisp — run: PLUGINS=1 ./build.sh" >&2; exit 1; }
mkdir -p "$OUT"

# The probe MUST run from a bundle, not the bare binary.
#
# `build.sh` emits a loose executable, and AppKit never services the main run loop
# for one: `applicationDidFinishLaunching` completes but every `asyncAfter` — the v9
# probe's included — is left queued forever, so the run looks like a silent hang. A
# minimal hand-assembled bundle (binary + Info.plist + Resources, ad-hoc signed) is
# enough; none of the third_party runtimes matter to the trigger layer, which is why
# this doesn't need the full `package.sh`.
APP="$ROOT/build/ProbeApp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/build/OpenWhisp" "$APP/Contents/MacOS/OpenWhisp"
cp "$ROOT/OpenWhisp/Info.plist" "$APP/Contents/"
[ -d "$ROOT/OpenWhisp/Resources" ] && cp -R "$ROOT/OpenWhisp/Resources/." "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
BIN="$APP/Contents/MacOS/OpenWhisp"

run_case() {
    local name="$1" instruction="$2" content="${3:-}"
    local log="$OUT/$name.log"

    echo "── $name ─────────────────────────────────────────────"
    echo "   instruction: \"$instruction\""
    [ -n "$content" ] && echo "   content:     \"$content\""

    # The probe fires `delay` seconds after launch, then samples the canvas after
    # `SETTLE`. Give the process both plus headroom, then stop it.
    local budget=$(( ${DELAY%.*} + ${SETTLE%.*} + 15 ))

    env OPENWHISP_MEME_TRACE=1 \
        OPENWHISP_MEME_PROBE_REFINE="$instruction" \
        ${content:+OPENWHISP_MEME_PROBE_REFINE_CONTENT="$content"} \
        OPENWHISP_MEME_PROBE_DELAY="$DELAY" \
        OPENWHISP_MEME_PROBE_SECONDS="$SETTLE" \
        "$BIN" >"$log" 2>&1 &
    local pid=$!

    # Wait for the probe to finish rather than a fixed sleep, so a fast case doesn't
    # burn the full budget — but never wait past it.
    local waited=0
    while [ "$waited" -lt "$budget" ]; do
        grep -q "probe done\|NOT ROUTED" "$log" 2>/dev/null && break
        sleep 2; waited=$((waited + 2))
    done

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    echo
    grep '\[MemeGen\]' "$log" || echo "   (no breadcrumbs — is the plugin enabled?)"
    echo
}

WHICH="${1:-all}"
case "$WHICH" in
  case1|case2|nearmiss|all) ;;
  *) echo "usage: $0 [case1|case2|nearmiss|all]" >&2; exit 2 ;;
esac

if [ "$WHICH" = case1 ] || [ "$WHICH" = all ]; then
    run_case case1 "create a meme based on that" \
      "Our deploy pipeline takes 45 minutes and fails on the last step half the time."
fi
if [ "$WHICH" = case2 ] || [ "$WHICH" = all ]; then
    run_case case2 \
      "create a meme expanding brain: typing, dictating, dictating memes, dictating memes by voice"
fi
if [ "$WHICH" = nearmiss ] || [ "$WHICH" = all ]; then
    run_case nearmiss "create a memo about the Q3 numbers" \
      "Revenue was up 12 percent."
fi

echo "Logs: $OUT"
