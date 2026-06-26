# WhisperKit Backend — Pilot

> An **experimental** second file-transcription backend: [WhisperKit](https://github.com/argmaxinc/WhisperKit)
> (Argmax, MIT) — a Swift-native CoreML/ANE Whisper runtime. It conforms to the
> same `FileTranscriptionEngine` protocol as the whisper.cpp engine, so it slots
> into the existing pipeline unchanged. This pilot does **file transcription only**
> (WAV → text); true streaming partials are a later step. See the
> [ASR alternatives study](ASR_ALTERNATIVES.md) for why WhisperKit was chosen.

## Why it's opt-in at build time

The app is compiled by `build.sh` with a raw `swiftc` glob (no SwiftPM dependency
resolution for the app — SwiftPM can't produce a signed `.app`). WhisperKit is a
SwiftPM package, so it's linked **only when you ask for it**:

- **Default build** (`./build.sh`): WhisperKit is *not* linked. `WhisperKitEngine`
  compiles to a stub that reports "not available" if selected. Zero impact.
- **WhisperKit build** (`WHISPERKIT=1 ./build.sh`): builds WhisperKit (and its
  whole dependency tree) into a single static lib, links it, and defines the
  `WHISPERKIT` compile flag that activates the real engine.

## Build & run with WhisperKit

```bash
# One-time (or after changing the WhisperKit version): builds the dependency.
# build.sh calls this automatically, but you can run it standalone to pre-warm:
./scripts/build-whisperkit.sh >/dev/null

# Build the app WITH the WhisperKit backend, then package + install:
WHISPERKIT=1 ./build.sh && ./package.sh --install
```

The first WhisperKit dependency build takes ~1 minute (compiles WhisperKit +
swift-transformers + crypto + collections, etc.). Subsequent builds are
incremental.

## A/B testing the two backends

1. Launch OpenWhisp (built with `WHISPERKIT=1`).
2. **Settings → Advanced → Engine → Transcription Engine.** You'll see:
   - **Whisper Local (whisper.cpp)** — the default, unchanged.
   - **WhisperKit (CoreML, experimental)** — the pilot.
   - **Apple Speech Streaming** — the existing native option.
3. Switch between **Whisper Local** and **WhisperKit** and dictate the same phrases.
   Switching rebuilds the engine live (no app restart). WhisperKit auto-downloads
   its model (`large-v3-turbo`) on first use — the first transcription will be slow
   while it downloads/loads; watch the status line.

Compare: accuracy (incl. Russian), speed, and how each handles `--translate`
(set Language → "English — Whisper translate to English" and dictate Russian).

## Known limitations of this pilot

- **File transcription only** — no true streaming partials yet (that's the next
  step; WhisperKit supports it via LocalAgreement).
- **Custom vocabulary prompt is not wired** for WhisperKit. WhisperKit biases via
  `promptTokens: [Int]?` (token IDs), not a plain string, so the vocabulary
  feature only affects the whisper.cpp backend in this pilot.
- **A WhisperKit build is not signed/distributable as-is via CI** — the release
  workflow builds the default (whisper.cpp) app. This is a local experiment.
- Model files download to WhisperKit's own cache (HuggingFace), separate from the
  whisper.cpp GGML models in Application Support.

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
