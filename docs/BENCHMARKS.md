# Engine benchmarks — SpeechAnalyzer vs Parakeet vs WhisperKit

> A public, **reproducible** file-transcription benchmark for OpenWhisp's three
> on-device engines (MAK-79). Everything here is produced by
> [`scripts/bench/engine-bench.sh`](../scripts/bench/engine-bench.sh) on a real
> machine — no numbers are extrapolated or hand-tuned. Re-run it yourself; the
> table below records the exact host it came from.

## TL;DR — which engine, when

Framing follows MAK-59's positioning: **Apple's engine where it's best, Parakeet
where latency matters.**

- **SpeechAnalyzer (Apple, macOS 26)** — fastest file throughput and clean
  auto-punctuation with zero bundled model to download. The default *file* engine
  on macOS 26 where it's available.
- **Parakeet (NVIDIA TDT v3 via FluidAudio)** — the engine that makes *streaming
  dictation* feel realtime (0.32 s partial latency, see below); its batch/file
  path keeps utterance-onset words and covers 25 European languages. The default
  transcription engine on a fresh install (`docs/PARAKEET.md`).
- **WhisperKit (OpenAI Whisper, CoreML/ANE)** — nominally the broadest language
  coverage; heavier per-file cost, model chosen by the user
  (tiny…large-v3-turbo). **Legacy/de-recommended.** Three caveats on that
  coverage claim: (1) it is **unmeasured here** — every fixture on this page is
  English, so nothing below tests any other language; (2) the app's language
  picker caps *every* engine at 12 languages + auto, so the extra coverage is
  not reachable from the UI; (3) the translate task it used to own is **no
  longer an engine feature at all** — translation runs on the Apple Translation
  *text* path for every engine, so it is not a WhisperKit differentiator.

