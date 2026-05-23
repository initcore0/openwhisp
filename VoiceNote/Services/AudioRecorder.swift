import Foundation
import AVFoundation

// MARK: - Audio Recorder

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    
    enum RecorderState {
        case idle
        case recording
        case stopped
        case error(String)
    }
    
    weak var appState: AppState?
    var onStateChanged: ((RecorderState) -> Void)?
    var onLevelChanged: ((Float) -> Void)?
    
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?
    private let streamQueue = DispatchQueue(label: "com.encryptedcat.voicenote.audio-stream")
    
    // Streaming state
    private var streamingEngine: AVAudioEngine?
    private var streamingFile: AVAudioFile?
    private var streamingURL: URL?
    private var streamingFormat: AVAudioFormat?
    private var streamFileIndex = 0
    private var chunkTimer: Timer?
    private var streamingChunks: [URL] = []
    private var onChunkComplete: ((URL?) -> Void)?
    private var chunkCount = 0
    private var isStreaming = false
    private var isPauseBasedStreaming = false
    private var silenceDuration: TimeInterval = 0.75
    private var minimumSpeechDuration: TimeInterval = 0.35
    private var maximumSpeechDuration: TimeInterval = 12.0
    private var speechThreshold: Float = 0.018
    private var lastSpeechAt: TimeInterval?
    private var activeChunkDuration: TimeInterval = 0
    private var activeChunkHasSpeech = false
    
    init(appState: AppState) {
        self.appState = appState
        super.init()
    }
    
    func selectDevice(_ deviceID: String) {
        if let device = AudioDevice.byID(deviceID) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var devID = device.deviceID
            let size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectSetPropertyData(
                UInt32(kAudioObjectSystemObject),
                &address,
                0, nil,
                size,
                &devID
            )
            if status != noErr {
                print("Warning: Could not set input device: \(status)")
            }
        }
    }
    
    // MARK: - Standard Recording
    
    func start() {
        stop { _ in }
        
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.encryptedcat.voicenote")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let fileName = "recording_\(Int(Date().timeIntervalSince1970 * 1000)).wav"
        recordingURL = cacheDir.appendingPathComponent(fileName)
        
        let settings = makeSettings()
        
        do {
            recorder = try AVAudioRecorder(url: recordingURL!, settings: settings)
            recorder?.delegate = self
            recorder?.isMeteringEnabled = true
            recorder?.prepareToRecord()
            recorder?.record()
            startMetering()
            onStateChanged?(.recording)
        } catch {
            onStateChanged?(.error("Recording failed: \(error.localizedDescription)"))
        }
    }
    
    // MARK: - Streaming Mode
    
    /// Start streaming mode: record continuously in chunks of `chunkDuration` seconds.
    /// Each chunk is saved as a separate WAV file and passed to `onChunk` callback.
    /// Call `stop()` to end the streaming session.
    func startStreaming(chunkDuration: Double, onChunk: @escaping (URL?) -> Void) {
        stop { _ in }
        isStreaming = true
        isPauseBasedStreaming = false
        onChunkComplete = onChunk
        streamingChunks = []
        chunkCount = 0
        streamFileIndex = 0
        
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        streamingEngine = engine
        streamingFormat = format
        
        do {
            try streamQueue.sync {
                try self.openNextStreamingFile(format: format)
            }
            
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.publishLevel(from: buffer)
                self.streamQueue.async {
                    do {
                        try self.streamingFile?.write(from: buffer)
                    } catch {
                        DispatchQueue.main.async {
                            self.onStateChanged?(.error("Streaming write failed: \(error.localizedDescription)"))
                        }
                    }
                }
            }
            
            try engine.start()
            onStateChanged?(.recording)
            scheduleChunkTimer(chunkDuration: chunkDuration)
        } catch {
            input.removeTap(onBus: 0)
            streamingEngine?.stop()
            streamingEngine = nil
            isStreaming = false
            onStateChanged?(.error("Streaming failed: \(error.localizedDescription)"))
        }
    }

    /// Start streaming mode that rotates files when the speaker pauses.
    /// This is local VAD based on input audio level; whisper.cpp still transcribes completed files.
    func startStreamingOnSilence(
        silenceDuration: TimeInterval = 0.75,
        minimumSpeechDuration: TimeInterval = 0.35,
        maximumSpeechDuration: TimeInterval = 12.0,
        speechThreshold: Float = 0.018,
        onChunk: @escaping (URL?) -> Void
    ) {
        stop { _ in }
        isStreaming = true
        isPauseBasedStreaming = true
        self.silenceDuration = silenceDuration
        self.minimumSpeechDuration = minimumSpeechDuration
        self.maximumSpeechDuration = maximumSpeechDuration
        self.speechThreshold = speechThreshold
        onChunkComplete = onChunk
        streamingChunks = []
        chunkCount = 0
        streamFileIndex = 0
        resetPauseStreamingState()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        streamingEngine = engine
        streamingFormat = format

        do {
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.publishLevel(from: buffer)
                self.streamQueue.async {
                    self.handlePauseBasedBuffer(buffer, format: format)
                }
            }

            try engine.start()
            onStateChanged?(.recording)
        } catch {
            input.removeTap(onBus: 0)
            streamingEngine?.stop()
            streamingEngine = nil
            isStreaming = false
            isPauseBasedStreaming = false
            onStateChanged?(.error("Pause-based streaming failed: \(error.localizedDescription)"))
        }
    }
    
    private func scheduleChunkTimer(chunkDuration: Double) {
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
            self?.rotateChunk()
        }
    }
    
    private func rotateChunk() {
        guard isStreaming, let format = streamingFormat else { return }
        streamQueue.async {
            let completedURL = self.streamingURL
            self.streamingFile = nil
            self.streamingURL = nil
            
            do {
                try self.openNextStreamingFile(format: format)
            } catch {
                DispatchQueue.main.async {
                    self.onStateChanged?(.error("Chunk rotation failed: \(error.localizedDescription)"))
                }
                return
            }
            
            DispatchQueue.main.async {
                if let completedURL {
                    self.onChunkComplete?(completedURL)
                    self.streamingChunks.append(completedURL)
                    self.chunkCount += 1
                }
            }
        }
    }

    private func handlePauseBasedBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard isStreaming, isPauseBasedStreaming else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let rms = Self.rmsLevel(from: buffer)
        let hasSpeech = rms >= speechThreshold

        do {
            if hasSpeech, streamingFile == nil {
                try openNextStreamingFile(format: format)
                activeChunkDuration = 0
                activeChunkHasSpeech = true
            }

            guard streamingFile != nil else { return }

            try streamingFile?.write(from: buffer)
            let bufferDuration = Double(buffer.frameLength) / max(1.0, buffer.format.sampleRate)
            activeChunkDuration += bufferDuration

            if hasSpeech {
                activeChunkHasSpeech = true
                lastSpeechAt = now
            }

            let silenceElapsed = now - (lastSpeechAt ?? now)
            let shouldFinalizeForSilence = activeChunkHasSpeech
                && activeChunkDuration >= minimumSpeechDuration
                && silenceElapsed >= silenceDuration
            let shouldFinalizeForLength = activeChunkDuration >= maximumSpeechDuration

            if shouldFinalizeForSilence || shouldFinalizeForLength {
                finishPauseBasedChunk()
            }
        } catch {
            DispatchQueue.main.async {
                self.onStateChanged?(.error("Pause-based streaming failed: \(error.localizedDescription)"))
            }
        }
    }

    private func finishPauseBasedChunk() {
        let completedURL = streamingURL
        let shouldEmit = activeChunkHasSpeech && activeChunkDuration >= minimumSpeechDuration
        streamingFile = nil
        streamingURL = nil
        resetPauseStreamingState()

        DispatchQueue.main.async {
            guard let completedURL else { return }
            if shouldEmit {
                self.onChunkComplete?(completedURL)
                self.streamingChunks.append(completedURL)
                self.chunkCount += 1
            } else {
                try? FileManager.default.removeItem(at: completedURL)
            }
        }
    }
    
    // MARK: - Stop
    
    func stop(completion: ((URL?) -> Void)? = nil) {
        // Cancel streaming timer if active
        chunkTimer?.invalidate()
        chunkTimer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        
        // Stop recording
        let path: URL?
        if isStreaming, let engine = streamingEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            streamingEngine = nil

            path = streamQueue.sync {
                let shouldKeepCurrentChunk = !isPauseBasedStreaming
                    || (activeChunkHasSpeech && activeChunkDuration >= minimumSpeechDuration)
                let currentURL = shouldKeepCurrentChunk ? streamingURL : nil
                if !shouldKeepCurrentChunk, let streamingURL {
                    try? FileManager.default.removeItem(at: streamingURL)
                }
                streamingFile = nil
                streamingURL = nil
                streamingFormat = nil
                streamFileIndex = 0
                resetPauseStreamingState()
                return currentURL
            }
        } else {
            recorder?.stop()
            path = recordingURL
            recorder = nil
            recordingURL = nil
        }
        
        // Chunk files may still be in use by whisper.cpp when streaming stops.
        // WhisperEngine removes each WAV after its process exits.
        if isStreaming {
            streamingChunks = []
            chunkCount = 0
            isStreaming = false
            isPauseBasedStreaming = false
            onChunkComplete = nil
        }
        
        onStateChanged?(.stopped)
        completion?(path)
    }
    
    // MARK: - Helpers
    
    private func makeSettings() -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
    
    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            let normalized = max(0.0, min(1.0, (power + 60.0) / 60.0))
            self.onLevelChanged?(normalized)
        }
    }
    
    private func openNextStreamingFile(format: AVAudioFormat) throws {
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.encryptedcat.voicenote")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let fileName = "chunk_\(streamFileIndex)_\(Int(Date().timeIntervalSince1970 * 1000)).wav"
        streamFileIndex += 1
        let url = cacheDir.appendingPathComponent(fileName)
        streamingFile = try AVAudioFile(forWriting: url, settings: format.settings)
        streamingURL = url
    }
    
    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        let rms = Self.rmsLevel(from: buffer)
        let normalized = max(0, min(1, rms * 8))
        DispatchQueue.main.async {
            self.onLevelChanged?(normalized)
        }
    }

    private func resetPauseStreamingState() {
        lastSpeechAt = nil
        activeChunkDuration = 0
        activeChunkHasSpeech = false
    }

    private static func rmsLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let divisor = Float(max(1, channelCount * frameCount))
        return sqrt(sum / divisor)
    }
    
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            onStateChanged?(.error("Recording finished with error"))
        }
    }
}

