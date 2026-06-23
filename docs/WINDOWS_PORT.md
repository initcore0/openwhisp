# OpenWhisp → Windows Port Feasibility

> A file-by-file assessment of how hard it would be to bring OpenWhisp to Windows.
> Produced from a full read of the codebase. Bottom line first: **don't attempt a
> full pure-Swift Windows port as-is** — the high-leverage move is to extract a
> platform-agnostic core so a Windows app can be a separate, incremental effort.

## Per-file Mac-only dependency inventory

| File | LOC | Apple-only APIs | Windows equivalent | Portability |
|---|---|---|---|---|
| **main.swift** | ~300 | `NSApplication`/`NSApplicationMain`, `NSStatusItem`/`NSStatusBar`, `NSMenu`, `NSWindow`, `NSHostingController`, `NSImage`, `UNUserNotificationCenter`, `AVCaptureDevice` | Tray: `Shell_NotifyIcon` / WinUI; windows/menus: WinUI/Win32; notifications: WinRT toast | **Rewrite** (app shell) |
| **Models/AppState.swift** | ~2050 | `Combine`/`@Published`, `@MainActor`, `UserDefaults`, `Timer`, `AVCaptureDevice`, `NSWorkspace.frontmostApplication`, `NSRunningApplication`, `NSPasteboard`, `Bundle.main` | UserDefaults→registry/JSON; frontmost app→`GetForegroundWindow`+`GetWindowThreadProcessId`; mic perm→none gated | **Split**: ~60% portable logic, ~40% glue |
| **Views/SettingsView.swift** | ~910 | SwiftUI (pure) | SwiftUI not on Windows | **Rewrite UI** |
| **Views/OverlayView.swift** | ~315 | SwiftUI + `NSPanel`/`NSScreen`/`NSColor` | Layered `WS_EX_TOPMOST` window | **Rewrite UI** |
| **Views/OnboardingView.swift** | ~313 | SwiftUI, AVFoundation, ApplicationServices | Rewrite; perm flow mostly disappears | **Rewrite UI** |
| **Services/AudioRecorder.swift** | ~720 | `AVAudioEngine`, `AVAudioRecorder`, `AVAudioConverter`, `AVAudioFile`, **CoreAudio** device enum/default switching | **WASAPI** capture + `IMMDeviceEnumerator`; resample via mix-format/`libsamplerate`. VAD/auto-gain/RMS math is portable | **Rewrite** (largest job) |
| **Services/HotkeyMonitor.swift** | ~255 | `CGEventTap`, `NSEvent` monitors, `CFRunLoop` | `RegisterHotKey` or `WH_KEYBOARD_LL` hook | **Rewrite** (small) |
| **Services/TextInserter.swift** | ~150 | `AXUIElement` (`kAXSelectedTextAttribute`), `CGEvent` Cmd+V, `NSPasteboard`, `AXIsProcessTrusted` | **UI Automation** (`ValuePattern`/`TextPattern`) + `SendInput` Ctrl+V fallback; clipboard via Win32 | **Rewrite** (small) |
| **Services/KeyboardSynthesizer.swift** | ~32 | shim over TextInserter | follows TextInserter | **Rewrite** (trivial) |
| **Services/AppleSpeechEngine.swift** | ~143 | `SFSpeechRecognizer` — **Mac/iOS only** | No good on-device equivalent | **Drop on Windows** (whisper covers it) |
| **Services/SecureFieldDetector.swift** | ~47 | `AXUIElement` role/subrole | UI Automation `IsPassword` | **Rewrite** (trivial; policy already extracted) |
| **Services/KeychainStore.swift** | ~46 | `Security` (`SecItem*`) | **Credential Manager** (`CredWrite`/`CredRead`) or DPAPI | **Rewrite** (trivial) |
| **Services/LaunchAtLogin.swift** | ~58 | `SMAppService` | `Run` registry key / Startup folder / Task Scheduler | **Rewrite** (trivial) |
| **Services/WhisperEngine.swift** | ~725 | **Foundation + Darwin only**: `Process`, `Pipe`, `URLSession`, BSD sockets, `proc_pidpath`/`kill`, `~/Library/Caches`, `sockaddr_in.sin_len` | Mostly portable. Port: `proc_pidpath`+`kill`→`OpenProcess`/`TerminateProcess`; `sin_len` (BSD-only); cache path→`%LOCALAPPDATA%` | **~90% portable**, small `#if os(Windows)` shims |
| **Services/OpenAITranslationService.swift** | ~255 | Foundation only | Fully portable | **Portable as-is** |
| **Services/SmartFormatter / VoiceCommandParser / MetaInstructionStripper / PostProcessor / DownloadProgressFormatter / SecureFieldPolicy / PrivacyStatus** | ~700 | Foundation only (`NSRegularExpression`, etc.) | Portable via swift-corelibs-Foundation | **Portable as-is** (already in `OpenWhispCore`) |
| **Services/Vocabulary / AppProfile / TranscriptionHistory** | ~230 | Foundation; `~/Library/Application Support` path | Portable | **Portable, 1-line path tweak** |

