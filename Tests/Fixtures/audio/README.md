# Audio test fixtures

16 kHz / mono / 16-bit PCM WAVs (Whisper's native format — no in-app resampling)
used by the E2E audio-testing suite. See [docs/E2E_AUDIO_TESTING.md](../../../docs/E2E_AUDIO_TESTING.md).

Each `*.wav` pairs with a `*.txt` holding the **spoken** text. Tier-1 tests
(plain `swift test`) replay the WAV through `FileAudioCapture` and assert on the
pipeline (chunking, VAD, ordering, formatting, history, output) with a scripted
engine — they do **not** need the `.txt` to match Whisper's output. The real-engine
Tier-2 / nightly suite asserts against the `.txt` with **fuzzy/WER matching**,
never exact equality (Whisper is non-deterministic across machines/OS — see the
determinism policy in the plan).

These are checked in (not generated at build time) because the whisper.cpp
`jfk.wav` lives in a submodule the CI job does not check out — fixtures must be
self-contained in the parent repo.

| Fixture | Duration | What it exercises |
|---|---|---|
| `plain_speech.wav` | ~2.5 s | Streaming-transcription baseline (continuous speech). |
| `numbers_dates.wav` | ~4.0 s | Smart-formatting (numbers, times, dates, currency). |
| `speech_then_silence.wav` | ~5.0 s | Silence auto-stop / VAD finalization (speech + 2 s silence tail). |
| `two_utterances.wav` | ~3.0 s | Pause-based chunker splitting into two utterances (1 s gap). |
| `silence.wav` | 1.5 s | The "nothing was said" path (empty outcome; pure digital silence). |

## Regenerating

```bash
./scripts/gen-audio-fixtures.sh          # rewrite the set
./scripts/gen-audio-fixtures.sh --check  # CI drift guard (format-only)
```

Generation uses `say` + `afconvert` with a pinned voice (`Samantha`) and rate
(175 wpm). Sample bytes can vary across macOS/voice versions, so `--check`
compares only the audio *format* (sample rate / channels / bit depth), which is
what the pipeline cares about.
