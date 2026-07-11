# Parakeet — maintainer doc

> A local, true-streaming CoreML transcription backend built on NVIDIA Parakeet
> models via [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0).
> Two engines share the FluidAudio dependency:
>
> - **`ParakeetStreamingEngine`** (a `StreamingTranscriptionEngine`, the Apple
>   Speech seam) — live dictation. Partials trail the voice by the variant's chunk
>   latency (0.32 s for the default Unified tier), and `finish()` returns in ~50 ms
>   (no batch decode). This is what makes Parakeet dictation feel realtime.
> - **`ParakeetFileEngine`** (a `FileTranscriptionEngine`, the whisper.cpp seam) —
>   every BACKGROUND / file job: meetings, the file queue, watch folders, history
>   re-transcribe. Backed by Parakeet TDT v3 (batch), which covers 25 European
>   languages (incl. Russian) and keeps utterance-onset words the streaming
>   variants clip.
>
> This promotes the MAK-46 spike (see [PARAKEET_SPIKE.md](PARAKEET_SPIKE.md) for the
> original feasibility report) to a full integration. Mirrors the WhisperKit pilot
> ([WHISPERKIT_PILOT.md](WHISPERKIT_PILOT.md)).

## Build flag (off by default)

The app is compiled by `build.sh`/`build-dmg.sh` with a raw `swiftc` glob. FluidAudio
is a SwiftPM package linked via the `PARAKEET` flag, which is **OFF by default** —
unlike WhisperKit, Parakeet is not yet a default-build cost (see follow-ups):

- **Opt-in** (`PARAKEET=1 ./build.sh`): builds FluidAudio into one static lib
  (`scripts/build-fluidaudio.sh` → `scripts/fluidaudio-link-args.sh`), links it,
  defines the `PARAKEET` compile flag that activates the real engines, and shows the
  Parakeet row in Settings › Models (labeled Experimental).
- **Default build** (`./build.sh`): FluidAudio is not linked. `ParakeetStreamingEngine`
  and `ParakeetFileEngine` compile to stubs that report unavailability if selected.

```bash
PARAKEET=1 ./build.sh && ./package.sh --install
```

## Models

FluidAudio stages CoreML models itself on first use (HuggingFace →
`~/Library/Application Support/FluidAudio/Models/<repo>/`). No progress callback is
available, so the Models pane shows a **coarse** per-variant state — Not downloaded /
Downloading… / installed — from folder presence + an in-flight prefetch flag
(`ParakeetDownloadStatePolicy`). The `~600 MB` per repo also shows in Settings ›
Storage (`.parakeet` kind) and can be deleted (re-downloads on next use).

| Variant (catalog id) | Family | Repo folder | Latency | Languages | Size |
|---|---|---|---|---|---|
| `parakeet-unified-320ms` (default) | English streaming (Unified) | `parakeet-unified-en-0.6b` | 0.32 s | English, punctuation | ~600 MB |
| `parakeet-unified-1120ms` | English streaming (Unified) | `parakeet-unified-en-0.6b` (shared) | 1.12 s | English, punctuation | shared |
| `parakeet-eou-320ms` | English streaming (EOU 120M) | `parakeet-eou-streaming` | 0.32 s | English, no punctuation | ~150 MB |
| `nemotron-multilingual-1120ms` | Multilingual streaming (Nemotron) | `nemotron-multilingual` | 1.12 s | ~40 languages (auto-detect), punctuation | ~600 MB |
| TDT v3 (file engine only) | Batch | `parakeet-tdt-0.6b-v3` | n/a (batch) | 25 European (incl. Russian) | ~600 MB |

Selecting Parakeet warms the streaming variant up front; TDT v3 (the file engine)
loads **lazily on the first file/meeting job**, so a dictation-only user never pays
two ~600 MB downloads.

## Streaming: two manager shapes behind one protocol

FluidAudio ships two incompatible streaming manager shapes. `ParakeetBridge` (the
single `import FluidAudio` point) hides both behind an internal `ParakeetStreamSession`
protocol; `ParakeetStreamingEngine` talks only to the protocol:

- **`StreamingAsrManagerSession`** wraps `any StreamingAsrManager` (the English
  Unified / EOU families). English-only, so `setLanguage` is a no-op.
- **`NemotronMultilingualStreamSession`** wraps `StreamingNemotronMultilingualAsrManager`
  (the Nemotron multilingual actor). Honors the language hint; auto-detects.

