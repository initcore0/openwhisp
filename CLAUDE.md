# OpenWhisp — working agreement

Local-first macOS dictation app (Swift). On-device transcription (WhisperKit /
whisper.cpp), optional LLM refine, agent bridge + MCP.

## Build

- **Always build with plain `./build.sh`** — WhisperKit is the DEFAULT engine.
  Never `WHISPERKIT=0` (that produces a lean build with a stub engine).
- `./package.sh` makes the signed `.app` (bundles the whisper/llama runtimes +
  the `openwhisp` CLI at `Contents/Helpers/`). Install by copying
  `build/OpenWhisp.app` → `/Applications/`.
- The GUI app is a raw-`swiftc` glob (no `.xcodeproj`). `OpenWhispCore` is a
  Foundation-only SwiftPM package (the subset that `swift test` compiles).

## When you build or change a feature — test it

The E2E test infrastructure exists specifically so every feature is regression-
tested. **When you add or change a pipeline/app feature, add a test for it and run
the suite before finishing.** See [docs/E2E_AUDIO_TESTING.md](docs/E2E_AUDIO_TESTING.md)
— especially the **"How to add a test for a new feature"** section.

Three test layers, from fast to real:

1. **`swift test`** — ALWAYS run this before finishing any code change. ~1.5s, no
   setup, deterministic. Covers all feature *logic* (pipeline, VAD, formatting,
   refine state machine, agent-bridge routing, resolvers, …) via fixture audio +
   fakes. This is the baseline gate — it must stay green.
   - Add the feature's integration test to
     `Tests/OpenWhispCoreTests/FeatureMatrixE2ETests.swift` (drive it from fixture
     audio through `LiveChunkDriver`). If the logic is trapped on the AppKit-only
     `AppState`, extract it into a pure core resolver first (see the guide).

2. **`./scripts/e2e-app-features.sh`** — the RUNNING app + REAL LLM over the agent
   bridge (`openwhisp refine/status/history`). Run this when you touch refine,
   the bridge, or any LLM-backed feature — it proves real output, which `swift
   test` can't (it stubs the LLM). Needs the app running with `llm=configured`.

3. **`./scripts/e2e-whisperkit.sh`** (real transcription engine over fixtures,
   offline) and **`./scripts/e2e-smoke.sh`** (real mic via BlackHole). Run these
   when you touch transcription or capture. Local/nightly, not blocking CI.

Rule of thumb: **every pipeline/app feature gets at least one automated test.** If
you can't write one without linking `AppState`, that's the signal to extract the
logic into core first.

## Conventions

- Commit messages end with the `Co-Authored-By: Claude …` trailer (see recent log).
- Branch off `main`; open a PR when the work is ready. Don't commit `.claude/`.
- Memory + prior context live in the auto-loaded memory index; check it before
  re-deriving project facts.
