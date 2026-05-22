# VoiceNote — Local Speech-to-Text for macOS

A minimal menu-bar application for macOS that transcribes speech to text **100% locally** and **types it directly into the active application**. No cloud APIs, no internet connection required. Uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for fast on-device transcription powered by OpenAI's Whisper models compiled to C/C++.

## What It Does

**VoiceNote streams your voice → text → your keyboard in real-time.**

1. You press a hotkey (or menu item) to start recording
2. While recording, audio is split into ~1-second chunks
3. Each chunk is transcribed by whisper.cpp running locally on your Mac
4. Transcribed text is **automatically typed into whatever app has focus** (TextEdit, Slack, Terminal, etc.)
5. Release the hotkey (or click Stop) to end the session

This is like having a dictation assistant that works with any application, in any language, entirely offline.

## Features

- **100% Local** — All transcription runs on-device using whisper.cpp. No data leaves your machine.
- **Real-Time Streaming** — Audio is processed in 1-second chunks as you speak, text appears as you talk.
- **Auto-Type to Active Window** — Transcription results are typed directly into the focused application via CGEvent keyboard synthesis (Cmd+V approach).
- **System Tray App** — Minimal interface. Runs silently in the menu bar.
- **Multiple Models** — Choose between 5 Whisper model sizes (tiny → large-v3) balancing speed vs accuracy.
- **Microphone Selection** — Pick any available input device in settings.
- **Multi-Language** — Supports 12+ languages plus auto-detection.
- **Clipboard Fallback** — Transcription also saved to clipboard and shown as a system notification.
- **Hotkey Recording** — Hold a key to record/stream, release to stop.

## Architecture

```
VoiceNote/
├── main.swift                    # @main entry point, NSApplicationDelegate
│                                 # Menu bar item, menu builder, settings window
├── Models/
│   └── AppState.swift            # Central state management (@MainActor)
│                                 # Settings persistence (UserDefaults)
│                                 # Streaming pipeline: chunk → transcribe → type
├── Services/
│   ├── AudioRecorder.swift       # AVAudioRecorder wrapper
│                                 # Streaming mode: chunk-based recording (~1s chunks)
│                                 # CoreAudio device enumeration (input selection)
│   ├── WhisperEngine.swift       # Process wrapper for whisper.cpp (whisper-cli) binary
│                                 # Captures stdout, parses transcription text
│   ├── HotkeyMonitor.swift       # Global keyboard event monitoring
│                                 # keyDown/keyUp detection for hold-to-record
│   └── KeyboardSynthesizer.swift # CGEvent keyboard synthesis (Cmd+V paste)
│                                 # Types text into the active application
├── Views/
│   └── SettingsView.swift        # SwiftUI settings panel
│                                 # Model picker, microphone selector, language
│                                 # whisper.cpp binary path, verify button
├── Info.plist                    # App metadata, microphone permission
└── VoiceNote.entitlements        # Code signing entitlements
```

### Component Responsibilities

- **`main.swift`** — App lifecycle, menu bar icon (📶), menu popup, settings window
- **`AppState`** — Single source of truth. Persists settings, orchestrates the streaming pipeline: `startStreaming()` → chunk loop → transcribe → `typeViaPaste()` → `stopStreaming()`
- **`AudioRecorder`** — Records audio at 16kHz mono WAV (Whisper format). Supports two modes:
  - **Standard**: Record entire session → single WAV → transcribe once
  - **Streaming**: Record continuously, split into ~1s chunks → each chunk triggers a transcription callback
- **`WhisperEngine`** — Spawns `whisper-cli` as a subprocess. Passes model path, WAV file, language. Parses stdout for transcription text. Supports async completion callbacks.
- **`HotkeyMonitor`** — Uses `NSEvent.addGlobalMonitorForEvents` for keyDown/keyUp. Hold key = start streaming, release = stop streaming.
- **`KeyboardSynthesizer`** — Types text into the active application using the Cmd+V approach:
  1. Save current clipboard content
  2. Set clipboard to transcribed text
  3. Simulate Cmd+V via `CGEvent` (keyboardEventSource)
  4. Restore original clipboard
  This works with ANY application — Terminal, TextEdit, Slack, VS Code, etc.