The variant's `multilingual` flag (`ParakeetCatalog.Variant`) picks the manager.

## Language matrix

- **Streaming, English variants** — English only. A FIXED non-English dictation
  language is refused up front by `ParakeetLanguageGate` (never silently mangle
  non-English speech), with a message pointing at the multilingual variant. "auto"
  and `en*` proceed.
- **Streaming, multilingual variant** — accepts any language. The app's setting is
  mapped to the manager's `xx-XX`/`auto` code by `ParakeetLanguageHint`; unknown
  codes fall back to auto-detect inside FluidAudio, so the gate never refuses it.
- **File engine (TDT v3)** — 25 European languages. A fixed language is passed as a
  v3 script hint (`ParakeetLanguageHint.batchLanguageCode` → 2-letter code); "auto"
  and unknown codes let the model decide.

Pure mappers/gates live in OpenWhispCore and are unit-tested (`ParakeetSpikeTests`).

## How it's wired (for maintainers)

- `OpenWhisp/Services/ParakeetStreamingEngine.swift` — the streaming engine
  (`#if PARAKEET`, else stub). Owns the mic via its own `AVAudioEngine` tap; buffers
  flow tap → `AsyncStream` (ordered) → the session; partials hop to the main actor
  behind a generation gate; `SerialTaskChain` serializes start/stop.
- `OpenWhisp/Services/ParakeetFileEngine.swift` — the batch/file engine
  (`#if PARAKEET`, else stub). Single shared load Task (coalesces concurrent
  requests), TDT v3 via `ParakeetBridge.loadBatch`/`transcribeBatch`.
- `OpenWhisp/Services/ParakeetBridge.swift` — the ONLY `import FluidAudio`. Holds
  `loadStreamSession`, the `ParakeetStreamSession` protocol + two adapters, and the
  batch handle.
- Pure core (OpenWhispCore, unit-tested): `ParakeetCatalog` (variant menu, incl.
  `multilingual`/`multilingualChunkMs`), `StreamingRoutePolicy` (parakeet always
  streams for dictation), `ParakeetLanguageGate` (variant-aware refusal),
  `ParakeetLanguageHint` (batch/multilingual code mapping), `ParakeetDownloadState`
  (coarse Models-pane state), `AgentEouAutoStop` (Phase 5 timing), `LanguageResolver`
  (parakeet in the no-translate rule), `ModelStorage` (`.parakeet` kind + labels).
- `AppState`: `makeFileEngine` case `"parakeet"` → `ParakeetFileEngine` (covers
  meetings / queue / watch folders / re-transcribe); `activeStreamingEngine` case
  `"parakeet"` → `ParakeetStreamingEngine`; `parakeetVariant` @Published rebuilds the
  engines; `ensureSelectedEngineModel` / `warmWhisperServerIfPossible` prefetch;
  `installedModelStorage` walks the FluidAudio dir.
- `ModelsPane.parakeetModelSection` (variant picker + download-state badge);
  `AgentBridgePane` (the EOU auto-stop toggle, `#if PARAKEET`).
- Build: `third_party/fluidaudio-dep`, `scripts/build-fluidaudio.sh`,
  `scripts/fluidaudio-link-args.sh`, `PARAKEET=1` → `-D PARAKEET`.

## Feature-matrix coverage

Every app feature routes through a shared seam, so Parakeet inherits them:

- **Refine / voice-edit** — Parakeet is a `StreamingTranscriptionEngine`; its final
  transcript funnels through `handleAppleSpeechFinal`, the same interception site
  Apple Speech and WhisperKit-streaming use. Refine + `VoiceEditRouter` work unchanged.
- **Agent bridge dictate** — agent sessions stream on Parakeet; the engine publishes
  absolute-RMS VAD levels, so the agent silence auto-stop works. Plus the optional
  EOU auto-stop below.
- **Custom vocabulary** — Parakeet has no engine-side prompt biasing, so the
  vocabulary prompt is silently unused (like WhisperKit). Text-side vocabulary /
  SmartFormatter replacements still apply — they run downstream of the engine. (CTC
  keyword boosting is a different FluidAudio model family — a follow-up, not wired.)
- **Stats / history** — recorded as engine `"parakeet"`, model = variant id (dictation)
  or `"parakeet"` (file jobs).