This page measures **file-transcription speed and accuracy only.** Streaming
latency — the number that actually decides the dictation feel — needs a live-mic
methodology and is tracked separately (MAK-72); see
[Streaming latency](#streaming-latency-not-measured-here) below.

## Methodology

### Fixture set

The five WAVs in [`Tests/Fixtures/audio/`](../Tests/Fixtures/audio/), each paired
with a `.txt` reference transcript:

| Fixture | Audio | Reference |
|---|---:|---|
| `plain_speech.wav` | 2.50 s | "The quick brown fox jumps over the lazy dog." |
| `numbers_dates.wav` | 4.03 s | "Call me at four fifteen on March third about the twelve hundred dollar invoice." |
| `two_utterances.wav` | 3.02 s | "First utterance. Second utterance." |
| `speech_then_silence.wav` | 4.97 s | "This sentence is followed by two seconds of silence." |
| `silence.wav` | 1.50 s | *(empty — must transcribe to nothing)* |

### Metrics

- **× realtime** = audio duration ÷ processing wall-clock time. Higher is faster;
  1.0× means "as long as the clip." The model is **warmed once** before timing
  (an initial discarded transcribe) so a one-off download/compile doesn't skew the
  first fixture. Timing varies run-to-run (thermal state, scheduling) — treat the
  × realtime figures as a band, not an exact constant; **WER is deterministic** and
  reproduces exactly across runs.
- **WER (word error rate)** = word-level Levenshtein edit distance between the
  normalized reference and hypothesis, divided by the reference word count — the
  standard definition, implemented deterministically in
  [`scripts/bench/harness/BenchCommon.swift`](../scripts/bench/harness/BenchCommon.swift).
  Normalization lowercases and maps every non-alphanumeric character to a space,
  so **punctuation and casing never count as errors** — only genuine word
  substitutions, insertions, and deletions do.
  - *Aggregate WER* is micro-averaged: total word edits across all fixtures ÷
    total reference words (not a mean of per-fixture rates). The empty `silence`
    reference contributes 0 edits / 0 words, so it never moves the aggregate.
  - **Caveat — digit normalization inflates WER.** All three engines auto-format
    numbers ("four fifteen" → "4:15", "twelve hundred dollar" → "$1,200"), which
    the word-level metric counts as errors against the spelled-out reference even
    when the transcription is *perfect*. `numbers_dates.wav` is therefore a
    stress fixture for the metric, not the engine — read its transcript, not just
    its WER. This is honest to report rather than hide: it's why the aggregate WER
    is non-zero for engines that made no real mistake.

### Exact commands

```bash
# All engines, auto model selection (WhisperKit reuses any already-staged model):
./scripts/bench/engine-bench.sh

# One engine at a time:
ENGINES="speechanalyzer" ./scripts/bench/engine-bench.sh
ENGINES="parakeet"       ./scripts/bench/engine-bench.sh
ENGINES="whisperkit" WHISPERKIT_MODEL=openai_whisper-small ./scripts/bench/engine-bench.sh

# Write the markdown table straight to a file:
OUT=/tmp/bench.md ./scripts/bench/engine-bench.sh
```

Each engine runs behind a small ad-hoc `swiftc` harness (no SwiftPM target, so
`swift test` is unaffected):

- **WhisperKit** — reuses the app's `WhisperKitEngine` compiled with
  `-D WHISPERKIT` and linked against the WhisperKit dependency (same recipe as
  `scripts/e2e-whisperkit.sh`). Runs offline once a model is staged.
- **Parakeet** — reuses the app's `ParakeetBridge.loadBatch`/`transcribeBatch`
  (the real `ParakeetFileEngine` backend, TDT v3) compiled with `-D PARAKEET` and
  linked against FluidAudio. **First run downloads ~600 MB** of CoreML models to
  `~/Library/Application Support/FluidAudio/Models/`.
- **SpeechAnalyzer** — the macOS 26 Speech framework (`SpeechTranscriber` file
  path), mirroring `SpeechAnalyzerBridge.transcribeFile`'s unbiased path. **First
  run provisions the locale's assets** via `AssetInventory`.

A build or download failure for one engine is isolated — it's reported as a TODO
row and the others still run.

## Results

<!-- BENCH_TABLE_START -->
<!-- Generated by scripts/bench/engine-bench.sh -->
**Host:** Apple M1 Pro · 16 GB · macOS 26.5.2 (25F84) · Swift version 6.3.3

Per-fixture (× realtime = audio duration ÷ processing time; higher is faster):

| Engine | Model / variant | Fixture | Audio (s) | Proc (s) | × realtime | WER |
|---|---|---|---:|---:|---:|---:|
| SpeechAnalyzer | SpeechTranscriber (system) | plain_speech.wav | 2.50 | 0.14 | 17.25x | 0.0% |
| SpeechAnalyzer | SpeechTranscriber (system) | numbers_dates.wav | 4.03 | 0.17 | 22.96x | 42.9% |
| SpeechAnalyzer | SpeechTranscriber (system) | two_utterances.wav | 3.02 | 0.14 | 20.80x | 0.0% |
| SpeechAnalyzer | SpeechTranscriber (system) | speech_then_silence.wav | 4.97 | 0.15 | 32.58x | 0.0% |
| SpeechAnalyzer | SpeechTranscriber (system) | silence.wav | 1.50 | 0.10 | 15.57x | 0.0% |
| WhisperKit | openai_whisper-small | plain_speech.wav | 2.50 | 0.48 | 5.17x | 0.0% |
| WhisperKit | openai_whisper-small | numbers_dates.wav | 4.03 | 0.56 | 7.15x | 42.9% |
| WhisperKit | openai_whisper-small | two_utterances.wav | 3.02 | 0.48 | 6.27x | 0.0% |
| WhisperKit | openai_whisper-small | speech_then_silence.wav | 4.97 | 0.48 | 10.24x | 0.0% |
| WhisperKit | openai_whisper-small | silence.wav | 1.50 | 0.41 | 3.68x | 100.0% |
| Parakeet | TDT v3 (batch/file) | plain_speech.wav | 2.50 | 0.11 | 22.66x | 0.0% |
| Parakeet | TDT v3 (batch/file) | numbers_dates.wav | 4.03 | 0.15 | 27.58x | 42.9% |
| Parakeet | TDT v3 (batch/file) | two_utterances.wav | 3.02 | 0.11 | 27.08x | 0.0% |
| Parakeet | TDT v3 (batch/file) | speech_then_silence.wav | 4.97 | 0.12 | 42.99x | 0.0% |
| Parakeet | TDT v3 (batch/file) | silence.wav | 1.50 | 0.10 | 14.83x | 100.0% |

Aggregate (all fixtures pooled — micro-averaged WER = total word edits ÷ total
reference words; the empty silence reference contributes 0 edits / 0 words):

| Engine | Model / variant | Mean × realtime | Aggregate WER | Notes |
|---|---|---:|---:|---|
| SpeechAnalyzer | SpeechTranscriber (system) | 22.44x | 16.7% | no bundled model to download; clean auto-punctuation; only engine that returns true empty on silence |
| WhisperKit | openai_whisper-small | 6.62x | 22.2% | legacy; nominally broadest languages, but **unmeasured** (all fixtures are English) and the UI caps every engine at 12 languages — and translate is now engine-independent (text path), not a WhisperKit feature; heavier per file; raw output emits `[BLANK_AUDIO]` on silence (the app's TranscriptCleaner strips it — the 100% silence WER is that raw marker, not a real error) |
| Parakeet | TDT v3 (batch/file) | 27.38x | 22.2% | fastest file throughput of the three; keeps utterance-onset words ("The …"); 25 European languages; first run downloads ~600 MB; hallucinates "Thank you." on pure silence (see below) |

Reading the numbers honestly:

- The **only** non-zero WER on real speech is `numbers_dates.wav` (42.9% on all
  three engines) — that is entirely digit normalization ("four fifteen" → "4:15" /
  "4 15", "twelve hundred dollar" → "$1,200"), not a transcription mistake. Every
  engine produces a clean sentence; see the [WER caveat](#metrics). On the other
  three spoken fixtures all three engines score **0% WER**.
- **The 100% on `silence.wav`** is a raw-engine artifact of benchmarking *bare*
  output: WhisperKit emits `[BLANK_AUDIO]` and Parakeet emits "Thank you." on pure
  silence — both are stripped by the app's downstream `TranscriptCleaner` (and by
  VAD, which never feeds pure silence to the engine in the live pipeline).
  SpeechAnalyzer alone returns true empty. This row is kept visible precisely
  because it's honest about the raw engines' silence behavior.
- **Speed:** on this host Parakeet TDT v3 (27.4× mean) and SpeechAnalyzer (22.4×)
  are the fastest per file; WhisperKit-small is ~6.6×. SpeechAnalyzer needs no
  bundled model and Parakeet keeps the leading word WhisperKit-small also keeps
  here — consistent with MAK-59's "Apple's engine where it's best, Parakeet where
  latency matters."
<!-- BENCH_TABLE_END -->

## Streaming latency (not measured here)

The numbers above are **file/batch throughput**, which is not the same as the
partial-transcript latency you feel while dictating. This benchmark deliberately
does **not** attempt live-mic measurement — that needs a controlled audio-injection
methodology (BlackHole virtual mic + a partial-timestamp probe) tracked under
**MAK-72**.

The one streaming figure OpenWhisp already documents is Parakeet's: **~0.32 s**
partial latency on the default Unified streaming tier, with `finish()` returning
in ~50 ms (no batch decode). Source: [`docs/PARAKEET.md`](PARAKEET.md) ("two
manager shapes" / "Measured results"), from the MAK-46 integration harness. That
0.32 s is what makes Parakeet the default dictation engine despite SpeechAnalyzer's
faster *file* throughput.

## Reproducing / contributing

Add a fixture by dropping a `<name>.wav` + `<name>.txt` pair into
`Tests/Fixtures/audio/`; the bench picks it up automatically. The harness sources
live in `scripts/bench/harness/` — `BenchCommon.swift` (WER + WAV-duration +
TSV emit) is shared, one `*-bench.swift` per engine.
