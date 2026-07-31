# WhisperKit Backend — Pilot

> An **experimental** second transcription backend: [WhisperKit](https://github.com/argmaxinc/WhisperKit)
> (Argmax, MIT) — a Swift-native CoreML/ANE Whisper runtime. It supports both
> **file transcription** (conforming to `FileTranscriptionEngine`) and **real-time
> streaming** (conforming to `StreamingTranscriptionEngine`, the same seam Apple
> Speech uses). In a live output mode (Preview / Paste-at-end) it streams partials
> with built-in silence skipping; otherwise it transcribes the whole recording.
> See the [ASR alternatives study](ASR_ALTERNATIVES.md) for why WhisperKit was chosen.

## Streaming (real-time)

`WhisperKitStreamingEngine` wraps WhisperKit's `AudioStreamTranscriber`, which owns
the mic and runs its own energy VAD (silence is skipped, not transcribed). It plugs
into the same session machinery as Apple Speech: live partials drive the overlay
preview, and the full transcript is pasted on release. Key decode settings
(`WhisperKitBridge.makeStreamHandle`):

- `skipSpecialTokens: true` — streaming segment text is the raw token stream
  otherwise (`<|startoftranscript|>…`). `withoutTimestamps` MUST stay `false`
  (`WhisperKitStreamingDecodePolicy.withoutTimestamps`): timestamp tokens are what
  let segments split and confirm, advancing the decode window — suppressing them
  truncated every dictation at 30 s (fixed in #222).
- `detectLanguage: true` for the "auto" case — WhisperKit's prefill otherwise forces
  English, so Russian came out translated. Explicit-language / translate skip this.

The engine emits the FULL current transcript (confirmed + the revised tail) as the
partial: WhisperKit only "confirms" segments after several accumulate, so a short
utterance would otherwise show nothing until stop.

## Settings are backend-aware

The Settings UI hides options that don't apply to the active backend (state is
preserved, so switching back restores it). whisper.cpp shows GGML quality tiers,
the model path, the CLI/server backend, and live-chunk tuning; WhisperKit shows a
picker of locally-staged CoreML models (`WhisperKitModelCatalog` lists only loadable
ones) and omits the "Type live" output mode; Apple Speech shows neither model
controls nor whisper.cpp plumbing. The selected WhisperKit model is persisted as
`whisperKitModel` and changing it rebuilds the WhisperKit engines.

## Build flag (on by default)

The app is compiled by `build.sh`/`build-dmg.sh` with a raw `swiftc` glob (no
SwiftPM dependency resolution for the app — SwiftPM can't produce a signed
`.app`). WhisperKit is a SwiftPM package, linked via the `WHISPERKIT` build flag.
WhisperKit is now the **default transcription engine**, so the flag is **ON by
default** — both compile paths share the same link logic (`scripts/whisperkit-link-args.sh`):

- **Default build** (`./build.sh`, `./build-dmg.sh`): builds WhisperKit (and its
  whole dependency tree) into a single static lib, links it, defines the
  `WHISPERKIT` compile flag that activates the real engine, and the app defaults
  `transcriptionEngine` to `whisperKit`.
- **Lean build** (`WHISPERKIT=0 ./build.sh`): WhisperKit is *not* linked.
  `WhisperKitEngine` compiles to a stub that reports "not available" if selected,
  and the default engine falls back to whisper.cpp (compile-time
  `AppState.defaultTranscriptionEngine`). Use this to avoid the CoreML dependency.

## Build & run

```bash
# One-time (or after changing the WhisperKit version): builds the dependency.
# build.sh calls this automatically, but you can run it standalone to pre-warm:
./scripts/build-whisperkit.sh >/dev/null

# Standard build + package + install (WhisperKit is included by default):
./build.sh && ./package.sh --install

# Lean build without WhisperKit:
WHISPERKIT=0 ./build.sh && ./package.sh --install
```

The first WhisperKit dependency build takes ~1 minute (compiles WhisperKit +
swift-transformers + crypto + collections, etc.). Subsequent builds are
incremental.

## Measuring load time (developer instrumentation)

Timing instrumentation is **off in consumer builds** and gated behind a build flag,
so the shipped app contains none of it. To measure where startup/first-dictation
latency goes (chiefly the CoreML specialization of the audio encoder):

```bash
INSTRUMENTATION=1 ./build.sh && ./package.sh --install
```

This defines `OPENWHISP_INSTRUMENTATION`, compiling in `Instrumentation` (see
`OpenWhisp/Services/Instrumentation.swift`). It emits, per measured span:
- an **`os_signpost` interval** under subsystem `com.openwhisp.app`, category
  `instrumentation` — view in **Console.app** (filter the subsystem) or
  **Instruments → os_signpost**; and
- a console line `[instr] <label>: <ms>ms` (read via Console.app or by launching the
  binary from Terminal).

Spans today: `whisperkit.warm` (warm start → model ready), `whisperkit.load.staged`
and `whisperkit.load.download` (the WhisperKit constructor / specialization cost).
To answer "is the slow load a one-time specialization or every launch?": compare
`whisperkit.load.staged` on the **first launch after install** vs a **second launch**
(a respecialization makes the first much larger; OS CoreML caching should make the
second small).

Build without the flag (the default) and the instrumentation compiles to no-ops.

## A/B testing the two backends

1. Launch OpenWhisp (a default build includes WhisperKit).
2. **Settings → Advanced → Engine → Transcription Engine.** You'll see:
   - **WhisperKit (CoreML)** — the default.
   - **Whisper Local (whisper.cpp)** — the original local engine.
   - **Apple Speech Streaming** — the existing native option.
3. Switch between **Whisper Local** and **WhisperKit** and dictate the same phrases.
   Switching rebuilds the engine live (no app restart) and warms **only** the
   selected backend, so the two never load models at the same time. WhisperKit
   loads its default model (`openai_whisper-small`, multilingual) from a locally
   staged folder (see below); the first load is a one-time CoreML compile — watch
   the status line ("Preparing WhisperKit model…" → "WhisperKit ready").

Compare: accuracy (incl. Russian), speed, and how each handles `--translate`
(set Language → "English — Whisper translate to English" and dictate Russian).

## The model: locally staged, GPU encoder

WhisperKit loads its model from a staged folder of compiled sub-models at:

```
~/Library/Application Support/OpenWhisp/whisperkit-models/<model>/
  ├── AudioEncoder.mlmodelc
  ├── MelSpectrogram.mlmodelc
  ├── TextDecoder.mlmodelc
  ├── config.json
  └── generation_config.json
```

`WhisperKitBridge.load()` points WhisperKit at this folder via `modelFolder`. (No
`Manifest.json` is needed on this path — `tiny.en` loads with none present.)

**Compute units matter — this is the fix for the "WhisperKit gets stuck" bug.**
WhisperKit defaults the audio encoder to the Apple Neural Engine
(`.cpuAndNeuralEngine`). On macOS 26 / Apple Silicon, the one-time on-device ANE
*specialization* of a non-tiny encoder (e.g. `small`'s ~176 MB encoder) can stall
indefinitely — the load never returns, no "model loaded" ever logs, and the ANE
bundle cache (`~/Library/Caches/com.apple.e5rt.e5bundlecache`) never grows. We
therefore pin the audio encoder to the **GPU** (`.cpuAndGPU`) in
`WhisperKitBridge.load()`; it loads in seconds. The (small) text decoder keeps its
ANE default. If the GPU path ever misbehaves, `.cpuOnly` is the robust fallback.

`large-v3-turbo` can be staged and selected too, but its encoder is ~7× larger and
its first-load specialization is slow and memory-heavy enough to be impractical on
a 16 GB Mac — `small` is the default for that reason.

## Known limitations of this pilot

- ~~**File transcription only**~~ — streaming partials shipped since
  (`WhisperKitStreamingEngine` / `AudioStreamTranscriber`); this pilot doc predates
  them. Streaming latency is governed by the confirmation lag — see
  `WhisperKitStreamingDecodePolicy.requiredSegmentsForConfirmation(translate:)`.
- **Custom vocabulary prompt is not wired** for WhisperKit. WhisperKit biases via
  `promptTokens: [Int]?` (token IDs), not a plain string, so the vocabulary
  feature only affects the whisper.cpp backend in this pilot.
- **Models download in-app.** Settings → (WhisperKit) Quality lists the selectable
  models with a **Download** button each; downloads come from Argmax's
  `argmaxinc/whisperkit-coreml` repo via WhisperKit's own `download(…)` API, staged
  into `~/Library/Application Support/OpenWhisp/whisperkit-models/<model>` (the flat
  layout the catalog/installer expect). A download is validated (the three required
  `.mlmodelc` are present) before it's moved into place. Manual staging still works
  for models not in the curated list.
- **Audio encoder runs on the GPU, not the ANE** (see above) to avoid the macOS 26
  ANE-specialization stall. This is a deliberate trade-off, not a perf bug.

## How it's wired (for maintainers)

- `OpenWhisp/Services/WhisperKitEngine.swift` — conforms to `FileTranscriptionEngine`;
  real impl under `#if WHISPERKIT`, stub otherwise.
- `OpenWhisp/Services/WhisperKitBridge.swift` — the only file that `import`s
  WhisperKit (under `#if WHISPERKIT`). The pure `WhisperKitTaskMapper` (language →
  transcribe/translate) lives here and is unit-tested.
- `AppState.makeFileEngine(for:model:)` picks the engine from the
  `transcriptionEngine` setting; `rebuildFileEngine()` swaps it live and re-wires
  the (protocol-only) callbacks via `wireFileEngineCallbacks()`.
- `third_party/whisperkit-dep/` — a tiny SwiftPM package whose only job is to build
  WhisperKit as one static lib. `scripts/build-whisperkit.sh` builds it and emits
  the link flags `build.sh` consumes.