- **Audio retention** — the streaming engine produces no WAV (same as Apple Speech);
  retention paths are already no-WAV-safe.
- **Translate** — suppressed for Parakeet (ASR-only) in `LanguageResolver`; the
  Settings translate toggle is gated off.
- **Meetings** — `meetingTranscriptionConfig` builds via `makeFileEngine`, so the
  meeting state machine (recorded → transcribing → transcribed) runs on the TDT v3
  file engine. FluidAudio resamples any-format WAV internally, so mixed system+mic /
  stereo / non-16 kHz meeting audio needs no pre-resample.

## Phase 5 — EOU auto-stop for agent dictate (experimental, default-off)

Agent-initiated dictation has no human "done" gesture (timeout / silence only). The
Parakeet EOU variant emits end-of-utterance timestamps (`StreamingAsrEouProvider`),
a crisper "the human finished" than an energy-silence run. When
`agentBridgeEouAutoStop` is on AND the EOU variant is selected
(`activeEngineEmitsEou`), an agent session arms `AgentEouAutoStop` alongside the
silence detector: an EOU event arms a settle window, a new partial cancels it, and
the level-tick clock finishes the session once the window elapses. Pure timing in
`AgentEouAutoStop` (unit-tested); inert on every other engine/variant.

## Known limitations / follow-ups

1. **No engine-side vocabulary biasing.** Parakeet has no prompt input; the vocab
   feature only affects text-side replacements. FluidAudio's CTC keyword boosting is
   a separate model family — a possible follow-up.
2. **Utterance-onset clipping** on the streaming Unified tier (drops a leading word at
   onset). The TDT v3 file engine and the multilingual streaming variant do not clip.
3. **No download progress.** FluidAudio exposes no progress callback; the Models pane
   shows a coarse three-state indicator instead of a percentage.
4. **Meeting speaker attribution** uses the existing Me/Them heuristic; Parakeet
   token timestamps could feed diarization, and FluidAudio ships an offline diarizer
   — a follow-up if Parakeet backs meetings with per-speaker labels.
5. **Multilingual detectedLanguage** returned nil for short English utterances in the
   harness (the lang tag isn't always emitted); transcription is unaffected.
6. **Default-on decision** deferred: adding FluidAudio to the default build costs
   static-lib size + clean-build time. Defer until the engines have real mileage.
7. **Multilingual always downloads the full-vocab model.** The bridge passes
   `languageCode: "auto"` to `downloadVariant`, which selects the full 13k-token
   `multilingual` sub-model. FluidAudio also ships a smaller, faster Latin-script
   sub-model (`latin`: en/es/fr/it/pt/de); keying the download on a FIXED app
   language could use it. Deliberate for now — "auto" must work regardless of the
   language setting, and shipping two sub-models per tier doubles the disk story.

## Measured results (harness, M-series, macOS 26, FluidAudio 0.15.5)

Fixture WAVs in `Tests/Fixtures/audio/` through the SPM harness
(`scratchpad/parakeet-harness`, modes `batch` / `multi`).

**Batch TDT v3** (`ParakeetFileEngine` backend), auto language:

```
plain_speech.wav (2.50s)   → "The quick brown fox jumps over the lazy dog."   (conf 0.997, transcribe 0.12s)
numbers_dates.wav (4.03s)  → "Call me at 4 15 on March 3 about the $1,200 invoice."  (conf 0.93, 0.13s)
two_utterances.wav (3.02s) → "First utterance second utterance."               (conf 0.95, 0.20s)
```

Model download+load first time ~86 s (~600 MB); warm reload ~0.2 s. TDT v3 keeps the
leading "The" the streaming Unified tier clips.

**Nemotron multilingual streaming** (`nemotron-multilingual-1120ms`), auto language,
simulated-realtime:

```
plain_speech.wav (2.50s)   → partials at 0.23/0.44/0.65s → "The quick brown fox jumps over the lazy dog"
two_utterances.wav (3.02s) → "First utterance, second utterance"   (finish 0.27s)
```

Model load ~40 s first time (one-time ANE compile; the noisy `E5RT … ANECCompile`
line is that compile, not a failure — models load and transcribe). Downloads
`~/Library/Application Support/FluidAudio/Models/nemotron-multilingual/multilingual/1120ms`.
Kept the leading "The" and added comma punctuation.
