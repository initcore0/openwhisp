import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

// MARK: - SystemAudioCapture (app-only, ScreenCaptureKit)

/// Captures **system audio** (everything the speakers would play) via
/// ScreenCaptureKit and emits 16 kHz mono Float32 sample arrays.
///
/// ## Why ScreenCaptureKit / min-OS
/// `SCStreamConfiguration.capturesAudio` + `excludesCurrentProcessAudio` are
/// macOS 13.0+ (verified in the local SDK header `SCStream.h`). The app targets
/// macOS 14.0 (Info.plist `LSMinimumSystemVersion`), so audio-only SCK capture is
/// always available. NOTE: SCK's *microphone* output type (`SCStreamOutputType
/// .microphone`) is 15.0+, so we do NOT use it — the mic leg is a separate
/// AVAudioEngine tap (see `MeetingMicCapture`) to keep the 14.0 floor.
///
/// SCK requires a stream even for audio-only capture; we attach the smallest
/// legal video config (1×1, a slow frame interval) to a display filter and only
/// register an audio output, discarding screen frames. `excludesCurrentProcessAudio`
/// keeps OpenWhisp's own sounds (e.g. TTS/chimes) out of the meeting mix.
///
/// ## TCC
/// System-audio capture requires the **Screen Recording** permission. Preflight
/// and request live in `MeetingCaptureSession`; this type surfaces the SCK error
/// path (a `getShareableContent` / stream-start failure) up to the session.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Delivered on `sampleQueue`. Mono Float32 at `SystemAudioCapture.targetSampleRate`.
    var onSamples: (([Float]) -> Void)?
    /// Fatal stream error (SCK stopped). Delivered on `sampleQueue`.
    var onError: ((String) -> Void)?

    static let targetSampleRate: Double = 16000

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private let sampleQueue = DispatchQueue(label: "com.openwhisp.app.meeting.system-audio")
    private var targetFormat: AVAudioFormat?

    /// Start capturing system audio. Async because SCK content discovery + stream
    /// start are async. Throws on permission/discovery/start failure.
    func start() async throws {
        // Discover shareable content. On missing Screen Recording permission this
        // throws (SCStreamError) — the session maps it to the guidance hook.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "OpenWhisp.MeetingCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for system-audio capture."])
        }

        // Audio-only: a display filter (no window exclusions) + a minimal video
        // config, since SCK requires a stream. We only register an audio output.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true          // keep our own sounds out
        config.sampleRate = Int(Self.targetSampleRate)      // request 16 kHz…
        config.channelCount = 1                             // …mono (still converted below to guarantee it)
        // Smallest legal video surface; frames are ignored (no screen output added).
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // ~1 fps, negligible cost
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let samples = convertToTargetMono(sampleBuffer), !samples.isEmpty else { return }
        onSamples?(samples)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Finish gracefully rather than losing the recording: the session
        // finalizes the WAV it has so far.
        onError?("System-audio stream stopped: \(error.localizedDescription)")
    }

    // MARK: Conversion

    /// Convert an SCK audio CMSampleBuffer to 16 kHz mono Float32. SCK delivers a
    /// PCM buffer described by an `AudioStreamBasicDescription`; we wrap it in an
    /// `AVAudioPCMBuffer` and run a persistent `AVAudioConverter` (resample +
    /// downmix) to the canonical target so the mixer/WAV get uniform samples.
    private func convertToTargetMono(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee   // mutable copy; never mutate the CMSampleBuffer's ASBD
        guard let inFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                              frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        inBuffer.frameLength = AVAudioFrameCount(frames)

        // Copy the CMSampleBuffer's PCM into the AVAudioPCMBuffer's audio buffer list.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: inBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }

        let target = targetFormat ?? {
            let f = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: Self.targetSampleRate,
                                  channels: 1, interleaved: false)!
            targetFormat = f
            return f
        }()

        if converter == nil || converter?.inputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: target)
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 1
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        var convError: NSError?
        let result = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
        guard result != .error, outBuffer.frameLength > 0,
              let ch = outBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuffer.frameLength)))
    }
}
