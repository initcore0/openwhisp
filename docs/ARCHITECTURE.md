# Architecture

A map of how OpenWhisp is put together. This is a living overview — for the
authoritative list of types, browse the source directly (the counts below drift
as the app grows).

## Layout

| Path | What lives here |
|---|---|
| `OpenWhisp/main.swift` | AppKit entry point (menu-bar agent, no window by default). |
| `OpenWhisp/Services/` | ~150 service types — the whole engine, pipeline, bridge, and store layer. This directory **is** the `OpenWhispCore` SwiftPM target (`Package.swift` points its `path` here), so everything Foundation-only here is reused as-is by the iOS companion. |
| `OpenWhisp/Views/` | AppKit/SwiftUI surfaces: the dictation overlay/HUD, settings, meetings, scratchpad. AppKit-only, not in the core package. |
| `OpenWhisp/Models/` | Shared value types the views bind to. |
| `OpenWhisp/Resources/` | Menu-bar icons and bundled assets. |
| `Sources/OpenWhispBridgeKit/` | The MCP server + persistent bridge client (`MCPServer`, `MCPWire`, `BridgeClient`, `PersistentBridge`). Its own SwiftPM library, also shipped to iOS. |
| `Sources/OpenWhispCLI/` | The `openwhisp` CLI (`setup`, `refine`, `status`, `history`, …) bundled at `Contents/Helpers/`. |
| `Tests/` | `swift test` suites (core, bridge, sync). See [E2E_AUDIO_TESTING.md](E2E_AUDIO_TESTING.md). |
| `third_party/` | whisper.cpp / llama.cpp submodules (built by `scripts/build-*.sh`). |
| `integrations/` | Editor/agent setup helpers. |

## The dictation pipeline

Audio flows from capture to the target app roughly as:

```
AudioCapture → VAD / SilenceAutoStop → TranscriptionEngine
   → SmartFormatter / TranscriptCleaner / Vocabulary
   → (optional) RefineFlow via the local LLM
   → SecureFieldPolicy gate → TextInserter → the frontmost app
```

Key clusters in `OpenWhisp/Services/`:

- **Capture** — `AudioCapture`, `AudioInputRouter`, `AudioDeviceMonitor`, `FileAudioCapture` (fixture-driven, used by the E2E tests).
- **Engines** — `ParakeetStreamingEngine` (default), `WhisperKitEngine` / `WhisperKitStreamingEngine`, `WhisperEngine` (whisper.cpp), `AppleSpeechEngine`. Capabilities and routing: `EngineCapabilities`, `StreamingRoutePolicy`, `LanguageResolver`.
- **Formatting** — `SmartFormatter`, `TranscriptCleaner`, `Vocabulary`, `MetaInstructionStripper`, `PostProcessor`.
- **Refine (LLM)** — `RefineFlow`, `LlamaServerEngine`, `RefineOutputGuard` (the non-Latin translation guard).
- **Privacy** — `SecureFieldPolicy` (password-field detection), `PrivacyStatus`, `AudioRetentionManager`.
- **Insert** — `TextInserter`, `AppleScriptInsert`, plus AX-based correction (`AXCorrectionWatcher`).

## The agent bridge

The differentiator. `AgentBridgeServer` / `AgentBridgeHost` expose OpenWhisp over
a private local socket; `BridgeRouter` and `BridgeWire` carry the protocol;
`AgentClientStore` tracks per-client, per-capability consent. `OpenWhispBridgeKit`
wraps this as an MCP server so any MCP-aware agent can request voice, history, or
refine. See [AGENT_BRIDGE.md](AGENT_BRIDGE.md).

## Stores (the versioned file-format contract)

Profiles, vocabulary, history, config packs, and stats persist as JSON on disk.
These formats are a **contract** shared with the iOS companion — see the note in
[CLAUDE.md](../CLAUDE.md). Relevant types: `AppProfile`, `Vocabulary`,
`TranscriptionHistory`, `ConfigBundle` / `ConfigPack`, `DictationStatsStore`.
