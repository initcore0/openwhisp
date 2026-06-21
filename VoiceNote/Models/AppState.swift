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
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }

    @Published var triggerMode: String {
        didSet {
            UserDefaults.standard.set(triggerMode, forKey: "triggerMode")
            hotkeyMonitor?.triggerMode = triggerMode
        }
    }

    @Published var outputMode: String {
        didSet { UserDefaults.standard.set(outputMode, forKey: "outputMode") }
    }

    @Published var showOverlay: Bool {
        didSet { UserDefaults.standard.set(showOverlay, forKey: "showOverlay") }
    }

    @Published var restoreClipboard: Bool {
        didSet { UserDefaults.standard.set(restoreClipboard, forKey: "restoreClipboard") }
    }

    @Published var addTrailingSpace: Bool {
        didSet { UserDefaults.standard.set(addTrailingSpace, forKey: "addTrailingSpace") }
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
        didSet { UserDefaults.standard.set(openAIEnhancementEnabled, forKey: "openAIEnhancementEnabled") }
    }

    @Published var openAIEnhancementMode: String {
        didSet { UserDefaults.standard.set(openAIEnhancementMode, forKey: "openAIEnhancementMode") }
    }

    @Published var translationTargetLanguage: String {
        didSet { UserDefaults.standard.set(translationTargetLanguage, forKey: "translationTargetLanguage") }
    }

    @Published var openAIAPIKey: String {
        didSet { KeychainStore.save(openAIAPIKey, key: "openAIAPIKey") }
    }

    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "openAIModel") }
    }

    // MARK: - Runtime State

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var lastTranscription: String?
    @Published var streamingText: String = ""
    @Published var statusMessage: String = "Ready"
    @Published var error: String?
    @Published var whisperWorkerStatus: String = "Not started"
    @Published var translationStatus: String = "Not configured"
    @Published var modelDownloadStatus: String = "Not checked"
    @Published var isModelDownloading = false
    @Published var audioLevel: Float = 0
    @Published var recordingElapsed: TimeInterval = 0
    @Published var inputMonitoringPermissionLabel: String = "Unknown"

    // MARK: - Services

    var audioRecorder: AudioRecorder!
    var whisperEngine: WhisperEngine!
    var appleSpeechEngine: AppleSpeechEngine!
    var translationService: OpenAITranslationService!
    var hotkeyMonitor: HotkeyMonitor!

    private var overlayController: OverlayWindowController?
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
    private var targetApplication: NSRunningApplication?
    private var overlayIsVisible = false
    private var activeSessionID = UUID()
    private var transcriptionRequests: [UUID: TranscriptionRequest] = [:]
    private var pendingLiveChunks: [(sequence: Int, url: URL)] = []
    private var liveInFlightCount = 0
    private let liveMaxConcurrentTranscriptions = 2
    private var nextLiveChunkSequence = 0
    private var nextLiveOutputSequence = 0
    private var liveChunkResults: [Int: String] = [:]
    private var liveInsertionQueue: [String] = []
    private var liveInsertionInFlight = false
    private var chunkCount = 0
    private var currentSessionText = ""
    private var isStreamingSession = false
    private var acceptingLiveChunks = false
    /// True from beginSession() until the session terminates. Tracks dictation intent
    /// independently of isRecording, which only flips true inside async grant callbacks.
    private var sessionActive = false
    /// Set when a stop arrives before the grant callback has started recording.
    private var pendingStop = false
    private var openAIEnhancementEnabledForSession = false
    private var isAppleSpeechSession = false
    private var appleLiveInsertedText = ""
    private var appleDidCompleteFinal = false
    private var downloadingModelPath: String?

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

    var hotkeyHelpText: String {
        let trigger = triggerMode == "fn" ? "Release Fn" : "Release Control+Space"
        return "\(trigger) to insert - Esc to cancel"
    }

    var languageDisplayName: String {
        Self.languageDisplayName(for: language)
    }

    private init() {
        let savedWhisperBinaryPath = UserDefaults.standard.string(forKey: "whisperBinaryPath") ?? ""
        whisperBinaryPath = Self.preferredWhisperCLIPath(savedPath: savedWhisperBinaryPath)

        let savedModel = UserDefaults.standard.string(forKey: "modelName") ?? "base"
        let fileName = Self.modelFileName(for: savedModel)
        modelName = savedModel
        let savedModelPath = UserDefaults.standard.string(forKey: "modelPath") ?? ""
        modelPath = Self.preferredModelPath(savedPath: savedModelPath, fileName: fileName)
        microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? ""
        language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        triggerMode = UserDefaults.standard.string(forKey: "triggerMode") ?? "fn"
        outputMode = UserDefaults.standard.string(forKey: "outputMode") ?? "finalOnly"
        showOverlay = UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true
        restoreClipboard = UserDefaults.standard.object(forKey: "restoreClipboard") as? Bool ?? false
        addTrailingSpace = UserDefaults.standard.object(forKey: "addTrailingSpace") as? Bool ?? false
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
        let keychainKey = KeychainStore.read(key: "openAIAPIKey")
        if let keychainKey, !keychainKey.isEmpty {
            openAIAPIKey = keychainKey
        } else if let legacyKey = UserDefaults.standard.string(forKey: "openAIAPIKey"),
                  !legacyKey.isEmpty {
            KeychainStore.save(legacyKey, key: "openAIAPIKey")
            UserDefaults.standard.removeObject(forKey: "openAIAPIKey")
            openAIAPIKey = legacyKey
        } else {
            openAIAPIKey = ""
        }
        openAIModel = UserDefaults.standard.string(forKey: "openAIModel") ?? "gpt-4o-mini"

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
        return base.appendingPathComponent("VoiceNote/models", isDirectory: true)
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
                        self.liveChunkResults[sequence] = ""
                    }
                    self.liveInFlightCount = max(0, self.liveInFlightCount - 1)
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

        audioRecorder = AudioRecorder(appState: self)
        audioRecorder.onStateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .recording:
                    self.isRecording = true
                    self.statusMessage = self.outputMode == "liveChunks" ? "Listening..." : "Recording..."
                case .stopped, .idle:
                    self.isRecording = false
                case .error(let msg):
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

        hotkeyMonitor = HotkeyMonitor(appState: self)
        hotkeyMonitor.triggerMode = triggerMode
        hotkeyMonitor.onPermissionStateChanged = { [weak self] isGranted in
            Task { @MainActor in
                self?.inputMonitoringPermissionLabel = isGranted ? "Granted" : "Needs permission"
                if !isGranted {
                    self?.error = "Input Monitoring is not available for this app build. Remove and re-add VoiceNote in System Settings, then quit and reopen the app."
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
    }

    // MARK: - Actions

    func startDictation() {
        guard !isRecording, !isTranscribing else { return }
        if transcriptionEngine == "appleSpeech" {
            startAppleSpeech()
            return
        }
        if outputMode == "liveChunks" {
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
        translationService.validate(apiKey: openAIAPIKey, model: openAIModel) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.translationStatus = "OpenAI key valid"
                case .failure(let error):
                    self.translationStatus = "Validation failed"
                    self.error = "OpenAI validation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func startAppleSpeech() {
        guard !isRecording, !isTranscribing else { return }
        beginSession(streaming: false)
        isAppleSpeechSession = true
        appleLiveInsertedText = ""
        appleDidCompleteFinal = false
        statusMessage = "Listening..."
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
        let insertion = appleLiveInsertedText.isEmpty ? delta : " \(delta)"
        appleLiveInsertedText = text
        currentSessionText = text
        KeyboardSynthesizer.typeViaPaste(
            insertion,
            restoreClipboard: restoreClipboard,
            targetApplication: targetApplication
        )
    }

    private func handleAppleSpeechFinal(_ rawText: String) {
        guard isAppleSpeechSession, !appleDidCompleteFinal else { return }
        appleDidCompleteFinal = true
        let finalText = postProcess(rawText.isEmpty ? streamingText : rawText)

        // liveChunks: completeFinalText only sets the clipboard for non-finalOnly, so words
        // in the final transcript that were not in the last pasted partial would be dropped.
        // Paste the trailing delta here (mirroring handleAppleSpeechPartial) before routing.
        if outputMode == "liveChunks" {
            let delta = liveDelta(previous: appleLiveInsertedText, current: finalText)
            if !delta.isEmpty {
                let insertion = appleLiveInsertedText.isEmpty ? delta : " \(delta)"
                appleLiveInsertedText = finalText
                KeyboardSynthesizer.typeViaPaste(
                    insertion,
                    restoreClipboard: restoreClipboard,
                    targetApplication: targetApplication
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
        beginSession(streaming: false)

        let micID = microphoneID
        let recorder = self.audioRecorder!
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
        beginSession(streaming: true)

        let micID = microphoneID
        let recorder = self.audioRecorder!
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
        statusMessage = "Finalizing..."
        hideOverlayNow()

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
        chunkCount = 0
        audioLevel = 0
        recordingElapsed = 0
        recordingStartedAt = Date()
        targetApplication = currentTextTargetApplication()
        isStreamingSession = streaming
        isTranscribing = false
        statusMessage = streaming ? "Listening..." : "Recording..."
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
                    liveChunkResults[sequence] = ""
                }
                liveInFlightCount = max(0, liveInFlightCount - 1)
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
                liveChunkResults[sequence] = text
            }
            liveInFlightCount = max(0, liveInFlightCount - 1)
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
        let sequence = nextLiveChunkSequence
        nextLiveChunkSequence += 1
        pendingLiveChunks.append((sequence, path))
        chunkCount += 1
        statusMessage = isTranscribing ? "Finalizing..." : "Queued chunk #\(chunkCount)..."
        processNextLiveChunk()
    }

    private func processNextLiveChunk() {
        guard outputMode == "liveChunks", liveInFlightCount < liveMaxConcurrentTranscriptions, let next = pendingLiveChunks.first else { return }
        pendingLiveChunks.removeFirst()
        liveInFlightCount += 1
        statusMessage = isTranscribing ? "Finalizing..." : "Transcribing chunks..."
        startTranscription(path: next.url, kind: .liveChunk, sequence: next.sequence)
        processNextLiveChunk()
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
            backend: whisperBackend == "serverAPI" ? .serverAPI : .cli
        )
    }

    private func consumeRequest(_ requestID: UUID) -> TranscriptionRequest? {
        transcriptionRequests.removeValue(forKey: requestID)
    }

    private func cleanupPendingLiveChunks() {
        for chunk in pendingLiveChunks {
            try? FileManager.default.removeItem(at: chunk.url)
        }
        pendingLiveChunks.removeAll()
    }

    private var livePipelineIsDrained: Bool {
        pendingLiveChunks.isEmpty
            && liveInFlightCount == 0
            && liveChunkResults.isEmpty
            && liveInsertionQueue.isEmpty
            && !liveInsertionInFlight
    }

    private func resetLivePipeline() {
        cleanupPendingLiveChunks()
        liveInFlightCount = 0
        nextLiveChunkSequence = 0
        nextLiveOutputSequence = 0
        liveChunkResults.removeAll()
        liveInsertionQueue.removeAll()
        liveInsertionInFlight = false
    }

    private func flushOrderedLiveResults() {
        while let text = liveChunkResults.removeValue(forKey: nextLiveOutputSequence) {
            if !text.isEmpty {
                queueLiveInsertion(text)
            }
            nextLiveOutputSequence += 1
        }
    }

    private func queueLiveInsertion(_ text: String) {
        liveInsertionQueue.append(text)
        processNextLiveInsertion()
    }

    private func processNextLiveInsertion() {
        guard !liveInsertionInFlight, !liveInsertionQueue.isEmpty else { return }
        let item = liveInsertionQueue.removeFirst()

        guard shouldEnhanceLiveChunks else {
            insertLiveChunk(item)
            processNextLiveInsertion()
            return
        }

        liveInsertionInFlight = true
        statusMessage = "Rephrasing chunk..."
        translationService.processFinalText(
            text: item,
            mode: "rephrase",
            targetLanguage: translationTargetLanguage,
            apiKey: openAIAPIKey,
            model: openAIModel
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
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
                self.liveInsertionInFlight = false
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

        let insertion = needsSeparator ? " \(text)" : text
        KeyboardSynthesizer.typeViaPaste(
            insertion,
            restoreClipboard: restoreClipboard,
            targetApplication: targetApplication
        )
        statusMessage = "Inserted: \(text.prefix(40))..."
    }

    private func completeFinalText(_ text: String) {
        let finalText = postProcess(text)

        guard !finalText.isEmpty else {
            isTranscribing = false
            statusMessage = "No speech detected"
            finishSessionUI()
            return
        }

        lastTranscription = finalText
        streamingText = finalText

        guard shouldEnhanceCurrentSession && outputMode == "finalOnly" else {
            isTranscribing = false
            insertCompletedText(finalText, originalText: finalText)
            return
        }

        statusMessage = openAIEnhancementMode == "rephrase" ? "Rephrasing..." : "Improving..."
        translationStatus = statusMessage
        translationService.processFinalText(
            text: finalText,
            mode: openAIEnhancementMode,
            targetLanguage: translationTargetLanguage,
            apiKey: openAIAPIKey,
            model: openAIModel
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
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

    private func insertCompletedText(_ text: String, originalText: String) {
        streamingText = text

        if outputMode == "finalOnly" {
            let insertion = addTrailingSpace ? "\(text) " : text
            KeyboardSynthesizer.typeViaPaste(
                insertion,
                restoreClipboard: restoreClipboard,
                targetApplication: targetApplication
            )
        } else {
            // liveChunks: the text was already pasted incrementally (no trailing space).
            // Type the single conditional trailing space now, honoring addTrailingSpace.
            if addTrailingSpace, !text.isEmpty {
                KeyboardSynthesizer.typeViaPaste(
                    " ",
                    restoreClipboard: restoreClipboard,
                    targetApplication: targetApplication
                )
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        let finalWasEnhanced = shouldEnhanceCurrentSession && outputMode == "finalOnly"
        statusMessage = finalWasEnhanced
            ? "Enhanced: \(text.prefix(50))..."
            : "Done: \(originalText.prefix(50))..."
        finishSessionUI(delay: 0.8)
    }

    private func postProcess(_ text: String) -> String {
        var normalized = removeNonSpeechMarkers(from: text)
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
        return isIgnorableTranscript(normalized) ? "" : normalized
    }

    private func isIgnorableTranscript(_ text: String) -> Bool {
        let lowercased = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let ignorableTokens: Set<String> = [
            "[blank_audio]",
            "[silence]",
            "(silence)",
            "[no speech]",
            "(no speech)",
            "[music]",
            "(music)",
            "[video playback]",
            "(video playback)",
            "[background noise]",
            "(background noise)",
            "[noise]",
            "(noise)",
            "[applause]",
            "(applause)",
            "[laughter]",
            "(laughter)"
        ]

        return lowercased.isEmpty || ignorableTokens.contains(lowercased)
    }

    private func removeNonSpeechMarkers(from text: String) -> String {
        let markerTerms = [
            "blank_audio",
            "silence",
            "no speech",
            "music",
            "video playback",
            "background noise",
            "noise",
            "static",
            "applause",
            "laughter",
            "laughing",
            "cough",
            "coughing",
            "sigh",
            "breath",
            "breathing",
            "inaudible",
            "unintelligible"
        ]
        var cleaned = text
        for term in markerTerms {
            cleaned = cleaned.replacingOccurrences(of: "[\(term)]", with: "", options: [.caseInsensitive])
            cleaned = cleaned.replacingOccurrences(of: "(\(term))", with: "", options: [.caseInsensitive])
        }
        return cleaned
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
            warmWhisperServerIfPossible()
            return
        }

        guard downloadingModelPath != modelPath else { return }
        let fileName = URL(fileURLWithPath: modelPath).lastPathComponent
        let currentModelPath = modelPath
        downloadingModelPath = currentModelPath
        isModelDownloading = true
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
                    self.modelDownloadStatus = "Download failed: \(fileName)"
                    self.error = "Model download failed: \(error.localizedDescription)\nPath: \(currentModelPath)"
                    if self.statusMessage == "Downloading model..." {
                        self.statusMessage = "Error"
                    }
                }
            }
        }
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
        let downloadedURL = try await ModelDownloader.download(from: url)
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

    static func download(from url: URL) async throws -> URL {
        let downloader = ModelDownloader()
        return try await downloader.download(from: url)
    }

    private func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.waitsForConnectivity = true
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voicenote-model-\(UUID().uuidString).download")
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
