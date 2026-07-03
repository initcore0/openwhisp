# OpenWhisp Settings — UX Redesign Spec

A ground-up reorganization of the Settings window based on the full inventory in `SETTINGS.md`.
Scope: information architecture, layout, copy, component patterns, and a handful of default/behavior
recommendations. Every existing control is accounted for in the migration map (§7). Persistence keys
are unchanged unless explicitly flagged.

---

## 1. What's wrong today (audit)

**1. "Basic vs. Advanced" is not an information architecture.** It groups settings by *how scary they
are*, not by what the user is trying to do. The result: the same conceptual domain is split across
tabs — model selection ("Quality") is Basic while the engine that determines which models exist is
Advanced; "Text Output" is Basic while "Smart Formatting" (which also shapes the output text) is
Advanced. Users hunting for "why does my text look like X" have to check both tabs.

**2. The Refine feature is split in half.** The key binding lives in Basic → Hotkey; the enable
toggle and its LLM dependency live in Basic → AI Post-processing. A user who finds one half has no
path to the other. One feature should live in one place.

**3. Model management exists in four places.** Quality tiers (Basic), the full Whisper Model picker
(Advanced → Model), WhisperKit per-model rows (Basic → Quality), and the Storage section (Advanced)
all manage the same artifacts. "Open Models Folder" appears three times. Two different pickers write
the same `modelName` key. This is the single biggest consolidation win.

**4. Cross-tab side effects.** Changing Engine (Advanced) silently swaps what the Basic tab's
Quality section shows, and switching to WhisperKit silently snaps `outputMode` from `liveChunks` to
`preview` with no explanation. Invisible state changes erode trust.

**5. Default/UI mismatches.**
- `modelName` defaults to `tiny`, which is *not* one of the three Quality tiers — a fresh
  whisper.cpp install shows a synthetic "Custom (tiny)" row as its default state. A default should
  never look like an exception.
- The default push-to-talk key is labeled "(experimental)". A default cannot be experimental —
  either it's stable (drop the label) or it shouldn't be the default.
- `llmProvider` defaults to `openai` (needs an API key) while the product's positioning is
  local/private. First-enable should work with zero setup.

**6. Conflated controls.** "English — Whisper translate to English" overloads the language picker:
it's simultaneously a language *hint* and a *task switch* (transcribe vs. translate). Two concepts,
one control, confusing label.

**7. Overlapping clipboard semantics.** Insertion method "Automatic (keep clipboard)" claims to keep
the clipboard, while a separate "Restore clipboard after paste" toggle defaults to **off**. Which is
it? The copy and the defaults contradict each other.

**8. Sensitive data in the wrong place.** Transcription history — the most privacy-sensitive thing
the app stores — is buried mid-way down Advanced. Permissions and the privacy indicator sit at the
very bottom. For a dictation app, privacy is a headline, not a footnote.

**9. Inconsistent vocabulary.** The same concept is called "Transcription Quality," "Active Model,"
and "Whisper Model." Provider parentheticals mix axes: "(offline)" / "(cloud)" / "(private)". Test
buttons have three different labels. Consistent vocabulary is how people learn an interface.

**10. Missing affordances.** No "reset to defaults" anywhere. No search. "Refresh Devices" is a
manual button for something CoreAudio can notify about.

---

## 2. Design principles

1. **Organize by the pipeline, not by difficulty.** A dictation app has a natural mental model:
   *you speak → it transcribes → it cleans up → it lands in your app*. The panes mirror that.
2. **One feature, one home.** Refine, models, history — each lives in exactly one place.
3. **Progressive disclosure inside a pane, never across tabs.** Power options collapse under
   disclosures *next to* their basic counterparts, so discovery is one click, not a tab hunt.
4. **Disable and explain rather than hide** when the option's existence matters (e.g., Live typing
   under WhisperKit). Hide only what is truly meaningless in context (e.g., model list under Apple
   Speech). Pane *set* in the sidebar never changes; only groups within a pane adapt.
5. **Name things by what people control**, in active voice, with one verb per action across the app
   (Download, Remove, Test, Reveal in Finder, Choose…).
6. **State privacy consequences at the point of choice** (cloud vs. on-device), and give sensitive
   data (history, permissions) a first-class home.

---

## 3. Window structure

