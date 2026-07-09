#!/bin/bash
# Real-engine E2E runner (Tier-2 / nightly): transcribe fixture WAVs with the
# REAL WhisperKit engine and assert fuzzy matches. This is the accuracy check
# plain `swift test` can't run — WhisperKitEngine is app-target-only and gated
# behind `-D WHISPERKIT`, so SwiftPM never compiles it (docs/E2E_AUDIO_TESTING.md).
#
# It compiles a small harness (scripts/e2e/whisperkit-harness.swift) linked
# against the WhisperKit dependency and the app's engine sources — the same
# link recipe build.sh uses — then runs every fixture through it.
#
# Determinism policy: assertions are fuzzy (key-phrase containment on normalized
# text), never exact — Whisper output varies across machines/OS.
#
# Prereqs: run on a Mac with the WhisperKit toolchain buildable (the same env
# `./build.sh` needs). First run downloads a tiny model (~needs network) unless
# already staged. Intended for a self-hosted/nightly job, NOT blocking CI.
#
# Usage:
#   ./scripts/e2e-whisperkit.sh                 # tiny.en over all fixtures
#   ./scripts/e2e-whisperkit.sh <model-name>    # e.g. openai_whisper-small
#   MODEL=openai_whisper-tiny.en ./scripts/e2e-whisperkit.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="$PROJECT_DIR/Tests/Fixtures/audio"
HARNESS_SRC="$PROJECT_DIR/scripts/e2e/whisperkit-harness.swift"
BUILD_DIR="$PROJECT_DIR/build/e2e-whisperkit"
MODEL="${1:-${MODEL:-openai_whisper-tiny.en}}"

log()  { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcrun >/dev/null || die "Xcode command line tools required."
[[ -f "$HARNESS_SRC" ]] || die "harness missing: $HARNESS_SRC"

mkdir -p "$BUILD_DIR"

# --- Resolve WhisperKit link args (shared with build.sh) ---
log "Resolving WhisperKit link flags (building the dep if needed)…"
# shellcheck source=scripts/whisperkit-link-args.sh
source "$PROJECT_DIR/scripts/whisperkit-link-args.sh"
WHISPERKIT=1 resolve_whisperkit_args
[[ ${#WHISPERKIT_ARGS[@]} -gt 0 ]] || die "WhisperKit args empty — WHISPERKIT build failed."

# --- Collect the engine sources the harness needs ---
# The harness references WhisperKitEngine, which pulls in WhisperKitBridge,
# WhisperKitModelCatalog, WhisperTask, the FileTranscriptionEngine protocol, and
# Instrumentation. Compile the whole Services dir (minus the alternate engines
# that would create duplicate symbols or need heavier deps) alongside the harness;
# swiftc resolves the graph. Framework-link like build.sh (this is a local tool).
SERVICES="$PROJECT_DIR/OpenWhisp/Services"
SOURCES=(
    "$HARNESS_SRC"
    "$SERVICES/WhisperKitEngine.swift"
    "$SERVICES/WhisperKitBridge.swift"
    "$SERVICES/WhisperKitModelCatalog.swift"
    "$SERVICES/TranscriptionEngine.swift"
    "$SERVICES/WhisperTask.swift"
    "$SERVICES/Instrumentation.swift"
    "$SERVICES/ModelStorage.swift"
    "$SERVICES/AudioLevel.swift"
    "$SERVICES/AsyncTimeout.swift"
)

OUT="$BUILD_DIR/whisperkit-harness"
log "Compiling real-engine harness…"
# Frameworks mirror build.sh; some engine sources touch AVFoundation/CoreML.
if ! xcrun swiftc \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -parse-as-library \
    -framework Foundation \
    -framework AVFoundation \
    -framework CoreML \
    "${WHISPERKIT_ARGS[@]}" \
    "${SOURCES[@]}" \
    -o "$OUT" 2>&1
then
    die "harness compile failed (see errors above). If a source is missing/extra, adjust SOURCES in this script."
fi
ok "Harness built: $OUT"

# --- Stage the model offline if a stager is available (best-effort) ---
# WhisperKitBridge.load auto-downloads on first use; nothing to do here beyond
# letting the harness's first transcribe trigger it. We just note where it caches.
MODELS_DIR="$HOME/Library/Application Support/OpenWhisp/whisperkit-models/$MODEL"
if [[ -d "$MODELS_DIR" ]]; then
    ok "Model '$MODEL' already staged at $MODELS_DIR"
else
    log "Model '$MODEL' not staged; the harness will auto-download on first use (needs network)."
fi

# --- Build the fixture argument list (wav txt pairs) ---
PAIRS=()
for wav in "$FIXTURE_DIR"/*.wav; do
    base="$(basename "$wav" .wav)"
    txt="$FIXTURE_DIR/$base.txt"
    [[ -f "$txt" ]] || continue
    PAIRS+=( "$wav" "$txt" )
done
[[ ${#PAIRS[@]} -gt 0 ]] || die "no fixtures found in $FIXTURE_DIR"

log "Running real-engine transcription over $(( ${#PAIRS[@]} / 2 )) fixtures with model '$MODEL'…"
"$OUT" "$MODEL" "${PAIRS[@]}"
ok "Real-engine E2E complete."
