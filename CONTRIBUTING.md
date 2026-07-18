# Contributing to OpenWhisp

Thanks for your interest! OpenWhisp is a local-first, MIT-licensed macOS
dictation app, and contributions are welcome.

## Quick start

```bash
git clone --recursive https://github.com/initcore0/openwhisp.git
cd openwhisp
./scripts/build-whisper.sh   # build the vendored whisper.cpp submodule
./build.sh && ./package.sh   # build + bundle the app
swift test                   # run the unit tests
```

See the [README](README.md#building) for full build/permissions details and
[docs/ROADMAP.md](docs/ROADMAP.md) for direction and priorities.

## Fast dev loop for the app (incremental builds + IDE)

`./build.sh` compiles the whole app as one `swiftc` glob — every edit recompiles
~59k LOC (~70s), and it gives editors no index for the app target (AppState + the
41 app-only services are invisible to autocomplete). For iterating on app/UI code,
use the dev-only SwiftPM package instead:

```bash
scripts/dev-app.sh              # incremental build — only the file you changed recompiles (~2–5s)
open AppPackage/Package.swift   # or: full Xcode / SourceKit-LSP over the whole app module
```

- **`AppPackage/`** is a **dev-only** manifest (`AppPackage/Package.swift`) that
  builds the same app sources (symlinked from `OpenWhisp/`) as one SwiftPM
  executable target — so you get incremental compilation and full LSP/Xcode
  support (autocomplete, jump-to-def, breakpoints) on **AppState and every app
  service/view**, which the root `Package.swift`'s test target excludes.
- It builds in the **lean** configuration (stub engines, no Sparkle — the same
  seam CI uses): enough to type-check and iterate on app/UI code without the
  WhisperKit/FluidAudio/Sparkle native deps. It is **not** the release path.
- To run the real app with real engines, or to produce the signed `.app`, use
  **`./build.sh`** / **`./package.sh`** as before — those remain the sole
  release/CI paths and are unchanged.

Point SourceKit-LSP (VS Code, Neovim, Zed, etc.) at `AppPackage/` — that's the
manifest that indexes the app module. Xcode: `open AppPackage/Package.swift`.

## Before you open a PR

- **Run `swift test` and `./build.sh`** — both must pass.
- **Add tests for logic changes.** The `OpenWhispCore` SwiftPM target compiles
  only Foundation-only files, so put new pure logic (parsing, formatting,
  decisions) in a `import Foundation`-only file under `OpenWhisp/Services/`, add
  it to `Package.swift`'s `sources`, and test it under `Tests/OpenWhispCoreTests/`.
  This keeps the bug-prone text/decision logic covered without needing the GUI.
- **Keep platform-bound code (AppKit/AVFoundation/Accessibility) thin** and
  delegate to testable pure helpers where possible.
- **Match the surrounding style** and keep diffs focused.

## What makes a good contribution

- Bug fixes (with a regression test).
- Items from the roadmap (open an issue first for larger ones so we can align).
- New **voice commands / prompt presets / vocabulary** — these are easy wins and
  exactly the kind of thing the community can share.
- Docs and onboarding improvements.

## Privacy is a hard requirement

OpenWhisp's promise is that **audio and text never leave the device** unless the
user explicitly opts into a cloud provider. Any change that could send data
off-device must be opt-in, clearly surfaced in the UI, and documented. See
[SECURITY.md](SECURITY.md).

## Reporting bugs

Use the issue templates. Include your macOS version, the engine (Whisper CLI vs
server, or Apple Speech) and AI provider in use, and relevant lines from the log
(`~/Library/Caches/com.openwhisp.app/whisper-engine.log`).
