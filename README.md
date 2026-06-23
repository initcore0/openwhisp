# OpenWhisp — Local‑First Dictation for macOS

> **Wispr Flow‑style dictation, but fully on‑device, free, and open source.**
> No cloud, no subscription, no telemetry — your voice never leaves your Mac.

OpenWhisp is a menu‑bar dictation app for macOS. Hold a key, speak, release — your words are transcribed **on‑device** and typed into whatever app is focused. No cloud account, no subscription, no audio leaving your machine (unless you explicitly opt into a cloud LLM for cleanup).

Transcription runs locally with [whisper.cpp](https://github.com/ggerganov/whisper.cpp); optional text cleanup can run **fully locally** against your own LLM server, or via OpenAI if you choose.

> **Status:** early but functional. Open‑source (MIT). Apple Silicon, macOS 14+.

---

## Highlights

- **100% local transcription** — whisper.cpp on‑device; works offline.
- **Type into any app** — text is inserted into the focused app via Accessibility (clipboard‑preserving) or Cmd+V paste.
- **Hold‑to‑talk** — hold a hotkey (Fn or Control+Space), release to insert, Esc to cancel.
- **Smart formatting (local, default‑on)** — capitalization, punctuation cleanup, filler‑word removal ("um/uh"), and spoken punctuation ("new line", "comma", "period").
- **Custom vocabulary** — bias whisper toward your names/jargon, plus "heard → correct" substitutions (e.g. "clod code" → "Claude Code").
- **AI post‑processing (optional)** — rephrase or improve translation with an LLM. Point it at a **local OpenAI‑compatible server** (llama.cpp `llama-server`, Ollama) to stay private, or at OpenAI.
- **Voice commands** — end a dictation with an instruction ("…make this formal") and it's applied to the rest via the LLM.
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

### 3. Build & package OpenWhisp

```bash
./build.sh        # compile the Swift sources -> build/OpenWhisp
./package.sh      # wrap into build/OpenWhisp.app (+ bundle whisper runtime, ad-hoc sign)

open build/OpenWhisp.app
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
users — that needs an Apple Developer ID cert + notarization. If you have one,
set `SIGN_IDENTITY="Developer ID Application: …"` and `package.sh` will use it.)

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
5. A live **test**

You can re‑open it any time from the menu bar → **Setup Guide…**.

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

---

## Settings overview

Settings has a **Basic** and an **Advanced** tab.

**Basic**

- **General** — launch at login.
- **Hotkey** — Fn / Globe or Control+Space.
- **Microphone** — input device.
- **Language** — 12 languages + Auto Detect; choose **English** to have whisper translate non‑English speech to English.
- **Quality** — Faster / Balanced / Best (maps to Whisper models; downloads on demand).
- **Smart Formatting** — clean‑up on/off, spoken punctuation, filler removal.
- **Custom Vocabulary** — bias terms + "heard → correct" replacements.
- **AI Post‑processing** — provider (OpenAI **or** local server), mode (rephrase / improve translation), and **voice commands**.
- **Text Output** — insertion method, output mode, overlay, trailing space, clipboard restore.

**Advanced**

- Engine (Whisper vs Apple Speech), raw model picker + paths, live‑chunk tuning, whisper.cpp backend (CLI vs warm server), per‑app modes, history, permissions, diagnostics.

---

## AI post‑processing (optional)

OpenWhisp can run a final LLM pass to rephrase your text or improve a translation. It speaks the standard **OpenAI chat‑completions API**, so you can keep it fully local:

- **Local (private)** — point it at any OpenAI‑compatible server. Default URL `http://localhost:8080/v1`.
  - **llama.cpp**: `llama-server -m your-model.gguf --host 0.0.0.0 --port 8080`
  - **Ollama**: runs an OpenAI‑compatible API at `http://localhost:11434/v1`
- **OpenAI (cloud)** — paste an API key; the key is stored in the macOS **Keychain**, not in plain text.

Use **Test Connection** / **Validate** in Settings to confirm reachability.

### Voice commands

With voice commands enabled, ending a dictation with a recognized instruction applies it to the rest:

> "Schedule the review for Monday. **Make this formal.**" → the instruction is stripped and the text is rewritten formally.

Recognized leads include "make this/it…", "rewrite/rephrase this…", "translate this to…", "summarize this", plus an optional wake word. Works in **Final** and **Preview** modes and needs an AI provider configured. (Trailing translate/transcribe instructions are stripped from output even with voice commands off, so dictating in Russian and saying "translate this into English" won't leave that phrase in your text.)

---

## Privacy

- Transcription is **on‑device**. Audio is recorded to `~/Library/Caches/com.openwhisp.app/` and the WAV is deleted after each transcription.
- History and settings are stored locally (`~/Library/Application Support/OpenWhisp/`, UserDefaults, Keychain).
- The **only** time text leaves your machine is if you turn on AI post‑processing with the **OpenAI** provider. The **local** provider keeps everything on your machine/LAN.
- Transcript text is **not** written to the app's log files.
- **Password / secure fields** are detected and skipped — OpenWhisp won't dictate into, insert, or store their contents.
- Settings → Status shows a live **privacy indicator** ("Fully on‑device" vs "Sends text to OpenAI") for your current configuration.

**Verify it yourself** — you don't have to take our word for it:

```bash
# Should stay silent while you dictate, unless you enabled the OpenAI cloud provider:
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
│   ├── TextInserter.swift           # Accessibility insert + Cmd+V paste fallback
│   ├── KeyboardSynthesizer.swift    # thin shim over TextInserter
│   ├── HotkeyMonitor.swift          # CGEventTap (+ NSEvent fallback) push-to-talk
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
- **Audio** — capture is resampled to whisper's required 16 kHz mono 16‑bit PCM; live mode supports timer‑based or pause‑based (VAD) chunking.
- **Insertion** — Accessibility direct‑insert avoids clobbering the clipboard; paste is the universal fallback. All insertion is serialized so live chunks stay in order.
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
