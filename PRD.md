Below is a technical architecture for a **native macOS push-to-talk dictation app**, essentially a local-first Wispr Flow-style product. Wispr Flow’s current positioning includes dictation across apps, personal dictionary/style settings, AI edits, shortcut-driven dictation, mouse-button activation, mobile/desktop sync, and 100+ language support, so I would design this as more than “Whisper plus paste.” ([Wispr Flow][1]) ([Wispr Flow][2]) ([App Store][3])

# 1. Product concept

The app lives in the macOS menu bar. The user holds a configurable hotkey, speaks, sees a beautiful floating waveform/transcription window, and the recognized text is inserted into the currently focused text field in any app.

Core behavior:

```text
Hold hotkey -> start mic capture -> stream audio -> transcribe incrementally
Release hotkey -> finalize transcription -> cleanup text -> paste/insert final text
```

Important nuance: **true “paste as words arrive” is harder than it sounds**. You need to avoid duplicating partial hypotheses and avoid corrupting the user’s cursor position. The system should support both:

1. **Preview streaming**: show partial transcript in the overlay while recording.
2. **Live insertion**: insert stable chunks into the focused input as they become reliable.
3. **Final replacement/correction**: optionally replace the last inserted segment with cleaned-up final text.

I would make live insertion configurable because many users prefer final-only paste for accuracy.

# 2. High-level architecture

```text
+-----------------------------+
| Menu Bar App                |
| SwiftUI + AppKit             |
+-------------+---------------+
              |
              v
+-----------------------------+
| App Coordinator             |
| State machine: idle, armed, |
| recording, finalizing, etc. |
+------+------+---------------+
       |      |
       |      v
       |  +----------------------+
       |  | Overlay Window       |
       |  | waveform, transcript |
       |  +----------------------+
       |
       v
+-----------------------------+
| Hotkey Service              |
| CGEventTap / Carbon / NSEvent|
+-------------+---------------+
              |
              v
+-----------------------------+
| Audio Capture Service       |
| AVAudioEngine/CoreAudio     |
| VAD, resampling, buffering  |
+-------------+---------------+
              |
              v
+-----------------------------+
| Streaming ASR Engine        |
| whisper.cpp / Core ML / API |
| partial + final segments    |
+-------------+---------------+
              |
              v
+-----------------------------+
| Text Post-Processor         |
| punctuation, cleanup,       |
| commands, personal vocab    |
+-------------+---------------+
              |
              v
+-----------------------------+
| Text Injection Service      |
| pasteboard, AX, CGEvent     |
+-----------------------------+
```

# 3. Recommended tech stack

## App shell

Use **Swift + SwiftUI + AppKit**.

SwiftUI is good for the settings UI, onboarding, and polished overlay. AppKit is still needed for menu bar behavior, floating panels, event taps, accessibility integration, and reliable window control.

Suggested structure:

```text
App/
  DictationApp.swift
  AppDelegate.swift
  MenuBarController.swift
  AppCoordinator.swift

Core/
  HotkeyService.swift
  AudioCaptureService.swift
  TranscriptionService.swift
  TextInjectionService.swift
  PermissionsService.swift
  SettingsStore.swift

UI/
  SettingsWindow/
  OverlayWindow/
  WaveformView.swift
  ModelDownloadView.swift
  PermissionOnboardingView.swift

Transcription/
  WhisperCppEngine.swift
  AppleSpeechEngine.swift
  CloudTranscriptionEngine.swift
  SegmentStabilizer.swift
  PromptBuilder.swift
  TextPostProcessor.swift
```

## Audio

Use **AVAudioEngine** for real-time mic capture. Apple documents AVAudioEngine as the core API for audio capture, processing, and playback, including real-time capture pipelines. ([Apple Developer][4]) ([Apple Developer][5])

Pipeline:

```text
AVAudioEngine input node
  -> format conversion to 16 kHz mono float32
  -> voice activity detection
  -> ring buffer
  -> waveform amplitude sampler
  -> transcription chunker
```

Recommended audio format for Whisper:

```text
Sample rate: 16,000 Hz
Channels: mono
Format: Float32 PCM
Chunk size: 20 to 100 ms for capture
ASR window: 0.5 to 2.0 seconds incremental
```

## Transcription engine

For local-first:

```text
whisper.cpp
  + ggml/gguf models
  + Metal acceleration
  + optional Core ML encoder
```

Model options:

