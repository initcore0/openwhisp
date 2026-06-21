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
    private let streamQueue = DispatchQueue(label: "com.openwhisp.app.audio-stream")

    // Desired input device (applied per-engine for streaming, per-recorder for legacy)
    private var selectedDeviceID: String?
    private var previousDefaultInputDevice: AudioDeviceID?

    // Streaming state
    private var streamingEngine: AVAudioEngine?
    private var streamingFile: AVAudioFile?
    private var streamingURL: URL?
    private var streamingFormat: AVAudioFormat?
    /// Canonical whisper.cpp format: 16 kHz, mono, 16-bit interleaved PCM.
    private var targetFormat: AVAudioFormat?
    /// Converter from the native tap format to `targetFormat`. Persists across
    /// buffers within a session to retain resampling state; recreated per session.
    private var streamingConverter: AVAudioConverter?
    private var streamFileIndex = 0

    /// Auto-gain: boost quiet mics toward a healthy level so whisper gets a strong
    /// signal. Off => audio is passed through unchanged.
    var autoGainEnabled: Bool = true
    /// Smoothed gain applied across buffers (avoids pumping between chunks).
    private var smoothedGain: Float = 1.0
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
    
    /// Records the desired input device. The device is applied lazily:
    /// - For streaming, it is scoped to the engine's input audio unit (`applyInputDevice`).
    /// - For the legacy `AVAudioRecorder` path, the system default input is set in
    ///   `start()` and restored in `stop()` (capture-and-restore), so no permanent
    ///   global mutation remains.
    func selectDevice(_ deviceID: String) {
        selectedDeviceID = deviceID
    }

    /// Address for the system default input device property.
    private static func defaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Reads the current system default input device.
    private static func currentDefaultInputDevice() -> AudioDeviceID? {
        var address = defaultInputAddress()
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            UInt32(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &devID
        )
        return status == noErr ? devID : nil
    }

    /// Sets the system default input device. Returns true on success.
    @discardableResult
    private static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = defaultInputAddress()
        var devID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            UInt32(kAudioObjectSystemObject),
            &address,
            0, nil,
            size,
            &devID
        )
        return status == noErr
    }

    /// Scopes the selected input device to a specific engine's input node.
    /// Must be called before `engine.start()`. Does not mutate the global default.
    private func applyInputDevice(to engine: AVAudioEngine) {
        guard let deviceID = selectedDeviceID, let device = AudioDevice.byID(deviceID) else { return }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(device.deviceID)
        } catch {
            print("Warning: Could not set input device on engine: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Standard Recording
    
    func start() {
        stop { _ in }
        
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.openwhisp.app")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let fileName = "recording_\(Int(Date().timeIntervalSince1970 * 1000)).wav"
        recordingURL = cacheDir.appendingPathComponent(fileName)

        let settings = makeSettings()

        // Legacy AVAudioRecorder can only capture from the system default input.
        // Temporarily switch the default to the selected device, capturing the
        // previous default so it can be restored in stop().
        if let deviceID = selectedDeviceID, let device = AudioDevice.byID(deviceID) {
            previousDefaultInputDevice = Self.currentDefaultInputDevice()
            if !Self.setDefaultInputDevice(device.deviceID) {
                print("Warning: Could not set input device for legacy recording")
                previousDefaultInputDevice = nil
            }
        }

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
        applyInputDevice(to: engine)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        streamingEngine = engine
        streamingFormat = format

        guard let target = Self.makeTargetFormat(),
              let converter = AVAudioConverter(from: format, to: target) else {
            isStreaming = false
            onStateChanged?(.error("Streaming failed: could not create 16kHz converter"))
            return
        }
        targetFormat = target
        streamingConverter = converter
        smoothedGain = 1.0

        do {
            try streamQueue.sync {
                try self.openNextStreamingFile()
            }

            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.publishLevel(from: buffer)
                self.streamQueue.async {
                    guard let converted = self.convertToTarget(buffer) else { return }
                    do {
                        try self.streamingFile?.write(from: converted)
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
            streamingConverter = nil
            streamingFormat = nil
            targetFormat = nil
            isStreaming = false
            // The first chunk file may already have been created; clean it up
            // and clear the dangling streaming references on the stream queue.
            streamQueue.sync {
                if let url = self.streamingURL {
                    try? FileManager.default.removeItem(at: url)
                }
                self.streamingFile = nil
                self.streamingURL = nil
            }
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
        applyInputDevice(to: engine)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        streamingEngine = engine
        streamingFormat = format

        guard let target = Self.makeTargetFormat(),
              let converter = AVAudioConverter(from: format, to: target) else {
            isStreaming = false
            isPauseBasedStreaming = false
            onStateChanged?(.error("Pause-based streaming failed: could not create 16kHz converter"))
            return
        }
        targetFormat = target
        streamingConverter = converter
        smoothedGain = 1.0

        do {
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.publishLevel(from: buffer)
                self.streamQueue.async {
                    self.handlePauseBasedBuffer(buffer)
                }
            }

            try engine.start()
            onStateChanged?(.recording)
        } catch {
            input.removeTap(onBus: 0)
            streamingEngine?.stop()
            streamingEngine = nil
            streamingConverter = nil
            streamingFormat = nil
            targetFormat = nil
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
        guard isStreaming else { return }
        streamQueue.async {
            let completedURL = self.streamingURL
            self.streamingFile = nil
            self.streamingURL = nil

            do {
                try self.openNextStreamingFile()
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

    private func handlePauseBasedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isStreaming, isPauseBasedStreaming else { return }

        // VAD operates on the native tap buffer (loudest channel).
        let now = ProcessInfo.processInfo.systemUptime
        let rms = Self.rmsLevel(from: buffer)
        let hasSpeech = rms >= speechThreshold

        do {
            if hasSpeech, streamingFile == nil {
                try openNextStreamingFile()
                activeChunkDuration = 0
                activeChunkHasSpeech = true
            }

            guard streamingFile != nil else { return }

            // Write resampled 16kHz mono int16 audio to disk for whisper.cpp.
            guard let converted = convertToTarget(buffer) else { return }
            try streamingFile?.write(from: converted)
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

            // Clear streaming flags and references on the same serial queue the
            // tap handler observes. This orders the flag clears after any tap
            // buffer already enqueued before removeTap, so a late buffer cannot
            // see isStreaming == true and reopen an orphan chunk file.
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
                streamingConverter = nil
                targetFormat = nil
                streamFileIndex = 0
                resetPauseStreamingState()
                isStreaming = false
                isPauseBasedStreaming = false
                onChunkComplete = nil
                return currentURL
            }

            // Chunk files may still be in use by whisper.cpp when streaming stops.
            // WhisperEngine removes each WAV after its process exits.
            streamingChunks = []
            chunkCount = 0
        } else {
            recorder?.stop()
            path = recordingURL
            recorder = nil
            recordingURL = nil

            // Restore the system default input device if the legacy path changed it.
            if let previous = previousDefaultInputDevice {
                Self.setDefaultInputDevice(previous)
                previousDefaultInputDevice = nil
            }
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

    /// Converter target format: 16 kHz, mono, **non-interleaved float32**.
    ///
    /// This intentionally is NOT the on-disk format. `AVAudioFile`'s
    /// `processingFormat` (what `write(from:)` requires the buffer to match) is
    /// always a deinterleaved float format derived from the file settings, so the
    /// converter must produce buffers in that format. The file is opened with
    /// 16 kHz mono **int16** settings (`makeSettings()`), and `AVAudioFile`
    /// transparently converts the float buffers to 16-bit PCM on disk — giving
    /// whisper.cpp the WAV it needs. Producing an interleaved int16 buffer here
    /// instead triggers a hard CoreAudio assertion inside `ExtAudioFileWrite`.
    private static func makeTargetFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
    }

    /// Resamples/converts a native tap buffer to the 16 kHz mono int16 target
    /// format using the session converter. Must be called on `streamQueue`.
    private func convertToTarget(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = streamingConverter, let target = targetFormat else { return nil }

        // Size the output buffer for the resampled frame count (round up).
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        // Feed the input buffer to the converter exactly once.
        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if status == .error {
            if let error {
                DispatchQueue.main.async {
                    self.onStateChanged?(.error("Audio conversion failed: \(error.localizedDescription)"))
                }
            }
            return nil
        }
        guard output.frameLength > 0 else { return nil }
        if autoGainEnabled {
            applyAutoGain(to: output)
        }
        return output
    }

    /// Peak-normalize a converted (float32 mono) buffer toward a healthy target
    /// level so quiet microphones still produce a strong signal for whisper.
    ///
    /// Conservative by design: gain is capped, never amplifies near-silence (so
    /// background hiss isn't blown up into "speech"), is smoothed across buffers
    /// to avoid pumping, and hard-clamps samples to [-1, 1] so it can never clip.
    private func applyAutoGain(to buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let samples = data[0]

        // Measure peak amplitude of this buffer.
        var peak: Float = 0
        for i in 0..<frames {
            let a = abs(samples[i])
            if a > peak { peak = a }
        }

        // Don't touch near-silence — avoids amplifying noise between words.
        let silenceFloor: Float = 0.005
        let targetPeak: Float = 0.7      // aim for a healthy but un-clipped level
        let maxGain: Float = 12.0        // cap so we never blow up faint noise

        let desiredGain: Float
        if peak < silenceFloor {
            desiredGain = 1.0            // leave silence as-is
        } else {
            desiredGain = min(maxGain, max(1.0, targetPeak / peak))
        }

        // Smooth toward the desired gain so loudness doesn't pump chunk-to-chunk.
        // Attack faster than release for responsiveness without artifacts.
        let rate: Float = desiredGain > smoothedGain ? 0.5 : 0.2
        smoothedGain += (desiredGain - smoothedGain) * rate

        guard smoothedGain > 1.0001 else { return }   // nothing meaningful to apply
        for i in 0..<frames {
            let v = samples[i] * smoothedGain
            samples[i] = v > 1.0 ? 1.0 : (v < -1.0 ? -1.0 : v)   // hard clamp, no clip
        }
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
    
    /// Opens the next rotated chunk file using the 16 kHz mono int16 target
    /// format so whisper.cpp receives correctly-formatted WAV files. Falls back
    /// to `makeSettings()` if the target format is unavailable.
    private func openNextStreamingFile() throws {
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.openwhisp.app")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let fileName = "chunk_\(streamFileIndex)_\(Int(Date().timeIntervalSince1970 * 1000)).wav"
        streamFileIndex += 1
        let url = cacheDir.appendingPathComponent(fileName)
        // On-disk WAV is 16 kHz mono 16-bit PCM (what whisper.cpp needs). The
        // converter feeds float buffers matching this file's processingFormat;
        // AVAudioFile converts them to int16 on write.
        streamingFile = try AVAudioFile(forWriting: url, settings: makeSettings())
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

    /// RMS of the loudest channel. Using the max per-channel RMS (rather than
    /// averaging across channels) avoids biasing VAD low on multi-channel
    /// devices where only one channel carries the speaker's voice.
    private static func rmsLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let divisor = Float(max(1, frameCount))
        var maxRMS: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            var sum: Float = 0
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sum += sample * sample
            }
            maxRMS = max(maxRMS, sqrt(sum / divisor))
        }

        return maxRMS
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
