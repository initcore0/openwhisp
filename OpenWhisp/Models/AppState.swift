import Foundation
import Combine
import AVFoundation
import UserNotifications
import Cocoa
import ApplicationServices
import Speech
import IOKit.hid

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Settings (persisted)

    @Published var whisperBinaryPath: String {
        didSet { settingsStore.set(whisperBinaryPath, forKey: "whisperBinaryPath") }
    }

    @Published var modelPath: String {
        didSet { settingsStore.set(modelPath, forKey: "modelPath") }
    }

    @Published var modelName: String {
        didSet {
            settingsStore.set(modelName, forKey: "modelName")
            modelPath = resolvedModelPath()
        }
    }

    /// WhisperKit CoreML model id (its own `openai_whisper-*` namespace), separate
    /// from the whisper.cpp GGML `modelName`. Drives the WhisperKit file + streaming
    /// engines. Changing it rebuilds the WhisperKit engine so the new model loads.
    @Published var whisperKitModel: String {
        didSet {
            guard whisperKitModel != oldValue else { return }
            settingsStore.set(whisperKitModel, forKey: "whisperKitModel")
            if transcriptionEngine == "whisperKit" { rebuildFileEngine() }
        }
    }

    @Published var microphoneID: String {
        didSet { settingsStore.set(microphoneID, forKey: "microphoneID") }
    }

    @Published var language: String {
        didSet { persist(language, "language") }
    }

    /// Translate speech (any language) into English text. Whisper-family
    /// engines only — Apple Speech has no translate concept. Replaces the old
    /// "English — Whisper translate to English" language-picker overload
    /// (SettingsMigration rewrites stored `language == "en"` into this).
    @Published var translateToEnglish: Bool {
        didSet { persist(translateToEnglish, "translateToEnglish") }
    }

    @Published var triggerMode: String {
        didSet {
            settingsStore.set(triggerMode, forKey: "triggerMode")
            hotkeyMonitor?.triggerMode = triggerMode
        }
    }

    /// The primary keycode of a fully-custom dictation trigger (MAK-17), or -1
    /// when the custom trigger is a bare modifier (e.g. lone ⌥). Only consulted
    /// when `triggerMode == "custom"`. Persisted as an Int; -1 is the nil sentinel.
    @Published var customTriggerKeyCode: Int {
        didSet {
            settingsStore.set(customTriggerKeyCode, forKey: "customTriggerKeyCode")
            pushCustomTriggerToMonitor()
        }
    }

    /// The modifier bitmask (TriggerModifiers.rawValue) of the custom trigger.
    @Published var customTriggerModifiers: Int {
        didSet {
            settingsStore.set(customTriggerModifiers, forKey: "customTriggerModifiers")
            pushCustomTriggerToMonitor()
        }
    }

    /// The resolved custom trigger from the two persisted fields (-1 keycode means
    /// a bare-modifier binding). Used to push to the monitor and to display.
    var customTrigger: DictationTrigger {
        DictationTrigger(
            keyCode: customTriggerKeyCode >= 0 ? Int64(customTriggerKeyCode) : nil,
            modifiers: TriggerModifiers(rawValue: customTriggerModifiers)
        )
    }

    /// Record a captured shortcut as the custom trigger and switch to it. Writing
    /// the fields persists and re-pushes to the monitor.
    func setCustomTrigger(keyCode: Int64?, modifiers: TriggerModifiers) {
        customTriggerKeyCode = keyCode.map(Int.init) ?? -1
        customTriggerModifiers = modifiers.rawValue
        triggerMode = "custom"
    }

    private func pushCustomTriggerToMonitor() {
        hotkeyMonitor?.customTrigger = customTrigger
    }

    /// How the trigger activates dictation: "hold" (press-to-talk, the default)
    /// or "toggle" (hands-free lock — tap to start, tap/Esc to stop). A quick
    /// double-tap reaches lock even in hold mode. The interaction logic lives in
    /// the pure `ActivationInteraction`; this only persists the choice and pushes
    /// it to the hotkey monitor (MAK-16).
    @Published var hotkeyMode: String {
        didSet {
            settingsStore.set(hotkeyMode, forKey: "hotkeyMode")
            // Setting the monitor's mode rebuilds its interaction machine to idle,
            // so a hands-free session locked open under the OLD mode could no
            // longer be stopped by a tap (the tap would read as a fresh start).
            // Deliver it now instead of stranding it.
            if oldValue != hotkeyMode, dictationLocked {
                stopDictation()
            }
            hotkeyMonitor?.hotkeyMode = hotkeyMode
        }
    }

    /// True while a hands-free (toggle/double-tap) dictation is LOCKED OPEN — the
    /// mic stays live with the trigger released, until a stop tap, Esc, or the
    /// silence safety auto-stop. Drives the overlay's lock affordance. Published
    /// so the overlay reflects it; set from the hotkey `onHotkeyDown(locked:)`
    /// callback and cleared on every session end.
    @Published private(set) var dictationLocked = false

    /// Safety silence auto-stop for a LOCKED USER session (MAK-16): a forgotten
    /// hands-free session must not record forever. Reuses the same
    /// `SilenceAutoStop` the agent bridge uses, but with a much longer hangover
    /// (the user may pause mid-thought), and is fed only while a user lock is
    /// live. nil for hold sessions, agent sessions, and when locked is off.
    private var lockSafetyDetector: SilenceAutoStop?

    /// Selected refine key (RefineKey id, e.g. "rightOption"; "off" disables it).
    @Published var refineKey: String {
        didSet {
            settingsStore.set(refineKey, forKey: "refineKey")
            hotkeyMonitor?.refineKey = refineKey
        }
    }

    /// Selected mouse-button dictation trigger (MouseTrigger id, e.g. "mouse2";
    /// "off" disables it). Shares the hold/toggle activation with the key trigger
    /// (MAK-42).
    @Published var mouseTrigger: String {
        didSet {
            settingsStore.set(mouseTrigger, forKey: "mouseTrigger")
            hotkeyMonitor?.mouseTrigger = mouseTrigger
        }
    }

    @Published var outputMode: String {
        didSet { persist(outputMode, "outputMode") }
    }

    @Published var showOverlay: Bool {
        didSet { settingsStore.set(showOverlay, forKey: "showOverlay") }
    }

    /// Visual style of the overlay's voice indicator (Settings › General → Recording Overlay).
    @Published var voiceIndicatorStyle: VoiceIndicatorStyle {
        didSet { settingsStore.set(voiceIndicatorStyle.rawValue, forKey: "voiceIndicatorStyle") }
    }

    /// Launch the app automatically after login/reboot. Source of truth is the
    /// system (SMAppService), so this is initialized from and written through to
    /// the real login-item status rather than UserDefaults.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            let applied = launchAtLoginService.setEnabled(launchAtLogin)
            // Re-sync to the actual system state in case the change didn't take
            // (e.g. user disabled it in System Settings and macOS needs approval).
            let outcome = LaunchAtLoginReconciler.reconcile(
                desired: launchAtLogin,
                applied: applied,
                actual: launchAtLoginService.isEnabled,
                requiresApproval: launchAtLoginService.requiresApproval
            )
            if outcome.needsApprovalMessage {
                error = "OpenWhisp was added to Login Items but needs your approval in System Settings > General > Login Items."
            }
            if outcome.resolvedValue != launchAtLogin {
                launchAtLogin = outcome.resolvedValue
            }
        }
    }

    @Published var restoreClipboard: Bool {
        didSet { settingsStore.set(restoreClipboard, forKey: "restoreClipboard") }
    }

    /// How transcribed text is inserted into the focused app:
    /// "auto" (try Accessibility direct-insert, fall back to paste),
    /// "directAX" (Accessibility only), or "paste" (Cmd+V only).
    /// Direct-insert preserves the user's clipboard entirely.
    @Published var insertionMode: String {
        didSet { settingsStore.set(insertionMode, forKey: "insertionMode") }
    }

    @Published var addTrailingSpace: Bool {
        didSet { settingsStore.set(addTrailingSpace, forKey: "addTrailingSpace") }
    }

    /// Auto-gain: boost a quiet microphone toward a healthy level before sending
    /// audio to whisper, improving recognition for soft talkers / low-output mics.
    /// Default-on; runs locally with a no-clip safety cap.
    @Published var autoGainEnabled: Bool {
        didSet {
            settingsStore.set(autoGainEnabled, forKey: "autoGainEnabled")
            audioRecorder?.autoGainEnabled = autoGainEnabled
        }
    }

    /// Quiet-dictation mode (MAK-45, v1): a preprocessing preset for whispered / very
    /// soft speech. Turning it on (a) swaps auto-gain to the stronger high-gain
    /// `QuietDictationMode` preset in the recorder, (b) lowers the pause-based VAD's
    /// `speechThreshold` (and lengthens the silence hangover) so a whisper still
    /// opens a chunk, and (c) drops the hands-free / agent-bridge silence-auto-stop
    /// gates so a whisper still arms them. Default OFF — when off, capture behaves
    /// exactly as before. Best paired with getting close to the mic (UI copy).
    @Published var quietDictationEnabled: Bool {
        didSet {
            settingsStore.set(quietDictationEnabled, forKey: "quietDictationEnabled")
            audioRecorder?.quietModeEnabled = quietDictationEnabled
        }
    }

    /// Local, on-device cleanup of dictated text (punctuation, capitalization,
    /// filler removal). Default-on — this is the baseline quality pass and runs
    /// entirely locally, no network.
    @Published var smartFormattingEnabled: Bool {
        didSet { settingsStore.set(smartFormattingEnabled, forKey: "smartFormattingEnabled") }
    }

    /// Apply spoken-punctuation commands ("new line", "comma", "period", ...).
    @Published var spokenPunctuationEnabled: Bool {
        didSet { settingsStore.set(spokenPunctuationEnabled, forKey: "spokenPunctuationEnabled") }
    }

    /// Remove filler words ("um", "uh", ...) from dictated text.
    @Published var fillerRemovalEnabled: Bool {
        didSet { settingsStore.set(fillerRemovalEnabled, forKey: "fillerRemovalEnabled") }
    }

    /// Rewrite spoken filenames to editor `@`-mentions (MAK-48), but ONLY when
    /// the frontmost app is a known AI-native editor (Cursor / Windsurf). Default
    /// OFF: a niche developer aid that would be wrong to run in a chat or doc, so
    /// it's opt-in and gated to editors even when enabled.
    @Published var fileTaggingEnabled: Bool {
        didSet { settingsStore.set(fileTaggingEnabled, forKey: "fileTaggingEnabled") }
    }

    // Opt-in structural formatting (MAK-20). The rules live in SmartFormatter and
    // are honored by TranscriptCleaner; these flags are the Settings controls that
    // turn each group on. All default OFF so ordinary prose is never touched until
    // the user opts in.
    @Published var normalizeNumbers: Bool {
        didSet { settingsStore.set(normalizeNumbers, forKey: "normalizeNumbers") }
    }

    @Published var normalizeCurrency: Bool {
        didSet { settingsStore.set(normalizeCurrency, forKey: "normalizeCurrency") }
    }

    @Published var spokenListsEnabled: Bool {
        didSet { settingsStore.set(spokenListsEnabled, forKey: "spokenListsEnabled") }
    }

    @Published var basicMarkdownEnabled: Bool {
        didSet { settingsStore.set(basicMarkdownEnabled, forKey: "basicMarkdownEnabled") }
    }

    @Published var liveChunkDuration: Double {
        didSet { settingsStore.set(liveChunkDuration, forKey: "liveChunkDuration") }
    }

    @Published var pauseBasedLiveChunksEnabled: Bool {
        didSet { settingsStore.set(pauseBasedLiveChunksEnabled, forKey: "pauseBasedLiveChunksEnabled") }
    }

    /// Default transcription engine for a fresh install. Parakeet is the preferred
    /// default (true streaming, ~0.3 s latency with punctuation) whenever it's
    /// compiled in (`PARAKEET` build flag); a lean `PARAKEET=0` build falls back to
    /// WhisperKit, and a `WHISPERKIT=0` build below that to whisper.cpp — each guard
    /// keeps the default from landing on an engine that isn't in the binary and
    /// would error. Existing installs keep whatever they chose (SettingsMigration
    /// v4 pins the pre-Parakeet default for them), so this only affects new users.
    static var defaultTranscriptionEngine: String {
        #if PARAKEET
        return "parakeet"
        #elseif WHISPERKIT
        return "whisperKit"
        #else
        return "whisper"
        #endif
    }

    @Published var transcriptionEngine: String {
        didSet {
            guard transcriptionEngine != oldValue else { return }
            settingsStore.set(transcriptionEngine, forKey: "transcriptionEngine")
            // WhisperKit doesn't support the "type live" (liveChunks) output mode —
            // it streams via its own pipeline. If a stale liveChunks value carries
            // over when switching to WhisperKit, snap it to the streaming-friendly
            // "preview" — and say so (never change state silently).
            engineSwitchNotice = nil
            if transcriptionEngine == "whisperKit", outputMode == "liveChunks" {
                outputMode = "preview"
                engineSwitchNotice = "Live typing isn't available with WhisperKit — output switched to “Preview, then insert”."
            }
            // Rebuild + rewire the file engine so switching backends takes effect
            // without an app restart (the Whisper-family path uses `whisperEngine`).
            rebuildFileEngine()
            // Provision the newly-selected engine's model if it isn't installed, so
            // switching engines never leaves the user with a working UI but no model
            // (the same class of "feels broken" bug as first launch). Engine-aware +
            // no-ops when already staged.
            ensureSelectedEngineModel()
        }
    }

    /// Build the file-transcription engine for the given setting. The routing
    /// decision is the tested `FileEngineChoice.choice(for:)`; this is a thin
    /// switch that constructs the (app-only) concrete engines.
    private static func makeFileEngine(for engine: String, model: String, whisperKitModel: String) -> FileTranscriptionEngine {
        switch FileEngineChoice.choice(for: engine) {
        // WhisperKit uses its OWN model namespace (openai_whisper-*), not the
        // whisper.cpp GGML model id.
        case .whisperKit: return WhisperKitEngine(modelName: whisperKitModel)
        // Parakeet: live dictation streams (ParakeetStreamingEngine), but every
        // FILE path (meetings, queue, watch folders, history re-transcribe) uses
        // the batch TDT v3 engine here — multilingual, on-device CoreML.
        case .parakeet:   return ParakeetFileEngine()
        // SpeechAnalyzer (macOS 26, MAK-59): the on-device Speech-framework
        // analyzer over the recorded WAV — the primary SpeechAnalyzer path.
        case .speechAnalyzer: return SpeechAnalyzerFileEngine()
        case .whisperCpp: return WhisperEngine()
        }
    }

    /// Parakeet streaming-model variant (ParakeetCatalog id, MAK-46 spike).
    /// Changing it rebuilds the streaming engine so the next session uses the
    /// new variant, and prefetches its model when Parakeet is the active engine.
    @Published var parakeetVariant: String {
        didSet {
            guard parakeetVariant != oldValue else { return }
            settingsStore.set(parakeetVariant, forKey: "parakeetVariant")
            rebuildFileEngine()
            ensureSelectedEngineModel()
        }
    }

    @Published var whisperBackend: String {
        didSet {
            settingsStore.set(whisperBackend, forKey: "whisperBackend")
            if whisperBackend != "serverAPI" {
                whisperEngine?.stopServer()
            } else {
                warmWhisperServerIfPossible()
            }
        }
    }

    /// MAK-35: the AI-cleanup intensity dial (`None`/`Low`/`Medium`/`High`) — the
    /// SINGLE source of truth for whether and how hard the whole-text LLM pass runs.
    /// `.none` skips the LLM entirely; low/medium/high feed the tier's system prompt
    /// (see `CleanupIntensity.systemPrompt`) into the refine. The legacy on/off
    /// `openAIEnhancementEnabled` toggle is now a thin facade over this (below), so
    /// there is exactly one authoritative value. Persisted by rawValue.
    @Published var cleanupIntensity: CleanupIntensity {
        didSet {
            guard cleanupIntensity != oldValue else { return }
            persist(cleanupIntensity.rawValue, "cleanupIntensity")
            // Remember the last non-none tier so the on/off facade (and the tray
            // toggle) can restore the user's chosen strength when flipped back on,
            // instead of snapping to a default.
            if cleanupIntensity != .none { lastNonNoneCleanupIntensity = cleanupIntensity }
            if cleanupIntensity.runsLLM {
                // First enable with the built-in provider should work with zero
                // setup: provision the model if it isn't on disk yet (no-ops and
                // warms when it is).
                if llmProvider == "bundled" { ensureLLMModelExists() }
                else { warmLlamaServerIfPossible() }
            } else {
                llamaEngine?.stopServer()
            }
        }
    }

    /// The last intensity the user picked that actually runs the LLM, so turning
    /// AI cleanup off then on again via the legacy toggle restores THAT tier
    /// (not a hard-coded default). Persisted so the restore survives a relaunch:
    /// dial=.high → toggle off (dial persists .none) → quit → relaunch → toggle on
    /// must restore .high, not the default. Seeded in init from the stored key,
    /// falling back to the migrated/loaded value.
    private var lastNonNoneCleanupIntensity: CleanupIntensity = .default {
        didSet {
            persist(lastNonNoneCleanupIntensity.rawValue, "lastNonNoneCleanupIntensity")
        }
    }

    /// Legacy on/off AI-cleanup switch, now DERIVED from `cleanupIntensity` so the
    /// dial is the one source of truth (MAK-35). Reads true iff a tier runs the LLM;
    /// setting it true restores the last non-none tier, false sets `.none`. Existing
    /// call sites (tray toggle, onboarding, per-app profiles, privacy status) keep
    /// working unchanged, and their bindings still update because `cleanupIntensity`
    /// is `@Published`. Not stored — nothing writes `openAIEnhancementEnabled` to
    /// UserDefaults anymore; `cleanupIntensity` carries the state.
    var openAIEnhancementEnabled: Bool {
        get { cleanupIntensity != .none }
        set { cleanupIntensity = newValue ? lastNonNoneCleanupIntensity : .none }
    }

    @Published var openAIEnhancementMode: String {
        didSet { settingsStore.set(openAIEnhancementMode, forKey: "openAIEnhancementMode") }
    }

    @Published var translationTargetLanguage: String {
        didSet { settingsStore.set(translationTargetLanguage, forKey: "translationTargetLanguage") }
    }

    @Published var openAIAPIKey: String {
        didSet { secretStore.save(openAIAPIKey, key: "openAIAPIKey") }
    }

    @Published var openAIModel: String {
        didSet { settingsStore.set(openAIModel, forKey: "openAIModel") }
    }

    /// Which LLM backend powers post-processing: "openai" (cloud) or
    /// "local" (an OpenAI-compatible local server — llama.cpp/Ollama). Local
    /// keeps everything on-device/on-LAN, preserving the privacy story.
    @Published var llmProvider: String {
        didSet {
            settingsStore.set(llmProvider, forKey: "llmProvider")
            if llmProvider == "bundled" {
                // Provision/warm only when AI cleanup is actually on — switching
                // the provider (or Reset All Settings) with cleanup off must not
                // kick off a model download behind the user's back.
                if openAIEnhancementEnabled {
                    ensureLLMModelExists()
                    warmLlamaServerIfPossible()
                }
            } else {
                // Free the ~0.7-1.5 GB the built-in LLM holds when it's not the
                // active provider.
                llamaEngine?.stopServer()
            }
        }
    }

    /// Base URL (through /v1) of the local OpenAI-compatible server.
    @Published var localLLMBaseURL: String {
        didSet { settingsStore.set(localLLMBaseURL, forKey: "localLLMBaseURL") }
    }

    /// Model name to request from the local server.
    @Published var localLLMModel: String {
        didSet { settingsStore.set(localLLMModel, forKey: "localLLMModel") }
    }

    // MARK: - Summarization model (MAK-53)
    // A SEPARATE provider/model for Meeting-mode summaries, decoupled from the
    // dictation-cleanup LLM. Dictation cleanup favors a tiny fast model (runs on
    // every transcript); summaries run only on demand and can afford a larger
    // (local) model. Defaults to the `sameAsCleanup` sentinel so existing installs
    // are unchanged. Resolution + privacy classification live in the pure
    // `SummaryModelResolver`.

    /// Summary provider override: the `sameAsCleanup` sentinel (default) or a real
    /// provider id (`bundled` / `local` / `openai`). Agent-CLI is intentionally not
    /// offered for summaries — the summarize seam is OpenAI-shape only.
    @Published var summaryLLMProvider: String {
        didSet { settingsStore.set(summaryLLMProvider, forKey: "summaryLLMProvider") }
    }

    /// Model to request for summaries (empty ⇒ the resolved provider's default).
    @Published var summaryLLMModel: String {
        didSet { settingsStore.set(summaryLLMModel, forKey: "summaryLLMModel") }
    }

    /// Custom server URL for summaries — used only when `summaryLLMProvider ==
    /// "local"`. Blank falls back to the cleanup local server URL.
    @Published var summaryLLMEndpoint: String {
        didSet { settingsStore.set(summaryLLMEndpoint, forKey: "summaryLLMEndpoint") }
    }

    /// Selected built-in (bundled llama.cpp) refinement model id, from
    /// llm-manifest.json. Used when `llmProvider == "bundled"`.
    @Published var bundledLLMModel: String {
        didSet {
            guard bundledLLMModel != oldValue else { return }
            settingsStore.set(bundledLLMModel, forKey: "bundledLLMModel")
            // The selected model changed. Stop the server now so a stale model
            // isn't reused, then either download the new model (if missing) or
            // warm it. ensureRunning relaunches on the new -m path anyway, but
            // stopping here makes the switch explicit and frees the old model's RAM.
            if llmProvider == "bundled" {
                llamaEngine?.stopServer()
                // Always route through ensureLLMModelExists: its installed
                // fast-path clears a stale isLLMModelDownloading left by a
                // superseded download (switching to an installed model while
                // another model is still downloading) and then warms the server.
                ensureLLMModelExists()
            }
        }
    }

    // MARK: Agent-CLI provider (MAK-44)
    //
    // Used when `llmProvider == EnhancementProvider.agentCLIID`. The whole-text
    // refine step then pipes the transcript through a locally-installed coding-agent
    // CLI (claude/codex/custom) and uses its cleaned stdout, reusing the user's
    // existing CLI auth (no API key). Persisted; default is the Claude preset so a
    // user who opts in gets a working setup with zero extra typing.

    /// Selected agent-CLI preset id ("claude" / "codex" / "custom").
    @Published var agentCLIPreset: String {
        didSet { persist(agentCLIPreset, "agentCLIPreset") }
    }

    /// Custom executable (bare name resolved on PATH, or an absolute path). Used
    /// only when `agentCLIPreset == "custom"`.
    @Published var agentCLICustomCommand: String {
        didSet { persist(agentCLICustomCommand, "agentCLICustomCommand") }
    }

    /// Custom fixed args, one per line (each line is one argv entry, verbatim — no
    /// shell splitting). The transcript is never here; it goes on stdin.
    @Published var agentCLICustomArgsText: String {
        didSet { persist(agentCLICustomArgsText, "agentCLICustomArgsText") }
    }

    /// Hard wall-clock timeout (seconds) for the agent CLI. On overrun the runner
    /// kills it and fails open to the original transcript.
    @Published var agentCLITimeout: Double {
        didSet { persist(agentCLITimeout, "agentCLITimeout") }
    }

    /// The effective, ready-to-run agent-CLI config from the persisted selection.
    /// A built-in preset keeps its shipped command + args; the custom preset uses
    /// the user's fields. Timeout is always the user's (clamped to a sane floor).
    var activeAgentCLIConfig: AgentCLIProvider.Config {
        AgentCLIProvider.resolveConfig(
            presetID: agentCLIPreset,
            customCommand: agentCLICustomCommand,
            customArgs: AgentCLIProvider.parseCustomArgs(agentCLICustomArgsText),
            timeout: agentCLITimeout
        )
    }

    #if OPENWHISP_INSTRUMENTATION
    /// Dev-only: show the debug HUD on the recording overlay. Toggled from the
    /// menu-bar checkbox; persisted. Only exists in instrumented builds.
    // NOTE: this default reads `UserDefaults.standard` directly (not the injected
    // `settingsStore`): a stored-property default is evaluated before `init`
    // assigns `self.settingsStore`, so it can't reference the seam. The didSet
    // write below still routes through the seam.
    @Published var debugOverlayEnabled: Bool = UserDefaults.standard.object(forKey: "debugOverlayEnabled") as? Bool ?? true {
        didSet { settingsStore.set(debugOverlayEnabled, forKey: "debugOverlayEnabled") }
    }
    #endif

    // Built-in LLM model download UI state (mirrors the whisper modelDownload* set).
    @Published var isLLMModelDownloading = false
    @Published var llmModelDownloadProgress: Double?
    @Published var llmModelDownloadStatus = ""
    @Published var llmModelDownloadFailed = false
    /// LLM model paths with a download currently in flight (per-path, so switching
    /// models mid-download can't clear the other download's dedup guard).
    private var inFlightLLMModelDownloads: Set<String> = []

    /// Lazily-created engine that manages the bundled llama-server subprocess.
    private var llamaEngine: LlamaServerEngine?
    private func ensureLlamaEngine() -> LlamaServerEngine {
        if let engine = llamaEngine { return engine }
        let engine = LlamaServerEngine()
        llamaEngine = engine
        return engine
    }

    /// Detect a spoken instruction at the end of a dictation ("…make this
    /// formal") and apply it via the LLM. Off by default — it's the most "magic"
    /// feature and needs an LLM configured. Works in Final / Preview modes.
    /// Enable the two-utterance "refine with a follow-up instruction" flow: after
    /// dictating, quickly re-press the hotkey within a short window and speak a
    /// natural-language instruction ("make it a telegram post") that the LLM applies
    /// to the just-dictated text. Requires an LLM provider. On by default.
    @Published var instructionChainEnabled: Bool {
        didSet { settingsStore.set(instructionChainEnabled, forKey: "instructionChainEnabled") }
    }

    /// Enable spoken *edit commands* in preview-mode dictation: a standalone
    /// "scratch that" / "delete last word" / "delete last sentence" / "new
    /// paragraph" / "new line" / "undo" edits the pending transcript instead of
    /// being typed as literal words. Only active in "preview" output mode (the text
    /// is held until the end, so an edit can still change what gets pasted) — see
    /// `VoiceEditRouter`. On by default: the parser only fires on a whole-utterance
    /// match, so it's false-positive-safe, and the payoff is high.
    @Published var voiceEditingEnabled: Bool {
        didSet { settingsStore.set(voiceEditingEnabled, forKey: "voiceEditingEnabled") }
    }

    /// Opt-in custom **script** post-processor. When enabled with a valid
    /// executable path, the final transcript is piped through the script (stdin →
    /// stdout) just before insertion. Off by default; fail-open (any error/timeout
    /// keeps the original text). See ScriptRunner / ScriptOutcome.
    @Published var scriptPostProcessorEnabled: Bool {
        didSet { settingsStore.set(scriptPostProcessorEnabled, forKey: "scriptPostProcessorEnabled") }
    }
    @Published var scriptPostProcessorPath: String {
        didSet { settingsStore.set(scriptPostProcessorPath, forKey: "scriptPostProcessorPath") }
    }

    /// Output target (M9 / MAK-11..14): where a FINAL dictation is delivered. A
    /// GLOBAL selection (v1) — one destination for every app — plus the three sink
    /// configs. `.focusedApp` is the default so nothing changes until the user opts
    /// in. Persisted as one JSON blob under `outputTargetSettings`; each mutation
    /// re-saves. The router is rebuilt fresh at each final insert from this value,
    /// so a config edit takes effect on the next dictation with no extra plumbing.
    @Published var outputTargetSettings: OutputTargetSettings {
        didSet { persistOutputTargetSettings() }
    }

    /// Post-completion rules engine (MAK-43): the user's `RuleSet`, loaded from and
    /// persisted to `RuleStore` (JSON, quarantine loader). Rules fire on the
    /// transcribe-complete / llm-complete hooks as a SIDE CHANNEL — see
    /// `fireRules(...)` — and never affect the normal transcript insert. Each
    /// mutation re-saves; the plan is recomputed fresh at each hook from this value,
    /// so a rule edit takes effect on the next dictation with no extra plumbing.
    @Published var ruleSet: RuleSet {
        didSet { RuleStore.save(ruleSet) }
    }

    /// Convenience projections so the Settings UI can bind directly to each field of
    /// `outputTargetSettings` (SwiftUI can't bind into a nested struct's members via
    /// a `@Published` aggregate without these). Each setter writes back through the
    /// aggregate, which persists.
    var outputTargetKind: OutputTargetKind {
        get { outputTargetSettings.kind }
        set { outputTargetSettings.kind = newValue }
    }
    var fileOutputPath: String {
        get { outputTargetSettings.file.path }
        set { outputTargetSettings.file.path = newValue }
    }
    var fileOutputTemplate: String {
        get { outputTargetSettings.file.template ?? "" }
        set { outputTargetSettings.file.template = newValue.isEmpty ? nil : newValue }
    }
    var fileOutputMode: FileOutputMode {
        get { outputTargetSettings.file.mode }
        set { outputTargetSettings.file.mode = newValue }
    }
    var webhookURL: String {
        get { outputTargetSettings.webhook.url }
        set { outputTargetSettings.webhook.url = newValue }
    }
    var shortcutOutputName: String {
        get { outputTargetSettings.shortcutName }
        set { outputTargetSettings.shortcutName = newValue }
    }

    /// Apply per-app profile overrides (language / output mode / AI cleanup)
    /// based on the frontmost app when a dictation starts.
    @Published var perAppModesEnabled: Bool {
        didSet { settingsStore.set(perAppModesEnabled, forKey: "perAppModesEnabled") }
    }

    /// Keep a local history of completed transcriptions (recover/reuse). Local only.
    @Published var historyEnabled: Bool {
        didSet { settingsStore.set(historyEnabled, forKey: "historyEnabled") }
    }

    // MARK: Raw-audio retention (MAK-40) — OPT-IN, on-device only

    /// Opt-in: keep each dictation's raw audio on THIS Mac (never uploaded) so it
    /// can be re-transcribed later. OFF by default. Turning it off deletes every
    /// retained clip immediately (the audio was the only reason to keep them).
    @Published var retainRawAudioEnabled: Bool {
        didSet {
            settingsStore.set(retainRawAudioEnabled, forKey: "retainRawAudioEnabled")
            if !retainRawAudioEnabled { purgeAllRetainedAudio() }
        }
    }

    /// Retention policy — delete audio + history older than N days (0 = no age cap).
    @Published var audioRetentionDays: Int {
        didSet {
            settingsStore.set(audioRetentionDays, forKey: "audioRetentionDays")
            applyRetentionPolicy()
        }
    }

    /// Retention policy — keep at most N retained clips (0 = no count cap).
    @Published var audioRetentionMaxClips: Int {
        didSet {
            settingsStore.set(audioRetentionMaxClips, forKey: "audioRetentionMaxClips")
            applyRetentionPolicy()
        }
    }

    /// A COPY of the whole-session WAV staged for retention by the current `.final`
    /// (non-streaming) dictation, made before the engine deletes the original.
    /// `recordHistory` moves it to the entry's canonical name (or discards it on any
    /// early return). Streaming/live-chunk sessions have no single whole-session WAV,
    /// so retention covers the standard hold-to-talk path (see the changelog note).
    private var pendingRetainWAVPath: URL?

    /// Per-app override profiles (persisted to profiles.json).
    @Published var profiles: [AppProfile] {
        didSet { AppProfileStore.save(profiles) }
    }

    /// First-class user-authored Modes (MAK-39), persisted to modes.json. A Mode
    /// generalizes an AppProfile: a stable invocation key + tone/instruction/model
    /// overrides + optional app auto-activation binding. Invoked by key from the
    /// Settings picker or an `openwhisp://switch-mode`/`activate-mode` URL, or auto-
    /// activated when its bound app is frontmost.
    @Published var modes: [Mode] {
        didSet { ModeStore.save(modes) }
    }

    /// The Mode explicitly activated WITHOUT recording (`activate-mode` / picker):
    /// it governs the NEXT dictation and stays put until changed. nil = no sticky
    /// active Mode. Not persisted (a session-scoped choice).
    @Published var activeModeKey: String?

    /// A Mode queued for the NEXT dictation only (`switch-mode`): consumed once when
    /// that dictation starts, then cleared. Takes precedence over `activeModeKey`.
    @Published var pendingModeKey: String?

    /// Recent transcriptions (persisted to history.json), newest first.
    @Published var history: [TranscriptionEntry] = []

    // MARK: Agent Bridge (M8)

    /// Expose OpenWhisp as a local MCP server / CLI to coding agents. Default-off:
    /// when false, no socket and no listener exist (zero cost). Toggling it starts
    /// or stops the control-plane socket server.
    @Published var agentBridgeEnabled: Bool {
        didSet {
            settingsStore.set(agentBridgeEnabled, forKey: "agentBridgeEnabled")
            agentBridgeServer.allowUnsignedClients = agentBridgeAllowUnsignedClients
            if agentBridgeEnabled { agentBridgeServer.start() } else { agentBridgeServer.stop() }
        }
    }
    /// Relax the code-signature admission check so a user's own (unsigned) client
    /// can connect. Default-off; on-brand escape hatch for the hackable positioning.
    @Published var agentBridgeAllowUnsignedClients: Bool {
        didSet {
            settingsStore.set(agentBridgeAllowUnsignedClients, forKey: "agentBridgeAllowUnsignedClients")
            agentBridgeServer.allowUnsignedClients = agentBridgeAllowUnsignedClients
        }
    }
    /// Allow an agent-initiated LLM call to use the CLOUD provider (OpenAI).
    /// Default-off: a prompt-injected agent must not be able to exfiltrate text
    /// through the user's OpenAI key. When off and the provider is OpenAI, agent
    /// `refine` is refused with `cloudRefineDisabled`.
    @Published var agentBridgeAllowCloudAI: Bool {
        didSet { settingsStore.set(agentBridgeAllowCloudAI, forKey: "agentBridgeAllowCloudAI") }
    }
    /// End an agent-initiated dictation automatically once the speaker falls
    /// silent, instead of waiting for the timeout. Default-ON: the whole point of
    /// agent dictate is a quick spoken answer, and an agent session has no natural
    /// finish gesture (the hotkey cancels it). NEVER affects user (hotkey)
    /// sessions — only sessions the bridge started. See [[SilenceAutoStop]].
    @Published var agentBridgeSilenceAutoStop: Bool {
        didSet { settingsStore.set(agentBridgeSilenceAutoStop, forKey: "agentBridgeSilenceAutoStop") }
    }
    /// Finish an AGENT dictation on the Parakeet EOU variant's end-of-utterance
    /// signal (MAK-46 Phase 5), a crisper "the human finished" than energy silence.
    /// Default-OFF and experimental: only the `parakeet-eou-320ms` variant emits
    /// EOU events, so it's a no-op on any other engine/variant. Agent sessions
    /// only, alongside (not replacing) the silence detector.
    @Published var agentBridgeEouAutoStop: Bool {
        didSet { settingsStore.set(agentBridgeEouAutoStop, forKey: "agentBridgeEouAutoStop") }
    }
    /// Auto-stop a hands-free (locked) dictation after a long stretch of silence,
    /// so a forgotten toggle session doesn't record forever (MAK-16). Default-ON;
    /// a safety net, not a quick-finish gesture — the hangover is deliberately
    /// long (see `lockSafetyConfig`) so a normal mid-thought pause never ends it.
    /// Only ever affects USER locked sessions; hold-to-talk is untouched.
    @Published var handsFreeSilenceAutoStop: Bool {
        didSet { settingsStore.set(handsFreeSilenceAutoStop, forKey: "handsFreeSilenceAutoStop") }
    }
    /// Play a short chime when an agent opens a dictation so you notice it even
    /// when you're not looking at that corner of the screen. Agent sessions only.
    @Published var agentBridgeChimeEnabled: Bool {
        didSet { settingsStore.set(agentBridgeChimeEnabled, forKey: "agentBridgeChimeEnabled") }
    }
    /// Read the agent's question aloud (on-device, no network) when it opens a
    /// dictation, so you can answer without reading the overlay. Agent sessions only.
    @Published var agentBridgeSpeakQuestionEnabled: Bool {
        didSet { settingsStore.set(agentBridgeSpeakQuestionEnabled, forKey: "agentBridgeSpeakQuestionEnabled") }
    }
    /// Audible cues (chime + spoken question) for agent-initiated dictation.
    /// On-device; gated by the two settings above.
    private let agentAnnouncer = AgentAnnouncer()
    /// Per-client consent records (persisted to agent-clients.json). Surfaced in
    /// the Agent Bridge settings pane.
    @Published var agentClients: AgentClientStore = AgentClientStore()
    /// Scopes granted "while running" during this launch, per client (never
    /// persisted). Keyed per-scope so a while-running grant for one capability
    /// doesn't silently cover another.
    private var consentGrantedThisRun: [String: Set<AgentScope>] = [:]
    /// Per-client `dictate` rate limiter (MAK-10). Belt-and-suspenders on top of
    /// consent + the always-visible overlay: an always-allowed client still can't
    /// chain sessions to hold the mic continuously. In-memory only (a fresh budget
    /// each launch), keyed by the same clientName consent uses. Only accepted
    /// starts are recorded, in `bridgeStartDictation`.
    private var agentRateLimiter = AgentRateLimiter()
    /// The agent's prompt for the current agent-initiated session, shown in the
    /// overlay ("X asks: …"). nil for user sessions. Published so the overlay can
    /// render it.
    @Published private(set) var agentDictatePrompt: String?
    /// The agent's identity for the current session ("claude-code", "An agent"),
    /// rendered as the overlay's small eyebrow above the question. Sanitized.
    /// nil for user sessions. Split out from `agentDictatePrompt` so the question
    /// can be the hero and the "who" a quiet label.
    @Published private(set) var agentDictateClientLabel: String?
    /// The agent's raw question for the current session, sanitized for display but
    /// WITHOUT the "X asks:" framing — the overlay renders this as the large,
    /// fully-readable hero text. nil when the agent supplied no prompt.
    @Published private(set) var agentDictateQuestion: String?
    /// True while the agent's question is being READ ALOUD, before the mic goes
    /// live. The overlay shows a "reading question — please wait" cue so the human
    /// doesn't answer into a dead mic (capture is intentionally held until speech
    /// ends, so the TTS isn't captured and returned as the answer).
    @Published private(set) var agentDictateReadingQuestion = false
    /// Set when the current agent session was ended by its timeout / by an explicit
    /// dictate.stop, so the delivered result reports the right `endedBy`.
    private var agentDictateTimedOut = false
    private var agentDictateStopped = false
    private var agentDictateTimeoutTask: Task<Void, Never>?
    /// Silence detector for the current agent session (nil for user sessions and
    /// when the feature is off). Fed the same `audioLevel` samples the overlay
    /// waveform reads; when it fires, the session finishes as if the user tapped
    /// done (`endedBy: .user`). Reset in `finishSessionUI`.
    private var agentSilenceDetector: SilenceAutoStop?
    /// Per-session EOU auto-stop timing (MAK-46 Phase 5), armed for an agent
    /// session only when `agentBridgeEouAutoStop` is on and the active engine emits
    /// EOU events (the Parakeet EOU variant). nil for every other session.
    private var agentEouDetector: AgentEouAutoStop?
    /// The control-plane socket server. Lazily constructed (no cost until the
    /// bridge is enabled); owns the socket, per-connection auth, and dispatch.
    private lazy var agentBridgeServer = AgentBridgeServer(host: self)

    // MARK: P2P sync — LAN bridge + pairing (MAK-51 WP6)

    /// The Mac's pairing state (local peer id, paired iPhones, per-peer PSK in the
    /// Keychain). Lazily built on the injected `secretStore`. Published so the
    /// pairing pane's device list updates when a device is paired/unpaired.
    lazy var pairingStore = PairingStore(secrets: secretStore)
    /// The freshly-minted QR payload while the pairing pane is open (nil otherwise).
    /// Rendered as a QR for the phone to scan.
    @Published var pendingPairingPayload: LANPairingPayload?
    /// The LAN counterpart of the agent bridge: NWListener + Bonjour + TLS-PSK,
    /// feeding accepted connections into the SAME BridgeRouter pipeline. Runs only
    /// while a device is paired or the pairing pane is open. Lazily constructed.
    lazy var lanBridgeServer: LANBridgeServer = {
        LANBridgeServer(
            host: self,
            pskProvider: { [weak self] in self?.pairingStore.pskLookup() ?? [:] },
            deviceName: { Host.current().localizedName ?? "Mac" },
            instanceName: { [weak self] in self?.syncServiceInstanceName ?? "OpenWhisp" },
            onPeerHandshake: { [weak self] peerID, clientName in
                guard let self else { return }
                self.pairingStore.confirmPairing(peerID: peerID, phoneDisplayName: clientName)
                // The pane reads pairingStore.pairedPeers directly — publish so
                // the placeholder row updates to the phone's real name live.
                self.objectWillChange.send()
            })
    }()

    /// Bias whisper recognition toward custom terms. Default-on; harmless when
    /// the vocabulary is empty (no prompt is sent).
    @Published var customVocabularyEnabled: Bool {
        didSet { settingsStore.set(customVocabularyEnabled, forKey: "customVocabularyEnabled") }
    }

    /// User's custom vocabulary (bias terms + heard→correct substitutions).
    /// Persisted to a JSON file in Application Support via VocabularyStore. The save
    /// is DEBOUNCED (see `scheduleVocabularySave`): the usage-count bump now fires on
    /// the paste hot path every dictation, and a synchronous atomic JSON write there
    /// would be needless main-thread I/O. A short coalescing window turns rapid
    /// dictations into one write while still persisting an explicit edit (star / add
    /// rule) within a fraction of a second.
    @Published var vocabulary: Vocabulary {
        didSet { scheduleVocabularySave() }
    }
    /// Debounce timer coalescing vocabulary saves. Main-actor only.
    private var vocabularySaveTimer: Timer?

    /// Self-learning dictionary (MAK-41): watch AX-path inserts for a
    /// type-over-the-word correction and PROPOSE it (never auto-apply). Default-on;
    /// gated further by `customVocabularyEnabled`. Off = the watcher never arms.
    @Published var correctionLearningEnabled: Bool {
        didSet { settingsStore.set(correctionLearningEnabled, forKey: "correctionLearningEnabled") }
    }

    /// Pending learned-correction proposals + declined keys, persisted locally.
    /// The editor renders `pending`; `acceptCorrectionProposal` / `rejectCorrectionProposal`
    /// mutate it. Never leaves the machine.
    @Published var correctionProposals: CorrectionProposalState {
        didSet { CorrectionProposalStore.save(correctionProposals) }
    }

    /// MAK-34 — live screen-context awareness config. Strictly opt-in (off by
    /// default), per-app allowlisted. Persisted as a single JSON blob in
    /// UserDefaults (it carries an array, so the per-bool key idiom doesn't fit).
    /// The captured context itself is NEVER persisted — only this config is.
    @Published var screenContext: ScreenContextSettings {
        didSet { persistScreenContext(screenContext) }
    }

    /// The screen context captured at the start of the CURRENT session (bias terms
    /// + bounded surrounding text), or nil when the gate denied it / nothing was
    /// read. Held in memory for the session only; cleared on the next start and on
    /// finish. Never written to disk.
    private var sessionScreenContext: SessionScreenContext?

    /// In-memory capture from `ScreenContextGate` + `ScreenContextReader` for one
    /// dictation session.
    struct SessionScreenContext {
        /// Extra bias terms appended to the whisper initial prompt for this session.
        var biasTerms: [String]
        /// Bounded surrounding text for the local refine LLM, or nil.
        var llmContext: String?
    }

    /// macOS AX watcher that captures a post-insert single-word correction. Nil on
    /// platforms/builds without it; armed after a completed AX-path final insert.
    private let correctionWatcher = AXCorrectionWatcher()


    // MARK: - Runtime State

    @Published var isRecording = false
    /// True while a Meeting-mode capture (MAK-50) is running. A meeting and a
    /// dictation share the mic, so they are mutually exclusive: the app delegate
    /// sets this on meeting Start/Stop and `startDictation` refuses while it's set.
    @Published var meetingInProgress = false
    @Published var isTranscribing = false {
        didSet {
            // Stamp the moment finalize begins (recording stopped → transcribing) so
            // stats can measure transcription latency, regardless of which stop path
            // ran. Only the first true-transition per session is recorded; cleared in
            // beginSession. Stats-only — see recordStats.
            if isTranscribing, !oldValue, transcriptionStartedAt == nil {
                transcriptionStartedAt = Date()
            }
        }
    }
    /// True from `beginSession()` until audio capture actually goes live
    /// (`.recording`) or the session tears down. During this window the overlay
    /// is visible but the microphone is NOT capturing yet — speaking here loses
    /// the leading word(s). The overlay shows a "starting / not capturing yet"
    /// cue instead of the green "speak now" cue. See `OverlayPhase`.
    @Published var isArming = false
    @Published var lastTranscription: String?
    /// The text this session actually inserted into the FOCUSED app (not a sink), kept
    /// so the overlay "revert to original" (MAK-35) can attempt an in-place swap of
    /// exactly those words for the raw pre-cleanup transcript. Set only on the
    /// focused-app insert path; nil when the last output went to a file/webhook/shortcut
    /// sink or nothing was inserted. Cleared once reverted so a swap can't run twice.
    private var lastInsertedIntoFocusedApp: String?
    @Published var streamingText: String = ""
    @Published var statusMessage: String = "Ready"
    @Published var error: String?
    @Published var whisperWorkerStatus: String = "Not started"
    @Published var translationStatus: String = "Not configured"
    /// Explanation for a settings change made on the user's behalf while
    /// switching engines (e.g. WhisperKit snapping "Type live" to Preview).
    /// Session-only, shown as a callout in Settings › Models; never persisted.
    @Published var engineSwitchNotice: String? = nil
    @Published var modelDownloadStatus: String = "Not checked"
    @Published var isModelDownloading = false
    /// Download completion fraction in 0.0...1.0, or `nil` when the total size
    /// is unknown (indeterminate progress — fall back to a spinner).
    @Published var modelDownloadProgress: Double? = nil
    /// Set when the most recent model download failed, so the UI can offer a
    /// retry action. Cleared when a (re)download starts or succeeds.
    @Published var modelDownloadFailed = false

    // WhisperKit model manager (separate from the GGML download state above).
    /// Model id currently downloading, or nil when idle (only one at a time).
    @Published var whisperKitDownloadingModel: String? = nil
    /// 0…1 progress for the in-flight WhisperKit model download.
    @Published var whisperKitDownloadProgress: Double = 0
    /// Human-readable status/error for the WhisperKit model manager.
    @Published var whisperKitDownloadStatus: String = ""
    /// Set when the most recent WhisperKit download failed (mirrors
    /// `modelDownloadFailed` for the GGML path) — the onboarding model step's
    /// retryable failure card keys on it. Cleared when a (re)download starts.
    @Published var whisperKitDownloadFailed = false
    /// Staged WhisperKit model ids (refreshed after a download / on open).
    @Published var whisperKitStagedModels: [String] = []

    @Published var audioLevel: Float = 0
    @Published var recordingElapsed: TimeInterval = 0
    @Published var inputMonitoringPermissionLabel: String = "Unknown"

    /// Banners for permissions that are needed but missing RIGHT NOW, re-checked
    /// on launch and whenever the app becomes active. Live state only — never
    /// persisted (a reinstall silently revokes Accessibility, so any cached
    /// "granted" flag would lie). Decision logic lives in PermissionBannerPolicy.
    @Published var missingPermissionBanners: [PermissionBannerPolicy.Permission] = []

    /// Session-scoped dismissal tracking for the permission banners.
    private var permissionBannerPolicy = PermissionBannerPolicy()

    /// Last inferred Input Monitoring state (from the hotkey event-tap attempt);
    /// nil until the monitor has reported. There is no direct "is granted" API.
    private var inputMonitoringGranted: Bool?

    /// Whether the user has completed (or skipped) the first-run onboarding.
    @Published var didCompleteOnboarding: Bool {
        didSet { settingsStore.set(didCompleteOnboarding, forKey: "didCompleteOnboarding") }
    }

    // MARK: - Discoverability hints (MAK-25)

    /// Count of counted user dictation sessions (never agent/refine) — the input to
    /// the rotating-hint auto-off window. Incremented once per completed user
    /// dictation in `recordStats`. Persisted so the first-run window survives quits.
    @Published private(set) var hintSessionCount: Int {
        didSet { settingsStore.set(hintSessionCount, forKey: "hintSessionCount") }
    }

    /// Ids of overlay hints the user has permanently dismissed. Persisted; a
    /// dismissed hint never shows again (see `HintRotation`).
    @Published private(set) var dismissedHintIDs: Set<String> {
        didSet { settingsStore.set(Array(dismissedHintIDs), forKey: "dismissedHintIDs") }
    }

    /// The rotating overlay hint to show for the current first-run session, or nil
    /// when hints are off (past the window / all dismissed). The overlay layers its
    /// own LIVE-state suppression on top (never during arming/finalizing/agent/
    /// refine/lock) — this is only the "which hint, is the feature still on" call.
    var currentOverlayHint: TipsCatalog.Hint? {
        // `hintSessionCount` is bumped at session COMPLETION (recordStats), so during
        // a live session it counts only the *previous* sessions. HintRotation expects
        // a 1-based count including the current one — hence the +1 (the very first
        // dictation is session 1, not 0, so it gets a hint too).
        HintRotation.hint(sessionCount: hintSessionCount + 1, dismissed: dismissedHintIDs)
    }

    /// Permanently dismiss the given overlay hint so it never rotates in again.
    func dismissOverlayHint(_ id: String) {
        dismissedHintIDs.insert(id)
    }

    // MARK: - Services

    /// Platform secret backend (Keychain on macOS). Injected so the secret
    /// logic is testable and a port can swap the implementation. See SecretStore.
    let secretStore: SecretStore

    /// Platform launch-at-login backend (SMAppService on macOS). Injected for the
    /// same reasons. See LaunchAtLoginService.
    let launchAtLoginService: LaunchAtLoginService

    /// Platform text-insertion backend (Accessibility + Cmd+V on macOS). Injected
    /// so the orchestration depends on the TextOutput protocol, not the concrete
    /// inserter. See TextOutput.
    let textOutput: TextOutput

    var audioRecorder: AudioCapture!
    var whisperEngine: FileTranscriptionEngine!

    /// Batch audio/video file transcription (MAK-36). Lazily built so it only
    /// spins up its queue/watcher when the Files pane is first opened. Uses a
    /// DEDICATED engine per job (never the live-dictation `whisperEngine`).
    lazy var fileCoordinator: FileTranscriptionCoordinator = {
        FileTranscriptionCoordinator(engineConfig: { [weak self] in
            self?.fileEngineConfig() ?? .init(
                makeEngine: { WhisperEngine() }, binaryPath: "", modelPath: "",
                languageSetting: "auto", backend: .cli, prompt: "", enhance: nil
            )
        })
    }()

    /// The current engine/model/backend config for batch file transcription,
    /// mirroring the live-dictation `startTranscription` wiring.
    func fileEngineConfig() -> FileTranscriptionCoordinator.EngineConfig {
        let engineName = transcriptionEngine
        let model = modelName
        let wkModel = whisperKitModel
        return .init(
            makeEngine: { Self.makeFileEngine(for: engineName, model: model, whisperKitModel: wkModel) },
            binaryPath: whisperBinaryPath,
            modelPath: modelPath,
            languageSetting: engineLanguageSetting,
            backend: whisperBackend == "serverAPI" ? .serverAPI : .cli,
            prompt: customVocabularyEnabled ? vocabulary.whisperPrompt : "",
            enhance: llmConfigured ? { [weak self] raw in
                // Reuse the overlay-refine LLM primitive. Fail-open: any error
                // (LLM busy, unavailable, mid-dictation) returns the raw text.
                await withCheckedContinuation { cont in
                    Task { @MainActor in
                        guard let self else { cont.resume(returning: raw); return }
                        self.refineText(
                            text: raw,
                            instruction: "Clean up this transcript: fix punctuation, casing, and obvious transcription mistakes. Keep the wording and meaning; do not summarize or omit content."
                        ) { result in
                            switch result {
                            case .success(let enhanced): cont.resume(returning: enhanced)
                            case .failure: cont.resume(returning: raw)
                            }
                        }
                    }
                }
            } : nil
        )
    }
    /// Meeting mode (MAK-50): transcribe + locally summarize recorded meetings.
    /// Lazily built so it only loads its store when the Meetings pane opens. Uses a
    /// DEDICATED transcription engine per job (like `fileCoordinator`) and routes
    /// summaries through the existing refine primitive. The capture half feeds it a
    /// `MeetingRecording` via `ingest(_:)` (the integration seam).
    lazy var meetingCoordinator: MeetingPipelineCoordinator = {
        MeetingPipelineCoordinator(
            transcriptionConfig: { [weak self] in
                self?.meetingTranscriptionConfig() ?? .init(
                    makeEngine: { WhisperEngine() }, binaryPath: "", modelPath: "",
                    languageSetting: "auto", backend: .cli, prompt: ""
                )
            },
            summarizeCall: { [weak self] instruction, input, resolved in
                // Route each summarize prompt through the RESOLVED summary model
                // (MAK-53) — a separate provider/model from dictation cleanup.
                // (instruction = the summary/map/combine prompt, input = the text).
                try await withCheckedThrowingContinuation { cont in
                    Task { @MainActor in
                        guard let self else {
                            cont.resume(throwing: MeetingSummarizeError.unavailable); return
                        }
                        self.summarizeResolved(text: input, instruction: instruction, resolved: resolved) { result in
                            switch result {
                            case .success(let out): cont.resume(returning: out)
                            case .failure(let err): cont.resume(throwing: err)
                            }
                        }
                    }
                }
            },
            resolveSummaryModel: { [weak self] in
                self?.resolvedSummaryModel() ?? .init(provider: "", model: "", endpoint: "")
            }
        )
    }()

    /// Transcription engine config for a meeting job, mirroring `fileEngineConfig`.
    func meetingTranscriptionConfig() -> MeetingPipelineCoordinator.TranscriptionConfig {
        let engineName = transcriptionEngine
        let model = modelName
        let wkModel = whisperKitModel
        return .init(
            makeEngine: { Self.makeFileEngine(for: engineName, model: model, whisperKitModel: wkModel) },
            binaryPath: whisperBinaryPath,
            modelPath: modelPath,
            languageSetting: engineLanguageSetting,
            backend: whisperBackend == "serverAPI" ? .serverAPI : .cli,
            prompt: customVocabularyEnabled ? vocabulary.whisperPrompt : ""
        )
    }

    var appleSpeechEngine: StreamingTranscriptionEngine!
    /// Experimental real-time WhisperKit engine. Shares the streaming session
    /// machinery with Apple Speech (same handlers) but uses WhisperKit's
    /// `AudioStreamTranscriber` (owns the mic, built-in VAD, multilingual).
    var whisperKitStreamEngine: StreamingTranscriptionEngine!
    /// True-streaming Parakeet/CoreML engine (MAK-46 spike, PARAKEET builds).
    /// Concrete type (not the protocol) so `prefetch()` — the model download
    /// kick — is callable; sessions still go through `activeStreamingEngine`.
    var parakeetStreamEngine: ParakeetStreamingEngine!
    /// Apple SpeechAnalyzer live-dictation engine (macOS 26, MAK-59). Shares the
    /// streaming session machinery with the other streamers; only constructed and
    /// selected when the OS supports it (SpeechAnalyzerAvailability).
    var speechAnalyzerStreamEngine: StreamingTranscriptionEngine!
    /// Variant ids with a Parakeet model prefetch/warm in flight — drives the
    /// coarse "Downloading…" badge in the Models pane (FluidAudio has no progress
    /// callback, so this is presence-of-folder + this in-flight flag). Cleared
    /// when the variant's repo folder appears on disk (polled by the pane).
    @Published var parakeetInFlightVariants: Set<String> = []
    /// True when the last Parakeet model prefetch FAILED (e.g. offline first-run)
    /// and its repo folder never landed. FluidAudio exposes no progress or error
    /// callback, so this is the only failure signal — it lets onboarding show a
    /// retryable "couldn't download" state instead of a perpetual spinner. Set
    /// when `prefetchAwaiting()` returns false with the folder still absent;
    /// cleared whenever a fresh prefetch is kicked (the Retry path).
    @Published var parakeetPrefetchFailed = false
    var translationService: OpenAITranslationService!
    var hotkeyMonitor: HotkeyControlling!

    private var overlayController: OverlayWindowController?
    /// The floating Scratchpad panel (MAK-49) — a target-free surface to dictate
    /// into. Lazily created on first open so the panel/text-view cost is paid only
    /// when the feature is used. When the pad is the frontmost key window, a
    /// completed dictation appends into its active note instead of the focused app.
    lazy var scratchpadController = ScratchpadWindowController(appState: self)
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
    /// When the current session entered the transcribing/finalize phase (set via the
    /// isTranscribing didSet, cleared per session). Used only to measure stats latency.
    private var transcriptionStartedAt: Date?
    /// Local-only, metadata-only dictation stats (collected, not surfaced in UI).
    private var dictationStats = DictationStatsStore.load()
    #if OPENWHISP_INSTRUMENTATION
    /// Most recent completed dictation event, for the dev debug HUD only.
    private var lastDictationEvent: DictationEvent?
    #endif
    private var targetApplication: NSRunningApplication?
    private var overlayIsVisible = false
    private var activeSessionID = UUID()
    /// The session that last started the AudioRecorder. The recorder's
    /// onStateChanged callback is wired once (not per-session) and delivers
    /// through a main-actor Task hop, so a state change from a cancelled
    /// session can land after the next session already began — e.g. a stale
    /// `.stopped` clearing the isRecording a new streaming session just set,
    /// wedging it (its stop would then only set pendingStop, which nothing
    /// consumes once streaming is live). Comparing this against
    /// activeSessionID drops those stale transitions.
    private var recorderSessionID: UUID?
    private var transcriptionRequests: [UUID: TranscriptionRequest] = [:]

    /// Strong ref to the throwaway engine driving a history re-transcribe (MAK-40),
    /// held only while its one-shot request is in flight so it isn't deallocated
    /// mid-transcription. Cleared in the completion/error callback.
    private var reTranscribeEngine: FileTranscriptionEngine?
    /// Pure ordering/sequencing state machine for live-chunk dictation (sequence
    /// assignment, concurrency cap, out-of-order reorder buffer, insertion queue,
    /// drain detection). AppState owns the side effects (transcribe/insert/file IO);
    /// this owns the bookkeeping. See LiveChunkPipeline.
    private var livePipeline = LiveChunkPipeline(maxConcurrent: 2)
    /// Chunk payloads (WAV file URLs) keyed by the pipeline's ChunkID, so AppState
    /// can transcribe / clean up files while the pipeline tracks only sequencing.
    private var liveChunkURLs: [LiveChunkPipeline.ChunkID: URL] = [:]
    private var currentSessionText = ""
    private var isStreamingSession = false
    private var acceptingLiveChunks = false
    /// True from beginSession() until the session terminates. Tracks dictation intent
    /// independently of isRecording, which only flips true inside async grant callbacks.
    private var sessionActive = false
    /// Set when a stop arrives before the grant callback has started recording.
    private var pendingStop = false
    /// Set while a preempt-deferred startDictation is queued (an agent session
    /// was cancelled this turn; the user's session starts next turn). A stop or
    /// cancel arriving in that one-turn gap consumes the flag so the deferred
    /// start no-ops instead of arming a session whose stop already passed.
    private var pendingPreemptStart = false
    private var openAIEnhancementEnabledForSession = false

    // MARK: Agent Bridge session plumbing (dormant until M8 wires the bridge)
    //
    // A dictation session is normally user-initiated and pastes its result. An
    // agent-initiated session (via the Agent Bridge, M8) instead RETURNS its
    // transcript to the calling client and pastes nothing. These fields carry
    // that intent through the existing funnel additively — default `.user` /
    // false / nil, so a user-initiated session behaves exactly as before.

    /// Who started the current session. Set by the caller BEFORE beginSession()
    /// (the agent path sets `.agent`; the user hotkey leaves it `.user`) and reset
    /// to `.user` in finishSessionUI().
    private var sessionInitiator: SessionInitiator = .user
    /// Session snapshot of "return the transcript, don't paste it", frozen in
    /// beginSession() from the initiator (like isPreviewSession) and cleared in
    /// finishSessionUI(). Read in insertCompletedText().
    private var suppressOutput = false
    /// The outcome recorded at the session's terminal point, read once by
    /// onSessionEnd in finishSessionUI(). Defaults to `.cancelled` if never set
    /// (abort, or an error terminal that didn't record one).
    private var sessionOutcome: SessionOutcome?
    /// Fired exactly once in finishSessionUI() with the session outcome, then
    /// cleared. nil for user sessions. The Agent Bridge sets this to receive the
    /// dictation result of an agent-initiated session.
    private var onSessionEnd: ((SessionOutcome) -> Void)?

    // MARK: Instruction chaining (dedicated-key refine flow)
    //
    // Refine is triggered by a DEDICATED chord (Fn+Ctrl by default) — separate
    // from the dictation key — so a plain dictation always pastes instantly (no
    // re-press disambiguation, no paste deferral). The lifecycle lives in the pure
    // `RefineFlow` state machine (RefineFlow.swift); AppState feeds it events and
    // executes the effects it returns.
    private var refineFlow = RefineFlow()
    /// The most recent completed dictation's final text, kept in memory so the
    /// dedicated Refine key can refine "what I just dictated" when there's no
    /// selection. Just a record — the text was already pasted normally.
    private var lastDictationText: String?
    /// Overlay cue: true whenever a refine is engaged. Published so OverlayView can
    /// show the "refining" tint. Kept in sync with the state machine via `syncRefineUI`.
    @Published private(set) var refineArmed = false
    /// Set when the user taps the Refine key MID-DICTATION (while still holding Fn):
    /// everything spoken after this point is the instruction; everything before is
    /// the content to refine. Applied on Fn release. nil = not refining this session.
    /// Published so the overlay can freeze the dictated content and render the
    /// live instruction as its own visually distinct row.
    @Published private(set) var refineContentSnapshot: String?
    /// The finalized spoken instruction while the refine LLM runs — the snapshot
    /// is consumed at that point, so the overlay reads this to keep the
    /// instruction row visible through the rewrite. Cleared when refine disarms.
    @Published private(set) var refineActiveInstruction: String?
    /// Whether the armed refine's content came from the user's selection (vs.
    /// dictation): an empty instruction then leaves the selection untouched
    /// instead of re-inserting it. Set alongside `refineContentSnapshot`.
    private var refineContentFromSelection = false
    /// Generation counter for idle-arm expiry: an idle arm (refine tapped with
    /// no active session) is invisible on screen, so it auto-expires unless a
    /// dictation starts soon after.
    private var refineArmGeneration = 0
    /// How long an idle refine arm stays live before expiring.
    private static let idleRefineArmTimeout: TimeInterval = 10

    /// How long the post-dictation overlay lingers when AI cleanup changed the words
    /// and the "revert to original" control is offered — long enough to read the
    /// result and click revert, short enough not to overstay (MAK-35). Well under the
    /// idle-refine window so it never collides with a follow-up refine arm.
    private static let revertOverlayHold: TimeInterval = 6

    /// Set briefly when an insert couldn't be confirmed and the text was left on the
    /// clipboard instead — drives a "copied, press ⌘V" cue in the overlay so the
    /// result is never silently lost.
    @Published private(set) var clipboardFallbackActive = false
    /// Snapshot of whether this session uses live-chunk output, captured at
    /// beginSession(). The live-chunk drain pipeline must be gated on this rather
    /// than the live @Published outputMode, so a mid-session settings change can't
    /// strand queued chunks and hang the session in "Finalizing...".
    private var isLiveChunkSession = false
    /// Snapshot of preview-and-polish mode for this session. In preview mode
    /// chunks are captured (into currentSessionText/streamingText for the overlay)
    /// but NOT pasted; the whole text is polished once at finalization and pasted
    /// a single time. Snapshotted at beginSession so a mid-session settings change
    /// can't change the paste behavior partway through.
    private var isPreviewSession = false
    private var isAppleSpeechSession = false
    private var appleLiveInsertedText = ""
    private var appleDidCompleteFinal = false
    /// Whether spoken edit commands (`voiceEditingEnabled`) are honored for THIS
    /// session — snapshotted in `startStreamingSession()` (the streaming path that
    /// reaches `handleAppleSpeechFinal`, where `outputMode` is authoritative), so a
    /// mid-session settings flip can't change how the pending text is finalized.
    /// Only ever true for a preview-mode streaming session (the mode where text is
    /// held until the end and can therefore still be edited before the single paste).
    private var voiceEditingActiveForSession = false
    /// The session's edit buffer: finalized dictation utterances accumulate here and
    /// standalone edit commands ("scratch that" / "undo" / …) mutate it, so the
    /// pasted text is `voiceEditBuffer.text` — the dictation AFTER the spoken edits.
    /// Reset at beginSession; only read when `voiceEditingActiveForSession`.
    private var voiceEditBuffer = VoiceEditBuffer()
    /// True when the active engine/variant emits end-of-utterance events — only
    /// the Parakeet EOU streaming variant does (MAK-46 Phase 5). Gates arming the
    /// agent EOU auto-stop so it stays inert on every other engine.
    var activeEngineEmitsEou: Bool {
        transcriptionEngine == "parakeet" && ParakeetCatalog.emitsEou(parakeetVariant)
    }

    /// The streaming engine for the current/next session. All conform to the
    /// same protocol and route through the same session handlers.
    private var activeStreamingEngine: StreamingTranscriptionEngine {
        switch transcriptionEngine {
        case "whisperKit":     return whisperKitStreamEngine
        case "parakeet":       return parakeetStreamEngine
        case "speechAnalyzer": return speechAnalyzerStreamEngine
        default:               return appleSpeechEngine
        }
    }
    /// Model paths with a download currently in flight. Per-path (not a single
    /// value): switching models mid-download starts a second download, and each
    /// one must dedupe itself without clearing the other's guard.
    private var inFlightModelDownloads: Set<String> = []

    /// Global setting values saved before a per-app profile temporarily overrode
    /// them for the current session, so they can be restored when it ends.
    private var profileOverrideBackup: (language: String, translateToEnglish: Bool, outputMode: String, aiCleanup: Bool)?

    /// The refine instruction contributed by the Mode active for the current
    /// session (MAK-39): the composed tone + free-form instruction. nil when no
    /// Mode is active or the active Mode steers nothing. Session-scoped: set in
    /// `applyProfileForFrontmostApp`, cleared in `restoreProfileOverridesIfNeeded`.
    /// `makeWholeTextRefiner` prefers it over the intensity-dial prompt so a Mode's
    /// style actually reaches the LLM.
    private var modeRefineInstructionOverride: String?

    /// Per-app refine-preset prompt (MAK-77); same lifecycle as the Mode override
    /// above, loses to it in the composer, never exempts the RefineOutputGuard.
    private var presetRefineInstructionOverride: String?

    /// A per-app profile's text-insert method for the CURRENT session (MAK-42), or
    /// nil when no profile overrides it. Kept separate from the persisted global
    /// `insertionMode` (unlike the other overrides it isn't a published setting the
    /// UI mirrors), so it's a plain session-scoped value: set on profile apply,
    /// cleared on restore, and preferred by `currentInsertionMode`.
    private var sessionInsertionModeOverride: InsertionMode?

    /// While a per-app profile override is in effect, don't persist the overridden
    /// settings to UserDefaults — otherwise a crash/force-quit mid-session would
    /// leave the profile's values as the user's globals on next launch.
    private var suppressSettingsPersistence = false

    /// Persist a setting unless a profile override is currently active.
    private func persist<T>(_ value: T, _ key: String) {
        guard !suppressSettingsPersistence else { return }
        settingsStore.set(value, forKey: key)
    }

    private enum TranscriptionKind {
        case liveChunk
        case final
    }

    private struct TranscriptionRequest {
        let sessionID: UUID
        let kind: TranscriptionKind
        let sequence: Int?
    }

    private var shouldEnhanceCurrentSession: Bool {
        openAIEnhancementEnabledForSession && openAIEnhancementEnabled
    }

    private var shouldEnhanceLiveChunks: Bool {
        // Agent sessions (suppressOutput) never enhance — the transcript goes back
        // raw and the agent refines explicitly, matching the whole-text gate in
        // completeFinalText.
        shouldEnhanceCurrentSession && !suppressOutput
            && outputMode == "liveChunks" && openAIEnhancementMode == "rephrase"
    }

    private var currentInsertionMode: InsertionMode {
        // A per-app profile can override the insert method for the session (MAK-42);
        // otherwise use the global setting.
        sessionInsertionModeOverride ?? InsertionMode(rawValue: insertionMode) ?? .auto
    }

    /// The active LLM endpoint for post-processing, derived from the provider setting.
    var llmEndpoint: LLMEndpoint {
        if llmProvider == "bundled" {
            // Loopback to the bundled llama-server. The engine must already be
            // running (callers gate refinement behind `ensureBundledLLMReady`),
            // so its dynamic port is live here.
            return LLMEndpoint(
                baseURL: ensureLlamaEngine().baseURL,
                apiKey: "",
                requiresKey: false
            )
        }
        if llmProvider == "local" {
            return LLMEndpoint(
                baseURL: localLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/$", with: "", options: .regularExpression),
                apiKey: "",
                requiresKey: false
            )
        }
        var ep = LLMEndpoint.openAI
        ep.apiKey = openAIAPIKey
        return ep
    }

    /// The model name to request, per provider.
    var llmModel: String {
        switch llmProvider {
        case "bundled": return bundledLLMModel
        case "local":   return localLLMModel
        default:        return openAIModel
        }
    }

    /// Resolve the summarization model (MAK-53) from the summary override +
    /// cleanup globals. The `sameAsCleanup` default resolves to today's cleanup
    /// provider/model, so existing installs are unchanged.
    func resolvedSummaryModel() -> SummaryModelResolver.Resolved {
        SummaryModelResolver.resolve(
            override: .init(provider: summaryLLMProvider, model: summaryLLMModel, endpoint: summaryLLMEndpoint),
            globalProvider: llmProvider,
            globalModel: llmModel,
            globalEndpoint: llmProvider == "local"
                ? localLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
        )
    }

    /// The `LLMEndpoint` for a RESOLVED summary provider (MAK-53). Mirrors
    /// `llmEndpoint` but keyed on the resolved provider/endpoint rather than the
    /// global cleanup provider: bundled → the loopback llama-server; local → the
    /// resolved server URL (falling back to the cleanup URL); openai → the cloud
    /// endpoint with the configured key.
    func summaryEndpoint(for resolved: SummaryModelResolver.Resolved) -> LLMEndpoint {
        switch resolved.provider {
        case "bundled":
            return LLMEndpoint(baseURL: ensureLlamaEngine().baseURL, apiKey: "", requiresKey: false)
        case "local":
            let url = resolved.endpoint.isEmpty
                ? localLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                : resolved.endpoint
            return LLMEndpoint(
                baseURL: url.replacingOccurrences(of: "/$", with: "", options: .regularExpression),
                apiKey: "", requiresKey: false
            )
        default:
            var ep = LLMEndpoint.openAI
            ep.apiKey = openAIAPIKey
            return ep
        }
    }

    /// Map a refinement `mode` to the bundled-LLM variant when the built-in
    /// provider is active, so tiny on-device models get the terser, stricter
    /// system prompt (see OpenAITranslationService.instructionForMode).
    private func refinementMode(_ mode: String) -> String {
        guard llmProvider == "bundled" else { return mode }
        return mode == "rephrase" ? "bundled-rephrase" : "bundled-improve"
    }

    /// The whole-text final AI step, expressed as the `AsyncTextRefiner` seam
    /// (MAK-15). This is the concrete `AIPostProcessor` refiner for the
    /// `VocabularySubstitutor → SmartFormatter → AIPostProcessor` chain: the app
    /// owns the network call (`OpenAITranslationService`) so core stays
    /// Foundation-only, and the chain composes this transform uniformly.
    ///
    /// A snapshot of the session's LLM settings, built per call so a mid-session
    /// settings change is reflected. Used by `completeFinalText` today; the rest
    /// of the AI orchestration (engine bracket, session guards, status UI) stays in
    /// AppState because those are UI/lifecycle concerns the pure chain doesn't model.
    ///
    /// Provider selection (MAK-44): when the user picked the agent-CLI backend, this
    /// returns an `AgentCLIRefiner` (pipe the transcript through claude/codex/custom)
    /// instead of `OpenAIRefiner`. Both conform to `AsyncTextRefiner`, so the
    /// `AIPostProcessor` chain and `completeFinalText` orchestration are unchanged.
    /// Every other provider keeps the OpenAI-service refiner — the default path.
    func makeWholeTextRefiner() -> AsyncTextRefiner {
        if EnhancementProvider.usesAgentCLI(llmProvider) {
            // The agent CLI carries its own prompting/agent config; the intensity
            // dial only gates whether it runs (via the `.none` skip upstream), not
            // its system prompt, so this path is unchanged.
            return AgentCLIRefiner(config: activeAgentCLIConfig)
        }
        // MAK-35/39/77: precedence Mode > per-app preset > intensity dial, via the
        // ONE composer funnel (improveTranslation carve-out + `.none` live there).
        let baseInstruction = RefineInstructionComposer.sessionInstruction(
            modeOverride: modeRefineInstructionOverride,
            presetOverride: presetRefineInstructionOverride,
            intensity: cleanupIntensity, mode: openAIEnhancementMode,
            translateToEnglish: effectiveTranslateToEnglish)
        // MAK-34: when the gate captured surrounding text this session (only ever
        // for a LOCAL provider — see ScreenContextGate), append it to the cleanup
        // system prompt as reference-only material so the local model matches the
        // thread's tone/vocabulary. Only augments a non-nil base instruction; a nil
        // one is the translation-polish carve-out that must reach its own branch, so
        // we leave it alone. The local-only guarantee is enforced by the gate at
        // capture time — but this refiner is deliberately built per call so
        // mid-session settings changes are reflected, which means the provider can
        // have CHANGED since capture (e.g. bundled → openai while dictating). So the
        // local-only rule is re-checked HERE, at use time, against the provider the
        // request will actually hit: a non-local provider never sees the context,
        // even when it was legitimately captured under a local one.
        let customInstruction: String?
        if let base = baseInstruction, let ctx = sessionScreenContext?.llmContext,
           ScreenContextGate.localRefineProviders.contains(llmProvider) {
            customInstruction = ScreenContextTruncator.augmentedInstruction(base, withContext: ctx)
        } else {
            customInstruction = baseInstruction
        }
        return OpenAIRefiner(
            service: translationService,
            mode: refinementMode(openAIEnhancementMode),
            targetLanguage: translationTargetLanguage,
            endpoint: llmEndpoint,
            model: modeOverriddenLLMModel,
            // customInstruction composes both merged features: the Mode override
            // (MAK-39) is the base via `baseInstruction`, and the screen-context
            // augmentation (MAK-34, local-only, re-checked above) wraps it.
            customInstruction: customInstruction
        )
    }

    /// The LLM model the whole-text refiner should use: the active Mode's override
    /// when it pins one (MAK-39), else the global `llmModel`. Session-scoped, so it
    /// reverts automatically when the Mode's overrides are restored.
    private var modeOverriddenLLMModel: String {
        activeModeLLMModel ?? llmModel
    }

    /// LLM model pinned by the Mode active for the current session, or nil. Set
    /// alongside `modeRefineInstructionOverride` (same lifecycle).
    private var activeModeLLMModel: String?

    /// Whether this build includes the built-in LLM runtime (llama-server).
    /// False for an app packaged without it — the built-in provider then can't
    /// work no matter what, and the UI should say so rather than fail vaguely.
    var bundledLLMRuntimeAvailable: Bool {
        LlamaServerEngine.runtimeAvailable()
    }

    /// Whether the active LLM provider is configured enough to call.
    var llmConfigured: Bool {
        switch llmProvider {
        case EnhancementProvider.agentCLIID:
            // Configured when the selected preset/custom fields build a valid argv
            // (non-empty command, no transcript-in-args). We can't verify the CLI is
            // actually installed here without spawning it — that's the runner's
            // fail-open job — but an empty custom command is a clear misconfig.
            if case .success = AgentCLIProvider.buildCommand(config: activeAgentCLIConfig) {
                return true
            }
            return false
        case "bundled":
            // Configured only when this build can run the LLM at all AND the
            // selected model is actually on disk. The runtime check keeps
            // features like Refine from arming against a provider that is
            // guaranteed to fail (an app packaged without the llama runtime).
            return bundledLLMRuntimeAvailable
                && FileManager.default.fileExists(atPath: selectedLLMModelPath())
        case "local":
            return !localLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var hotkeyHelpText: String {
        let trigger: String
        switch triggerMode {
        case "fn":     trigger = "Release Fn"
        case "custom": trigger = "Release \(customTrigger.displayName)"
        default:       trigger = "Release Control+Space"
        }
        return "\(trigger) to insert - Esc to cancel"
    }

    /// The engine-facing language setting: the user's spoken language, or the
    /// translate-to-English sentinel when translation is on. Apple Speech has
    /// no translate concept, so it always gets the plain language (used as a
    /// locale hint).
    var engineLanguageSetting: String {
        LanguageResolver.engineLanguageSetting(
            language: language,
            translateToEnglish: translateToEnglish,
            transcriptionEngine: transcriptionEngine
        )
    }

    /// The language of the OUTPUT text, for formatting rules (spoken
    /// punctuation etc.): English when translating, else the spoken language.
    private var outputLanguageForCleaning: String {
        LanguageResolver.outputLanguageForCleaning(
            language: language,
            translateToEnglish: translateToEnglish,
            transcriptionEngine: transcriptionEngine
        )
    }

    /// The translate intent actually in effect: the stored toggle gated on the
    /// engine's translation capability. The refine layer (cleanup prompts,
    /// RefineOutputGuard's expected script) must key on THIS, never on the raw
    /// `translateToEnglish` — on Parakeet/Apple Speech the transcript stays in the
    /// spoken language (and the UI shows translate as off), so a stale stored
    /// `true` would otherwise disarm the language guard and, in improveTranslation
    /// mode, actively LLM-translate the dictation the engine refused to.
    var effectiveTranslateToEnglish: Bool {
        LanguageResolver.effectiveTranslateToEnglish(
            translateToEnglish: translateToEnglish,
            transcriptionEngine: transcriptionEngine
        )
    }

    /// Whether dictation can send any text off this machine to the internet.
    /// Transcription is always on-device; the only egress is AI post-processing
    /// with the OpenAI (cloud) provider. The local provider stays on machine/LAN.
    /// (One-time model downloads aren't counted — they're not your dictated text.)
    var sendsTextToCloud: Bool {
        PrivacyStatus.sendsTextToCloud(enhancementEnabled: openAIEnhancementEnabled, provider: llmProvider)
    }

    /// Short, user-facing privacy statement for the current configuration.
    var privacyStatusText: String {
        PrivacyStatus.statusText(enhancementEnabled: openAIEnhancementEnabled, provider: llmProvider)
    }

    var languageDisplayName: String {
        Self.languageDisplayName(for: language)
    }

    /// Test/DI seam: when injected, `wireUpServices()` uses these instead of
    /// constructing the concrete `AudioRecorder()` / real file engine. Nil in the
    /// shipping app (the `.shared` singleton), so production wiring is unchanged.
    private let injectedAudioCapture: AudioCapture?
    private let injectedFileEngine: FileTranscriptionEngine?

    /// The persisted-settings backing store (UserDefaults in the shipping app).
    /// Every `@Published` setting reads its saved value from here at init and
    /// writes changes back through here in its `didSet` — this is the seam that
    /// lets the persistence layer be swapped for an in-memory store in tests
    /// (MAK-32 SettingsStore extraction). Keys and value shapes are identical to
    /// the old direct-`UserDefaults` path; do not rename them (iOS contract).
    let settingsStore: SettingsStore

    init(
        secretStore: SecretStore = KeychainStore(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLogin(),
        textOutput: TextOutput = TextInserter(),
        audioCapture: AudioCapture? = nil,
        fileEngine: FileTranscriptionEngine? = nil,
        settingsStore: SettingsStore = UserDefaults.standard
    ) {
        self.secretStore = secretStore
        self.launchAtLoginService = launchAtLoginService
        self.textOutput = textOutput
        self.injectedAudioCapture = audioCapture
        self.injectedFileEngine = fileEngine
        self.settingsStore = settingsStore
        let savedWhisperBinaryPath = settingsStore.string(forKey: "whisperBinaryPath") ?? ""
        whisperBinaryPath = Self.preferredWhisperCLIPath(savedPath: savedWhisperBinaryPath)

        // Versioned settings migration MUST run before any key is read below:
        // it preserves old defaults for existing installs and splits the legacy
        // "en means translate" language value into language + translateToEnglish.
        SettingsMigration.migrate(settingsStore)

        // Default first-run model is "base" (147 MB): fast enough for a quick
        // first success, and — unlike the old "tiny" default — one of the
        // visible quality tiers, so a fresh install never renders as the
        // synthetic "Custom" row. (Existing installs keep "tiny" via migration.)
        let savedModel = settingsStore.string(forKey: "modelName") ?? "base"
        let fileName = Self.modelFileName(for: savedModel)
        modelName = savedModel
        let savedModelPath = settingsStore.string(forKey: "modelPath") ?? ""
        modelPath = Self.preferredModelPath(savedPath: savedModelPath, fileName: fileName)
        microphoneID = settingsStore.string(forKey: "microphoneID") ?? ""
        language = settingsStore.string(forKey: "language") ?? "auto"
        translateToEnglish = settingsStore.object(forKey: "translateToEnglish") as? Bool ?? false
        triggerMode = settingsStore.string(forKey: "triggerMode") ?? "fn"
        // Custom trigger (MAK-17): -1 keycode = bare-modifier binding / unset.
        customTriggerKeyCode = settingsStore.object(forKey: "customTriggerKeyCode") as? Int ?? -1
        customTriggerModifiers = settingsStore.object(forKey: "customTriggerModifiers") as? Int ?? 0
        // Press-to-talk stays the default activation; hands-free lock (toggle) is opt-in.
        hotkeyMode = settingsStore.string(forKey: "hotkeyMode") ?? "hold"
        // Left Control: the old rightControl default doesn't exist on MacBook
        // keyboards, which made refine silently impossible there.
        refineKey = settingsStore.string(forKey: "refineKey") ?? RefineKey.defaultKey.rawValue
        mouseTrigger = settingsStore.string(forKey: "mouseTrigger") ?? MouseTrigger.defaultTrigger.id
        outputMode = settingsStore.string(forKey: "outputMode") ?? "preview"
        showOverlay = settingsStore.object(forKey: "showOverlay") as? Bool ?? true
        voiceIndicatorStyle = VoiceIndicatorStyle.from(settingsStore.string(forKey: "voiceIndicatorStyle"))
        launchAtLogin = launchAtLoginService.isEnabled
        // Restoring is what users assume happens — clipboard clobbering is the
        // top complaint about paste-based dictation. (Existing installs keep
        // their old effective value via migration.)
        restoreClipboard = settingsStore.object(forKey: "restoreClipboard") as? Bool ?? true
        insertionMode = settingsStore.string(forKey: "insertionMode") ?? "auto"
        addTrailingSpace = settingsStore.object(forKey: "addTrailingSpace") as? Bool ?? false
        autoGainEnabled = settingsStore.object(forKey: "autoGainEnabled") as? Bool ?? true
        quietDictationEnabled = settingsStore.object(forKey: "quietDictationEnabled") as? Bool ?? false
        smartFormattingEnabled = settingsStore.object(forKey: "smartFormattingEnabled") as? Bool ?? true
        spokenPunctuationEnabled = settingsStore.object(forKey: "spokenPunctuationEnabled") as? Bool ?? true
        fillerRemovalEnabled = settingsStore.object(forKey: "fillerRemovalEnabled") as? Bool ?? true
        fileTaggingEnabled = settingsStore.object(forKey: "fileTaggingEnabled") as? Bool ?? false
        // MAK-20 structural formatting groups default OFF (opt-in).
        normalizeNumbers = settingsStore.object(forKey: "normalizeNumbers") as? Bool ?? false
        normalizeCurrency = settingsStore.object(forKey: "normalizeCurrency") as? Bool ?? false
        spokenListsEnabled = settingsStore.object(forKey: "spokenListsEnabled") as? Bool ?? false
        basicMarkdownEnabled = settingsStore.object(forKey: "basicMarkdownEnabled") as? Bool ?? false
        liveChunkDuration = settingsStore.object(forKey: "liveChunkDuration") as? Double ?? 2.0
        pauseBasedLiveChunksEnabled = settingsStore.object(forKey: "pauseBasedLiveChunksEnabled") as? Bool ?? false
        transcriptionEngine = settingsStore.string(forKey: "transcriptionEngine") ?? Self.defaultTranscriptionEngine
        whisperKitModel = settingsStore.string(forKey: "whisperKitModel") ?? "openai_whisper-small"
        parakeetVariant = ParakeetCatalog.normalize(
            settingsStore.string(forKey: "parakeetVariant") ?? ParakeetCatalog.defaultVariantID
        )
        if let savedBackend = settingsStore.string(forKey: "whisperBackend") {
            whisperBackend = savedBackend
        } else {
            whisperBackend = "serverAPI"
        }
        openAIEnhancementMode = settingsStore.string(forKey: "openAIEnhancementMode") ?? "rephrase"
        // MAK-35: resolve the AI-cleanup intensity dial. Prefer a stored dial value;
        // on FIRST load for an existing install (no dial persisted yet) derive it
        // from the legacy on/off + mode so behavior is preserved exactly (enabled +
        // rephrase → .medium; disabled → .none). Fresh installs (no legacy keys)
        // fall through to migrated(enabled:false) == .none, matching the old default
        // of AI cleanup off out of the box.
        let resolvedIntensity = CleanupIntensity.resolveInitial(
            storedDialRawValue: settingsStore.string(forKey: "cleanupIntensity"),
            legacyEnabled: settingsStore.object(forKey: "openAIEnhancementEnabled") as? Bool ?? false,
            legacyMode: settingsStore.string(forKey: "openAIEnhancementMode") ?? "rephrase"
        )
        cleanupIntensity = resolvedIntensity
        // Seed the "last non-none" memory so the legacy toggle restores the user's
        // chosen strength — from the persisted key first (survives a relaunch while
        // cleanup was toggled off), else the resolved dial / default. (Read the
        // local `resolvedIntensity`, not the stored property — Swift forbids reading
        // a stored property mid-init before all are initialized.)
        lastNonNoneCleanupIntensity = CleanupIntensity.resolveLastNonNone(
            storedRawValue: settingsStore.string(forKey: "lastNonNoneCleanupIntensity"),
            resolvedIntensity: resolvedIntensity
        )
        translationTargetLanguage = settingsStore.string(forKey: "translationTargetLanguage") ?? "en"
        // One-time migration: move any legacy plaintext key out of UserDefaults into the
        // Keychain. didSet does not fire during init, so the keychain write must be explicit.
        let keychainKey = secretStore.read(key: "openAIAPIKey")
        if let keychainKey, !keychainKey.isEmpty {
            openAIAPIKey = keychainKey
        } else if let legacyKey = settingsStore.string(forKey: "openAIAPIKey"),
                  !legacyKey.isEmpty {
            secretStore.save(legacyKey, key: "openAIAPIKey")
            UserDefaults.standard.removeObject(forKey: "openAIAPIKey")
            openAIAPIKey = legacyKey
        } else {
            openAIAPIKey = ""
        }
        openAIModel = settingsStore.string(forKey: "openAIModel") ?? "gpt-4o-mini"
        // Built-in by default: first enable of AI cleanup works offline with
        // zero setup, matching the product's privacy story. (Existing installs
        // keep "openai" via migration.)
        llmProvider = settingsStore.string(forKey: "llmProvider") ?? "bundled"
        localLLMBaseURL = settingsStore.string(forKey: "localLLMBaseURL") ?? "http://localhost:8080/v1"
        localLLMModel = settingsStore.string(forKey: "localLLMModel") ?? ""
        // MAK-53: summarization model override (default = same as cleanup).
        summaryLLMProvider = settingsStore.string(forKey: "summaryLLMProvider") ?? SummaryModelResolver.sameAsCleanupID
        summaryLLMModel = settingsStore.string(forKey: "summaryLLMModel") ?? ""
        summaryLLMEndpoint = settingsStore.string(forKey: "summaryLLMEndpoint") ?? ""
        bundledLLMModel = settingsStore.string(forKey: "bundledLLMModel") ?? "qwen2.5-0.5b-instruct"
        // Agent-CLI provider (MAK-44) — used only when llmProvider == "agentCLI".
        // Default to the Claude preset so opting in works with zero extra typing.
        agentCLIPreset = settingsStore.string(forKey: "agentCLIPreset") ?? "claude"
        agentCLICustomCommand = settingsStore.string(forKey: "agentCLICustomCommand") ?? ""
        agentCLICustomArgsText = settingsStore.string(forKey: "agentCLICustomArgsText") ?? ""
        agentCLITimeout = settingsStore.object(forKey: "agentCLITimeout") as? Double ?? 30.0
        instructionChainEnabled = settingsStore.object(forKey: "instructionChainEnabled") as? Bool ?? true
        voiceEditingEnabled = settingsStore.object(forKey: "voiceEditingEnabled") as? Bool ?? true
        scriptPostProcessorEnabled = settingsStore.object(forKey: "scriptPostProcessorEnabled") as? Bool ?? false
        scriptPostProcessorPath = settingsStore.string(forKey: "scriptPostProcessorPath") ?? ""
        outputTargetSettings = Self.loadOutputTargetSettings()
        ruleSet = RuleStore.load()
        screenContext = Self.loadScreenContext()
        perAppModesEnabled = settingsStore.object(forKey: "perAppModesEnabled") as? Bool ?? false
        historyEnabled = settingsStore.object(forKey: "historyEnabled") as? Bool ?? true
        // MAK-40 raw-audio retention: opt-in (default OFF); policy defaults keep the
        // newest 50 clips and impose no age cap until the user sets one.
        retainRawAudioEnabled = settingsStore.bool(forKey: "retainRawAudioEnabled")
        audioRetentionDays = settingsStore.integer(forKey: "audioRetentionDays")
        audioRetentionMaxClips = settingsStore.object(forKey: "audioRetentionMaxClips") as? Int ?? 50
        // Agent Bridge (M8) — default off; started at launch via startAgentBridgeIfEnabled().
        // (Property observers don't fire during init, so the lazy server isn't
        // touched here — it starts only from the explicit launch call.)
        agentBridgeEnabled = settingsStore.bool(forKey: "agentBridgeEnabled")
        agentBridgeAllowUnsignedClients = settingsStore.bool(forKey: "agentBridgeAllowUnsignedClients")
        agentBridgeAllowCloudAI = settingsStore.bool(forKey: "agentBridgeAllowCloudAI")
        // Default-ON (silence auto-stop is the expected agent-dictate UX).
        agentBridgeSilenceAutoStop = settingsStore.object(forKey: "agentBridgeSilenceAutoStop") as? Bool ?? true
        agentBridgeEouAutoStop = settingsStore.object(forKey: "agentBridgeEouAutoStop") as? Bool ?? false
        handsFreeSilenceAutoStop = settingsStore.object(forKey: "handsFreeSilenceAutoStop") as? Bool ?? true
        // Default-ON: the chime and spoken question are the whole point of an
        // agent handing you the mic — you should notice and be able to answer
        // without staring at the overlay. Users can turn either off.
        agentBridgeChimeEnabled = settingsStore.object(forKey: "agentBridgeChimeEnabled") as? Bool ?? true
        agentBridgeSpeakQuestionEnabled = settingsStore.object(forKey: "agentBridgeSpeakQuestionEnabled") as? Bool ?? true
        agentClients = AgentClientStore.load()
        profiles = AppProfileStore.load()
        // MAK-39: load user-authored Modes. On the FIRST launch after Modes ship,
        // an install with per-app profiles but no modes.json is seeded with a Mode
        // per profile (bridged 1:1), so existing per-app behavior survives and the
        // profiles show up in the new Modes UI. Profiles remain their own store for
        // AppState's existing apply/restore lifecycle; Modes add the invocation key
        // + tone/instruction layer on top.
        let loadedModes = ModeStore.load()
        modes = loadedModes.isEmpty
            ? AppProfileStore.load().map(Mode.init(fromProfile:))
            : loadedModes
        history = TranscriptionHistoryStore.load()
        customVocabularyEnabled = settingsStore.object(forKey: "customVocabularyEnabled") as? Bool ?? true
        vocabulary = VocabularyStore.load()
        correctionLearningEnabled = settingsStore.object(forKey: "correctionLearningEnabled") as? Bool ?? true
        correctionProposals = CorrectionProposalStore.load()
        didCompleteOnboarding = settingsStore.bool(forKey: "didCompleteOnboarding")
        hintSessionCount = settingsStore.integer(forKey: "hintSessionCount")
        dismissedHintIDs = Set(settingsStore.stringArray(forKey: "dismissedHintIDs") ?? [])

        wireUpServices()
        overlayController = OverlayWindowController(appState: self)
        hotkeyMonitor.start()
        // Launch-time permission recheck: a reinstall silently revokes the TCC
        // Accessibility grant, so verify the LIVE state now instead of trusting
        // the persisted onboarding flag. (Input Monitoring reports asynchronously
        // via onPermissionStateChanged above.)
        refreshPermissionBanners()
        ensureModelExists()
        warmWhisperServerIfPossible()
        // MAK-40: enforce the retention policy on launch (age cap may have elapsed
        // while the app was closed) — a no-op when retention is off.
        applyRetentionPolicy()
        // MAK-51 WP6: bring the LAN sync bridge up iff a device is already paired
        // (zero cost otherwise — no listener, nothing on the LAN).
        lanBridgeServer.refresh(hasPairedPeers: pairingStore.hasPairedPeers)
    }

    private static func modelFileName(for modelName: String) -> String {
        switch modelName {
        case "tiny":          return "ggml-tiny.bin"
        case "tiny.en":       return "ggml-tiny.en.bin"
        case "base":          return "ggml-base.bin"
        case "base.en":       return "ggml-base.en.bin"
        case "small":         return "ggml-small.bin"
        case "small.en":      return "ggml-small.en.bin"
        case "medium":        return "ggml-medium.bin"
        case "medium.en":     return "ggml-medium.en.bin"
        case "large-v3":      return "ggml-large-v3.bin"
        case "large-v3-turbo": return "ggml-large-v3-turbo.bin"
        default:         return "ggml-base.bin"
        }
    }

    static func languageDisplayName(for code: String) -> String {
        switch code {
        case "auto": return "Auto Detect"
        case "en": return "English"
        case "ru": return "Russian"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "ja": return "Japanese"
        case "zh": return "Chinese"
        case "ko": return "Korean"
        case "ar": return "Arabic"
        default: return code.uppercased()
        }
    }

    private func resolvedModelPath() -> String {
        Self.applicationSupportModelsDirectory()
            .appendingPathComponent(Self.modelFileName(for: modelName))
            .path
    }

    private static func preferredWhisperCLIPath(savedPath: String) -> String {
        if !savedPath.isEmpty, FileManager.default.fileExists(atPath: savedPath) {
            return savedPath
        }

        if let bundled = bundledResourcePath("whisper/whisper-cli"),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        return "\(NSHomeDirectory())/whisper.cpp/build/bin/whisper-cli"
    }

    private static func preferredModelPath(savedPath: String, fileName: String) -> String {
        if !savedPath.isEmpty, FileManager.default.fileExists(atPath: savedPath) {
            return savedPath
        }

        let oldWhisperCppPath = "\(NSHomeDirectory())/whisper.cpp/models/\(fileName)"
        if FileManager.default.fileExists(atPath: oldWhisperCppPath) {
            return oldWhisperCppPath
        }

        return applicationSupportModelsDirectory()
            .appendingPathComponent(fileName)
            .path
    }

    private static func bundledResourcePath(_ relativePath: String) -> String? {
        Bundle.main.resourceURL?
            .appendingPathComponent(relativePath)
            .path
    }

    private static func applicationSupportModelsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenWhisp/models", isDirectory: true)
    }

    private func wireUpServices() {
        // The file-transcription engine is chosen by the `transcriptionEngine`
        // setting. "whisperKit" is an experimental CoreML backend (pilot) that
        // conforms to the same FileTranscriptionEngine protocol, so all the
        // callback wiring below is identical regardless of which one is active.
        whisperEngine = injectedFileEngine
            ?? Self.makeFileEngine(for: transcriptionEngine, model: modelName, whisperKitModel: whisperKitModel)
        appleSpeechEngine = AppleSpeechEngine()
        whisperKitStreamEngine = WhisperKitStreamingEngine(modelName: whisperKitModel)
        parakeetStreamEngine = ParakeetStreamingEngine(variantID: parakeetVariant)
        speechAnalyzerStreamEngine = SpeechAnalyzerStreamingEngine()
        translationService = OpenAITranslationService()

        wireFileEngineCallbacks()
        wireStreamingEngineCallbacks(whisperKitStreamEngine)
        wireStreamingEngineCallbacks(parakeetStreamEngine)
        wireStreamingEngineCallbacks(speechAnalyzerStreamEngine)
        wireParakeetEouCallback()

        audioRecorder = injectedAudioCapture ?? AudioRecorder()
        audioRecorder.autoGainEnabled = autoGainEnabled
        audioRecorder.quietModeEnabled = quietDictationEnabled
        audioRecorder.onStateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                // Session fence: drop transitions from a recorder run that isn't
                // the current session's (see recorderSessionID). Without it, a
                // cancelled session's late `.stopped`/`.recording`/`.error` would
                // mutate the session that replaced it.
                guard self.recorderSessionID == self.activeSessionID else { return }
                switch state {
                case .recording:
                    // Capture is now genuinely live: leave the arming window so the
                    // overlay flips from "starting" to the green "speak now" cue.
                    self.isArming = false
                    self.isRecording = true
                    self.statusMessage = self.outputMode == "liveChunks" ? "Listening..." : "Recording..."
                    // The hotkey-up can land AFTER the grant callback's pendingStop
                    // guard but BEFORE this state change is delivered. Nothing else
                    // reads pendingStop once recording starts, so honor it here —
                    // otherwise the mic keeps recording unattended after a quick tap.
                    if self.pendingStop, self.sessionActive {
                        self.pendingStop = false
                        self.stopDictation()
                    }
                case .stopped, .idle:
                    self.isArming = false
                    self.isRecording = false
                case .error(let msg):
                    self.isArming = false
                    self.error = msg
                    self.statusMessage = "Error"
                    self.isRecording = false
                    self.sessionOutcome = .error(message: msg)
                    self.finishSessionUI()
                }
            }
        }
        audioRecorder.onLevelChanged = { [weak self] level in
            Task { @MainActor in
                // Recorder levels are already on the absolute fromDB/fromRMS curve.
                self?.updateAudioLevel(level, vadLevel: level)
            }
        }

        wireStreamingEngineCallbacks(appleSpeechEngine)

        hotkeyMonitor = HotkeyMonitor()
        hotkeyMonitor.triggerMode = triggerMode
        hotkeyMonitor.customTrigger = customTrigger
        hotkeyMonitor.hotkeyMode = hotkeyMode
        hotkeyMonitor.refineKey = refineKey
        hotkeyMonitor.mouseTrigger = mouseTrigger
        hotkeyMonitor.onPermissionStateChanged = { [weak self] isGranted in
            Task { @MainActor in
                self?.inputMonitoringPermissionLabel = isGranted ? "Granted" : "Needs permission"
                self?.inputMonitoringGranted = isGranted
                self?.refreshPermissionBanners()
                if !isGranted {
                    self?.error = "Input Monitoring is not available for this app build. Remove and re-add OpenWhisp in System Settings, then quit and reopen the app."
                }
            }
        }
        hotkeyMonitor.onHotkeyDown = { [weak self] locked in
            Task { @MainActor in
                self?.startDictation(locked: locked)
            }
        }
        hotkeyMonitor.onHotkeyUp = { [weak self] in
            Task { @MainActor in
                self?.stopDictation()
            }
        }
        // Refine key is now a mid-dictation MODE SWITCH (a tap), not a separate
        // hold: press it while still holding Fn to mark "everything after this is
        // the instruction". Applied when you release Fn.
        hotkeyMonitor.onRefineDown = { [weak self] in
            Task { @MainActor in
                self?.armRefineMidSession()
            }
        }
        hotkeyMonitor.onRefineUp = { /* mode switch is on tap-down; up is a no-op */ }
        hotkeyMonitor.onCancel = { [weak self] in
            Task { @MainActor in
                self?.cancelDictation()
            }
        }
    }

    /// Attach AppState's callbacks to the current `whisperEngine`. Shared by
    /// initial wiring and by `rebuildFileEngine()` so a backend switch re-wires
    /// identically (the callbacks only depend on the FileTranscriptionEngine
    /// protocol, not on which concrete engine is active).
    private func wireFileEngineCallbacks() {
        whisperEngine.onTranscriptionComplete = { [weak self] requestID, text in
            Task { @MainActor in
                self?.handleTranscription(text, requestID: requestID)
            }
        }
        whisperEngine.onTranscriptionError = { [weak self] requestID, msg in
            Task { @MainActor in
                guard let self else { return }
                guard let request = self.consumeRequest(requestID), request.sessionID == self.activeSessionID else { return }
                if request.kind == .liveChunk {
                    if let sequence = request.sequence {
                        self.livePipeline.complete(sequence, text: "")
                    }
                    self.processNextLiveChunk()
                    self.flushOrderedLiveResults()
                    if self.isTranscribing && self.livePipelineIsDrained {
                        self.completeFinalText(self.currentSessionText)
                    }
                    self.statusMessage = self.isTranscribing ? "Finalizing..." : "Listening..."
                    return
                }
                self.error = msg
                self.statusMessage = "Error"
                self.isTranscribing = false
                self.sessionOutcome = .error(message: msg)
                self.finishSessionUI()
            }
        }
        whisperEngine.onProgress = { [weak self] pct in
            Task { @MainActor in
                self?.statusMessage = "Transcribing... \(pct)%"
            }
        }
        whisperEngine.onWorkerStatus = { [weak self] status in
            Task { @MainActor in
                self?.whisperWorkerStatus = status
            }
        }
    }

    /// Wire a streaming engine (Apple Speech or WhisperKit) to the shared session
    /// handlers. Both backends drive the same live-preview/delta-paste path, so the
    /// callbacks are identical — only the underlying recognizer differs.
    ///
    /// The partial/final closures are (re)bound per streaming session in
    /// `bindStreamingSessionCallbacks(_:sessionID:)` so they capture the session
    /// generation and can drop late callbacks from a previous engine session (e.g.
    /// Apple Speech's 0.8s synthesized-final fallback firing after a quick
    /// cancel+restart). The error/level closures below aren't session-critical, so
    /// they're wired once here.
    private func wireStreamingEngineCallbacks(_ engine: StreamingTranscriptionEngine) {
        bindStreamingSessionCallbacks(engine, sessionID: activeSessionID)
        let sessionID = activeSessionID
        engine.onError = { [weak self] message in
            Task { @MainActor in
                guard let self, self.isAppleSpeechSession else { return }
                // Session fence, same as partial/final/started: a late error from
                // a torn-down session must not abort the successor session
                // (isAppleSpeechSession alone can't catch that — the successor
                // sets it true too).
                guard !StreamingRoutePolicy.isStaleStreamingCallback(
                    callbackSessionID: sessionID, activeSessionID: self.activeSessionID) else { return }
                self.error = message
                self.statusMessage = "Streaming Error"
                self.isRecording = false
                self.isTranscribing = false
                self.isAppleSpeechSession = false
                self.sessionOutcome = .error(message: message)
                self.finishSessionUI()
            }
        }
        engine.onLevelChanged = { [weak self] display, vad in
            Task { @MainActor in self?.updateAudioLevel(display, vadLevel: vad) }
        }
    }

    /// (Re)bind the partial/final closures of a streaming engine to a specific
    /// session generation. The closures capture `sessionID` and pass it to the
    /// handlers, which drop the callback if the session has since moved on. This
    /// closes the late-final hole: on a quick cancel+restart, a leftover
    /// synthesized final from the PREVIOUS engine session would otherwise be
    /// treated as the CURRENT session's final (pasting the old transcript and
    /// completing the new session early), because `isAppleSpeechSession` is a plain
    /// boolean that the successor session also sets true. Called per streaming
    /// session start (`startStreamingSession`) with the fresh `activeSessionID`.
    private func bindStreamingSessionCallbacks(_ engine: StreamingTranscriptionEngine, sessionID: UUID) {
        engine.onPartial = { [weak self] text in
            Task { @MainActor in self?.handleAppleSpeechPartial(text, sessionID: sessionID) }
        }
        engine.onFinal = { [weak self] text in
            Task { @MainActor in self?.handleAppleSpeechFinal(text, sessionID: sessionID) }
        }
        engine.onStarted = { [weak self] in
            Task { @MainActor in self?.handleStreamingCaptureStarted(sessionID: sessionID) }
        }
    }

    /// The streaming engine reported capture genuinely live (mic tap installed,
    /// audio being consumed) — or the arming-timeout fallback fired. Streaming
    /// counterpart of the recorder's `.recording` transition: only NOW does the
    /// session leave arming ("Starting…") and claim "Listening...". Flipping at
    /// `engine.start()` return was the bug — WhisperKit/Parakeet only enqueue
    /// their start there, so the UI said "Listening" through the whole model
    /// load (or first-run download) while speech was silently dropped.
    /// The decision is the tested `StreamingRoutePolicy.captureStartedAction`;
    /// the isArming gate also makes the late duplicate (onStarted after the
    /// timeout fallback, or vice versa) a no-op.
    @MainActor
    private func handleStreamingCaptureStarted(sessionID: UUID) {
        switch StreamingRoutePolicy.captureStartedAction(
            callbackSessionID: sessionID,
            activeSessionID: activeSessionID,
            isArming: isArming,
            pendingStop: pendingStop
        ) {
        case .drop:
            return
        case .beginListening:
            isArming = false
            isRecording = true
            statusMessage = "Listening..."
        case .beginListeningThenStop:
            // The hotkey-up landed while the engine was still arming (after the
            // grant callback's pendingStop guard, so nothing else consumes it).
            // Go live, then run the stop — otherwise the mic keeps capturing
            // unattended. Same handling as the recorder's `.recording` case.
            isArming = false
            isRecording = true
            statusMessage = "Listening..."
            pendingStop = false
            stopDictation()
        }
    }

    /// Wire the Parakeet streaming engine's EOU signal to the agent EOU auto-stop
    /// (MAK-46 Phase 5). Only the EOU variant ever fires this; the detector is only
    /// armed for an agent session with the setting on (see `armAgentEouDetector`),
    /// so this is inert otherwise.
    private func wireParakeetEouCallback() {
        parakeetStreamEngine.onEouDetected = { [weak self] in
            Task { @MainActor in self?.handleAgentEouEvent() }
        }
    }

    /// An end-of-utterance event fired: arm the settle window. The actual stop
    /// decision runs on the continuous audio-level tick (`updateAudioLevel`),
    /// which re-checks `shouldStop` once the window has elapsed with no newer
    /// partial — a fresh EOU can never satisfy the window at arming time.
    @MainActor
    private func handleAgentEouEvent() {
        guard agentEouDetector != nil,
              agentBridgeEouAutoStop,
              sessionActive, isRecording,
              sessionInitiator.isAgent else { return }
        agentEouDetector?.noteEou(now: ProcessInfo.processInfo.systemUptime)
    }

    /// Publish a new audio level for the overlay AND drive the agent-session
    /// silence detector. The single place every level source (AVAudioRecorder
    /// metering + the streaming engine taps) funnels through, so the VAD sees
    /// every sample regardless of which capture path is live. `vadLevel` is the
    /// sample on the ABSOLUTE AudioLevel curve — WhisperKit's display level is
    /// silence-referenced and would make the fixed gates meaningless.
    @MainActor
    private func updateAudioLevel(_ level: Float, vadLevel: Float) {
        audioLevel = level
        feedLockSafetyAutoStop(vadLevel: vadLevel)
        // EOU settle check (MAK-46 Phase 5): the level tick is a free continuous
        // clock. If an EOU is pending and its settle window has elapsed with no new
        // partial, finish the agent session. Cheap: detector is nil except for an
        // armed agent EOU session.
        if agentEouDetector != nil, sessionActive, isRecording, sessionInitiator.isAgent,
           agentEouDetector?.shouldStop(now: ProcessInfo.processInfo.systemUptime) == true {
            agentEouDetector = nil
            finishAgentDictationOnSilence()
            return
        }
        // Only agent sessions auto-stop on silence; a user's hotkey dictation ends
        // on their own gesture and must be untouched. The detector-nil test comes
        // first so the dominant case (user sessions, where it is always nil) pays
        // one check per tick. Also require the session to be genuinely capturing
        // (not still arming) so leading silence during engine spin-up can't feed
        // the detector.
        guard agentSilenceDetector != nil,
              agentBridgeSilenceAutoStop,
              sessionActive, isRecording,
              sessionInitiator.isAgent else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if agentSilenceDetector?.ingest(level: vadLevel, now: now) == true {
            // The speaker fell silent after speaking — finish exactly as a user
            // "done" tap would (endedBy: .user), returning whatever was captured.
            agentSilenceDetector = nil
            finishAgentDictationOnSilence()
        }
    }

    /// Finish the active agent session because silence was detected. Distinct from
    /// `bridgeStopAgentDictation()` (which marks `endedBy: .stop` for an explicit
    /// client stop): a silence finish is the user's natural "done", so it leaves
    /// both the timeout and stop flags clear and resolves as `endedBy: .user`.
    @MainActor
    private func finishAgentDictationOnSilence() {
        guard sessionActive, sessionInitiator.isAgent else { return }
        // The finish is decided NOW; kill the timeout before finalization begins.
        // Transcribing a long utterance can outlast the deadline, and a timeout
        // firing in that window would flip the delivered endedBy to .timeout (or
        // turn an empty capture into a timeout error).
        agentDictateTimeoutTask?.cancel()
        agentDictateTimeoutTask = nil
        stopDictation()
    }

    /// Silence safety config for a LOCKED user session. Same detector as the
    /// agent bridge but with a MUCH longer hangover: a hands-free user is likely
    /// composing and may pause to think, so this is a "you clearly walked away"
    /// backstop (~8s of continuous silence after speech), never a quick finish.
    private static let lockSafetyConfig = SilenceAutoStop.Config(silenceToStop: 8.0)

    /// Lock-safety config for quiet mode: the lowered whisper-friendly speech/silence
    /// gates (so a whisper still arms the detector) but keeping the long 8s safety
    /// stop, so a whispered session is still protected from running forever.
    private static let quietLockSafetyConfig: SilenceAutoStop.Config = {
        let q = QuietDictationMode.quietSilenceAutoStopConfig
        return SilenceAutoStop.Config(
            speechLevel: q.speechLevel,
            silenceLevel: q.silenceLevel,
            silenceToStop: 8.0,
            minSpeechToArm: q.minSpeechToArm
        )
    }()

    /// Feed the locked-user-session silence safety auto-stop (MAK-16). Arms the
    /// detector lazily on the first live sample of a locked user session, then
    /// finishes the session if the speaker goes silent for the long hangover.
    /// No-op for hold sessions, agent sessions, or when the setting is off — the
    /// dominant hold/agent case pays only the fast guard below.
    @MainActor
    private func feedLockSafetyAutoStop(vadLevel: Float) {
        guard dictationLocked, handsFreeSilenceAutoStop,
              sessionActive, isRecording,
              !sessionInitiator.isAgent else {
            // Not an armed context — drop any stale detector so a later hold
            // session can't inherit it.
            lockSafetyDetector = nil
            return
        }
        if lockSafetyDetector == nil {
            lockSafetyDetector = SilenceAutoStop(
                config: quietDictationEnabled ? Self.quietLockSafetyConfig : Self.lockSafetyConfig
            )
        }
        let now = ProcessInfo.processInfo.systemUptime
        if lockSafetyDetector?.ingest(level: vadLevel, now: now) == true {
            // Long silence after speech in a forgotten locked session — deliver
            // whatever was captured, exactly as a stop tap would.
            lockSafetyDetector = nil
            statusMessage = "Stopped — silence"
            stopDictation()
        }
    }

    /// Swap the file-transcription backend live (when the user changes the Engine
    /// setting). Tears down the old one, builds the new one, re-wires callbacks,
    /// and re-warms if appropriate. Safe to call only after initial wiring.
    private func rebuildFileEngine() {
        whisperEngine?.stopServer()
        whisperEngine = Self.makeFileEngine(for: transcriptionEngine, model: modelName, whisperKitModel: whisperKitModel)
        wireFileEngineCallbacks()
        // Rebuild the WhisperKit streaming engine too, so an engine or WhisperKit
        // model change is reflected on the streaming path (it caches its own model).
        whisperKitStreamEngine?.stop(cancel: true)
        whisperKitStreamEngine = WhisperKitStreamingEngine(modelName: whisperKitModel)
        wireStreamingEngineCallbacks(whisperKitStreamEngine)
        // Same for the Parakeet streaming engine (it caches its variant's model).
        // Cancel any in-flight variant download before discarding the old instance —
        // stop(cancel:) only tears down the mic/session, so switching variant
        // mid-download would otherwise orphan a ~600 MB fetch for the old variant.
        parakeetStreamEngine?.cancelLoading()
        parakeetStreamEngine?.stop(cancel: true)
        parakeetStreamEngine = ParakeetStreamingEngine(variantID: parakeetVariant)
        wireStreamingEngineCallbacks(parakeetStreamEngine)
        wireParakeetEouCallback()
        // SpeechAnalyzer streaming engine holds no cached model of its own, but
        // rebuild it too so a torn-down session never leaks into the next.
        speechAnalyzerStreamEngine?.stop(cancel: true)
        speechAnalyzerStreamEngine = SpeechAnalyzerStreamingEngine()
        wireStreamingEngineCallbacks(speechAnalyzerStreamEngine)
        whisperWorkerStatus = "Not started"
        // `warmWhisperServerIfPossible()` is engine-aware: it warms WhisperKit's
        // CoreML model up front, warms whisper.cpp's server only for the serverAPI
        // backend, and no-ops for Apple Speech — so only the selected backend ever
        // loads a model (no dual-engine residency).
        warmWhisperServerIfPossible()
    }

    // MARK: - Actions

    /// Open (and focus) the floating Scratchpad panel (MAK-49). Idempotent: brings
    /// an already-open pad to the front. Once it's the key window, a completed
    /// dictation lands in its active note.
    func openScratchpad() {
        scratchpadController.showAndFocus()
    }

    /// - Parameter locked: this dictation is hands-free (toggle/double-tap) — it
    ///   stays open with the trigger released, shows the lock affordance, and arms
    ///   the silence safety auto-stop. Default `false` (ordinary press-to-talk).
    func startDictation(locked: Bool = false) {
        // Mic exclusivity (MAK-50): a meeting owns the mic — refuse to start a
        // dictation while one is recording (the reverse guard lives in the menu's
        // Start Meeting item / startMeeting).
        if meetingInProgress {
            statusMessage = "Stop the meeting before dictating"
            return
        }
        // The dictation key is now ONLY dictation — refine has its own dedicated
        // chord (see startRefine). So a plain press always starts a normal
        // dictation and pastes instantly (no re-press disambiguation, no deferral).
        // Abort any in-progress refine defensively (e.g. user starts a new
        // dictation while a refine is mid-flight).
        if refineFlow.isActive {
            executeRefineEffects(refineFlow.handle(.abort))
        }

        // The human always wins the mic: if the user presses the hotkey while an
        // AGENT session is capturing, cancel that session (it gets no transcript,
        // per the cancel invariant) and start the user's own dictation. Only fires
        // for a genuine user press — beginAgentDictation() sets the initiator but
        // has no active session yet, so it never trips this.
        if sessionActive, sessionInitiator.isAgent {
            // ORDERING INVARIANT: set the preempt flag BEFORE cancelling. The cancel
            // runs finishSessionUI, whose `if !pendingPreemptStart { resetActivation() }`
            // guard must SEE the flag set — otherwise it wipes the activation machine
            // and the hotkey release after preempting never stops the mic. So the flag
            // is set here, and cancelDictation is told to preserve it (its default is
            // to clear the flag, for the Esc-in-gap back-out case).
            pendingPreemptStart = true
            cancelDictation(preservePreemptStart: true)
            // Start the user's dictation on the NEXT main-actor turn, not this
            // one: the cancel above already enqueued the dead session's deferred
            // recorder/engine hops (.stopped clears isArming/isRecording with no
            // session fence, and a streaming engine can have a partial in
            // flight). One deferred turn lets those drain against dead state
            // instead of clobbering the successor session mid-arming.
            Task { @MainActor in
                guard self.pendingPreemptStart else { return } // stop/cancel in the gap consumed it
                self.pendingPreemptStart = false
                self.startDictation(locked: locked)
            }
            return
        }

        guard !isRecording, !isTranscribing else {
            // The press was refused — no session starts. Return the interaction
            // machine to idle so a locked "start" that never happened can't leave
            // it lockedOpen (the next tap would then read as a stop for a session
            // that doesn't exist).
            hotkeyMonitor?.resetActivation()
            return
        }
        // Privacy guard: never dictate into a focused password/secure field. The
        // speech would otherwise be transcribed, typed in, copied to the clipboard
        // and saved to history. Refuse at the source before any session begins.
        // Detection is fail-open (see SecureFieldDetector): we only refuse on a
        // positive secure-field match, so dictation is never broken when AX can't
        // determine the role.
        guard !SecureFieldDetector.focusedFieldIsSecure() else {
            refuseDictationIntoSecureField()
            return
        }
        // Remember the activation style for the whole session so the overlay shows
        // the lock affordance and the silence safety auto-stop arms once capture
        // is live. Set only AFTER every refusal guard above — a refused press must
        // not overwrite the flag (or leave a phantom lock behind).
        dictationLocked = locked
        // Apply a per-app profile (if any) BEFORE routing, so an override of
        // outputMode/language/AI-cleanup affects the whole session including the
        // streaming-vs-recording decision below. Restored when the session ends.
        applyProfileForFrontmostApp()
        // MAK-34: capture screen context (bias terms + bounded surrounding text)
        // once, now, while the user's original field is still focused — after the
        // secure-field refusal guard above and profile resolution, before any
        // routing. The gate re-checks the secure-field and per-app rules.
        captureScreenContext()
        let liveMode = outputMode == "liveChunks" || outputMode == "preview"
        // Streaming backends (Apple Speech and Parakeet always; WhisperKit when a
        // live preview is wanted) run the real-time path. All go through the shared
        // streaming session starter; `activeStreamingEngine` picks the recognizer.
        // The gate is a tested core policy — see StreamingRoutePolicyTests.
        if StreamingRoutePolicy.usesStreamingSession(engine: transcriptionEngine, liveMode: liveMode) {
            startStreamingSession()
            return
        }
        if liveMode {
            startStreaming()
        } else {
            startRecording()
        }
    }

    func stopDictation() {
        // A hotkey-up landing in the preempt gap (agent session cancelled, the
        // user's replacement start still queued) means the press is over —
        // consume the queued start instead of letting it arm an unattended mic.
        if pendingPreemptStart {
            pendingPreemptStart = false
            return
        }
        // The hotkey-up may arrive before the async permission-grant callback has flipped
        // isRecording true. In that case record the intent and let the grant callback abort.
        guard isRecording else {
            if sessionActive { pendingStop = true }
            return
        }
        if isAppleSpeechSession {
            stopAppleSpeech()
            return
        }
        if isStreamingSession {
            stopStreaming()
        } else {
            stopRecording()
        }
    }

    /// - Parameter preservePreemptStart: when true, do NOT clear
    ///   `pendingPreemptStart`. The agent-preempt path in `startDictation` sets the
    ///   flag and then cancels the agent session; the flag must survive this cancel
    ///   so `finishSessionUI` leaves the activation machine intact for the user's
    ///   queued replacement session. Every OTHER caller (Esc, shutdown) wants the
    ///   default: a cancel in the preempt gap is a back-out and clears the flag.
    func cancelDictation(preservePreemptStart: Bool = false) {
        // An Esc (or shutdown) in the preempt gap also cancels the queued
        // replacement start — the user is backing out entirely.
        if !preservePreemptStart {
            pendingPreemptStart = false
        }
        // Esc while a refine is engaged (waiting for step-1 or the instruction):
        // abort the flow without inserting anything.
        if refineFlow.isActive && !isRecording && !isTranscribing && !sessionActive {
            refineFlow.reset()
            syncRefineUI()
            statusMessage = "Cancelled"
            finishSessionUI()
            return
        }
        // Esc while the agent's question is still being read (mic not yet live):
        // stop the speech and tear down before capture ever starts. The MCP thread
        // is blocked on onSessionEnd, so deliver a cancel through the normal path.
        if agentDictateReadingQuestion && !isRecording && !isTranscribing && !sessionActive {
            agentAnnouncer.stopSpeaking()
            sessionOutcome = .cancelled
            finishSessionUI()
            statusMessage = "Cancelled"
            return
        }
        guard isRecording || isTranscribing || sessionActive else { return }
        activeSessionID = UUID()
        sessionActive = false
        pendingStop = false
        refineContentSnapshot = nil
        refineFlow.reset()
        syncRefineUI()
        transcriptionRequests.removeAll()
        cleanupPendingLiveChunks()
        resetLivePipeline()
        acceptingLiveChunks = false
        isAppleSpeechSession = false
        activeStreamingEngine.stop(cancel: true)
        isStreamingSession = false
        isLiveChunkSession = false
        isPreviewSession = false
        isTranscribing = false
        audioRecorder.stop { url in
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // Clear synchronously: the recorder/engines above are already stopped, but
        // their state callbacks clear this flag a Task-hop later — too late for a
        // caller that starts a new session right after this cancel (the hotkey
        // preempt of an agent session would find isRecording still true and bail,
        // silently eating the user's press).
        isRecording = false
        currentSessionText = ""
        streamingText = ""
        // MAK-34: drop any captured screen context so a cancelled session can never
        // leak surrounding text into a later refine.
        sessionScreenContext = nil
        statusMessage = "Cancelled"
        finishSessionUI()
    }

    /// Refuse to start a dictation session because a secure/password field is
    /// focused. Surfaces a clear status without starting recording or touching
    /// the clipboard/history, and ensures no half-started session lingers.
    private func refuseDictationIntoSecureField() {
        error = nil
        statusMessage = "Won't dictate into a password field"
        // Belt-and-suspenders: make sure no session state is left active.
        sessionActive = false
        pendingStop = false
        isRecording = false
        isTranscribing = false
    }

    func shutdown() {
        cancelDictation()
        // Persist any pending debounced vocabulary usage-count bump before we exit,
        // so a rapid dictate-then-quit doesn't lose the last increment (MAK-41).
        flushVocabularySave()
        agentBridgeServer.stop()
        lanBridgeServer.stop()
        whisperEngine.stopServer()
        llamaEngine?.stopServer()
        hotkeyMonitor.stop()
    }

    /// Start the Agent Bridge socket server if the user has enabled it. Called
    /// once at launch (property observers don't fire during init).
    func startAgentBridgeIfEnabled() {
        guard agentBridgeEnabled else { return }
        agentBridgeServer.allowUnsignedClients = agentBridgeAllowUnsignedClients
        agentBridgeServer.start()
    }

    func stopWhisperServer() {
        whisperEngine.stopServer()
    }

    // MARK: - Built-in (bundled) LLM

    /// Application Support path of the selected built-in LLM GGUF.
    func selectedLLMModelPath() -> String {
        let fileName = Self.bundledLLMManifest()?
            .first(where: { $0.id == bundledLLMModel })?.file
            ?? "\(bundledLLMModel).gguf"
        return Self.applicationSupportModelsDirectory()
            .appendingPathComponent(fileName)
            .path
    }

    /// True when the selected built-in model is downloaded.
    var bundledLLMModelInstalled: Bool {
        FileManager.default.fileExists(atPath: selectedLLMModelPath())
    }

    /// Application Support path of an arbitrary built-in model id (for the LLM Lab,
    /// which can target a model other than the active `bundledLLMModel`).
    func bundledModelPath(_ id: String) -> String {
        let fileName = Self.bundledLLMManifest()?
            .first(where: { $0.id == id })?.file
            ?? "\(id).gguf"
        return Self.applicationSupportModelsDirectory()
            .appendingPathComponent(fileName)
            .path
    }

    func isBundledModelInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: bundledModelPath(id))
    }

    /// True when the built-in LLM would coexist with a resident whisper.cpp
    /// server — surfaced in Settings so the user can pick a lighter pairing on a
    /// small-RAM Mac. (Public mirror of the private dual-engine check.)
    var bundledLLMHasMemoryCaution: Bool {
        llmProvider == "bundled" && whisperServerResident
    }

    /// Dev diagnostic: the live status of the built-in LLM server — which model is
    /// SELECTED vs. which is actually LOADED in the running llama-server (they can
    /// differ briefly during a switch, or the server may be torn down when idle).
    /// Only meaningful for the bundled provider.
    var bundledLLMRuntimeStatus: String {
        let selected = bundledLLMModel
        guard let path = llamaEngine?.runningModelPath else {
            return "selected: \(selected) · server: stopped (starts on next refine)"
        }
        let loaded = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let match = path == selectedLLMModelPath()
        return "selected: \(selected) · loaded: \(loaded)\(match ? "" : "  ⚠︎ MISMATCH") · port \(llamaEngine?.port ?? 0)"
    }

    #if OPENWHISP_INSTRUMENTATION
    /// Snapshot of debugging info for the overlay HUD (dev builds only). Sampled
    /// each time the HUD's poll timer fires.
    struct DebugHUDSnapshot {
        var engineLine: String       // transcription engine · backend · output mode
        var stateLine: String        // recording/transcribing/arming flags
        var llmLine: String          // built-in model selected/loaded
        var appMemCPU: String        // OpenWhisp process RSS + CPU
        var llamaMemCPU: String      // llama-server process RSS + CPU (or stopped)
        var timingLine: String       // last session duration + transcription latency
    }

    func debugHUDSnapshot() -> DebugHUDSnapshot {
        let appRSS = DebugStats.selfResidentMB()
        let appCPU = DebugStats.selfCPUPercent()
        let appMemCPU = "app: \(appRSS) MB · \(String(format: "%.0f", appCPU))% cpu"

        let llamaMemCPU: String
        if let pid = llamaEngine?.runningPID, let s = DebugStats.sample(pid: pid) {
            llamaMemCPU = "llama: \(s.rssMB) MB · \(String(format: "%.0f", s.cpuPercent))% cpu (pid \(pid))"
        } else {
            llamaMemCPU = "llama: not loaded"
        }

        let backend = transcriptionEngine == "whisper" ? "whisper.cpp/\(whisperBackend)" : transcriptionEngine
        let engineLine = "\(backend) · out: \(outputMode) · provider: \(llmProvider)"

        var flags: [String] = []
        if isRecording { flags.append("REC") }
        if isTranscribing { flags.append("TRANSCRIBING") }
        if isArming { flags.append("ARMING") }
        if refineFlow.isActive {
            let label: String
            switch refineFlow.state {
            case .inactive: label = "inactive"
            case .capturing(let s, _): label = s == nil ? "capturing(await-step1)" : "capturing(instr)"
            case .applying: label = "applying"
            }
            flags.append("REFINE:\(label)")
        }
        let stateLine = "state: " + (flags.isEmpty ? "idle" : flags.joined(separator: " "))

        let llmLine = llmProvider == "bundled" ? bundledLLMRuntimeStatus : "provider: \(llmProvider) (not built-in)"

        let timingLine: String
        if let e = lastDictationEvent {
            let lat = e.transcriptionLatencySeconds.map { String(format: "%.2fs", $0) } ?? "—"
            timingLine = String(format: "last: %.2fs total · %@ asr · %d words", e.durationSeconds, lat, e.wordCount)
        } else {
            timingLine = "last: (no session yet)"
        }

        return DebugHUDSnapshot(
            engineLine: engineLine,
            stateLine: stateLine,
            llmLine: llmLine,
            appMemCPU: appMemCPU,
            llamaMemCPU: llamaMemCPU,
            timingLine: timingLine
        )
    }
    #endif

    /// Whether a download is currently in flight for the given model id.
    func isLLMModelDownloadingForLab(_ id: String) -> Bool {
        inFlightLLMModelDownloads.contains(bundledModelPath(id))
    }

    /// The list of swappable built-in models for the Settings picker.
    func bundledLLMModelsList() -> [(id: String, label: String, size: String, license: String)] {
        (Self.bundledLLMManifest() ?? []).map {
            (id: $0.id, label: $0.label, size: $0.size, license: $0.license ?? "")
        }
    }

    private static func bundledLLMManifest() -> [ModelManifestEntry]? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("models/llm-manifest.json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode([ModelManifestEntry].self, from: data)
    }

    /// True when a resident whisper.cpp server is held in memory at the same time
    /// the built-in LLM would run. Both load a model, so on small-RAM Macs they
    /// can race for memory. (WhisperKit/AppleSpeech keep no resident server.)
    private var whisperServerResident: Bool {
        transcriptionEngine == "whisper" && whisperBackend == "serverAPI"
    }

    /// Start the bundled llama-server if the built-in provider is the active,
    /// enabled, downloaded one. Idempotent (the engine no-ops if already healthy).
    func warmLlamaServerIfPossible() {
        guard llmProvider == "bundled",
              openAIEnhancementEnabled,
              bundledLLMModelInstalled else { return }
        let engine = ensureLlamaEngine()
        // Shorter idle teardown when a whisper-server is also resident, to relieve
        // dual-engine memory pressure sooner.
        engine.idleTimeout = whisperServerResident ? 30 : 90
        engine.ensureRunning(modelPath: selectedLLMModelPath()) { _ in }
    }

    /// Gate a refinement call behind the bundled server being healthy. For the
    /// bundled provider it lazily starts llama-server, then runs `work` on
    /// success, or `fallback` (insert the raw local text — never drop it) on
    /// failure. For every other provider it runs `work` immediately. `work` must
    /// itself call `processFinalText`; we bracket the request with the engine's
    /// in-flight counter so idle teardown can't kill a live generation.
    /// Diagnostic logger for the refine/instruction-chain flow. Writes to
    /// ~/Library/Caches/com.openwhisp.app/refine-debug.log. Dev-only: a NO-OP in
    /// consumer builds (this flow has been a recurring source of subtle bugs, so
    /// the trace is worth keeping in instrumented builds).
    func refineDebug(_ message: String) {
        #if OPENWHISP_INSTRUMENTATION
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.openwhisp.app/refine-debug.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try? h.seekToEnd(); h.write(Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }

    /// `work` receives a `done` callback that MUST be invoked exactly once when the
    /// LLM request actually completes (before any early-return guards) — it closes
    /// the engine's in-flight bracket so idle teardown can't kill a live generation.
    /// For non-bundled providers `done` is a no-op.
    ///
    /// `boundToSession` (the default) drops the callback when the dictation
    /// session rotates mid-load — right for session-scoped refines, whose output
    /// would land in a dead session. Callers that must ALWAYS hear back (the
    /// Agent Bridge blocks a thread on the completion) pass false.
    private func ensureBundledLLMReady(
        statusWhileLoading: String = "Loading local model…",
        quiesceWhisper: Bool = false,
        boundToSession: Bool = true,
        provider: String? = nil,
        work: @escaping (_ done: @escaping () -> Void) -> Void,
        fallback: @escaping () -> Void
    ) {
        // The provider whose readiness we're bracketing. Defaults to the global
        // cleanup provider; the summarize path (MAK-53) passes the RESOLVED
        // summary provider so a bundled summary warms the engine even when
        // cleanup uses a different provider.
        let provider = provider ?? llmProvider
        refineDebug("ensureBundledLLMReady ENTER provider=\(provider) sessionID=\(activeSessionID.uuidString.prefix(8))")
        guard provider == "bundled" else {
            refineDebug("ensureBundledLLMReady: non-bundled -> work() immediately")
            work({})
            return
        }

        guard bundledLLMRuntimeAvailable else {
            // Not a user-fixable state: this copy of the app was packaged
            // without the llama runtime. Name the real problem.
            translationStatus = "This build doesn't include the built-in AI runtime"
            fallback()
            return
        }

        guard bundledLLMModelInstalled else {
            translationStatus = "Built-in model not downloaded"
            fallback()
            return
        }

        // Dual-engine memory relief: when a whisper-server is resident and the
        // caller is post-transcription (whole-text refinement), stop it before
        // loading the LLM so they don't both hold a model at once. It re-warms on
        // the next dictation via warmWhisperServerIfPossible().
        if quiesceWhisper, whisperServerResident {
            stopWhisperServer()
        }

        let engine = ensureLlamaEngine()
        engine.idleTimeout = whisperServerResident ? 30 : 90
        let sessionID = activeSessionID
        statusMessage = statusWhileLoading
        engine.requestStarted()
        engine.ensureRunning(modelPath: selectedLLMModelPath()) { [weak self] result in
            Task { @MainActor in
                guard let self else { engine.requestFinished(); return }
                guard !boundToSession || sessionID == self.activeSessionID else {
                    engine.requestFinished()
                    return
                }
                switch result {
                case .success:
                    // Keep the request open through the async LLM call: `done`
                    // decrements the in-flight count (single-fire) when the
                    // completion path invokes it, so the idle timer can't tear the
                    // server down mid-generation.
                    var finished = false
                    work({
                        guard !finished else { return }
                        finished = true
                        engine.requestFinished()
                    })
                case .failure:
                    engine.requestFinished()
                    self.translationStatus = "Local model unavailable"
                    fallback()
                }
            }
        }
    }

    func ensureLLMModelExists() {
        let path = selectedLLMModelPath()
        guard !FileManager.default.fileExists(atPath: path) else {
            llmModelDownloadStatus = "Installed: \(URL(fileURLWithPath: path).lastPathComponent)"
            isLLMModelDownloading = false
            llmModelDownloadFailed = false
            llmModelDownloadProgress = nil
            warmLlamaServerIfPossible()
            return
        }

        guard !inFlightLLMModelDownloads.contains(path) else { return }
        guard let entry = Self.bundledLLMManifest()?.first(where: { $0.id == bundledLLMModel }),
              let url = URL(string: entry.url) else {
            llmModelDownloadFailed = true
            llmModelDownloadStatus = "No download URL for \(bundledLLMModel)"
            return
        }

        let fileName = entry.file
        inFlightLLMModelDownloads.insert(path)
        isLLMModelDownloading = true
        llmModelDownloadFailed = false
        llmModelDownloadProgress = nil
        llmModelDownloadStatus = "Downloading \(fileName)..."

        Task {
            do {
                let dest = URL(fileURLWithPath: path)
                try dest.deletingLastPathComponent().createDirectories()
                try await downloadLLMModelWithProgress(from: url, to: dest, fileName: fileName)
                await MainActor.run {
                    self.inFlightLLMModelDownloads.remove(path)
                    // A superseded download (the user switched models mid-flight)
                    // must not clobber the selected model's download UI state.
                    guard path == self.selectedLLMModelPath() else { return }
                    self.isLLMModelDownloading = false
                    self.llmModelDownloadProgress = 1.0
                    self.llmModelDownloadFailed = false
                    self.llmModelDownloadStatus = "Installed: \(fileName)"
                    self.warmLlamaServerIfPossible()
                }
            } catch {
                await MainActor.run {
                    self.inFlightLLMModelDownloads.remove(path)
                    guard path == self.selectedLLMModelPath() else { return }
                    self.isLLMModelDownloading = false
                    self.llmModelDownloadProgress = nil
                    self.llmModelDownloadFailed = true
                    self.llmModelDownloadStatus = "Download failed: \(fileName)"
                    self.error = "Built-in model download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func retryLLMModelDownload() {
        guard !isLLMModelDownloading else { return }
        llmModelDownloadFailed = false
        error = nil
        ensureLLMModelExists()
    }

    private func downloadLLMModelWithProgress(from url: URL, to destination: URL, fileName: String) async throws {
        let tempURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).download")
        try? FileManager.default.removeItem(at: tempURL)
        let downloadedURL = try await ModelDownloader.download(from: url) { [weak self] written, totalExpected in
            Task { @MainActor in
                // Only reflect progress for the download of the currently selected
                // model (a superseded download may still be running).
                guard let self, self.isLLMModelDownloading, self.selectedLLMModelPath() == destination.path else { return }
                let progress = DownloadProgressFormatter.make(written: written, totalExpected: totalExpected)
                self.llmModelDownloadProgress = progress.fraction
                self.llmModelDownloadStatus = progress.label
            }
        }
        // GGUF files start with the ASCII magic "GGUF".
        try Self.validateModelMagic(at: downloadedURL, expected: ["GGUF"], fileName: fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloadedURL, to: tempURL)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Refresh the list of staged WhisperKit models (call when opening the manager).
    func refreshWhisperKitStagedModels() {
        whisperKitStagedModels = WhisperKitModelCatalog.stagedModels()
    }

    // MARK: - Model storage (Settings › Models → Storage)

    /// Every installed model across the three backends, with its on-disk size and
    /// whether it's the currently-active one. Drives the Storage list + total. Walks
    /// the real directories (so manually-staged models are counted too). The display
    /// sorting/formatting/total is pure `ModelStorage`.
    func installedModelStorage() -> [ModelStorage.Item] {
        var items: [ModelStorage.Item] = []
        let fm = FileManager.default

        // WhisperKit CoreML: each staged model is a folder under whisperkit-models.
        let wkBase = WhisperKitModelCatalog.baseDir
        let activeWhisperKit = transcriptionEngine == "whisperKit" ? whisperKitModel : nil
        for name in (try? fm.contentsOfDirectory(atPath: wkBase.path)) ?? [] {
            let path = wkBase.appendingPathComponent(name)
            guard (try? path.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            items.append(ModelStorage.Item(
                kind: .whisperKit,
                label: WhisperKitModelCatalog.displayInfo(for: name).label,
                path: path.path,
                bytes: Self.directorySize(at: path),
                isActive: name == activeWhisperKit
            ))
        }

        // whisper.cpp GGML (*.bin) and built-in LLM (*.gguf) share OpenWhisp/models.
        let modelsDir = Self.applicationSupportModelsDirectory()
        let activeGGMLPath = URL(fileURLWithPath: modelPath).standardizedFileURL.path
        let activeLLMPath = URL(fileURLWithPath: selectedLLMModelPath()).standardizedFileURL.path
        for name in (try? fm.contentsOfDirectory(atPath: modelsDir.path)) ?? [] {
            let url = modelsDir.appendingPathComponent(name)
            let bytes = Self.fileSize(at: url)
            if name.hasSuffix(".bin") {
                items.append(ModelStorage.Item(
                    kind: .whisperCpp, label: name, path: url.path, bytes: bytes,
                    isActive: url.standardizedFileURL.path == activeGGMLPath
                ))
            } else if name.hasSuffix(".gguf") {
                items.append(ModelStorage.Item(
                    kind: .bundledLLM, label: name, path: url.path, bytes: bytes,
                    isActive: llmProvider == "bundled" && url.standardizedFileURL.path == activeLLMPath
                ))
            }
        }

        // Parakeet CoreML models (FluidAudio): each repo is a folder under
        // Application Support/FluidAudio/Models. Shown so their ~600 MB each
        // appears in disk usage and can be deleted (re-downloads on next use).
        // isActive stays false — the folder→variant mapping is loose and the
        // models re-download cheaply, so we keep them all deletable.
        let faBase = Self.fluidAudioModelsDirectory()
        for name in (try? fm.contentsOfDirectory(atPath: faBase.path)) ?? [] {
            let path = faBase.appendingPathComponent(name)
            guard (try? path.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            items.append(ModelStorage.Item(
                kind: .parakeet,
                label: ModelStorage.parakeetRepoLabel(forFolder: name),
                path: path.path,
                bytes: Self.directorySize(at: path),
                isActive: false
            ))
        }
        return ModelStorage.sorted(items)
    }

    /// Base directory FluidAudio stages its CoreML model repos under
    /// (`~/Library/Application Support/FluidAudio/Models`). Mirrors FluidAudio's
    /// own `downloadVariant`/`defaultCacheDirectory` layout.
    static func fluidAudioModelsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Delete a model's files. Refuses the currently-active model (removing it would
    /// force a re-download on the next dictation) — the UI disables that case, this
    /// is the belt-and-suspenders guard. Returns nil on success, else an error message.
    @discardableResult
    func removeModel(_ item: ModelStorage.Item) -> String? {
        guard !item.isActive else { return "Can't remove the model that's currently in use." }
        do {
            try FileManager.default.removeItem(atPath: item.path)
            // WhisperKit removals change the staged set the picker reads.
            if item.kind == .whisperKit { refreshWhisperKitStagedModels() }
            return nil
        } catch {
            return "Couldn't remove: \(error.localizedDescription)"
        }
    }

    /// Recursive allocated size of a directory (bytes). Used for WhisperKit models,
    /// which are folders of compiled sub-models.
    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let vals = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            total += Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Allocated size of a single file (bytes).
    private static func fileSize(at url: URL) -> Int64 {
        let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
    }

    /// Download + stage a WhisperKit model from the model manager. Single-flight:
    /// ignores a request while another download is in progress.
    func downloadWhisperKitModel(_ model: String) {
        guard whisperKitDownloadingModel == nil else { return }
        whisperKitDownloadingModel = model
        whisperKitDownloadFailed = false
        whisperKitDownloadProgress = 0
        let label = WhisperKitModelCatalog.displayInfo(for: model).label
        whisperKitDownloadStatus = "Downloading \(label)…"

        Task { @MainActor in
            do {
                try await WhisperKitEngine.downloadModel(model) { fraction in
                    Task { @MainActor in
                        // Only reflect progress for the active download (guards a late
                        // callback after cancel/replace).
                        guard self.whisperKitDownloadingModel == model else { return }
                        self.whisperKitDownloadProgress = fraction
                        self.whisperKitDownloadStatus =
                            "Downloading \(label)… \(Int(fraction * 100))%"
                    }
                }
                self.whisperKitDownloadStatus = "\(label) installed"
                self.refreshWhisperKitStagedModels()
                // If the just-downloaded model is the selected one, warm it now that
                // it's staged (turns the next dictation's load into a no-op).
                if self.transcriptionEngine == "whisperKit", self.whisperKitModel == model {
                    self.warmWhisperServerIfPossible()
                }
            } catch {
                self.whisperKitDownloadStatus = "Download failed: \(error.localizedDescription)"
                // Discrete flag, not just status text: the onboarding model step
                // keys its retryable failure card on this (a text-only signal left
                // it spinning forever behind "Preparing your speech model").
                self.whisperKitDownloadFailed = true
            }
            self.whisperKitDownloadingModel = nil
            self.whisperKitDownloadProgress = 0
        }
    }

    /// Kick the streaming-variant model prefetch and mark it in-flight so the
    /// Models pane shows a coarse "Downloading…" badge (FluidAudio gives no
    /// progress). Event-driven: the badge clears when the engine's load task
    /// completes — success or failure (on failure the row honestly reverts to
    /// "Not downloaded"). No disk polling, and no state mutation during view
    /// rendering. Idempotent (the engine coalesces concurrent loads).
    func prefetchParakeetVariant() {
        let variant = ParakeetCatalog.normalize(parakeetVariant)
        // A new prefetch attempt clears any stale failure — this doubles as the
        // Retry path (onboarding re-kicks this on the retry button).
        parakeetPrefetchFailed = false
        // If the repo is already on disk there's nothing to download — don't
        // flash a badge; still prefetch (it warms the loaded model cheaply).
        let installed = Self.installedFluidAudioFolders()
        if ParakeetDownloadStatePolicy.state(
            forVariant: variant, installedFolders: installed, inFlightVariants: []
        ) != .installed {
            parakeetInFlightVariants.insert(variant)
        }
        // Capture THIS engine instance: if the user switches variant mid-prefetch,
        // rebuildFileEngine replaces `parakeetStreamEngine` (and cancels its load).
        // Awaiting the captured instance means this task tracks the load it actually
        // started — not whichever engine happens to exist when the await resumes.
        let engine = parakeetStreamEngine
        Task { @MainActor in
            let ok = await engine?.prefetchAwaiting() ?? false
            parakeetInFlightVariants.remove(variant)
            // Only report a failure when the model genuinely isn't on disk. A load
            // can "fail" for reasons unrelated to the download (e.g. the engine was
            // replaced by a variant switch) while the bytes are already staged; a
            // present folder means the user is not stuck, so don't cry failure.
            if !ok {
                let onDisk = ParakeetDownloadStatePolicy.state(
                    forVariant: variant,
                    installedFolders: Self.installedFluidAudioFolders(),
                    inFlightVariants: []
                ) == .installed
                parakeetPrefetchFailed = !onDisk
            }
        }
    }

    /// The set of FluidAudio Models repo folders present on disk right now.
    static func installedFluidAudioFolders() -> Set<String> {
        let base = fluidAudioModelsDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return Set(names.filter { name in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(
                atPath: base.appendingPathComponent(name).path, isDirectory: &isDir)
            return isDir.boolValue
        })
    }

    func warmWhisperServerIfPossible() {
        // Warm the CURRENTLY SELECTED file-transcription backend — and only that
        // one. This must be engine-aware: `whisperEngine` is a WhisperKitEngine
        // when transcriptionEngine == "whisperKit", so warming the wrong gate here
        // is how we ended up with whisper.cpp's server AND WhisperKit both loading
        // models at once (the dual-engine memory pressure behind the crash).
        switch transcriptionEngine {
        case "whisperKit":
            // WhisperKit has no external server; warm = preload its CoreML model
            // up front (with a visible status) so the slow first load doesn't block
            // the first dictation. Doesn't depend on whisperBackend.
            guard !isModelDownloading else {
                whisperWorkerStatus = "Waiting for model"
                return
            }
            whisperEngine?.warmServer(binaryPath: whisperBinaryPath, modelPath: modelPath)
        case "appleSpeech":
            // Apple Speech is a streaming engine; nothing to warm here.
            return
        case "speechAnalyzer":
            // SpeechAnalyzer (macOS 26): warm = provision the on-device locale
            // model so the first file/meeting job doesn't pay the asset install.
            // The file engine owns that; no-ops on older OSes.
            whisperEngine?.warmServer(binaryPath: whisperBinaryPath, modelPath: modelPath)
            return
        case "parakeet":
            // Parakeet has two model families: the streaming variant (live
            // dictation) and the batch TDT v3 (meetings / file jobs). Warm the
            // streaming variant now (the common dictation path); the file engine's
            // TDT v3 is warmed lazily on the first file/meeting job to avoid
            // paying two ~600 MB downloads up front when only one is used.
            prefetchParakeetVariant()
            return
        default:
            // whisper.cpp: only the serverAPI backend keeps a warm server process.
            guard whisperBackend == "serverAPI" else { return }
            guard !isModelDownloading else {
                whisperWorkerStatus = "Waiting for model"
                return
            }
            whisperEngine?.warmServer(binaryPath: whisperBinaryPath, modelPath: modelPath)
        }
    }

    /// Provider-aware "Test": verifies what the SELECTED provider actually
    /// needs — the built-in runtime+model (loading the server if needed), the
    /// self-hosted server, or the OpenAI key — and reports in those terms.
    /// (Previously every provider went through the same endpoint ping, so a
    /// bundled test could report "OpenAI key valid".)
    func testLLMProvider() {
        error = nil
        switch llmProvider {
        case EnhancementProvider.agentCLIID:
            // Validate the config builds first (empty command / transcript-in-args
            // fail closed with a clear message, no spawn).
            switch AgentCLIProvider.buildCommand(config: activeAgentCLIConfig) {
            case .failure(.emptyCommand):
                translationStatus = "Enter the agent CLI command first"
                return
            case .failure(.transcriptInArgs):
                translationStatus = "Remove \(AgentCLIProvider.transcriptSentinel) from the arguments"
                return
            case .success:
                break
            }
            translationStatus = "Testing agent CLI…"
            let config = activeAgentCLIConfig
            // Actually run the CLI on a tiny probe off the main actor (it's a
            // blocking Process spawn). Fail-open: identical output = the CLI didn't
            // transform anything, but it DID run, so the wiring is proven.
            Task { @MainActor [weak self] in
                let probe = "test one two"
                let output = await Task.detached(priority: .userInitiated) {
                    AgentCLIRunner.run(probe, config: config)
                }.value
                guard let self else { return }
                if output == probe {
                    // Ran but returned the original — either the CLI isn't installed
                    // (fail-open kept the input) or it genuinely made no change.
                    self.translationStatus = "Agent CLI ran (no change / not installed)"
                } else {
                    self.translationStatus = "Agent CLI working"
                }
            }

        case "bundled":
            guard bundledLLMRuntimeAvailable else {
                translationStatus = "This build doesn't include the built-in AI runtime"
                return
            }
            guard bundledLLMModelInstalled else {
                translationStatus = "Built-in model not downloaded"
                return
            }
            translationStatus = "Loading built-in model…"
            // Route through the same readiness path refine uses, so a passing
            // test means refine will actually work.
            ensureBundledLLMReady(statusWhileLoading: "Loading built-in model…", work: { [weak self] done in
                guard let self else { done(); return }
                self.translationService.validate(endpoint: self.llmEndpoint, model: self.llmModel) { result in
                    Task { @MainActor in
                        done()
                        switch result {
                        case .success:
                            self.translationStatus = "Built-in model working"
                        case .failure(let error):
                            self.translationStatus = "Built-in model test failed"
                            self.error = "Built-in model test failed: \(error.localizedDescription)"
                        }
                    }
                }
            }, fallback: { [weak self] in
                self?.translationStatus = "Built-in model unavailable"
            })

        case "local":
            translationStatus = "Testing server…"
            translationService.validate(endpoint: llmEndpoint, model: llmModel) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.translationStatus = "Server reachable"
                    case .failure(let error):
                        self.translationStatus = "Server test failed"
                        self.error = "Server test failed: \(error.localizedDescription)"
                    }
                }
            }

        default:
            guard !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                translationStatus = "Add your OpenAI API key first"
                return
            }
            translationStatus = "Validating key…"
            translationService.validate(endpoint: llmEndpoint, model: llmModel) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.translationStatus = "OpenAI key valid"
                    case .failure(let error):
                        self.translationStatus = "OpenAI key check failed"
                        self.error = "OpenAI key check failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Start a real-time streaming session with the active streaming engine (Apple
    /// Speech or WhisperKit). Both share this path, the session flags, and the
    /// live-preview handlers; only auth and the recognizer differ.
    func startStreamingSession() {
        guard !isRecording, !isTranscribing else { return }
        guard !SecureFieldDetector.focusedFieldIsSecure() else {
            refuseDictationIntoSecureField()
            return
        }
        beginSession(streaming: false)
        // Snapshot the live-typed decision for this session. In liveChunks mode the
        // streaming handlers type each delta incrementally, so insertCompletedText
        // must take the "already pasted, clipboard only" branch — exactly like
        // whisper chunked sessions. Deciding from the live @Published outputMode
        // there would paste the whole final text a second time.
        isLiveChunkSession = outputMode == "liveChunks"
        isAppleSpeechSession = true
        // Re-bind the active engine's partial/final closures to THIS session's
        // generation so its callbacks carry `activeSessionID`. A late final from a
        // previous engine session (bound to an older generation) is then dropped by
        // the handlers' fence rather than pasting the old transcript / completing
        // this session early (finding: late-onFinal cross-session leak).
        bindStreamingSessionCallbacks(activeStreamingEngine, sessionID: activeSessionID)
        // Spoken edit commands (MAK-19) are decided HERE, not in beginSession:
        // this streaming path calls beginSession(streaming: false), so its
        // isPreviewSession is always false — the gate has to read `outputMode`
        // directly, which is authoritative on this path (both streaming engines
        // finalize through handleAppleSpeechFinal, the interception site). Never
        // in agent sessions (they return the raw transcript over the bridge);
        // suppressOutput was snapshotted by the beginSession call just above. The
        // predicate lives in VoiceEditRouter.isActive so it's unit-tested (a dead
        // gate here is exactly the regression the reviewer caught).
        voiceEditingActiveForSession = VoiceEditRouter.isActive(
            outputMode: outputMode,
            enabled: voiceEditingEnabled,
            suppressOutput: suppressOutput
        )
        voiceEditBuffer = VoiceEditBuffer()
        appleLiveInsertedText = ""
        appleDidCompleteFinal = false
        // Keep the "Starting..." arming cue from beginSession until the recognizer
        // is actually live. Every backend has a startup gap: async mic grant (plus
        // Speech-auth for Apple), then engine start — and for the chained engines
        // (WhisperKit/Parakeet) the model load after start() is enqueued. The gap
        // ends when the engine's onStarted signal fires (handleStreamingCaptureStarted).
        let sessionID = activeSessionID
        // Apple Speech needs Speech-framework authorization on top of the mic;
        // the on-device engines (WhisperKit, Parakeet) need only the mic.
        let needsSpeechAuth = StreamingRoutePolicy.needsSpeechAuthorization(engine: transcriptionEngine)
        let engine = activeStreamingEngine
        // Snapshot the selected input device for this session. Both streaming engines
        // apply it in start(): Apple Speech retargets its own AVAudioEngine input
        // node; WhisperKit passes the device into AudioStreamTranscriber (fork
        // backport of upstream #503). "" = follow the system default. Previously
        // never applied here at all — the reason a non-default mic was silently
        // ignored on the default (streaming) path.
        let micID = microphoneID

        // The actual engine start, after permissions are granted.
        let launch: @MainActor () -> Void = {
            // The grant is async: a newer session may have begun (drop — aborting
            // would tear down that successor), or this session's own stop may have
            // landed first (abort). Only proceed when still active with no pending
            // stop. See StreamingRoutePolicy.grantCallbackAction.
            switch StreamingRoutePolicy.grantCallbackAction(
                callbackSessionID: sessionID,
                activeSessionID: self.activeSessionID,
                pendingStop: self.pendingStop
            ) {
            case .drop:
                return
            case .abort:
                self.isAppleSpeechSession = false
                self.abortSessionBeforeStart()
                return
            case .proceed:
                break
            }
            do {
                engine.selectDevice(micID)
                try engine.start(language: self.engineLanguageSetting, prompt: EngineCapabilities.streamingPrompt(
                    transcriptionEngine: self.transcriptionEngine, vocabularyPrompt: self.effectiveWhisperPrompt))
                // Do NOT flip to Listening here: for WhisperKit/Parakeet,
                // start() only ENQUEUED the real start on the engine's serial
                // lifecycle chain — the model load (or first-run download)
                // hasn't happened and no mic tap exists yet, so speech in that
                // gap would be silently dropped behind a "Listening" UI. The
                // session stays arming ("Starting…") until the engine's
                // onStarted signal (bound per-session in
                // bindStreamingSessionCallbacks) reports capture genuinely
                // live. Apple Speech starts synchronously, so its onStarted has
                // already fired inside start() and the session is live here.
                // Timeout fallback: if the signal never lands (wiring bug),
                // flip anyway rather than wedging the session at "Starting…".
                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: UInt64(StreamingRoutePolicy.captureStartTimeout * 1_000_000_000))
                    self.handleStreamingCaptureStarted(sessionID: sessionID)
                }
            } catch {
                self.error = error.localizedDescription
                self.statusMessage = "Streaming Error"
                self.isAppleSpeechSession = false
                self.sessionOutcome = .error(message: error.localizedDescription)
                self.finishSessionUI()
            }
        }

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.error = "Microphone access denied. Check System Settings."
                    self.isAppleSpeechSession = false
                    self.sessionOutcome = .error(message: "microphone access denied")
                    self.finishSessionUI()
                    return
                }
                // WhisperKit/Parakeet need only the mic; Apple Speech also needs Speech auth.
                if !needsSpeechAuth {
                    launch()
                } else {
                    AppleSpeechEngine.requestAuthorization { status in
                        Task { @MainActor in
                            guard status == .authorized else {
                                self.error = "Speech recognition access denied. Check System Settings."
                                self.isAppleSpeechSession = false
                                self.sessionOutcome = .error(message: "speech recognition access denied")
                                self.finishSessionUI()
                                return
                            }
                            launch()
                        }
                    }
                }
            }
        }
    }

    func stopAppleSpeech() {
        guard isAppleSpeechSession else { return }
        isRecording = false
        isTranscribing = true
        statusMessage = "Finalizing..."
        // Keep the overlay up through finalize so a follow-up double-tap (refine)
        // transitions by COLOR rather than a disappear/reappear flicker. It's hidden
        // at the true end (insert / finishSessionUI).
        activeStreamingEngine.stop(cancel: false)

        // Session-scoped fallback: a rapid follow-up session could otherwise be
        // finalized early by THIS session's leftover timer.
        //
        // 2.0s (not 0.9s): AppleSpeechEngine's own 0.8s fallback guarantees a
        // final for the Apple path, so this is a stuck-session guard (WhisperKit
        // streaming teardown, engine deallocated) — with a wide margin so a busy
        // main thread can't let this fire first and clobber the engine's genuine
        // final (which arrives via an extra Task hop) with a stale partial.
        let sessionID = activeSessionID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if sessionID == self.activeSessionID && self.isAppleSpeechSession && self.isTranscribing && !self.appleDidCompleteFinal {
                self.handleAppleSpeechFinal(self.streamingText, sessionID: sessionID)
            }
        }
    }

    private func handleAppleSpeechPartial(_ rawText: String, sessionID: UUID) {
        // Drop a partial from a previous engine session (bound to an older
        // generation) that landed after a newer session began — see
        // StreamingRoutePolicy.isStaleStreamingCallback.
        guard !StreamingRoutePolicy.isStaleStreamingCallback(
            callbackSessionID: sessionID, activeSessionID: activeSessionID) else { return }
        guard isAppleSpeechSession else { return }
        // A new partial means the speaker kept going — cancel any pending EOU stop
        // (MAK-46 Phase 5). Inert unless an agent EOU session is armed.
        agentEouDetector?.notePartial()
        let text = postProcess(rawText)
        streamingText = text
        statusMessage = text.isEmpty ? "Listening..." : "Listening..."

        // Once refine is armed mid-session, the words being spoken are the
        // INSTRUCTION — don't type them into the document as live chunks.
        guard refineContentSnapshot == nil else { return }

        // Agent sessions return the transcript over the bridge and must never
        // type into the frontmost app — the overlay preview above still updates.
        guard isLiveChunkSession, !suppressOutput, !text.isEmpty else { return }
        let delta = liveDelta(previous: appleLiveInsertedText, current: text)
        guard !delta.isEmpty else { return }

        // Use a leading separator (matching insertLiveChunk) so the trailing space stays
        // conditional and is typed once at finalization based on addTrailingSpace.
        // Defensive privacy guard: don't paste a live partial into a secure field
        // if focus moved to one mid-session. Fail-open on detection errors.
        guard !SecureFieldDetector.focusedFieldIsSecure() else {
            statusMessage = "Won't dictate into a password field"
            return
        }
        let insertion = appleLiveInsertedText.isEmpty ? delta : " \(delta)"
        appleLiveInsertedText = text
        currentSessionText = text
        textOutput.insert(
            insertion,
            mode: currentInsertionMode,
            restoreClipboard: restoreClipboard
        )
    }

    private func handleAppleSpeechFinal(_ rawText: String, sessionID: UUID) {
        // Drop a LATE final from a previous engine session (e.g. Apple Speech's
        // ~0.8s synthesized-final fallback firing after a quick cancel+restart):
        // without this fence it would paste the old transcript and complete the
        // NEW session early. See StreamingRoutePolicy.isStaleStreamingCallback.
        guard !StreamingRoutePolicy.isStaleStreamingCallback(
            callbackSessionID: sessionID, activeSessionID: activeSessionID) else { return }
        guard isAppleSpeechSession, !appleDidCompleteFinal else { return }
        appleDidCompleteFinal = true
        let rawTranscript = rawText.isEmpty ? streamingText : rawText

        // Spoken edit commands (MAK-19): in a preview session with the feature on,
        // route the recognizer's transcript through the session's edit buffer BEFORE
        // cleanup. A standalone "scratch that" / "undo" / … then edits the pending
        // dictation instead of being pasted as literal words; `voiceEditBuffer.text`
        // is the dictation AFTER those edits, and the normal cleanup runs on THAT.
        // Only the preview path reaches here with the flag set (guaranteed in
        // beginSession), and the isLiveChunkSession delta-paste block below is
        // skipped in preview, so nothing else changes for other modes.
        let editedRaw: String
        if voiceEditingActiveForSession {
            VoiceEditRouter.route(final: rawTranscript, into: &voiceEditBuffer)
            editedRaw = voiceEditBuffer.text
        } else {
            editedRaw = rawTranscript
        }
        let finalText = postProcess(editedRaw, isFinalTranscript: true)

        // liveChunks: completeFinalText only sets the clipboard for non-finalOnly, so words
        // in the final transcript that were not in the last pasted partial would be dropped.
        // Paste the trailing delta here (mirroring handleAppleSpeechPartial) before routing.
        // While a refine is armed the delta is the spoken INSTRUCTION — same guard as the
        // partial handler; completeFinalText consumes it via the snapshot path.
        if isLiveChunkSession, !suppressOutput, refineContentSnapshot == nil, !SecureFieldDetector.focusedFieldIsSecure() {
            let delta = liveDelta(previous: appleLiveInsertedText, current: finalText)
            if !delta.isEmpty {
                let insertion = appleLiveInsertedText.isEmpty ? delta : " \(delta)"
                appleLiveInsertedText = finalText
                textOutput.insert(
                    insertion,
                    mode: currentInsertionMode,
                    restoreClipboard: restoreClipboard
                )
            }
        }

        currentSessionText = finalText
        isAppleSpeechSession = false
        completeFinalText(finalText)
    }

    private func liveDelta(previous: String, current: String) -> String {
        guard current.count > previous.count else { return "" }
        let prefix = current.prefix(previous.count)
        guard prefix == previous else { return "" }
        return String(current.dropFirst(previous.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func startRecording() {
        guard !isRecording, !isTranscribing else { return }
        // Mic exclusivity (MAK-50): defense-in-depth for callers that bypass
        // startDictation (which carries the primary guard).
        if meetingInProgress {
            statusMessage = "Stop the meeting before dictating"
            return
        }
        guard !SecureFieldDetector.focusedFieldIsSecure() else {
            refuseDictationIntoSecureField()
            return
        }
        beginSession(streaming: false)

        let micID = microphoneID
        let sessionID = activeSessionID
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.error = "Microphone access denied. Check System Settings."
                    self.sessionOutcome = .error(message: "microphone access denied")
                    self.finishSessionUI()
                    return
                }
                // The hotkey may have been released (or the session cancelled/restarted)
                // before this callback ran. Drop if a newer session began (aborting
                // would tear it down); abort only this session's own stalled start.
                // See StreamingRoutePolicy.grantCallbackAction.
                switch StreamingRoutePolicy.grantCallbackAction(
                    callbackSessionID: sessionID,
                    activeSessionID: self.activeSessionID,
                    pendingStop: self.pendingStop
                ) {
                case .drop:
                    return
                case .abort:
                    self.abortSessionBeforeStart()
                    return
                case .proceed:
                    break
                }
                // Read the recorder here (inside the @MainActor Task) rather than
                // capturing it into the @Sendable access-grant closure — the
                // non-Sendable existential never crosses the concurrency boundary.
                let recorder = self.audioRecorder!
                if !micID.isEmpty {
                    recorder.selectDevice(micID)
                }
                self.recorderSessionID = sessionID
                recorder.start()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isStreamingSession = false
        isTranscribing = true
        statusMessage = "Finalizing..."
        // Keep the overlay up through transcription (it shows the violet "finalizing"
        // pulse + a status caption) so the user gets feedback during the load+decode
        // window — which can be seconds, or much longer on a cold WhisperKit model
        // load. It's hidden at the true end (insertCompletedText → finishSessionUI,
        // or the error path). Previously hidden here, which made WhisperKit look hung.

        let sessionID = activeSessionID
        audioRecorder.stop { [weak self] wavPath in
            Task { @MainActor in
                guard let self else { return }
                // Release-then-Esc race: drop the trailing audio if the session was rotated.
                guard sessionID == self.activeSessionID else {
                    if let path = wavPath {
                        try? FileManager.default.removeItem(at: path)
                    }
                    return
                }
                guard let path = wavPath else {
                    self.isTranscribing = false
                    self.statusMessage = "Ready"
                    self.sessionOutcome = .empty
                    self.finishSessionUI()
                    return
                }

                // MAK-40: the engine transcribes with deleteWhenDone, so COPY the
                // whole-session WAV to a staging file NOW (before it's deleted) if
                // retention is on. recordHistory renames the staging file to the
                // entry's canonical name; the secure-field guard there still applies.
                self.stageRetainedAudio(from: path)
                self.startTranscription(path: path, kind: .final)
            }
        }
    }

    /// Optional live mode: record chunks, transcribe each, paste stable-ish chunks.
    func startStreaming() {
        guard !isRecording, !isTranscribing else { return }
        // Mic exclusivity (MAK-50): defense-in-depth for callers that bypass
        // startDictation (which carries the primary guard).
        if meetingInProgress {
            statusMessage = "Stop the meeting before dictating"
            return
        }
        guard !SecureFieldDetector.focusedFieldIsSecure() else {
            refuseDictationIntoSecureField()
            return
        }
        beginSession(streaming: true)

        let micID = microphoneID
        let sessionID = activeSessionID
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.error = "Microphone access denied."
                    self.sessionOutcome = .error(message: "microphone access denied")
                    self.finishSessionUI()
                    return
                }
                // The hotkey may have been released (or the session cancelled/restarted)
                // before grant. Drop if a newer session began (aborting would tear it
                // down); abort only this session's own stalled start. See
                // StreamingRoutePolicy.grantCallbackAction.
                switch StreamingRoutePolicy.grantCallbackAction(
                    callbackSessionID: sessionID,
                    activeSessionID: self.activeSessionID,
                    pendingStop: self.pendingStop
                ) {
                case .drop:
                    return
                case .abort:
                    self.abortSessionBeforeStart()
                    return
                case .proceed:
                    break
                }
                // Read the recorder here (inside the @MainActor Task) rather than
                // capturing it into the @Sendable access-grant closure — the
                // non-Sendable existential never crosses the concurrency boundary.
                let recorder = self.audioRecorder!
                if !micID.isEmpty {
                    recorder.selectDevice(micID)
                }
                let onChunk: (URL?) -> Void = { [weak self] chunkPath in
                    Task { @MainActor in
                        guard let self, let path = chunkPath, self.acceptingLiveChunks else {
                            if let chunkPath {
                                try? FileManager.default.removeItem(at: chunkPath)
                            }
                            return
                        }
                        self.enqueueLiveChunk(path)
                    }
                }
                self.recorderSessionID = sessionID
                if self.pauseBasedLiveChunksEnabled {
                    // Quiet mode lowers the VAD speech gate (and lengthens the pause
                    // hangover) so a whisper still opens a chunk. Thresholds come from
                    // the pure, unit-tested QuietDictationMode resolver.
                    let t = QuietDictationMode.thresholds(quietEnabled: self.quietDictationEnabled)
                    recorder.startStreamingOnSilence(
                        silenceDuration: t.silenceDuration,
                        minimumSpeechDuration: t.minimumSpeechDuration,
                        maximumSpeechDuration: t.maximumSpeechDuration,
                        speechThreshold: t.speechThreshold,
                        onChunk: onChunk
                    )
                } else {
                    recorder.startStreaming(chunkDuration: self.liveChunkDuration, onChunk: onChunk)
                }
            }
        }
    }

    func stopStreaming() {
        guard isRecording else { return }
        isStreamingSession = false
        acceptingLiveChunks = false
        isTranscribing = true
        statusMessage = isPreviewSession ? "Polishing..." : "Finalizing..."
        // Preview keeps the overlay up through the polish step so the user sees
        // the captured transcript + "Polishing..." before the single paste.
        // (finishSessionUI hides it after insertCompletedText.)
        if !isPreviewSession {
            hideOverlayNow()
        }

        let sessionID = activeSessionID
        audioRecorder.stop { [weak self] finalPath in
            Task { @MainActor in
                guard let self else { return }
                // Release-then-Esc race: if the session was cancelled (or rotated) between
                // the hotkey-up and this completion, drop the trailing audio entirely.
                guard sessionID == self.activeSessionID else {
                    if let path = finalPath {
                        try? FileManager.default.removeItem(at: path)
                    }
                    return
                }
                if let path = finalPath {
                    self.enqueueLiveChunk(path)
                } else if self.livePipelineIsDrained {
                    // Fully silent session with nothing pending: finalize now so it doesn't hang.
                    self.completeFinalText(self.currentSessionText)
                }
                // Otherwise leave isTranscribing = true ("Finalizing...") and let the
                // drain-gated paths (handleTranscription / processNextLiveInsertion /
                // the live-chunk error handler) call completeFinalText once chunks finish.
            }
        }
    }

    /// Called from a grant callback when the user already released the hotkey (or cancelled)
    /// before recording could start. Tears the half-started session down without recording.
    private func abortSessionBeforeStart() {
        activeSessionID = UUID()
        transcriptionRequests.removeAll()
        cleanupPendingLiveChunks()
        resetLivePipeline()
        acceptingLiveChunks = false
        isStreamingSession = false
        isLiveChunkSession = false
        isPreviewSession = false
        isAppleSpeechSession = false
        isRecording = false
        isTranscribing = false
        // Also drop any engaged refine. Without this, aborting the instruction-
        // capture session of a too-fast re-press left the flow active with no live
        // session — a late transcript would re-enter the refine path and wedge the
        // overlay. reset() (not .abort) because we're already tearing the UI down.
        refineContentSnapshot = nil
        refineFlow.reset()
        syncRefineUI()
        currentSessionText = ""
        streamingText = ""
        statusMessage = "Ready"
        finishSessionUI()
    }

    private func beginSession(streaming: Bool) {
        error = nil
        sessionActive = true
        pendingStop = false
        activeSessionID = UUID()
        // Let the file engine forget per-dictation state (e.g. WhisperKit's
        // auto-detected language) so each session starts fresh.
        whisperEngine?.resetSession()
        transcriptionRequests.removeAll()
        cleanupPendingLiveChunks()
        resetLivePipeline()
        acceptingLiveChunks = streaming
        currentSessionText = ""
        streamingText = ""
        // Reset the overlay-revert tracker so it's only ever set when THIS session
        // actually inserts into the focused app — a session that ends empty, in a
        // secure field, or with an error must not leave a prior session's text as a
        // revert target (MAK-35). The insert paths set it when they place text.
        lastInsertedIntoFocusedApp = nil
        openAIEnhancementEnabledForSession = openAIEnhancementEnabled
        isLiveChunkSession = streaming
        // Preview mode captures via the chunk pipeline but defers pasting.
        isPreviewSession = streaming && outputMode == "preview"
        // Agent-initiated sessions return the transcript to the caller instead of
        // pasting. Snapshot from the initiator (set by the bridge before this call)
        // so a mid-session change can't alter the paste-vs-return disposition.
        suppressOutput = sessionInitiator.isAgent
        // Spoken edit commands (MAK-19) are gated per-session, but the decision is
        // made in startStreamingSession() — the streaming path that actually reaches
        // the interception site (handleAppleSpeechFinal) and where `outputMode` is
        // authoritative. Here we only DEFAULT it off + reset the buffer, so a session
        // that never goes through that path (recording/chunk paths) can't inherit a
        // stale flag from a prior streaming session.
        voiceEditingActiveForSession = false
        voiceEditBuffer = VoiceEditBuffer()
        audioLevel = 0
        recordingElapsed = 0
        recordingStartedAt = Date()
        transcriptionStartedAt = nil
        // A new dictation invalidates any pending correction re-read from the last
        // one — the field is about to change for a different reason (MAK-41 Part C).
        correctionWatcher.cancel()
        // And drop any un-consumed fired-rule stash from a session that post-
        // processed but never delivered (MAK-41 Part A, consume-once semantics).
        sessionFiredSubstitutionIDs = []
        targetApplication = currentTextTargetApplication()
        isStreamingSession = streaming
        isTranscribing = false
        // Capture isn't live until the recorder reports `.recording` (after the
        // async mic-permission grant + engine start). Until then we're "arming":
        // the overlay shows a wait cue so the user doesn't speak into the gap and
        // lose the first word(s). `.recording` clears isArming.
        isArming = true
        statusMessage = "Starting..."
        startElapsedTimer()
        // Agent-initiated sessions ALWAYS show the overlay (regardless of the
        // user's showOverlay setting) so agent microphone use is never invisible.
        if showOverlay || sessionInitiator.isAgent {
            overlayController?.show()
            overlayIsVisible = true
        }
    }

    private func handleTranscription(_ rawText: String, requestID: UUID) {
        guard let request = consumeRequest(requestID), request.sessionID == activeSessionID else { return }
        let text = postProcess(rawText)

        guard !text.isEmpty else {
            if request.kind == .liveChunk {
                if let sequence = request.sequence {
                    livePipeline.complete(sequence, text: "")
                }
                processNextLiveChunk()
                flushOrderedLiveResults()
                if isTranscribing && livePipelineIsDrained {
                    completeFinalText(currentSessionText)
                } else {
                    statusMessage = isTranscribing ? "Finalizing..." : "Listening..."
                }
            } else if isTranscribing {
                completeFinalText(currentSessionText)
            } else {
                statusMessage = "Listening..."
            }
            return
        }

        switch request.kind {
        case .liveChunk:
            if let sequence = request.sequence {
                livePipeline.complete(sequence, text: text)
            }
            processNextLiveChunk()
            flushOrderedLiveResults()
            if isTranscribing && livePipelineIsDrained {
                completeFinalText(currentSessionText)
            }
        case .final:
            if isTranscribing {
                let finalText = currentSessionText.isEmpty ? text : "\(currentSessionText) \(text)"
                completeFinalText(finalText)
            }
        }
    }

    private func enqueueLiveChunk(_ path: URL) {
        let id = livePipeline.enqueue()
        liveChunkURLs[id] = path
        statusMessage = isTranscribing ? "Finalizing..." : "Queued chunk #\(livePipeline.queuedCount)..."
        processNextLiveChunk()
    }

    private func processNextLiveChunk() {
        guard isLiveChunkSession else { return }
        let dispatched = livePipeline.dispatchable()
        guard !dispatched.isEmpty else { return }
        statusMessage = isTranscribing ? "Finalizing..." : "Transcribing chunks..."
        for id in dispatched {
            // Hand the file to whisper (deleteWhenDone: true) and stop tracking it
            // here, so cleanup on cancel only removes still-undispatched files —
            // it must never yank a WAV out from under an in-flight transcription.
            guard let url = liveChunkURLs.removeValue(forKey: id) else { continue }
            startTranscription(path: url, kind: .liveChunk, sequence: id)
        }
    }

    private func startTranscription(path: URL, kind: TranscriptionKind, sequence: Int? = nil) {
        let requestID = UUID()
        transcriptionRequests[requestID] = TranscriptionRequest(sessionID: activeSessionID, kind: kind, sequence: sequence)
        whisperEngine.transcribe(
            requestID: requestID,
            binaryPath: whisperBinaryPath,
            modelPath: modelPath,
            language: engineLanguageSetting,
            wavPath: path.path,
            backend: whisperBackend == "serverAPI" ? .serverAPI : .cli,
            // MAK-34: custom vocabulary + any screen-context bias terms harvested
            // this session. Both only prime the on-device engine (whisper.cpp CLI /
            // server); WhisperKit ignores the string prompt today (known pilot gap).
            prompt: effectiveWhisperPrompt
        )
    }

    private func consumeRequest(_ requestID: UUID) -> TranscriptionRequest? {
        transcriptionRequests.removeValue(forKey: requestID)
    }

    /// Delete the WAV files for any chunks the pipeline still holds, then drop the
    /// payload map. The pipeline's own sequencing reset happens in resetLivePipeline.
    private func cleanupPendingLiveChunks() {
        for url in liveChunkURLs.values {
            try? FileManager.default.removeItem(at: url)
        }
        liveChunkURLs.removeAll()
    }

    private var livePipelineIsDrained: Bool {
        livePipeline.isDrained
    }

    private func resetLivePipeline() {
        cleanupPendingLiveChunks()
        livePipeline.reset()
    }

    /// Emit the now-contiguous ordered results from the pipeline into the
    /// insertion stage.
    private func flushOrderedLiveResults() {
        for text in livePipeline.takeOrderedReady() {
            queueLiveInsertion(text)
        }
    }

    private func queueLiveInsertion(_ text: String) {
        livePipeline.queueForInsertion([text])
        processNextLiveInsertion()
    }

    private func processNextLiveInsertion() {
        guard let item = livePipeline.nextInsertion() else { return }

        guard shouldEnhanceLiveChunks else {
            insertLiveChunk(item)
            livePipeline.finishInsertion()
            processNextLiveInsertion()
            return
        }

        statusMessage = "Rephrasing chunk..."
        let sessionID = activeSessionID

        // Insert the raw chunk and advance the pipeline — used as the fallback
        // when the bundled LLM can't start, so a chunk is never dropped.
        func insertRawAndAdvance() {
            self.insertLiveChunk(item)
            self.livePipeline.finishInsertion()
            self.processNextLiveInsertion()
            if self.isTranscribing && self.livePipelineIsDrained {
                self.completeFinalText(self.currentSessionText)
            }
        }

        ensureBundledLLMReady(work: { [weak self] done in
            guard let self else { done(); return }
            self.translationService.processFinalText(
                text: item,
                mode: self.refinementMode("rephrase"),
                targetLanguage: self.translationTargetLanguage,
                endpoint: self.llmEndpoint,
                model: self.llmModel,
                // MAK-35/77: the same composer funnel as the whole-text refiner, so
                // the dial + per-app preset are authoritative for live chunks too
                // (`.none` never reaches here — shouldEnhanceLiveChunks gates it out;
                // Modes never steered live chunks, so modeOverride stays nil).
                customInstruction: RefineInstructionComposer.sessionInstruction(
                    modeOverride: nil,
                    presetOverride: self.presetRefineInstructionOverride,
                    intensity: self.cleanupIntensity, mode: self.openAIEnhancementMode,
                    translateToEnglish: self.effectiveTranslateToEnglish)
            ) { [weak self] result in
                Task { @MainActor in
                    // Close the engine's in-flight bracket on EVERY completion path
                    // (including the guarded early returns below).
                    done()
                    guard let self, sessionID == self.activeSessionID else { return }
                    let textToInsert: String
                    switch result {
                    case .success(let processedText):
                        let cleaned = self.postProcess(processedText)
                        // Language guard (fix): reject a chunk the model translated
                        // away (non-Latin → Latin) and keep the raw chunk. Same
                        // fail-open behavior as an LLM error. Live chunks only ever run
                        // "rephrase" and never agent sessions, so the exemptions reduce
                        // to translateToEnglish.
                        let chunkExpectedScript = RefineOutputGuard.expectedCleanupScript(
                            translateToEnglish: self.effectiveTranslateToEnglish,
                            mode: self.openAIEnhancementMode,
                            translationTargetLanguage: self.translationTargetLanguage
                        )
                        let guardChunk = RefineOutputGuard.shouldLanguageGuard(
                            isSpokenInstructionRefine: false,
                            isAgentBridgeRefine: false
                        ) && RefineOutputGuard.outputTranslatedAway(
                            input: item, output: cleaned, expectedOutputScript: chunkExpectedScript
                        )
                        if guardChunk {
                            self.refineDebug("language guard REJECTED chunk cleanup (looked translated); keeping raw chunk")
                            textToInsert = item
                            self.translationStatus = "Kept your language (cleanup translated)"
                        } else {
                            textToInsert = cleaned.isEmpty ? item : cleaned
                            self.translationStatus = cleaned.isEmpty ? "LLM returned empty chunk" : "Rephrased"
                        }
                    case .failure(let error):
                        textToInsert = item
                        self.translationStatus = "Rephrase failed"
                        self.error = "Chunk rephrase failed: \(error.localizedDescription)"
                    }

                    self.insertLiveChunk(textToInsert)
                    self.livePipeline.finishInsertion()
                    self.processNextLiveInsertion()
                    if self.isTranscribing && self.livePipelineIsDrained {
                        self.completeFinalText(self.currentSessionText)
                    }
                }
            }
        }, fallback: { [weak self] in
            guard let self, sessionID == self.activeSessionID else { return }
            insertRawAndAdvance()
        })
    }

    private func insertLiveChunk(_ text: String) {
        // Use a leading separator so chunks are space-separated, but never append a trailing
        // space here. The conditional trailing space (addTrailingSpace) is typed once at
        // finalization, so addTrailingSpace = false leaves no trailing space in the output.
        let needsSeparator = !currentSessionText.isEmpty
        if needsSeparator {
            currentSessionText += " "
        }
        currentSessionText += text
        streamingText = currentSessionText

        // Preview mode: capture into the overlay but DON'T paste yet. The whole
        // text is polished and pasted once at finalization (completeFinalText ->
        // insertCompletedText). Ordering/drain machinery still runs the chunk
        // through this single choke point, just without the side effect.
        guard !isPreviewSession else {
            statusMessage = "Previewing: \(text.prefix(40))..."
            return
        }

        // Agent sessions capture like preview: the chunk is accumulated above for
        // the bridge result and the overlay, but never typed into the frontmost app.
        guard !suppressOutput else { return }

        // Defensive privacy guard: skip the incremental paste if a secure field
        // became focused mid-session. The text stays captured in currentSessionText
        // for the overlay, but is never typed into a password field. Fail-open.
        guard !SecureFieldDetector.focusedFieldIsSecure() else {
            statusMessage = "Won't dictate into a password field"
            return
        }

        let insertion = needsSeparator ? " \(text)" : text
        textOutput.insert(
            insertion,
            mode: currentInsertionMode,
            restoreClipboard: restoreClipboard
        )
        statusMessage = "Inserted: \(text.prefix(40))..."
    }

    private func completeFinalText(_ text: String) {
        let finalText = postProcess(text, isFinalTranscript: true)

        // Self-learning dictionary (MAK-41), Part A: bump usageCount for exactly the
        // substitution rules that fired against this dictation, keyed on the RAW
        // pre-clean `text` — the string the vocabulary stage inside `postProcess`
        // actually matched `from` against. Keying on the POST-postProcess output
        // would be wrong: vocab has already rewritten `from`→`to`, so a normal
        // (from != to) rule could never match its own output. Recorded here, once
        // per final, before any refine/enhance/insert branch, so it counts even for
        // agent sessions and mid-refine finals (vocab ran on `text` in all of them).
        recordVocabularyUsage(inRawTranscript: text)

        // Rules engine (MAK-43), transcribe-complete hook: the transcript is now
        // locally cleaned but PRE-refine. Fire matching rules as a fail-open side
        // channel (never blocks/alters the insert below). Skipped on the empty/
        // mid-refine branches only incidentally — those don't produce a normal
        // insert either, and an empty `finalText` won't match a literal rule.
        if !finalText.isEmpty {
            fireRules(hook: .transcribeComplete, text: finalText)
        }

        // Mid-dictation refine: the user tapped Refine while holding Fn, so this
        // session's final splits into CONTENT (snapshot at the tap) + INSTRUCTION
        // (spoken after). Run the refine via RefineFlow.
        if let content = refineContentSnapshot {
            let fromSelection = refineContentFromSelection
            refineContentSnapshot = nil
            refineContentFromSelection = false
            let instruction = instructionSuffix(fullFinal: finalText, content: content)
            refineActiveInstruction = instruction
            refineDebug("completeFinalText MID-REFINE content=\"\(content.prefix(20))\" instr=\"\(instruction.prefix(20))\" fromSelection=\(fromSelection)")
            isTranscribing = true
            // Drive the machine: engage with the content as step-1, then feed the
            // instruction.
            executeRefineEffects(refineFlow.handle(.engage(step1: content, fromSelection: fromSelection)))
            executeRefineEffects(refineFlow.handle(.instructionFinalized(instruction)))
            return
        }

        guard !finalText.isEmpty else {
            isTranscribing = false
            sessionOutcome = .empty
            statusMessage = "No speech detected"
            finishSessionUI()
            return
        }

        lastTranscription = finalText
        streamingText = finalText

        // Run a whole-text OpenAI pass for finalOnly OR preview mode when
        // enhancement is enabled. Otherwise insert once. Agent sessions never
        // enhance — they return the raw transcript (the agent calls refine
        // explicitly), which also keeps bundled-LLM cold-start and the whisper-
        // server quiesce out of a live agent dictation.
        let enhanceWholeText = shouldEnhanceCurrentSession
            && !suppressOutput
            && (outputMode == "finalOnly" || outputMode == "preview")
        guard enhanceWholeText else {
            isTranscribing = false
            // Paste immediately — refine has its own dedicated key now, so there's
            // no re-press to disambiguate and no reason to hold the paste. Remember
            // the text so the Refine key can act on "what I just dictated" — but not
            // for agent sessions, which must not hijack the user's "last dictation".
            if !suppressOutput { rememberLastDictation(finalText) }
            insertCompletedText(finalText, originalText: finalText)
            return
        }

        statusMessage = openAIEnhancementMode == "rephrase" ? "Polishing..." : "Improving..."
        translationStatus = statusMessage
        // Capture the session so a cancel (Esc) or new session started while the
        // LLM call is in flight causes this callback to be ignored — otherwise
        // it would paste/clobber the clipboard after the session was cancelled.
        let sessionID = activeSessionID

        // Route the whole-text AI transform through the `AsyncTextRefiner` seam
        // (MAK-15) — the `AIPostProcessor` refiner — instead of calling
        // `translationService.processFinalText` directly. Behavior is byte-identical:
        // the seam wraps the same call, and the completion-style branches below
        // (empty-output and failure fallbacks, status/error/side-effects) are
        // UNCHANGED. Only the source of the transform moved to the composable seam.
        // The engine bracket, session guard, and status UI stay here because they
        // are lifecycle/UI concerns the pure chain doesn't model.
        ensureBundledLLMReady(quiesceWhisper: true, work: { [weak self] done in
            guard let self else { done(); return }
            // Build the refiner INSIDE work:, after the engine is ready — the
            // bundled provider re-picks its port per launch (MAK-28) and
            // `llmEndpoint` must be read AFTER `ensureRunning` reports healthy.
            // This matches the OLD code, which read endpoint/model here too.
            let refiner = self.makeWholeTextRefiner()
            let refineContext = PostProcessContext(
                language: self.outputLanguageForCleaning,
                targetBundleID: self.targetApplication?.bundleIdentifier,
                isLiveChunk: false
            )
            Task { @MainActor [weak self] in
                let result: Result<String, Error>
                do {
                    result = .success(try await refiner.refine(finalText, context: refineContext))
                } catch {
                    result = .failure(error)
                }
                // Close the engine's in-flight bracket on EVERY completion path
                // (including the guarded early returns below). Fires regardless of
                // whether self survived the await, matching the old completion.
                done()
                guard let self, sessionID == self.activeSessionID else { return }
                self.isTranscribing = false
                switch result {
                case .success(let processedText):
                    let cleaned = self.postProcess(processedText)
                    guard !cleaned.isEmpty else {
                        self.error = "The LLM returned empty text."
                        self.translationStatus = "Refinement failed"
                        self.openAIEnhancementEnabledForSession = false
                        self.insertCompletedText(finalText, originalText: finalText)
                        self.statusMessage = "Refinement failed; inserted local text"
                        return
                    }
                    // Language guard (fix): small cleanup models sometimes TRANSLATE
                    // the dictation into a DIFFERENT script even though the prompt
                    // says to keep the language — Russian → English, or (the fix here)
                    // English → Russian when the "Improve translation" target-language
                    // picker is stale. Reject that and keep the raw transcript — the
                    // same fail-open path used when the LLM errors. The guard runs even
                    // for the intended-translation modes (translateToEnglish /
                    // improveTranslation): `expectedCleanupScript` names the script
                    // those legitimately produce, so genuine translate-to-X passes
                    // while a drift into any OTHER script is still caught. Only the
                    // free-form instruction paths (spoken/agent/Mode) are exempt — this
                    // path is never the spoken-instruction refine (that returned early
                    // above) and agent sessions never enhance, so both are false here.
                    let expectedScript = RefineOutputGuard.expectedCleanupScript(
                        translateToEnglish: self.effectiveTranslateToEnglish,
                        mode: self.openAIEnhancementMode,
                        translationTargetLanguage: self.translationTargetLanguage
                    )
                    if RefineOutputGuard.shouldLanguageGuard(
                        isSpokenInstructionRefine: false,
                        isAgentBridgeRefine: false,
                        // A Mode's own instruction may legitimately translate (MAK-39);
                        // per-app presets (MAK-77) never exempt the guard.
                        hasCustomModeInstruction: self.modeRefineInstructionOverride != nil
                    ), RefineOutputGuard.outputTranslatedAway(
                        input: finalText, output: cleaned, expectedOutputScript: expectedScript
                    ) {
                        self.refineDebug("language guard REJECTED cleanup (looked translated); keeping raw transcript")
                        self.translationStatus = "Kept your language (cleanup translated)"
                        self.rememberLastDictation(finalText)
                        self.insertCompletedText(finalText, originalText: finalText)
                        return
                    }
                    self.translationStatus = self.openAIEnhancementMode == "rephrase" ? "Rephrased" : "Improved"
                    self.rememberLastDictation(cleaned)
                    self.insertCompletedText(cleaned, originalText: finalText)
                case .failure(let error):
                    self.error = "Post-processing failed: \(error.localizedDescription)"
                    self.translationStatus = "Refinement failed"
                    self.openAIEnhancementEnabledForSession = false
                    self.insertCompletedText(finalText, originalText: finalText)
                    self.statusMessage = "Refinement failed; inserted local text"
                }
            }
        }, fallback: { [weak self] in
            guard let self, sessionID == self.activeSessionID else { return }
            self.isTranscribing = false
            self.openAIEnhancementEnabledForSession = false
            self.insertCompletedText(finalText, originalText: finalText)
            self.statusMessage = "Built-in model unavailable; inserted local text"
        })
    }

    // MARK: - Instruction chaining (mid-dictation refine)
    //
    // Gesture: HOLD Fn and speak your content (normal dictation). Without releasing
    // Fn, TAP the Refine key — from that point, what you say is the INSTRUCTION, not
    // content. RELEASE Fn to apply: the instruction rewrites the content dictated
    // before the tap (or a selection / last dictation if there was no content yet).
    // One continuous hold — no separate recognizer session, no chord oscillation,
    // no timing race. RefineFlow still owns the apply/insert/failure logic.

    /// Record a completed normal dictation so a later refine (with no in-session
    /// content) can act on it.
    private func rememberLastDictation(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastDictationText = t.isEmpty ? nil : text
    }

    /// Refine key TAPPED mid-dictation (while Fn is still held). Snapshot what's
    /// been dictated so far as the content to refine; everything spoken from here on
    /// is the instruction. Applied when Fn is released (see completeFinalText).
    func armRefineMidSession() {
        guard InstructionChain.isAvailable(outputMode: outputMode, llmConfigured: llmConfigured, enabled: instructionChainEnabled) else {
            statusMessage = "Set up an AI provider to use Refine"
            return
        }
        guard refineContentSnapshot == nil else { return }   // already armed this session
        // Content to refine, in intent order: what's been dictated so far this
        // session, else the user's LIVE selection (an explicit selection is the
        // clearest statement of intent — it must beat the last dictation, which
        // can be arbitrarily stale), else the last dictation, else a selection
        // via the clipboard fallback. The AX read is safe to probe early (no
        // selection = nil); the clipboard fallback stays last because a
        // synthesized copy with nothing selected copies the current line in
        // some apps.
        let sofar = (currentSessionText.isEmpty ? streamingText : currentSessionText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secureField = SecureFieldDetector.focusedFieldIsSecure()
        let content: String
        let fromSelection: Bool
        if !sofar.isEmpty {
            content = sofar
            fromSelection = false
        } else if !secureField,
                  let sel = SelectionReader.readSelectedText(allowClipboardFallback: false)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !sel.isEmpty {
            content = sel
            fromSelection = true
        } else if let last = lastDictationText?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            content = last
            fromSelection = false
        } else if !secureField,
                  let sel = SelectionReader.readSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sel.isEmpty {
            content = sel
            fromSelection = true
        } else {
            statusMessage = "Nothing to refine yet — dictate first, then tap Refine"
            return
        }
        refineContentSnapshot = content
        refineContentFromSelection = fromSelection
        refineArmed = true                       // overlay refine cue
        statusMessage = "Refine: now speak your instruction…"
        refineDebug("armRefineMidSession content=\"\(content.prefix(30))\" fromSelection=\(fromSelection)")

        // An IDLE arm (no session running) has no visible UI — nothing changes
        // on screen until the next dictation. Expire it, so a stray tap can't
        // ambush a dictation minutes later as surprise refine mode.
        if !sessionActive {
            refineArmGeneration &+= 1
            let generation = refineArmGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.idleRefineArmTimeout * 1_000_000_000))
                guard let self,
                      generation == self.refineArmGeneration,
                      self.refineContentSnapshot != nil,
                      !self.sessionActive else { return }
                self.refineContentSnapshot = nil
                self.refineContentFromSelection = false
                self.syncRefineUI()
                self.statusMessage = "Ready"
                self.refineDebug("idle refine arm expired")
                // The delayed post-dictation hide skips while refineArmed (the arm
                // owns the overlay) — so when an idle arm expires with the overlay
                // still up (e.g. armed during the lingering revert hold, MAK-35),
                // dismiss it here or it stays orphaned until the next session.
                self.dismissOverlayIfSettled(after: 0)
            }
        }
    }

    /// See `InstructionChain.instructionSuffix` — shared with the overlay's live
    /// instruction row, so what the user sees is exactly what the model receives.
    private func instructionSuffix(fullFinal: String, content: String) -> String {
        InstructionChain.instructionSuffix(fullFinal: fullFinal, content: content)
    }

    /// Perform the state machine's effects. This is the ONLY place refine side
    /// effects happen, so the sequencing is in one auditable spot.
    private func executeRefineEffects(_ effects: [RefineFlow.Effect]) {
        syncRefineUI()
        for effect in effects {
            switch effect {
            case .startInstructionCapture:
                // No-op in the mid-dictation model: the instruction was captured
                // during the same Fn hold, so there's no separate session to start.
                // (Kept so RefineFlow stays trigger-agnostic.)
                refineDebug("effect: startInstructionCapture (no-op, mid-session)")

            case let .runLLM(step1, instruction):
                refineDebug("effect: runLLM step1=\"\(step1.prefix(20))\" instr=\"\(instruction.prefix(20))\"")
                applyRefineLLM(instruction: instruction, to: step1)

            case let .insert(text, replacingSelection):
                refineDebug("effect: insert replacingSelection=\(replacingSelection)")
                isTranscribing = false
                insertCompletedText(text, originalText: text)

            case let .finishQuietly(status):
                refineDebug("effect: finishQuietly \(status)")
                isTranscribing = false
                streamingText = ""
                currentSessionText = ""
                statusMessage = status
                finishSessionUI()

            case let .status(message):
                translationStatus = message
                statusMessage = message
            }
        }
        syncRefineUI()
    }

    /// Keep the published overlay cue in sync with the machine.
    private func syncRefineUI() {
        // Armed while a mid-session refine is pending (content snapshot taken) OR
        // the machine is applying.
        refineArmed = refineContentSnapshot != nil || refineFlow.isActive
        // The finalized instruction only matters while the rewrite is in flight.
        if !refineArmed { refineActiveInstruction = nil }
    }

    /// Run the refine LLM (apply `instruction` to `target`) and feed the result
    /// back into the machine. The machine already transitioned to `.applying`.
    private func applyRefineLLM(instruction: String, to target: String) {
        // Working cue while the LLM runs (can take seconds).
        isRecording = false
        isTranscribing = true
        streamingText = target
        statusMessage = "Refining…"
        translationStatus = statusMessage
        if showOverlay, !overlayIsVisible {
            overlayController?.show()
            overlayIsVisible = true
        }
        let sessionID = activeSessionID
        // Instruction + text labeled together in ONE user message with a
        // transform-only system prompt — keeps tiny models from answering/obeying
        // the text instead of rewriting it. See InstructionChain.
        let systemDirective = InstructionChain.systemDirective
        let userPayload = InstructionChain.userPayload(instruction: instruction, text: target)
        refineDebug("applyRefineLLM provider=\(llmProvider) sessionID=\(sessionID.uuidString.prefix(8))")

        ensureBundledLLMReady(statusWhileLoading: "Refining…", quiesceWhisper: true, work: { [weak self] done in
            guard let self else { done(); return }
            self.refineDebug("applyRefineLLM POST to \(self.llmEndpoint.baseURL) model=\"\(self.llmModel)\"")
            self.translationService.processFinalText(
                text: userPayload,
                mode: "rephrase",
                targetLanguage: self.translationTargetLanguage,
                endpoint: self.llmEndpoint,
                model: self.llmModel,
                customInstruction: systemDirective
            ) { [weak self] result in
                Task { @MainActor in
                    // Close the engine's in-flight bracket on EVERY completion path
                    // (including the guarded early returns below).
                    done()
                    guard let self else { return }
                    guard sessionID == self.activeSessionID else {
                        self.refineDebug("applyRefineLLM RESULT DROPPED: session changed")
                        // Don't leave the machine stuck in .applying — abort it.
                        self.executeRefineEffects(self.refineFlow.handle(.abort))
                        return
                    }
                    switch result {
                    case .success(let processedText):
                        self.refineDebug("applyRefineLLM SUCCESS raw=\"\(processedText.prefix(50))\"")
                        let cleaned = self.postProcess(processedText)
                        self.executeRefineEffects(self.refineFlow.handle(.llmSucceeded(cleaned)))
                    case .failure(let error):
                        self.refineDebug("applyRefineLLM FAILURE: \(error.localizedDescription)")
                        self.executeRefineEffects(self.refineFlow.handle(.llmFailed(error.localizedDescription)))
                    }
                }
            }
        }, fallback: { [weak self] in
            guard let self else { return }
            guard sessionID == self.activeSessionID else {
                self.executeRefineEffects(self.refineFlow.handle(.abort))
                return
            }
            // Built-in model unavailable: treat as a failed refine (inserts step-1).
            self.executeRefineEffects(self.refineFlow.handle(.llmFailed("built-in model unavailable")))
        })
    }

    private func insertCompletedText(_ text: String, originalText: String) {
        // Defensive privacy guard: even though we refuse at session start, a field
        // can become secure mid-session (or focus can shift to a password field
        // before the final paste). Never insert into, copy to the clipboard, or
        // persist a transcript when a secure field is now focused. Fail-open.
        guard !SecureFieldDetector.focusedFieldIsSecure() else {
            isTranscribing = false
            sessionOutcome = .secureField
            streamingText = ""
            currentSessionText = ""
            statusMessage = "Won't dictate into a password field"
            finishSessionUI()
            return
        }

        // Agent-initiated session: return the transcript to the caller instead of
        // pasting. Skip the script post-processor, the paste, and the clipboard
        // write — but still record history so history.list and the tray reflect it.
        // The result is delivered via onSessionEnd in finishSessionUI().
        if suppressOutput {
            // Agent sessions return the transcript to the caller — nothing is inserted
            // into a focused field, so no overlay in-place revert applies (the tracker
            // was reset in beginSession and no insert path below runs).
            streamingText = text
            sessionOutcome = .completed(text: text)
            // Agent sessions never enhance (text == originalText), so rawText resolves
            // to nil and no revert affordance appears — passed for consistency.
            recordHistory(text, rawText: originalText)
            recordStats(text)
            // Rules engine (MAK-43), llm-complete hook for agent sessions. Agent
            // sessions don't run the script post-processor or type into a field, so
            // `text` here is the final result the caller gets — fire rules over it.
            // Only rules that opted into agent sessions (RuleSessionMode) will match.
            fireRules(hook: .llmComplete, text: text)
            statusMessage = "Done"
            finishSessionUI(delay: 0.8)
            return
        }

        // Opt-in custom script post-processor: pipe the final text through the
        // user's executable (stdin -> stdout) as the last transform before
        // insertion. Bounded to ~2s and fail-open (any error/timeout/empty output
        // keeps the original), so a broken script can't break dictation.
        var text = text
        if scriptPostProcessorEnabled, !scriptPostProcessorPath.isEmpty {
            statusMessage = "Running script..."
            text = ScriptRunner.run(text, scriptPath: scriptPostProcessorPath)
        }

        streamingText = text

        // Decide purely from session SNAPSHOTS, never the live @Published
        // outputMode (which can change mid-session or after cancel). A session
        // pastes the whole text once iff it didn't paste incrementally:
        // finalOnly/legacy recording (isLiveChunkSession == false) or preview.
        // liveChunks already pasted per chunk, so it only needs a trailing space.
        let pastesWholeOnce = !isLiveChunkSession || isPreviewSession
        if pastesWholeOnce {
            let insertion = addTrailingSpace ? "\(text) " : text
            // Scratchpad (MAK-49): when our own floating pad is the frontmost key
            // window, the user is dictating INTO it with no other target. The
            // focused-app insert path can't serve this (its paste fallback
            // deliberately declines when OUR app is frontmost), so append straight
            // into the active note's model + text view instead. This is the
            // target-free capture the pad exists for; it never touches the
            // clipboard and always lands the text.
            if scratchpadController.appendDictationIfKey(text) {
                lastInsertedIntoFocusedApp = nil
            } else {
            // Output target (MAK-11..14): when the user has selected AND configured a
            // non-focused sink (file / Shortcut / webhook), route the FINAL text
            // there; otherwise keep the exact historical focused-app insert. Keeping
            // the default path a bare `textOutput.insert` (not wrapped in the router)
            // means the common case is byte-for-byte unchanged — no regression.
            let effectiveKind = OutputTargetResolver.effectiveKind(outputTargetSettings)
            if effectiveKind == .focusedApp {
                // The whole final text landed in the focused field — remember it so the
                // overlay revert can swap it in place for the raw words (MAK-35).
                lastInsertedIntoFocusedApp = text
                textOutput.insert(
                    insertion,
                    mode: currentInsertionMode,
                    restoreClipboard: restoreClipboard
                ) { [weak self] outcome in
                    guard let self else { return }
                    // If the insert couldn't be confirmed, the text was left on the
                    // clipboard — tell the user so it isn't silently lost. (Arrives after
                    // the success status below; overrides it only on fallback.)
                    if outcome == .copiedToClipboard {
                        self.showClipboardFallbackNotice()
                    } else {
                        // Confirmed insert: watch for a type-over-the-word correction
                        // (MAK-41 Part C). The watcher itself gates on AX-readable focus.
                        self.armCorrectionWatcherIfEligible(finalText: text)
                    }
                }
            } else {
                // A configured sink is selected. Build a fresh router (default =
                // focused-app insert that still surfaces the clipboard-fallback
                // notice) + the sink, and route the payload. On any sink failure the
                // router fails open to that same focused-app insert — matching the
                // never-drop-text guarantee. The sink receives the un-spaced text; a
                // trailing space belongs to the focused-app insert path only.
                // The text went to a sink, not the focused field — an in-place overlay
                // revert doesn't apply (the tracker stays nil from beginSession; router
                // fail-open to a focused-app insert is best-effort and the clipboard-copy
                // revert still covers it).
                let router = buildOutputRouter(effectiveKind: effectiveKind, focusedAppInsertion: insertion)
                let payload = OutputPayload(
                    text: text,
                    language: outputLanguageForCleaning,
                    targetAppBundleID: targetApplication?.bundleIdentifier,
                    isLiveChunk: false
                )
                router.route(payload) { _ in }
            }
            } // end: not routed to the Scratchpad
        } else if scratchpadController.appendDictationIfKey(text) {
            // Scratchpad (MAK-49) in liveChunks mode: the per-chunk live pastes all
            // fell back to the clipboard because OUR pad is frontmost (the focused-app
            // insert declines when OpenWhisp is key), so NOTHING landed in the note.
            // Route the WHOLE session text into the active note once here — the honest
            // completion-time fix for the data loss (per-chunk live typing into the pad
            // is out of scope). Skip the clipboard-only finish below entirely; the pad
            // owns the text and never touches the clipboard.
            lastInsertedIntoFocusedApp = nil
        } else {
            // liveChunks: the text was already pasted incrementally (no trailing space).
            // Type the single conditional trailing space now, honoring addTrailingSpace.
            if addTrailingSpace, !text.isEmpty {
                textOutput.insert(
                    " ",
                    mode: currentInsertionMode,
                    restoreClipboard: restoreClipboard
                )
            }
            // Route the final clipboard write through the same serial paste queue
            // so it stays FIFO-ordered behind any still-draining chunk pastes.
            // A direct main-thread NSPasteboard write here would race the async
            // paste queue and could clobber (or be clobbered by) a late chunk.
            textOutput.setClipboard(text)

            // Live-chunk sessions inserted incrementally via AX/paste; the field now
            // holds the whole dictation, so watch for a type-over correction too.
            armCorrectionWatcherIfEligible(finalText: text)
            // The whole dictation is in the focused field — the overlay revert can
            // swap it for the raw words in place (MAK-35).
            lastInsertedIntoFocusedApp = text
        }

        // The actually-inserted text is the canonical result — update lastTranscription
        // so the tray "copy" and history match what was pasted (the refined / enhanced
        // / script-processed text), not step-1's raw transcript.
        lastTranscription = text

        // Rules engine (MAK-43), llm-complete hook: `text` is the truly-final string
        // (post-refine, post-script) that was just dispatched to the insert path above.
        // Fire matching rules as a fail-open side channel AFTER the insert dispatch —
        // the runner is non-blocking and independent, so it never delays or alters the
        // insert, and it receives the exact same final text the user got. Dictation
        // (non-agent) sessions reach here.
        fireRules(hook: .llmComplete, text: text)

        // MAK-35: `originalText` is the pre-AI-cleanup transcript (the caller passes
        // step-1's local text). Persist it as the revert baseline so the user can
        // recover their exact words when the LLM changed them. recordHistory stores
        // it only when it actually differs from the inserted `text`.
        recordHistory(text, rawText: originalText)
        recordStats(text)

        let finalWasEnhanced = shouldEnhanceCurrentSession
            && (!isLiveChunkSession || isPreviewSession)
        statusMessage = finalWasEnhanced
            ? "Enhanced: \(text.prefix(50))..."
            : "Done: \(originalText.prefix(50))..."

        // Keep the overlay up longer when AI cleanup changed the words this session, so
        // the "revert to original" control (shown while `history.first.revertTarget !=
        // nil`) is actually clickable before the overlay fades (MAK-35). recordHistory
        // ran above, so history.first reflects THIS dictation.
        let revertAvailable = history.first?.revertTarget != nil
        finishSessionUI(delay: revertAvailable ? Self.revertOverlayHold : 0.8)
    }

    // MARK: - Output target routing (MAK-11..14)

    /// Build a fresh `OutputRouter` for a final delivery whose effective (configured)
    /// kind is a non-focused sink. The default target is a focused-app insert that
    /// mirrors the historical path — including the "couldn't insert — text is on the
    /// clipboard" notice — so a sink fail-open behaves exactly like a normal insert.
    ///
    /// - Parameters:
    ///   - effectiveKind: the already-resolved sink kind (never `.focusedApp` here;
    ///     the caller handles that case with the bare insert).
    ///   - focusedAppInsertion: the exact string the focused-app path would insert
    ///     (i.e. `text` plus any trailing space), used by the default/fallback target.
    private func buildOutputRouter(effectiveKind: OutputTargetKind, focusedAppInsertion: String) -> OutputRouter {
        let defaultTarget = FocusedAppInsertTarget(
            insertion: focusedAppInsertion,
            mode: currentInsertionMode,
            restoreClipboard: restoreClipboard,
            insert: { [weak self] insertion, mode, restore, completion in
                self?.textOutput.insert(insertion, mode: mode, restoreClipboard: restore) { outcome in
                    if outcome == .copiedToClipboard { self?.showClipboardFallbackNotice() }
                    completion()
                }
            }
        )

        var sinks: [OutputTarget] = []
        switch effectiveKind {
        case .focusedApp:
            break   // handled by the caller; nothing extra to register.
        case .file:
            sinks.append(FileOutputTarget(config: outputTargetSettings.file))
        case .webhook:
            sinks.append(WebhookOutputTarget(config: outputTargetSettings.webhook))
        case .shortcut:
            sinks.append(ShortcutOutputTarget(shortcutName: outputTargetSettings.shortcutName))
        }

        // Global selection (v1): apply the effective kind to whatever app is
        // frontmost so the router keys on the current bundle. (`nil` bundle → the
        // router resolves to the default focused-app insert, which is fine.)
        let selections: [OutputTargetSelection]
        if let bundleID = targetApplication?.bundleIdentifier {
            selections = [OutputTargetSelection(appBundleID: bundleID, kind: effectiveKind)]
        } else {
            selections = []
        }
        return OutputRouter(defaultTarget: defaultTarget, targets: sinks, selections: selections)
    }

    // MARK: - Output target persistence

    /// Persist the whole output-target settings blob as JSON under one key.
    private func persistOutputTargetSettings() {
        guard let data = try? JSONEncoder().encode(outputTargetSettings) else { return }
        settingsStore.set(data, forKey: "outputTargetSettings")
    }

    /// Load the persisted output-target settings, defaulting to focused-app (today's
    /// behavior) when absent or unreadable.
    private static func loadOutputTargetSettings() -> OutputTargetSettings {
        // Static (called during init before `self.settingsStore` is assigned), so
        // it reads UserDefaults.standard directly rather than the injected seam.
        guard let data = UserDefaults.standard.data(forKey: "outputTargetSettings"),
              let decoded = try? JSONDecoder().decode(OutputTargetSettings.self, from: data)
        else { return OutputTargetSettings() }
        return decoded
    }

    // MARK: - Rules engine (MAK-43)

    /// The app-side runner that executes planned rule actions over the existing
    /// delivery layer. Lazy so it's built once; `insertSnippet` adapts the runner to
    /// the same `TextOutput` insert seam the normal path uses.
    private lazy var ruleEngineRunner: RuleEngineRunner = RuleEngineRunner(
        insertSnippet: { [weak self] snippet in
            guard let self else { return }
            self.textOutput.insert(
                snippet, mode: self.currentInsertionMode, restoreClipboard: self.restoreClipboard
            )
        }
    )

    /// Fire the rules engine for one lifecycle `hook` over `text`, as a fail-open
    /// SIDE CHANNEL: hand the rule set + context to the runner, which plans (pure,
    /// can't throw) and executes off-thread, best-effort. This NEVER changes, delays, or breaks
    /// the normal transcript insert — the caller has already dispatched that. A
    /// no-op when no rules exist, so the common case costs a single array check.
    ///
    /// The agent-session gate lives in the planner (`RuleSessionMode`): a rule only
    /// fires on a `suppressOutput` (agent) session if it explicitly opted in.
    private func fireRules(hook: RuleHook, text: String) {
        guard !ruleSet.rules.isEmpty else { return }
        let context = RuleContext(
            hook: hook,
            text: text,
            appBundleID: targetApplication?.bundleIdentifier,
            isAgentSession: suppressOutput
        )
        let payload = OutputPayload(
            text: text,
            language: outputLanguageForCleaning,
            targetAppBundleID: targetApplication?.bundleIdentifier,
            isLiveChunk: false
        )
        // Planning happens on the runner's queue, not here: matching can evaluate a
        // user-supplied regex, and even the matcher's backtracking time budget must
        // never be spent on the finalize path. `ruleSet` is a value type — the
        // runner gets an immutable snapshot.
        ruleEngineRunner.planAndRun(rules: ruleSet, context: context, payload: payload)
    }

    /// Instance method (called only from `screenContext`'s didSet, where `self`
    /// exists) so its write routes through the injected `settingsStore` seam.
    private func persistScreenContext(_ settings: ScreenContextSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        settingsStore.set(data, forKey: "screenContextSettings")
    }

    /// Load the persisted screen-context config, defaulting to OFF (opt-in) when
    /// absent or unreadable. Static (init-time), so it reads UserDefaults.standard
    /// directly rather than the injected seam.
    private static func loadScreenContext() -> ScreenContextSettings {
        guard let data = UserDefaults.standard.data(forKey: "screenContextSettings"),
              let decoded = try? JSONDecoder().decode(ScreenContextSettings.self, from: data)
        else { return ScreenContextSettings.default }
        return decoded
    }

    /// Capture screen context for the session that is starting, applying the full
    /// `ScreenContextGate` (opt-in, per-app allowlist, secure-field guard,
    /// local-provider-only for LLM context). Reads the focused field via AX ONLY
    /// when the gate permits it; nothing is persisted. Called from `startDictation`
    /// AFTER the secure-field refusal guard and target-app resolution.
    private func captureScreenContext() {
        sessionScreenContext = nil

        // NEVER capture for an agent-initiated session: its transcript is returned
        // to the agent raw, and a whisper prompt can echo (hallucinate) prompt
        // tokens into the output — screen text harvested as bias terms could
        // otherwise leak to the agent through the transcript. Screen context is a
        // user-session-only feature.
        guard !sessionInitiator.isAgent else { return }

        let decision = ScreenContextGate.decide(
            settings: screenContext,
            bundleID: currentTextTargetApplication()?.bundleIdentifier,
            focusedFieldIsSecure: SecureFieldDetector.focusedFieldIsSecure(),
            refineEnhancementEnabled: openAIEnhancementEnabled,
            refineProvider: llmProvider
        )
        guard decision.readsField else { return }

        // A single AX read serves both uses (bias terms + LLM context).
        guard let fieldText = ScreenContextReader.readFocusedFieldText() else { return }

        var biasTerms: [String] = []
        if decision.harvestBiasTerms {
            biasTerms = ScreenContextHarvester.harvest(
                from: fieldText,
                existingTerms: customVocabularyEnabled ? vocabulary.terms : [],
                limit: screenContext.maxBiasTerms
            )
        }
        var llmContext: String?
        if decision.provideLLMContext {
            llmContext = ScreenContextTruncator.prepareContext(
                from: fieldText, maxChars: screenContext.maxContextChars
            )
        }
        if biasTerms.isEmpty && llmContext == nil { return }
        sessionScreenContext = SessionScreenContext(biasTerms: biasTerms, llmContext: llmContext)
    }

    /// The whisper initial-prompt string for the current session: the user's custom
    /// vocabulary prompt plus any bias terms harvested from screen context this
    /// session. Empty when neither applies. Bias terms never leave the machine —
    /// they only prime the on-device transcription engine.
    private var effectiveWhisperPrompt: String {
        let base = customVocabularyEnabled ? vocabulary.whisperPrompt : ""
        let extra = sessionScreenContext?.biasTerms ?? []
        guard !extra.isEmpty else { return base }
        let extraJoined = extra.joined(separator: ", ")
        return base.isEmpty ? extraJoined : "\(base), \(extraJoined)"
    }

    /// Local transcript cleanup. Delegates to TranscriptCleaner (in OpenWhispCore)
    /// Surface the "couldn't insert — text is on the clipboard" fallback: set the
    /// status, keep/show the overlay with the cue, and auto-clear after a few seconds.
    private func showClipboardFallbackNotice() {
        statusMessage = "Couldn't insert — copied, press ⌘V"
        clipboardFallbackActive = true
        if showOverlay {
            if !overlayIsVisible {
                overlayController?.show()
                overlayIsVisible = true
            }
        }
        let token = UUID()
        clipboardFallbackToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // Only clear if a newer notice/session hasn't superseded this one.
            guard self.clipboardFallbackToken == token else { return }
            self.clipboardFallbackActive = false
            // Don't hide a NEW session's overlay while it's still arming
            // (isRecording flips true only after the async grant + engine start), and
            // keep it up while a "revert to original" is still offered so that
            // affordance stays reachable (MAK-35) — the revert flow dismisses it.
            let revertOffered = self.history.first?.revertTarget != nil
            if !self.isRecording && !self.isTranscribing && !self.sessionActive
                && !self.isArming && !revertOffered {
                self.hideOverlayNow()
            }
        }
    }
    private var clipboardFallbackToken: UUID?

    /// — the OS-independent post-processing pipeline — built from current settings.
    /// `isFinalTranscript` enables the trailing meta-instruction strip (only on the
    /// whole final utterance, never per chunk or on already-LLM-processed output).
    private func postProcess(_ text: String, isFinalTranscript: Bool = false) -> String {
        let cleaner = TranscriptCleaner(config: transcriptCleanerConfig)
        // Self-learning dictionary (MAK-41 Part A): record which rules fire HERE,
        // against this call's raw input, unioned across the session. Live-chunk
        // sessions apply vocabulary per CHUNK and accumulate the substituted text,
        // so by finalization the `from` phrases are gone — the firing decision has
        // to be captured at each clean call, not re-derived from the final text.
        // Set-union keeps "once per dictation" semantics across chunks/re-cleans;
        // consumed once by recordVocabularyUsage, cleared at session start.
        sessionFiredSubstitutionIDs.formUnion(cleaner.firedSubstitutionIDs(inRawTranscript: text))
        return cleaner.clean(text, isFinalTranscript: isFinalTranscript)
    }

    /// Substitution rules that fired against any raw text this session post-
    /// processed (per-chunk and final). See `postProcess`; consume-once via
    /// `recordVocabularyUsage`, cleared at session start.
    private var sessionFiredSubstitutionIDs: Set<Vocabulary.Substitution.ID> = []

    /// Snapshot of the formatting/vocabulary settings the cleaner needs, built on
    /// each call so toggles take effect immediately.
    private var transcriptCleanerConfig: TranscriptCleaner.Config {
        TranscriptCleaner.Config(
            language: outputLanguageForCleaning,
            customVocabularyEnabled: customVocabularyEnabled,
            substitutions: vocabulary.substitutions,
            smartFormattingEnabled: smartFormattingEnabled,
            fillerRemovalEnabled: fillerRemovalEnabled,
            spokenPunctuationEnabled: spokenPunctuationEnabled,
            normalizeNumbers: normalizeNumbers,
            normalizeCurrency: normalizeCurrency,
            spokenListsEnabled: spokenListsEnabled,
            basicMarkdownEnabled: basicMarkdownEnabled,
            fileTaggingEnabled: fileTaggingIsActive
        )
    }

    /// Self-learning dictionary (MAK-41), Part A: bump `usageCount` for the
    /// substitution rules that fired against `rawTranscript`, and persist. `rawTranscript`
    /// MUST be the pre-clean transcript the vocabulary stage matched `from` against
    /// — NOT the post-`postProcess` text, in which `from` has already been rewritten
    /// to `to` so a normal (from != to) rule could never match its own output. The
    /// firing decision is the SAME whole-phrase, case-insensitive match the pipeline
    /// uses (`VocabularySubstitutor.firedSubstitutionIDs`), so a rule is counted iff
    /// it actually rewrote text; multiple hits of one rule count once (set
    /// semantics). Gated on the feature being on. The persist is debounced off the
    /// main actor (see `scheduleVocabularySave`) so the paste hot path doesn't do a
    /// synchronous atomic disk write every dictation.
    private func recordVocabularyUsage(inRawTranscript rawTranscript: String) {
        guard customVocabularyEnabled, !vocabulary.substitutions.isEmpty else { return }
        // Union of (a) rules firing against the text handed to completeFinalText —
        // raw for the plain finalOnly path — and (b) the session stash captured in
        // `postProcess` per clean call. (b) is what makes live-chunk and Apple
        // Speech sessions count: there the accumulated/final text is already
        // substituted, so (a) alone would fire on nothing. Consume-once.
        var fired = VocabularySubstitutor(substitutions: vocabulary.substitutions)
            .firedSubstitutionIDs(in: rawTranscript)
        fired.formUnion(sessionFiredSubstitutionIDs)
        sessionFiredSubstitutionIDs = []
        guard !fired.isEmpty else { return }
        // The `vocabulary` didSet coalesces the disk write (scheduleVocabularySave),
        // so this main-actor assignment updates the live "used N×"/sort immediately
        // but doesn't do a synchronous atomic write on the paste hot path.
        vocabulary = vocabulary.incrementingUsage(of: fired)
    }

    /// Coalesce vocabulary persistence: (re)start a short debounce timer whose fire
    /// writes the CURRENT `vocabulary` once, off the main thread. Rapid dictations
    /// (each bumping a usage count) collapse into one write instead of one atomic
    /// JSON encode + temp-file rename per paste; an explicit edit (star toggle, add
    /// rule) still persists within the window. The write is dispatched to a background
    /// queue — `VocabularyStore.save` is a value-type snapshot, so ordering is
    /// preserved by the serial queue and there's no shared-state race.
    private func scheduleVocabularySave() {
        vocabularySaveTimer?.invalidate()
        let snapshot = vocabulary
        vocabularySaveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
            Self.vocabularySaveQueue.async { VocabularyStore.save(snapshot) }
        }
    }

    /// Serial queue for the (debounced) vocabulary disk write, so coalesced saves
    /// stay strictly ordered and never block the main actor.
    private static let vocabularySaveQueue = DispatchQueue(label: "com.openwhisp.app.vocab-save")

    /// Flush any pending debounced vocabulary write immediately (e.g. app teardown /
    /// reset), so an in-flight bump isn't lost if the process exits before the timer.
    private func flushVocabularySave() {
        guard vocabularySaveTimer?.isValid == true else { return }
        vocabularySaveTimer?.invalidate()
        vocabularySaveTimer = nil
        let snapshot = vocabulary
        Self.vocabularySaveQueue.async { VocabularyStore.save(snapshot) }
    }

    // MARK: - Self-learning dictionary: correction capture (MAK-41 Part C)

    /// Arm the AX correction watcher after a confirmed insert, if the feature is on.
    /// The watcher itself is the second gate — it only captures when the same
    /// AX-readable element is still focused a moment later and the user made a clean
    /// single-word edit. On such an edit `handleObservedCorrection` runs the pair
    /// through the conservative learner and, if it survives, queues a PROPOSAL (never
    /// an auto-applied rule). We deliberately don't try to distinguish an AX-path
    /// insert from a paste fallback here — the watcher reads the field value back and
    /// simply captures nothing when the value isn't AX-readable.
    private func armCorrectionWatcherIfEligible(finalText: String) {
        guard correctionLearningEnabled, customVocabularyEnabled else { return }
        guard !suppressOutput else { return }   // agent sessions don't type into a field
        correctionWatcher.arm(insertedText: finalText) { [weak self] inserted, surviving in
            self?.handleObservedCorrection(inserted: inserted, surviving: surviving)
        }
    }

    /// A captured (inserted, surviving) single-word edit: run it through the learner
    /// + proposal state. Adds a user-facing proposal iff it's an unambiguous
    /// correction that isn't already a rule / pending / previously declined. NEVER
    /// mutates the dictionary here — acceptance is an explicit user action.
    private func handleObservedCorrection(inserted: String, surviving: String) {
        let (newState, added) = correctionProposals.considering(
            inserted: inserted,
            surviving: surviving,
            existingSubstitutions: vocabulary.substitutions
        )
        guard added != nil else { return }
        correctionProposals = newState   // didSet persists
    }

    /// Accept a pending correction proposal: fold it into the real vocabulary (so it
    /// rewrites future transcripts) and dequeue it. Called from the editor.
    func acceptCorrectionProposal(_ id: CorrectionProposal.ID) {
        let (newState, accepted) = correctionProposals.accepting(id)
        guard let accepted else { return }
        correctionProposals = newState
        // Don't duplicate an identical rule if one somehow already exists.
        let key = CorrectionProposal.key(from: accepted.from, to: accepted.to)
        let exists = vocabulary.substitutions.contains {
            CorrectionProposal.key(from: $0.from, to: $0.to) == key
        }
        if !exists {
            // Route through the stamping helper so the accepted rule carries a
            // fresh updatedAt (a user action edits the vocabulary → LWW must see it).
            vocabulary = vocabulary.addingSubstitution(accepted)
        }
    }

    /// Reject a pending correction proposal: dequeue it and remember not to re-offer
    /// the same fix. Does not touch the dictionary.
    func rejectCorrectionProposal(_ id: CorrectionProposal.ID) {
        correctionProposals = correctionProposals.rejecting(id)
    }

    /// File-tagging (MAK-48) fires ONLY when the user opted in AND the app being
    /// dictated into is a known AI-native editor (Cursor/Windsurf). `targetApplication`
    /// is captured at session start (the frontmost app at record time), so this
    /// reflects where the text will actually land — a spoken "@main.ts" would be
    /// wrong in a Slack message or a doc. The editor decision lives in a pure,
    /// tested helper so `swift test` covers the bundle-id set.
    private var fileTaggingIsActive: Bool {
        guard fileTaggingEnabled else { return false }
        return FileTagTransform.appliesTo(bundleID: targetApplication?.bundleIdentifier)
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.recordingStartedAt else { return }
                self.recordingElapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func finishSessionUI(delay: TimeInterval = 0) {
        sessionActive = false
        pendingStop = false
        // MAK-40: this is the single terminal site for every session path, so any
        // staged retention WAV that recordHistory did NOT consume (secure-field
        // guard, error, cancel, empty result) is discarded here — a password-field
        // dictation's audio must never linger in staging. Successful sessions
        // consumed it in recordHistory before reaching this point, so it's a no-op
        // for them.
        discardStagedRetainedAudio()
        // Never let a spoken question run past the session — if it's still being
        // read when capture finalizes (short question, fast answer), cut it so the
        // app isn't talking over the user or into the next session.
        agentAnnouncer.stopSpeaking()
        // A refine armed mid-session that never reached completeFinalText (error
        // terminations: engine onError, recorder .error, empty-WAV, final-kind
        // failure) must not leak into the next dictation — a stale snapshot would
        // hijack it, treating the new speech as an instruction on the old content.
        // Normal refines consumed the snapshot before getting here, so this is
        // a no-op for them.
        if refineContentSnapshot != nil {
            refineContentSnapshot = nil
            syncRefineUI()
        }
        // Never leave the overlay stuck in the "starting" arming cue once a session
        // ends (capture may never have gone live — denied permission, abort, error).
        isArming = false
        // Restore any per-app profile overrides immediately (independent of the
        // overlay-hide delay) so the next session sees the user's real globals.
        restoreProfileOverridesIfNeeded()
        // Clear session snapshots so they're only ever true while a session is
        // genuinely active (prevents a stale flag from being read by a late
        // callback or the delayed overlay-hide between sessions).
        isLiveChunkSession = false
        isPreviewSession = false
        isStreamingSession = false
        // MAK-34: drop the captured screen context at every session terminal, not
        // just cancel — stale context from app A must never survive into anything
        // that runs between sessions or into a later session in app B.
        sessionScreenContext = nil
        voiceEditingActiveForSession = false
        voiceEditBuffer = VoiceEditBuffer()
        // Deliver the outcome to an agent-initiated waiter exactly once. This is
        // the single terminal site for every session path (success, empty, secure
        // field, cancel, error) — abortSessionBeforeStart() also ends here — so one
        // fire covers them all. Then reset the agent-session fields so they can
        // never leak into the next (user) session.
        if let deliver = onSessionEnd {
            onSessionEnd = nil
            deliver(sessionOutcome ?? .cancelled)
        }
        sessionInitiator = .user
        suppressOutput = false
        sessionOutcome = nil
        agentDictatePrompt = nil
        agentDictateClientLabel = nil
        agentDictateQuestion = nil
        agentDictateReadingQuestion = false
        agentSilenceDetector = nil
        agentEouDetector = nil
        // Clear the hands-free lock state and its safety detector, and return the
        // interaction machine to idle — a session ending off-trigger (silence
        // safety, agent preempt, error) would otherwise leave the machine thinking
        // a lock is still open, so the next tap would stop-instead-of-start.
        dictationLocked = false
        lockSafetyDetector = nil
        // …but NOT while a preempt-replacement start is queued: there the machine's
        // current state (mid-press or locked open) describes the user's NEW session,
        // and wiping it would swallow the upcoming release — in hold mode the
        // preempt-started mic would then never stop on release. See
        // DictationSessionLifecycle.shouldResetActivation for the invariant (and the
        // ordering requirement that the preempt path sets the flag BEFORE cancelling).
        if DictationSessionLifecycle.shouldResetActivation(pendingPreemptStart: pendingPreemptStart) {
            hotkeyMonitor?.resetActivation()
        }
        agentDictateTimeoutTask?.cancel()
        agentDictateTimeoutTask = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
        targetApplication = nil
        audioLevel = 0

        // Hide whenever the overlay is up — NOT gated on the showOverlay setting:
        // agent sessions force-show it regardless of that setting, and gating the
        // hide symmetrically would leave it stuck on screen for overlay-off users.
        guard overlayIsVisible else { return }
        if delay > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // Also check sessionActive/isArming: a new session started during
                // the delay is "arming" (isRecording still false) and its overlay
                // must not be hidden by this stale task. Likewise leave the overlay up
                // if a refine was armed on it or a clipboard-fallback cue is showing —
                // both actively own the overlay and dismiss it themselves. (The longer
                // hold used when a revert is offered widens the window these can occur.)
                if !self.isRecording && !self.isTranscribing && !self.sessionActive
                    && !self.isArming && !self.refineArmed && !self.clipboardFallbackActive {
                    self.hideOverlayNow()
                }
            }
        } else {
            hideOverlayNow()
        }
    }

    private func hideOverlayNow() {
        guard overlayIsVisible else { return }
        overlayController?.hide()
        overlayIsVisible = false
    }

    // MARK: - Permissions

    var microphonePermissionLabel: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Granted"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    var speechPermissionLabel: String {
        switch AppleSpeechEngine.authorizationStatus {
        case .authorized: return "Granted"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    var accessibilityPermissionLabel: String {
        AXIsProcessTrusted() ? "Granted" : "Needs permission"
    }

    /// LIVE Input-Monitoring authorization, read on demand via the IOKit HID
    /// preflight (`IOHIDCheckAccess` for ListenEvent). Unlike `inputMonitoringGranted`
    /// — which is only *inferred* after the hotkey CGEventTap has been attempted —
    /// this can be queried before any hotkey fires, so onboarding can tell the user
    /// their push-to-talk key is dead BEFORE the "try it" step (MAK-24).
    var liveInputMonitoringStatus: OnboardingHotkeyGate.InputMonitoringStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied:  return .denied
        default:                      return .unknown // includes kIOHIDAccessTypeUnknown
        }
    }

    var runningBundlePath: String {
        Bundle.main.bundlePath
    }

    var whisperLogPath: String {
        WhisperEngine.logFileURL().path
    }

    func retryHotkeyMonitor() {
        hotkeyMonitor.stop()
        hotkeyMonitor.start()
    }

    // MARK: - Onboarding helpers

    /// Request microphone access (no-op if already decided). Calls `completion`
    /// on the main actor with the resulting granted state.
    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                self.objectWillChange.send()
                completion(granted)
            }
        }
    }

    /// Nudge SwiftUI to re-read the permission-label computed properties (they
    /// reflect live system state, not stored @Published values).
    func refreshPermissionLabels() {
        objectWillChange.send()
    }

    // MARK: - Launch-time permission recheck

    /// Re-evaluate the live permission state and update the missing-permission
    /// banners. Called on launch and every time the app becomes active, so the
    /// banner appears when a reinstall revoked Accessibility and auto-clears the
    /// moment the user grants it in System Settings and returns.
    func refreshPermissionBanners() {
        let banners = permissionBannerPolicy.visibleBanners(
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: inputMonitoringGranted
        )
        if banners != missingPermissionBanners {
            missingPermissionBanners = banners
        }
        // The Settings permission rows read live computed labels; nudge them too.
        refreshPermissionLabels()
    }

    /// Hide a banner for the rest of the session. Granting the permission later
    /// re-arms it (see PermissionBannerPolicy), so a future revocation resurfaces.
    func dismissPermissionBanner(_ permission: PermissionBannerPolicy.Permission) {
        permissionBannerPolicy.dismiss(permission)
        refreshPermissionBanners()
    }

    /// Deep link into the exact System Settings pane for a banner's permission.
    func openSettings(for permission: PermissionBannerPolicy.Permission) {
        switch permission {
        case .accessibility:
            // Also trigger the system prompt so OpenWhisp appears pre-listed
            // in the Accessibility pane the user is about to see.
            requestAccessibilityPermission()
            openAccessibilitySettings()
        case .inputMonitoring:
            openInputMonitoringSettings()
        }
    }

    func finishOnboarding() {
        didCompleteOnboarding = true
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealRunningApp() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: runningBundlePath)])
    }

    func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSpeechRecognitionPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Reset

    /// Reset every preference to its factory default and clear the JSON stores
    /// (profiles, vocabulary, history). Keeps the Keychain API key, downloaded
    /// models, onboarding completion, and the settings-migration version — the
    /// goal is a known-good configuration, not a factory-wipe reinstall.
    func resetAllSettings() {
        // Order matters in two places: AI cleanup goes off before the provider
        // flips to "bundled" (so the didSet doesn't start a model download),
        // and modelName is set after the engine (didSet re-resolves modelPath).
        // Factory default: AI cleanup off (dial = .none), and reset the "restore on
        // re-enable" memory so a later toggle-on lands on the standard default tier.
        cleanupIntensity = .none
        lastNonNoneCleanupIntensity = .default
        llmProvider = "bundled"
        openAIEnhancementMode = "rephrase"
        translationTargetLanguage = "en"
        openAIModel = "gpt-4o-mini"
        localLLMBaseURL = "http://localhost:8080/v1"
        localLLMModel = ""
        bundledLLMModel = "qwen2.5-0.5b-instruct"
        agentCLIPreset = "claude"
        agentCLICustomCommand = ""
        agentCLICustomArgsText = ""
        agentCLITimeout = 30.0
        instructionChainEnabled = true
        voiceEditingEnabled = true

        triggerMode = "fn"
        customTriggerKeyCode = -1
        customTriggerModifiers = 0
        hotkeyMode = "hold"
        handsFreeSilenceAutoStop = true
        refineKey = RefineKey.defaultKey.rawValue
        mouseTrigger = MouseTrigger.defaultTrigger.id
        microphoneID = ""
        autoGainEnabled = true
        quietDictationEnabled = false
        language = "auto"
        translateToEnglish = false

        transcriptionEngine = Self.defaultTranscriptionEngine
        whisperKitModel = "openai_whisper-small"
        modelName = "base"
        parakeetVariant = ParakeetCatalog.defaultVariantID
        whisperBinaryPath = Self.preferredWhisperCLIPath(savedPath: "")
        whisperBackend = "serverAPI"
        liveChunkDuration = 2.0
        pauseBasedLiveChunksEnabled = false

        // MAK-53 summarization override — back to "same as cleanup" defaults.
        summaryLLMProvider = SettingsResetDefaults.summaryLLMProvider
        summaryLLMModel = SettingsResetDefaults.summaryLLMModel
        summaryLLMEndpoint = SettingsResetDefaults.summaryLLMEndpoint

        outputMode = "preview"
        insertionMode = "auto"
        restoreClipboard = true
        addTrailingSpace = false
        scriptPostProcessorEnabled = false
        scriptPostProcessorPath = ""
        outputTargetSettings = OutputTargetSettings()   // back to focused-app default

        showOverlay = true
        voiceIndicatorStyle = .defaultStyle
        smartFormattingEnabled = true
        spokenPunctuationEnabled = true
        fillerRemovalEnabled = true
        // Advanced formatting toggles (init defaults, see SettingsResetDefaults):
        // these were previously missed, so "reset to defaults" left them on whatever
        // the user had set.
        normalizeNumbers = SettingsResetDefaults.normalizeNumbers
        normalizeCurrency = SettingsResetDefaults.normalizeCurrency
        spokenListsEnabled = SettingsResetDefaults.spokenListsEnabled
        basicMarkdownEnabled = SettingsResetDefaults.basicMarkdownEnabled
        fileTaggingEnabled = false
        customVocabularyEnabled = true
        correctionLearningEnabled = true
        perAppModesEnabled = false
        historyEnabled = true

        // Agent Bridge (M8) — back to init defaults. The agentBridgeEnabled didSet
        // stops the server when it flips to false.
        agentBridgeEnabled = SettingsResetDefaults.agentBridgeEnabled
        agentBridgeAllowUnsignedClients = SettingsResetDefaults.agentBridgeAllowUnsignedClients
        agentBridgeAllowCloudAI = SettingsResetDefaults.agentBridgeAllowCloudAI
        agentBridgeSilenceAutoStop = SettingsResetDefaults.agentBridgeSilenceAutoStop
        agentBridgeEouAutoStop = SettingsResetDefaults.agentBridgeEouAutoStop
        agentBridgeChimeEnabled = SettingsResetDefaults.agentBridgeChimeEnabled
        agentBridgeSpeakQuestionEnabled = SettingsResetDefaults.agentBridgeSpeakQuestionEnabled

        // Screen context (MAK-34) — strictly-opt-in default.
        screenContext = ScreenContextSettings.default

        // Raw-audio retention (MAK-40) — opt-in off, newest-50 policy default.
        retainRawAudioEnabled = SettingsResetDefaults.retainRawAudioEnabled
        audioRetentionDays = SettingsResetDefaults.audioRetentionDays
        audioRetentionMaxClips = SettingsResetDefaults.audioRetentionMaxClips

        // Rules (MAK-43) and Modes (MAK-39) — clear back to empty.
        ruleSet = .empty
        modes = []

        vocabulary = .empty
        flushVocabularySave()   // reset must persist the cleared vocab promptly
        correctionProposals = .empty
        profiles = []
        clearHistory()

        engineSwitchNotice = nil
        error = nil
        translationStatus = "Not configured"
    }

    /// Whether the GGML model for `name` is already downloaded at its default
    /// Application Support location. Drives the Settings model rows' state.
    func isWhisperModelInstalled(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: Self.applicationSupportModelsDirectory()
                .appendingPathComponent(Self.modelFileName(for: name))
                .path
        )
    }

    private func currentTextTargetApplication() -> NSRunningApplication? {
        let ownBundleID = Bundle.main.bundleIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != ownBundleID, frontmost?.activationPolicy == .regular {
            return frontmost
        }

        return nil
    }

    // MARK: - Modes (per-app + first-class, MAK-39)

    /// Select a Mode by its invocation key, from the `openwhisp://` URL scheme or
    /// the Settings picker. Returns false (and changes nothing) when no Mode owns
    /// the key, so the caller can report an honest miss.
    ///
    /// - `sticky == true`  → `activate-mode`: set the sticky `activeModeKey`; the
    ///   Mode governs subsequent dictations until changed. No recording starts.
    /// - `sticky == false` → `switch-mode`: queue the Mode for the NEXT dictation
    ///   only (`pendingModeKey`), consumed when it starts.
    @discardableResult
    func selectMode(key: String, sticky: Bool) -> Bool {
        guard let mode = ModeResolver.mode(forKey: key, in: modes) else { return false }
        if sticky {
            activeModeKey = mode.key
        } else {
            pendingModeKey = mode.key
        }
        return true
    }

    /// Clear any sticky/queued Mode selection, reverting to global settings +
    /// app auto-activation for future dictations (the picker's "None" choice).
    func clearActiveMode() {
        activeModeKey = nil
        pendingModeKey = nil
    }


    /// Resolve and apply the Mode governing this dictation, temporarily overriding
    /// the session-scoped globals (language / output / AI cleanup) and setting the
    /// Mode's refine instruction, backing up originals for restore at session end.
    ///
    /// Precedence (via `ModeResolver.resolveActive`):
    ///   1. `pendingModeKey` — a `switch-mode` queued for THIS dictation (consumed).
    ///   2. `activeModeKey` — a sticky `activate-mode`/picker selection.
    ///   3. app auto-activation — a Mode bound to the frontmost app (only when
    ///      `perAppModesEnabled`).
    ///
    /// An explicit Mode (1 or 2) applies even when per-app modes is off — the user
    /// asked for it by name. Keeps the historic method name so the call site in
    /// `startDictation` is untouched.
    private func applyProfileForFrontmostApp() {
        guard profileOverrideBackup == nil else { return }
        let frontmost = currentTextTargetApplication()

        // Agent-initiated sessions (agent-dictate) must NOT consume or apply the
        // user's explicit Mode selection: a `switch-mode` the user queued for
        // THEIR next dictation would otherwise be silently eaten (and applied) by
        // an agent asking a question in between. Agents get only the pre-Mode
        // behavior: app auto-activation via the per-app toggle.
        let explicitKey: String?
        if sessionInitiator.isAgent {
            explicitKey = nil
        } else {
            // A pending (switch-mode) key is one-shot: consume it now regardless of
            // whether it resolves, so a stale key can't stick to future dictations.
            explicitKey = pendingModeKey ?? activeModeKey
            if pendingModeKey != nil { pendingModeKey = nil }
        }

        let mode = ModeResolver.resolveActive(
            explicitKey: explicitKey,
            frontmostBundleID: frontmost?.bundleIdentifier,
            perAppModesEnabled: perAppModesEnabled,
            modes: modes
        )

        // MAK-77: per-app refine preset (Profiles rows + terminal/IDE verbatim default).
        let presetOutcome = RefinePresetResolver.resolve(
            profile: AppProfileStore.profile(for: frontmost?.bundleIdentifier, in: profiles),
            frontmostBundleID: frontmost?.bundleIdentifier,
            perAppProfilesEnabled: perAppModesEnabled,
            globalIntensity: cleanupIntensity
        )

        guard mode != nil || presetOutcome != .inherit else { return }

        // Back up the overridable globals.
        profileOverrideBackup = (language: language, translateToEnglish: translateToEnglish,
                                 outputMode: outputMode, aiCleanup: openAIEnhancementEnabled)
        suppressSettingsPersistence = true

        if let mode {
            // Same pure resolver as per-app profiles (see ModeResolver.resolveSession).
            let resolved = ModeResolver.resolveSession(mode: mode, over: .init(
                language: language, translateToEnglish: translateToEnglish,
                outputMode: outputMode, aiCleanupEnabled: openAIEnhancementEnabled,
                insertionMode: insertionMode
            ))
            language = resolved.language
            translateToEnglish = resolved.translateToEnglish
            outputMode = resolved.outputMode
            openAIEnhancementEnabled = resolved.aiCleanupEnabled

            // The tone + free-form instruction the Mode contributes to the refine pass,
            // plus an optional LLM-model override.
            modeRefineInstructionOverride = ModeResolver.refineInstruction(for: mode)
            activeModeLLMModel = mode.llmModel

            // The insert method is session-scoped, not a persisted published setting —
            // stash it for currentInsertionMode; only when the profile actually changes
            // it from the global (else stay nil so nothing to restore).
            let resolvedInsert = InsertionMode.from(id: resolved.insertionMode)
            sessionInsertionModeOverride = resolvedInsert.rawValue == insertionMode ? nil : resolvedInsert
        }

        // Preset applies after the Mode; the pure helper encodes the tie-breaks.
        let presetApply = RefinePresetResolver.application(
            outcome: presetOutcome, modePinsCleanupOn: mode?.aiCleanupEnabled == true)
        if presetApply.disableRefine { openAIEnhancementEnabled = false }
        presetRefineInstructionOverride = presetApply.presetPrompt
    }

    /// Restore any settings a profile overrode for the just-finished session.
    private func restoreProfileOverridesIfNeeded() {
        modeRefineInstructionOverride = nil
        presetRefineInstructionOverride = nil
        activeModeLLMModel = nil
        sessionInsertionModeOverride = nil
        guard let backup = profileOverrideBackup else { return }
        profileOverrideBackup = nil
        // Re-enable persistence so restoring the originals writes them back.
        suppressSettingsPersistence = false
        if language != backup.language { language = backup.language }
        if translateToEnglish != backup.translateToEnglish { translateToEnglish = backup.translateToEnglish }
        if outputMode != backup.outputMode { outputMode = backup.outputMode }
        if openAIEnhancementEnabled != backup.aiCleanup { openAIEnhancementEnabled = backup.aiCleanup }
        // Originals were already in UserDefaults from before the override; the
        // assignments above re-persist them anyway. Belt-and-suspenders: ensure
        // they reflect the true globals.
        settingsStore.set(language, forKey: "language")
        settingsStore.set(translateToEnglish, forKey: "translateToEnglish")
        settingsStore.set(outputMode, forKey: "outputMode")
        // AI cleanup is now stored via the intensity dial (MAK-35), so persist THAT
        // key — the legacy on/off boolean is a derived facade with no backing store.
        settingsStore.set(cleanupIntensity.rawValue, forKey: "cleanupIntensity")
    }

    // MARK: - History

    /// Record a completed transcription (newest first), trimming to the cap.
    ///
    /// `rawText` (MAK-35) is the transcript BEFORE the whole-text AI cleanup pass —
    /// the local-cleaned words the user actually said. Passing it lets the history
    /// "revert to original" affordance recover those words when the LLM changed
    /// them. It is stored only when it MEANINGFULLY differs from the inserted
    /// `text`; when nothing was refined (raw == final) we store nil so
    /// `revertTarget` correctly hides the affordance (a revert would be a no-op).
    private func recordHistory(_ text: String, rawText: String? = nil) {
        // MAK-40: on ANY early return the staged retained WAV must be discarded so it
        // can't leak into the next entry. Take it here; the success path below moves
        // it into place, and `defer` deletes any staging file left unused.
        let staged = takeStagedRetainedAudio()
        defer { if let staged, FileManager.default.fileExists(atPath: staged.path) { try? FileManager.default.removeItem(at: staged) } }
        guard historyEnabled else { return }
        // Defensive privacy guard: never persist a transcript if a secure field is
        // focused at record time. Fail-open on detection errors.
        guard !SecureFieldDetector.focusedFieldIsSecure() else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Only keep a raw baseline that differs from the final text (trimmed on both
        // sides, matching how the final is stored) — otherwise it's redundant.
        let rawTrimmed = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedRaw: String? = {
            guard let rawTrimmed, !rawTrimmed.isEmpty, rawTrimmed != trimmed else { return nil }
            return rawTrimmed
        }()
        let entryID = UUID()
        // MAK-40: move the staged WAV into the retained-audio dir under the entry's
        // canonical name. The `defer` above cleans up the staging file if this
        // doesn't consume it (retention off, or move fails).
        var audioFileName: String? = nil
        if retainRawAudioEnabled, let staged, FileManager.default.fileExists(atPath: staged.path) {
            audioFileName = AudioRetentionManager.adopt(stagedWAV: staged, entryID: entryID)
        }
        let entry = TranscriptionEntry(
            id: entryID,
            text: trimmed,
            date: Date(),
            appBundleID: targetApplication?.bundleIdentifier,
            appName: targetApplication?.localizedName,
            rawText: storedRaw,
            audioFileName: audioFileName
        )
        history.insert(entry, at: 0)
        if history.count > TranscriptionHistoryStore.maxEntries {
            // Evict overflow entries — and delete any retained audio they carried,
            // so the audio directory can't outgrow the history it's keyed to.
            let overflow = history.suffix(from: TranscriptionHistoryStore.maxEntries)
            for e in overflow {
                if let name = e.audioFileName { AudioRetentionManager.deleteAudio(fileName: name) }
            }
            history = Array(history.prefix(TranscriptionHistoryStore.maxEntries))
        }
        TranscriptionHistoryStore.save(history)
        applyRetentionPolicy()
    }

    func clearHistory() {
        history = []
        TranscriptionHistoryStore.save(history)
        // Manual "Clear" wipes the audio too — the clips are only useful attached to
        // a history entry. Only files matching the retained-audio scheme are removed.
        AudioRetentionManager.deleteAllAudio()
    }

    // MARK: - Raw-audio retention (MAK-40)

    /// Absolute URL of a history entry's retained audio, if it currently exists on
    /// disk. Used by the PrivacyPane "re-transcribe" affordance to gate itself.
    func retainedAudioURL(for entry: TranscriptionEntry) -> URL? {
        guard let name = entry.audioFileName, AudioRetentionManager.audioExists(fileName: name) else { return nil }
        return RetainedAudioStore.url(for: name)
    }

    /// Re-run a history entry's stored audio through the CURRENT transcription engine
    /// and replace the entry's text with the new result — keeping the old text as the
    /// revert baseline (rawText) so the user can undo, reusing the MAK-35 plumbing.
    ///
    /// Reuses the `FileTranscriptionEngine.transcribe` seam exactly like a live
    /// dictation: a fresh engine instance, wired to a one-shot completion that patches
    /// the matching history entry. Best-effort — a failure surfaces via `error` and
    /// leaves the entry unchanged.
    func reTranscribeHistoryEntry(_ entry: TranscriptionEntry) {
        guard let url = retainedAudioURL(for: entry) else {
            error = "No stored audio for this entry to re-transcribe."
            return
        }
        // One at a time: overwriting the strong ref would deallocate the in-flight
        // engine mid-transcription (undefined subprocess/callback lifetime) and its
        // result would be silently dropped.
        guard reTranscribeEngine == nil else {
            statusMessage = "Re-transcribe already running..."
            return
        }
        statusMessage = "Re-transcribing..."
        let engine = Self.makeFileEngine(for: transcriptionEngine, model: modelName, whisperKitModel: whisperKitModel)
        // Hold a strong ref until the callback fires (the local would otherwise
        // deallocate immediately). Cleared inside the callbacks.
        reTranscribeEngine = engine
        let requestID = UUID()
        engine.onTranscriptionComplete = { [weak self] rid, text in
            Task { @MainActor in
                guard let self, rid == requestID else { return }
                self.reTranscribeEngine = nil
                self.applyReTranscription(text, to: entry.id)
                self.statusMessage = "Ready"
            }
        }
        engine.onTranscriptionError = { [weak self] rid, msg in
            Task { @MainActor in
                guard let self, rid == requestID else { return }
                self.reTranscribeEngine = nil
                self.error = "Re-transcribe failed: \(msg)"
                self.statusMessage = "Ready"
            }
        }
        engine.transcribe(
            requestID: requestID,
            binaryPath: whisperBinaryPath,
            modelPath: modelPath,
            language: engineLanguageSetting,
            wavPath: url.path,
            deleteWhenDone: false, // NEVER delete the retained clip — it's the user's kept audio
            backend: whisperBackend == "serverAPI" ? .serverAPI : .cli,
            prompt: customVocabularyEnabled ? vocabulary.whisperPrompt : ""
        )
    }

    /// Patch a history entry with a re-transcription result. The previous text
    /// becomes the entry's `rawText` (revert target) when it actually differs, so the
    /// MAK-35 revert affordance restores the pre-re-transcribe words.
    private func applyReTranscription(_ newText: String, to entryID: UUID) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = history.firstIndex(where: { $0.id == entryID }) else { return }
        history[idx] = history[idx].reTranscribed(withNewText: trimmed)
        TranscriptionHistoryStore.save(history)
        textOutput.setClipboard(trimmed)
    }

    /// Evaluate the retention policy over the current history and execute any sweep
    /// it dictates: drop expired entries (age cap) and prune surplus audio (count
    /// cap). Pure decision in `AudioRetentionPolicy`; this just applies it. No-op
    /// when retention is off (the policy returns an empty sweep).
    func applyRetentionPolicy(now: Date = Date()) {
        let settings = AudioRetentionSettings(
            enabled: retainRawAudioEnabled,
            maxAgeDays: audioRetentionDays,
            maxEntries: audioRetentionMaxClips
        )
        let candidates = history.map {
            AudioRetentionPolicy.Candidate(id: $0.id, date: $0.date, hasAudio: $0.audioFileName != nil)
        }
        let sweep = AudioRetentionPolicy.evaluate(candidates: candidates, settings: settings, now: now)
        guard !sweep.isEmpty else { return }

        // Delete audio files first (both count-cap prunes and age-cap drops).
        for e in history where sweep.audioToDelete.contains(e.id) {
            if let name = e.audioFileName { AudioRetentionManager.deleteAudio(fileName: name) }
        }
        // Rebuild history: remove age-cap entries entirely; clear the audio filename
        // on entries whose clip was pruned (count cap) so the row stays but shows no
        // re-transcribe affordance.
        history = history.compactMap { e in
            if sweep.entriesToDelete.contains(e.id) { return nil }
            if sweep.audioToDelete.contains(e.id) {
                return TranscriptionEntry(
                    id: e.id, text: e.text, date: e.date,
                    appBundleID: e.appBundleID, appName: e.appName,
                    rawText: e.rawText, audioFileName: nil
                )
            }
            return e
        }
        TranscriptionHistoryStore.save(history)
    }

    /// Stage a COPY of a just-finished whole-session WAV for retention, made before
    /// the engine deletes the original. No-op when retention is off. Replaces any
    /// prior un-consumed staging file (a session that never recorded history).
    private func stageRetainedAudio(from wav: URL) {
        if let old = pendingRetainWAVPath, FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.removeItem(at: old)
        }
        pendingRetainWAVPath = nil
        guard retainRawAudioEnabled else { return }
        pendingRetainWAVPath = AudioRetentionManager.stageCopy(of: wav)
    }

    /// Consume and clear the staged retained-audio path (nil if none). The caller is
    /// then responsible for moving it into place or deleting it.
    private func takeStagedRetainedAudio() -> URL? {
        defer { pendingRetainWAVPath = nil }
        return pendingRetainWAVPath
    }

    /// Delete any un-consumed staged retention WAV and clear the pointer. Called
    /// from finishSessionUI() so sessions that never record history (secure field,
    /// error, cancel) can't leave their audio behind in the staging directory.
    private func discardStagedRetainedAudio() {
        guard let staged = takeStagedRetainedAudio() else { return }
        if FileManager.default.fileExists(atPath: staged.path) {
            try? FileManager.default.removeItem(at: staged)
        }
    }

    /// Delete every retained clip and clear all entries' audio filenames (called when
    /// the user turns retention OFF). History text rows are kept.
    private func purgeAllRetainedAudio() {
        AudioRetentionManager.deleteAllAudio()
        var changed = false
        history = history.map { e in
            guard e.audioFileName != nil else { return e }
            changed = true
            return TranscriptionEntry(
                id: e.id, text: e.text, date: e.date,
                appBundleID: e.appBundleID, appName: e.appName,
                rawText: e.rawText, audioFileName: nil
            )
        }
        if changed { TranscriptionHistoryStore.save(history) }
    }

    /// Fold a completed dictation into the local-only stats aggregates. METADATA
    /// ONLY — no transcript text is stored, only counts/durations/identifiers — and
    /// the file never leaves the device. Independent of `historyEnabled` (this is
    /// privacy-safe metadata), but still skips secure-field sessions, fully-empty
    /// transcripts, and sessions with no known start time.
    private func recordStats(_ text: String) {
        guard !SecureFieldDetector.focusedFieldIsSecure() else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let startedAt = recordingStartedAt else { return }

        let now = Date()
        let model: String? = switch transcriptionEngine {
        case "whisperKit":  whisperKitModel
        case "parakeet":    parakeetVariant
        case "appleSpeech": nil
        case "speechAnalyzer": nil
        default:            modelName
        }
        let latency = transcriptionStartedAt.map { now.timeIntervalSince($0) }

        let event = DictationEvent(
            date: now,
            wordCount: DictationEvent.words(in: trimmed),
            charCount: trimmed.count,
            durationSeconds: now.timeIntervalSince(startedAt),
            engine: transcriptionEngine,
            model: model,
            outputMode: outputMode,
            appBundleID: targetApplication?.bundleIdentifier,
            transcriptionLatencySeconds: latency
        )
        dictationStats.record(event)
        DictationStatsStore.save(dictationStats)

        // MAK-25: count only genuine USER dictations toward the first-run hint
        // window — never agent sessions or refine passes (those aren't the user
        // discovering dictation, and hints are suppressed during them anyway).
        // Stop bumping once past the window so the persisted counter can't overflow.
        if !sessionInitiator.isAgent, !refineArmed,
           hintSessionCount <= HintRotation.sessionsToShow {
            hintSessionCount += 1
        }
        #if OPENWHISP_INSTRUMENTATION
        lastDictationEvent = event
        #endif
    }

    // MARK: - Insights (MAK-38)

    /// Derive the local Usage Insights summary from the in-memory metadata
    /// aggregates. Pure computation over `dictationStats` (already the live copy,
    /// mutated on every completed dictation) — nothing here leaves the device.
    ///
    /// App bundle ids are mapped to readable names using currently-running apps
    /// (best source) with a fallback to the last app name seen in local history,
    /// then to a prettified bundle id inside `InsightsSummary` itself.
    var insightsSummary: InsightsSummary {
        InsightsSummary(
            stats: dictationStats,
            today: DictationStats.dayKey(for: Date()),
            appName: { [weak self] bundleID in self?.displayName(forBundleID: bundleID) },
            engineName: { InsightsSummary.prettifyEngine($0) }
        )
    }

    /// Best-effort human name for a bundle id, using running apps then history.
    private func displayName(forBundleID bundleID: String) -> String? {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        })?.localizedName {
            return running
        }
        return history.first(where: {
            $0.appBundleID == bundleID && ($0.appName?.isEmpty == false)
        })?.appName
    }

    func copyHistoryEntry(_ entry: TranscriptionEntry) {
        textOutput.setClipboard(entry.text)
    }

    /// MAK-35: one-click "revert to original" for a history entry whose AI-cleanup
    /// pass changed the words. Replaces the entry's stored `text` with its
    /// `revertTarget` (the raw pre-cleanup transcript), copies those words to the
    /// clipboard so the user can immediately re-paste them, and persists the change.
    /// No-op when `revertTarget == nil` (nothing was refined, or already reverted).
    /// Returns the reverted text so callers/tests can act on it.
    @discardableResult
    func revertHistoryEntry(_ entry: TranscriptionEntry) -> String? {
        guard let raw = entry.revertTarget,
              let idx = history.firstIndex(where: { $0.id == entry.id }) else { return nil }
        // Rewrite in place: the reverted text becomes the entry's `text`, and its
        // rawText is cleared so `revertTarget` now hides the affordance (you can't
        // revert twice — the words are already the originals).
        let old = history[idx]
        history[idx] = TranscriptionEntry(
            id: old.id,
            text: raw,
            date: old.date,
            appBundleID: old.appBundleID,
            appName: old.appName,
            rawText: nil
        )
        TranscriptionHistoryStore.save(history)
        // Put the original words on the clipboard so the user can paste them right
        // away — matching how copyHistoryEntry works. Deliberately does NOT touch
        // `lastTranscription`: that tracks the LIVE session's last output (used by
        // the tray "copy last" / "refine last"), not an arbitrary historical entry —
        // reverting a history row must not repoint those at the reverted words.
        textOutput.setClipboard(raw)
        return raw
    }

    /// MAK-35 (overlay): one-click "revert to original" surfaced in the post-dictation
    /// overlay, so the user can restore their raw pre-AI-cleanup words the instant a
    /// dictation lands — without opening Settings › Privacy.
    ///
    /// Reverts the MOST-RECENT history entry via `revertHistoryEntry` (which swaps the
    /// stored text back to the raw words, copies them to the clipboard, and hides the
    /// affordance so it can't run twice). Because the overlay fires right after the
    /// paste, it ALSO attempts the higher-value action the History revert can't: an
    /// in-place swap of the just-inserted text for the raw words in the focused field.
    /// That swap is best-effort and self-gating (it only touches the field when it
    /// still ends with exactly what we inserted); on any miss the clipboard copy from
    /// `revertHistoryEntry` remains the fallback (⌘V restores the originals) — with the
    /// ⌘V cue shown. On SUCCESS the clipboard is put back to what it held before, since
    /// the field already carries the raw words and the copy was unnecessary.
    ///
    /// No-op when the newest entry has nothing to revert (`revertTarget == nil`).
    /// Returns the raw text when a revert happened, else nil.
    @discardableResult
    func revertLastDictation() -> String? {
        guard let entry = history.first, entry.revertTarget != nil else { return nil }

        // Cancel the type-over correction watcher armed at insert BEFORE mutating the
        // field: the in-place swap would otherwise look like a user correction and the
        // learner would propose an inverted (cleaned→raw) dictionary rule (MAK-41).
        correctionWatcher.cancel()

        // Snapshot the clipboard so a successful in-place swap can restore it — the raw
        // words only need to live on the clipboard when the swap couldn't place them.
        let clipboardBefore = NSPasteboard.general.string(forType: .string)
        guard let raw = revertHistoryEntry(entry) else { return nil }

        // Try to replace the words already sitting in the focused field. Consume the
        // tracker first so a second tap (or a mis-fire) can't run the swap again — the
        // history entry is already reverted, and the raw words are on the clipboard.
        if let inserted = lastInsertedIntoFocusedApp {
            lastInsertedIntoFocusedApp = nil
            textOutput.replaceLastInsertion(inserted: inserted, raw: raw) { [weak self] replaced in
                guard let self else { return }
                if replaced {
                    // The field now holds the raw words — the clipboard copy was
                    // unnecessary, so restore what the user had (never clobber it).
                    if let clipboardBefore { self.textOutput.setClipboard(clipboardBefore) }
                    self.dismissOverlayIfSettled(after: 0.9)
                } else {
                    // The in-place swap didn't take (user moved focus, non-AX field, …)
                    // — the raw words are on the clipboard from revertHistoryEntry, so
                    // surface the same "press ⌘V" cue the insert-fallback path uses (it
                    // owns the overlay's lifetime from here).
                    self.showClipboardFallbackNotice()
                }
            }
        } else {
            // No in-place target (last output went to a sink, or nothing was inserted):
            // the raw words are on the clipboard; leave the ⌘V cue and let it dismiss.
            showClipboardFallbackNotice()
        }
        return raw
    }

    /// Hide the overlay after `delay`, but only if it's still settled (no session
    /// started, no refine armed, no clipboard-fallback cue owning it). Used by the
    /// overlay revert so the lingering post-dictation overlay dismisses once the revert
    /// has done its job, without fighting the clipboard-fallback notice's own lifetime.
    private func dismissOverlayIfSettled(after delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !self.isRecording, !self.isTranscribing, !self.sessionActive,
                  !self.isArming, !self.refineArmed, !self.clipboardFallbackActive else { return }
            self.hideOverlayNow()
        }
    }

    // MARK: - Config import / export

    /// Snapshot the user-editable config (profiles, vocabulary) as a portable
    /// bundle. History and secrets are intentionally excluded.
    func exportConfig() -> ConfigBundle {
        ConfigBundle(
            profiles: profiles,
            modes: modes,
            vocabulary: vocabulary
        )
    }

    /// Apply the sections present in `bundle` to the live settings (each setter's
    /// didSet persists it). Sections absent from the bundle are left untouched, so
    /// a vocab-only pack only changes vocabulary. Returns the bundle's summary for
    /// user feedback.
    @discardableResult
    func applyConfig(_ bundle: ConfigBundle) -> String {
        // A user importing a config or applying a pack IS a user edit, so entries
        // from a pre-v3 source (bundled packs are schemaVersion 1 with fixed ids;
        // any v2 export) — which decode to the epoch sentinel — get restamped now.
        // Otherwise the just-imported data would silently lose the next sync's
        // last-writer-wins to a stamped peer copy of the same id and revert.
        // Genuinely stamped v3 imports keep their real timestamps.
        let now = Date()
        if let importedProfiles = bundle.profiles {
            profiles = importedProfiles.restampingUnstamped(now: now)
        }
        if let importedModes = bundle.modes {
            modes = importedModes.restampingUnstamped(now: now)
        }
        if let importedVocab = bundle.vocabulary {
            vocabulary = importedVocab.restampingUnstamped(now: now)
        }
        return bundle.summary
    }

    /// Write the current config to `url` as JSON. Throws on encode/write failure.
    func exportConfig(to url: URL) throws {
        let data = try exportConfig().jsonData()
        try data.write(to: url, options: .atomic)
    }

    /// Read, validate, and apply a config bundle from `url`. Throws
    /// `ConfigBundle.DecodeError` on malformed/too-new data. Returns the summary.
    @discardableResult
    func importConfig(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let bundle = try ConfigBundle.decode(from: data)
        return applyConfig(bundle)
    }

    /// Built-in config packs shipped in the app bundle (Resources/packs/*.json).
    /// Parsing/sorting/dedup is done by the pure `ConfigPack.parseAll`; this just
    /// reads the directory. Bad/too-new pack files are skipped, not fatal.
    func bundledConfigPacks() -> [ConfigPack] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("packs", isDirectory: true),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        let files: [(name: String, data: Data)] = names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
                return (name, data)
            }
        return ConfigPack.parseAll(files)
    }

    /// Apply a pack's bundle (same path as a hand-imported file). Returns the summary.
    @discardableResult
    func applyPack(_ pack: ConfigPack) -> String {
        applyConfig(pack.bundle)
    }

    // MARK: - Model

    func availableModelsList() -> [(name: String, label: String, size: String)] {
        if let models = bundledModelManifest(), !models.isEmpty {
            return models.map { ($0.id, $0.label, $0.size) }
        }

        return [
            ("tiny",           "Tiny - fastest, lowest quality", "39 MB"),
            ("tiny.en",        "Tiny English - fastest English", "39 MB"),
            ("base",           "Base - fast default", "147 MB"),
            ("base.en",        "Base English - better English default", "147 MB"),
            ("small",          "Small - better quality", "464 MB"),
            ("small.en",       "Small English - recommended quality", "464 MB"),
            ("medium",         "Medium - high quality", "1.5 GB"),
            ("medium.en",      "Medium English - high quality English", "1.5 GB"),
            ("large-v3-turbo", "Large v3 Turbo - best speed/quality", "1.5 GB"),
            ("large-v3",       "Large v3 - best quality, slowest", "2.9 GB")
        ]
    }

    /// Provision the model for the CURRENTLY SELECTED engine — and only that engine.
    /// Called on launch. Previously launch always ran `ensureModelExists()`, which
    /// downloads a whisper.cpp `.bin` regardless of engine; with WhisperKit as the
    /// default that fetched the WRONG model (whisper.cpp) while the actual engine's
    /// CoreML model was never staged, so a fresh install felt broken. Route by engine
    /// so we download exactly what's in use (nothing for Apple Speech).
    func ensureSelectedEngineModel() {
        switch transcriptionEngine {
        case "whisperKit":
            // Stage the selected WhisperKit CoreML model if it isn't already present.
            // downloadWhisperKitModel is single-flight and warms the engine after.
            guard !WhisperKitModelCatalog.isStaged(whisperKitModel) else {
                warmWhisperServerIfPossible()
                return
            }
            downloadWhisperKitModel(whisperKitModel)
        case "appleSpeech":
            // Uses the built-in macOS dictation model — nothing to download.
            return
        case "speechAnalyzer":
            // SpeechAnalyzer provisions its locale model via AssetInventory on
            // first use; warm it now (via the file engine) so the asset install
            // happens at engine-select time, not mid-first-dictation. No-op on
            // macOS < 26.
            warmWhisperServerIfPossible()
            return
        case "parakeet":
            // FluidAudio stages models itself (HuggingFace → Application
            // Support/FluidAudio). Kick the download now so it happens at
            // engine-select time, not mid-first-dictation.
            prefetchParakeetVariant()
            return
        default:
            // whisper.cpp: download its GGML model (the original behavior, now scoped
            // to when whisper.cpp is actually the selected engine).
            ensureModelExists()
        }
    }

    func ensureModelExists() {
        guard !FileManager.default.fileExists(atPath: modelPath) else {
            modelDownloadStatus = "Installed: \(URL(fileURLWithPath: modelPath).lastPathComponent)"
            isModelDownloading = false
            modelDownloadFailed = false
            modelDownloadProgress = nil
            warmWhisperServerIfPossible()
            return
        }

        guard !inFlightModelDownloads.contains(modelPath) else { return }
        let fileName = URL(fileURLWithPath: modelPath).lastPathComponent
        let currentModelPath = modelPath
        inFlightModelDownloads.insert(currentModelPath)
        isModelDownloading = true
        modelDownloadFailed = false
        modelDownloadProgress = nil
        modelDownloadStatus = "Downloading \(fileName)..."
        statusMessage = "Downloading model..."

        Task {
            do {
                let url = Self.modelDownloadURL(modelID: modelName, fileName: fileName)
                let dest = URL(fileURLWithPath: currentModelPath)
                try dest.deletingLastPathComponent().createDirectories()
                try await downloadModelWithProgress(from: url, to: dest, fileName: fileName)
                await MainActor.run {
                    self.inFlightModelDownloads.remove(currentModelPath)
                    // A superseded download (the user switched models mid-flight)
                    // must not clobber the selected model's download UI state.
                    guard currentModelPath == self.modelPath else { return }
                    self.isModelDownloading = false
                    self.modelDownloadProgress = 1.0
                    self.modelDownloadFailed = false
                    self.modelDownloadStatus = "Installed: \(fileName)"
                    if self.statusMessage == "Downloading model..." {
                        self.statusMessage = "Ready"
                    }
                    self.warmWhisperServerIfPossible()
                }
            } catch {
                await MainActor.run {
                    self.inFlightModelDownloads.remove(currentModelPath)
                    guard currentModelPath == self.modelPath else { return }
                    self.isModelDownloading = false
                    self.modelDownloadProgress = nil
                    self.modelDownloadFailed = true
                    self.modelDownloadStatus = "Download failed: \(fileName)"
                    self.error = "Model download failed: \(error.localizedDescription)\nPath: \(currentModelPath)"
                    if self.statusMessage == "Downloading model..." {
                        self.statusMessage = "Error"
                    }
                }
            }
        }
    }

    /// Re-attempt a model download after a failure. Clears any prior error state
    /// and restarts the flow (a failed download already removed itself from
    /// `inFlightModelDownloads`, so ensureModelExists can start fresh).
    func retryModelDownload() {
        guard !isModelDownloading else { return }
        modelDownloadFailed = false
        error = nil
        ensureModelExists()
    }

    /// Receives progress updates from `ModelDownloader` on the main actor and
    /// publishes a fraction + human-readable status string.
    fileprivate func updateModelDownloadProgress(written: Int64, totalExpected: Int64) {
        guard isModelDownloading else { return }
        let progress = DownloadProgressFormatter.make(written: written, totalExpected: totalExpected)
        modelDownloadProgress = progress.fraction
        modelDownloadStatus = progress.label
    }

    func revealModelsFolder() {
        let directory = URL(fileURLWithPath: modelPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func downloadModelWithProgress(from url: URL, to destination: URL, fileName: String) async throws {
        let tempURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).download")
        try? FileManager.default.removeItem(at: tempURL)
        let downloadedURL = try await ModelDownloader.download(from: url) { [weak self] written, totalExpected in
            Task { @MainActor in
                guard let self, self.modelPath == destination.path else { return }
                self.updateModelDownloadProgress(written: written, totalExpected: totalExpected)
            }
        }
        // whisper.cpp GGML files start with the magic "lmgg" (0x67676d6c LE).
        try Self.validateModelMagic(at: downloadedURL, expected: ["lmgg"], fileName: fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloadedURL, to: tempURL)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Reject a downloaded payload that isn't the expected model format before it
    /// is installed. Catches error/captive-portal pages served with HTTP 200 (a
    /// status check alone misses those): once a bogus file sits at the model path,
    /// ensure*ModelExists treats it as installed forever and every transcription
    /// fails with no in-app recovery.
    private static func validateModelMagic(at url: URL, expected: [String], fileName: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        let magics = expected.compactMap { $0.data(using: .ascii) }
        guard magics.contains(head) else {
            throw ModelDownloadError(message: "Downloaded \(fileName) is not a valid model file (server may have returned an error page)")
        }
    }

    private static func modelDownloadURL(modelID: String, fileName: String) -> URL {
        if let entry = bundledModelManifest()?.first(where: { $0.id == modelID }),
           let url = URL(string: entry.url) {
            return url
        }

        return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    private func bundledModelManifest() -> [ModelManifestEntry]? {
        Self.bundledModelManifest()
    }

    private static func bundledModelManifest() -> [ModelManifestEntry]? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("models/manifest.json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode([ModelManifestEntry].self, from: data)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Notification

    private func showNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req)
    }
}

struct ModelManifestEntry: Decodable {
    let id: String
    let file: String
    let label: String
    let size: String
    let url: String
    /// Present in the LLM manifest (llm-manifest.json); absent in the whisper one.
    let license: String?
}

struct ModelDownloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    /// Called as bytes arrive with (totalBytesWritten, totalBytesExpectedToWrite).
    /// `totalBytesExpectedToWrite` is `NSURLSessionTransferSizeUnknown` (-1) when
    /// the server does not advertise a Content-Length.
    private var progressHandler: ((Int64, Int64) -> Void)?

    static func download(from url: URL, progress: ((Int64, Int64) -> Void)? = nil) async throws -> URL {
        let downloader = ModelDownloader()
        return try await downloader.download(from: url, progress: progress)
    }

    private func download(from url: URL, progress: ((Int64, Int64) -> Void)?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.progressHandler = progress
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.waitsForConnectivity = true
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progressHandler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession delivers this for ANY completed transfer, including 404/403/5xx
        // (the error body is what got written to disk). Installing an error page as
        // the model file would break every subsequent transcription with no in-app
        // recovery, so fail the download instead.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            continuation?.resume(throwing: ModelDownloadError(message: "Server returned HTTP \(http.statusCode)"))
            continuation = nil
            session.invalidateAndCancel()
            return
        }
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("openwhisp-model-\(UUID().uuidString).download")
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.moveItem(at: location, to: tempURL)
            continuation?.resume(returning: tempURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, continuation != nil {
            continuation?.resume(throwing: error)
            continuation = nil
            session.invalidateAndCancel()
        }
    }
}

