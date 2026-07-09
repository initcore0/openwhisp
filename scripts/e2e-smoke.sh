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
SAVED_OUTPUT_FILE="$STATE_DIR/saved-output-device"
SAVED_INPUT_FILE="$STATE_DIR/saved-input-device"
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
    # Parse the JSON listing ({"name":…,"type":…,"id":…,"uid":…}) rather than the
    # CSV `-f cli` form: some device UIDs contain commas (e.g. Shure MV7+), which
    # would break naive comma-splitting. Match our device by name, print its uid.
    SwitchAudioSource -a -t input -f json 2>/dev/null \
        | python3 -c "
import sys, json
name = '$BLACKHOLE_NAME'
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get('name') == name:
        print(d.get('uid', ''))
        break
"
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
    if [[ -f "$SAVED_OUTPUT_FILE" ]]; then
        local dev; dev="$(cat "$SAVED_OUTPUT_FILE")"
        [[ -n "$dev" ]] && SwitchAudioSource -t output -s "$dev" 2>/dev/null \
            && ok "Restored default output to '$dev'."
    fi
    if [[ -f "$SAVED_INPUT_FILE" ]]; then
        local dev; dev="$(cat "$SAVED_INPUT_FILE")"
        [[ -n "$dev" ]] && SwitchAudioSource -t input -s "$dev" 2>/dev/null \
            && ok "Restored default input to '$dev'."
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
    local status_line
    status_line="$("$cli" status 2>/dev/null)" || die "OpenWhisp app not running / bridge unreachable. Launch the app, then retry."
    # A session already in progress makes `dictate` return busy (exit 4). Catch it
    # here with a clear message instead of a cryptic mid-run failure — a stuck
    # user session clears by pressing the dictation hotkey once or restarting the app.
    if printf '%s' "$status_line" | grep -q "session=active"; then
        die "OpenWhisp already has an active session. End it (press your dictation hotkey, or restart the app), then retry."
    fi

    local uid; uid="$(blackhole_uid)"
    [[ -n "$uid" ]] || die "BlackHole not found. Run: $0 --setup"

    # Routing — the important subtlety: a RUNNING OpenWhisp only reads its
    # `microphoneID` setting at launch (no live observer), so `defaults write` to
    # it is invisible to the running app. Instead we drive the SYSTEM defaults:
    #   - default OUTPUT = BlackHole → the fixture playback lands in BlackHole
    #   - default INPUT  = BlackHole → OpenWhisp (with an EMPTY microphoneID, i.e.
    #     "system default") captures BlackHole
    # We also CLEAR OpenWhisp's microphoneID so a previously-pinned device can't
    # override the system default. Playing to the default AudioToolbox sink also
    # sidesteps ffmpeg's undiscoverable per-device output index.
    defaults read "$BUNDLE_ID" microphoneID > "$SAVED_MIC_ID_FILE" 2>/dev/null || echo "" > "$SAVED_MIC_ID_FILE"
    SwitchAudioSource -c -t output > "$SAVED_OUTPUT_FILE" 2>/dev/null || echo "" > "$SAVED_OUTPUT_FILE"
    SwitchAudioSource -c -t input  > "$SAVED_INPUT_FILE"  2>/dev/null || echo "" > "$SAVED_INPUT_FILE"
    trap cmd_restore EXIT

    # Clear OpenWhisp's pinned mic so it follows the system default input. NOTE:
    # this only takes effect for an app launched AFTER this write; if the app was
    # already running with a pinned device, set "Input device: System Default" (or
    # BlackHole) in OpenWhisp Settings once — see the note we print on mismatch.
    defaults write "$BUNDLE_ID" microphoneID ""

    SwitchAudioSource -t output -s "$BLACKHOLE_NAME" 2>/dev/null \
        && ok "Default OUTPUT → BlackHole (fixture playback lands here)." \
        || die "Couldn't set BlackHole as the default output device."
    SwitchAudioSource -t input -s "$BLACKHOLE_NAME" 2>/dev/null \
        && ok "Default INPUT → BlackHole (OpenWhisp captures here)." \
        || die "Couldn't set BlackHole as the default input device."
    sleep 1   # let CoreAudio + OpenWhisp settle on the new devices

    log "Starting dictation and playing '$fixture_name' into BlackHole…"
    # dictate blocks until the session ends. The fixture ends in silence, so
    # silence-auto-stop finishes the session; --timeout is a backstop.
    local out_file="$STATE_DIR/transcript.txt"
    ( sleep 0.5   # ~0.5s leading silence so capture is armed before audio
      # -re paces playback at real time; default audiotoolbox sink = BlackHole now.
      ffmpeg -hide_banner -loglevel error -re -i "$wav" -f audiotoolbox - 2>/dev/null
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
        # Tolerate Whisper's silence hallucinations: non-speech markers the app
        # strips ([BLANK_AUDIO]) AND the bare-word artifacts models emit on silence
        # ("you", "thank you", "thanks for watching", "bye") — never real
        # single-word dictations, so treating them as empty is safe here.
        case "$t_norm" in
            ""|"blank audio"|"silence"|"no speech"|"music"|"inaudible"|"noise"\
            |"you"|"thank you"|"thanks for watching"|"bye"|"thanks")
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
