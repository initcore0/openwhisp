# E2E Audio Testing Plan

**Goal:** regression-test every shipped feature by feeding pre-recorded audio through the full pipeline — capture → chunking/VAD → transcription → voice actions/formatting → post-processing → output/history/bridge — without a human speaking into a microphone.

**Status:** implemented (2026-07-08), Tiers 1–2 + the Phase-B feature matrix.
Everything deterministic runs in the plain `swift test` CI job; the real-engine and
BlackHole checks are scripted for local/nightly. See **Implementation status** below,
and **[How to add a test for a new feature](#how-to-add-a-test-for-a-new-feature)**
before shipping the next feature.

---

## Implementation status (2026-07-08)

**Tier 1 — in-process fixture replay (branch `feat/e2e-audio-testing`):**

- **Fixtures** — `Tests/Fixtures/audio/` holds 5 checked-in 16 kHz mono 16-bit WAVs
  (plain speech, numbers/dates, speech+silence tail, two-utterance pause split,
  pure silence), each with an expected-transcript `.txt`. Regenerate with
  `scripts/gen-audio-fixtures.sh` (`say` + `afconvert`, pinned voice/rate;
  `--check` is a format-drift guard). Checked in — not from the whisper.cpp
  submodule, which CI doesn't fetch.
- **`FileAudioCapture`** ([FileAudioCapture.swift](../OpenWhisp/Services/FileAudioCapture.swift), in
  `OpenWhispCore`) — a Foundation-only fixture-replaying `AudioCapture` that
  reproduces `AudioRecorder`'s RMS + pause-based VAD and writes real chunk WAVs.
  Ships with a tiny `WAVFile` RIFF reader/writer so no AVFoundation leaks into
  core. Unit-tested in `Tests/OpenWhispCoreTests/FileAudioCaptureTests.swift`.
- **Core pipeline suite** — `Tests/OpenWhispCoreTests/AudioPipelineE2ETests.swift`
  drives fixtures through the real `LiveChunkPipeline` + `TranscriptCleaner` +
  spy `TextOutput` + history, with a `ScriptedFileEngine` (canned text) for
  deterministic, exact assertions. Runs in the **existing** `ci.yml` `swift test`
  job — no CI changes needed.

**Phase B — feature matrix (branch `feat/e2e-phase-b-feature-matrix`):**

- **Resolvers extracted to core** — the thin app-only session-setting decision
  logic is now pure and testable: [`LanguageResolver`](../OpenWhisp/Services/LanguageResolver.swift)
  (translate/auto/appleSpeech matrix) and [`ProfileResolver`](../OpenWhisp/Services/ProfileResolver.swift)
  (per-app-profile `"en"`→translate remap + inherit/override). `AppState` delegates
  to both; `ResolverTests.swift` covers them.
- **AppState DI seam widened** — `AppState.init` now accepts `audioCapture:` and
  `fileEngine:` (defaults keep the `.shared` singleton unchanged), so a future
  full-app harness can inject `FileAudioCapture` + a scripted engine.
- **Feature-matrix suite** — `Tests/OpenWhispCoreTests/FeatureMatrixE2ETests.swift`
  (41 tests) drives fixture audio through each shipped feature: **script
  post-processor** (real `/bin/sh` via `Process` → `ScriptPostProcessor`), **LLM
  refine** (`RefineFlow` state machine + stub LLM), **output + SecureFieldPolicy**,
  **agent bridge** (`BridgeRouter` dictate routing + `AgentRateLimiter`), and
  **multilingual/profiles** (resolver-driven behavior differences). All in the fast
  core CI job.

**Tier 2 — reality check (local/nightly, non-blocking):**

- `scripts/e2e-smoke.sh` (BlackHole virtual-mic; sets the **system default** input
  to BlackHole and drives the app via `openwhisp dictate`) and
  `scripts/e2e-whisperkit.sh` + `scripts/e2e/whisperkit-harness.swift` (compiles a
  harness linked against the real WhisperKit engine; auto-picks a staged model to
  run offline). The WhisperKit runner is wired nightly via
  `.github/workflows/e2e-nightly.yml`.
- **Live app-feature tests** — `scripts/e2e-app-features.sh` drives the **running
  app** through its `openwhisp` CLI (the agent bridge) and asserts the text
  features end-to-end against the **real LLM / real app state**, which `swift test`
  can't (it stubs the LLM). Covers **refine** (rephrase / grammar / translate /
  no-op passthrough / stdin / `--json`), `status`, and `history`. This is the
  "give it text + an instruction and confirm the output actually changed" test.
  Requires the app running with an LLM configured (`openwhisp status` →
  `llm=configured`); refine cases skip (not fail) without one.

