import Foundation

/// Platform-neutral handle for an input device, threaded through the engine
/// seams. On macOS the concrete recorder/engine speaks CoreAudio, so the handle
/// IS a CoreAudio `AudioDeviceID` (an integer device id). On iOS there is no
/// CoreAudio device enumeration — routing is by `AVAudioSession` route UID — so
/// the handle is a `String`. The public protocol seams (`AudioCapture`,
/// `StreamingTranscriptionEngine`) already select devices by opaque `String`;
/// this typealias exists for the WhisperKit-linked (`#if WHISPERKIT`, macOS)
/// stream handle that pins the CoreAudio device directly, so that code names a
/// platform-neutral type instead of `AudioDeviceID` verbatim.
#if os(macOS)
import CoreAudio
public typealias AudioDeviceHandle = AudioDeviceID
#else
public typealias AudioDeviceHandle = String
#endif

/// Lifecycle state of an audio capture session, surfaced via `onStateChanged`.
///
/// Foundation-only so it lives in OpenWhispCore and can be named by the
/// `AudioCapture` protocol and by AppState without pulling in AVFoundation.
enum RecorderState: Equatable {
    case idle
    case recording
    case stopped
    case error(String)
}

/// Platform-agnostic audio-capture seam (Phase 2.5 core extraction).
///
/// AppState depends on this protocol instead of the concrete macOS
/// `AudioRecorder` (AVAudioEngine + AVAudioConverter + CoreAudio). It models the
/// three capture modes the app drives — single-file, fixed-interval chunking, and
/// silence/pause-based chunking — plus level metering and auto-gain. A port keeps
/// the (portable) RMS/auto-gain/VAD math and swaps the capture backend (Windows:
/// WASAPI + a resampler).
///
/// Microphone enumeration/selection is intentionally NOT fully here: device
/// listing returns platform device handles (CoreAudio `AudioDeviceID`), so the
/// concrete `AudioDevice` type stays on the platform side. The protocol exposes
/// only `selectDevice(_:)` by opaque string ID, which is all AppState drives.
protocol AudioCapture: AnyObject {
    /// Peak-normalize quiet input toward a healthy level. Settable live.
    var autoGainEnabled: Bool { get set }
    /// Quiet-dictation mode (MAK-45): swaps auto-gain to the stronger high-gain
    /// `QuietDictationMode` preset (higher target, larger boost ceiling) so
    /// whispered/very soft speech is lifted much harder. Only takes effect when
    /// `autoGainEnabled` is also true. Settable live. Default off.
    var quietModeEnabled: Bool { get set }
    /// Capture lifecycle transitions (idle/recording/stopped/error).
    var onStateChanged: ((RecorderState) -> Void)? { get set }
    /// Normalized (0–1) live level for the waveform.
    var onLevelChanged: ((Float) -> Void)? { get set }

    /// Make `deviceID` (an opaque platform device identifier) the input device.
    func selectDevice(_ deviceID: String)

    /// Record a single WAV file until `stop`.
    func start()

    /// Record continuously, emitting a finished WAV every `chunkDuration` seconds
    /// via `onChunk`.
    func startStreaming(chunkDuration: Double, onChunk: @escaping (URL?) -> Void)

    /// Record continuously, emitting a WAV per detected utterance (chunk on
    /// silence). The tuning parameters bound chunk length and the speech/silence
    /// thresholds.
    func startStreamingOnSilence(
        silenceDuration: TimeInterval,
        minimumSpeechDuration: TimeInterval,
        maximumSpeechDuration: TimeInterval,
        speechThreshold: Float,
        onChunk: @escaping (URL?) -> Void
    )

    /// Stop any capture mode; `completion` receives the final WAV (if any).
    func stop(completion: ((URL?) -> Void)?)
}

extension AudioCapture {
    /// Convenience matching the concrete recorder's defaults, so AppState can
    /// call `startStreamingOnSilence(onChunk:)` through the protocol unchanged.
    func startStreamingOnSilence(onChunk: @escaping (URL?) -> Void) {
        startStreamingOnSilence(
            silenceDuration: 0.75,
            minimumSpeechDuration: 0.35,
            maximumSpeechDuration: 12.0,
            speechThreshold: 0.018,
            onChunk: onChunk
        )
    }

    /// Convenience so `stop()` (no completion) works through the protocol.
    func stop() { stop(completion: nil) }
}
