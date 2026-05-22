import Foundation
import Combine
import AVFoundation
import UserNotifications
import Cocoa

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
    
    // MARK: - Runtime State
    
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var lastTranscription: String?
    @Published var streamingText: String = ""  // Accumulated real-time text
    @Published var statusMessage: String = "Ready"
    @Published var error: String?
    
    // MARK: - Services
    
    var audioRecorder: AudioRecorder!
    var whisperEngine: WhisperEngine!
    var hotkeyMonitor: HotkeyMonitor!
    
    // Streaming state
    private var chunkCount = 0
    private var currentSessionText: String = ""
    private var transcriptionQueue: String = ""  // Buffer for pending typed text
    private var isStreamingSession = false
    
    private init() {
        // Swift 6: must assign all stored properties before any self.method call
        whisperBinaryPath = UserDefaults.standard.string(forKey: "whisperBinaryPath")
            ?? "\(NSHomeDirectory())/whisper.cpp/build/bin/whisper-cli"
        
        let savedModel = UserDefaults.standard.string(forKey: "modelName") ?? "base"
        let fileName: String
        switch savedModel {
        case "tiny":     fileName = "ggml-tiny.bin"
        case "base":     fileName = "ggml-base.bin"
        case "small":    fileName = "ggml-small.bin"
        case "medium":   fileName = "ggml-medium.bin"
        case "large-v3": fileName = "ggml-large-v3.bin"
        default:         fileName = "ggml-base.bin"
        }
        
        modelName = savedModel
        modelPath = "\(NSHomeDirectory())/whisper.cpp/models/\(fileName)"
        microphoneID = UserDefaults.standard.string(forKey: "microphoneID") ?? ""
        language = UserDefaults.standard.string(forKey: "language") ?? "en"
        
        // Now wire up services
        wireUpServices()
        hotkeyMonitor.start()
        ensureModelExists()
    }
    
    private func resolvedModelPath() -> String {
        let fileName: String
        switch modelName {
        case "tiny":     fileName = "ggml-tiny.bin"
        case "base":     fileName = "ggml-base.bin"
        case "small":    fileName = "ggml-small.bin"
        case "medium":   fileName = "ggml-medium.bin"
        case "large-v3": fileName = "ggml-large-v3.bin"
        default:         fileName = "ggml-base.bin"
        }
        return "\(NSHomeDirectory())/whisper.cpp/models/\(fileName)"
    }
    
    private func wireUpServices() {
        whisperEngine = WhisperEngine()
        
        // Streaming transcription callback — types text into active window
        whisperEngine.onTranscriptionComplete = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                
                if text.isEmpty {
                    // Silence chunk — nothing to do
                    self.statusMessage = "Listening..."
                    return
                }
                
                // Append to accumulated text
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    if !self.currentSessionText.isEmpty {
                        self.currentSessionText += " "
                    }
                    self.currentSessionText += trimmed
                    self.streamingText = self.currentSessionText
                    
                    // Type this chunk into the active window
                    KeyboardSynthesizer.typeViaPaste(" \(text)")
                    
                    self.statusMessage = "Typing: \(trimmed.prefix(40))..."
                } else {
                    self.statusMessage = "Listening..."
                }
            }
        }
        
        whisperEngine.onTranscriptionError = { [weak self] msg in
            Task { @MainActor in
                guard let self else { return }
                self.error = msg
                self.statusMessage = "Error"
            }
        }
        
        whisperEngine.onProgress = { [weak self] pct in
            Task { @MainActor in
                guard let self else { return }
                self.statusMessage = "Transcribing... \(pct)%"
            }
        }
        
        audioRecorder = AudioRecorder(appState: self)
        audioRecorder.onStateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .recording:
                    self.isRecording = true
                    self.statusMessage = "Recording..."
                case .stopped, .idle:
                    self.isRecording = false
                case .error(let msg):
                    self.error = msg
                    self.statusMessage = "Error"
                    self.isRecording = false
                }
            }
        }
        
        hotkeyMonitor = HotkeyMonitor(appState: self)
        hotkeyMonitor.onHotkeyDown = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isRecording else { return }
                self.startStreaming()
            }
        }
        hotkeyMonitor.onHotkeyUp = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.stopStreaming()
            }
        }
    }
    
    // MARK: - Actions
    
    func startRecording() {
        guard !isRecording else { return }
        error = nil
        currentSessionText = ""
        streamingText = ""
        chunkCount = 0
        isStreamingSession = true
        
        let micID = microphoneID
        let recorder = self.audioRecorder!
        
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let _ = self, granted else {
                Task { @MainActor in
                    AppState.shared.error = "Microphone access denied. Check System Settings."
                }
                return
            }
            if !micID.isEmpty {
                recorder.selectDevice(micID)
            }
            recorder.start()
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        isStreamingSession = false
        
        audioRecorder.stop { [weak self] wavPath in
            guard let self, let path = wavPath else {
                self?.isRecording = false
                self?.statusMessage = "Ready"
                return
            }
            
            // Final transcription of the full recording
            self.isTranscribing = true
            self.statusMessage = "Finalizing..."
            self.whisperEngine.transcribe(
                binaryPath: self.whisperBinaryPath,
                modelPath: self.modelPath,
                language: self.language,
                wavPath: path.path
            )
        }
    }
    
    /// Start streaming mode: record 1s chunks, transcribe each, type into active window
    func startStreaming() {
        guard !isRecording else { return }
        error = nil
        currentSessionText = ""
        streamingText = ""
        chunkCount = 0
        isStreamingSession = true
        
        let micID = microphoneID
        let recorder = self.audioRecorder!
        
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let _ = self, granted else {
                Task { @MainActor in
                    AppState.shared.error = "Microphone access denied."
                }
                return
            }
            if !micID.isEmpty {
                recorder.selectDevice(micID)
            }
            recorder.startStreaming(chunkDuration: 3.0) { [weak self] chunkPath in
                Task { @MainActor in
                    guard let self, let path = chunkPath else { return }
                    self.chunkCount += 1
                    self.statusMessage = "Chunk #\(self.chunkCount)..."
                    
                    self.whisperEngine.transcribe(
                        binaryPath: self.whisperBinaryPath,
                        modelPath: self.modelPath,
                        language: self.language,
                        wavPath: path.path
                    )
                }
            }
        }
    }
    
    /// Stop streaming and type the final accumulated text
    func stopStreaming() {
        guard isRecording else { return }
        isStreamingSession = false
        
        audioRecorder.stop { [weak self] finalPath in
            guard let self else { return }
            
            // Transcribe final chunk too
            if let path = finalPath {
                self.whisperEngine.transcribe(
                    binaryPath: self.whisperBinaryPath,
                    modelPath: self.modelPath,
                    language: self.language,
                    wavPath: path.path
                )
            }
            
            // Type the accumulated text into active window
            if !self.currentSessionText.isEmpty {
                let finalText = self.currentSessionText
                self.lastTranscription = finalText
                self.statusMessage = "Done: \(finalText.prefix(50))..."
                
                // Also put in clipboard
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(finalText, forType: .string)
            } else {
                self.statusMessage = "Ready"
            }
            
            self.isRecording = false
            self.isTranscribing = false
        }
    }
    
    // MARK: - Model
    
    func availableModelsList() -> [(name: String, size: String)] {
        [
            ("tiny",     "39 MB"),
            ("base",     "72 MB"),
            ("small",    "464 MB"),
            ("medium",   "1.5 GB"),
            ("large-v3", "2.9 GB")
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
