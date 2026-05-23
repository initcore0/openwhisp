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
    
    @Published var transcriptionEngine: String {
        didSet { UserDefaults.standard.set(transcriptionEngine, forKey: "transcriptionEngine") }
    }
    
    @Published var whisperBackend: String {
        didSet {
            UserDefaults.standard.set(whisperBackend, forKey: "whisperBackend")
            if whisperBackend != "serverAPI" {
                whisperEngine?.stopServer()
            }
        }
    }
    
    // MARK: - Runtime State
    
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var lastTranscription: String?
    @Published var streamingText: String = ""
    @Published var statusMessage: String = "Ready"
    @Published var error: String?
    @Published var whisperWorkerStatus: String = "Not started"
    @Published var audioLevel: Float = 0
    @Published var recordingElapsed: TimeInterval = 0
    @Published var inputMonitoringPermissionLabel: String = "Unknown"
    
    // MARK: - Services
    
    var audioRecorder: AudioRecorder!
    var whisperEngine: WhisperEngine!
    var appleSpeechEngine: AppleSpeechEngine!
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
    private var chunkCount = 0
    private var currentSessionText = ""
    private var isStreamingSession = false
    private var acceptingLiveChunks = false
    private var isAppleSpeechSession = false
    private var appleLiveInsertedText = ""
    private var appleDidCompleteFinal = false
    
    private enum TranscriptionKind {
        case liveChunk
        case final
    }
    
    private struct TranscriptionRequest {
        let sessionID: UUID
        let kind: TranscriptionKind
        let sequence: Int?
    }
    
    var hotkeyHelpText: String {
        let trigger = triggerMode == "fn" ? "Release Fn" : "Release Control+Space"
        return "\(trigger) to insert - Esc to cancel"
    }
    
    private init() {
        whisperBinaryPath = UserDefaults.standard.string(forKey: "whisperBinaryPath")
            ?? "\(NSHomeDirectory())/whisper.cpp/build/bin/whisper-cli"
        
        let savedModel = UserDefaults.standard.string(forKey: "modelName") ?? "base"
        let fileName = Self.modelFileName(for: savedModel)
        modelName = savedModel
        modelPath = UserDefaults.standard.string(forKey: "modelPath")
            ?? "\(NSHomeDirectory())/whisper.cpp/models/\(fileName)"
        microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? ""
        language = UserDefaults.standard.string(forKey: "language") ?? "en"
        triggerMode = UserDefaults.standard.string(forKey: "triggerMode") ?? "controlSpace"
        outputMode = UserDefaults.standard.string(forKey: "outputMode") ?? "finalOnly"
        showOverlay = UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true
        restoreClipboard = UserDefaults.standard.object(forKey: "restoreClipboard") as? Bool ?? false
        addTrailingSpace = UserDefaults.standard.object(forKey: "addTrailingSpace") as? Bool ?? false
        liveChunkDuration = UserDefaults.standard.object(forKey: "liveChunkDuration") as? Double ?? 2.0
        transcriptionEngine = UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "whisper"
        if let savedBackend = UserDefaults.standard.string(forKey: "whisperBackend") {
            whisperBackend = savedBackend
        } else {
            let legacyWorkerEnabled = UserDefaults.standard.object(forKey: "useWhisperWorker") as? Bool ?? false
            whisperBackend = legacyWorkerEnabled ? "serverAPI" : "cli"
        }
        
        wireUpServices()
        overlayController = OverlayWindowController(appState: self)
        hotkeyMonitor.start()
        ensureModelExists()
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
    
    private func resolvedModelPath() -> String {
        "\(NSHomeDirectory())/whisper.cpp/models/\(Self.modelFileName(for: modelName))"
    }
    
    private func wireUpServices() {
        whisperEngine = WhisperEngine()
        appleSpeechEngine = AppleSpeechEngine()
        
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
        guard isRecording else { return }
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
        guard isRecording || isTranscribing else { return }
        activeSessionID = UUID()
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
    
    func startAppleSpeech() {
        guard !isRecording, !isTranscribing else { return }
        beginSession(streaming: false)
        isAppleSpeechSession = true
        appleLiveInsertedText = ""
        appleDidCompleteFinal = false
        statusMessage = "Listening..."
        
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
        
        appleLiveInsertedText = text
        currentSessionText = text
        KeyboardSynthesizer.typeViaPaste(
            delta.hasSuffix(" ") ? delta : "\(delta) ",
            restoreClipboard: restoreClipboard,
            targetApplication: targetApplication
        )
    }
    
    private func handleAppleSpeechFinal(_ rawText: String) {
        guard isAppleSpeechSession, !appleDidCompleteFinal else { return }
        appleDidCompleteFinal = true
        let finalText = postProcess(rawText.isEmpty ? streamingText : rawText)
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
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.error = "Microphone access denied. Check System Settings."
                    self.finishSessionUI()
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
        
        audioRecorder.stop { [weak self] wavPath in
            Task { @MainActor in
                guard let self, let path = wavPath else {
                    self?.isTranscribing = false
                    self?.statusMessage = "Ready"
                    self?.finishSessionUI()
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
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.error = "Microphone access denied."
                    self.finishSessionUI()
                    return
                }
                if !micID.isEmpty {
                    recorder.selectDevice(micID)
                }
                recorder.startStreaming(chunkDuration: self.liveChunkDuration) { [weak self] chunkPath in
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
        
        audioRecorder.stop { [weak self] finalPath in
            Task { @MainActor in
                guard let self else { return }
                if let path = finalPath {
                    self.enqueueLiveChunk(path)
                } else {
                    self.completeFinalText(self.currentSessionText)
                }
            }
        }
    }
    
    private func beginSession(streaming: Bool) {
        error = nil
        activeSessionID = UUID()
        transcriptionRequests.removeAll()
        cleanupPendingLiveChunks()
        resetLivePipeline()
        acceptingLiveChunks = streaming
        currentSessionText = ""
        streamingText = ""
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
        pendingLiveChunks.isEmpty && liveInFlightCount == 0 && liveChunkResults.isEmpty
    }
    
    private func resetLivePipeline() {
        cleanupPendingLiveChunks()
        liveInFlightCount = 0
        nextLiveChunkSequence = 0
        nextLiveOutputSequence = 0
        liveChunkResults.removeAll()
    }
    
    private func flushOrderedLiveResults() {
        while let text = liveChunkResults.removeValue(forKey: nextLiveOutputSequence) {
            if !text.isEmpty {
                appendLiveChunk(text)
            }
            nextLiveOutputSequence += 1
        }
    }
    
    private func appendLiveChunk(_ text: String) {
        if !currentSessionText.isEmpty {
            currentSessionText += " "
        }
        currentSessionText += text
        streamingText = currentSessionText
        
        let insertion = "\(text) "
        KeyboardSynthesizer.typeViaPaste(
            insertion,
            restoreClipboard: restoreClipboard,
            targetApplication: targetApplication
        )
        statusMessage = "Inserted: \(text.prefix(40))..."
    }
    
    private func completeFinalText(_ text: String) {
        let finalText = postProcess(text)
        isTranscribing = false
        
        guard !finalText.isEmpty else {
            statusMessage = "No speech detected"
            finishSessionUI()
            return
        }
        
        lastTranscription = finalText
        streamingText = finalText
        
        if outputMode == "finalOnly" {
            let insertion = addTrailingSpace ? "\(finalText) " : finalText
            KeyboardSynthesizer.typeViaPaste(
                insertion,
                restoreClipboard: restoreClipboard,
                targetApplication: targetApplication
            )
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(finalText, forType: .string)
        }
        
        statusMessage = "Done: \(finalText.prefix(50))..."
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
        [
            ("tiny",           "Tiny - fastest, lowest quality", "39 MB"),
            ("tiny.en",        "Tiny English - fastest English", "39 MB"),
            ("base",           "Base - fast default", "72 MB"),
            ("base.en",        "Base English - better English default", "72 MB"),
            ("small",          "Small - better quality", "464 MB"),
            ("small.en",       "Small English - recommended quality", "464 MB"),
            ("medium",         "Medium - high quality", "1.5 GB"),
            ("medium.en",      "Medium English - high quality English", "1.5 GB"),
            ("large-v3-turbo", "Large v3 Turbo - best speed/quality", "1.5 GB"),
            ("large-v3",       "Large v3 - best quality, slowest", "2.9 GB")
        ]
    }
    
    func ensureModelExists() {
        guard !FileManager.default.fileExists(atPath: modelPath) else { return }
        let fileName = URL(fileURLWithPath: modelPath).lastPathComponent
        Task {
            do {
                let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
                let dest = URL(fileURLWithPath: modelPath)
                try dest.deletingLastPathComponent().createDirectories()
                try await URLSession.shared.downloadModel(from: url, to: dest)
            } catch {
                Task { @MainActor in
                    self.error = "Model not found. Download from whisper.cpp repo.\nPath: \(modelPath)"
                }
            }
        }
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
