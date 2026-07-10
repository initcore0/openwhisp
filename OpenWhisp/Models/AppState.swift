import Foundation
import Combine
import AVFoundation
import UserNotifications
import Cocoa
import ApplicationServices
import Speech

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Settings (persisted)

    @Published var whisperBinaryPath: String {
        didSet { UserDefaults.standard.set(whisperBinaryPath, forKey: "whisperBinaryPath") }
    }

    @Published var modelPath: String {
        didSet { UserDefaults.standard.set(modelPath, forKey: "modelPath") }
    }

    @Published var modelName: String {
        didSet {
            UserDefaults.standard.set(modelName, forKey: "modelName")
            modelPath = resolvedModelPath()
        }
    }

    /// WhisperKit CoreML model id (its own `openai_whisper-*` namespace), separate
    /// from the whisper.cpp GGML `modelName`. Drives the WhisperKit file + streaming
    /// engines. Changing it rebuilds the WhisperKit engine so the new model loads.
    @Published var whisperKitModel: String {
        didSet {
            guard whisperKitModel != oldValue else { return }
            UserDefaults.standard.set(whisperKitModel, forKey: "whisperKitModel")
            if transcriptionEngine == "whisperKit" { rebuildFileEngine() }
        }
    }

    @Published var microphoneID: String {
        didSet { UserDefaults.standard.set(microphoneID, forKey: "microphoneID") }
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
            UserDefaults.standard.set(triggerMode, forKey: "triggerMode")
            hotkeyMonitor?.triggerMode = triggerMode
        }
    }

    /// Selected refine key (RefineKey id, e.g. "rightOption"; "off" disables it).
    @Published var refineKey: String {
        didSet {
            UserDefaults.standard.set(refineKey, forKey: "refineKey")
            hotkeyMonitor?.refineKey = refineKey
        }
    }

    @Published var outputMode: String {
        didSet { persist(outputMode, "outputMode") }
    }

    @Published var showOverlay: Bool {
        didSet { UserDefaults.standard.set(showOverlay, forKey: "showOverlay") }
    }

    /// Visual style of the overlay's voice indicator (Settings › General → Recording Overlay).
    @Published var voiceIndicatorStyle: VoiceIndicatorStyle {
        didSet { UserDefaults.standard.set(voiceIndicatorStyle.rawValue, forKey: "voiceIndicatorStyle") }
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
        didSet { UserDefaults.standard.set(restoreClipboard, forKey: "restoreClipboard") }
    }

    /// How transcribed text is inserted into the focused app:
    /// "auto" (try Accessibility direct-insert, fall back to paste),
    /// "directAX" (Accessibility only), or "paste" (Cmd+V only).
    /// Direct-insert preserves the user's clipboard entirely.
    @Published var insertionMode: String {
        didSet { UserDefaults.standard.set(insertionMode, forKey: "insertionMode") }
    }

    @Published var addTrailingSpace: Bool {
        didSet { UserDefaults.standard.set(addTrailingSpace, forKey: "addTrailingSpace") }
    }

    /// Auto-gain: boost a quiet microphone toward a healthy level before sending
    /// audio to whisper, improving recognition for soft talkers / low-output mics.
    /// Default-on; runs locally with a no-clip safety cap.
    @Published var autoGainEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoGainEnabled, forKey: "autoGainEnabled")
            audioRecorder?.autoGainEnabled = autoGainEnabled
        }
    }

    /// Local, on-device cleanup of dictated text (punctuation, capitalization,
    /// filler removal). Default-on — this is the baseline quality pass and runs
    /// entirely locally, no network.
    @Published var smartFormattingEnabled: Bool {
        didSet { UserDefaults.standard.set(smartFormattingEnabled, forKey: "smartFormattingEnabled") }
    }

    /// Apply spoken-punctuation commands ("new line", "comma", "period", ...).
    @Published var spokenPunctuationEnabled: Bool {
        didSet { UserDefaults.standard.set(spokenPunctuationEnabled, forKey: "spokenPunctuationEnabled") }
    }

    /// Remove filler words ("um", "uh", ...) from dictated text.
    @Published var fillerRemovalEnabled: Bool {
        didSet { UserDefaults.standard.set(fillerRemovalEnabled, forKey: "fillerRemovalEnabled") }
    }

    /// Rewrite spoken filenames to editor `@`-mentions (MAK-48), but ONLY when
    /// the frontmost app is a known AI-native editor (Cursor / Windsurf). Default
    /// OFF: a niche developer aid that would be wrong to run in a chat or doc, so
    /// it's opt-in and gated to editors even when enabled.
    @Published var fileTaggingEnabled: Bool {
        didSet { UserDefaults.standard.set(fileTaggingEnabled, forKey: "fileTaggingEnabled") }
    }

    // Opt-in structural formatting (MAK-20). The rules live in SmartFormatter and
    // are honored by TranscriptCleaner; these flags are the Settings controls that
    // turn each group on. All default OFF so ordinary prose is never touched until
    // the user opts in.
    @Published var normalizeNumbers: Bool {
        didSet { UserDefaults.standard.set(normalizeNumbers, forKey: "normalizeNumbers") }
    }

    @Published var normalizeCurrency: Bool {
        didSet { UserDefaults.standard.set(normalizeCurrency, forKey: "normalizeCurrency") }
    }

    @Published var spokenListsEnabled: Bool {
        didSet { UserDefaults.standard.set(spokenListsEnabled, forKey: "spokenListsEnabled") }
    }

    @Published var basicMarkdownEnabled: Bool {
        didSet { UserDefaults.standard.set(basicMarkdownEnabled, forKey: "basicMarkdownEnabled") }
    }

    @Published var liveChunkDuration: Double {
        didSet { UserDefaults.standard.set(liveChunkDuration, forKey: "liveChunkDuration") }
    }

    @Published var pauseBasedLiveChunksEnabled: Bool {
        didSet { UserDefaults.standard.set(pauseBasedLiveChunksEnabled, forKey: "pauseBasedLiveChunksEnabled") }
    }

    /// Default transcription engine for a fresh install. WhisperKit is the preferred
    /// default, but only when it's actually compiled in (`WHISPERKIT` build flag) —
    /// a lean `WHISPERKIT=0` build would otherwise default to an engine that errors,
    /// so it falls back to whisper.cpp there.
    static var defaultTranscriptionEngine: String {
        #if WHISPERKIT
        return "whisperKit"
        #else
        return "whisper"
        #endif
    }

    @Published var transcriptionEngine: String {
        didSet {
            guard transcriptionEngine != oldValue else { return }
            UserDefaults.standard.set(transcriptionEngine, forKey: "transcriptionEngine")
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

    /// Build the file-transcription engine for the given setting. "whisperKit" is
    /// the experimental CoreML backend (only functional in a WHISPERKIT build —
    /// otherwise its stub reports unavailability); everything else uses whisper.cpp.
    private static func makeFileEngine(for engine: String, model: String, whisperKitModel: String) -> FileTranscriptionEngine {
        switch engine {
        // WhisperKit uses its OWN model namespace (openai_whisper-*), not the
        // whisper.cpp GGML model id.
        case "whisperKit": return WhisperKitEngine(modelName: whisperKitModel)
        default:           return WhisperEngine()
        }
    }

    @Published var whisperBackend: String {
        didSet {
            UserDefaults.standard.set(whisperBackend, forKey: "whisperBackend")
            if whisperBackend != "serverAPI" {
                whisperEngine?.stopServer()
            } else {
                warmWhisperServerIfPossible()
            }
        }
    }

    @Published var openAIEnhancementEnabled: Bool {
        didSet {
            persist(openAIEnhancementEnabled, "openAIEnhancementEnabled")
            if openAIEnhancementEnabled {
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

    @Published var openAIEnhancementMode: String {
        didSet { UserDefaults.standard.set(openAIEnhancementMode, forKey: "openAIEnhancementMode") }
    }

    @Published var translationTargetLanguage: String {
        didSet { UserDefaults.standard.set(translationTargetLanguage, forKey: "translationTargetLanguage") }
    }

    @Published var openAIAPIKey: String {
        didSet { secretStore.save(openAIAPIKey, key: "openAIAPIKey") }
    }

    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "openAIModel") }
    }

    /// Which LLM backend powers post-processing: "openai" (cloud) or
    /// "local" (an OpenAI-compatible local server — llama.cpp/Ollama). Local
    /// keeps everything on-device/on-LAN, preserving the privacy story.
    @Published var llmProvider: String {
        didSet {
            UserDefaults.standard.set(llmProvider, forKey: "llmProvider")
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
        didSet { UserDefaults.standard.set(localLLMBaseURL, forKey: "localLLMBaseURL") }
    }

    /// Model name to request from the local server.
    @Published var localLLMModel: String {
        didSet { UserDefaults.standard.set(localLLMModel, forKey: "localLLMModel") }
    }

    /// Selected built-in (bundled llama.cpp) refinement model id, from
    /// llm-manifest.json. Used when `llmProvider == "bundled"`.
    @Published var bundledLLMModel: String {
        didSet {
            guard bundledLLMModel != oldValue else { return }
            UserDefaults.standard.set(bundledLLMModel, forKey: "bundledLLMModel")
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
    @Published var debugOverlayEnabled: Bool = UserDefaults.standard.object(forKey: "debugOverlayEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(debugOverlayEnabled, forKey: "debugOverlayEnabled") }
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
        didSet { UserDefaults.standard.set(instructionChainEnabled, forKey: "instructionChainEnabled") }
    }


    /// Opt-in custom **script** post-processor. When enabled with a valid
    /// executable path, the final transcript is piped through the script (stdin →
    /// stdout) just before insertion. Off by default; fail-open (any error/timeout
    /// keeps the original text). See ScriptRunner / ScriptOutcome.
    @Published var scriptPostProcessorEnabled: Bool {
        didSet { UserDefaults.standard.set(scriptPostProcessorEnabled, forKey: "scriptPostProcessorEnabled") }
    }
    @Published var scriptPostProcessorPath: String {
        didSet { UserDefaults.standard.set(scriptPostProcessorPath, forKey: "scriptPostProcessorPath") }
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
        didSet { UserDefaults.standard.set(perAppModesEnabled, forKey: "perAppModesEnabled") }
    }

    /// Keep a local history of completed transcriptions (recover/reuse). Local only.
    @Published var historyEnabled: Bool {
        didSet { UserDefaults.standard.set(historyEnabled, forKey: "historyEnabled") }
    }

    /// Per-app override profiles (persisted to profiles.json).
    @Published var profiles: [AppProfile] {
        didSet { AppProfileStore.save(profiles) }
    }

    /// Recent transcriptions (persisted to history.json), newest first.
    @Published var history: [TranscriptionEntry] = []

    // MARK: Agent Bridge (M8)

    /// Expose OpenWhisp as a local MCP server / CLI to coding agents. Default-off:
    /// when false, no socket and no listener exist (zero cost). Toggling it starts
    /// or stops the control-plane socket server.
    @Published var agentBridgeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(agentBridgeEnabled, forKey: "agentBridgeEnabled")
            agentBridgeServer.allowUnsignedClients = agentBridgeAllowUnsignedClients
            if agentBridgeEnabled { agentBridgeServer.start() } else { agentBridgeServer.stop() }
        }
    }
    /// Relax the code-signature admission check so a user's own (unsigned) client
    /// can connect. Default-off; on-brand escape hatch for the hackable positioning.
    @Published var agentBridgeAllowUnsignedClients: Bool {
        didSet {
            UserDefaults.standard.set(agentBridgeAllowUnsignedClients, forKey: "agentBridgeAllowUnsignedClients")
            agentBridgeServer.allowUnsignedClients = agentBridgeAllowUnsignedClients
        }
    }
    /// Allow an agent-initiated LLM call to use the CLOUD provider (OpenAI).
    /// Default-off: a prompt-injected agent must not be able to exfiltrate text
    /// through the user's OpenAI key. When off and the provider is OpenAI, agent
    /// `refine` is refused with `cloudRefineDisabled`.
    @Published var agentBridgeAllowCloudAI: Bool {
        didSet { UserDefaults.standard.set(agentBridgeAllowCloudAI, forKey: "agentBridgeAllowCloudAI") }
    }
    /// End an agent-initiated dictation automatically once the speaker falls
    /// silent, instead of waiting for the timeout. Default-ON: the whole point of
    /// agent dictate is a quick spoken answer, and an agent session has no natural
    /// finish gesture (the hotkey cancels it). NEVER affects user (hotkey)
    /// sessions — only sessions the bridge started. See [[SilenceAutoStop]].
    @Published var agentBridgeSilenceAutoStop: Bool {
        didSet { UserDefaults.standard.set(agentBridgeSilenceAutoStop, forKey: "agentBridgeSilenceAutoStop") }
    }
    /// Play a short chime when an agent opens a dictation so you notice it even
    /// when you're not looking at that corner of the screen. Agent sessions only.
    @Published var agentBridgeChimeEnabled: Bool {
        didSet { UserDefaults.standard.set(agentBridgeChimeEnabled, forKey: "agentBridgeChimeEnabled") }
    }
    /// Read the agent's question aloud (on-device, no network) when it opens a
    /// dictation, so you can answer without reading the overlay. Agent sessions only.
    @Published var agentBridgeSpeakQuestionEnabled: Bool {
        didSet { UserDefaults.standard.set(agentBridgeSpeakQuestionEnabled, forKey: "agentBridgeSpeakQuestionEnabled") }
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
    /// The control-plane socket server. Lazily constructed (no cost until the
    /// bridge is enabled); owns the socket, per-connection auth, and dispatch.
    private lazy var agentBridgeServer = AgentBridgeServer(host: self)

    /// Bias whisper recognition toward custom terms. Default-on; harmless when
    /// the vocabulary is empty (no prompt is sent).
    @Published var customVocabularyEnabled: Bool {
        didSet { UserDefaults.standard.set(customVocabularyEnabled, forKey: "customVocabularyEnabled") }
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
        didSet { UserDefaults.standard.set(correctionLearningEnabled, forKey: "correctionLearningEnabled") }
    }

    /// Pending learned-correction proposals + declined keys, persisted locally.
    /// The editor renders `pending`; `acceptCorrectionProposal` / `rejectCorrectionProposal`
    /// mutate it. Never leaves the machine.
    @Published var correctionProposals: CorrectionProposalState {
        didSet { CorrectionProposalStore.save(correctionProposals) }
    }

    /// macOS AX watcher that captures a post-insert single-word correction. Nil on
    /// platforms/builds without it; armed after a completed AX-path final insert.
    private let correctionWatcher = AXCorrectionWatcher()


    // MARK: - Runtime State

    @Published var isRecording = false
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
        didSet { UserDefaults.standard.set(didCompleteOnboarding, forKey: "didCompleteOnboarding") }
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
    var appleSpeechEngine: StreamingTranscriptionEngine!
    /// Experimental real-time WhisperKit engine. Shares the streaming session
    /// machinery with Apple Speech (same handlers) but uses WhisperKit's
    /// `AudioStreamTranscriber` (owns the mic, built-in VAD, multilingual).
    var whisperKitStreamEngine: StreamingTranscriptionEngine!
    var translationService: OpenAITranslationService!
    var hotkeyMonitor: HotkeyControlling!

    private var overlayController: OverlayWindowController?
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
    /// True when the current streaming session is WhisperKit (vs Apple Speech).
    /// Selects the engine and whether to run the Speech-framework authorization.
    private var streamingUsesWhisperKit = false

    /// The streaming engine for the current/next session. WhisperKit when its
    /// backend is selected, otherwise Apple Speech. Both conform to the same
    /// protocol and route through the same session handlers.
    private var activeStreamingEngine: StreamingTranscriptionEngine {
        transcriptionEngine == "whisperKit" ? whisperKitStreamEngine : appleSpeechEngine
    }
    /// Model paths with a download currently in flight. Per-path (not a single
    /// value): switching models mid-download starts a second download, and each
    /// one must dedupe itself without clearing the other's guard.
    private var inFlightModelDownloads: Set<String> = []

    /// Global setting values saved before a per-app profile temporarily overrode
    /// them for the current session, so they can be restored when it ends.
    private var profileOverrideBackup: (language: String, translateToEnglish: Bool, outputMode: String, aiCleanup: Bool)?

    /// While a per-app profile override is in effect, don't persist the overridden
    /// settings to UserDefaults — otherwise a crash/force-quit mid-session would
    /// leave the profile's values as the user's globals on next launch.
    private var suppressSettingsPersistence = false

    /// Persist a setting unless a profile override is currently active.
    private func persist<T>(_ value: T, _ key: String) {
        guard !suppressSettingsPersistence else { return }
        UserDefaults.standard.set(value, forKey: key)
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
        InsertionMode(rawValue: insertionMode) ?? .auto
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
            return AgentCLIRefiner(config: activeAgentCLIConfig)
        }
        return OpenAIRefiner(
            service: translationService,
            mode: refinementMode(openAIEnhancementMode),
            targetLanguage: translationTargetLanguage,
            endpoint: llmEndpoint,
            model: llmModel
        )
    }

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
        let trigger = triggerMode == "fn" ? "Release Fn" : "Release Control+Space"
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

    init(
        secretStore: SecretStore = KeychainStore(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLogin(),
        textOutput: TextOutput = TextInserter(),
        audioCapture: AudioCapture? = nil,
        fileEngine: FileTranscriptionEngine? = nil
    ) {
        self.secretStore = secretStore
        self.launchAtLoginService = launchAtLoginService
        self.textOutput = textOutput
        self.injectedAudioCapture = audioCapture
        self.injectedFileEngine = fileEngine
        let savedWhisperBinaryPath = UserDefaults.standard.string(forKey: "whisperBinaryPath") ?? ""
        whisperBinaryPath = Self.preferredWhisperCLIPath(savedPath: savedWhisperBinaryPath)

        // Versioned settings migration MUST run before any key is read below:
        // it preserves old defaults for existing installs and splits the legacy
        // "en means translate" language value into language + translateToEnglish.
        SettingsMigration.migrate(UserDefaults.standard)

        // Default first-run model is "base" (147 MB): fast enough for a quick
        // first success, and — unlike the old "tiny" default — one of the
        // visible quality tiers, so a fresh install never renders as the
        // synthetic "Custom" row. (Existing installs keep "tiny" via migration.)
        let savedModel = UserDefaults.standard.string(forKey: "modelName") ?? "base"
        let fileName = Self.modelFileName(for: savedModel)
        modelName = savedModel
        let savedModelPath = UserDefaults.standard.string(forKey: "modelPath") ?? ""
        modelPath = Self.preferredModelPath(savedPath: savedModelPath, fileName: fileName)
        microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? ""
        language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        translateToEnglish = UserDefaults.standard.object(forKey: "translateToEnglish") as? Bool ?? false
        triggerMode = UserDefaults.standard.string(forKey: "triggerMode") ?? "fn"
        // Left Control: the old rightControl default doesn't exist on MacBook
        // keyboards, which made refine silently impossible there.
        refineKey = UserDefaults.standard.string(forKey: "refineKey") ?? RefineKey.defaultKey.rawValue
        outputMode = UserDefaults.standard.string(forKey: "outputMode") ?? "preview"
        showOverlay = UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true
        voiceIndicatorStyle = VoiceIndicatorStyle.from(UserDefaults.standard.string(forKey: "voiceIndicatorStyle"))
        launchAtLogin = launchAtLoginService.isEnabled
        // Restoring is what users assume happens — clipboard clobbering is the
        // top complaint about paste-based dictation. (Existing installs keep
        // their old effective value via migration.)
        restoreClipboard = UserDefaults.standard.object(forKey: "restoreClipboard") as? Bool ?? true
        insertionMode = UserDefaults.standard.string(forKey: "insertionMode") ?? "auto"
        addTrailingSpace = UserDefaults.standard.object(forKey: "addTrailingSpace") as? Bool ?? false
        autoGainEnabled = UserDefaults.standard.object(forKey: "autoGainEnabled") as? Bool ?? true
        smartFormattingEnabled = UserDefaults.standard.object(forKey: "smartFormattingEnabled") as? Bool ?? true
        spokenPunctuationEnabled = UserDefaults.standard.object(forKey: "spokenPunctuationEnabled") as? Bool ?? true
        fillerRemovalEnabled = UserDefaults.standard.object(forKey: "fillerRemovalEnabled") as? Bool ?? true
        fileTaggingEnabled = UserDefaults.standard.object(forKey: "fileTaggingEnabled") as? Bool ?? false
        // MAK-20 structural formatting groups default OFF (opt-in).
        normalizeNumbers = UserDefaults.standard.object(forKey: "normalizeNumbers") as? Bool ?? false
        normalizeCurrency = UserDefaults.standard.object(forKey: "normalizeCurrency") as? Bool ?? false
        spokenListsEnabled = UserDefaults.standard.object(forKey: "spokenListsEnabled") as? Bool ?? false
        basicMarkdownEnabled = UserDefaults.standard.object(forKey: "basicMarkdownEnabled") as? Bool ?? false
        liveChunkDuration = UserDefaults.standard.object(forKey: "liveChunkDuration") as? Double ?? 2.0
        pauseBasedLiveChunksEnabled = UserDefaults.standard.object(forKey: "pauseBasedLiveChunksEnabled") as? Bool ?? false
        transcriptionEngine = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? Self.defaultTranscriptionEngine
        whisperKitModel = UserDefaults.standard.string(forKey: "whisperKitModel") ?? "openai_whisper-small"
        if let savedBackend = UserDefaults.standard.string(forKey: "whisperBackend") {
            whisperBackend = savedBackend
        } else {
            whisperBackend = "serverAPI"
        }
        openAIEnhancementEnabled = UserDefaults.standard.object(forKey: "openAIEnhancementEnabled") as? Bool ?? false
        openAIEnhancementMode = UserDefaults.standard.string(forKey: "openAIEnhancementMode") ?? "rephrase"
        translationTargetLanguage = UserDefaults.standard.string(forKey: "translationTargetLanguage") ?? "en"
        // One-time migration: move any legacy plaintext key out of UserDefaults into the
        // Keychain. didSet does not fire during init, so the keychain write must be explicit.
        let keychainKey = secretStore.read(key: "openAIAPIKey")
        if let keychainKey, !keychainKey.isEmpty {
            openAIAPIKey = keychainKey
        } else if let legacyKey = UserDefaults.standard.string(forKey: "openAIAPIKey"),
                  !legacyKey.isEmpty {
            secretStore.save(legacyKey, key: "openAIAPIKey")
            UserDefaults.standard.removeObject(forKey: "openAIAPIKey")
            openAIAPIKey = legacyKey
        } else {
            openAIAPIKey = ""
        }
        openAIModel = UserDefaults.standard.string(forKey: "openAIModel") ?? "gpt-4o-mini"
        // Built-in by default: first enable of AI cleanup works offline with
        // zero setup, matching the product's privacy story. (Existing installs
        // keep "openai" via migration.)
        llmProvider = UserDefaults.standard.string(forKey: "llmProvider") ?? "bundled"
        localLLMBaseURL = UserDefaults.standard.string(forKey: "localLLMBaseURL") ?? "http://localhost:8080/v1"
        localLLMModel = UserDefaults.standard.string(forKey: "localLLMModel") ?? ""
        bundledLLMModel = UserDefaults.standard.string(forKey: "bundledLLMModel") ?? "qwen2.5-0.5b-instruct"
        // Agent-CLI provider (MAK-44) — used only when llmProvider == "agentCLI".
        // Default to the Claude preset so opting in works with zero extra typing.
        agentCLIPreset = UserDefaults.standard.string(forKey: "agentCLIPreset") ?? "claude"
        agentCLICustomCommand = UserDefaults.standard.string(forKey: "agentCLICustomCommand") ?? ""
        agentCLICustomArgsText = UserDefaults.standard.string(forKey: "agentCLICustomArgsText") ?? ""
        agentCLITimeout = UserDefaults.standard.object(forKey: "agentCLITimeout") as? Double ?? 30.0
        instructionChainEnabled = UserDefaults.standard.object(forKey: "instructionChainEnabled") as? Bool ?? true
        scriptPostProcessorEnabled = UserDefaults.standard.object(forKey: "scriptPostProcessorEnabled") as? Bool ?? false
        scriptPostProcessorPath = UserDefaults.standard.string(forKey: "scriptPostProcessorPath") ?? ""
        outputTargetSettings = Self.loadOutputTargetSettings()
        perAppModesEnabled = UserDefaults.standard.object(forKey: "perAppModesEnabled") as? Bool ?? false
        historyEnabled = UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true
        // Agent Bridge (M8) — default off; started at launch via startAgentBridgeIfEnabled().
        // (Property observers don't fire during init, so the lazy server isn't
        // touched here — it starts only from the explicit launch call.)
        agentBridgeEnabled = UserDefaults.standard.bool(forKey: "agentBridgeEnabled")
        agentBridgeAllowUnsignedClients = UserDefaults.standard.bool(forKey: "agentBridgeAllowUnsignedClients")
        agentBridgeAllowCloudAI = UserDefaults.standard.bool(forKey: "agentBridgeAllowCloudAI")
        // Default-ON (silence auto-stop is the expected agent-dictate UX).
        agentBridgeSilenceAutoStop = UserDefaults.standard.object(forKey: "agentBridgeSilenceAutoStop") as? Bool ?? true
        // Default-ON: the chime and spoken question are the whole point of an
        // agent handing you the mic — you should notice and be able to answer
        // without staring at the overlay. Users can turn either off.
        agentBridgeChimeEnabled = UserDefaults.standard.object(forKey: "agentBridgeChimeEnabled") as? Bool ?? true
        agentBridgeSpeakQuestionEnabled = UserDefaults.standard.object(forKey: "agentBridgeSpeakQuestionEnabled") as? Bool ?? true
        agentClients = AgentClientStore.load()
        profiles = AppProfileStore.load()
        history = TranscriptionHistoryStore.load()
        customVocabularyEnabled = UserDefaults.standard.object(forKey: "customVocabularyEnabled") as? Bool ?? true
        vocabulary = VocabularyStore.load()
        correctionLearningEnabled = UserDefaults.standard.object(forKey: "correctionLearningEnabled") as? Bool ?? true
        correctionProposals = CorrectionProposalStore.load()
        didCompleteOnboarding = UserDefaults.standard.bool(forKey: "didCompleteOnboarding")

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
        translationService = OpenAITranslationService()

        wireFileEngineCallbacks()
        wireStreamingEngineCallbacks(whisperKitStreamEngine)

        audioRecorder = injectedAudioCapture ?? AudioRecorder()
        audioRecorder.autoGainEnabled = autoGainEnabled
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
        hotkeyMonitor.refineKey = refineKey
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
        hotkeyMonitor.onHotkeyDown = { [weak self] in
            Task { @MainActor in
                self?.startDictation()
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
    private func wireStreamingEngineCallbacks(_ engine: StreamingTranscriptionEngine) {
        engine.onPartial = { [weak self] text in
            Task { @MainActor in self?.handleAppleSpeechPartial(text) }
        }
        engine.onFinal = { [weak self] text in
            Task { @MainActor in self?.handleAppleSpeechFinal(text) }
        }
        engine.onError = { [weak self] message in
            Task { @MainActor in
                guard let self, self.isAppleSpeechSession else { return }
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

    /// Publish a new audio level for the overlay AND drive the agent-session
    /// silence detector. The single place every level source (AVAudioRecorder
    /// metering + the streaming engine taps) funnels through, so the VAD sees
    /// every sample regardless of which capture path is live. `vadLevel` is the
    /// sample on the ABSOLUTE AudioLevel curve — WhisperKit's display level is
    /// silence-referenced and would make the fixed gates meaningless.
    @MainActor
    private func updateAudioLevel(_ level: Float, vadLevel: Float) {
        audioLevel = level
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
        whisperWorkerStatus = "Not started"
        // `warmWhisperServerIfPossible()` is engine-aware: it warms WhisperKit's
        // CoreML model up front, warms whisper.cpp's server only for the serverAPI
        // backend, and no-ops for Apple Speech — so only the selected backend ever
        // loads a model (no dual-engine residency).
        warmWhisperServerIfPossible()
    }

    // MARK: - Actions

    func startDictation() {
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
            cancelDictation()
            // Start the user's dictation on the NEXT main-actor turn, not this
            // one: the cancel above already enqueued the dead session's deferred
            // recorder/engine hops (.stopped clears isArming/isRecording with no
            // session fence, and a streaming engine can have a partial in
            // flight). One deferred turn lets those drain against dead state
            // instead of clobbering the successor session mid-arming.
            pendingPreemptStart = true
            Task { @MainActor in
                guard self.pendingPreemptStart else { return } // stop/cancel in the gap consumed it
                self.pendingPreemptStart = false
                self.startDictation()
            }
            return
        }

        guard !isRecording, !isTranscribing else { return }
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
        // Apply a per-app profile (if any) BEFORE routing, so an override of
        // outputMode/language/AI-cleanup affects the whole session including the
        // streaming-vs-recording decision below. Restored when the session ends.
        applyProfileForFrontmostApp()
        let liveMode = outputMode == "liveChunks" || outputMode == "preview"
        // Streaming backends (Apple Speech always; WhisperKit when a live preview is
        // wanted) run the real-time path. Both go through the shared streaming
        // session starter; `activeStreamingEngine` picks the recognizer.
        if transcriptionEngine == "appleSpeech" || (transcriptionEngine == "whisperKit" && liveMode) {
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

    func cancelDictation() {
        // An Esc (or shutdown) in the preempt gap also cancels the queued
        // replacement start — the user is backing out entirely.
        pendingPreemptStart = false
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
        work: @escaping (_ done: @escaping () -> Void) -> Void,
        fallback: @escaping () -> Void
    ) {
        refineDebug("ensureBundledLLMReady ENTER provider=\(llmProvider) sessionID=\(activeSessionID.uuidString.prefix(8))")
        guard llmProvider == "bundled" else {
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
        return ModelStorage.sorted(items)
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
            }
            self.whisperKitDownloadingModel = nil
            self.whisperKitDownloadProgress = 0
        }
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
        streamingUsesWhisperKit = transcriptionEngine == "whisperKit"
        appleLiveInsertedText = ""
        appleDidCompleteFinal = false
        // Keep the "Starting..." arming cue from beginSession until the recognizer
        // is actually live. Both backends have a startup gap: async mic grant (plus
        // Speech-auth for Apple), then engine start.
        let sessionID = activeSessionID
        let usesWhisperKit = streamingUsesWhisperKit
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
            // Abort if the hotkey was released or the session cancelled before grant.
            guard sessionID == self.activeSessionID, !self.pendingStop else {
                self.isAppleSpeechSession = false
                self.abortSessionBeforeStart()
                return
            }
            do {
                engine.selectDevice(micID)
                try engine.start(language: self.engineLanguageSetting)
                self.isArming = false
                self.isRecording = true
                self.statusMessage = "Listening..."
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
                // WhisperKit needs only the mic; Apple Speech also needs Speech auth.
                if usesWhisperKit {
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
                self.handleAppleSpeechFinal(self.streamingText)
            }
        }
    }

    private func handleAppleSpeechPartial(_ rawText: String) {
        guard isAppleSpeechSession else { return }
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

    private func handleAppleSpeechFinal(_ rawText: String) {
        guard isAppleSpeechSession, !appleDidCompleteFinal else { return }
        appleDidCompleteFinal = true
        let finalText = postProcess(rawText.isEmpty ? streamingText : rawText, isFinalTranscript: true)

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
                // The hotkey may have been released (or the session cancelled) before this
                // callback ran. Abort cleanly so recording never starts unattended.
                guard sessionID == self.activeSessionID, !self.pendingStop else {
                    self.abortSessionBeforeStart()
                    return
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

                self.startTranscription(path: path, kind: .final)
            }
        }
    }

    /// Optional live mode: record chunks, transcribe each, paste stable-ish chunks.
    func startStreaming() {
        guard !isRecording, !isTranscribing else { return }
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
                // Abort if the hotkey was released or the session cancelled before grant.
                guard sessionID == self.activeSessionID, !self.pendingStop else {
                    self.abortSessionBeforeStart()
                    return
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
                    recorder.startStreamingOnSilence(onChunk: onChunk)
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
        openAIEnhancementEnabledForSession = openAIEnhancementEnabled
        isLiveChunkSession = streaming
        // Preview mode captures via the chunk pipeline but defers pasting.
        isPreviewSession = streaming && outputMode == "preview"
        // Agent-initiated sessions return the transcript to the caller instead of
        // pasting. Snapshot from the initiator (set by the bridge before this call)
        // so a mid-session change can't alter the paste-vs-return disposition.
        suppressOutput = sessionInitiator.isAgent
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
            prompt: customVocabularyEnabled ? vocabulary.whisperPrompt : ""
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
                model: self.llmModel
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
                        textToInsert = cleaned.isEmpty ? item : cleaned
                        self.translationStatus = cleaned.isEmpty ? "LLM returned empty chunk" : "Rephrased"
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
            streamingText = text
            sessionOutcome = .completed(text: text)
            recordHistory(text)
            recordStats(text)
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
            // Output target (MAK-11..14): when the user has selected AND configured a
            // non-focused sink (file / Shortcut / webhook), route the FINAL text
            // there; otherwise keep the exact historical focused-app insert. Keeping
            // the default path a bare `textOutput.insert` (not wrapped in the router)
            // means the common case is byte-for-byte unchanged — no regression.
            let effectiveKind = OutputTargetResolver.effectiveKind(outputTargetSettings)
            if effectiveKind == .focusedApp {
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
                let router = buildOutputRouter(effectiveKind: effectiveKind, focusedAppInsertion: insertion)
                let payload = OutputPayload(
                    text: text,
                    language: outputLanguageForCleaning,
                    targetAppBundleID: targetApplication?.bundleIdentifier,
                    isLiveChunk: false
                )
                router.route(payload) { _ in }
            }
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
        }

        // The actually-inserted text is the canonical result — update lastTranscription
        // so the tray "copy" and history match what was pasted (the refined / enhanced
        // / script-processed text), not step-1's raw transcript.
        lastTranscription = text

        recordHistory(text)
        recordStats(text)

        let finalWasEnhanced = shouldEnhanceCurrentSession
            && (!isLiveChunkSession || isPreviewSession)
        statusMessage = finalWasEnhanced
            ? "Enhanced: \(text.prefix(50))..."
            : "Done: \(originalText.prefix(50))..."
        finishSessionUI(delay: 0.8)
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
        UserDefaults.standard.set(data, forKey: "outputTargetSettings")
    }

    /// Load the persisted output-target settings, defaulting to focused-app (today's
    /// behavior) when absent or unreadable.
    private static func loadOutputTargetSettings() -> OutputTargetSettings {
        guard let data = UserDefaults.standard.data(forKey: "outputTargetSettings"),
              let decoded = try? JSONDecoder().decode(OutputTargetSettings.self, from: data)
        else { return OutputTargetSettings() }
        return decoded
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
            // (isRecording flips true only after the async grant + engine start).
            if !self.isRecording && !self.isTranscribing && !self.sessionActive && !self.isArming {
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
            vocabulary.substitutions.append(accepted)
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
                // must not be hidden by this stale task.
                if !self.isRecording && !self.isTranscribing && !self.sessionActive && !self.isArming {
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
        openAIEnhancementEnabled = false
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

        triggerMode = "fn"
        refineKey = RefineKey.defaultKey.rawValue
        microphoneID = ""
        autoGainEnabled = true
        language = "auto"
        translateToEnglish = false

        transcriptionEngine = Self.defaultTranscriptionEngine
        whisperKitModel = "openai_whisper-small"
        modelName = "base"
        whisperBinaryPath = Self.preferredWhisperCLIPath(savedPath: "")
        whisperBackend = "serverAPI"
        liveChunkDuration = 2.0
        pauseBasedLiveChunksEnabled = false

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
        fileTaggingEnabled = false
        customVocabularyEnabled = true
        correctionLearningEnabled = true
        perAppModesEnabled = false
        historyEnabled = true

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

    // MARK: - Per-app profiles

    /// If per-app modes are on and the frontmost app has a profile, temporarily
    /// apply its non-nil overrides to the global settings, backing up originals.
    private func applyProfileForFrontmostApp() {
        guard perAppModesEnabled, profileOverrideBackup == nil else { return }
        let frontmost = currentTextTargetApplication()
        guard let profile = AppProfileStore.profile(for: frontmost?.bundleIdentifier, in: profiles) else { return }

        // Back up the overridable globals.
        profileOverrideBackup = (language: language, translateToEnglish: translateToEnglish,
                                 outputMode: outputMode, aiCleanup: openAIEnhancementEnabled)

        // Resolve the effective settings via the pure resolver (single source of
        // truth for the "en" → translate remap + inherit-vs-override matrix), then
        // apply. Don't persist the overridden values; they're session-scoped.
        suppressSettingsPersistence = true
        let resolved = ProfileResolver.resolve(profile: profile, over: .init(
            language: language, translateToEnglish: translateToEnglish,
            outputMode: outputMode, aiCleanupEnabled: openAIEnhancementEnabled
        ))
        language = resolved.language
        translateToEnglish = resolved.translateToEnglish
        outputMode = resolved.outputMode
        openAIEnhancementEnabled = resolved.aiCleanupEnabled
    }

    /// Restore any settings a profile overrode for the just-finished session.
    private func restoreProfileOverridesIfNeeded() {
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
        UserDefaults.standard.set(language, forKey: "language")
        UserDefaults.standard.set(translateToEnglish, forKey: "translateToEnglish")
        UserDefaults.standard.set(outputMode, forKey: "outputMode")
        UserDefaults.standard.set(openAIEnhancementEnabled, forKey: "openAIEnhancementEnabled")
    }

    // MARK: - History

    /// Record a completed transcription (newest first), trimming to the cap.
    private func recordHistory(_ text: String) {
        guard historyEnabled else { return }
        // Defensive privacy guard: never persist a transcript if a secure field is
        // focused at record time. Fail-open on detection errors.
        guard !SecureFieldDetector.focusedFieldIsSecure() else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = TranscriptionEntry(
            text: trimmed,
            date: Date(),
            appBundleID: targetApplication?.bundleIdentifier,
            appName: targetApplication?.localizedName
        )
        history.insert(entry, at: 0)
        if history.count > TranscriptionHistoryStore.maxEntries {
            history = Array(history.prefix(TranscriptionHistoryStore.maxEntries))
        }
        TranscriptionHistoryStore.save(history)
    }

    func clearHistory() {
        history = []
        TranscriptionHistoryStore.save(history)
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
        let model: String? = transcriptionEngine == "whisperKit" ? whisperKitModel
            : (transcriptionEngine == "appleSpeech" ? nil : modelName)
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
        #if OPENWHISP_INSTRUMENTATION
        lastDictationEvent = event
        #endif
    }

    func copyHistoryEntry(_ entry: TranscriptionEntry) {
        textOutput.setClipboard(entry.text)
    }

    // MARK: - Config import / export

    /// Snapshot the user-editable config (profiles, vocabulary) as a portable
    /// bundle. History and secrets are intentionally excluded.
    func exportConfig() -> ConfigBundle {
        ConfigBundle(
            profiles: profiles,
            vocabulary: vocabulary
        )
    }

    /// Apply the sections present in `bundle` to the live settings (each setter's
    /// didSet persists it). Sections absent from the bundle are left untouched, so
    /// a vocab-only pack only changes vocabulary. Returns the bundle's summary for
    /// user feedback.
    @discardableResult
    func applyConfig(_ bundle: ConfigBundle) -> String {
        if let importedProfiles = bundle.profiles {
            profiles = importedProfiles
        }
        if let importedVocab = bundle.vocabulary {
            vocabulary = importedVocab
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
        [BridgeWire.Capability.dictate, BridgeWire.Capability.refine, BridgeWire.Capability.history]
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
            self.agentSilenceDetector = self.agentBridgeSilenceAutoStop ? SilenceAutoStop() : nil

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