// MARK: - Helpers

extension URL {
    func createDirectories() throws {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true, attributes: nil)
    }
}

// MARK: - Agent Bridge host (M8)

extension AppState: AgentBridgeHost {
    /// Called on the main thread by AgentBridgeServer. Builds a read-only status
    /// snapshot for the `status` control-plane method and the CLI liveness probe.
    func bridgeStatus() -> BridgeWire.StatusResult {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let engine = transcriptionEngine == "whisper" ? whisperBackend : transcriptionEngine
        return BridgeWire.StatusResult(
            appVersion: appVersion,
            engine: engine,
            model: modelName,
            sessionActive: isRecording || isTranscribing || sessionActive,
            llmConfigured: llmConfigured,
            llmProvider: llmProvider,
            // Only the cloud (OpenAI) provider leaves the device.
            sendsTextToCloud: llmProvider == "openai",
            historyEnabled: historyEnabled
        )
    }

    /// Recent dictation history, newest first (the store already inserts at 0),
    /// mapped to the wire DTO. Empty when history is disabled.
    func bridgeHistory(limit: Int) -> [BridgeWire.HistoryEntryDTO] {
        guard historyEnabled else { return [] }
        return history.prefix(limit).map { e in
            BridgeWire.HistoryEntryDTO(
                id: e.id,
                text: e.text,
                date: BridgeWire.iso8601String(from: e.date),
                appBundleID: e.appBundleID,
                appName: e.appName,
                initiator: nil // recorded per-entry once the agent path lands (step 6)
            )
        }
    }