Replace the two-tab window with a **sidebar + detail** layout (`NavigationSplitView`), the pattern
of macOS System Settings and modern utilities. Each pane is a grouped `Form`
(`.formStyle(.grouped)`), scrolling independently. Sidebar ~200 pt, detail ~540 pt; minimum window
≈ 760 × 540. The permission banner remains global, pinned above the detail area, and deep-links to
the Privacy pane.

```
┌───────────────────────────────────────────────────────────────────┐
│ ● ● ●                     OpenWhisp Settings                      │
├───────────────┬───────────────────────────────────────────────────┤
│ ⚠ Banner (only when a permission is missing — links to Privacy)   │
├───────────────┼───────────────────────────────────────────────────┤
│  ⚙  General   │   Models                                          │
│  🎙  Dictation │  ┌─────────────────────────────────────────────┐  │
│ ▸🧠  Models    │  │ ENGINE                                      │  │
│  ✨  Cleanup   │  │ ◉ WhisperKit (CoreML) · Recommended         │  │
│  📤  Output    │  │   Optimized for Apple Silicon               │  │
│  🗂  Per-App   │  │ ○ Whisper Local (whisper.cpp)               │  │
│  🔒  Privacy   │  │   Most models · supports live typing        │  │
│  🛠  Advanced  │  │ ○ Apple Speech                              │  │
│               │  │   Built into macOS · instant, no downloads  │  │
│               │  └─────────────────────────────────────────────┘  │
│               │  ┌─────────────────────────────────────────────┐  │
│               │  │ MODEL                                       │  │
│               │  │ ○ Fast        base · 147 MB      Installed ✓│  │
│               │  │ ◉ Balanced    small · 464 MB     ● In use   │  │
│               │  │ ○ Accurate    large-v3-turbo · 1.5 GB   ↓   │  │
│               │  │ ▸ All models…                               │  │
│               │  └─────────────────────────────────────────────┘  │
└───────────────┴───────────────────────────────────────────────────┘
```

**Sidebar order** (frequency-weighted after the conventional General-first):
General · Dictation · Models · Cleanup · Output · Per-App Profiles · Privacy & Permissions · Advanced.

---

## 4. Pane-by-pane specification

### 4.1 General

| Group | Control | Notes |
|---|---|---|
| Startup | Launch OpenWhisp at login (toggle) | System SMAppService state, as today. Conditional "Open Login Items Settings…" link-button when approval is required. |
| Recording overlay | Show overlay while recording (toggle) · `showOverlay` | Moved from "Appearance" — it's the only appearance setting; a whole section for it was overhead. |
| | Indicator style (picker: Spectral bars / Waveform) · `voiceIndicatorStyle` | Nested/indented under the toggle; shown only while overlay is on (meaningless otherwise, so hiding is fine per principle 4). Decide the fate of `.orb`: ship it as a third option or delete the code — don't carry dead enum cases. |
| Configuration | Export Settings… / Import Settings… | Renamed from "Config" — users export *settings*. |
| | Setting packs (list + Apply per pack) | Only when bundled packs exist, as today. |
| Reset | Reset All Settings… (destructive, confirm dialog) | **New.** Currently there is no way back to a known-good state. Keeps Keychain key and downloaded models; resets UserDefaults + JSON stores after confirmation. |

### 4.2 Dictation

*How you start speaking and what you speak into.*

| Group | Control | Notes |
|---|---|---|
| Activation | Push-to-talk key (picker) · `triggerMode` | Options: "Fn (Globe)" — default, `controlSpace` → "Control + Space". Drop "(experimental)" from the default or change the default; a footnote can carry the caveat ("Some apps intercept the Fn key"). Future: a shortcut-recorder control (e.g., the KeyboardShortcuts package) instead of a fixed picker. |
| Microphone | Input device (picker) · `microphoneID` | Keep "System Default" first and the synthetic "Saved microphone (disconnected)" row — that's a genuinely good pattern; add subtitle "Reconnects automatically when available." |
| | Auto-boost quiet microphone (toggle) · `autoGainEnabled` | Subtitle: "Raises the level of soft microphones on this Mac before transcribing." |
| | *(Refresh Devices button — removed)* | Subscribe to CoreAudio device-change notifications and refresh the picker automatically. Keep a manual refresh in an overflow menu as a fallback if you're cautious. |
| Language | Spoken language (picker) · `language` | Plain names only: Auto Detect, English, Russian, Spanish, … The translate behavior moves out (below). |
| | Translate to English (toggle) · **new key**, e.g. `translateToEnglish` | Replaces the "English — Whisper translate to English" overload. Subtitle: "Speech in any language comes out as English text." Shown only for Whisper engines (whisper.cpp / WhisperKit); Apple Speech doesn't translate. Migration: existing `language == "en"` maps to `language = auto` (or `en`) + `translateToEnglish = true` per current semantics. This also lets you surface the AI "Improve Whisper translation" mode contextually (see 4.4). |

