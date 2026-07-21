#!/bin/bash
# engine-bench.sh — public, reproducible engine benchmark (MAK-79).
#
# Runs the fixture WAVs in Tests/Fixtures/audio/ through each transcription
# engine's FILE path on THIS machine and emits a markdown table: engine,
# model/variant, x-realtime (audioDuration / processingTime), WER vs the fixture
# reference transcripts, and notes. WER is a word-level Levenshtein edit distance
# over normalized text (see scripts/bench/harness/BenchCommon.swift) — punctuation
# and casing don't count, word errors do.
#
# Three engines, each behind a small ad-hoc swiftc harness (no SwiftPM target):
#   - WhisperKit    : reuses the app's WhisperKitEngine (-D WHISPERKIT + dep).
#   - Parakeet      : reuses the app's ParakeetBridge (-D PARAKEET + FluidAudio,
#                     TDT v3 batch). First run downloads ~600 MB.
#   - SpeechAnalyzer: macOS 26 Speech framework (SpeechTranscriber file path).
#                     First run provisions locale assets.
#
# Each engine is optional and isolated — a build/download failure for one is
# reported as a TODO row, the others still run.
#
# Usage:
#   ./scripts/bench/engine-bench.sh                 # all engines, auto model pick
#   ENGINES="parakeet,speechanalyzer" ./scripts/bench/engine-bench.sh
#   WHISPERKIT_MODEL=openai_whisper-tiny.en ./scripts/bench/engine-bench.sh
#   OUT=docs/BENCHMARKS.tbl.md ./scripts/bench/engine-bench.sh   # write table to file
#
# Re-runnable end-to-end: warm models/assets are reused; nothing is left staged
# beyond the model caches the engines manage themselves.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE_DIR="$PROJECT_DIR/Tests/Fixtures/audio"
HARNESS_DIR="$PROJECT_DIR/scripts/bench/harness"
BUILD_DIR="$PROJECT_DIR/build/engine-bench"
COMMON="$HARNESS_DIR/BenchCommon.swift"
RESULTS="$BUILD_DIR/results.tsv"
ENGINES="${ENGINES:-whisperkit,parakeet,speechanalyzer}"