    /// Capabilities this build implements. `dictate` and `refine` are added as M8
    /// steps 6–7 wire them; advertising only what works keeps agents from calling
    /// unimplemented tools.
    func bridgeCapabilities() -> [String] {
        [BridgeWire.Capability.dictate, BridgeWire.Capability.refine,
         BridgeWire.Capability.history, BridgeWire.Capability.sync]
    }

    // MARK: Refine (M8)

    /// Refine `text` per `instruction` using the user's configured LLM, delivering
    /// the result to `completion`. Used by the bridge `refine` tool. On failure the
    /// error carries the original text so an agent can proceed unrefined.
    func bridgeRefine(
        clientName: String, text: String, instruction: String,
        completion: @escaping (Result<String, BridgeWire.ErrorObject>) -> Void
    ) {
        refineText(text: text, instruction: instruction, completion: completion)
    }

    /// The refine primitive: reuses the exact overlay-refine LLM path (InstructionChain
    /// directive + payload → the user's endpoint/model), bracketed by
    /// ensureBundledLLMReady. Gated by the cloud-AI toggle and busy-rejected while a
    /// dictation session is live (quiescing the whisper-server under a session is the
    /// documented hazard). Fail-open: errors carry `originalText`.
    func refineText(
        text: String, instruction: String,
        completion: @escaping (Result<String, BridgeWire.ErrorObject>) -> Void
    ) {
        // Cloud-refine gate: never let an agent send text to OpenAI unless allowed.
        if llmProvider == "openai" && !agentBridgeAllowCloudAI {
            completion(.failure(.domain(.cloudRefineDisabled,
                message: "agent cloud AI is off — enable it in Settings → Agent Bridge, or switch to a local provider",
                originalText: text)))
            return
        }
        guard llmConfigured else {
            completion(.failure(.domain(.llmUnavailable,
                message: "no AI model is configured — set one in Settings → Cleanup", originalText: text)))
            return
        }
        // Busy-reject while dictating: quiesceWhisper would stop a live session's
        // whisper-server.
        guard !sessionActive, !isRecording, !isTranscribing else {
            completion(.failure(.domain(.busy,
                message: "OpenWhisp is busy dictating; try again shortly", originalText: text)))
            return
        }

        let systemDirective = InstructionChain.systemDirective
        let userPayload = InstructionChain.userPayload(instruction: instruction, text: text)
        var delivered = false
        let deliver: (Result<String, BridgeWire.ErrorObject>) -> Void = { result in
            guard !delivered else { return }
            delivered = true
            completion(result)
        }

        // boundToSession: false — an agent refine isn't scoped to a dictation
        // session, so a user starting a dictation mid-load must not strand the
        // completion (the server's connection thread blocks on it).
        ensureBundledLLMReady(statusWhileLoading: "Refining…", quiesceWhisper: true, boundToSession: false, work: { [weak self] done in
            guard let self else {
                done()
                deliver(.failure(.domain(.internalError, message: "app deallocated", originalText: text)))
                return
            }
            self.translationService.processFinalText(
                text: userPayload,
                mode: "rephrase",
                targetLanguage: self.translationTargetLanguage,
                endpoint: self.llmEndpoint,
                model: self.llmModel,
                customInstruction: systemDirective
            ) { [weak self] result in
                Task { @MainActor in
                    done() // close the engine bracket on every path
                    guard let self else {
                        deliver(.failure(.domain(.internalError, message: "app deallocated", originalText: text)))
                        return
                    }
                    switch result {
                    case .success(let processedText):
                        deliver(.success(self.postProcess(processedText)))
                    case .failure(let error):
                        deliver(.failure(.domain(.llmUnavailable, message: error.localizedDescription, originalText: text)))
                    }
                }
            }
        }, fallback: {
            deliver(.failure(.domain(.llmUnavailable, message: "built-in model unavailable", originalText: text)))
        })
    }