*Note on Refine key:* it moves out of this pane entirely — see 4.4. If you want a breadcrumb, a
one-line footnote under Activation ("Refine key is configured in Cleanup → Refine") costs nothing.

### 4.3 Models

*One home for engine choice, model selection, downloads, and disk usage. Absorbs: Basic → Quality,
Advanced → Engine, Advanced → Model, Advanced → Storage, and all three "Open Models Folder" buttons.*

**Engine** — rich radio rows (title + subtitle), not a bare menu picker · `transcriptionEngine`:

- **WhisperKit (CoreML)** — "Optimized for Apple Silicon. Recommended." *(default, build-dependent)*
- **Whisper Local (whisper.cpp)** — "Widest model selection. Supports live typing."
- **Apple Speech** — "Built into macOS. Instant, no downloads."

When switching *to* WhisperKit while `outputMode == liveChunks`, show an inline callout: *"Live
typing isn't available with WhisperKit — output switched to Preview."* Never change state silently.

**Model** — content adapts to engine; the *group* is always present:

- *whisper.cpp:* three recommended tiers as selectable rows using the unified ModelRow component
  (§8) — **Fast** (`base`, 147 MB), **Balanced** (`small`, 464 MB, recommended), **Accurate**
  (`large-v3-turbo`, 1.5 GB). A collapsed **"All models…"** disclosure lists the full catalog
  (tiny/tiny.en/base.en/small.en/medium/large-v3 …) with the same rows, plus a "Custom model
  file…" row that absorbs Model Path + Browse…. Selecting anything triggers `ensureModelExists()`
  exactly as today. This retires the duplicate Quality-tier picker and the synthetic "Custom" row
  in the common case.
- *WhisperKit:* same ModelRow list from `selectableModels()` — Fast (`tiny.en`, English only),
  Balanced (`small`, recommended), Accurate (`large-v3-turbo`). Uninstalled models show a Download
  accessory instead of a " — not installed" suffix. Per-model rows replace the separate
  Active-Model picker + download-row stack: **selection and installation are the same list.**
- *Apple Speech:* an explainer card — "Uses the macOS speech engine. Nothing to download or
  configure." (Formalizes today's empty state.)

**Storage** — merged into this pane:

- Total line: "Downloaded models: 4.2 GB" + **Open Models Folder** (the *single* instance of this
  button) — covers all backends, including the bundled LLM.
- Per-model delete lives on the rows above (trash on hover, disabled + tooltip for the in-use
  model, confirmation dialog as today). The separate Storage list, its Refresh button, and the
  duplicated folder buttons go away; sizes refresh automatically on pane appearance and after
  downloads/deletes.

**Naming rule:** the word for this concept is **Model**, everywhere. "Transcription Quality,"
"Active Model," and "Whisper Model" all retire.

whisper.cpp *runtime* internals (CLI vs. server, binary path, logs) are deliberately **not** here —
they're operational, not model choice. They live in Advanced (4.8).

### 4.4 Cleanup

*Everything that transforms the transcript, in pipeline order: deterministic formatting →
vocabulary → AI rewrite → spoken refine. Absorbs: Advanced → Smart Formatting, Advanced → Custom
Vocabulary, Basic → AI Post-processing, and the Refine key from Basic → Hotkey.*

**Formatting** *(free, instant, on-device — listed first for exactly that reason)*

| Control | Key | Notes |
|---|---|---|
| Clean up dictation automatically (toggle) | `smartFormattingEnabled` | Master. |
| Apply spoken punctuation (toggle, nested) | `spokenPunctuationEnabled` | Subtitle keeps the examples: ""new line", "comma", "period"". |
| Remove filler words (toggle, nested) | `fillerRemovalEnabled` | Subtitle: ""um", "uh"". |

**Vocabulary**

