import Foundation

/// Pure decision for what the dictation overlay should communicate, derived from
/// the current session flags. Foundation-only so it lives in OpenWhispCore and is
/// unit-tested independently of SwiftUI.
///
/// The important case for the lost-leading-audio bug is `.arming`: the overlay is
/// shown the instant the hotkey is pressed (`beginSession`), but audio capture is
/// not actually live until the recorder's `AVAudioEngine` has started — which
/// happens behind an async microphone-permission grant and a cold engine start.
/// Speaking during that gap loses the first word or two. `.arming` lets the UI
/// say "not capturing yet" and withhold the green "speak now" cue until capture
/// is genuinely live (`isCapturing == true`).
///
/// We deliberately do NOT keep the microphone warm/always-on (privacy), so the
/// startup gap is real; the fix is to surface it honestly rather than hide it.
enum OverlayPhase: Equatable {
    /// Session requested; capture not yet live. Tell the user to wait — anything
    /// said now may be dropped.
    case arming
    /// Capture is live and the room is quiet (the "green / ready" listening cue).
    case listening
    /// Capture is live and speech energy is present.
    case speaking
    /// Recording ended; transcribing / polishing.
    case finalizing
    /// Terminal error with no active capture/transcription.
    case error

    /// Inputs mirror exactly the AppState flags the overlay already observes.
    /// - Parameters:
    ///   - hasError: a non-nil session error is set.
    ///   - isCapturing: the recorder has reported `.recording` (engine live).
    ///   - isTranscribing: the session is finalizing/polishing.
    ///   - isArming: a session has begun but capture isn't live yet (the gap).
    ///   - audioLevel: normalized live mic level (0–1).
    ///   - speakingThreshold: level above which we render the "speaking" cue.
    static func resolve(
        hasError: Bool,
        isCapturing: Bool,
        isTranscribing: Bool,
        isArming: Bool,
        audioLevel: Float,
        speakingThreshold: Float = 0.06
    ) -> OverlayPhase {
        // Error only "wins" once nothing is actively capturing/transcribing, matching
        // the prior overlay logic (a transient error mid-session shouldn't flicker red).
        if hasError, !isCapturing, !isTranscribing { return .error }
        if isTranscribing { return .finalizing }
        // Arming: session begun, capture not yet live. `isCapturing` going true is
        // the single signal that ends it (AppState clears isArming in lockstep).
        if isArming, !isCapturing { return .arming }
        if audioLevel > speakingThreshold { return .speaking }
        return .listening
    }
}
