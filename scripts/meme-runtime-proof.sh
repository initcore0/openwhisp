#!/usr/bin/env bash
# Runtime proof for the meme plugin's GENERATE path (docs/PLUGINS.md).
#
# ## Why this exists
#
# `swift test` covers the pure decision layer — extraction, the shortlist, slot
# enforcement, seeding (`MemeCaptionSeeding.resolve`). It cannot cover the CHAIN:
# `plugins/MemeGenerator/MemeGeneratorModel.swift` compiles only into the app, sits
# outside the core test target, and is exactly where the "four items rendered as two
# captions" defect lived while every unit test stayed green.
#
# Twice that report was diagnosed by reading the wiring and declaring it correct, and
# twice the running binary disagreed. So this harness asks the binary instead: it
# drives `model.generate()` — the same method the Generate button calls — and prints
# the `MemeTrace` breadcrumb from each decision point, ending with the boxes that
# actually reached the canvas.
#
# The companion script `meme-voice-command-proof.sh` proves the TRIGGER layer (a
# spoken refine instruction reaching the plugin). This one proves what happens after.
#
# ## Usage
#
#   INSTRUMENTATION=1 ./build.sh
#   scripts/meme-runtime-proof.sh ["<prompt>"]
#
# With no argument it runs the regression prompt — the owner's original repro, whose
# four comma-separated items must arrive as FOUR filled boxes, not two:
#
#   "expanding brain: typing, dictating, dictating memes, dictating memes by voice"
#
# Requires: INSTRUMENTATION=1 ./build.sh — the probe entry point and the MemeTrace
# breadcrumbs are BOTH compiled out of a normal build, so a consumer binary produces
# no output here at all. Plugins are on by default (PLUGINS=0 opts out), but the meme
# plugin must be ENABLED in Settings → Plugins, and Settings → Cleanup must have a
# working model — this exercises a real LLM round-trip.
# Runs the WORKTREE binary only — it never touches an installed /Applications copy.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/build/meme-proof}"
SETTLE="${OPENWHISP_MEME_PROBE_SECONDS:-90}"
DELAY="${OPENWHISP_MEME_PROBE_DELAY:-6}"

# The regression prompt. Four items after a colon; the pass condition is four boxes.
DEFAULT_PROMPT="expanding brain: typing, dictating, dictating memes, dictating memes by voice"
PROMPT="${1:-$DEFAULT_PROMPT}"

[ -x "$ROOT/build/OpenWhisp" ] || {
    echo "✗ no binary at $ROOT/build/OpenWhisp — run: INSTRUMENTATION=1 ./build.sh" >&2; exit 1; }
mkdir -p "$OUT"

# The probe MUST run from a bundle, not the bare binary.
#
# `build.sh` emits a loose executable, and AppKit never services the main run loop
# for one: `applicationDidFinishLaunching` completes but every `asyncAfter` — the
# probe's included — is left queued forever, so the run looks like a silent hang. A
# minimal hand-assembled bundle (binary + Info.plist + Resources, ad-hoc signed) is
# enough. Mirrors meme-voice-command-proof.sh deliberately: two harnesses that
# assembled the bundle differently would eventually prove two different binaries.
APP="$ROOT/build/ProbeApp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/build/OpenWhisp" "$APP/Contents/MacOS/OpenWhisp"
cp "$ROOT/OpenWhisp/Info.plist" "$APP/Contents/"
[ -d "$ROOT/OpenWhisp/Resources" ] && cp -R "$ROOT/OpenWhisp/Resources/." "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
BIN="$APP/Contents/MacOS/OpenWhisp"

LOG="$OUT/generate.log"
echo "── generate ──────────────────────────────────────────"
echo "   prompt: \"$PROMPT\""
echo

# The probe opens the plugin window, waits `DELAY` for the catalog + model warm, fires
# Generate, then samples the canvas after `SETTLE`. Give the process both plus
# headroom, then stop it.
budget=$(( ${DELAY%.*} + ${SETTLE%.*} + 15 ))

env OPENWHISP_MEME_TRACE=1 \
    OPENWHISP_MEME_PROBE_PROMPT="$PROMPT" \
    OPENWHISP_MEME_PROBE_DELAY="$DELAY" \
    OPENWHISP_MEME_PROBE_SECONDS="$SETTLE" \
    "$BIN" >"$LOG" 2>&1 &
pid=$!

# Wait for the probe to report rather than a fixed sleep, so a fast run doesn't burn
# the full budget — but never wait past it.
waited=0
while [ "$waited" -lt "$budget" ]; do
    grep -q "probe done\|probe ABORTED" "$LOG" 2>/dev/null && break
    sleep 2; waited=$((waited + 2))
done

kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

grep '\[MemeGen\]' "$LOG" \
    || echo "   (no breadcrumbs — built with INSTRUMENTATION=1? plugin enabled?)"
echo
echo "Log: $LOG"

# Report the box count against the prompt's own item count when the prompt is
# list-shaped, so the regression case reads as a pass/fail rather than as a wall of
# breadcrumbs. Purely advisory — the breadcrumbs above are the evidence.
result="$(grep -o 'probe result: [0-9]* boxes' "$LOG" | tail -1 | grep -o '[0-9]*' || true)"
if [ -n "$result" ] && [ "$PROMPT" = "$DEFAULT_PROMPT" ]; then
    if [ "$result" = "4" ]; then
        echo "✓ regression prompt produced $result boxes (expected 4)"
    else
        echo "✗ regression prompt produced $result boxes, expected 4" >&2
        exit 1
    fi
fi
