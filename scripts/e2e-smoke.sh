#!/bin/bash
# Tier-2 E2E smoke test — the reality check (docs/E2E_AUDIO_TESTING.md).
#
# Black-box test of the REAL capture stack that Tier 1 deliberately doesn't
# touch: CoreAudio / AVAudioEngine capture, device enumeration by UID, and TCC.
# It routes a fixture WAV into the OpenWhisp app through a BlackHole virtual mic,
# drives a session with `openwhisp dictate` (which blocks until the session ends),
# and asserts on the transcript the CLI prints.
#
#   fixture.wav ──ffmpeg──▶ BlackHole 2ch ──CoreAudio──▶ OpenWhisp ──▶ transcript
#                                                    (mic UID selected by us)
#
# This is intentionally a HANDFUL of tests, tolerant of flake, run locally or
# nightly on a self-hosted Mac — NOT in blocking CI (the BlackHole cask is
# known-fragile on GitHub runner images). Everything deterministic lives in
# Tier 1 (`swift test`).
#
# Prereqs (installed by --setup):
#   brew install blackhole-2ch switchaudio-osx ffmpeg
# and the OpenWhisp app must be built + running, with mic permission granted once
# by hand (a signed local dev build is the forgiving case for TCC).
#
# Usage:
#   ./scripts/e2e-smoke.sh --setup     # install deps, list devices, print guidance
#   ./scripts/e2e-smoke.sh [fixture]   # run the smoke test (default: plain_speech)
#   ./scripts/e2e-smoke.sh --restore   # restore the saved default input device

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="$PROJECT_DIR/Tests/Fixtures/audio"
BUNDLE_ID="com.openwhisp.app"
BLACKHOLE_NAME="BlackHole 2ch"
APP_BINARY="OpenWhisp"
STATE_DIR="${TMPDIR:-/tmp}/openwhisp-e2e-smoke"
SAVED_DEVICE_FILE="$STATE_DIR/saved-input-device"
SAVED_MIC_ID_FILE="$STATE_DIR/saved-microphone-id"

mkdir -p "$STATE_DIR"

