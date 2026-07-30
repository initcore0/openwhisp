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
/// **The restart must not be reflexive** (the v1.0.12 dead-mic regression):
/// AVAudioEngine posts this notification for ANY io-unit configuration change of
/// the observed engine — including changes CAUSED by our own teardown+rebuild.
/// On systems where a capture start itself perturbs the device (observed: a
/// notification at every session start), a restart-on-every-notification handler
/// enters a self-sustaining loop (~4 restarts/second), and capture never lives
/// long enough to feed the decoder — the mic is dead for EVERY session. So the
/// handler must first let the transient settle (`settleDelay`, coalescing any
/// storm into one check), then consult the only signal that distinguishes a real
/// device loss from a spurious renegotiation: whether the engine is still
/// running. And as defense-in-depth against a genuinely flapping device, the
/// restarts are budgeted per capture session — past the budget the session fails
/// LOUDLY instead of looping silently.
///
/// Foundation-only (no AVFoundation) so it lives in OpenWhispCore and
/// `swift test` pins the gates; the notification observer + tap rebuild live
/// app-side in the engine.
enum CaptureConfigChangePolicy {

    /// How long after a configuration-change notification to wait before
    /// deciding anything. Two jobs: coalesce a notification storm into a single
    /// check, and give a transient renegotiation time to finish so the
    /// `engineStillRunning` probe reads the settled state, not the mid-change
    /// state. A real device loss keeps the engine stopped well past this.
    static let settleDelay: TimeInterval = 0.3

    /// Capture rebuilds allowed per capture session. A legitimate device change
    /// needs exactly one; a couple more covers a messy unplug/replug. A device
    /// that still stops capture after this many rebuilds will do so forever —
    /// give up loudly instead of looping.
    static let maxRestartsPerSession = 3

    /// What the engine should do when the settle-check runs.
    enum Action: Equatable {
        /// Stale notification (a stop or a newer session superseded the capture
        /// this observer was armed for), or the engine is still running — the
        /// change was a transient renegotiation, capture is alive, touch
        /// nothing. Restarting a RUNNING engine is what looped v1.0.12.
        case ignore
        /// The engine genuinely stopped and the budget allows a rebuild:
        /// rebuild the engine + tap and keep feeding the SAME decode session.
        /// Audio captured before the change is already in the feed stream, so
        /// the transcript loses only the glitch itself.
        case restartCapture
        /// The engine stopped again after `maxRestartsPerSession` rebuilds —
        /// the device is flapping. Tear capture down and fail the session
        /// loudly (`gaveUpMessage`) instead of restarting forever.
        case giveUp
    }

    /// `generationMatches` is the engine's session-generation fence (the same
    /// gate the partial/EOU callbacks use); `didStop` is the engine's stop flag;
    /// `engineStillRunning` is the live `AVAudioEngine.isRunning` probe read at
    /// settle time; `restartsUsed` counts rebuilds already performed for this
    /// capture session.
    static func action(
        generationMatches: Bool,
        didStop: Bool,
        engineStillRunning: Bool,
        restartsUsed: Int
    ) -> Action {
        guard generationMatches, !didStop else { return .ignore }
        // Still rendering after the settle window: the change was cosmetic
        // (renegotiation, another client touching the device). Capture is
        // alive — a rebuild would only perturb the device again.
        if engineStillRunning { return .ignore }
        return restartsUsed < maxRestartsPerSession ? .restartCapture : .giveUp
    }

    /// User-facing error when the capture rebuild failed (no input device left
    /// after the change, or the tap/engine start threw). Surfaced through the
    /// session's error path so the session fails LOUDLY instead of silently
    /// eating speech for its remainder.
    static func restartFailedMessage(underlying: String) -> String {
        "Microphone changed mid-dictation and capture couldn't be restarted: \(underlying)"
    }

    /// User-facing error when the restart budget ran out — the input device
    /// keeps stopping capture no matter how often it's rebuilt.
    static var gaveUpMessage: String {
        "The input device keeps interrupting capture — dictation stopped. Try a different microphone or start a new session."
    }
}
