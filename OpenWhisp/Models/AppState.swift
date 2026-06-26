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

    @Published var transcriptionEngine: String {
        didSet { UserDefaults.standard.set(transcriptionEngine, forKey: "transcriptionEngine") }
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
        didSet { persist(openAIEnhancementEnabled, "openAIEnhancementEnabled") }
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
        didSet { UserDefaults.standard.set(llmProvider, forKey: "llmProvider") }
    }

    /// Base URL (through /v1) of the local OpenAI-compatible server.
    @Published var localLLMBaseURL: String {
        didSet { UserDefaults.standard.set(localLLMBaseURL, forKey: "localLLMBaseURL") }
    }

    /// Model name to request from the local server.
    @Published var localLLMModel: String {
        didSet { UserDefaults.standard.set(localLLMModel, forKey: "localLLMModel") }
    }

    /// Detect a spoken instruction at the end of a dictation ("…make this
    /// formal") and apply it via the LLM. Off by default — it's the most "magic"
    /// feature and needs an LLM configured. Works in Final / Preview modes.
    @Published var voiceCommandsEnabled: Bool {
        didSet { UserDefaults.standard.set(voiceCommandsEnabled, forKey: "voiceCommandsEnabled") }
    }

    /// Optional wake lead-in for voice commands (e.g. "voice note"). Empty =
    /// rely on imperative templates only.
    @Published var voiceCommandWakeWord: String {
        didSet { UserDefaults.standard.set(voiceCommandWakeWord, forKey: "voiceCommandWakeWord") }
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

    /// User/pack-supplied voice actions, overlaid on the built-ins by id (a pack
    /// can retune Telegram or add a new action like "make a tweet"). Persisted to
    /// voice-actions.json.
    @Published var customVoiceActions: [VoiceAction] {
        didSet { VoiceActionStore.save(customVoiceActions) }
    }

    // MARK: - Runtime State

    @Published var isRecording = false
    @Published var isTranscribing = false
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
    var translationService: OpenAITranslationService!
    var hotkeyMonitor: HotkeyControlling!

    private var overlayController: OverlayWindowController?
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
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
        llmProvider == "local" ? localLLMModel : openAIModel
    }

    /// Whether the active LLM provider is configured enough to call.
    var llmConfigured: Bool {
        if llmProvider == "local" {
            return !localLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        transcriptionEngine = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "whisper"
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
        voiceCommandsEnabled = UserDefaults.standard.object(forKey: "voiceCommandsEnabled") as? Bool ?? false
        voiceCommandWakeWord = UserDefaults.standard.string(forKey: "voiceCommandWakeWord") ?? ""
        scriptPostProcessorEnabled = UserDefaults.standard.object(forKey: "scriptPostProcessorEnabled") as? Bool ?? false
        scriptPostProcessorPath = UserDefaults.standard.string(forKey: "scriptPostProcessorPath") ?? ""
        perAppModesEnabled = UserDefaults.standard.object(forKey: "perAppModesEnabled") as? Bool ?? false
        historyEnabled = UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true
        profiles = AppProfileStore.load()
        history = TranscriptionHistoryStore.load()
        customVocabularyEnabled = UserDefaults.standard.object(forKey: "customVocabularyEnabled") as? Bool ?? true
        vocabulary = VocabularyStore.load()
        customVoiceActions = VoiceActionStore.load()
        didCompleteOnboarding = UserDefaults.standard.bool(forKey: "didCompleteOnboarding")

        // All stored properties are now initialized; safe to run migrations that
        // read/mutate them. One-time: fold a legacy `telegramPostPrompt` (now
        // unified into customVoiceActions) into a telegram-post override.
        Self.migrateLegacyTelegramPrompt(into: &customVoiceActions)

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
        whisperEngine = WhisperEngine()
        appleSpeechEngine = AppleSpeechEngine()
        translationService = OpenAITranslationService()

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
                guard let self else { return }
                self.statusMessage = "Transcribing... \(pct)%"
            }
        }
        whisperEngine.onWorkerStatus = { [weak self] status in
            Task { @MainActor in
                self?.whisperWorkerStatus = status
            }
        }

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

        appleSpeechEngine.onPartial = { [weak self] text in
            Task { @MainActor in
                self?.handleAppleSpeechPartial(text)
            }
        }
        appleSpeechEngine.onFinal = { [weak self] text in
            Task { @MainActor in
                self?.handleAppleSpeechFinal(text)
            }
        }
        appleSpeechEngine.onError = { [weak self] message in
            Task { @MainActor in
                guard let self, self.isAppleSpeechSession else { return }
                self.error = message
                self.statusMessage = "Apple Speech Error"
                self.isRecording = false
                self.isTranscribing = false
                self.isAppleSpeechSession = false
                self.finishSessionUI()
            }
        }
        appleSpeechEngine.onLevelChanged = { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
            }
        }

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
        hotkeyMonitor.onCancel = { [weak self] in
            Task { @MainActor in
                self?.cancelDictation()
            }
        }
    }

    // MARK: - Actions

    func startDictation() {
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
        if transcriptionEngine == "appleSpeech" {
            startAppleSpeech()
            return
        }
        if outputMode == "liveChunks" || outputMode == "preview" {
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
        guard isRecording || isTranscribing || sessionActive else { return }
        activeSessionID = UUID()
        sessionActive = false
        pendingStop = false
        transcriptionRequests.removeAll()
        cleanupPendingLiveChunks()
        resetLivePipeline()
        acceptingLiveChunks = false
        isAppleSpeechSession = false
        appleSpeechEngine.stop(cancel: true)
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
        hotkeyMonitor.stop()
    }

    func stopWhisperServer() {
        whisperEngine.stopServer()
    }

    func warmWhisperServerIfPossible() {
        guard whisperBackend == "serverAPI" else { return }
        guard !isModelDownloading else {
            whisperWorkerStatus = "Waiting for model"
            return
        }
        whisperEngine?.warmServer(binaryPath: whisperBinaryPath, modelPath: modelPath)
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

    func startAppleSpeech() {
        guard !isRecording, !isTranscribing else { return }
        guard !SecureFieldDetector.focusedFieldIsSecure() else {
            refuseDictationIntoSecureField()
            return
        }
        beginSession(streaming: false)
        isAppleSpeechSession = true
        appleLiveInsertedText = ""
        appleDidCompleteFinal = false
        // Keep the "Starting..." arming cue from beginSession until the recognizer
        // is actually live (below). Apple Speech has the same startup gap as the
        // whisper path: async mic + speech-auth grants, then engine start.
        let sessionID = activeSessionID

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.error = "Microphone access denied. Check System Settings."
                    self.isAppleSpeechSession = false
                    self.finishSessionUI()
                    return
                }

                AppleSpeechEngine.requestAuthorization { status in
                    Task { @MainActor in
                        guard status == .authorized else {
                            self.error = "Speech recognition access denied. Check System Settings."
                            self.isAppleSpeechSession = false
                            self.finishSessionUI()
                            return
                        }

                        // Abort if the hotkey was released or the session cancelled before grant.
                        guard sessionID == self.activeSessionID, !self.pendingStop else {
                            self.isAppleSpeechSession = false
                            self.abortSessionBeforeStart()
                            return
                        }

                        do {
                            try self.appleSpeechEngine.start(language: self.language)
                            self.isArming = false
                            self.isRecording = true
                            self.statusMessage = "Listening..."
                        } catch {
                            self.error = error.localizedDescription
                            self.statusMessage = "Apple Speech Error"
                            self.isAppleSpeechSession = false
                            self.finishSessionUI()
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
        hideOverlayNow()
        appleSpeechEngine.stop(cancel: false)

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
        hideOverlayNow()

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
        translationService.processFinalText(
            text: item,
            mode: "rephrase",
            targetLanguage: translationTargetLanguage,
            endpoint: llmEndpoint,
            model: llmModel
        ) { [weak self] result in
            Task { @MainActor in
                guard let self, sessionID == self.activeSessionID else { return }
                let textToInsert: String
                switch result {
                case .success(let processedText):
                    let cleaned = self.postProcess(processedText)
                    textToInsert = cleaned.isEmpty ? item : cleaned
                    self.translationStatus = cleaned.isEmpty ? "OpenAI returned empty chunk" : "Rephrased"
                case .failure(let error):
                    textToInsert = item
                    self.translationStatus = "OpenAI failed"
                    self.error = "OpenAI chunk rephrase failed: \(error.localizedDescription)"
                }

                self.insertLiveChunk(textToInsert)
                self.livePipeline.finishInsertion()
                self.processNextLiveInsertion()
                if self.isTranscribing && self.livePipelineIsDrained {
                    self.completeFinalText(self.currentSessionText)
                }
            }
        }
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

        guard !finalText.isEmpty else {
            isTranscribing = false
            statusMessage = "No speech detected"
            finishSessionUI()
            return
        }

        lastTranscription = finalText
        streamingText = finalText

        // Voice commands: if the user ended with a spoken instruction
        // ("…make this formal" / "…make a telegram post"), strip it and transform
        // the content via the LLM. Only in whole-text modes (the command is in the
        // buffer at finalize).
        if voiceCommandsEnabled,
           outputMode == "finalOnly" || outputMode == "preview",
           let command = VoiceCommandParser(wakeWord: voiceCommandWakeWord, actions: voiceActionRegistry).parse(finalText) {
            if llmConfigured {
                applyVoiceCommand(command)
            } else {
                // Command recognized but no LLM to run it: never type the command
                // words. Insert the (stripped) content and tell the user why.
                isTranscribing = false
                insertCompletedText(command.content, originalText: command.content)
                statusMessage = "Set up an AI provider in Settings to run voice commands"
            }
            return
        }

        // Run a whole-text OpenAI pass for finalOnly OR preview mode when
        // enhancement is enabled. Otherwise paste/insert the captured text once.
        let enhanceWholeText = shouldEnhanceCurrentSession
            && (outputMode == "finalOnly" || outputMode == "preview")
        guard enhanceWholeText else {
            isTranscribing = false
            insertCompletedText(finalText, originalText: finalText)
            return
        }

        statusMessage = openAIEnhancementMode == "rephrase" ? "Polishing..." : "Improving..."
        translationStatus = statusMessage
        // Capture the session so a cancel (Esc) or new session started while the
        // OpenAI call is in flight causes this callback to be ignored — otherwise
        // it would paste/clobber the clipboard after the session was cancelled.
        let sessionID = activeSessionID
        translationService.processFinalText(
            text: finalText,
            mode: openAIEnhancementMode,
            targetLanguage: translationTargetLanguage,
            endpoint: llmEndpoint,
            model: llmModel
        ) { [weak self] result in
            Task { @MainActor in
                guard let self, sessionID == self.activeSessionID else { return }
                self.isTranscribing = false
                switch result {
                case .success(let processedText):
                    let cleaned = self.postProcess(processedText)
                    guard !cleaned.isEmpty else {
                        self.error = "OpenAI returned empty text."
                        self.translationStatus = "OpenAI failed"
                        self.openAIEnhancementEnabledForSession = false
                        self.insertCompletedText(finalText, originalText: finalText)
                        self.statusMessage = "OpenAI failed; inserted local text"
                        return
                    }
                    self.translationStatus = self.openAIEnhancementMode == "rephrase" ? "Rephrased" : "Improved"
                    self.insertCompletedText(cleaned, originalText: finalText)
                case .failure(let error):
                    self.error = "OpenAI post-processing failed: \(error.localizedDescription)"
                    self.translationStatus = "OpenAI failed"
                    self.openAIEnhancementEnabledForSession = false
                    self.insertCompletedText(finalText, originalText: finalText)
                    self.statusMessage = "OpenAI failed; inserted local text"
                }
            }
        }
    }

    /// Transform the dictated content per a detected spoken command and insert it.
    /// On LLM failure, falls back to inserting the (command-stripped) content so
    /// the user never gets the literal command words typed.
    /// Read-only view of the active voice actions, for the Settings overview/editor.
    var activeVoiceActions: [VoiceAction] { voiceActionRegistry.actions }

    /// The voice actions in effect this session: the built-ins overlaid with the
    /// user's custom actions (overrides built-ins by id, plus any brand-new ones).
    /// `customVoiceActions` is the single source of overlays — the Settings editor,
    /// imports, and packs all write here.
    private var voiceActionRegistry: VoiceActionRegistry {
        customVoiceActions.isEmpty
            ? .builtins
            : VoiceActionRegistry.builtins.merging(customVoiceActions)
    }

    // MARK: Voice-action editor support

    /// Upsert an edited/added action into the custom overlay (override-or-append
    /// by id). Used by the Settings editor.
    func upsertVoiceAction(_ action: VoiceAction) {
        customVoiceActions = VoiceActionRegistry(customVoiceActions).merging([action]).actions
    }

    /// Remove a custom action by id. Built-in ids can't be removed (use reset);
    /// removing a custom override of a built-in just reverts it to the built-in.
    func removeVoiceAction(id: String) {
        customVoiceActions.removeAll { $0.id == id }
    }

    /// True if `id` is a built-in action (can be reset but not deleted).
    func isBuiltinVoiceAction(id: String) -> Bool {
        VoiceActionRegistry.builtins.action(id: id) != nil
    }

    /// True if `id` currently has a custom override (a built-in that's been edited,
    /// or a user-added action).
    func hasCustomOverride(id: String) -> Bool {
        customVoiceActions.contains { $0.id == id }
    }

    /// Reset a built-in action to its shipped definition by dropping any override.
    func resetVoiceAction(id: String) {
        customVoiceActions.removeAll { $0.id == id }
    }

    /// One-time migration of the removed `telegramPostPrompt` setting into the
    /// unified customVoiceActions overlay. No-op once migrated (key removed).
    private static func migrateLegacyTelegramPrompt(into actions: inout [VoiceAction]) {
        guard let legacy = UserDefaults.standard.string(forKey: "telegramPostPrompt") else { return }
        let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != VoiceAction.defaultTelegramPostPrompt,
           !actions.contains(where: { $0.id == VoiceAction.telegramPostID }) {
            var telegram = VoiceAction.telegramPost
            telegram.prompt = legacy
            actions.append(telegram)
            VoiceActionStore.save(actions)
        }
        UserDefaults.standard.removeObject(forKey: "telegramPostPrompt")
    }

    private func applyVoiceCommand(_ command: VoiceCommandParser.Result) {
        streamingText = command.content
        // Named actions use their curated prompt from the registry; free-form
        // commands use the generic "apply this transformation" directive.
        let directive: String
        if let actionID = command.actionID, let action = voiceActionRegistry.action(id: actionID) {
            directive = action.prompt
            statusMessage = "Running \(action.displayName)..."
        } else {
            directive = VoiceCommandParser.directive(for: command.instruction)
            statusMessage = "Applying command..."
        }
        translationStatus = statusMessage
        let sessionID = activeSessionID
        translationService.processFinalText(
            text: command.content,
            mode: "rephrase",
            targetLanguage: translationTargetLanguage,
            endpoint: llmEndpoint,
            model: llmModel,
            customInstruction: directive
        ) { [weak self] result in
            Task { @MainActor in
                guard let self, sessionID == self.activeSessionID else { return }
                self.isTranscribing = false
                switch result {
                case .success(let processedText):
                    let cleaned = self.postProcess(processedText)
                    let textToInsert = cleaned.isEmpty ? command.content : cleaned
                    self.translationStatus = "Command applied"
                    self.insertCompletedText(textToInsert, originalText: command.content)
                case .failure(let error):
                    self.error = "Voice command failed: \(error.localizedDescription)"
                    self.translationStatus = "Command failed"
                    self.insertCompletedText(command.content, originalText: command.content)
                    self.statusMessage = "Command failed; inserted text"
                }
            }
        }
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
            )
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

        recordHistory(text)

        let finalWasEnhanced = shouldEnhanceCurrentSession
            && (!isLiveChunkSession || isPreviewSession)
        statusMessage = finalWasEnhanced
            ? "Enhanced: \(text.prefix(50))..."
            : "Done: \(originalText.prefix(50))..."
        finishSessionUI(delay: 0.8)
    }

    /// Local transcript cleanup. Delegates to TranscriptCleaner (in OpenWhispCore)
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

    func copyHistoryEntry(_ entry: TranscriptionEntry) {
        textOutput.setClipboard(entry.text)
    }

    // MARK: - Config import / export

    /// Snapshot the user-editable config (profiles, vocabulary, prompts) as a
    /// portable bundle. History and secrets are intentionally excluded.
    func exportConfig() -> ConfigBundle {
        ConfigBundle(
            profiles: profiles,
            vocabulary: vocabulary,
            actions: customVoiceActions.isEmpty ? nil : customVoiceActions,
            prompts: ConfigBundle.Prompts(
                voiceCommandWakeWord: voiceCommandWakeWord
            )
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
        if let importedActions = bundle.actions {
            // Merge by id onto the existing custom actions (override or append),
            // so importing a pack adds/updates actions without wiping others.
            customVoiceActions = VoiceActionRegistry(customVoiceActions)
                .merging(importedActions)
                .actions
        }
        if let wake = bundle.prompts?.voiceCommandWakeWord {
            voiceCommandWakeWord = wake
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