**Still deferred:** a full-app raw-swiftc harness that links `AppState` itself
(compiles the 4368-line `@MainActor` class + ~40 deps) — most feature *logic* is
already core-testable via the extracted resolvers + state machines, so this is only
needed if a future feature's behavior lives *entirely* in AppState's async session
glue and can't be extracted. See **[How to add a test for a new feature](#how-to-add-a-test-for-a-new-feature)**.

---

## How to add a test for a new feature

When you ship a feature that touches the dictation pipeline, add its regression
test here so it's covered by fixture audio. Follow the seam it lives on:

**1. Is the feature's logic pure (or extractable)?** Prefer this — it's the fast
`swift test` path.
- If the logic is already in a Foundation-only type in `OpenWhispCore` (a formatter,
  a state machine, a resolver, a policy), test it directly, and add an **integration**
  test in `FeatureMatrixE2ETests.swift` that drives it *from fixture audio* through
  `LiveChunkDriver` so it's proven to compose, not just work in isolation.
- If the logic is inline on `AppState` (like `applyProfileForFrontmostApp` was),
  **extract the decision logic into a pure core type first** (as `ProfileResolver` /
  `LanguageResolver` did — take inputs, return the resolved result; leave the
  effectful parts on AppState), then test the resolver. This is the same move that
  split `SecureFieldPolicy` out of `SecureFieldDetector`. It keeps `AppState` and the
  tests from drifting and avoids the AppState-linking tax.

**2. Write the integration test.** In `FeatureMatrixE2ETests.swift`, reuse the shared
doubles (do **not** redefine them):

| Helper | What it does |
|---|---|
| `FileAudioCaptureTests.fixture("name.wav")` | Resolves a checked-in fixture URL. |
| `FileAudioCapture(fixtureURL:outputDirectory:)` | Replays a fixture through the real `AudioCapture` contract (chunking + VAD). |
| `ScriptedFileEngine(constant:)` / `(byOrdinal:completionOrder:)` | A `FileTranscriptionEngine` returning canned text per chunk — deterministic, exact. |
| `SpyTextOutput` | A `TextOutput` recording `.insertions` / `.clipboardWrites`. |
| `LiveChunkDriver(fixture:engine:output:outputDir:chunkDuration:mode:cleanerConfig:finalTranscript:maxConcurrent:)` | Wires `FileAudioCapture → LiveChunkPipeline → engine → TranscriptCleaner → SpyTextOutput → TranscriptionEntry`; exposes `.chunkCount`, `.errors`, `.historyEntries`. |

Pattern: construct a temp `outputDir`, drive a fixture with a `ScriptedFileEngine`
returning text that exercises your feature, run the driver, and assert on
`output.insertions` / `driver.historyEntries` / your feature's observable effect.
Keep assertions **fuzzy** for anything a real engine would produce (WER/containment,
never exact) — but a scripted engine's text flowing through formatting can be exact.

**3. Need a new fixture?** Add a clip + expected `.txt` to `scripts/gen-audio-fixtures.sh`
(spoken text that triggers your feature — a voice command, a number, a non-English
phrase), run it, and check the `.wav`/`.txt` in. Re-run `./scripts/gen-audio-fixtures.sh --check`
to confirm format.

**4. Real-engine / real-capture / real-LLM coverage (optional).** If the feature only
matters with the *real* engine, the *real* mic, or the *real* LLM, add a case to the
matching Tier-2 script (nightly/local, not blocking CI):
- real transcription engine → `scripts/e2e-whisperkit.sh`
- real microphone capture → `scripts/e2e-smoke.sh` (BlackHole)
- **real LLM / any agent-bridge verb (refine, status, history)** → `scripts/e2e-app-features.sh`,
  which drives the running app via the `openwhisp` CLI and asserts the real output.
  This is the place for "the app produced genuinely different/correct text" checks.