| Control | Key/Store | Notes |
|---|---|---|
| Use custom vocabulary (toggle) | `customVocabularyEnabled` | |
| Bias terms | `vocabulary.json` | Upgrade the comma-separated TextField to a **token field** — terms become removable chips; commas are an implementation detail users shouldn't manage. |
| Substitutions | `vocabulary.json` | Replace the per-row "Add" UI with a standard macOS **table + ± footer**: columns "Heard" / "Replace with", inline editing, − removes selection. Same pattern as Per-App Profiles (§4.6) so the two tables feel like siblings. |

**AI cleanup**

| Control | Key | Notes |
|---|---|---|
| Improve text with AI (toggle) | `openAIEnhancementEnabled` | Master. Subtitle: "Runs the transcript through a language model after transcription." Retires the mouthful "Clean up text with AI after transcription." |
| Provider (picker) | `llmProvider` | Consistent, privacy-honest labels on one axis: **"On this Mac (built-in)"** / **"OpenAI (cloud)"** / **"Your server (self-hosted)"**. **Recommend default → `bundled`** so first enable works offline with zero setup, matching the product's privacy story (today's default `openai` dead-ends without an API key). |
| Mode (picker) | `openAIEnhancementMode` | "Rephrase in the same language" / "Improve English translation". Show the second option only when *Translate to English* (4.2) is on — it's meaningless otherwise; a footnote explains where to enable translation. Kills a silent coupling. |
| Target language (picker) | `translationTargetLanguage` | Only when mode = improve translation, as today. |
| Provider fields | — | Shown **directly** when the provider is selected — required configuration must never hide behind a DisclosureGroup. OpenAI: model picker (+ Custom… field) and API key SecureField with inline caption "Stored in your Keychain, never in preferences." Your server: URL + model (placeholder: "Leave blank for server default"). On this Mac: bundled-model picker with the unified ModelRow download state; keep the memory-caution callout when paired with a resident whisper.cpp server, rendered as the standard Callout component (§8). |
| **Test** (button) | — | One label everywhere — "Test" — replacing "Validate OpenAI Key" / "Test Connection" / "Test built-in model". Result is a **persistent inline status line**, not a transient string: "✓ Connected · gpt-4o-mini · 0.3 s" / "✕ Invalid API key" with time-ago. |

**Refine** *(the whole feature, finally in one place)*

| Control | Key | Notes |
|---|---|---|
| Refine with a spoken instruction (toggle) | `instructionChainEnabled` | Subtitle: "Tap the refine key mid-dictation and speak an instruction — "make it formal", "turn into bullet points"." |
| Refine key (picker) | `refineKey` | Off / Right Option ⌥ / Right Command ⌘ / Right Control ⌃ / Right Shift ⇧ — moved from Hotkey. |
| Dependency callout | — | If enabled while AI cleanup is off/unconfigured, show the standard warning Callout **with a fix-it button**: "Refine needs AI cleanup — Turn on ↑". Today's bare orange text tells users what's wrong without helping them fix it. |

### 4.5 Output

*Where and how text lands. Absorbs Basic → Text Output and Advanced → Script Post-processor (a
script that mutates the final transcript is an output-stage hook, not generic "advanced").*

| Group | Control | Key | Notes |
|---|---|---|---|
| Delivery | Output mode (picker) | `outputMode` | "Preview, then insert (recommended)" / "Insert at end" / "Type live as you speak". Under WhisperKit, **show Live disabled with a subtitle** ("Requires the whisper.cpp engine") instead of hiding it — users should learn the option exists and what unlocks it. |
| Insertion | Insertion method (picker) | `insertionMode` | Subtitled options: **Automatic (recommended)** — "Inserts directly when the app allows it, otherwise pastes" / **Direct insert only** — "Never touches the clipboard" / **Paste** — "Always uses ⌘V". Retires the contradictory "(keep clipboard)" claim. |
| | Restore clipboard after pasting (toggle) | `restoreClipboard` | **Recommend default → on.** Clipboard clobbering is the #1 complaint about paste-based dictation tools; restoring is what users assume happens. Disabled with explanation when method = Direct insert only (as today, keep). |
| | Add a space after inserted text (toggle) | `addTrailingSpace` | Slightly clearer than "trailing space after paste" — it applies to insertion generally. |
| Script | Run my script on the final transcript (toggle) | `scriptPostProcessorEnabled` | |
| | Script path row | `scriptPostProcessorPath` | Choose… / Clear as today; the missing/not-executable warning becomes a standard Callout with a **Reveal in Finder** action. |

### 4.6 Per-App Profiles

Unchanged in substance, upgraded in form:

- "Apply per-app profiles" toggle · `perAppModesEnabled`, with a one-line explainer:
  "Override language, output, and AI cleanup for specific apps."
- A proper **table** (`profiles.json`): App | Language (Inherit/Auto/English/Russian) |
  Output (Inherit/Preview/Final/Live) | AI cleanup (Inherit/On/Off) — with a **± footer**;
  "+" offers *Choose App…* and *Add Last-Used App* in a menu. Same table pattern as Substitutions.
- **Empty state** with direction, not a blank list: "No profiles yet. Add the app you dictate into
  most — for example, keep Live typing for your editor and Preview everywhere else."

### 4.7 Privacy & Permissions

*Promoted from the bottom of Advanced to a first-class pane. Absorbs Advanced → Permissions,
Advanced → History, and the privacy indicator from Status.*

**Privacy summary** — the pane opens with the dynamic indicator, promoted from a status footnote to
the headline: e.g. "🔒 Audio and text are processed on this Mac" vs. "☁️ Transcripts are sent to
OpenAI for cleanup". For a dictation app this single line is the trust anchor; computed from
engine + AI provider.

**Permissions** — four uniform PermissionRows (§8): Microphone · Speech Recognition ·
Accessibility · Input Monitoring. Each row: status (dot **and** word — never color alone) + a
single right-aligned action (*Request* when the API allows prompting, otherwise *Open Settings…*).
This consolidates today's five loose buttons; *Retry Hotkey* and *Reveal Running App* move to a
small "Troubleshooting" row beneath (they're recovery tools, not permissions). The global banner
deep-links here.

**History**

- Keep transcription history (toggle) · `historyEnabled` — subtitle: "Stores your last 15
  transcriptions on this Mac (`history.json`)."
- The recent list (≤15, per-entry copy) + Clear History. History is the most sensitive data the app
  writes to disk; colocating it with permissions makes the privacy pane the honest answer to
  "what does this app know about me."

### 4.8 Advanced

*Genuinely operational internals only — the pane earns its name back.*

| Group | Control | Notes |
|---|---|---|
| whisper.cpp runtime *(engine = whisper.cpp)* | Backend (picker) · `whisperBackend` | "Background server — keeps the model loaded (faster)" *(default)* / "Command line — starts fresh each dictation (simpler)". Axis-consistent labels replace "CLI - reliable / Server API - warm model". |
| | Server status + log path (read-only), Stop Server, Reveal Log | As today. |
| | Binary path + Browse… + Verify · `whisperBinaryPath` | As today. |
| Live typing tuning *(engine = whisper.cpp)* | Chunk duration (picker) · `liveChunkDuration` | 1.0 / 1.5 / 2.0 (default) / 3.0 s; disabled with explanation while pause-based is on. |
| | Pause-based chunking (toggle) · `pauseBasedLiveChunksEnabled` | Subtitle must surface the side effect: "Splits on natural pauses. Turns on "Type live" output." Silent mode-forcing was finding #4. |
| Diagnostics | Current status · last error · last-transcription preview | Relocated from Status. Better long-term home: the **menu bar popover** (§10) — status is monitoring, and nobody opens Settings to monitor. Keep a minimal read-only block here until then. |
| Developer *(instrumentation builds)* | LLM Lab | Unchanged, `#if OPENWHISP_INSTRUMENTATION`. `debugOverlayEnabled` stays menu-bar-only, as today. |

---

## 5. Copy changes at a glance

| Today | Proposed | Why |
|---|---|---|
| "Fn / Globe (experimental)" *(default)* | "Fn (Globe)" + footnote caveat | Defaults can't be experimental. |
| "English - Whisper translate to English" | *Spoken language* picker + *Translate to English* toggle | Two concepts, two controls. |
| "Clean up text with AI after transcription" | "Improve text with AI" | Verb-first, half the length. |
| "Built-in (offline)" / "OpenAI (cloud)" / "Local server (private)" | "On this Mac (built-in)" / "OpenAI (cloud)" / "Your server (self-hosted)" | One axis: *where it runs*. |
| "Faster — quick notes" / "Balanced" / "Best — most accurate" · "Small (recommended)" / "Tiny" / "Turbo (heavy)" | **Fast / Balanced / Accurate** across both engines, with model + size as metadata | One tier vocabulary; "Turbo (heavy)" is an oxymoron. |
| "Transcription Quality" / "Active Model" / "Whisper Model" | **Model** | One word per concept. |
| "Validate OpenAI Key" / "Test Connection" / "Test built-in model" | **Test** (+ persistent result line) | One verb per action. |
| "CLI - reliable" / "Server API - warm model" | "Command line — starts fresh each dictation" / "Background server — keeps the model loaded (faster)" | Says what it does, not how it's built. |
| "Automatic (keep clipboard)" | "Automatic (recommended)" + honest subtitle | The clipboard claim contradicted the restore toggle. |
| " — not installed" suffix in picker | Download accessory on the model row | State belongs on the control, not in the label. |

---

## 6. Behavior & default recommendations

Ranked by impact; all are independent of the re-layout.

1. **`modelName` default `tiny` → `base`** (or add tiny as a visible "Fastest" tier). A default that
   renders as "Custom (tiny)" looks broken on first run.
2. **`llmProvider` default `openai` → `bundled`.** First enable of AI cleanup should succeed with
   zero setup and zero data leaving the Mac.
3. **`restoreClipboard` default off → on.** Matches user expectation for paste-based insertion.
4. **No silent state changes.** Engine → WhisperKit announces the live-typing fallback; pause-based
   chunking declares that it forces Live output.
5. **Auto-refresh the microphone list** via CoreAudio device notifications; retire the button.
6. **Add Reset All Settings** (General) — currently unrecoverable misconfiguration has no exit.
7. **Resolve `.orb`**: ship it or delete it.
8. **Settings search** (stretch): index label → pane anchor; even a simple filter over ~60 controls
   pays for itself. Sidebar layout makes this natural later.

---

## 7. Migration map (complete)

Every control from `SETTINGS.md`, old → new. Keys unchanged unless noted.

| Old location | Control | New home | Change |
|---|---|---|---|
| Basic → General | Launch at login (+ Login Items link) | General → Startup | — |
| Basic → Hotkey | Push-to-talk | Dictation → Activation | Copy fix (§5) |
| Basic → Hotkey | **Refine key** | **Cleanup → Refine** | Colocated with its feature |
| Basic → Microphone | Input device | Dictation → Microphone | — |
| Basic → Microphone | Refresh Devices | *(removed)* | Auto-refresh (§6.5) |
| Basic → Microphone | Auto-boost quiet microphone | Dictation → Microphone | — |
| Basic → Language | Transcription Language | Dictation → Language | Split: language + Translate toggle (new key) |
| Basic → Quality (whisper.cpp) | Tier picker + download status/Retry | Models → Model | Unified ModelRow; tiers = Fast/Balanced/Accurate |
| Basic → Quality (WhisperKit) | Active Model + per-model rows + Open Models Folder | Models → Model / Storage | Selection and install merged into one list; single folder button |
| Basic → AI Post-processing | Master toggle, Provider, Mode, Target language, provider fields, API key, Test/Validate | Cleanup → AI cleanup | Copy + inline config + unified Test |
| Basic → AI Post-processing | Refine with spoken instruction | Cleanup → Refine | Joined with its key; callout gets a fix-it action |
| Basic → Text Output | Insertion, Output mode, trailing space, restore clipboard | Output | Live shown-disabled under WhisperKit; copy fixes |
| Basic → Appearance | Overlay + indicator style | General → Recording overlay | — |
| Advanced → Smart Formatting | All three toggles | Cleanup → Formatting | — |
| Advanced → Custom Vocabulary | Toggle, bias terms, substitutions | Cleanup → Vocabulary | Token field; table + ± |
| Advanced → Engine | Engine picker | Models → Engine | Rich rows; switch callout |
| Advanced → Model | Full model picker, status, Model Path, Download/Check, Reveal, Browse… | Models → "All models…" disclosure | Path/Browse become "Custom model file…" row |
| Advanced → Live Chunks | Duration + pause-based | Advanced → Live typing tuning | Side effect surfaced in copy |
| Advanced → Per-App Modes | Toggle + profile list + Choose/Add buttons | Per-App Profiles pane | Table + ± footer; empty state |
| Advanced → Script Post-processor | Toggle + path + warning | Output → Script | Callout with Reveal action |
| Advanced → History | Toggle + list + Clear | Privacy → History | Promoted; privacy framing |
| Advanced → Backup & Sharing | Export/Import + Packs | General → Configuration | — |
| Advanced → Storage | Totals, per-model rows, folder, Refresh | Models (merged) | Delete on model rows; auto-refresh |
| Advanced → whisper.cpp | Backend, status, log, binary, Verify, Stop, Reveal | Advanced → whisper.cpp runtime | Copy fixes |
| Advanced → LLM Lab | Dev harness | Advanced → Developer | — |
| Advanced → Permissions | 4 statuses + 5 buttons | Privacy → Permissions (+ Troubleshooting row) | PermissionRow pattern |
| Advanced → Status | Privacy indicator / status / error / preview | Privacy summary + Advanced → Diagnostics | Indicator promoted; rest → menu bar eventually |
| Onboarding | All steps/keys | Unchanged | Align labels with §5 (provider names, Fn label) |
| Appendix | `debugOverlayEnabled`, `didCompleteOnboarding` | Unchanged | Menu bar / internal |

Net: **0 capabilities removed**, 3 controls retired as redundant (duplicate model picker, duplicate
folder buttons, Refresh Devices), 3 added (Translate toggle, Reset, promoted privacy summary).

---

## 8. Shared components (build once, use everywhere)

- **ModelRow** — `[selection] Name  ·size badge·  [accessory]` where accessory ∈
  Download ↓ | progress ring (cancelable) | Installed ✓ | ● In use pill; trash on hover (disabled
  for in-use). Used by: whisper.cpp models, WhisperKit models, bundled LLM. Today these are three
  different UIs for one job.
- **Callout** — info/warning/error tint, message, optional **action button**. Replaces every ad-hoc
  orange Text (refine-unconfigured, memory caution, script-missing, engine-switch notice). A
  warning without a next step is only half a warning.
- **PermissionRow** — status dot + status *word* + name + one trailing action. Never color-only
  (accessibility).
- **TestResult** — persistent inline line under a Test button: symbol + summary + relative time.
- **Table + ± footer** — Substitutions and Per-App Profiles share it.
- **Verb dictionary** — Download / Remove / Test / Reveal in Finder / Choose… / Open … Settings.
  Same action, same word, everywhere, including confirmation dialogs and toasts.

Accessibility floor: every status conveyed in text as well as color; VoiceOver labels on progress
("Downloading small, 40%"); indicator-style previews respect Reduce Motion; full keyboard
navigation through the sidebar and forms.

---

## 9. Implementation notes (SwiftUI)

- `Settings` scene → `NavigationSplitView`; each pane a `Form { Section { … } }` with
  `.formStyle(.grouped)` for the native System-Settings look. `LabeledContent` for read-only rows.
- Engine rows: custom selectable rows (button + checkmark) rather than `.radioGroup` — you need
  subtitles and trailing accessories.
- Pane visibility is static; *sections* observe `transcriptionEngine` etc. This kills the
  cross-tab morphing while keeping all existing `AppState` bindings intact.
- Phase 1 is nearly pure view-layer work: same keys, same `AppState`, new arrangement. The only
  model changes in the whole spec are the `translateToEnglish` split (with the one-line migration)
  and the three default changes (§6.1–6.3), each gated behind a stored settings-version bump so
  existing users keep their current values.

---

## 10. Beyond the Settings window

Two moves that reduce how often anyone needs Settings at all:

1. **Menu bar popover = daily driver.** Put the things people flip mid-day where the mic icon
   already is: language, AI cleanup on/off, microphone, the privacy indicator, and recent history
   with per-entry copy. Status/error monitoring belongs there too (§4.8). Settings becomes what it
   should be — configuration, visited rarely.
2. **Onboarding stays the thin veneer it is** (same keys), with labels synced to §5 and the AI step
   defaulting to the bundled provider per §6.2 — so the out-of-box story is "works offline, nothing
   to configure," which is the product's strongest card.

---

## 11. Suggested phasing

| Phase | Work | Risk |
|---|---|---|
| 1 — Re-home | Sidebar + 8 panes; move sections per §7; merge Storage into Models; colocate Refine; copy pass (§5) | View-layer only; no key changes |
| 2 — Components | ModelRow, Callout, PermissionRow, TestResult, tables + ±, token field | Isolated views |
| 3 — Behavior | Translate split + migration; defaults (§6.1–6.3); auto mic refresh; Reset; disabled-not-hidden Live; switch callouts | Small model changes, gated by settings-version |
| 4 — Reach | Menu bar quick controls; settings search; shortcut recorder | Independent features |

Phase 1 alone fixes findings 1–4 and 8 — the structural complaints — without touching a single
persistence key.
