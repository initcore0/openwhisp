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
