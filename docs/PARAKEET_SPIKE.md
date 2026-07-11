# Parakeet Realtime Engine — MAK-46 spike

> **This is the original feasibility report.** The spike has since been promoted to
> a full integration (streaming + batch file engine, multilingual, model management,
> EOU auto-stop). For the maintainer doc — build flag, models, wiring, language
> matrix, limitations, measured results — see **[PARAKEET.md](PARAKEET.md)**.


**Verdict: feasible, and it delivers the promise.** A true streaming
(transcribe-as-you-speak) local engine built on NVIDIA Parakeet CoreML models
via [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0)
streams partials that trail the voice by ~0.3–0.9 s **with punctuation and
capitalization**, finalizes in ~50 ms, and slots behind the existing
`StreamingTranscriptionEngine` seam with no protocol changes. This is the
"Parakeet Realtime feels categorically snappier" experience superwhisper ships
(their engine is almost certainly the same NVIDIA `parakeet_realtime_eou` /
FluidAudio family — informed inference, not confirmed).

## Measured results (M-series, macOS 26, FluidAudio 0.15.5)

Simulated-realtime harness: fixture WAV fed in 100 ms chunks at live pace to
`StreamingUnifiedAsrManager` (`parakeet-unified-320ms`).

- **Partial cadence:** a new partial every ~250 ms, trailing the audio by
  ~0.5–0.9 s wall-clock (the 0.32 s model latency + decode).
- **Final:** `finish()` returned in **0.05 s** (whisper-family engines pay a
  full batch decode here — this is the categorical difference).
- **Quality:** `plain_speech.wav` → "Quick brown fox jumps over the lazy dog."
  (reference: "The quick brown fox jumps over the lazy dog." — leading "The"
  lost at utterance onset); `numbers_dates.wav` → "Call me at 4:15 on March 3
  about the 1200 invoice." with correct number/date formatting.
- **Model load:** 0.3 s warm; first-ever use downloads ~600 MB from
  HuggingFace (took ~3 min here). Models cache under
  `~/Library/Application Support/FluidAudio/Models/`.
- **EOU 120M comparison** (`parakeet-eou-320ms`): kept the leading "The" that
  Unified clipped but dropped the trailing "dog", emitted no punctuation, and
  its first inference after a cold load stalled ~5 s (CoreML/ANE
  specialization) before partials flowed. Confirms Unified as the right
  default; EOU stays in the menu as the low-footprint option.

## Why FluidAudio (survey summary, July 2026)

- **FluidAudio** — pure-Swift CoreML/ANE, Apache 2.0, active (~weekly
  releases), no transitive SPM deps, macOS 14+. The only OSS path with TRUE
  cache-aware/chunked-attention streaming in Swift. Already the engine inside
  Spokenly, Hex, TypeWhisper. **Chosen.**
- **Argmax ParakeetKit (WhisperKit Pro)** — streaming Parakeet exists but is
  commercial/closed ("argmax-fmod-license", Pro SDK sign-up). Wrong fit for a
  local-first hackable OSS app.
- **parakeet-mlx** — Python only; the Swift MLX port was archived by its own
  authors in favor of CoreML (that work *became* FluidAudio).
- **sherpa-onnx** — ships Parakeet ONNX but explicitly non-streaming for it;
  its true-streaming models are CPU-only Zipformers. Heavier C++ dep.

### Streaming model menu (all on-device, via one `StreamingModelVariant` enum)

| Variant | Latency | WER (test-clean) | Punct/caps | Languages | Size |
|---|---|---|---|---|---|
| `parakeet-unified-320ms` (default) | 0.32 s | 2.37% | **yes** | English | ~600 MB |
| `parakeet-unified-1120ms` | 1.12 s | 2.25% | **yes** | English | same repo |
| `parakeet-eou-320ms` | 0.32 s | ~4.9% | no | English | ~150 MB |
| `nemotron-560ms` … `2240ms` | 0.56–2.24 s | ~2.3% | ? | English (multilingual variant exists, ~40 langs) | ~600 MB |
| (contrast) Parakeet TDT v3 | sliding-window pseudo-streaming | 2.6% batch | no | 25 European | ~600 MB |

The streaming/multilingual/punctuation triangle: **no single model gives all
three.** The spike ships the Unified English tiers (streaming + punctuation);
multilingual streaming (Nemotron multilingual) and TDT v3 batch (25 languages,
also a `FileTranscriptionEngine` candidate) are follow-ups.

## What the spike built

- `third_party/fluidaudio-dep/` — SwiftPM helper package (mirrors
  `whisperkit-dep`) pinned **exact 0.15.5** (pre-1.0 API churn is real; bump
  deliberately and re-test).
- `scripts/build-fluidaudio.sh` + `scripts/fluidaudio-link-args.sh` — build +
  link plumbing, spliced into `build.sh`/`build-dmg.sh`. OFF by default at
  spike time (`PARAKEET=1` opted in); the flag has since flipped to **ON by
  default** — see docs/PARAKEET.md. A lean `PARAKEET=0` build keeps the stub
  engine and hides the Settings row.
