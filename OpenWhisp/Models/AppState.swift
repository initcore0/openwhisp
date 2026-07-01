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

    @Published var triggerMode: String {
        didSet {
            UserDefaults.standard.set(triggerMode, forKey: "triggerMode")
            hotkeyMonitor?.triggerMode = triggerMode
        }
    }

    @Published var outputMode: String {
        didSet { persist(outputMode, "outputMode") }
    }

    @Published var showOverlay: Bool {
        didSet { UserDefaults.standard.set(showOverlay, forKey: "showOverlay") }
    }

    /// Visual style of the overlay's voice indicator (Settings → Appearance).
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
            // "preview" so behavior matches the (filtered) Settings options.
            if transcriptionEngine == "whisperKit", outputMode == "liveChunks" {
                outputMode = "preview"
            }
            // Rebuild + rewire the file engine so switching backends takes effect
            // without an app restart (the Whisper-family path uses `whisperEngine`).
            rebuildFileEngine()
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
            if openAIEnhancementEnabled { warmLlamaServerIfPossible() }
            else { llamaEngine?.stopServer() }
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
                ensureLLMModelExists()
                warmLlamaServerIfPossible()
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
                if bundledLLMModelInstalled {
                    warmLlamaServerIfPossible()
                } else {
                    ensureLLMModelExists()
                }
            }
        }
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
    private var downloadingLLMModelPath: String?

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

    /// Bias whisper recognition toward custom terms. Default-on; harmless when
    /// the vocabulary is empty (no prompt is sent).
    @Published var customVocabularyEnabled: Bool {
        didSet { UserDefaults.standard.set(customVocabularyEnabled, forKey: "customVocabularyEnabled") }
    }

    /// User's custom vocabulary (bias terms + heard→correct substitutions).
    /// Persisted to a JSON file in Application Support via VocabularyStore.
    @Published var vocabulary: Vocabulary {
        didSet { VocabularyStore.save(vocabulary) }
    }


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
    private var openAIEnhancementEnabledForSession = false

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
    /// Failsafe: if a refine engages but nothing progresses (no speech captured),
    /// recover after this timeout so the overlay can never get permanently stuck.
    private var refineWatchdog: DispatchWorkItem?
    private let refineWatchdogTimeout: TimeInterval = 4
    /// True while an instruction-capture session is active (distinguishes the refine
    /// recording from a normal dictation in the shared start/stop plumbing).
    private var isRefineSession = false
    /// The user released the refine chord before the recognizer went live. The
    /// launch path honors this to stop cleanly once live, giving a short hold a
    /// chance to capture instead of aborting empty (the "nothing happens" bug).
    private var refineStopRequested = false
    /// Minimum time the instruction recognizer stays live before a release actually
    /// stops it, so a quick chord tap still captures a word or two despite the
    /// recognizer's ~1s startup latency.
    private let refineMinListen: TimeInterval = 0.6
    private var refineListenStartedAt: TimeInterval?

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
    private var downloadingModelPath: String?

    /// Global setting values saved before a per-app profile temporarily overrode
    /// them for the current session, so they can be restored when it ends.
    private var profileOverrideBackup: (language: String, outputMode: String, aiCleanup: Bool)?

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
        shouldEnhanceCurrentSession && outputMode == "liveChunks" && openAIEnhancementMode == "rephrase"
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

    /// Whether the active LLM provider is configured enough to call.
    var llmConfigured: Bool {
        switch llmProvider {
        case "bundled":
            // Configured only once the selected model is actually on disk.
            return FileManager.default.fileExists(atPath: selectedLLMModelPath())
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

    private init(
        secretStore: SecretStore = KeychainStore(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLogin(),
        textOutput: TextOutput = TextInserter()
    ) {
        self.secretStore = secretStore
        self.launchAtLoginService = launchAtLoginService
        self.textOutput = textOutput
        let savedWhisperBinaryPath = UserDefaults.standard.string(forKey: "whisperBinaryPath") ?? ""
        whisperBinaryPath = Self.preferredWhisperCLIPath(savedPath: savedWhisperBinaryPath)

        // Default first-run model is "tiny" (39 MB) for a near-instant first
        // success during onboarding. Users can upgrade to higher-quality models
        // from Settings → Quality at any time.
        let savedModel = UserDefaults.standard.string(forKey: "modelName") ?? "tiny"
        let fileName = Self.modelFileName(for: savedModel)
        modelName = savedModel
        let savedModelPath = UserDefaults.standard.string(forKey: "modelPath") ?? ""
        modelPath = Self.preferredModelPath(savedPath: savedModelPath, fileName: fileName)
        microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? ""
        language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        triggerMode = UserDefaults.standard.string(forKey: "triggerMode") ?? "fn"
        outputMode = UserDefaults.standard.string(forKey: "outputMode") ?? "preview"
        showOverlay = UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true
        voiceIndicatorStyle = VoiceIndicatorStyle.from(UserDefaults.standard.string(forKey: "voiceIndicatorStyle"))
        launchAtLogin = launchAtLoginService.isEnabled
        restoreClipboard = UserDefaults.standard.object(forKey: "restoreClipboard") as? Bool ?? false
        insertionMode = UserDefaults.standard.string(forKey: "insertionMode") ?? "auto"
        addTrailingSpace = UserDefaults.standard.object(forKey: "addTrailingSpace") as? Bool ?? false
        autoGainEnabled = UserDefaults.standard.object(forKey: "autoGainEnabled") as? Bool ?? true
        smartFormattingEnabled = UserDefaults.standard.object(forKey: "smartFormattingEnabled") as? Bool ?? true
        spokenPunctuationEnabled = UserDefaults.standard.object(forKey: "spokenPunctuationEnabled") as? Bool ?? true
        fillerRemovalEnabled = UserDefaults.standard.object(forKey: "fillerRemovalEnabled") as? Bool ?? true
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
        llmProvider = UserDefaults.standard.string(forKey: "llmProvider") ?? "openai"
        localLLMBaseURL = UserDefaults.standard.string(forKey: "localLLMBaseURL") ?? "http://localhost:8080/v1"
        localLLMModel = UserDefaults.standard.string(forKey: "localLLMModel") ?? ""
        bundledLLMModel = UserDefaults.standard.string(forKey: "bundledLLMModel") ?? "qwen2.5-0.5b-instruct"
        instructionChainEnabled = UserDefaults.standard.object(forKey: "instructionChainEnabled") as? Bool ?? true
        scriptPostProcessorEnabled = UserDefaults.standard.object(forKey: "scriptPostProcessorEnabled") as? Bool ?? false
        scriptPostProcessorPath = UserDefaults.standard.string(forKey: "scriptPostProcessorPath") ?? ""
        perAppModesEnabled = UserDefaults.standard.object(forKey: "perAppModesEnabled") as? Bool ?? false
        historyEnabled = UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true
        profiles = AppProfileStore.load()
        history = TranscriptionHistoryStore.load()
        customVocabularyEnabled = UserDefaults.standard.object(forKey: "customVocabularyEnabled") as? Bool ?? true
        vocabulary = VocabularyStore.load()
        didCompleteOnboarding = UserDefaults.standard.bool(forKey: "didCompleteOnboarding")

        wireUpServices()
        overlayController = OverlayWindowController(appState: self)
        hotkeyMonitor.start()
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
        whisperEngine = Self.makeFileEngine(for: transcriptionEngine, model: modelName, whisperKitModel: whisperKitModel)
        appleSpeechEngine = AppleSpeechEngine()
        whisperKitStreamEngine = WhisperKitStreamingEngine(modelName: whisperKitModel)
        translationService = OpenAITranslationService()

        wireFileEngineCallbacks()
        wireStreamingEngineCallbacks(whisperKitStreamEngine)

        audioRecorder = AudioRecorder()
        audioRecorder.autoGainEnabled = autoGainEnabled
        audioRecorder.onStateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .recording:
                    // Capture is now genuinely live: leave the arming window so the
                    // overlay flips from "starting" to the green "speak now" cue.
                    self.isArming = false
                    self.isRecording = true
                    self.statusMessage = self.outputMode == "liveChunks" ? "Listening..." : "Recording..."
                case .stopped, .idle:
                    self.isArming = false
                    self.isRecording = false
                case .error(let msg):
                    self.isArming = false
                    self.error = msg
                    self.statusMessage = "Error"
                    self.isRecording = false
                    self.finishSessionUI()
                }
            }
        }
        audioRecorder.onLevelChanged = { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        wireStreamingEngineCallbacks(appleSpeechEngine)

        hotkeyMonitor = HotkeyMonitor()
        hotkeyMonitor.triggerMode = triggerMode
        hotkeyMonitor.onPermissionStateChanged = { [weak self] isGranted in
            Task { @MainActor in
                self?.inputMonitoringPermissionLabel = isGranted ? "Granted" : "Needs permission"
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
        hotkeyMonitor.onRefineDown = { [weak self] in
            Task { @MainActor in
                self?.startRefine()
            }
        }
        hotkeyMonitor.onRefineUp = { [weak self] in
            Task { @MainActor in
                self?.stopRefine()
            }
        }
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
                self.finishSessionUI()
            }
        }
        engine.onLevelChanged = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
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
        // Esc while a refine is engaged (waiting for step-1 or the instruction):
        // abort the flow without inserting anything.
        if refineFlow.isActive && !isRecording && !isTranscribing && !sessionActive {
            cancelRefineWatchdog()
            refineFlow.reset()
            syncRefineUI()
            statusMessage = "Cancelled"
            finishSessionUI()
            return
        }
        guard isRecording || isTranscribing || sessionActive else { return }
        activeSessionID = UUID()
        sessionActive = false
        pendingStop = false
        cancelRefineWatchdog()
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
        whisperEngine.stopServer()
        llamaEngine?.stopServer()
        hotkeyMonitor.stop()
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
        isLLMModelDownloading && downloadingLLMModelPath == bundledModelPath(id)
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

    private func ensureBundledLLMReady(
        statusWhileLoading: String = "Loading local model…",
        quiesceWhisper: Bool = false,
        work: @escaping () -> Void,
        fallback: @escaping () -> Void
    ) {
        refineDebug("ensureBundledLLMReady ENTER provider=\(llmProvider) sessionID=\(activeSessionID.uuidString.prefix(8))")
        guard llmProvider == "bundled" else {
            refineDebug("ensureBundledLLMReady: non-bundled -> work() immediately")
            work()
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
                guard sessionID == self.activeSessionID else {
                    engine.requestFinished()
                    return
                }
                switch result {
                case .success:
                    // requestFinished is called by the refinement completion path
                    // once processFinalText returns; keep the request open through it.
                    work()
                    engine.requestFinished()
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

        guard downloadingLLMModelPath != path else { return }
        guard let entry = Self.bundledLLMManifest()?.first(where: { $0.id == bundledLLMModel }),
              let url = URL(string: entry.url) else {
            llmModelDownloadFailed = true
            llmModelDownloadStatus = "No download URL for \(bundledLLMModel)"
            return
        }

        let fileName = entry.file
        downloadingLLMModelPath = path
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
                    self.isLLMModelDownloading = false
                    self.downloadingLLMModelPath = nil
                    self.llmModelDownloadProgress = 1.0
                    self.llmModelDownloadFailed = false
                    self.llmModelDownloadStatus = "Installed: \(fileName)"
                    self.warmLlamaServerIfPossible()
                }
            } catch {
                await MainActor.run {
                    self.isLLMModelDownloading = false
                    self.downloadingLLMModelPath = nil
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
        downloadingLLMModelPath = nil
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
                guard let self, self.isLLMModelDownloading else { return }
                let progress = DownloadProgressFormatter.make(written: written, totalExpected: totalExpected)
                self.llmModelDownloadProgress = progress.fraction
                self.llmModelDownloadStatus = progress.label
            }
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloadedURL, to: tempURL)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Refresh the list of staged WhisperKit models (call when opening the manager).
    func refreshWhisperKitStagedModels() {
        whisperKitStagedModels = WhisperKitModelCatalog.stagedModels()
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

    func validateOpenAIKey() {
        translationStatus = "Validating..."
        error = nil
        let isLocal = llmProvider == "local"
        translationService.validate(endpoint: llmEndpoint, model: llmModel) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.translationStatus = isLocal ? "Local LLM reachable" : "OpenAI key valid"
                case .failure(let error):
                    self.translationStatus = "Validation failed"
                    self.error = "LLM validation failed: \(error.localizedDescription)"
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

        // The actual engine start, after permissions are granted.
        let launch: @MainActor () -> Void = {
            guard sessionID == self.activeSessionID else {
                self.isAppleSpeechSession = false
                self.abortSessionBeforeStart()
                return
            }
            // For a REFINE instruction session, a release before we went live must
            // NOT abort (that lost the instruction — the "nothing happens" bug):
            // start anyway, then stop cleanly after the minimum listen window so a
            // quick chord tap still captures. For normal dictation, pendingStop
            // still aborts (user changed their mind before it started).
            if self.pendingStop && !self.isRefineSession {
                self.isAppleSpeechSession = false
                self.abortSessionBeforeStart()
                return
            }
            do {
                try engine.start(language: self.language)
                self.isArming = false
                self.isRecording = true
                self.statusMessage = self.isRefineSession ? "Refine: speak your instruction…" : "Listening..."
                if self.isRefineSession {
                    self.refineListenStartedAt = ProcessInfo.processInfo.systemUptime
                    // If the chord was already released, stop after the min window.
                    if self.pendingStop || self.refineStopRequested {
                        self.pendingStop = false
                        self.refineStopRequested = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.refineMinListen) { [weak self] in
                            guard let self, self.refineStopRequested, self.isRefineSession else { return }
                            self.performRefineStop()
                        }
                    }
                }
            } catch {
                self.error = error.localizedDescription
                self.statusMessage = "Streaming Error"
                self.isAppleSpeechSession = false
                self.finishSessionUI()
            }
        }

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.error = "Microphone access denied. Check System Settings."
                    self.isAppleSpeechSession = false
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

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if self.isAppleSpeechSession && self.isTranscribing && !self.appleDidCompleteFinal {
                self.handleAppleSpeechFinal(self.streamingText)
            }
        }
    }

    private func handleAppleSpeechPartial(_ rawText: String) {
        guard isAppleSpeechSession else { return }
        let text = postProcess(rawText)
        streamingText = text
        statusMessage = text.isEmpty ? "Listening..." : "Listening..."

        guard outputMode == "liveChunks", !text.isEmpty else { return }
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
        if outputMode == "liveChunks", !SecureFieldDetector.focusedFieldIsSecure() {
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
        cancelRefineWatchdog()
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
        audioLevel = 0
        recordingElapsed = 0
        recordingStartedAt = Date()
        transcriptionStartedAt = nil
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
        if showOverlay {
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
            language: language,
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

        ensureBundledLLMReady(work: { [weak self] in
            guard let self else { return }
            self.translationService.processFinalText(
                text: item,
                mode: self.refinementMode("rephrase"),
                targetLanguage: self.translationTargetLanguage,
                endpoint: self.llmEndpoint,
                model: self.llmModel
            ) { [weak self] result in
                Task { @MainActor in
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

        // If a refine is engaged, this finished session's transcript is EITHER the
        // late step-1 dictation (machine still awaiting step-1) OR the spoken
        // instruction (step-1 already resolved). Feed the right event; the machine
        // owns all the empty/wedge/ordering decisions (see RefineFlow).
        if refineFlow.isActive {
            if refineExpectsStep1 {
                refineDebug("completeFinalText -> step1Finalized \"\(finalText.prefix(20))\"")
                // Keep the working cue up while we still wait for the instruction.
                isTranscribing = true
                feedRefineTranscript(finalText, isInstruction: false)
            } else {
                refineDebug("completeFinalText -> instructionFinalized \"\(finalText.prefix(20))\"")
                isTranscribing = true
                feedRefineTranscript(finalText, isInstruction: true)
            }
            return
        }

        guard !finalText.isEmpty else {
            isTranscribing = false
            statusMessage = "No speech detected"
            finishSessionUI()
            return
        }

        lastTranscription = finalText
        streamingText = finalText

        // Run a whole-text OpenAI pass for finalOnly OR preview mode when
        // enhancement is enabled. Otherwise insert once.
        let enhanceWholeText = shouldEnhanceCurrentSession
            && (outputMode == "finalOnly" || outputMode == "preview")
        guard enhanceWholeText else {
            isTranscribing = false
            // Paste immediately — refine has its own dedicated key now, so there's
            // no re-press to disambiguate and no reason to hold the paste. Remember
            // the text so the Refine key can act on "what I just dictated".
            rememberLastDictation(finalText)
            insertCompletedText(finalText, originalText: finalText)
            return
        }

        statusMessage = openAIEnhancementMode == "rephrase" ? "Polishing..." : "Improving..."
        translationStatus = statusMessage
        // Capture the session so a cancel (Esc) or new session started while the
        // LLM call is in flight causes this callback to be ignored — otherwise
        // it would paste/clobber the clipboard after the session was cancelled.
        let sessionID = activeSessionID

        ensureBundledLLMReady(quiesceWhisper: true, work: { [weak self] in
            guard let self else { return }
            self.translationService.processFinalText(
                text: finalText,
                mode: self.refinementMode(self.openAIEnhancementMode),
                targetLanguage: self.translationTargetLanguage,
                endpoint: self.llmEndpoint,
                model: self.llmModel
            ) { [weak self] result in
                Task { @MainActor in
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
            }
        }, fallback: { [weak self] in
            guard let self, sessionID == self.activeSessionID else { return }
            self.isTranscribing = false
            self.openAIEnhancementEnabledForSession = false
            self.insertCompletedText(finalText, originalText: finalText)
            self.statusMessage = "Built-in model unavailable; inserted local text"
        })
    }

    // MARK: - Instruction chaining (dedicated-key refine flow)
    //
    // Gesture: hold the dedicated Refine chord (Fn+Ctrl) and speak an instruction,
    // then release. It refines the current SELECTION if any, else the LAST
    // dictation. The lifecycle is driven by the pure `RefineFlow` state machine;
    // these methods only (a) feed it events and (b) execute the effects it returns.

    /// Record a completed normal dictation so the Refine key can act on it later.
    private func rememberLastDictation(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastDictationText = t.isEmpty ? nil : text
    }

    /// Refine key PRESSED (dedicated Fn+Ctrl chord). Resolve what to refine —
    /// the current selection if any, else the last dictation we still hold — engage
    /// the machine, and start capturing the spoken instruction. Held-to-talk: the
    /// instruction is whatever is spoken until stopRefine.
    func startRefine() {
        guard InstructionChain.isAvailable(outputMode: outputMode, llmConfigured: llmConfigured, enabled: instructionChainEnabled) else {
            statusMessage = "Set up an AI provider to use Refine"
            return
        }
        // Don't collide with an active dictation or an in-flight refine.
        guard !isRecording, !refineFlow.isActive else { return }

        let selection = SecureFieldDetector.focusedFieldIsSecure()
            ? nil
            : SelectionReader.readSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let step1: String?
        let fromSelection: Bool
        if let sel = selection, !sel.isEmpty {
            step1 = sel
            fromSelection = true
        } else if let last = lastDictationText?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            step1 = last
            fromSelection = false
        } else {
            statusMessage = "Nothing to refine — dictate or select text first"
            return
        }
        refineDebug("startRefine step1=\"\(step1!.prefix(20))\" fromSelection=\(fromSelection)")
        isRefineSession = true
        refineStopRequested = false
        refineListenStartedAt = nil
        executeRefineEffects(refineFlow.handle(.engage(step1: step1, fromSelection: fromSelection)))
    }

    /// Refine key RELEASED — stop capturing the instruction. Its final transcript
    /// is fed to the machine as `instructionFinalized` (see completeFinalText).
    /// Guards the two races that made refine feel broken:
    ///  - released before the recognizer went live → defer the stop (refineStopRequested)
    ///    so the launch path stops it cleanly once live instead of losing the utterance;
    ///  - released within refineMinListen of going live → hold on until the window
    ///    elapses, so a quick tap still captures a word or two.
    func stopRefine() {
        refineDebug("stopRefine (isRecording=\(isRecording) live=\(refineListenStartedAt != nil))")
        guard isRefineSession else { return }

        // Not live yet — remember the release; the launch path will honor it.
        guard isRecording, let liveAt = refineListenStartedAt else {
            refineStopRequested = true
            return
        }
        let listened = ProcessInfo.processInfo.systemUptime - liveAt
        if listened < refineMinListen {
            // Give a quick tap a minimum listen window before actually stopping.
            refineStopRequested = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (refineMinListen - listened)) { [weak self] in
                guard let self, self.refineStopRequested, self.isRefineSession else { return }
                self.performRefineStop()
            }
            return
        }
        performRefineStop()
    }

    private func performRefineStop() {
        refineStopRequested = false
        guard isRecording else { return }
        if isAppleSpeechSession { stopAppleSpeech(); return }
        if isStreamingSession { stopStreaming() } else { stopRecording() }
    }

    /// Feed a completed transcript into the refine machine. `isInstruction` picks
    /// which event: the instruction utterance vs. a late step-1 dictation final.
    private func feedRefineTranscript(_ text: String, isInstruction: Bool) {
        let event: RefineFlow.Event = isInstruction ? .instructionFinalized(text) : .step1Finalized(text)
        executeRefineEffects(refineFlow.handle(event))
    }

    /// Whether the currently-finishing session is the refine INSTRUCTION capture.
    /// True while the machine is capturing and step-1 is already resolved — the
    /// next final is the instruction. If step-1 is still nil, the next final is
    /// step-1 itself.
    private var refineExpectsInstruction: Bool {
        if case .capturing(let step1, _) = refineFlow.state { return step1 != nil }
        return false
    }
    private var refineExpectsStep1: Bool {
        if case .capturing(let step1, _) = refineFlow.state { return step1 == nil }
        return false
    }

    /// Perform the state machine's effects. This is the ONLY place refine side
    /// effects happen, so the sequencing is in one auditable spot.
    private func executeRefineEffects(_ effects: [RefineFlow.Effect]) {
        syncRefineUI()
        for effect in effects {
            switch effect {
            case .startInstructionCapture:
                refineDebug("effect: startInstructionCapture")
                isRecording = false
                streamingText = ""
                statusMessage = "Refine: speak your instruction…"
                let liveMode = outputMode == "liveChunks" || outputMode == "preview"
                if transcriptionEngine == "appleSpeech" || (transcriptionEngine == "whisperKit" && liveMode) {
                    startStreamingSession()
                } else {
                    startRecording()
                }
                armRefineWatchdog()

            case let .runLLM(step1, instruction):
                refineDebug("effect: runLLM step1=\"\(step1.prefix(20))\" instr=\"\(instruction.prefix(20))\"")
                cancelRefineWatchdog()
                applyRefineLLM(instruction: instruction, to: step1)

            case let .insert(text, replacingSelection):
                refineDebug("effect: insert replacingSelection=\(replacingSelection)")
                cancelRefineWatchdog()
                isTranscribing = false
                insertCompletedText(text, originalText: text)

            case let .finishQuietly(status):
                refineDebug("effect: finishQuietly \(status)")
                cancelRefineWatchdog()
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

    /// Keep the published overlay cue in sync with the machine, and tidy the
    /// instruction-session flags once the flow goes inactive so a later normal
    /// dictation is never misclassified as a refine capture.
    private func syncRefineUI() {
        refineArmed = refineFlow.isActive
        if !refineFlow.isActive {
            isRefineSession = false
            refineStopRequested = false
            refineListenStartedAt = nil
        }
    }

    /// Failsafe: if a refine engages but nothing progresses (no speech captured),
    /// recover after a timeout so the overlay can never get permanently stuck. The
    /// machine's `isApplying` distinguishes a genuine in-flight LLM call from a
    /// wedge; we also leave it alone while the user is still recording.
    private func armRefineWatchdog() {
        refineWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.refineFlow.isActive, !self.refineFlow.isApplying, !self.isRecording else { return }
            self.refineDebug("refineWatchdog FIRED — recovering stuck refine/overlay")
            self.executeRefineEffects(self.refineFlow.handle(.abort))
        }
        refineWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + refineWatchdogTimeout, execute: work)
    }

    private func cancelRefineWatchdog() {
        refineWatchdog?.cancel()
        refineWatchdog = nil
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

        ensureBundledLLMReady(statusWhileLoading: "Refining…", quiesceWhisper: true, work: { [weak self] in
            guard let self else { return }
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
            streamingText = ""
            currentSessionText = ""
            statusMessage = "Won't dictate into a password field"
            finishSessionUI()
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
            textOutput.insert(
                insertion,
                mode: currentInsertionMode,
                restoreClipboard: restoreClipboard
            ) { [weak self] outcome in
                // If the insert couldn't be confirmed, the text was left on the
                // clipboard — tell the user so it isn't silently lost. (Arrives after
                // the success status below; overrides it only on fallback.)
                guard let self, outcome == .copiedToClipboard else { return }
                self.showClipboardFallbackNotice()
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
            if !self.isRecording && !self.isTranscribing {
                self.hideOverlayNow()
            }
        }
    }
    private var clipboardFallbackToken: UUID?

    /// — the OS-independent post-processing pipeline — built from current settings.
    /// `isFinalTranscript` enables the trailing meta-instruction strip (only on the
    /// whole final utterance, never per chunk or on already-LLM-processed output).
    private func postProcess(_ text: String, isFinalTranscript: Bool = false) -> String {
        TranscriptCleaner(config: transcriptCleanerConfig)
            .clean(text, isFinalTranscript: isFinalTranscript)
    }

    /// Snapshot of the formatting/vocabulary settings the cleaner needs, built on
    /// each call so toggles take effect immediately.
    private var transcriptCleanerConfig: TranscriptCleaner.Config {
        TranscriptCleaner.Config(
            language: language,
            customVocabularyEnabled: customVocabularyEnabled,
            substitutions: vocabulary.substitutions,
            smartFormattingEnabled: smartFormattingEnabled,
            fillerRemovalEnabled: fillerRemovalEnabled,
            spokenPunctuationEnabled: spokenPunctuationEnabled
        )
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
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
        targetApplication = nil
        audioLevel = 0

        guard showOverlay else { return }
        guard overlayIsVisible else { return }
        if delay > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if !self.isRecording && !self.isTranscribing {
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

        // Back up the three overridable globals.
        profileOverrideBackup = (language: language, outputMode: outputMode, aiCleanup: openAIEnhancementEnabled)

        // Don't persist the overridden values; they're session-scoped.
        suppressSettingsPersistence = true
        if let lang = profile.language { language = lang }
        if let mode = profile.outputMode { outputMode = mode }
        if let ai = profile.aiCleanupEnabled { openAIEnhancementEnabled = ai }
    }

    /// Restore any settings a profile overrode for the just-finished session.
    private func restoreProfileOverridesIfNeeded() {
        guard let backup = profileOverrideBackup else { return }
        profileOverrideBackup = nil
        // Re-enable persistence so restoring the originals writes them back.
        suppressSettingsPersistence = false
        if language != backup.language { language = backup.language }
        if outputMode != backup.outputMode { outputMode = backup.outputMode }
        if openAIEnhancementEnabled != backup.aiCleanup { openAIEnhancementEnabled = backup.aiCleanup }
        // Originals were already in UserDefaults from before the override; the
        // assignments above re-persist them anyway. Belt-and-suspenders: ensure
        // they reflect the true globals.
        UserDefaults.standard.set(language, forKey: "language")
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

    func ensureModelExists() {
        guard !FileManager.default.fileExists(atPath: modelPath) else {
            modelDownloadStatus = "Installed: \(URL(fileURLWithPath: modelPath).lastPathComponent)"
            isModelDownloading = false
            modelDownloadFailed = false
            modelDownloadProgress = nil
            warmWhisperServerIfPossible()
            return
        }

        guard downloadingModelPath != modelPath else { return }
        let fileName = URL(fileURLWithPath: modelPath).lastPathComponent
        let currentModelPath = modelPath
        downloadingModelPath = currentModelPath
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
                    self.isModelDownloading = false
                    self.downloadingModelPath = nil
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
                    self.isModelDownloading = false
                    self.downloadingModelPath = nil
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
    /// (including the stale `downloadingModelPath` guard) and restarts the flow.
    func retryModelDownload() {
        guard !isModelDownloading else { return }
        downloadingModelPath = nil
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
                self?.updateModelDownloadProgress(written: written, totalExpected: totalExpected)
            }
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloadedURL, to: tempURL)
        try FileManager.default.moveItem(at: tempURL, to: destination)
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

extension URLSession {
    func downloadModel(from url: URL, to destination: URL) async throws {
        let (tempURL, _) = try await download(from: url)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}