```text
tiny.en      fastest, lower accuracy
base.en      good default for lightweight mode
small.en     better quality, still reasonable
medium.en    strong accuracy, heavier
large-v3     best quality, slower and big
distil-large-v3  good quality/latency tradeoff
```

I would expose these profiles:

```text
Fast
  model: base.en or small.en
  live insertion: enabled
  cleanup: light

Balanced
  model: small or distil-medium
  live insertion: stable chunks only
  cleanup: enabled

Accurate
  model: medium/large-v3
  insertion: final-only by default
  cleanup: enabled
```

Optional fallback engines:

1. **Apple Speech framework** for a low-setup mode. Apple’s Speech framework supports recognizing words from live or recorded audio, but privacy/network behavior can vary depending on setup and language. ([Apple Developer][6]) ([Apple Developer][7])
2. **Cloud API mode** for better latency/accuracy if the user opts in.
3. **Hybrid mode**: local preview, cloud final rewrite.

# 4. Hotkey design

The user wants “Fn hold to talk.” This is possible-ish, but there are macOS caveats.

## Recommended implementation

Support three hotkey types:

```text
1. Standard global shortcut
   Example: Control + Space, Option + Space, Command + Shift + D

2. Modifier-only push-to-talk
   Example: Fn, Right Option, Right Control

3. Mouse button push-to-talk
   Example: side button on Logitech/MX mouse
```

Wispr Flow recently added non-primary mouse-button binding for push-to-talk and push-on/push-off, so it is worth supporting mouse buttons too. ([Wispr Flow][2])

## Fn key caveat

`Fn` / `Globe` is special on macOS. It is not always delivered like a normal key. You may be able to detect it via `flagsChanged` events and `NSEvent.ModifierFlags.function`, but behavior can differ by keyboard, macOS version, and system settings.

So architect this as:

```swift
enum TriggerMode {
    case holdHotkey(KeyCombo)
    case toggleHotkey(KeyCombo)
    case holdModifier(ModifierKey) // fn, rightOption, rightControl
    case mouseButton(button: Int, behavior: PushToTalkBehavior)
}
```

Implementation choices:

```text
Carbon RegisterEventHotKey
  Good for normal combos.
  Not enough for modifier-only Fn.

CGEventTap
  Needed for modifier-only hold detection, mouse buttons, key up/down.
  Requires Input Monitoring / Accessibility permission.

NSEvent.addGlobalMonitorForEvents
  Simpler, but less reliable for low-level push-to-talk.
```

State machine:

```text
idle
  hotkeyDown -> recording

recording
  hotkeyUp -> finalizing
  escapePressed -> cancel
  timeout -> finalizing

finalizing
  final transcript ready -> paste -> idle
```

# 5. Permissions

You need a first-run onboarding flow that explicitly guides the user through permissions.

Required:

```text
Microphone
  Needed for audio capture.

Accessibility
  Needed to interact with other apps, detect focused UI, and synthesize paste/keyboard events.

Input Monitoring
  Needed for low-level global hotkey/event tap behavior.

Automation
  Possibly needed if using AppleScript/System Events fallback.
```

Apple’s accessibility APIs allow assistive apps to communicate with and control accessible applications on macOS. ([Apple Developer][8])

Do not bury permissions in settings. Make onboarding a checklist:

```text
[ ] Microphone access
[ ] Accessibility access
[ ] Input Monitoring access
[ ] Test hotkey
[ ] Test paste into sample text field
[ ] Download first model
```

# 6. Text insertion strategy

This is one of the most important architectural decisions.

## Option A: Pasteboard + Cmd+V

This is the most reliable across apps.

Flow:

```text
1. Save current focused app.
2. Put transcript chunk into NSPasteboard.
3. Send Cmd+V via CGEvent.
4. Optionally restore previous clipboard.
```

Apple’s `NSPasteboard` is the standard AppKit interface for pasteboard operations. ([Apple Developer][9])

Pros:

```text
Works in almost every text field.
Fast for large chunks.
Handles Unicode well.
```

Cons:

```text
Temporarily touches clipboard.
Restoring clipboard may require reading it, which has privacy implications.
Some apps may block synthetic paste.
```

Important: newer macOS versions have increasing pasteboard privacy behavior, especially around programmatic reads. Even if writes are usually fine, avoid unnecessary clipboard reads. ([Michael Tsai][10])

Recommended behavior:

```text
Default:
  write transcript to pasteboard, paste, do not read/restore old clipboard.

Optional setting:
  "Restore clipboard after dictation"
  Warn that this may require pasteboard read access and may trigger privacy prompts.
```

