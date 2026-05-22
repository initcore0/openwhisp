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
    
    // Streaming state
    private var chunkTimer: Timer?
    private var streamingChunks: [URL] = []
    private var onChunkComplete: ((URL?) -> Void)?
    private var chunkCount = 0
    private var isStreaming = false
    
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
        onChunkComplete = onChunk
        streamingChunks = []
        chunkCount = 0
        
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.encryptedcat.voicenote")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let fileName = "chunk_0_\(Int(Date().timeIntervalSince1970 * 1000)).wav"
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
            
            // Schedule chunk rotation
            scheduleChunkTimer(chunkDuration: chunkDuration)
        } catch {
            onStateChanged?(.error("Streaming failed: \(error.localizedDescription)"))
        }
    }
    
    private func scheduleChunkTimer(chunkDuration: Double) {
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
            self?.rotateChunk()
        }
    }
    
    private func rotateChunk() {
        guard let url = recordingURL else { return }
        recorder?.stop()
        
        // Callback with the completed chunk
        onChunkComplete?(url)
        streamingChunks.append(url)
        chunkCount += 1
        
        // Start a new chunk
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.encryptedcat.voicenote")
        let fileName = "chunk_\(chunkCount)_\(Int(Date().timeIntervalSince1970 * 1000)).wav"
        recordingURL = cacheDir.appendingPathComponent(fileName)
        
        do {
            self.recorder = try AVAudioRecorder(url: recordingURL!, settings: makeSettings())
            self.recorder?.delegate = self
            self.recorder?.isMeteringEnabled = true
            self.recorder?.prepareToRecord()
            self.recorder?.record()
        } catch {
            onStateChanged?(.error("Chunk rotation failed: \(error.localizedDescription)"))
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
        recorder?.stop()
        let path = recordingURL
        recorder = nil
        recordingURL = nil
        
        // Clean up chunk files if streaming
        if isStreaming {
            for chunk in streamingChunks {
                try? FileManager.default.removeItem(at: chunk)
            }
            streamingChunks = []
            chunkCount = 0
            isStreaming = false
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
            
            // Get name
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize: UInt32 = UInt32(MemoryLayout<CFString>.size)
            
            // Get UID
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize: UInt32 = UInt32(MemoryLayout<CFString>.size)
            
            if AudioObjectGetPropertyData(devID, &nameAddr, 0, nil, &nameSize, &name) == noErr,
               AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, &uid) == noErr {
                devices.append(AudioDevice(name: name as String, uid: uid as String, deviceID: devID))
            }
        }
        
        return devices
    }
    
    static func byID(_ id: String) -> AudioDevice? {
        return availableInputs().first { $0.uid == id || $0.name == id }
    }
}
