#!/bin/bash
# Generate the E2E audio-test fixture set in Tests/Fixtures/audio/.
#
# Each fixture is a 16 kHz / mono / 16-bit PCM WAV (Whisper's native format, so
# no in-app resampling) paired with an expected-transcript `.txt`. The set is
# small and checked in (the whisper.cpp `jfk.wav` lives in a submodule that CI
# does NOT check out, so fixtures must be self-contained in the parent repo).
#
# Determinism: `say` renders from text with a fixed voice + rate, then
# `afconvert` down-samples to 16 kHz mono LEI16. Re-running reproduces the same
# bytes on the same OS/voice. The expected `.txt` is the *spoken* text — the
# real-engine (Tier 2 / nightly) suite asserts against it with fuzzy/WER
# matching, never exact equality (see docs/E2E_AUDIO_TESTING.md determinism
# policy). Tier 1 (plain `swift test`) replays these WAVs through
# FileAudioCapture and a scripted engine and asserts on the pipeline, not on
# Whisper's accuracy, so it does not need the real transcript to match.
#
# Usage: ./scripts/gen-audio-fixtures.sh [--check]
#   --check   regenerate into a temp dir and diff against the committed set;
#             exits non-zero if they differ (a CI drift guard). Because `say`
#             output can vary across macOS/voice versions, --check compares only
#             format (sample rate / channels / bit depth), not sample bytes.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_DIR/Tests/Fixtures/audio"

VOICE="${OPENWHISP_FIXTURE_VOICE:-Samantha}"   # a stable US-English voice
RATE="${OPENWHISP_FIXTURE_RATE:-175}"          # words per minute

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if [[ "$CHECK" == "1" ]]; then
    OUT_DIR="$(mktemp -d)/audio"
fi
mkdir -p "$OUT_DIR"

# say-to-16kHz-mono-WAV. Renders AIFF then converts, because `say`'s WAV output
# doesn't let us pin the sample rate; afconvert does.
render() {
    local text="$1" out="$2"
    local aiff
    aiff="$(mktemp).aiff"
    say -v "$VOICE" -r "$RATE" -o "$aiff" "$text"
    # LEI16 = little-endian signed 16-bit; 16000 Hz; mono. Matches AudioRecorder's
    # on-disk WAV settings (16 kHz / 1ch / 16-bit int / LE).
    afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$out"
    rm -f "$aiff"
}

# Concatenate WAVs with a silence gap between them, so VAD/silence-auto-stop and
# the pause-based chunker have realistic utterance boundaries to find.
# gap_seconds of digital silence at 16 kHz mono 16-bit.
silence_wav() {
    local seconds="$1" out="$2"
    local frames
    frames="$(printf '%.0f' "$(echo "$seconds * 16000" | bc -l)")"
    # 2 bytes/frame of zeros.
    afconvert -f WAVE -d LEI16@16000 -c 1 \
        <(head -c $((frames * 2)) /dev/zero | \
          afconvert -f WAVE -d LEI16@16000 -c 1 /dev/stdin - 2>/dev/null) \
        "$out" 2>/dev/null || {
        # Fallback: python writes the silence WAV directly (robust across afconvert
        # stdin quirks).
        python3 - "$out" "$frames" <<'PY'
import sys, wave
out, frames = sys.argv[1], int(sys.argv[2])
w = wave.open(out, "wb")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b"\x00\x00" * frames)
w.close()
PY
    }
}

# Concatenate a list of WAVs (assumed identical format) into one.
concat_wavs() {
    local out="$1"; shift
    python3 - "$out" "$@" <<'PY'
import sys, wave
out, ins = sys.argv[1], sys.argv[2:]
first = wave.open(ins[0], "rb")
params = first.getparams()
frames = [first.readframes(first.getnframes())]
first.close()
for p in ins[1:]:
    w = wave.open(p, "rb")
    frames.append(w.readframes(w.getnframes()))
    w.close()
w = wave.open(out, "wb")
w.setparams(params)
for f in frames:
    w.writeframes(f)
w.close()
PY
}

# Emit a fixture: a WAV plus its expected-transcript sidecar.
emit() {
    local name="$1" transcript="$2"
    render "$transcript" "$OUT_DIR/$name.wav"
    printf '%s\n' "$transcript" > "$OUT_DIR/$name.txt"
    echo "  ✓ $name.wav ($(du -h "$OUT_DIR/$name.wav" | cut -f1))"
}

echo "Generating audio fixtures into $OUT_DIR (voice=$VOICE rate=$RATE)…"

# 1) Plain speech — the streaming-transcription baseline.
emit "plain_speech" "The quick brown fox jumps over the lazy dog."

# 2) Numbers and dates — smart-formatting coverage.
emit "numbers_dates" "Call me at four fifteen on March third about the twelve hundred dollar invoice."

# 3) Speech then a long silence tail — silence auto-stop / VAD finalization.
tmp_speech="$(mktemp).wav"
tmp_sil="$(mktemp).wav"
render "This sentence is followed by two seconds of silence." "$tmp_speech"
silence_wav 2.0 "$tmp_sil"
concat_wavs "$OUT_DIR/speech_then_silence.wav" "$tmp_speech" "$tmp_sil"
printf '%s\n' "This sentence is followed by two seconds of silence." \
    > "$OUT_DIR/speech_then_silence.txt"
rm -f "$tmp_speech" "$tmp_sil"
echo "  ✓ speech_then_silence.wav ($(du -h "$OUT_DIR/speech_then_silence.wav" | cut -f1))"

# 4) Two utterances separated by a pause — pause-based chunker splits into two.
a="$(mktemp).wav"; b="$(mktemp).wav"; g="$(mktemp).wav"
render "First utterance." "$a"
silence_wav 1.0 "$g"
render "Second utterance." "$b"
concat_wavs "$OUT_DIR/two_utterances.wav" "$a" "$g" "$b"
printf '%s\n' "First utterance. Second utterance." > "$OUT_DIR/two_utterances.txt"
rm -f "$a" "$b" "$g"
echo "  ✓ two_utterances.wav ($(du -h "$OUT_DIR/two_utterances.wav" | cut -f1))"

# 5) Pure silence — the "nothing was said" path (empty outcome).
silence_wav 1.5 "$OUT_DIR/silence.wav"
printf '' > "$OUT_DIR/silence.txt"
echo "  ✓ silence.wav ($(du -h "$OUT_DIR/silence.wav" | cut -f1))"

echo "Done. $(ls "$OUT_DIR"/*.wav | wc -l | tr -d ' ') WAV fixtures."

if [[ "$CHECK" == "1" ]]; then
    echo ""
    echo "Checking committed fixtures' format against a fresh render…"
    fail=0
    for wav in "$OUT_DIR"/*.wav; do
        name="$(basename "$wav")"
        committed="$PROJECT_DIR/Tests/Fixtures/audio/$name"
        if [[ ! -f "$committed" ]]; then
            echo "  ✗ $name missing from committed set"; fail=1; continue
        fi
        fresh_fmt="$(afinfo "$wav" 2>/dev/null | grep -E 'Data format|Channels|sample rate' || true)"
        comm_fmt="$(afinfo "$committed" 2>/dev/null | grep -E 'Data format|Channels|sample rate' || true)"
        if [[ "$fresh_fmt" != "$comm_fmt" ]]; then
            echo "  ✗ $name format drift"; fail=1
        else
            echo "  ✓ $name format matches"
        fi
    done
    exit "$fail"
fi
