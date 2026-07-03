# OpenWhisp — Settings Inventory

> **⚠️ Historical snapshot.** This inventory describes the OLD two-tab Settings
> window, captured to support the redesign in `openwhisp-settings-redesign.md`.
> **The redesign is now implemented**: the window is a sidebar with eight panes
> (General · Dictation · Models · Cleanup · Output · Per-App Profiles ·
> Privacy & Permissions · Advanced) — see the redesign spec's §4 pane
> specification and §7 migration map for where every control below now lives.
> Current source of truth: `OpenWhisp/Views/SettingsView.swift` +
> `OpenWhisp/Views/Settings/*.swift`, `OpenWhisp/Models/AppState.swift`.
>
> **Implemented behavior changes** (redesign §6, gated by
> `SettingsMigration` / `settingsVersion` = 2 so existing installs keep their
> old effective values):
> - `language == "en"` overload split into plain `language` + new
>   **`translateToEnglish`** Bool key (engines receive a `translate-en`
>   sentinel via `WhisperTask.translateToEnglishSetting`).
> - New-install defaults: `modelName` `tiny` → **`base`**, `llmProvider`
>   `openai` → **`bundled`**, `restoreClipboard` off → **on**.
> - "Refresh Devices" button removed — CoreAudio device changes auto-refresh
>   the mic picker (`AudioDeviceMonitor`).
> - **Reset All Settings…** added (General); keeps Keychain key + models.
> - Engine switches no longer change output mode silently
>   (`AppState.engineSwitchNotice` callout); "Type live" is shown disabled
>   under WhisperKit instead of hidden.

A complete map of every user-facing setting, for reviewing/reorganizing the
Settings UX. Each control lists: **Type · Options (value → label) · Default · Key ·
Purpose**. Values are the persisted tag; labels are the UI text.

## Structure at a glance (pre-redesign)

- **Window**: two tabs — **Basic** and **Advanced** (min 640×600).
- **Permission banner stack** sits above the tabs when a needed permission (Accessibility / Input Monitoring) is missing. Session-only, never persisted.
- **Backend-conditional**: many sections change or hide based on the selected `transcriptionEngine`:
  - `whisper` → whisper.cpp · `whisperKit` → WhisperKit (CoreML) · `appleSpeech` → Apple Speech.
  - Default engine: `whisperKit` (in a WhisperKit build), else `whisper`.

---

# Basic Tab

Order: General · Hotkey · Microphone · Language · Quality · AI Post-processing · Text Output · Appearance.

## General

- **Launch OpenWhisp at login** — Toggle · on/off · Default: from system (SMAppService) · Key: *none* (system state) · Auto-start after login.
- **Open Login Items Settings** — Button (only when approval required) · deep-link.

## Hotkey

- **Push-to-talk** — Picker · `controlSpace`→"Control + Space", `fn`→"Fn / Globe (experimental)" · Default: **`fn`** · Key: `triggerMode` · Which key starts dictation.
- **Refine key** — Picker · `off`→"Off", `rightOption`→"Right Option (⌥)", `rightCommand`→"Right Command (⌘)", `rightControl`→"Right Control (⌃)", `rightShift`→"Right Shift (⇧)" · Default: **`rightControl`** · Key: `refineKey` · Tap mid-dictation to speak an instruction that rewrites the dictation.

## Microphone

- **Input Device** — Picker · `""`→"System Default", then one per mic (`uid`→name); synthetic "Saved microphone (disconnected)" row when the saved device is absent · Default: **`""`** · Key: `microphoneID` (stores device UID).
- **Refresh Devices** — Button.
- **Auto-boost quiet microphone** — Toggle · on/off · Default: **on** · Key: `autoGainEnabled` · Locally raises volume of soft mics before transcription.

## Language

- **Transcription Language** — Picker · `auto`→"Auto Detect", `en`→"English - Whisper translate to English", `ru`→"Russian", `es`→"Spanish", `fr`→"French", `de`→"German", `it`→"Italian", `pt`→"Portuguese", `ja`→"Japanese", `zh`→"Chinese", `ko`→"Korean", `ar`→"Arabic" · Default: **`auto`** · Key: `language` · English = translate non-English speech to English.

