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
- **Fast dev loop (MAK-65):** `scripts/dev-app.sh` builds the app incrementally
  (~2–5s/edit vs ~70s for `./build.sh`) via the dev-only `AppPackage/Package.swift`
  manifest, which also gives Xcode/SourceKit-LSP full index on AppState + all app
  services (`open AppPackage/Package.swift`). It's LEAN-only (stub engines) and is
  NOT a release path — `./build.sh` / `./package.sh` stay the sole release/CI
  builders. The app's `@main` entry lives in `OpenWhisp/AppMain.swift` (renamed
  from `main.swift` so SwiftPM's executable target accepts `@main`); build.sh
  globs `*.swift` so the name is irrelevant to it.
- **Toolchain floor: Xcode 16 / Swift 6 tools.** `Package.swift` is
  `swift-tools-version:6.0` (needed for the `.iOS(.v18)` platform); older
  toolchains fail `swift test` with a manifest error. The language mode stays
  pinned to 5 (`swiftLanguageModes: [.v5]`).
- **`OpenWhispCore` + `OpenWhispBridgeKit` are consumed by the iOS companion**
  (openwhisp-ios, MAK-51) as library products. Treat their `public` API AND the
  JSON file formats behind the public stores (profiles/vocabulary/history/…) as
  a versioned contract — renames and format changes now have a second client to
  migrate. New members on already-`public` core types should be `public` too
  (CI's `ios-libraries` job builds both products for iOS, but it can't see a
  missing `public` until the iOS app actually needs the symbol).

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
