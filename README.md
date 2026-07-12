# OpenWhisp — Local‑First Dictation for macOS

> **Wispr Flow‑style dictation, but fully on‑device, free, and open source.**
> No cloud, no subscription, no telemetry — your voice never leaves your Mac.

OpenWhisp is a menu‑bar dictation app for macOS. Hold a key, speak, release — your words are transcribed **on‑device** and typed into whatever app is focused. No cloud account, no subscription, no audio leaving your machine (unless you explicitly opt into a cloud LLM for cleanup).

Transcription runs locally with [whisper.cpp](https://github.com/ggerganov/whisper.cpp); optional text cleanup can run **fully locally** against your own LLM server, or via OpenAI if you choose.

**Website:** [openwhisp.app](https://openwhisp.app) · mirror (for regions where the main site is blocked): [initcore0.github.io/openwhisp-mirror](https://initcore0.github.io/openwhisp-mirror/)

> **Status:** early but functional. Open‑source (MIT). Apple Silicon, macOS 14+.

---

## Highlights

- **100% local transcription** — whisper.cpp on‑device; works offline.
- **Type into any app** — text is inserted into the focused app via Accessibility (clipboard‑preserving) or Cmd+V paste.
- **Hold‑to‑talk** — hold a hotkey (Fn or Control+Space), release to insert, Esc to cancel.
- **Smart formatting (local, default‑on)** — capitalization, punctuation cleanup, filler‑word removal ("um/uh"), and spoken punctuation ("new line", "comma", "period").
- **Custom vocabulary** — bias whisper toward your names/jargon, plus "heard → correct" substitutions (e.g. "clod code" → "Claude Code").
- **AI post‑processing (optional)** — rephrase or improve translation with an LLM. Choose **Built‑in (offline)** to run a small model fully on‑device with no setup (downloads once, then never phones home), point it at a **local OpenAI‑compatible server** (llama.cpp `llama-server`, Ollama), or at OpenAI.
- **Refine while dictating** — keep holding the dictation key, tap the Refine key, and speak an instruction ("make it a Telegram post"); on release the AI rewrites what you dictated.
- **Refine your selection** — with text highlighted in any app, hold the dictation key, tap the Refine key, and speak an instruction ("make it more formal", "translate to Russian"); the selected text is replaced in place with the AI's result.
- **Per‑app modes** — auto‑apply language / output / AI‑cleanup overrides based on the app you're typing into.
- **Transcription history** — local, searchable list of past dictations with copy/re‑use.
- **Multiple models & languages** — tiny → large‑v3; 12 languages plus auto‑detect; optional whisper translate‑to‑English.
- **Apple Speech engine** — optional native streaming recognizer as an alternative to whisper.
- **Launch at login**, a sleek recording overlay with live transcript, and a guided first‑run setup.

---

## Install

OpenWhisp builds from source (no notarized release yet). See **[Building](#building)**.

A prebuilt `.app`/DMG is attached to each [GitHub Release](../../releases). Builds are currently **ad‑hoc signed** (no paid Apple Developer ID yet), so macOS Gatekeeper blocks them on first launch and shows *"OpenWhisp is damaged / cannot be opened."* That's expected — to open it:

- **macOS 15 (Sequoia) and later:** double‑click once (it gets blocked), then go to **System Settings → Privacy & Security**, scroll to the OpenWhisp message and click **Open Anyway**.
- **Or, from Terminal (any version):** `xattr -dr com.apple.quarantine /Applications/OpenWhisp.app`

> The old "right‑click → Open" trick no longer works for ad‑hoc‑signed apps on macOS 15+. To avoid the warning entirely, [build it yourself](#building).

---

## Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon** (the build targets `arm64`)
- **whisper.cpp** built locally (for the bundled runtime) — see below
- A **microphone**

RAM scales with model size: ~2 GB for `tiny`, ~4 GB `base`, ~8 GB `small`, ~16 GB `medium`, ~32 GB `large‑v3`.

---

## Building

OpenWhisp uses plain `swiftc` build scripts (no Xcode project). **whisper.cpp is vendored as a git submodule** (pinned to a stable release), so the only prerequisites are the Xcode command‑line tools and `cmake`. The app bundles the whisper.cpp runtime, so end users don't need it on PATH.

### 1. Clone (with the submodule)

```bash
git clone --recursive https://github.com/initcore0/openwhisp.git
cd openwhisp
# already cloned without --recursive?  ->  git submodule update --init --recursive
```

### 2. Build whisper.cpp (the submodule)

```bash
./scripts/build-whisper.sh
```

This builds `third_party/whisper.cpp` and produces `whisper-cli` + `whisper-server` under `third_party/whisper.cpp/build/bin/`, which the packaging step bundles into the app.

### 2b. (Optional) Build the built‑in LLM runtime

```bash
./scripts/build-llama.sh
```

This builds the `third_party/llama.cpp` submodule into `llama-server`, bundled under `Resources/llama/` (with its **own** ggml dylibs, isolated from whisper's). It powers the **Built‑in (offline)** AI post‑processing provider — on‑device text refinement with no Ollama / external server. It's **opt‑in**: skip this step and the app still builds and runs (the built‑in provider just won't have a runtime). The refinement model itself (e.g. Qwen2.5 0.5B) downloads once on first use, like whisper models — it is never bundled in the `.app`.

### 3. Build & package OpenWhisp

```bash
./build.sh        # compile the Swift sources -> build/OpenWhisp
./package.sh      # wrap into build/OpenWhisp.app (+ bundle whisper runtime, ad-hoc sign)

open build/OpenWhisp.app

# Or, to build AND replace the copy in /Applications in one go (quits the running
# app, installs the fresh bundle, relaunches):
./build.sh && ./package.sh --install
```

> Always run via the `.app` bundle, not the bare binary — `UserNotifications` and the permission prompts require a real bundle.

To point at a whisper.cpp build elsewhere instead of the submodule:

```bash
WHISPER_BIN_DIR=/path/to/whisper.cpp/build/bin ./package.sh
```

### Stop re‑granting permissions on every build

By default `package.sh` signs **ad‑hoc** (`codesign --sign -`), which gives each
build a *different* signing identity. macOS ties permissions (Microphone,
Accessibility, Input Monitoring) to that identity, so every rebuild looks like a
new app and re‑asks for permission.

Fix it once by creating a **stable self‑signed identity**:

```bash
./scripts/create-signing-cert.sh   # one time; prompts for your password to trust the cert
./build.sh && ./package.sh         # now signed with a stable identity
```

After this, permissions persist across rebuilds. (This is self‑signed: it stops
the re‑prompts on *your* machine but doesn't make the app trusted for other
users — that needs an Apple Developer ID cert + notarization.)

To build a **distributable, notarized** DMG that opens on other Macs with no
Gatekeeper warning, see **[docs/SIGNING_AND_NOTARIZATION.md](docs/SIGNING_AND_NOTARIZATION.md)**
(`NOTARIZE=1 ./build-dmg.sh release` once you have a Developer ID cert).

### Optional: build a DMG

```bash
./build-dmg.sh    # or ./create-dmg.sh
```

---

## First run

A short guided setup walks you through:

1. **Microphone** permission
2. **Accessibility** permission (needed to type into other apps and to detect the hotkey)
3. **Model download** (the chosen Whisper model downloads automatically on first use)
4. **Hotkey** choice (Fn or Control+Space)
5. **AI refinement** (optional) — turn it on and pick a provider; choose **Built-in (offline)** to download a small on-device model right from setup
6. A live **test**

You can re‑open it any time from the menu bar → **Setup Guide…**.

### Switching AI models on the fly

The menu-bar menu has an **AI** submenu where you can flip the provider
(Built-in / OpenAI / Local) and, for the built-in provider, **switch between
bundled models** (Qwen2.5 0.5B / 1.5B, SmolLM2) without opening Settings — handy
for comparing speed and quality. Un-downloaded models are marked and fetch
automatically the first time you use them.

### Permissions

| Permission | Why | Where |
|-----------|-----|-------|
| **Microphone** | record audio | System Settings → Privacy & Security → Microphone |
| **Accessibility** | type into apps + global hotkey | System Settings → Privacy & Security → Accessibility |
| **Input Monitoring** | detect the push‑to‑talk hotkey | System Settings → Privacy & Security → Input Monitoring |
| **Notifications** | optional status notifications | granted on prompt |

> **About the "OpenWhisp would like to receive keystrokes" prompt** — that's the Input Monitoring permission. OpenWhisp watches keyboard events only to detect your push‑to‑talk hotkey; **keystrokes are never logged, stored, or sent anywhere** (it's a local, listen‑only check against your chosen key). It's required because macOS gates any global hotkey behind this consent. If you deny it, the hotkey won't work — re‑enable OpenWhisp under Input Monitoring and use **Retry Hotkey** in Settings.

`reset-permissions.sh` resets OpenWhisp's TCC records if a rebuilt app identity gets stuck.

---

## Using it

1. Click the menu‑bar **waveform** icon, or just use the hotkey.
2. **Hold** the hotkey (default **Fn**) and speak — your words stream into the on‑screen overlay as you talk. **Release** to insert; press **Esc** to cancel.
3. Text is typed into whatever app is focused.

**Output modes** (Settings → Text Output):

- **Preview, then paste** *(default)* — text streams into the overlay while you speak; **nothing is inserted until you release**, then it's pasted once (cleaned up, and rephrased if AI is on). The recommended flow: see it, then commit it.
- **Paste at end** — inserts once on release, without the live overlay text.
- **Type live** — each phrase is pasted into the app as you speak (experimental).

**Insertion method** (Settings → Text Output):

- **Automatic** *(default)* — insert directly into the focused field via Accessibility (your clipboard is left untouched), falling back to paste when an app doesn't support it.
- **Direct insert only** / **Paste (Cmd+V)**.

Whichever mode you pick, insertion is **verified** — if it can't be confirmed, your text is kept on the clipboard with a "copied, press ⌘V" cue, never silently dropped.

---

## Automation — the `openwhisp://` URL scheme (Raycast / Alfred)

OpenWhisp registers an `openwhisp://` URL scheme so any launcher (Raycast, Alfred, Shortcuts, or a plain `open openwhisp://…` in a script) can drive its control surface. It reuses the same in‑app actions the hotkey and menu bar use — no CLI needed.

```sh
open "openwhisp://record"                              # start / stop dictation (like the hotkey)
open "openwhisp://paste-last-result"                   # paste the last result into the focused app
open "openwhisp://refine?instruction=make%20it%20formal"  # rewrite the last result (→ clipboard)
open "openwhisp://?switch-mode=email&record"           # chain verbs, run in order
```

Verbs are a fixed, validated **allow‑list** — the scheme never runs a shell string or an arbitrary file, and hostile/malformed URLs are rejected as a whole. `record`, `refine`, and `paste-last-result` are **live**; `switch-mode` / `activate-mode` are parsed and validated now but wired in a follow‑up (OpenWhisp's modes are per‑app profiles today, with no named‑mode registry to switch by key yet).

Ready‑made **Raycast Script Commands** and an **Alfred recipe** live in [`integrations/`](integrations/), with the full URL grammar in [`integrations/README.md`](integrations/README.md).

---

## Settings overview

Settings has a **Basic** and an **Advanced** tab.

**Basic**

- **General** — launch at login.
- **Hotkey** — Fn / Globe or Control+Space.
- **Microphone** — input device.
- **Language** — 12 languages + Auto Detect; choose **English** to have whisper translate non‑English speech to English.
- **Quality** — Faster / Balanced / **Best (Large v3 Turbo, recommended)** — maps to Whisper models; downloads on demand. Turbo is near top accuracy and still fast on Apple Silicon.
- **AI Post‑processing** — the on/off toggle and provider (OpenAI **or** local server) are always visible (they decide whether text leaves your machine); provider details (mode, key/model, connection test) and the voice‑actions/prompt editor are tucked into collapsible "▸" groups.
- **Text Output** — insertion method, output mode, overlay, trailing space, clipboard restore.

**Advanced**

- **Smart Formatting** — clean‑up on/off, spoken punctuation, filler removal (defaults are fine for most; here if you need to turn them off, e.g. for verbatim/code).
- **Custom Vocabulary** — bias terms + "heard → correct" replacements.
- Engine (Whisper · Apple Speech · WhisperKit), raw model picker + paths, live‑chunk tuning, whisper.cpp backend (CLI vs warm server), per‑app modes, history, permissions, diagnostics. The settings shown adapt to the selected engine.
- **Backup & Sharing** — export your per‑app profiles, vocabulary, and command prompts to a JSON file you can back up, hand‑edit, or share; import replaces only the sections present in the file (so a vocab‑only file touches just your vocabulary). Also includes one‑click **config packs** (e.g. a developer vocabulary) — small bundled config files; the same JSON format works for your own.

---

## AI post‑processing (optional)

OpenWhisp can run a final LLM pass to rephrase your text or improve a translation. It speaks the standard **OpenAI chat‑completions API**, so you can keep it fully local:

- **Built‑in (offline)** — the zero‑setup option. A small model (default **Qwen2.5 0.5B**, Apache‑2.0) runs in a bundled `llama-server` entirely on your Mac — no Ollama, no server to start, nothing leaves the machine. The model downloads once into Application Support on first use. Swap models (0.5B / 1.5B / SmolLM2) from the picker to trade speed for quality. Requires the optional `./scripts/build-llama.sh` step at build time. Pairs best with the **Apple Speech** or **WhisperKit** transcription engine to keep memory low.
- **Local (private)** — point it at any OpenAI‑compatible server. Default URL `http://localhost:8080/v1`.
  - **llama.cpp**: `llama-server -m your-model.gguf --host 0.0.0.0 --port 8080`
  - **Ollama**: runs an OpenAI‑compatible API at `http://localhost:11434/v1`
- **OpenAI (cloud)** — paste an API key; the key is stored in the macOS **Keychain**, not in plain text.

Use **Test Connection** / **Validate** in Settings to confirm reachability.

### Refine while dictating (tap the Refine key)

While still **holding your dictation key**, **tap the Refine key** (default **Right Control**, changeable under **Settings → Hotkey**) and speak an instruction. When you **release the dictation key**, the AI rewrites what you dictated before the tap:

> Hold Fn, say "hello team, I'm on vacation and all is great", **tap Right Control** (keep holding Fn), say *"make it a Telegram post"*, release Fn → the rewritten Telegram post is inserted.

It's one continuous hold — normal dictation (no Refine tap) always pastes instantly. No fixed phrases — say what you want in plain language (any language). Needs an AI provider configured; the overlay turns magenta while you speak the instruction and shows **"Refining…"** while the AI works. Toggle it in **Settings → AI Post‑processing**.

(Trailing translate/transcribe instructions are still stripped from output, so dictating in Russian and saying "translate this into English" won't leave that phrase in your text.)

**Refine selected text** — with text **selected** and no in-session dictation, tapping Refine during a hold applies to the selection instead.

> Select a paragraph, hold the dictation key, **tap the Refine key**, say *"make it more concise"*, release → the selection is replaced in place with the AI's rewrite.

The selection is read via the Accessibility API (no clipboard touch); for apps that don't expose it, OpenWhisp falls back to a synthesized ⌘C and **restores your previous clipboard** afterward. In-session dictation takes priority — the selection is only used when you didn't dictate anything before tapping Refine. Password/secure fields are never read.

### Script post‑processor (advanced)

Settings → Advanced → **Script Post‑processor** lets you pipe the **final** transcript through any executable you choose: your text arrives on **stdin**, and whatever the script prints to **stdout** is inserted instead. Off by default. It runs only at the end of a dictation, with a **~2 second timeout**, and **fails open** — on any error, timeout, non‑zero exit, or empty output, your original transcript is used unchanged. It does run code you point it at, so only use a script you trust. Example (uppercase): a script that runs `tr '[:lower:]' '[:upper:]'`.

---

## Privacy

- Transcription is **on‑device**. Audio is recorded to `~/Library/Caches/com.openwhisp.app/` and the WAV is deleted after each transcription.
- History and settings are stored locally (`~/Library/Application Support/OpenWhisp/`, UserDefaults, Keychain).
- The **one network call OpenWhisp makes by default is the update check** (via [Sparkle](https://sparkle-project.org)): once a day it fetches a small **EdDSA‑signed** release feed over HTTPS, sending **only your app version and macOS version** — no analytics, no system profile, no dictation data. Toggle it off in **Settings → General → Software Update**. Details in [docs/AUTO_UPDATE.md](docs/AUTO_UPDATE.md).
- The **only** time your dictated **text** leaves your machine is if you turn on AI post‑processing with the **OpenAI** provider. The **local** provider keeps everything on your machine/LAN.
- Transcript text is **not** written to the app's log files.
- **Password / secure fields** are detected and skipped — OpenWhisp won't dictate into, insert, or store their contents.
- Settings → Status shows a live **privacy indicator** ("Fully on‑device" vs "Sends text to OpenAI") for your current configuration.

**Verify it yourself** — you don't have to take our word for it:

```bash
# Should stay silent while you dictate, unless you enabled the OpenAI cloud
# provider. (The daily Sparkle update check is the one exception — disable it in
# Settings → General → Software Update to see zero egress.)
nettop -p "$(pgrep -x OpenWhisp)"
```

See [SECURITY.md](SECURITY.md) for the full privacy model and how to report issues.

---

## Architecture

```
OpenWhisp/
├── main.swift                 # @main app delegate, menu bar, windows, onboarding
├── Models/
│   └── AppState.swift         # @MainActor source of truth: settings, session
│                              # lifecycle, the transcription/insertion pipeline
├── Services/
│   ├── AudioRecorder.swift          # AVAudioEngine/AVAudioRecorder capture,
│   │                                # 16 kHz mono resampling, chunking, VAD
│   ├── WhisperEngine.swift          # whisper-cli subprocess + warm whisper-server (HTTP)
│   ├── AppleSpeechEngine.swift      # optional SFSpeechRecognizer engine
│   ├── WhisperKitBridge.swift       # WhisperKit (CoreML) file + streaming bridge (#if WHISPERKIT)
│   ├── WhisperKitEngine.swift       # WhisperKit file engine; WhisperKitStreamingEngine = streaming
│   ├── WhisperKitModelCatalog.swift # staged CoreML model list/labels (build-independent)
│   ├── TextInserter.swift           # Accessibility insert + Cmd+V paste fallback
│   ├── SelectionReader.swift        # read selected text (AX, ⌘C fallback) for refine-selection
│   ├── InstructionChain.swift       # refine availability + LLM prompt construction
│   ├── RefineFlow.swift             # pure, unit-tested refine state machine
│   ├── RefineKey.swift              # selectable refine key (id ↔ keycode)
│   ├── KeyboardSynthesizer.swift    # thin shim over TextInserter
│   ├── HotkeyMonitor.swift          # CGEventTap (+ NSEvent fallback) push-to-talk + refine key
│   ├── PostProcessor.swift          # protocol + chain for text post-processing
│   ├── SmartFormatter.swift         # local formatting/punctuation/filler rules
│   ├── Vocabulary.swift             # custom terms + substitutions
│   ├── VoiceCommandParser.swift     # trailing spoken-instruction detection
│   ├── MetaInstructionStripper.swift# strips trailing "translate this…" etc.
│   ├── OpenAITranslationService.swift # OpenAI-compatible LLM client (cloud/local)
│   ├── AppProfile.swift             # per-app override profiles
│   ├── TranscriptionHistory.swift   # local history store
│   ├── LaunchAtLogin.swift          # SMAppService login item
│   └── KeychainStore.swift          # API key storage
├── Views/
│   ├── SettingsView.swift     # Basic/Advanced settings
│   ├── OverlayView.swift      # "Quiet Glass" recording overlay + live transcript
│   └── OnboardingView.swift   # first-run setup
├── Resources/models/manifest.json   # model catalog
├── Info.plist
└── OpenWhisp.entitlements

Tests/OpenWhispCoreTests/      # XCTest for the pure-logic types (swift test)
Package.swift                  # SwiftPM test package (OpenWhispCore) — tests only
third_party/whisper.cpp/       # vendored whisper.cpp (git submodule, pinned)
build.sh / package.sh          # compile + bundle the GUI app
build-dmg.sh / create-dmg.sh   # DMG packaging
scripts/build-whisper.sh           # build the whisper.cpp submodule
scripts/bundle-whisper-runtime.sh  # copy whisper binaries + dylibs into the .app
```

### Notable design points

- **Transcription backends** — `whisper-cli` per request, or a warm `whisper-server` kept loaded for lower latency (Advanced → whisper.cpp backend). The app bundles both (built from the `third_party/whisper.cpp` submodule); falls back to `~/whisper.cpp/build/bin/` if a bundled binary isn't present.
- **WhisperKit backend (default)** — a Swift‑native CoreML/ANE Whisper runtime ([Argmax](https://github.com/argmaxinc/WhisperKit)), now the **default transcription engine**. It does both file transcription and **real‑time streaming** (built‑in VAD skips silence) and shares the streaming session path with Apple Speech. It's compiled in by default; build lean without it via `WHISPERKIT=0 ./build.sh` (the engine then falls back to whisper.cpp). Two macOS‑26 gotchas worth knowing: models are loaded from a locally‑staged folder of compiled `.mlmodelc` (the published prebuilts don't load on Tahoe), and the audio encoder is pinned to the **GPU** because ANE specialization of a non‑tiny encoder can stall indefinitely. Settings become backend‑aware (only the relevant options show per engine). Full technical write‑up: [docs/WHISPERKIT_PILOT.md](docs/WHISPERKIT_PILOT.md).
- **Audio** — capture is resampled to whisper's required 16 kHz mono 16‑bit PCM; live mode supports timer‑based or pause‑based (VAD) chunking.
- **Insertion** — Accessibility direct‑insert avoids clobbering the clipboard; paste is the universal fallback. All insertion is serialized so live chunks stay in order. **Verified, never‑lose‑text:** an AX insert is read back where the field exposes a value (so a silently‑ignored insert in some Electron/web views falls through to paste), the paste path confirms the clipboard write and a frontmost target before firing ⌘V, and if nothing can be confirmed the text is **left on the clipboard** with a "Couldn't insert — copied, press ⌘V" cue rather than vanishing.
- **Concurrency** — `AppState` is `@MainActor`; service callbacks hop back via `Task { @MainActor }`. Long‑running work (whisper subprocess/server, LLM calls, paste timing) runs off the main actor.

---

## Development

```bash
./build.sh                 # build the app
swift test                 # run the unit tests for core logic
```

`swift test` covers the Foundation‑only logic (smart formatting, vocabulary substitution, voice‑command parsing, translate‑instruction stripping) via the `OpenWhispCore` SwiftPM package. The GUI app itself is built by `build.sh`/`package.sh` (SwiftPM can't produce a signed `.app`). CI runs `swift test` on every push/PR.

### Common tweaks

- **Default hotkey / model / language** — `OpenWhisp/Models/AppState.swift` → `init()`.
- **Add a language** — `OpenWhisp/Views/SettingsView.swift` → Language picker.
- **Formatting rules** — `OpenWhisp/Services/SmartFormatter.swift`.

---

## Contributing

Issues and PRs welcome — see **[CONTRIBUTING.md](CONTRIBUTING.md)** for the dev setup, test conventions, and the privacy requirement. Run `swift test` and `./build.sh` before submitting.

Direction and priorities (competitive analysis, feature gaps, plugin plan) live in **[docs/ROADMAP.md](docs/ROADMAP.md)**.

## License

MIT — see [LICENSE](LICENSE).

Built on [whisper.cpp](https://github.com/ggerganov/whisper.cpp).