    /// Run ONE summarize prompt (map/reduce step) through the RESOLVED summary
    /// provider/model/endpoint (MAK-53), rather than the global cleanup LLM. The
    /// per-meeting privacy consent is enforced upstream in the coordinator using
    /// `resolved.isLocal`; this method just performs the round-trip. Brackets the
    /// bundled engine when the resolved provider is bundled.
    func summarizeResolved(
        text: String, instruction: String, resolved: SummaryModelResolver.Resolved,
        completion: @escaping (Result<String, BridgeWire.ErrorObject>) -> Void
    ) {
        // Busy-reject while dictating (same guarantee refineText gives): warming
        // the bundled LLM would stop a live whisper-server.
        guard !sessionActive, !isRecording, !isTranscribing else {
            completion(.failure(.domain(.busy,
                message: "OpenWhisp is busy dictating; try again shortly", originalText: text)))
            return
        }

        // Defense in depth (the coordinator already refuses agent-CLI resolutions):
        // `summaryEndpoint`'s default branch is the OpenAI cloud endpoint, so an
        // agentCLI-resolved provider must fail closed here rather than silently
        // POST the transcript to a cloud endpoint the user never consented to.
        guard resolved.provider != EnhancementProvider.agentCLIID else {
            completion(.failure(.domain(.llmUnavailable,
                message: "the agent CLI provider can't summarize meetings — pick a summarization model in Settings → Meetings",
                originalText: text)))
            return
        }

        let systemDirective = InstructionChain.systemDirective
        let userPayload = InstructionChain.userPayload(instruction: instruction, text: text)
        let endpoint = summaryEndpoint(for: resolved)
        let model = resolved.model
        var delivered = false
        let deliver: (Result<String, BridgeWire.ErrorObject>) -> Void = { result in
            guard !delivered else { return }
            delivered = true
            completion(result)
        }

        ensureBundledLLMReady(statusWhileLoading: "Summarizing…", quiesceWhisper: true, boundToSession: false, provider: resolved.provider, work: { [weak self] done in
            guard let self else {
                done()
                deliver(.failure(.domain(.internalError, message: "app deallocated", originalText: text)))
                return
            }
            self.translationService.processFinalText(
                text: userPayload,
                mode: "rephrase",
                targetLanguage: self.translationTargetLanguage,
                endpoint: endpoint,
                model: model,
                customInstruction: systemDirective
            ) { [weak self] result in
                Task { @MainActor in
                    done()
                    guard let self else {
                        deliver(.failure(.domain(.internalError, message: "app deallocated", originalText: text)))
                        return
                    }
                    switch result {
                    case .success(let processedText):
                        // Meeting SUMMARY text (MAK-53): deliver the LLM's output
                        // verbatim — do NOT run it through the dictation cleaner
                        // (`postProcess`). That cleaner is for dictated SPEECH: it
                        // normalizes every newline to a space (which flattens the
                        // summary's Markdown structure) and applies spoken-punctuation /
                        // vocab / filler transforms that don't belong on written prose —
                        // and it would also pollute the self-learning vocabulary usage
                        // counts (`sessionFiredSubstitutionIDs`) with matches from the
                        // summary. The summarizer prompt already produces clean Markdown.
                        deliver(.success(processedText))
                    case .failure(let error):
                        deliver(.failure(.domain(.llmUnavailable, message: error.localizedDescription, originalText: text)))
                    }
                }
            }
        }, fallback: {
            deliver(.failure(.domain(.llmUnavailable, message: "built-in model unavailable", originalText: text)))
        })
    }

