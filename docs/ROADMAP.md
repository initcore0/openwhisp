# OpenWhisp — Research & Roadmap

> Strategy doc from a multi-agent research pass (competitive landscape, feature-gap
> analysis, plugin architecture, UX/growth) synthesized into a prioritized plan.
> Code-level claims were verified against the source. Competitor pricing/features
> move fast — treat those as ~2025-era and verify before citing publicly.

---

## 1. Executive summary

OpenWhisp occupies a **rare quadrant**: fully local transcription **+** local-LLM
cleanup **+** MIT **+** free **+** hackable. Only **VoiceInk** is close (and it's
GPL and more polished), so our wedge is **MIT licensing, the lower-level config
surface, and provable zero-egress privacy** — not "local and open source" alone.

**Strategic stance:** don't fight Wispr Flow or Aqua Voice on cloud-AI cleanup
quality — we'll lose. Own **"the dictation app a compliance team can approve"**:
private by architecture, free forever, forkable.

**Before any new features, fix three verified issues** (see §4): a secure-field
password leak, a hung-looking model download, and outdated Gatekeeper install docs.

---

## 2. Competitive landscape

| Product | Model | Local? | Open? | Where it beats us | Where we beat it |
|---|---|---|---|---|---|
| **Wispr Flow** | Cloud, subscription (~$12–15/mo) | ❌ | ❌ | Best-in-class AI cleanup, auto-format-to-context, cross-platform (mac/win/iOS), low-latency "reads my mind" editing | Privacy (audio never leaves device), price (free), hackability |
| **VoiceInk** ⚠️ closest rival | Local + opt. cloud LLM, lifetime license (~$19–29) *or* build free | ✅ | ✅ GPL-3.0 | More polished UI, active community, parakeet models, iOS-adjacent | **MIT** (more permissive for forks/companies), warm whisper-server HTTP mode, output-mode trifecta, voice-command meta-instructions |
| **Superwhisper** | Local + cloud, freemium/sub (~$8.49/mo) or lifetime (~$200) | ✅ | ❌ | Polish, "modes", **iOS app** | Free/open vs paid/closed |
| **MacWhisper** | Local + cloud, one-time (~$59) | ✅ | ❌ | **File/meeting transcription**, diarization, subtitles | Free/open; push-to-talk dictation focus |
| **Aqua Voice** | Cloud, sub | ❌ | ❌ | Smart voice-native editing | Privacy, price |
| **Talon** | Local, free + Patreon beta | ✅ | partial | Full hands-free **computer control**, scripting (RSI/accessibility) | We're a typist, not a controller — different lane |
| **Apple Dictation** | On-device, free, system-deep | ✅ | ❌ | Free, zero-install, system-wide | Accuracy (large-v3), formatting, vocab, per-app modes, history, LLM cleanup |

**Key takeaways**
- **VoiceInk is the real comparison**, not Wispr. Our claimed differentiators
  (local, no-subscription, hackable) are *not unique vs VoiceInk*. Differentiate
  on the margin: **MIT vs GPL**, warm `whisper-server`, the
  preview/liveChunks/finalOnly granularity, voice commands, and a lower-level
  config surface.
- **Don't chase MacWhisper's file/meeting transcription** or Superwhisper's iOS
  app — those dilute identity for a small project.
- **Target the power/privacy/accuracy user**, not the casual one (Apple Dictation
  is "good enough" for casual and is system-deep + free).