log()  { printf '\033[36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Locate the bundled CLI: prefer a built .app, fall back to a `swift build` binary.
find_cli() {
    local candidates=(
        "$PROJECT_DIR/build/$APP_BINARY.app/Contents/Helpers/openwhisp"
        "$PROJECT_DIR/build/OpenWhisp.app/Contents/Helpers/openwhisp"
        "/Applications/OpenWhisp.app/Contents/Helpers/openwhisp"
        "$PROJECT_DIR/.build/debug/openwhisp"
        "$PROJECT_DIR/.build/release/openwhisp"
    )
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

blackhole_uid() {
    # The CoreAudio device UID string OpenWhisp stores in `microphoneID`.
    # SwitchAudioSource prints it with -f cli/json; parse the UID for our device.
    SwitchAudioSource -a -t input -f cli 2>/dev/null \
        | awk -F, -v name="$BLACKHOLE_NAME" '
            $0 ~ name { for (i=1;i<=NF;i++) if ($i ~ /uid=/) { sub(/.*uid=/,"",$i); print $i; exit } }'
}

cmd_setup() {
    log "Installing BlackHole + helpers (idempotent)…"
    if ! command -v brew >/dev/null; then die "Homebrew required: https://brew.sh"; fi
    brew list blackhole-2ch  >/dev/null 2>&1 || brew install blackhole-2ch
    brew list switchaudio-osx >/dev/null 2>&1 || brew install switchaudio-osx
    brew list ffmpeg          >/dev/null 2>&1 || brew install ffmpeg

    log "Nudging coreaudiod so a freshly-installed BlackHole is enumerated…"
    sudo killall coreaudiod 2>/dev/null || warn "couldn't killall coreaudiod (may need sudo); device may still appear"

    log "Waiting for '$BLACKHOLE_NAME' to appear…"
    for _ in $(seq 1 20); do
        if system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole"; then
            ok "BlackHole present."
            break
        fi
        sleep 0.5
    done

    log "Input devices:"
    SwitchAudioSource -a -t input 2>/dev/null | sed 's/^/    /'
    local uid; uid="$(blackhole_uid)"
    [[ -n "$uid" ]] && ok "BlackHole UID: $uid" || warn "Could not read BlackHole UID yet."

    cat <<EOF

Next:
  1. Build + launch the OpenWhisp app (./build.sh && ./package.sh, then open it),
     or install it to /Applications.
  2. Grant microphone permission once (System Settings ▸ Privacy ▸ Microphone).
  3. Run:  ./scripts/e2e-smoke.sh plain_speech
EOF
}

cmd_restore() {
    if [[ -f "$SAVED_DEVICE_FILE" ]]; then
        local dev; dev="$(cat "$SAVED_DEVICE_FILE")"
        SwitchAudioSource -t input -s "$dev" 2>/dev/null && ok "Restored default input to '$dev'."
    fi
    if [[ -f "$SAVED_MIC_ID_FILE" ]]; then
        local prev; prev="$(cat "$SAVED_MIC_ID_FILE")"
        defaults write "$BUNDLE_ID" microphoneID "$prev" 2>/dev/null
        ok "Restored OpenWhisp microphoneID."
    fi
}

cmd_run() {
    local fixture_name="${1:-plain_speech}"
    local wav="$FIXTURE_DIR/$fixture_name.wav"
    local expected_file="$FIXTURE_DIR/$fixture_name.txt"
    [[ -f "$wav" ]] || die "fixture not found: $wav (see $FIXTURE_DIR)"

    command -v ffmpeg >/dev/null || die "ffmpeg missing — run: $0 --setup"
    command -v SwitchAudioSource >/dev/null || die "switchaudio-osx missing — run: $0 --setup"

    local cli; cli="$(find_cli)" || die "openwhisp CLI not found — build the app first (./build.sh && ./package.sh)"
    log "Using CLI: $cli"

    # Is the app up? `status` must reach the bridge socket.
    "$cli" status >/dev/null 2>&1 || die "OpenWhisp app not running / bridge unreachable. Launch the app, then retry."

    local uid; uid="$(blackhole_uid)"
    [[ -n "$uid" ]] || die "BlackHole not found. Run: $0 --setup"

    # Save + set the OpenWhisp input device to BlackHole by UID.
    defaults read "$BUNDLE_ID" microphoneID > "$SAVED_MIC_ID_FILE" 2>/dev/null || echo "" > "$SAVED_MIC_ID_FILE"
    SwitchAudioSource -c -t input > "$SAVED_DEVICE_FILE" 2>/dev/null || true
    defaults write "$BUNDLE_ID" microphoneID "$uid"
    ok "OpenWhisp input device set to BlackHole ($uid)."
    trap cmd_restore EXIT

    # ffmpeg output device index for BlackHole (AudioToolbox sink enumeration).
    local dev_index
    dev_index="$(ffmpeg -hide_banner -f audiotoolbox -list_devices true -i "" 2>&1 \
        | awk -v n="$BLACKHOLE_NAME" '$0 ~ n { gsub(/[^0-9]/,"",$1); print $1; exit }')"
    [[ -n "$dev_index" ]] || warn "Couldn't resolve ffmpeg device index; trying default sink."

    log "Starting dictation and playing '$fixture_name' into BlackHole…"
    # dictate blocks until the session ends. The fixture ends in silence, so
    # silence-auto-stop finishes the session; --timeout is a backstop.
    local out_file="$STATE_DIR/transcript.txt"
    ( sleep 0.5   # ~0.5s leading silence so capture is armed before audio
      if [[ -n "$dev_index" ]]; then
          ffmpeg -hide_banner -loglevel error -re -i "$wav" \
              -f audiotoolbox -audio_device_index "$dev_index" - 2>/dev/null
      else
          ffmpeg -hide_banner -loglevel error -re -i "$wav" -f audiotoolbox - 2>/dev/null
      fi
    ) &
    local ffmpeg_pid=$!

    "$cli" dictate --timeout 20 --language en > "$out_file" 2>/dev/null
    local rc=$?
    wait "$ffmpeg_pid" 2>/dev/null || true

    [[ $rc -eq 0 ]] || die "dictate exited $rc (see exit-code table in main.swift)"

    local transcript; transcript="$(cat "$out_file")"
    log "Transcript: \"$transcript\""

    # Fuzzy assertion (determinism policy): key-phrase containment on normalized
    # text. Whisper output varies across machines/OS — never exact-match.
    local expected="" ; [[ -f "$expected_file" ]] && expected="$(cat "$expected_file")"
    norm() { tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:] ' | tr -s ' '; }
    local t_norm; t_norm="$(printf '%s' "$transcript" | norm)"
    if [[ "$fixture_name" == "silence" ]]; then
        # Tolerate Whisper's blank-audio hallucination the app strips ([BLANK_AUDIO]).
        case "$t_norm" in
            ""|"blank audio"|"silence"|"no speech"|"music"|"inaudible"|"noise")
                ok "silence → empty transcript (got \"$transcript\")" ;;
            *) die "expected empty transcript for silence, got: $transcript" ;;
        esac
    else
        local e_norm
        e_norm="$(printf '%s' "$expected" | norm)"
        # Fraction of the expected's 3+-letter content words present in the
        # transcript. A ratio tolerates Whisper's number/date normalization
        # ("four fifteen" → "415") far better than a single key word. ≥40% passes.
        local total=0 hits=0 w
        for w in $(printf '%s' "$e_norm" | tr ' ' '\n' | awk 'length>=3' | sort -u); do
            total=$((total + 1))
            case " $t_norm " in *" $w "*) hits=$((hits + 1)) ;; esac
        done
        local pct=0; [[ $total -gt 0 ]] && pct=$(( hits * 100 / total ))
        if [[ $total -eq 0 || $pct -ge 40 ]]; then
            ok "transcript matches (${pct}% content-word overlap)"
        else
            die "only ${pct}% overlap — got=[$t_norm] expected≈[$e_norm]"
        fi
    fi
    ok "Tier-2 smoke test passed for '$fixture_name'."
}

case "${1:-}" in
    --setup)   cmd_setup ;;
    --restore) cmd_restore ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)         cmd_run "${1:-plain_speech}" ;;
esac