    // MARK: Dictate (M8)

    /// Start an agent-initiated dictation. Guards run up front (busy / mic
    /// permission / secure field) so a failure is delivered immediately; otherwise
    /// the result is delivered when the session finalizes (via onSessionEnd) or on
    /// the timeout. Called on the main thread; `completion` fires on the main thread.
    func bridgeStartDictation(
        clientName: String, prompt: String?, timeoutSeconds: Int, language: String?,
        completion: @escaping (Result<BridgeWire.DictateResult, BridgeWire.ErrorObject>) -> Void
    ) {
        // Busy: the human (or another agent session) always wins the mic.
        guard !isRecording, !isTranscribing, !sessionActive else {
            completion(.failure(.domain(.busy, message: "OpenWhisp is busy with another dictation; try again shortly")))
            return
        }
        // Don't surface the macOS microphone TCC prompt on an agent's behalf.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            completion(.failure(.domain(.micPermissionNeeded, message: "grant OpenWhisp microphone access in System Settings first")))
            return
        }
        // Refuse if a password field is focused (agent dictation never pastes, but
        // the user might speak a secret while a secure field has focus).
        guard !SecureFieldDetector.focusedFieldIsSecure() else {
            completion(.failure(.domain(.secureField, message: "a password field is focused; dictation refused")))
            return
        }
        // Per-client rate limit (MAK-10): even an always-allowed client can't hold
        // the mic continuously. Checked AFTER busy/permission/secure-field — those
        // aren't the client's fault, so they mustn't consume its budget — and only
        // once we're committed to starting (all synchronous guards passed), so the
        // recorded start matches a session that actually opens the mic.
        let now = Date()
        if case .throttled(let retryAfter) = agentRateLimiter.check(clientName: clientName, now: now) {
            let secs = Int(retryAfter.rounded(.up))
            completion(.failure(.domain(
                .rateLimited,
                message: "this client is dictating too frequently; retry in about \(secs)s",
                retryAfterSeconds: max(1, secs)
            )))
            return
        }
        agentRateLimiter.recordStart(clientName: clientName, now: now)

