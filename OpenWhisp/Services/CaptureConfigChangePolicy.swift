import Foundation

/// Pure decision logic for a mid-session `AVAudioEngineConfigurationChange` on a
/// streaming capture engine (Parakeet/WhisperKit/Apple Speech own their own
/// `AVAudioEngine` taps).
///
/// When the input device is disconnected, switched, or renegotiates its format
/// mid-dictation, AVAudioEngine STOPS rendering. Without a reaction the session
/// keeps showing "Listening…" while capturing nothing — every word spoken after
/// the change is silently lost until the user gives up and starts a new session.
/// `AudioRecorder` has handled this since the AirPods-disconnect hang; the
/// streaming engines never got the observer.
///
/// Foundation-only (no AVFoundation) so it lives in OpenWhispCore and
/// `swift test` pins the gates; the notification observer + tap rebuild live
/// app-side in the engine.
enum CaptureConfigChangePolicy {

    /// What the engine should do when the notification fires.
    enum Action: Equatable {
        /// Stale notification — a stop or a newer session already superseded the
        /// capture this observer was armed for. Touch nothing: the successor
        /// session owns the mic now.
        case ignore
        /// The session is still live: rebuild the engine + tap and keep feeding
        /// the SAME decode session. Audio captured before the change is already
        /// in the feed stream, so the transcript loses only the glitch itself.
        case restartCapture
    }

    /// `generationMatches` is the engine's session-generation fence (the same
    /// gate the partial/EOU callbacks use); `didStop` is the engine's stop flag.
    static func action(generationMatches: Bool, didStop: Bool) -> Action {
        (generationMatches && !didStop) ? .restartCapture : .ignore
    }

    /// User-facing error when the capture rebuild failed (no input device left
    /// after the change, or the tap/engine start threw). Surfaced through the
    /// session's error path so the session fails LOUDLY instead of silently
    /// eating speech for its remainder.
    static func restartFailedMessage(underlying: String) -> String {
        "Microphone changed mid-dictation and capture couldn't be restarted: \(underlying)"
    }
}