## Quality — *backend-conditional (three variants)*

### whisper.cpp (`transcriptionEngine == whisper`)

- **Transcription Quality** — Picker · `base`→"Faster — quick notes", `small`→"Balanced — good all-rounder", `large-v3-turbo`→"Best — most accurate, recommended"; synthetic "Custom (`<modelName>`)" row when active model isn't a tier · Writes `modelName` (overall default **`tiny`**) · Selecting a tier triggers a model download.
- **Model download status** — ProgressView + status text; **Retry Download** button on failure.

### WhisperKit (`transcriptionEngine == whisperKit`)

- **Active Model** — Picker · options = curated + staged (`selectableModels()`), unstaged suffixed " — not installed": `openai_whisper-small`→"Small (multilingual, recommended)", `openai_whisper-tiny.en`→"Tiny (English only)", `openai_whisper-large-v3-turbo`→"Turbo (heavy)" · Default: **`openai_whisper-small`** · Key: `whisperKitModel`.
- **Per-model download rows** — each: "Installed" ✓ / progress / **Download** button (disabled while any WK download runs).
- **Open Models Folder** — Button.

### Apple Speech (`transcriptionEngine == appleSpeech`)

- No controls — uses the built-in macOS dictation model.

## AI Post-processing

- **Clean up text with AI after transcription** — Toggle · on/off · Default: **off** · Key: `openAIEnhancementEnabled` · Master switch.
- **Provider** — Picker · `bundled`→"Built-in (offline)", `openai`→"OpenAI (cloud)", `local`→"Local server (private)" · Default: **`openai`** · Key: `llmProvider`.

**Provider details (DisclosureGroup):**

- **Mode** — Picker · `rephrase`→"Rephrase in same language", `improveTranslation`→"Improve Whisper translation" · Default: **`rephrase`** · Key: `openAIEnhancementMode`.
- **Translation Language** — Picker (only when mode = `improveTranslation`) · `en`→"English", `ru`→"Russian" · Default: **`en`** · Key: `translationTargetLanguage`.

**Provider-specific fields:**

- *OpenAI:*
  - **OpenAI Model** — Picker · `gpt-4o-mini`→"GPT-4o mini", `gpt-4.1-mini`→"GPT-4.1 mini", `gpt-4.1-nano`→"GPT-4.1 nano", `__custom__`→"Custom…" · Default: **`gpt-4o-mini`** · Key: `openAIModel`.
  - **Custom OpenAI model** — TextField (when Custom).
  - **OpenAI API Key** — SecureField · **stored in Keychain** (not UserDefaults).
- *Local server:*
  - **Server URL** — TextField · Default: **`http://localhost:8080/v1`** · Key: `localLLMBaseURL`.
  - **Model (blank = server default)** — TextField · Default: **`""`** · Key: `localLLMModel`.
- *Built-in:*
  - **Built-in model** — Picker (from bundled `llm-manifest.json`, label "`label · size`") · Default: **`qwen2.5-0.5b-instruct`** · Key: `bundledLLMModel`.
  - Download UI (progress / "Active — ready (offline)" / **Download model** / **Retry**); orange memory-caution when paired with a resident whisper.cpp server.

- **Test/Validate** — Button · dynamic label: "Test built-in model" / "Test Connection" / "Validate OpenAI Key" · shows `translationStatus`.
- **Refine with a spoken instruction** — Toggle · on/off · Default: **on** · Key: `instructionChainEnabled` · orange warning if enabled but LLM unconfigured.

## Text Output