        let started = now
        agentDictateTimedOut = false
        agentDictateStopped = false
        // The overlay attribution line. Sanitized (control/bidi chars stripped,
        // capped) and always framed as the CLIENT asking — agent-controlled text
        // must never read as OpenWhisp's own voice.
        let displayClient = BridgeWire.sanitizedForDisplay(clientName, maxLength: 60)
        let clientLabel = displayClient.isEmpty ? "An agent" : displayClient
        let displayQuestion = prompt.map { BridgeWire.sanitizedForDisplay($0, maxLength: 200) } ?? ""
        if !displayQuestion.isEmpty {
            agentDictatePrompt = "\(clientLabel) asks: \(displayQuestion)"
        } else {
            agentDictatePrompt = "\(clientLabel) asked you to dictate"
        }
        // Split pieces for the hero overlay: the question is the content, the
        // client the quiet attribution. `agentDictateQuestion` is nil (not empty)
        // when the agent gave no prompt, so the overlay falls back cleanly.
        agentDictateClientLabel = clientLabel
        agentDictateQuestion = displayQuestion.isEmpty ? nil : displayQuestion
        sessionInitiator = .agent(client: clientName, prompt: prompt)
        onSessionEnd = { [weak self] outcome in
            guard let self else { return }
            self.agentDictateTimeoutTask?.cancel()
            self.agentDictateTimeoutTask = nil
            // Close the rate-limit entry: the listening-time budget charges actual
            // mic time, and the cooldown runs from the session's END (a gap
            // between sessions), not its start.
            self.agentRateLimiter.recordEnd(clientName: clientName, now: Date())
            let duration = Date().timeIntervalSince(started)
            let timedOut = self.agentDictateTimedOut
            let stopped = self.agentDictateStopped
            switch outcome {
            case .completed(let text):
                let endedBy: BridgeWire.DictateEnd = timedOut ? .timeout : (stopped ? .stop : .user)
                completion(.success(.init(text: text, durationSeconds: duration, timedOut: timedOut, endedBy: endedBy)))
            case .empty:
                if timedOut {
                    completion(.failure(.domain(.timeout, message: "no speech within the time limit")))
                } else {
                    completion(.success(.init(text: "", durationSeconds: duration, timedOut: false, endedBy: stopped ? .stop : .user)))
                }
            case .secureField:
                completion(.failure(.domain(.secureField, message: "a password field was focused; dictation refused")))
            case .cancelled:
                // Per the cancel invariant: no transcript on a cancel.
                completion(.failure(.domain(.cancelled, message: "the user declined to answer — do not retry")))
            case .error(let message):
                completion(.failure(.domain(.audioUnavailable, message: message)))
            }
        }