**Rule of thumb:** every pipeline feature gets at least one `FeatureMatrixE2ETests`
case driven from a fixture. If you find yourself unable to write one without linking
`AppState`, that's the signal to extract the logic into core first.

---

## TL;DR

Two tiers, built in this order:

1. **Tier 1 — in-process fake audio source (the workhorse).** Inject a `FileAudioCapture` behind the existing `AudioCapture` protocol and run the *real* transcription engines on fixture WAVs. Deterministic, no TCC prompts, no drivers, runs in plain CI. Covers ~95% of the pipeline. This is where "test every feature" lives.
2. **Tier 2 — BlackHole virtual-mic smoke test (the reality check).** Install BlackHole, point OpenWhisp's input-device setting at it by UID, play a fixture into it with ffmpeg, drive a session via `openwhisp dictate`. Covers the last 5%: real CoreAudio/AVAudioEngine capture, device enumeration, TCC. A handful of tests, tolerant of flake, run nightly/pre-release.

**Do not build a custom CoreAudio driver.** Apple's NullAudio sample + libASPL make it feasible, but it's ongoing driver maintenance for marginal gain over BlackHole. CMIOExtensions are camera-only — not a path for virtual mics. There is no public API to make `AVAudioEngine.inputNode` emit fake data, so the seam must sit above the engine — which we already have.

---

## Why this split works: the seams we already have

The Phase 2.5 core extraction left exactly the right injection points:

- **`AudioCapture` protocol** ([AudioCapture.swift](../OpenWhisp/Services/AudioCapture.swift)) — `start()`, `startStreaming(chunkDuration:onChunk:)`, `startStreamingOnSilence(...)`, `stop(completion:)`, `selectDevice(_:)`, `onStateChanged`/`onLevelChanged`. `AudioRecorder` is the only conformer; `AppState` holds it as the protocol type (`AppState.swift:565`, wired at `:1073`).
- **`FileTranscriptionEngine` protocol** ([TranscriptionEngine.swift](../OpenWhisp/Services/TranscriptionEngine.swift)) — already file-fed by design: hand it a WAV path, get text. Both `WhisperEngine` (whisper.cpp) and `WhisperKitEngine` conform. So a fake *capture* layer that emits real WAV chunks exercises the **real** engines.
- **Input device is user-selectable by UID** — `AppState.microphoneID` (UserDefaults `"microphoneID"`), picker in `DictationPane.swift:37`, applied via `recorder.selectDevice(micID)` at session start. This is what makes Tier 2 possible with **zero code changes**.
- **A `FakeAudioCapture` already exists** in `Tests/OpenWhispCoreTests/AudioCaptureTests.swift` — it records calls but emits no audio. Tier 1 is essentially "make it emit real audio."
- **Fixtures on hand:** `third_party/whisper.cpp/samples/jfk.wav` / `jfk.mp3`.

---

## Tier 1 — In-process fake audio source

### Design

Build `FileAudioCapture: AudioCapture` that replays a fixture:

- Reads a WAV (16 kHz / mono / 16-bit — Whisper's native format, so in-app SRC is a no-op).
- For `startStreaming(chunkDuration:onChunk:)`: slices the file into chunk-duration WAV files and delivers them through `onChunk` on a timer (configurable: real-time pacing for timing-sensitive tests, "as fast as possible" for throughput).
- For `startStreamingOnSilence`: fixtures contain embedded silence gaps; the fake computes RMS per buffer the same way `AudioRecorder` does, so VAD/auto-stop logic runs for real. Emits realistic `onLevelChanged` values from actual sample RMS.
- For legacy `start()`/`stop(completion:)`: returns the whole fixture as one WAV.
- Fires `onStateChanged` transitions identically to `AudioRecorder`.

This sits *above* AVAudioEngine, so nothing OS-level is faked — chunk pipeline, VAD math, streaming finalization, WhisperKit/whisper.cpp transcription, formatting, voice actions, refine, history, and output all run their production code.

### Prerequisite: a testable AppState

The blocker today: `AppState` is AppKit/SwiftUI and not in the SwiftPM `OpenWhispCore` target, and `swift test` only covers the core. Two-step fix:

1. **Constructor injection.** Extend the existing DI initializer (`AppState.swift:864` already injects `secretStore`/`launchAtLoginService`/`textOutput`) with `audioCapture: AudioCapture = AudioRecorder()` and optionally the engines; `wireUpServices()` uses the injected instance instead of constructing one.
2. **A new integration-test target that links AppKit**, built/run via `xcodebuild test` (or a dedicated `swift test` target that can import the app sources). `build.sh` gains a `test-e2e` mode; CI gets a separate job. Where AppState is too entangled, prefer extracting the session orchestration into core (continuing Phase 2.5) over duplicating logic in tests.

Pragmatic interim: many flows (`LiveChunkPipeline`, `DictationSession`, `BridgeRouter`) are already in core — a `FileAudioCapture` placed in `OpenWhispCore` can drive those *today* with real WhisperKit via the existing engine protocols, before AppState DI lands.

### Feature-coverage matrix (the regression suite)

| Feature | How it's tested with fixture audio |
|---|---|
| Streaming transcription | jfk.wav through `FileAudioCapture` → `LiveChunkPipeline` → real engine; assert normalized transcript |
| Silence auto-stop / VAD | fixture with speech + 2s silence tail; assert session auto-finalizes |
| Both engines | same fixture through `WhisperKitEngine` and `WhisperEngine` (cli + serverAPI backends) |
| Voice actions | fixtures speaking "new line", "delete that", pack-defined actions; assert `MetaInstructionStripper`/`InstructionChain` output |
| Smart formatting / vocabulary | fixtures with numbers, punctuation commands, custom vocab terms |
| Script post-processor | fixture → transcript → known shell script; assert transformed output |
| LLM refine | fixture → `RefineFlow` with a stub/local llama server; assert refine invoked with the right transcript |
| History | run N sessions; assert `TranscriptionHistory` entries |
| Output path | inject fake `TextOutput` (protocol exists); assert inserted text + `SecureFieldPolicy` blocks password fields |
| Agent bridge / MCP | `openwhisp dictate` against a test AppState using `FileAudioCapture`; assert CLI receives transcript; rate limiting; **regression for TTS↔mic feedback** (fixture = TTS audio, assert gated) |
| Settings/profiles | run same fixture under different profiles/config packs; assert behavior differences |
| Multilingual | non-English fixtures; assert language handling / translation service invocation |

### Fixtures

- Record a small curated set (10–20 clips) as **16 kHz mono WAV**, checked into `Tests/Fixtures/audio/` (or Git LFS if large): plain speech, speech+voice-commands, speech+silence gaps, numbers/dates, non-English, noisy speech (mixed via sox at fixed SNR).
- Generation is scriptable: `say -o` + sox resample, or record once by hand. Each fixture pairs with an expected-transcript `.txt`.
- MP3 is fine as a source of truth, but decode to WAV at build time — feed the pipeline WAV to keep decode variance out.

### Determinism policy (important)

Whisper is deterministic per (model, binary, hardware) at temperature 0 / greedy decode, but ANE/GPU float non-associativity means transcripts can differ **across machines and OS versions**, and the temperature-fallback ladder reintroduces randomness. Therefore:

- Pin decoding: temperature 0, fallback count 0, fixed model version per CI image.
- Assert with **normalized fuzzy matching** (lowercase, strip punctuation, WER threshold ≤ ~5% or key-phrase containment), never exact string equality.
- For logic-focused tests (voice actions, refine, output), optionally add a `ScriptedTranscriptionEngine` fake that returns canned text — fast and exact — keeping real-engine runs for the transcription-accuracy suite.

---

## Tier 2 — BlackHole virtual-mic smoke test

Black-box test of the real capture stack. Recipe (works headlessly; BlackHole is a signed user-space AudioServerPlugIn, no kext, no reboot):

```bash
brew install blackhole-2ch switchaudio-osx ffmpeg
sudo killall coreaudiod           # 'launchctl kickstart' is blocked on macOS 14+
# poll until device appears: system_profiler SPAudioDataType | grep BlackHole
SwitchAudioSource -t input -s "BlackHole 2ch"   # or set OpenWhisp microphoneID to its UID
# set BlackHole nominal rate to 16 kHz to avoid double SRC (or use a 48 kHz fixture)
# play fixture in real time into BlackHole (afplay can't pick a device; ffmpeg can):
ffmpeg -re -i fixture.wav -f audiotoolbox -audio_device_index <N> -
```

Test flow: launch the packaged app → write `microphoneID` = BlackHole UID into UserDefaults → start a session via the agent bridge (`openwhisp dictate` blocks until done — perfect harness) → start ffmpeg playback with ~0.5 s leading silence → fixture ends in silence so **silence auto-stop finishes the session** → assert transcript from the CLI.

**TCC:** mic permission must be pre-seeded. On CI, `sqlite3` INSERT of `kTCCServiceMicrophone` (`auth_value=2`) into the user `~/Library/.../TCC.db` — works on GitHub Actions (runner has FDA); schema varies by macOS version, and unsigned dev builds are the forgiving case (csreq NULL). On a local dev Mac, grant once by hand.

**Where it runs:** primary target is a local/self-hosted Mac (nightly or pre-release, e.g. `./scripts/e2e-smoke.sh`). GH Actions is possible but known-fragile — the BlackHole cask has a standing issue on runner images ([runner-images#11746](https://github.com/actions/runner-images/issues/11746)); the killall-coreaudiod workaround usually recovers it. Mark the CI job non-blocking.

**Scope:** ~3–5 tests only — device enumeration shows BlackHole, dictate-through-virtual-mic produces the expected transcript, device selection by UID sticks, TTS-during-capture feedback check. Everything else belongs in Tier 1.

---

## Build plan (phased)

**Phase A — foundations (biggest value, no app restructuring): ✅ DONE**
1. ✅ Fixture set + expected transcripts in `Tests/Fixtures/audio/`, with a generation script.
2. ✅ `FileAudioCapture` in `OpenWhispCore` (promoted/extended the existing `FakeAudioCapture`).
3. ✅ Core-level pipeline tests: `FileAudioCapture` → `LiveChunkPipeline` → engine → assert transcripts. Silence-auto-stop + ordering covered. (Real `WhisperKitEngine` runs via the nightly `scripts/e2e-whisperkit.sh` rather than in `swift test`, since it's app-target-only behind `-D WHISPERKIT`.)
4. ✅ CI: the existing `swift test` job on macos-14 covers Tiers 1 + the Phase-B matrix.

**Phase B — feature matrix: ✅ DONE (approach revised)**
5. ✅ Constructor injection of `AudioCapture` (+ engine) into `AppState`. **Revised:** rather than a new AppKit-linked `xcodebuild test` lane (high friction — no `.xcodeproj` exists), the thin app-only decision logic was **extracted into pure core resolvers** (`LanguageResolver`, `ProfileResolver`) — continuing Phase 2.5 — so the feature matrix is `swift test`-able without linking AppState. A full raw-swiftc AppState harness remains available if a future feature's behavior can't be extracted.
6. ✅ Feature-matrix suite (`FeatureMatrixE2ETests.swift`, 41 tests): script post-processor, refine, output/SecureFieldPolicy, agent-bridge routing + rate limiting, multilingual/profiles — all driven from fixture audio.

**Phase C — real-hardware smoke: ✅ DONE**
7. ✅ `scripts/e2e-smoke.sh` implementing the BlackHole recipe (routes via the **system default input** so OpenWhisp captures BlackHole); runs locally/nightly. Plus `scripts/e2e-whisperkit.sh` for the real WhisperKit engine over fixtures, wired non-blocking in `.github/workflows/e2e-nightly.yml`.

**Explicit non-goals:** custom AudioServerPlugIn driver; CMIOExtension virtual mic (camera-only); XCUITest-driven permission dialogs (flaky; TCC pre-seeding is more reliable).

---

## Reference links

- BlackHole: https://github.com/ExistentialAudio/BlackHole · runner-images issue: https://github.com/actions/runner-images/issues/11746
- ffmpeg audiotoolbox output: https://ffmpeg.org/ffmpeg-devices.html · playing into BlackHole: https://github.com/ExistentialAudio/BlackHole/issues/45
- Apple AudioServerPlugIn (if ever needed): https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in · libASPL: https://github.com/gavv/libASPL
- Whisper determinism: https://github.com/openai/whisper/discussions/81
