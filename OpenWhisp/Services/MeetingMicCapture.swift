import Foundation
import AVFoundation

// MARK: - MeetingMicCapture (app-only, independent AVAudioEngine tap)

/// The microphone leg of Meeting mode. A *separate* `AVAudioEngine` tap, resampled
/// to 16 kHz mono Float32 — deliberately independent of dictation's `AudioRecorder`
/// so a meeting and a dictation never share engine state.
///
/// ## Exclusivity (documented)
/// CoreAudio does NOT make the input device exclusive: two `AVAudioEngine`s can
/// tap the same mic concurrently, so at the OS level a meeting + a dictation could
/// both record. That is undesirable (they'd fight over auto-gain and produce
/// confusing overlapping transcripts), so `MeetingCaptureSession`/`AppState` refuse
/// to *start* a meeting while dictating and vice-versa at the app level. This type
/// itself just owns one clean engine and tears it down fully on `stop()`.
final class MeetingMicCapture {

    /// Delivered on `sampleQueue`. Mono Float32 at 16 kHz.
    var onSamples: (([Float]) -> Void)?
    var onError: ((String) -> Void)?

    static let targetSampleRate: Double = 16000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let sampleQueue = DispatchQueue(label: "com.openwhisp.app.meeting.mic")
    private var configObserver: NSObjectProtocol?
    private var running = false

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            throw NSError(domain: "OpenWhisp.MeetingCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone has no active input format."])
        }

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: Self.targetSampleRate,
                                   channels: 1, interleaved: false)!
        targetFormat = target
        converter = AVAudioConverter(from: inFormat, to: target)
        guard converter != nil else {
            throw NSError(domain: "OpenWhisp.MeetingCapture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create 16 kHz mic converter."])
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self, let samples = self.convert(buffer) else { return }
            self.onSamples?(samples)
        }

        engine.prepare()
        try engine.start()
        running = true
        observeConfigChanges()
    }

    func stop() {
        guard running else { return }
        running = false
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func observeConfigChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.running else { return }
            // Input device disconnected/switched mid-meeting: surface it; the
            // session finalizes what it has rather than silently capturing nothing.
            self.onError?("Microphone disconnected or input device changed.")
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter, let target = targetFormat else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        var err: NSError?
        let status = converter.convert(to: out, error: &err, withInputFrom: inputBlock)
        guard status != .error, out.frameLength > 0, let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}