        // "Go live": actually open the mic and arm the session guards. Deferred
        // until AFTER any spoken question finishes — otherwise the mic captures the
        // app's own TTS and returns it to the agent as the human's answer (an
        // acoustic feedback loop). Runs exactly once; a `fired` latch dedups the
        // TTS-completion callback against the watchdog fallback.
        var fired = false
        let goLive: () -> Void = { [weak self] in
            guard let self, !fired else { return }
            fired = true
            self.agentDictateReadingQuestion = false

            // A cancel/decline can arrive while the question is still being read
            // (the overlay's Esc, a superseding session). Don't open the mic on a
            // session that's already been torn down.
            guard self.sessionInitiator.isAgent, self.onSessionEnd != nil else { return }

            // Run the shared start path. Any pre-session bail (e.g. a secure field
            // that became focused in the last instant) leaves sessionActive false;
            // catch it so the agent is never left hanging.
            self.startDictation()
            guard self.sessionActive else {
                let done = self.onSessionEnd
                self.onSessionEnd = nil
                self.agentDictatePrompt = nil
                self.agentDictateClientLabel = nil
                self.agentDictateQuestion = nil
                self.sessionInitiator = .user
                // Deliver the failure directly — the session never began, so
                // finishSessionUI's normal delivery won't run.
                if done != nil {
                    completion(.failure(.domain(.internalError, message: "could not start dictation")))
                }
                return
            }

            // Arm silence auto-stop (default-on) so the answer ends when the speaker
            // stops, not only on the timeout. Fed from `updateAudioLevel`. The
            // timeout below remains the hard ceiling / no-speech fallback.
            self.agentSilenceDetector = self.agentBridgeSilenceAutoStop
                ? SilenceAutoStop(config: QuietDictationMode.silenceAutoStopConfig(quietEnabled: self.quietDictationEnabled))
                : nil

            // Arm the EOU auto-stop (MAK-46 Phase 5) alongside the silence detector,
            // but only when the setting is on AND the active engine emits EOU events
            // (the Parakeet EOU variant). Otherwise no EOU callback ever fires and
            // the detector stays inert. Default-off + experimental.
            self.agentEouDetector = (self.agentBridgeEouAutoStop && self.activeEngineEmitsEou)
                ? AgentEouAutoStop()
                : nil

            let sid = self.activeSessionID
            self.agentDictateTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutSeconds)) * 1_000_000_000)
                // Cancellation makes Task.sleep THROW EARLY (and try? swallows it) —
                // without this check, the cancel issued by a silence/stop finish
                // would wake the task immediately, mid-finalization (sessionActive
                // still true, same sid), and flip the very endedBy it tried to protect.
                guard !Task.isCancelled else { return }
                guard let self, self.sessionActive, self.activeSessionID == sid else { return }
                self.agentDictateTimedOut = true
                self.stopDictation()
            }
        }

        // Audible "your turn" cues (both opt-out). The chime fires first as a
        // distinct attention ping. If the question is read aloud, we hold capture
        // until speech ends (via the completion callback) and show a "reading —
        // wait" cue meanwhile. With no spoken question (TTS off, or nothing
        // speakable, or chime-only), go live immediately.
        if agentBridgeChimeEnabled {
            agentAnnouncer.chime()
        }
        if agentBridgeSpeakQuestionEnabled, let prompt,
           !AgentAnnouncer.spokenForm(of: prompt).isEmpty {
            agentDictateReadingQuestion = true
            // Show the overlay NOW (normally beginSession does this, but capture —
            // and beginSession — is held until speech ends). It renders the
            // "Reading question — wait" cue and the question hero, and gives the
            // user an Esc target to back out before the mic ever opens.
            if showOverlay || sessionInitiator.isAgent {
                overlayController?.show()
                overlayIsVisible = true
            }
            agentAnnouncer.speak(prompt, onFinish: goLive)
            // Watchdog: if the speech-finished callback never arrives (engine
            // stall, delegate never fires), open the mic anyway a few seconds past
            // the longest realistic read of the 240-char cap so the agent is never
            // left hanging in "reading" forever.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self, !fired else { return }
                self.agentAnnouncer.stopSpeaking()
                goLive()
            }
        } else {
            goLive()
        }
    }

    /// Agent-signaled "the user said they're done" — finalize this agent session.
    /// Never affects a user session.
    func bridgeStopAgentDictation() -> Bool {
        guard sessionActive, sessionInitiator.isAgent else { return false }
        agentDictateStopped = true
        // Same as the silence finish: the stop is decided now, so the timeout must
        // not fire during finalization and misreport endedBy as .timeout.
        agentDictateTimeoutTask?.cancel()
        agentDictateTimeoutTask = nil
        stopDictation()
        return true
    }

    /// Cancel this agent session (returns no transcript). Never affects a user
    /// session — an agent can't stop the human's dictation.
    func bridgeCancelAgentDictation() -> Bool {
        guard sessionActive, sessionInitiator.isAgent else { return false }
        cancelDictation()
        return true
    }

    // MARK: Consent (M8)

    /// Resolve consent for `clientName` on a specific `scope`, presenting the
    /// consent window when that scope's stored policy requires it. Called on the
    /// main thread; `completion` fires on the main thread with allow/deny. The
    /// server bridges the async result back to its connection thread.
    func bridgeResolveConsent(clientName: String, scope: AgentScope, completion: @escaping (Bool) -> Void) {
        // Policy → decision goes through the tested AgentConsentPolicy.decision
        // (a persisted `.whileRunning` from an earlier run correctly demotes to
        // a prompt: the grant itself lives only in this run's set).
        switch consentDecision(for: clientName, scope: scope) {
        case .allow:
            completion(true)
        case .deny:
            completion(false)
        case .prompt:
            AgentConsentWindowController.shared.present(
                clientName: clientName, scope: scope,
                // Re-checked at presentation: while this request sat queued behind
                // another prompt, the user may have already decided this exact
                // (client, scope) — presenting again would invite them to
                // contradict, and overwrite, that fresh decision.
                revalidate: { [weak self] in
                    self?.consentDecision(for: clientName, scope: scope) ?? .deny
                }
            ) { [weak self] choice in
                guard let self else { completion(false); return }
                switch choice {
                case .always:
                    self.upsertConsent(clientName, scope: scope, policy: .always)
                    completion(true)
                case .whileRunning:
                    // The run-set is what grants; the record (policy .whileRunning)
                    // is what makes the client visible — and revocable — in the
                    // settings pane while the grant stands.
                    self.upsertConsent(clientName, scope: scope, policy: .whileRunning)
                    self.consentGrantedThisRun[clientName, default: []].insert(scope)
                    completion(true)
                case .askEveryTime:
                    self.upsertConsent(clientName, scope: scope, policy: .askEveryTime)
                    completion(true)
                case .deny:
                    // Explicit Deny → persist a standing deny for THIS scope only
                    // (fail fast next time; other scopes are unaffected).
                    self.upsertConsent(clientName, scope: scope, policy: .denied)
                    completion(false)
                case .grantedWhileQueued:
                    // Decided while queued (e.g. the user just clicked "Always
                    // allow" on the identical prompt) — nothing to persist.
                    completion(true)
                case .deniedWhileQueued:
                    completion(false)
                case .dismiss:
                    // Window closed / timed out → refuse this call only.
                    completion(false)
                }
            }
        }
    }

    /// The decision the stored per-scope policy + this-run grants yield for
    /// `(clientName, scope)`, without prompting. An unrecorded scope prompts.
    private func consentDecision(for clientName: String, scope: AgentScope) -> AgentConsentDecision {
        consentDecision(record: agentClients.record(for: clientName), clientName: clientName, scope: scope)
    }

    /// Same, with the record already fetched — bridge.hello resolves every scope
    /// at once and must not re-scan the records array once per scope.
    private func consentDecision(
        record: AgentClientRecord?, clientName: String, scope: AgentScope
    ) -> AgentConsentDecision {
        guard let policy = record?.policy(for: scope) else { return .prompt }
        let grantedThisRun = consentGrantedThisRun[clientName]?.contains(scope) ?? false
        return policy.decision(grantedThisRun: grantedThisRun)
    }

    /// The posture advertised in `bridge.hello` (never prompts): a per-scope map
    /// plus a summary scalar — `.granted` only if EVERY scope is already allowed,
    /// `.denied` only if every scope is denied, else `.pending`. The scalar alone
    /// is too lossy for real clients (a dictate-only agent with an explicit deny
    /// would read "pending" forever); adapters that care which capability is
    /// usable read the map. Prompting still happens per call.
    func bridgeConsentSnapshot(clientName: String) -> (summary: BridgeWire.ConsentState, scopes: [String: BridgeWire.ConsentState]) {
        let record = agentClients.record(for: clientName)
        var scopes: [String: BridgeWire.ConsentState] = [:]
        var allAllow = true
        var allDeny = true
        for scope in AgentScope.allCases {
            let decision = consentDecision(record: record, clientName: clientName, scope: scope)
            switch decision {
            case .allow:  scopes[scope.rawValue] = .granted
            case .deny:   scopes[scope.rawValue] = .denied
            case .prompt: scopes[scope.rawValue] = .pending
            }
            allAllow = allAllow && decision == .allow
            allDeny = allDeny && decision == .deny
        }
        return (allAllow ? .granted : (allDeny ? .denied : .pending), scopes)
    }

    /// Note a completed agent call on the client's record (for the settings pane).
    func bridgeDidCall(clientName: String, tool: String) {
        guard var record = agentClients.record(for: clientName) else { return }
        record.lastCall = Date()
        record.lastTool = tool
        agentClients.upsert(record)
        agentClients.save()
    }

    /// Revoke a client's stored consent entirely (from the settings pane) — drops
    /// the record and every this-run grant for the client, so the next call in any
    /// scope prompts fresh.
    func revokeAgentClient(_ clientName: String) {
        agentClients.remove(clientName: clientName)
        consentGrantedThisRun.removeValue(forKey: clientName)
        agentRateLimiter.forget(clientName: clientName)
        agentClients.save()
    }

    /// Record `policy` for a single `scope` of `clientName`, leaving the client's
    /// other scopes intact. Skips the full-store rewrite when nothing changed —
    /// an ask-every-time client would otherwise re-save a byte-identical file on
    /// every consented call (right before bridgeDidCall saves again).
    private func upsertConsent(_ clientName: String, scope: AgentScope, policy: AgentConsentPolicy) {
        var record = agentClients.record(for: clientName)
            ?? AgentClientRecord(clientName: clientName, scopePolicies: [:], firstSeen: Date())
        guard record.scopePolicies[scope] != policy else { return }
        record.scopePolicies[scope] = policy
        agentClients.upsert(record)
        agentClients.save()
    }
}