log()  { printf '\033[36m▸\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcrun >/dev/null || die "Xcode command line tools required."
[[ -d "$FIXTURE_DIR" ]] || die "fixtures missing: $FIXTURE_DIR"
mkdir -p "$BUILD_DIR"
: > "$RESULTS"

SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macosx14.0"

# --- fixture pairs (wav txt) ---
PAIRS=()
for wav in "$FIXTURE_DIR"/*.wav; do
    base="$(basename "$wav" .wav)"
    txt="$FIXTURE_DIR/$base.txt"
    [[ -f "$txt" ]] || continue
    PAIRS+=( "$wav" "$txt" )
done
[[ ${#PAIRS[@]} -gt 0 ]] || die "no fixtures in $FIXTURE_DIR"
log "$(( ${#PAIRS[@]} / 2 )) fixtures from $FIXTURE_DIR"

# TODO rows accumulate here (engine|reason) for engines that couldn't run.
TODO_ROWS=()
want() { [[ ",$ENGINES," == *",$1,"* ]]; }

# ---------------------------------------------------------------------------
# WhisperKit
# ---------------------------------------------------------------------------
run_whisperkit() {
    local staged="$HOME/Library/Application Support/OpenWhisp/whisperkit-models"
    local model="${WHISPERKIT_MODEL:-}"
    if [[ -z "$model" ]]; then
        for m in openai_whisper-small openai_whisper-tiny.en openai_whisper-large-v3-turbo; do
            [[ -d "$staged/$m" ]] && { model="$m"; break; }
        done
        model="${model:-openai_whisper-tiny.en}"
    fi
    log "WhisperKit: model '$model' (override with WHISPERKIT_MODEL=…)"

    # shellcheck source=scripts/whisperkit-link-args.sh
    source "$PROJECT_DIR/scripts/whisperkit-link-args.sh"
    if ! WHISPERKIT=1 resolve_whisperkit_args || [[ ${#WHISPERKIT_ARGS[@]} -eq 0 ]]; then
        TODO_ROWS+=( "WhisperKit|WhisperKit dependency failed to build/link on this host" )
        return
    fi

    local svc="$PROJECT_DIR/OpenWhisp/Services"
    local out="$BUILD_DIR/whisperkit-bench"
    log "WhisperKit: compiling harness…"
    if ! xcrun swiftc \
        -target "$TARGET" -sdk "$SDK" -parse-as-library -O \
        -framework Foundation -framework AVFoundation -framework CoreML \
        "${WHISPERKIT_ARGS[@]}" \
        "$COMMON" \
        "$HARNESS_DIR/whisperkit-bench.swift" \
        "$svc/WhisperKitEngine.swift" "$svc/WhisperKitBridge.swift" \
        "$svc/WhisperKitModelCatalog.swift" "$svc/TranscriptionEngine.swift" \
        "$svc/WhisperTask.swift" "$svc/Instrumentation.swift" \
        "$svc/ModelStorage.swift" "$svc/AudioLevel.swift" "$svc/AsyncTimeout.swift" \
        "$svc/AudioCapture.swift" \
        -o "$out" 2>"$BUILD_DIR/whisperkit-build.log"
    then
        warn "WhisperKit harness compile failed (see $BUILD_DIR/whisperkit-build.log)"
        TODO_ROWS+=( "WhisperKit|harness compile failed — see build/engine-bench/whisperkit-build.log" )
        return
    fi
    ok "WhisperKit harness built"
    log "WhisperKit: transcribing (first run may download the model)…"
    if ! "$out" "$model" "${PAIRS[@]}" >>"$RESULTS" 2>&1; then
        warn "WhisperKit run exited non-zero"
    fi
}

# ---------------------------------------------------------------------------
# Parakeet (TDT v3 batch)
# ---------------------------------------------------------------------------
run_parakeet() {
    # shellcheck source=scripts/fluidaudio-link-args.sh
    source "$PROJECT_DIR/scripts/fluidaudio-link-args.sh"
    if ! PARAKEET=1 resolve_fluidaudio_args || [[ ${#FLUIDAUDIO_ARGS[@]} -eq 0 ]]; then
        TODO_ROWS+=( "Parakeet|FluidAudio dependency failed to build/link on this host" )
        return
    fi

    local out="$BUILD_DIR/parakeet-bench"
    log "Parakeet: compiling harness…"
    if ! xcrun swiftc \
        -target "$TARGET" -sdk "$SDK" -parse-as-library -O \
        -framework Foundation -framework AVFoundation -framework CoreML \
        "${FLUIDAUDIO_ARGS[@]}" \
        "$COMMON" \
        "$HARNESS_DIR/parakeet-bench.swift" \
        "$PROJECT_DIR/OpenWhisp/Services/ParakeetBridge.swift" \
        "$PROJECT_DIR/OpenWhisp/Services/ParakeetCatalog.swift" \
        -o "$out" 2>"$BUILD_DIR/parakeet-build.log"
    then
        warn "Parakeet harness compile failed (see $BUILD_DIR/parakeet-build.log)"
        TODO_ROWS+=( "Parakeet|harness compile failed — see build/engine-bench/parakeet-build.log" )
        return
    fi
    ok "Parakeet harness built"
    log "Parakeet: transcribing (first run downloads ~600 MB TDT v3)…"
    if ! "$out" "${PAIRS[@]}" >>"$RESULTS" 2>&1; then
        warn "Parakeet run exited non-zero"
        TODO_ROWS+=( "Parakeet|model load/transcribe failed at runtime — see console" )
    fi
}

# ---------------------------------------------------------------------------
# SpeechAnalyzer (macOS 26)
# ---------------------------------------------------------------------------
run_speechanalyzer() {
    local osmajor; osmajor="$(sw_vers -productVersion | cut -d. -f1)"
    if (( osmajor < 26 )); then
        TODO_ROWS+=( "SpeechAnalyzer|requires macOS 26; host is macOS $(sw_vers -productVersion)" )
        return
    fi
    local out="$BUILD_DIR/speechanalyzer-bench"
    log "SpeechAnalyzer: compiling harness…"
    if ! xcrun swiftc \
        -target "$TARGET" -sdk "$SDK" -parse-as-library -O \
        -framework Foundation -framework AVFoundation -framework Speech \
        "$COMMON" \
        "$HARNESS_DIR/speechanalyzer-bench.swift" \
        -o "$out" 2>"$BUILD_DIR/speechanalyzer-build.log"
    then
        warn "SpeechAnalyzer harness compile failed (see $BUILD_DIR/speechanalyzer-build.log)"
        TODO_ROWS+=( "SpeechAnalyzer|harness compile failed — see build/engine-bench/speechanalyzer-build.log" )
        return
    fi
    ok "SpeechAnalyzer harness built"
    log "SpeechAnalyzer: transcribing (first run provisions locale assets)…"
    if ! "$out" "${PAIRS[@]}" >>"$RESULTS" 2>&1; then
        warn "SpeechAnalyzer run exited non-zero"
        TODO_ROWS+=( "SpeechAnalyzer|model/asset provisioning or transcribe failed — see console" )
    fi
}

want whisperkit     && run_whisperkit
want parakeet       && run_parakeet
want speechanalyzer && run_speechanalyzer

# ---------------------------------------------------------------------------
# Render the markdown table.
# ---------------------------------------------------------------------------
HW="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
MEM="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"
OSV="macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
SWIFTV="$(swift --version 2>&1 | grep -o 'Swift version [0-9.]*' | head -1)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

render() {
    echo "<!-- Generated by scripts/bench/engine-bench.sh on $NOW -->"
    echo "**Host:** $HW · $MEM · $OSV · $SWIFTV"
    echo
    echo "Per-fixture (× realtime = audio duration ÷ processing time; higher is faster):"
    echo
    echo "| Engine | Model / variant | Fixture | Audio (s) | Proc (s) | × realtime | WER |"
    echo "|---|---|---|---:|---:|---:|---:|"
    # aggregate accumulators keyed by engine||model
    awk -F'\t' '
        $1 == "BENCH" {
            eng=$2; model=$3; fix=$4; adur=$5; pdur=$6; x=$7; wer=$8; refw=$9; edit=$10;
            printf "| %s | %s | %s | %.2f | %.2f | %.2fx | %.1f%% |\n", eng, model, fix, adur, pdur, x, wer;
            key=eng "||" model;
            sumA[key]+=adur; sumP[key]+=pdur; sumRef[key]+=refw; sumEdit[key]+=edit; n[key]++;
            order[key]=(key in order)?order[key]:(++oi);
        }
        END {
            print "" > "/dev/stderr";
            # emit an aggregate block via a temp marker the shell picks up
        }
    ' "$RESULTS"
    echo
    echo "Aggregate (all fixtures pooled — micro-averaged WER = total word edits ÷ total reference words; the empty silence reference contributes 0 edits / 0 words):"
    echo
    echo "| Engine | Model / variant | Mean × realtime | Aggregate WER | Notes |"
    echo "|---|---|---:|---:|---|"
    awk -F'\t' '
        $1 == "BENCH" {
            key=$2 "||" $3;
            if (!(key in seen)) { seen[key]=1; ord[++oi]=key; eng[key]=$2; mdl[key]=$3; }
            sumA[key]+=$5; sumP[key]+=$6; sumRef[key]+=$9; sumEdit[key]+=$10; n[key]++;
        }
        END {
            for (i=1;i<=oi;i++){
                k=ord[i];
                meanX = (sumP[k]>0)? sumA[k]/sumP[k] : 0;
                wer = (sumRef[k]>0)? (sumEdit[k]/sumRef[k]*100) : 0;
                printf "| %s | %s | %.2fx | %.1f%% | %d fixtures |\n", eng[k], mdl[k], meanX, wer, n[k];
            }
        }
    ' "$RESULTS"
    if (( ${#TODO_ROWS[@]} > 0 )); then
        echo
        echo "TODO (engines that could not run headlessly on this host):"
        echo
        echo "| Engine | Reason |"
        echo "|---|---|"
        for row in "${TODO_ROWS[@]}"; do
            echo "| ${row%%|*} | TODO — ${row#*|} |"
        done
    fi
}

TABLE="$(render)"

if [[ -n "${OUT:-}" ]]; then
    printf '%s\n' "$TABLE" > "$OUT"
    ok "Wrote table to $OUT"
fi
printf '\n%s\n' "$TABLE"
ok "Bench complete. Raw TSV: $RESULTS"