### Positioning angles the cloud leaders structurally cannot copy
1. **Privacy by architecture** — audio never leaves the device, *provable* because
   the source is open. (Subscription SaaS can't match this without changing its model.)
2. **Zero subscription, forever** — free + MIT.
3. **Deep hackability/scriptability** — plugins, presets, scriptable post-processing
   that closed SaaS won't ship (it cannibalizes their pricing).

---

## 3. Current feature inventory (baseline)

Engines: whisper.cpp (CLI + warm HTTP server) and Apple Speech · models tiny→large-v3
· 12 languages + auto + translate-to-English · output modes preview / finalOnly /
liveChunks · pause-based VAD · Accessibility insert + paste fallback · auto-gain ·
SmartFormatter (caps/punct/filler/spoken-punctuation) · custom vocabulary
(bias + substitutions) · optional LLM post-processing (OpenAI **or** local
llama.cpp/Ollama) · voice commands · per-app profiles · transcription history ·
onboarding · launch-at-login · "Quiet Glass" overlay with live transcript.

---

## 4. ✅ Verified issues — FIXED (were the Phase 0 gate)

Found by reading the code during research, confirmed, and **all three now fixed**
(PRs #34/#35/#36):

1. **Secure-field password leak (critical) — ✅ fixed (#35).** Now detects a focused
   secure field via the Accessibility API (`AXSecureTextField` subrole) and refuses
   to record / insert / persist; fail-open on AX errors, fail-safe on a positive
   match. Pure `SecureFieldPolicy` + 14 unit tests.
2. **Model download looked hung (critical for activation) — ✅ fixed (#36).** Added
   `didWriteData` progress (percent + "X / Y MB"), a determinate bar in onboarding
   and settings, a Retry on failure, and **defaulted first-run to the tiny model
   (39 MB)** for near-instant first success. Pure `DownloadProgressFormatter` +
   11 unit tests.
3. **Outdated Gatekeeper install docs (high) — ✅ fixed (#34).** README + release-
   notes template now give the macOS 15+ path (System Settings → Privacy &
   Security → *Open Anyway*, or `xattr -dr com.apple.quarantine`) and explain the
   ad-hoc signing.
   → Fix README + `release.yml`, and state *why* the app is unsigned.

---

## 5. Feature gaps (independent of plugins)

| Gap | Class | Effort | Notes |
|---|---|---|---|
| **Voice editing / undo** ("scratch that", edit-before-commit in the overlay) | differentiator | L | `VoiceCommandParser` only does trailing LLM transforms today. |
| **Whisper streaming partials** | table-stakes | L | Only Apple Speech emits live partials; whisper preview shows chunked text at finalize. whisper.cpp supports streaming. |
| **Hotkey remap + toggle / hands-free mode** | table-stakes | M | Hardcoded to Fn / Control+Space, hold-only. No remap, no toggle for long dictation. |
| **Insert verification + secure-field** | table-stakes | M | AX→Cmd+V fails silently in terminals/VNC/Electron/web fields; no verify, no secure-field guard (see §4). |
| **Richer formatting + deeper vocab** | nice-to-have | L | No lists/markdown/code/number formatting; casing English-only; vocab is exact-match subs and can overflow whisper's ~224-token prompt. |

---

## 6. Plugin support — design

### Recommendation (decisive)
Build on the **existing `PostProcessor` protocol** — do **not** add a SwiftPM /
dynamic-library plugin API. In-process third-party code is unacceptable in an app
that holds **Accessibility + clipboard** rights (keylogging / clipboard-exfil
risk). Lead with **Class A (text post-processors)**, then **Class C (backend
presets)**, then **Class B (output targets)**. Defer STT plugins and any
sandboxed-process system until there's real demand.

**P0 prerequisite (also pays down debt):** the `PostProcessorChain` in
`PostProcessor.swift` is currently **unused** — `AppState.postProcess()` hardcodes
its stages and the AI step runs separately via `processFinalText`. Wire one real
chain (`VocabularySubstitutor` → `SmartFormatter` → `AIPostProcessor` wrapping
`OpenAITranslationService`) so plugins have a single place to drop in. This also
helps decompose the ~1900-line `AppState`.

### Class A — Text post-processors
Transforms on the transcript: custom LLM prompts, scripts, regex/format rules,
AI "actions" (summarize, make-a-commit-message, translate-to-X).

**User stories**
- *As a developer*, I want a "format as a git commit message" action so dictating
  a change description yields a ready-to-paste commit.
- *As a writer*, I want a saved "make concise" prompt so I can clean rambling
  drafts without re-typing the instruction each time.
- *As a privacy-conscious user*, I want my custom prompt to run against my **local**
  LLM so the action never touches the cloud.
- *As a power user*, I want to pipe the transcript through **my own script**
  (stdin → stdout) so I can do anything (call an API, run a formatter, look up a
  term) without waiting for a built-in feature.
- *As a multilingual user*, I want a one-tap "translate to Spanish" action bound
  to a profile.

Plugin contract: receive `{text, language, targetAppBundleID, isLiveChunk}`;
return transformed `text`. (Mirrors the existing `PostProcessor` protocol.)

### Class B — Output / integration targets
Send the result somewhere besides the focused app.

**User stories**
- *As a note-taker*, I want dictations appended to a daily **Markdown file** in my
  notes vault.
- *As an Obsidian/Notion user*, I want the transcript sent to a specific note via
  the app's API / a webhook.
- *As an automation user*, I want to fire a **macOS Shortcut** with the transcript
  as input so I can route it anywhere.
- *As a task manager*, I want "remind me to…" dictations sent to Things/Reminders
  instead of typed.

Plugin contract: an `OutputTarget` protocol (today there's exactly one sink:
`TextInserter`). Targets: file, webhook, clipboard-as-format, Shortcuts, app APIs.

### Class C — Engine / backend plugins
Pluggable STT or LLM backends.

**User stories**
- *As a user with a preferred local model server*, I want to point cleanup at
  **Ollama / llama-server / any OpenAI-compatible endpoint** via a preset.
- *As an experimenter*, I want to try a different STT engine (e.g. parakeet)
  without forking.

Reality: LLM backends are **nearly free** — they're presets over the existing
`LLMEndpoint` (just URL + model + auth). STT engine plugins are the
lowest-priority, highest-effort item; defer.

### Architecture options weighed
| Option | Security | Distribution | Effort | Verdict |
|---|---|---|---|---|
| Config-only "packs" (prompt presets, rule packs, profile/vocab JSON) | ✅ no code runs | easy (share JSON / Discussions) | S–M | **Do first** |
| `ScriptPostProcessor` (stdin→stdout, timeout, opt-in, default-deny) | ⚠️ runs user's own code, sandbox via opt-in | easy (share a script) | M | **Do (P2)** — power-user wedge |
| macOS Shortcuts integration | ✅ OS-mediated | easy | M | **Do (P3)** as an output target |
| Manifest + sandboxed external process | ⚠️ contained | medium | L–XL | Only on demand |
| SwiftPM / dylib in-process plugins | ❌ unacceptable (keylog/exfil) | hard | XL | **Reject** |

Principles: **default-deny, fail-open** (a failing plugin must never block a
dictation — fall back to the raw text), and **declare network use** per plugin.

---

## 7. UX & open-source growth

- **Activation:** the model-download progress fix (§4) is the #1 leak. Also tighten
  onboarding — it currently never blocks and only checks mic + `AXIsProcessTrusted`,
  so a user can reach the "try it" step with a **dead hotkey** (Input Monitoring
  not granted). Add a live Input-Monitoring check + inline fix.
- **Discoverability:** voice commands, per-app modes, vocabulary, and output modes
  live only in Settings. Add a "What's next" card after onboarding, rotate overlay
  hints for the first ~10 sessions, and a "Tips & Commands" menu item.
- **Trust signaling (the moat):** add a **network indicator** derived from
  `llmProvider` ("No network used" vs "Sends text to OpenAI"), and a README
  "verify it yourself" note (`nettop`; WAVs are deleted per transcription —
  already true in code).
- **OSS scaffolding:** add `SECURITY.md` (privacy is the moat), `ISSUE_TEMPLATE`
  (macOS version, chip, model, engine CLI-vs-server, log lines),
  `PULL_REQUEST_TEMPLATE`, and `CONTRIBUTING.md`.
- **Demo:** add a looping **GIF** of the overlay above the README highlights — it's
  the single best demo asset and there's currently no visual media.
- **Community sharing:** profiles, vocab, and prompts are exactly what a community
  trades — add **JSON import/export** and seed a presets folder / pinned
  Discussions thread.

---

## 8. Prioritized roadmap

### Phase 0 — Trust & safety ✅ DONE
- ✅ Detect `AXSecureTextField` → refuse to record / insert / persist (#35).
- ✅ `didWriteData` progress + Retry; first-run defaults to **tiny** (#36).
- ✅ Gatekeeper install docs fixed in README + `release.yml` (#34).

### Phase 1 — Positioning & proof *(mostly ✅)*
- ✅ Tagline locked (Wispr-style, fully on-device, free, open source).
- ⬜ Demo GIF *(deferred — needs a screen recording)*.
- ✅ Network/privacy indicator in Settings → Status + "verify it yourself" note.
- ✅ `SECURITY` / `CONTRIBUTING` / issue + PR templates added.

### Phase 2 — Wire the chain *(plugin prerequisite + tech-debt paydown)*
- Replace the hardcoded stages in `postProcess()` and the separate
  `processFinalText` path with one `PostProcessorChain`.
- Wrap `OpenAITranslationService` as an `AIPostProcessor`.
- Extract the pipeline out of `AppState`.
- *(This is also step 1 of the platform-agnostic core below — the post-processing
  chain is the first piece of the OS-independent core.)*

### Phase 2.5 — Platform-agnostic core *(unblocks plugins AND a future Windows port)*

Per the [Windows feasibility study](WINDOWS_PORT.md): ~40% of the code is already
OS-independent logic, but `AppState` wires **concrete** platform types at ~50
sites with no seams. Extracting protocols + moving the orchestration into a core
makes the macOS app more testable **and** converts "port the whole app" into
"write platform adapters." Do this incrementally; no behavior change.

**Status:** all six I/O service seams are extracted and injected (✅ below) —
secrets, launch-at-login, text output, hotkeys, transcription (file + streaming),
and audio capture. Each concrete macOS type now conforms to a Foundation-only
protocol in `OpenWhispCore`, AppState holds the protocol type and injects the
macOS adapter via its initializer, and test doubles exist for every seam. What
remains is the app-shell / UI layer (`MenuBarUI`, `Permissions`), which the
[Windows study](WINDOWS_PORT.md) classes as a full per-OS rewrite rather than a
seam, plus optionally lifting more orchestration out of `AppState`.

- Define platform protocols and dependency-inject them into `AppState` instead of
  constructing concrete types:
  - ✅ `SecretStore` (Keychain → Credential Manager) — extracted; `AppState`
    injects it, `InMemorySecretStore` covers the logic in `swift test`.
  - ✅ `FileTranscriptionEngine` (whisper CLI/server) + `StreamingTranscriptionEngine`
    (Apple Speech) — extracted as two focused protocols (the engines have different
    request/response vs. streaming shapes); `AppleSpeechEngine`'s permission statics
    stay concrete (they return platform types). `WhisperBackend` moved to the core;
    fakes added for both.
  - ✅ `AudioCapture` (AVAudioEngine today → WASAPI on Windows) — extracted;
    `AppState` injects it, `RecorderState` moved to the core, the dead AppState
    back-ref removed. The CoreAudio `AudioDevice` enumeration stays concrete.
    Adversarially reviewed (it's the audio pipeline) — body byte-identical.
  - ✅ `TextOutput` (AX + Cmd+V → UI Automation + SendInput) — extracted;
    `AppState` injects it, `InsertionMode` moved to the core, the
    `KeyboardSynthesizer` shim removed, and a `SpyTextOutput` double unlocks
    paste/clipboard assertions in `swift test`.
  - ✅ `HotkeyControlling` (CGEventTap → RegisterHotKey) — extracted; `AppState`
    injects it and receives gestures via callbacks (incl. a new `onCancel` so the
    monitor no longer reaches into `AppState`). The press/release edge logic moved
    to a pure, unit-tested `HotkeyGesture`.
  - ✅ `LaunchAtLoginService` (SMAppService → Run-key/Task Scheduler) — extracted;
    `AppState` injects it, and the toggle re-sync logic moved to a pure,
    unit-tested `LaunchAtLoginReconciler`.
  - `MenuBarUI` / app shell, `Permissions`
- Move the pipeline + post-processing + profile/vocab application out of `AppState`
  into `OpenWhispCore` (the existing SwiftPM target), behind those protocols.
  - ✅ `LiveChunkPipeline` — the live-chunk ordering/sequencing state machine
    (sequence assignment, concurrency cap, out-of-order reorder buffer, insertion
    gate, drain detection) extracted as a pure, unit-tested struct. AppState keeps
    the side effects (transcribe/insert/file IO) and delegates the bookkeeping.
    Adversarially reviewed — behavior-identical.
- Keep the macOS implementations as the first set of adapters. A Windows app then
  becomes "implement the adapters" (or a Tauri/Electron shell on the same
  `whisper-server` HTTP backend) — a separate, incremental community effort.
- **A full Windows port stays out of scope for the core team** (L–XL); this stage
  only makes it *possible* without a rewrite.

### Phase 3 — Hackability *(the wedge)* — ✅ complete
- ✅ **Refine with a follow-up instruction (double-tap)** — *replaces* the old
  named-voice-actions system. Dictate, double-tap the hotkey, and speak a
  natural-language instruction the LLM applies to the just-dictated text (e.g.
  "make it a Telegram post"). No hardcoded phrases, wake words, or per-app prompt
  config — the LLM interprets plain language in any language, which works far
  better with the rephrase pipeline than the old phrase-matching. The double-tap is
  an explicit command that bypasses the rephrase/translate setting. Pure decision
  logic in `InstructionChain` (OpenWhispCore, unit-tested). Removed:
  `VoiceCommandParser`, `VoiceAction`/registry/editor, the Telegram/Tweet built-ins
  and packs, and the wake-word setting.
- ✅ **Refine your selection** — the same double-tap gesture works on text
  SELECTED in any app, with no dictation: highlight text, double-tap, speak an
  instruction, and the selection is replaced in place with the LLM's result.
  Selection is read via Accessibility (`SelectionReader`, `kAXSelectedTextAttribute`)
  with a synthesized-⌘C clipboard fallback (previous clipboard restored). Dictation
  takes priority; secure/password fields are never read. Reuses the entire refine
  pipeline — the selection just becomes "step-1 text".
- ✅ **JSON import/export** for profiles / vocab / prompts — versioned, tolerant
  `ConfigBundle` (OpenWhispCore, unit-tested); Settings → Backup & Sharing.
  Partial bundles supported (import touches only the sections present), which is
  the foundation packs reuse.
- ✅ **Config packs** (config-only) — named `ConfigPack` bundles shipped in
  Resources/packs (Developer Vocabulary, Punchy Telegram Posts), applied one-click
  via the same import path. Pure `ConfigPack.parseAll` (sort/dedup/skip-bad) is
  unit-tested, and a test loads the shipped packs so an authoring typo fails CI.
- ✅ **Script post-processor** (stdin→stdout, opt-in, timeout, fail-open) — pipe
  the final transcript through a user-chosen executable just before insertion.
  Off by default; ~2s timeout; any error/timeout/empty output keeps the original
  text. Pure `ScriptOutcome`/`ScriptPathValidator` (decision + validation) unit-
  tested; the `Process`/timeout glue (`ScriptRunner`) verified end-to-end.

### Phase 4 — Output & ergonomics
- `OutputTarget` protocol: file / webhook / Notion / Things / Shortcuts.
- LLM backend **presets** on `LLMEndpoint` (Ollama / llama-server / OpenAI).
- Insert-verification; remappable hotkey + toggle mode.

### Phase 5 — Bigger bets *(valuable, large)*
- Whisper streaming partials. See the [ASR alternatives study](ASR_ALTERNATIVES.md)
  for the on-device streaming options (WhisperKit pilot, sherpa-onnx+T-one for
  Russian) and why the Python AlignAtt projects (incl. SimulStreaming) aren't
  shippable in a signed `.app`.
- Voice editing / undo ("scratch that", edit-before-commit).
- Richer formatting (lists/markdown/code/numbers) + deeper vocab.
- **Out of scope (for the core team):** a full Windows/Linux app and
  file/meeting transcription — they dilute identity for a small project. Note the
  Phase 2.5 core extraction *enables* a community Windows port without committing
  the core team to building one (see [WINDOWS_PORT.md](WINDOWS_PORT.md)).

---

*Generated from multi-agent research; code claims verified against source.
Revisit competitor pricing/features before external use.*