- **Insertion Method** — Picker · `auto`→"Automatic (keep clipboard)", `directAX`→"Direct insert only", `paste`→"Paste (Cmd+V)" · Default: **`auto`** · Key: `insertionMode`.
- **Output Mode** — Picker · `preview`→"Preview, then paste (recommended)", `finalOnly`→"Paste at end, no preview", `liveChunks`→"Type live as you speak" (*not shown for WhisperKit*) · Default: **`preview`** · Key: `outputMode`.
- **Add trailing space after paste** — Toggle · Default: **off** · Key: `addTrailingSpace`.
- **Restore clipboard after paste** — Toggle · disabled when insertion = `directAX` · Default: **off** · Key: `restoreClipboard`.

## Appearance

- **Show overlay while recording** — Toggle · Default: **on** · Key: `showOverlay`.
- **Voice indicator** — Picker (only when overlay on) · `bars`→"Spectral bars", `waveform`→"Waveform" · Default: **`bars`** · Key: `voiceIndicatorStyle` · (`.orb` exists in code but is not offered.)

---

# Advanced Tab

Order: Smart Formatting · Custom Vocabulary · Engine · [Model — whisper.cpp] · [Live Chunks — whisper.cpp] · Per-App Modes · Script Post-processor · History · Backup & Sharing · Storage · [whisper.cpp — whisper.cpp] · [LLM Lab — instrumentation] · Permissions · Status.

## Smart Formatting

- **Clean up dictation automatically** — Toggle · Default: **on** · Key: `smartFormattingEnabled`.
- **Apply spoken punctuation ("new line", "comma", "period")** — Toggle (only when above on) · Default: **on** · Key: `spokenPunctuationEnabled`.
- **Remove filler words ("um", "uh")** — Toggle (only when above on) · Default: **on** · Key: `fillerRemovalEnabled`.

## Custom Vocabulary

- **Use custom vocabulary** — Toggle · Default: **on** · Key: `customVocabularyEnabled`.
- **Bias terms** — multiline TextField (comma-separated) · **stored in `vocabulary.json`**.
- **Substitutions** — list of from→to rows (each removable) + **Add** row (heard / correct + Add) · in `vocabulary.json`.

## Engine

- **Transcription Engine** — Picker · `whisperKit`→"WhisperKit (CoreML)", `whisper`→"Whisper Local (whisper.cpp)", `appleSpeech`→"Apple Speech Streaming" · Default: **`whisperKit`** (build-dependent) · Key: `transcriptionEngine` · Switching rebuilds engines live; WhisperKit + `liveChunks` snaps to `preview`.

## Model — *shown only for whisper.cpp*

- **Whisper Model** — Picker (`availableModelsList()`, label "`label (size)`"):
  `tiny`·`tiny.en` (39 MB) · `base`·`base.en` (147 MB) · `small`·`small.en` (464 MB) · `medium`·`medium.en` (1.5 GB) · `large-v3-turbo` (1.5 GB) · `large-v3` (2.9 GB) · Writes `modelName` · triggers `ensureModelExists()`.
- **Model download status** row.
- **Model Path** — TextField · Default: resolved from `modelName` (`…/OpenWhisp/models/ggml-<model>.bin`) · Key: `modelPath`.
- Buttons: **Download / Check Model**, **Reveal Models Folder**, **Browse…**.

## Live Chunks — *shown only for whisper.cpp*

- **Live Chunk Duration** — Picker · `1.0`→"1.0 sec - fastest", `1.5`→"1.5 sec", `2.0`→"2.0 sec - balanced", `3.0`→"3.0 sec - accurate" · disabled when pause-based on · Default: **`2.0`** · Key: `liveChunkDuration`.
- **Pause-based live chunks** — Toggle · Default: **off** · Key: `pauseBasedLiveChunksEnabled` · forces `outputMode = liveChunks` when on.

## Per-App Modes

- **Apply per-app profiles** — Toggle · Default: **off** · Key: `perAppModesEnabled`.
- **Profile list** (stored in `profiles.json`) — per app: **Language** (Inherit/Auto/English/Russian), **Output** (Inherit/Preview/Final/Live), **AI cleanup** (Inherit/On/Off segmented), + remove.
- Buttons: **Choose App…**, **Add Last-Used App**.