// MARK: - Audio Device Helpers

struct AudioDevice {
    let name: String
    let uid: String
    let deviceID: AudioDeviceID
    
    static func availableInputs() -> [AudioDevice] {
        var devices: [AudioDevice] = []
        
        var size: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let sysObj = UInt32(kAudioObjectSystemObject)
        
        guard AudioObjectGetPropertyDataSize(sysObj, &address, 0, nil, &size) == noErr else {
            return devices
        }
        
        let count = size / UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(count))
        
        guard AudioObjectGetPropertyData(sysObj, &address, 0, nil, &size, &deviceIDs) == noErr else {
            return devices
        }
        
        for devID in deviceIDs {
            // Check input streams
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(devID, &inputAddr, 0, nil, &inputSize) == noErr, inputSize > 0 else {
                continue
            }
            
            if let name = stringProperty(kAudioDevicePropertyDeviceNameCFString, for: devID),
               let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: devID) {
                devices.append(AudioDevice(name: name, uid: uid, deviceID: devID))
            }
        }
        
        return devices
    }
    
    private static func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { rawPointer in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawPointer)
            }
        }
        
        guard status == noErr, let value else { return nil }
        return value as String
    }
    
    static func byID(_ id: String) -> AudioDevice? {
        return availableInputs().first { $0.uid == id || $0.name == id }
    }
}