## Portable-vs-platform split

- **Portable today / trivial path tweaks:** ~23% of LOC (the `OpenWhispCore` files + OpenAITranslationService + the portable part of WhisperEngine). whisper.cpp itself is cross-platform C++ (vendored submodule, builds on Windows with CMake) — the ASR engine carries over for free.
- **Pure-logic still tangled inside AppState** (pipeline orchestration, settings model, profile/vocab application): ~17% — salvageable once extracted from Combine/NSWorkspace glue.
- **Genuine platform rewrite:** ~50% — all UI (SwiftUI/AppKit), AudioRecorder, HotkeyMonitor, TextInserter, permissions/keychain/launch, app shell.

So roughly **~40% reusable logic, ~50% platform rewrite, ~10% glue to re-plumb.**

**Key architectural finding:** `AppState` instantiates concrete platform types
directly (`WhisperEngine()`, `AudioRecorder(...)`, `HotkeyMonitor`, `TextInserter`,
`AppleSpeechEngine`, `KeychainStore`, `LaunchAtLogin`) at ~50 call sites — no
protocol seams. The dependency graph is clean (one-directional closure callbacks),
but any port first pays a refactoring tax to introduce abstractions.

## Options & effort

- **(a) Native Swift-on-Windows** (reuse Core, rewrite platform layers in
  Win32/WinUI) — **XL, high risk.** Max code reuse, but **no SwiftUI/AppKit on
  Windows** and immature Swift↔WinUI/COM interop. You'd be pioneering.
- **(b) Cross-platform shell** (Tauri/Electron + the existing whisper binaries) —
  **L–XL.** The `whisper-server` HTTP backend is a gift: the same `/inference`
  endpoint works unchanged. Port only the small regex/string algorithms to TS/Rust
  and get audio/hotkey/insertion/tray from mature crates. Two codebases diverge,
  but lands on battle-tested primitives.
- **(c) Re-architect: platform-agnostic core behind protocols + thin per-OS
  adapters** — **M (refactor) + L (Windows adapters).** ~40% already fits; the
  refactor is mostly mechanical. Windows adapters: WASAPI (audio), `RegisterHotKey`
  (hotkey), UI Automation + `SendInput` (insert), `Shell_NotifyIcon` (tray),
  Credential Manager (secrets). The UI adapter still hits the Swift-on-Windows wall.

## Biggest risks / blockers

1. **Swift UI on Windows is the killer blocker** — no SwiftUI/AppKit; experimental interop.
2. **AudioRecorder is a large CoreAudio→WASAPI rewrite** (resampling + VAD + device handling).
3. **AppleSpeechEngine is dead on Windows** — acceptable; whisper covers transcription.
4. **Text-insertion fidelity** — UI Automation coverage is spottier than macOS AX; leans on the SendInput/clipboard fallback.
5. **No protocol seams today** — ~50 concrete call sites in AppState to abstract first.
6. **Permissions inversion** — much macOS TCC plumbing simply vanishes on Windows (effort discarded, not reused).

## Bottom line

**Do not attempt a full pure-Swift Windows port of the app as-is.** Economics are
poor for a small OSS project: ~50% is platform rewrite, the UI has no Swift path
on Windows, and the toolchain is immature.

**Recommended move: option (c), but stop at the core, not the Windows app.** Spend
**M effort** extracting a platform-agnostic core (pipeline + formatters + parsers +
the WhisperEngine HTTP client behind protocols). This is worthwhile **on its own
merits** for macOS (testability, isolating platform code) and converts "port the
whole app" into "write platform adapters," which a contributor can tackle
incrementally — either linking the Swift core with Win32 adapters, or (more
pragmatically) a Tauri/Electron shell talking to the same `whisper-server` backend.

**Rough total effort to a shipping Windows app:** **L–XL (~6–12 focused weeks)** by
any route, dominated by WASAPI audio + the from-scratch UI. The single
highest-leverage action is the **M-sized core extraction** — see the
["platform-agnostic core" stage in the roadmap](ROADMAP.md).