- `OpenWhisp/Services/ParakeetStreamingEngine.swift` — conforms to
  `StreamingTranscriptionEngine` (the Apple Speech seam; no protocol changes).
  Owns the mic via its own `AVAudioEngine` tap; buffers flow tap →
  `AsyncStream` (ordered) → FluidAudio's actor manager; partials hop to the
  main actor behind a generation gate; `SerialTaskChain` serializes start/stop
  (all patterns lifted from AppleSpeech/WhisperKitStreaming engines). Real impl
  under `#if PARAKEET`, stub otherwise.
- `OpenWhisp/Services/ParakeetBridge.swift` — the only `import FluidAudio`.
- Pure core (unit-tested, `ParakeetSpikeTests`):
  - `ParakeetCatalog` — variant menu + stale-id normalization.
  - `StreamingRoutePolicy` — extracted the startDictation streaming-vs-file
    gate (parakeet/appleSpeech always stream; whisperKit only in live modes)
    and the Speech-authorization rule.
  - `ParakeetLanguageGate` — refuses a FIXED non-English dictation language up
    front (never silently mangle non-English speech; "auto" is allowed and
    documented as English-only).
  - `LanguageResolver` — parakeet added to the no-translate rule (ASR-only),
    single source of truth `supportsTranslation` also gates the Settings
    translate toggle.
- AppState wiring: `parakeet` engine value → `activeStreamingEngine` switch,
  session routing via `StreamingRoutePolicy`, `parakeetVariant` setting
  (rebuilds engine on change), warm/provision paths call `prefetch()` (kicks
  the model download at engine-select time, not mid-first-dictation).
- Settings → Models: Parakeet row (only in `PARAKEET` builds, "Experimental")
  + variant picker.

## How to try it

```bash
./build.sh                     # Parakeet is included by default (PARAKEET=0 for a lean build)
# run the app → Settings → Models → "Parakeet Realtime (CoreML)"
# first selection downloads ~600 MB in the background; then dictate
```

Output modes: all of them stream (preview / live typing / clipboard); Parakeet
never uses the file path — same routing as Apple Speech.

## Known limitations / follow-ups (if promoted from spike)

1. **English-only** in this spike. Next: FluidAudio's Nemotron streaming
   *multilingual* manager (~40 langs incl. RU) — different manager type, needs
   a catalog + bridge extension and quality eval (punctuation unverified).
2. **No download progress UI** — FluidAudio stages models itself; the Models
   pane just says "downloads on first use". Wants: progress row (FluidAudio
   has no progress callback today), staged/installed state, and a
   `ModelStorage` entry so the ~600 MB shows in disk usage + can be deleted.
3. **Leading-word clipping** at utterance onset (lost "The" on the first
   fixture) — evaluate priming the stream with ~0.5 s of silence, or the
   1120 ms tier for quality-sensitive users.
4. **VAD levels**: the engine publishes absolute-RMS levels (good for the
   agent silence auto-stop), but does no VAD gating of its own — silence is
   fed to the model (cheap: it emits nothing). Fine for dictation sessions.
5. **E2E test tier**: add `scripts/e2e-parakeet.sh` mirroring
   `e2e-whisperkit.sh` (real engine over fixtures; app-only, since the engine
   is behind the app-glob `#if PARAKEET`). The pure logic is covered by
   `swift test` (`ParakeetSpikeTests`); the live-path plumbing
   (partials → delta paste) is the shared streaming path already exercised by
   the Apple Speech tests.
6. **Word timestamps** for Meeting mode speaker attribution: streaming
   managers expose per-token ms timestamps (`StreamingAsrTokenTimestampProvider`)
   — needs client-side word aggregation if Parakeet should ever back meetings.
7. **Default-on decision**: adding FluidAudio to the default build costs ~30 MB
   of static lib and ~100 s of clean-build time (cached after). Defer until the
   engine has real-world mileage.

## How it's wired (for maintainers)

- `ParakeetStreamingEngine` (app-only) — the engine; `ParakeetBridge` — the
  FluidAudio import boundary; both `#if PARAKEET`.
- `ParakeetCatalog` / `StreamingRoutePolicy` / `ParakeetLanguageGate` — core,
  tested in `Tests/OpenWhispCoreTests/ParakeetSpikeTests.swift`.
- `AppState`: `activeStreamingEngine`, `startDictation` routing,
  `parakeetVariant` @Published, `ensureSelectedEngineModel` /
  `warmWhisperServerIfPossible` `case "parakeet"` → `prefetch()`.
- `ModelsPane.parakeetModelSection` + the engine row (`#if PARAKEET`).
- Build: `third_party/fluidaudio-dep`, `scripts/build-fluidaudio.sh`,
  `scripts/fluidaudio-link-args.sh`, `PARAKEET` env (default 1) → `-D PARAKEET`.