## Option B: Accessibility insertion

Use `AXUIElement` to inspect focused UI and try setting selected text.

Possible flow:

```text
AXUIElementCreateSystemWide()
  -> kAXFocusedUIElementAttribute
  -> selected text range
  -> set value or selected text
```

Pros:

```text
Can avoid clipboard.
Can theoretically replace partial text cleanly.
```

Cons:

```text
Not universal.
Many apps/custom editors do not expose writable AX text APIs.
Web apps are inconsistent.
Electron apps vary.
```

Use this as an optimization, not the only path.

## Option C: Synthetic typing

Generate key events for every character.

Pros:

```text
Does not use clipboard.
Feels like typing.
```

Cons:

```text
Slow.
Buggy with non-English text, symbols, IMEs, emoji.
Bad for long text.
```

Use only for very small chunks or fallback.

## Recommended insertion policy

```text
Primary:
  pasteboard + Cmd+V

Secondary:
  AX insertion for apps where it works well

Fallback:
  synthetic typing for short text
```

# 7. Live streaming insertion

Naive approach will fail:

```text
partial: "hello"
partial: "hello world"
partial: "hello world this"
```

If you paste every partial, the field becomes:

```text
hello hello world hello world this
```

You need a segment stabilizer.

## Segment model

Represent ASR output like this:

```swift
struct TranscriptSegment {
    let id: UUID
    let text: String
    let startMs: Int
    let endMs: Int
    let confidence: Float
    let isFinal: Bool
}
```

The app maintains:

```text
draftTranscript
stablePrefix
unstableTail
insertedText
```

Only insert text when it becomes stable.

## Stabilization algorithm

Every ASR update:

```text
1. Normalize whitespace.
2. Compare new hypothesis with previous hypothesis.
3. Find longest common prefix.
4. If prefix survived N updates or M milliseconds, mark it stable.
5. Insert only the delta between last inserted stable text and new stable text.
6. Keep unstable tail only in overlay.
```

Example:

```text
Update 1: "I think we should"
stable: ""

Update 2: "I think we should deploy"
stable: "I think we should "

Update 3: "I think we should deploy this today"
insert delta: "I think we should "
overlay tail: "deploy this today"
```

## Final correction

On release:

```text
1. Run final transcription pass over entire audio.
2. Run text cleanup.
3. If live insertion was enabled:
   - either append correction note is bad, do not do this
   - or select/delete last inserted session text and replace with final
4. If final-only:
   - paste final text once
```

Best UX:

```text
Live insertion mode:
  Insert stable chunks while speaking.
  Keep an internal marker of how many chars were inserted.
  On final, if final differs significantly, use Cmd+Shift+Left or AX selected range to replace session text.
```

But cross-app replacement is risky. I would ship:

```text
MVP:
  live preview in overlay
  final paste into active field

v1:
  stable chunk live paste
  no destructive replacement by default

v2:
  app-specific replacement adapters
```

# 8. UI/UX design

## Menu bar

Menu items:

```text
Start Dictation
Pause Listening
Settings
Model Manager
Dictionary
History
Check Permissions
Quit
```

Menu bar icon states:

```text
Idle: subtle monochrome icon
Recording: pulsing red/blue dot
Finalizing: spinner
Error: warning badge
```

## Overlay window

This should be a borderless floating panel above all apps.

Design:

```text
Rounded glass panel
Live waveform
Timer
Current partial transcript
Mic/device indicator
Model/latency badge
Cancel button
```

Layout:

```text
+------------------------------------------------+
|  🎙  Listening...                 00:08        |
|                                                |
|  ▁▂▃▅▇▆▃▂▁▂▃▅▆▇▆▃▂▁                 |
|                                                |
|  "Let's rewrite the deployment plan..."        |
|                                                |
|  Release Fn to insert • Esc to cancel          |
+------------------------------------------------+
```

Use SwiftUI for the view, AppKit for the window:

```swift
NSPanel(
  contentRect: ...,
  styleMask: [.borderless, .nonactivatingPanel],
  backing: .buffered,
  defer: false
)
```

Window behavior:

```text
Always on top
Does not steal focus
Appears near active text cursor when possible
Falls back to center-bottom of active screen
Animates in/out
```

## Waveform

Use the audio capture service to publish RMS/peak values:

```swift
struct AudioLevelSample {
    let rms: Float
    let peak: Float
    let timestamp: TimeInterval
}
```