## Script Post-processor

- **Run my script on the final transcript** — Toggle · Default: **off** · Key: `scriptPostProcessorEnabled`.
- **Script path** (when on) — **Choose…** / **Clear** buttons → `scriptPostProcessorPath` (Default `""`); inline warning if file missing / not executable.

## History

- **Keep transcription history** — Toggle · Default: **on** · Key: `historyEnabled`.
- History list (≤15 recent, in `history.json`) — per entry: text + app·time + copy; **Clear History** button.

## Backup & Sharing

- **Export Config…** / **Import Config…** — Buttons (profiles + vocabulary + prompts JSON).
- **Packs** (when bundled packs exist) — per pack: name/description/summary + **Apply**.

## Storage

- Read-only **total** "Downloaded models" size.
- Per-model rows (all backends, `installedModelStorage()`) — label · kind · "• In use" · size · trash (disabled for active model, confirmation dialog).
- Buttons: **Open Models Folder**, **Refresh**.

## whisper.cpp — *shown only for whisper.cpp*

- **Whisper Backend** — Picker · `cli`→"CLI - reliable", `serverAPI`→"Server API - warm model" · Default: **`serverAPI`** · Key: `whisperBackend`.
- Read-only Server API status + log path.
- **Binary Path** — TextField · Default: resolved (`preferredWhisperCLIPath`) · Key: `whisperBinaryPath`.
- Buttons: **Browse…**, **Verify**, **Stop Server API**, **Reveal Log**.

## LLM Lab — *instrumentation-only (`#if OPENWHISP_INSTRUMENTATION`)*

Dev A/B harness (Model picker, Download / Run-all-cases, per-case results). Not a user setting.

## Permissions

Read-only status rows (Microphone · Speech Recognition · Accessibility · Input Monitoring). Buttons: **Request Accessibility**, **Open Accessibility**, **Open Input Monitoring**, **Retry Hotkey**, **Reveal Running App**.

## Status

Read-only: privacy indicator · current status · error · last-transcription preview. No controls.

---

# Onboarding (first-run wizard)

Gated by `didCompleteOnboarding` (default `false`). Steps: welcome · microphone · accessibility · model · hotkey · ai · tryIt. Re-exposes existing settings (same keys/defaults):

- **hotkey step** — `triggerMode`: `fn`→"Fn / Globe key — one-handed, recommended", `controlSpace`→"Control + Space".
- **ai step** — `openAIEnhancementEnabled` toggle; `llmProvider`: `bundled`→"Built-in — offline, no setup", `openai`→"OpenAI — cloud, needs API key", `local`→"Local server — your own"; + bundled model picker/download.

---

# Appendix

## Settings NOT exposed in the Settings UI

- **`debugOverlayEnabled`** — Bool, default `true`, key `debugOverlayEnabled`. Instrumentation-only; toggled from the **menu bar**, not Settings.
- **`didCompleteOnboarding`** — Bool, default `false`. Set by finishing/skipping onboarding.
- **`voiceIndicatorStyle` = `.orb`** — exists in the enum but excluded from the picker.

## Non-UserDefaults persistence

- **OpenAI API key** → Keychain (not UserDefaults).
- **Launch at login** → system SMAppService (source of truth).
- **Vocabulary** → `vocabulary.json` · **Profiles** → `profiles.json` · **History** → `history.json`.

## All buttons / actions

Download/Check Model · Retry Download · Reveal Models Folder · Browse… (model + binary) · Open Models Folder (WhisperKit + Storage) · per-model Download (WhisperKit) · Refresh (Storage) · Refresh Devices · Add/remove (substitutions & profiles) · Choose App… · Add Last-Used App · Choose…/Clear (script) · Clear History + per-entry copy · Export/Import Config · Apply (pack) · Validate/Test (AI) · Download/Retry (bundled LLM) · Verify · Stop Server API · Reveal Log · Request Accessibility · Open Accessibility · Open Input Monitoring · Retry Hotkey · Reveal Running App · Open Login Items Settings.