- **`SettingsView`** — SwiftUI Form with sections for Model, Microphone, Language, whisper.cpp binary path

### Streaming Data Flow

```
User starts streaming (hotkey / menu)
    → AppState.startStreaming()
    → AudioRecorder.startStreaming(chunkDuration: 1.5s)
    → Records audio at 16kHz mono WAV
    
    ┌─────────────────────────────────────────┐
    │  LOOP (while recording):                │
    │                                         │
    │  1. Timer fires every 1.5s             │
    │  2. Current chunk WAV saved            │
    │  3. Recorder starts new chunk          │
    │  4. Callback: AppState onStreamingChunk│
    │  5. WhisperEngine.transcribe(chunk)    │
    │  6. Result → KeyboardSynthesizer.type  │
    │  7. Text typed into active app         │
    │                                         │
    └─────────────────────────────────────────┘
    
User stops streaming (release hotkey / menu)
    → AppState.stopStreaming()
    → AudioRecorder.stop() (final chunk + cleanup)
    → Status: "Idle"
```

## System Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon** (arm64) or Intel Mac
- **whisper.cpp** installed and built locally
- **Microphone** (built-in or external)
- **RAM**: Minimum 2GB for `tiny` model, 4GB+ for `base`, 8GB+ for `small`, 16GB+ for `medium`, 32GB+ for `large-v3`

## Quick Start

### 1. Build whisper.cpp

```bash
git clone https://github.com/ggerganov/whisper.cpp.git ~/whisper.cpp
cd ~/whisper.cpp
make -j$(sysctl -n hw.ncpu)
```

This produces the `main` binary at `~/whisper.cpp/main`.

### 2. Download a model

```bash
mkdir -p ~/whisper.cpp/models

# Base model — good balance of speed and accuracy (72 MB)
curl -L -o ~/whisper.cpp/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin

# Or use the app's auto-download (Settings → Model → select size)
```

Available models:

| Model | Size | Speed | Accuracy | Best For |
|-------|------|-------|----------|----------|
| tiny | 39 MB | Fastest | Low | Testing, quick notes |
| base | 72 MB | Fast | Good | Default choice |
| small | 464 MB | Medium | Very Good | Production use |
| medium | 1.5 GB | Slow | Excellent | High accuracy needed |
| large-v3 | 2.9 GB | Slowest | Best | Maximum quality |

**Why whisper.cpp?** It was selected over alternatives (faster-whisper, openai-whisper) because:
- Runs natively in C/C++ with no Python dependency
- Optimized for Apple Silicon with Metal backend
- Smallest binary footprint, easiest distribution
- Direct command-line interface — no complex API integration needed
- Actively maintained, battle-tested

### 3. Build VoiceNote

```bash
cd ~/projects/voice-note

# Compile
./build.sh

# Package as .app
./package.sh

# Run
open build/VoiceNote.app
```

> **Important:** Always run the app via `open build/VoiceNote.app`, not the bare binary.
> macOS requires a proper `.app` bundle for `UserNotifications` and microphone permissions to work correctly.
> Running the raw binary will cause a silent crash.

### 4. Configure

First launch will prompt for:
1. **Microphone access** — grant in System Settings → Privacy & Security → Microphone
2. **Notification access** — grant when prompted

Then click the menu bar icon → **⚙ Settings**:

1. **whisper.cpp Binary** — set path to `~/whisper.cpp/main`, click **Verify**
2. **Model** — select model size (auto-downloads if missing)
3. **Microphone** — select your preferred input device
4. **Language** — select transcription language or "Auto Detect"

### 5. Use

**Streaming mode** (recommended):
1. Click the menu bar icon → **🎙 Start Streaming**
2. Click on the app where you want text to appear
3. Start speaking — text will be typed in real-time
4. Click the menu bar icon → **⏹ Stop Streaming** when done

**Legacy mode** (record once, transcribe once):
1. Click the menu bar icon → **🎙 Record (legacy)**
2. Speak, then click → **⏹ Stop**
3. Result appears in notification + clipboard

## How Keyboard Synthesis Works

VoiceNote uses the **Cmd+V (paste)** approach to type text:

```swift
// KeyboardSynthesizer.typeViaPaste(text):
1. Save current clipboard content
2. pb.clearContents()
3. pb.setString(transcribedText, forType: .string)
4. CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V down
   → flags = .maskCommand  // Cmd held
5. CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)  // V up
   → flags = .maskCommand
6. Restore original clipboard
```

This approach has several advantages:
- **Universal** — works with ANY application that accepts text input
- **Multi-language** — handles any Unicode character (emoji, CJK, Cyrillic, etc.)
- **No Accessibility hack needed** — uses standard CGEvent API (though Accessibility permissions are still recommended for the global hotkey)
- **Non-intrusive** — clipboard is restored after each paste

### Permissions

| Permission | Purpose | Where to Grant |
|-----------|---------|---------------|
| **Microphone** | Record audio | System Settings → Privacy → Microphone |
| **Notifications** | Show transcription results | System Settings → Notifications |
| **Accessibility** | Global hotkey monitoring | System Settings → Privacy → Accessibility |

## Build System

VoiceNote uses a **script-based build** (`swiftc`) instead of Xcode project files. This ensures deterministic builds without `.pbxproj` fragility.

### Scripts

| Script | Purpose |
|--------|---------|
| `build.sh` | Compiles all Swift files into a Mach-O executable |
| `package.sh` | Wraps the executable in a `.app` bundle with code signing |

### Build Commands

```bash
# Debug build
./build.sh

# Package as .app (also builds if needed)
./package.sh

# Clean and rebuild
rm -rf build/
./build.sh && ./package.sh
```

### Build Flags

The `build.sh` script uses:
- `-target arm64-apple-macosx14.0` — Apple Silicon, macOS 14+
- `-parse-as-library` — allows `@main` with top-level code
- Frameworks: `Cocoa`, `AVFoundation`, `Foundation`, `SwiftUI`, `UserNotifications`, `CoreAudio`, `CoreGraphics`

## Technical Details

### Audio Recording