The waveform renderer should not process raw audio on the main thread. Publish downsampled level data at 30 to 60 fps.

# 9. Settings window

Tabs:

```text
General
Audio
Transcription
Hotkeys
Text Output
AI Cleanup
Dictionary
Privacy
Advanced
```

## General

```text
Launch at login
Show menu bar icon
Show overlay while recording
Play start/stop sounds
Keep dictation history
```

## Audio

```text
Input device selector
Input gain
Noise suppression
Voice activity detection threshold
Silence auto-stop
Test microphone
Waveform preview
```

## Transcription

```text
Engine:
  Local Whisper
  Apple Speech
  Cloud API

Model:
  tiny/base/small/medium/large/distil

Language:
  Auto
  English
  Russian
  Ukrainian
  etc.

Mode:
  Final paste only
  Live stable chunks
  Live aggressive
```

## Hotkeys

```text
Push-to-talk hotkey
Toggle dictation hotkey
Cancel hotkey
Mouse button trigger
Double-tap trigger
```

## Text Output

```text
Paste method:
  Clipboard paste
  Accessibility insert
  Simulated typing
  Auto

After paste:
  Add trailing space
  Add newline
  Do nothing

Capitalization:
  Auto
  Preserve raw
  Sentence case

Punctuation:
  Auto
  Spoken punctuation
  Minimal
```

## AI Cleanup

```text
Fix grammar
Remove filler words
Preserve casual tone
Professional rewrite
Convert to bullet list
Convert to email
Translate before paste
```

## Dictionary

```text
Names
Company jargon
Technical terms
Acronyms
Replacement rules
```

Examples:

```text
"Meaw VPN" not "meow VPN"
"VLESS" not "the less"
"llama.cpp" not "llama dot C P P"
"Coinbase" not "coin base"
```

## Privacy

```text
Local-only mode
Never save audio
Save transcript history
Save audio snippets for debugging
Cloud transcription opt-in
Redact sensitive fields
```

# 10. Features I would add

## 1. Personal dictionary

This is a must-have. Dictation apps become annoying when they repeatedly misrecognize names, acronyms, products, and technical terms.

Implementation:

```text
User dictionary
  -> injected into Whisper prompt
  -> used by post-processor
  -> used by replacement rules
```

Example prompt:

```text
The user often says these terms:
Meaw VPN, VLESS, Reality, Xray, llama.cpp, Coinbase, Saratoga, encrypted_cat.
Prefer these spellings.
```

## 2. Voice commands

Allow spoken commands:

```text
"new paragraph"
"comma"
"period"
"send message"
"make this professional"
"turn this into bullet points"
"translate to English"
"cancel that"
```

Command pipeline:

```text
Raw transcript
  -> command detector
  -> command executor
  -> output text or action
```

Do not execute dangerous actions by default. For example, “send message” should require explicit permission per app or a confirmation.

## 3. Dictation modes

```text
Raw Dictation
  Paste exactly what was said with punctuation.

Clean Dictation
  Remove ums, fix grammar, add punctuation.

Command Mode
  Interpret speech as commands.

Prompt Mode
  User says: "Write a polite reply saying..."
  App outputs polished response.

Translation Mode
  Speak Russian, paste English.
```

## 4. App-specific profiles

Different apps need different behavior.

```text
Slack/Discord:
  casual tone, short messages, paste final only

Gmail:
  professional tone, paragraphs, email cleanup

Cursor/VS Code:
  preserve code terms, no smart quotes, command mode

Terminal:
  never auto-paste unless explicitly enabled
```

## 5. History panel

Show previous dictations:

```text
Timestamp
App name
Transcript
Copy button
Re-run cleanup
Delete
```

Privacy-first default:

```text
History disabled by default or transcript-only, no audio.
```

## 6. “Undo last dictation”

Critical feature.

Implementation:

```text
Track last inserted text length.
On hotkey: remove last inserted text using AX if possible.
Fallback: send Cmd+Z once.
```

The app should store:

```swift
struct InsertionRecord {
    let appBundleId: String
    let timestamp: Date
    let insertedText: String
    let insertionMethod: InsertionMethod
}
```

## 7. Silence detection

When the user releases the hotkey, finalization happens. But also support:

```text
Auto-stop after 2 seconds of silence
Auto-finalize if max duration exceeded
Warn if no voice detected
```

## 8. Meeting/note capture mode

Separate from paste mode:

```text
Record longer session
Transcribe continuously
Summarize
Extract action items
Export Markdown
```

## 9. Multi-language support

Features:

```text
Auto-detect language
Force language
Translate to target language
Mixed Russian/English technical mode
```

## 10. Local LLM cleanup

Use a small local model or cloud model for rewrite:

```text
Raw ASR:
  "hey can you please check the thing with deployment I think maybe the server is not started"

Cleaned:
  "Can you please check the deployment? I think the server may not have started."
```

For speed, make cleanup asynchronous and optional.

# 11. Data model

## Settings

```swift
struct AppSettings: Codable {
    var launchAtLogin: Bool
    var showOverlay: Bool
    var selectedInputDeviceId: String?
    var hotkey: HotkeyConfig
    var triggerMode: TriggerMode
    var transcriptionEngine: EngineConfig
    var outputConfig: OutputConfig
    var cleanupConfig: CleanupConfig
    var privacyConfig: PrivacyConfig
}
```

## Engine config

```swift
struct EngineConfig: Codable {
    var engine: TranscriptionEngineKind
    var modelId: String
    var language: String?
    var useMetal: Bool
    var useVAD: Bool
    var beamSize: Int
    var temperature: Float
    var initialPrompt: String
}
```

## Output config

```swift
struct OutputConfig: Codable {
    var insertionMode: InsertionMode
    var pasteTiming: PasteTiming
    var restoreClipboard: Bool
    var addTrailingSpace: Bool
    var smartPunctuation: Bool
    var spokenPunctuation: Bool
}
```

# 12. Transcription pipeline details

## Recording session lifecycle

```text
onHotkeyDown:
  capture current focused app/input metadata
  start audio engine
  start waveform stream
  start ASR session
  show overlay

whileRecording:
  receive audio buffers
  run VAD
  append speech audio to ring buffer
  send chunks to ASR
  receive partial transcript
  update overlay
  optionally paste stable chunks

onHotkeyUp:
  stop accepting new audio
  flush ASR
  run final transcription
  post-process text
  paste final text
  hide overlay
  store history record
```

## Threading

Use separate queues:

```text
MainActor:
  SwiftUI state, settings UI, overlay UI

Audio queue:
  AVAudioEngine callbacks, ring buffer writes

ASR queue:
  Whisper inference

Text queue:
  cleanup, command parsing

Injection queue:
  pasteboard/CGEvent operations
```

Avoid doing inference on the audio callback thread.

# 13. Whisper streaming strategy

Whisper is not naturally token-streaming in the same way as an LLM. For good UX:

```text
1. Capture continuous audio.
2. Keep rolling audio window.
3. Run inference every 500 to 1000 ms.
4. Use VAD to split utterances.
5. Stabilize repeated prefixes.
6. Finalize on release.
```

Pseudo-flow:

```swift
func processAudioLoop() async {
    while session.isRecording {
        let window = audioBuffer.last(seconds: 8)
        let result = await whisper.transcribe(window, prompt: contextPrompt)
        let stable = stabilizer.update(result.text)

        await MainActor.run {
            overlay.partialText = result.text
        }

        if settings.liveInsertion {
            let delta = stable.deltaSinceLastInsert
            if !delta.isEmpty {
                await textInjector.insert(delta)
            }
        }

        try await Task.sleep(for: .milliseconds(700))
    }
}
```

# 14. Security and privacy

Principles:

```text
Local-first by default.
No audio leaves device unless cloud mode is explicitly enabled.
No transcript history unless enabled.
No clipboard read unless "restore clipboard" is enabled.
Clear indicator while mic is active.
```

Sensitive app detection:

```text
Do not auto-paste into:
  password fields
  secure text fields
  Terminal unless enabled
  banking apps unless enabled
```

Use Accessibility metadata where possible to detect secure fields.

# 15. Failure cases

Handle these explicitly.

## No focused text field

Behavior:

```text
Show overlay transcript.
Copy final text to clipboard.
Show: "No text field detected. Transcript copied."
```

## Hotkey blocked

Behavior:

```text
Show permission repair screen.
Offer alternative hotkey.
```

## Model too slow

Behavior:

```text
Warn user.
Suggest smaller model.
Disable live insertion.
```

## Clipboard paste failed

Behavior:

```text
Fallback to simulated typing for short text.
Otherwise copy transcript to clipboard and show notification.
```

## User changes focused app mid-dictation

Configurable:

```text
Lock target app on hotkey down
or
Paste wherever focus is on release
```

Default should be **lock target app**.

# 16. Implementation milestones

## Milestone 1: MVP

```text
Menu bar app
Settings window
Microphone permission
Accessibility/Input Monitoring onboarding
Configurable normal hotkey
Record while held
Final transcription with local whisper.cpp
Paste final text into active app
Simple overlay with timer and waveform
```

## Milestone 2: Better UX

```text
Model manager
Input device selector
Partial transcript preview
VAD
Cancel hotkey
History
Clipboard behavior settings
Launch at login
```

## Milestone 3: Flow-like intelligence

```text
Personal dictionary
AI cleanup
App-specific profiles
Translation mode
Spoken commands
Mouse button push-to-talk
Modifier-only hotkeys including Fn where supported
```

## Milestone 4: Live insertion

```text
Stable chunk streaming
Segment stabilizer
Per-app insertion adapters
Undo last dictation
Final correction strategy
```

## Milestone 5: Pro features

```text
Cloud sync
Mobile companion
Team dictionaries
Shared style profiles
Admin privacy controls
Meeting mode
Programmable voice automations
```

# 17. Biggest technical risks

## Risk 1: Fn hotkey reliability

Mitigation:

```text
Support Fn, but do not make it the only option.
Also support Control/Option/Command combos and mouse buttons.
Explain in UI when Fn is unavailable.
```

## Risk 2: Universal paste is messy

Mitigation:

```text
Use pasteboard + Cmd+V as primary.
Add AX insertion where reliable.
Keep final-only paste as default.
```

## Risk 3: Real-time Whisper latency

Mitigation:

```text
Use smaller model for live mode.
Use rolling windows.
Use VAD.
Use Metal.
Separate preview from final transcription.
```

## Risk 4: Privacy trust

Mitigation:

```text
Local-first.
Clear mic indicator.
No audio retention by default.
Transparent cloud opt-in.
No clipboard read by default.
```

# 18. Recommended MVP defaults

```text
Engine: local whisper.cpp
Model: small.en or base.en
Language: auto or system language
Hotkey: Control + Space hold
Fn: available as experimental
Paste mode: final paste only
Overlay: enabled
Clipboard restore: disabled
History: disabled
VAD: enabled
Cleanup: light punctuation only
```

# 19. Final architecture recommendation

Build it as a **native Swift/AppKit menu bar app** with a modular pipeline:

```text
HotkeyService
  -> AudioCaptureService
  -> TranscriptionService
  -> TranscriptStabilizer
  -> TextPostProcessor
  -> TextInjectionService
  -> Overlay/UI
```

Do **not** start with live paste as the default. Start with **live overlay plus final paste**, then add stable-chunk live insertion once the transcription and insertion pipeline is reliable.

The key to making it feel like Wispr Flow is not just Whisper. It is the combination of:

```text
fast hotkey activation
beautiful non-intrusive overlay
excellent text cleanup
personal dictionary
reliable insertion
app-specific behavior
privacy-first defaults
undo/cancel safety
```

That is the difference between a demo and something people can use all day.

[1]: https://wisprflow.ai/?utm_source=chatgpt.com "Wispr Flow | Effortless Voice Dictation"
[2]: https://wisprflow.ai/whats-new?utm_source=chatgpt.com "What's new"
[3]: https://apps.apple.com/au/app/wispr-flow-ai-voice-keyboard/id6497229487?utm_source=chatgpt.com "Wispr Flow: AI Voice Keyboard - App Store - Apple"
[4]: https://developer.apple.com/documentation/avfaudio/avaudioengine?utm_source=chatgpt.com "AVAudioEngine | Apple Developer Documentation"
[5]: https://developer.apple.com/videos/play/wwdc2019/510/?utm_source=chatgpt.com "What's New in AVAudioEngine - WWDC19 - Videos"
[6]: https://developer.apple.com/documentation/speech?utm_source=chatgpt.com "Speech | Apple Developer Documentation"
[7]: https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition?utm_source=chatgpt.com "Asking Permission to Use Speech Recognition"
[8]: https://developer.apple.com/documentation/applicationservices/axuielement_h?utm_source=chatgpt.com "AXUIElement.h | Apple Developer Documentation"
[9]: https://developer.apple.com/documentation/appkit/nspasteboard?utm_source=chatgpt.com "NSPasteboard | Apple Developer Documentation"
[10]: https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/?utm_source=chatgpt.com "Pasteboard Privacy Preview in macOS 15.4"