- Uses `AVAudioRecorder` for WAV capture
- Format: 16kHz, mono, 16-bit PCM (Whisper's expected input format)
- Files saved to `~/Library/Caches/com.encryptedcat.voicenote/`
- Device selection via CoreAudio `AudioObjectGetPropertyData` API
- **Streaming mode**: Timer-based chunk rotation (~1.5s default). Each chunk is a complete WAV file.

### whisper.cpp Integration

The app invokes whisper.cpp as an external process:

```bash
~/whisper.cpp/main -m ~/whisper.cpp/models/ggml-base.bin \
  -f /path/to/recording.wav \
  -l en \
  --no-timestamps \
  -otxt \
  --print-special false \
  --suppress-none
```

Arguments explained:
- `-m` — model file path
- `-f` — input WAV file
- `-l` — language code (`en`, `ru`, `auto`, etc.)
- `--no-timestamps` — omit timestamps from output
- `-otxt` — plain text output (no JSON/CSV/VTT)
- `--print-special false` — no special tokens
- `--suppress-none` — don't suppress any tokens

### Streaming Pipeline

The streaming pipeline runs as an async callback chain:

1. `Timer` fires every `chunkDuration` seconds (default: 1.5s)
2. `AudioRecorder.rotateChunk()` stops current recording, saves WAV, starts new chunk
3. Callback passes chunk URL to `AppState.onStreamingChunk()`
4. `AppState` spawns `WhisperEngine.transcribe()` for this chunk
5. On transcription success → `KeyboardSynthesizer.typeViaPaste(result)`
6. Result text is typed into the currently focused application
7. If transcription fails → chunk skipped, next chunk processed

Each transcription runs in a separate `Process`. Concurrent transcriptions are managed via `DispatchQueue` serialization.

### Hotkey System

Uses `NSEvent.addGlobalMonitorForEvents(matching:)` for:
- `.keyDown` — triggers `startStreaming()`
- `.keyUp` — triggers `stopStreaming()`

The global monitor requires **Accessibility permissions**. Grant in:
System Settings → Privacy & Security → Accessibility → VoiceNote

### Swift 6 Concurrency

The app is built with Swift 6 strict concurrency checking:
- `AppState` is `@MainActor` isolated
- Callbacks from non-isolated contexts (audio recorder, hotkey monitor, whisper process) use `Task { @MainActor in ... }` to cross actor boundaries
- Service closures capture `[weak self]` to avoid retain cycles
- `WhisperEngine` is a plain class with completion callbacks (no actor isolation needed)

## Project Structure

```
voice-note/
├── README.md           ← This file
├── build.sh            ← Build script (swiftc)
├── package.sh          ← Bundle packaging script
├── VoiceNote/          ← Source files
│   ├── main.swift      ← Entry point, menu bar, window mgmt
│   ├── Models/
│   │   └── AppState.swift  ← State, settings, streaming pipeline
│   ├── Services/
│   │   ├── AudioRecorder.swift  ← Audio capture, streaming chunks
│   │   ├── WhisperEngine.swift  ← whisper.cpp subprocess wrapper
│   │   ├── HotkeyMonitor.swift  ← Global keyboard monitoring
│   │   └── KeyboardSynthesizer.swift  ← CGEvent Cmd+V typing
│   ├── Views/
│   │   └── SettingsView.swift   ← SwiftUI settings panel
│   ├── Info.plist                 ← App metadata
│   └── VoiceNote.entitlements    ← Code signing
└── build/              ← Build output (gitignored)
    ├── VoiceNote       ← Raw executable
    └── VoiceNote.app   ← Application bundle
```

## Troubleshooting

**"whisper.cpp binary not found"**
→ Set the correct path in Settings → whisper.cpp → Binary Path. Default: `~/whisper.cpp/main`

**"Model not found"**
→ Download a model manually or select a model in Settings. The app will attempt auto-download.

**"Microphone access denied"**
→ System Settings → Privacy & Security → Microphone → Enable VoiceNote

**Hotkey doesn't work**
→ System Settings → Privacy & Security → Accessibility → Enable VoiceNote
→ Check that no other app is using the same hotkey

**"Transcription returned empty result"**
→ Check microphone input level. Try speaking louder or closer to the mic.
→ Try a larger model (base → small) for better accuracy.
→ In streaming mode, ensure chunks are long enough (at least ~1s of speech)

**Text is not being typed**
→ Make sure the target app has an active text field
→ VoiceNote uses Cmd+V (paste) — the app must support pasting
→ Some security software may block CGEvent keyboard synthesis

**App doesn't appear in menu bar**
→ VoiceNote is an agent app (`LSUIElement = true`). It has no dock icon.
→ Look for the waveform icon (📶) in the top-right menu bar.
→ **Make sure you're running via `open build/VoiceNote.app`**, not the raw binary.
→ Check Console.app for crash logs: filter by process name "VoiceNote"

## Development

### Changing Chunk Duration

Edit `AppState.swift` → `startStreaming()` → change `chunkDuration` value (default: `1.5`).

### Adding a New Language

Edit `SettingsView.swift` → Language Section → add a `Text("Name").tag("code")` entry.

### Changing Default Hotkey

Edit `AppState.swift` → `init()` → change the default `keyCode` value.

Common key codes:
- Space: `0x31`
- Caps Lock: `0x39`
- Any letter: see [Apple Virtual Key Codes](https://apple.stackexchange.com/a/67735)

### Model Research

Why **whisper.cpp** was chosen as the STT engine:

| Criterion | whisper.cpp | faster-whisper | openai-whisper |
|-----------|-------------|----------------|----------------|
| Local execution | ✅ Native C/C++ | ✅ Python + CTranslate2 | ✅ Python + PyTorch |
| Apple Silicon optimized | ✅ Metal backend | ✅ MPS support | ✅ MPS support |
| Binary distribution | ✅ Single binary | ❌ Requires Python env | ❌ Requires Python env |
| Integration complexity | ✅ Subprocess call | ❌ Python interop | ❌ Python interop |
| Startup time | ✅ Instant | ⚠️ Python startup | ⚠️ Python startup |
| Memory efficiency | ✅ Best | ✅ Good | ❌ Heavy (PyTorch) |
| Maintenance | ✅ Active | ✅ Active | ✅ Active |

The decision favored whisper.cpp for its simplicity of integration (subprocess call), instant startup, and minimal dependencies — critical for a lightweight menu-bar app with streaming requirements.

## License

MIT
