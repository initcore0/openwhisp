import Foundation

/// Who initiated a dictation session.
///
/// A **user** session behaves exactly as OpenWhisp always has: it pastes its
/// result into the frontmost app. An **agent** session (started via the Agent
/// Bridge) instead returns the transcript to the calling client and pastes
/// nothing — the microphone and overlay are the same, only the disposition of
/// the result differs.
///
/// Foundation-only so it lives in `OpenWhispCore` and can be unit-tested; the app
/// carries it through the existing session funnel, and the future
/// `DictationCoordinator` (M8 step 9) will own it.
enum SessionInitiator: Equatable {
    case user
    case agent(client: String, prompt: String?)

    var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    /// The claimed client name for an agent session (display-only; never trusted
    /// for authorization — the socket peer's code signature is what authorizes).
    var clientName: String? {
        if case let .agent(client, _) = self { return client }
        return nil
    }

    /// The agent's prompt to show in the overlay, if any.
    var prompt: String? {
        if case let .agent(_, prompt) = self { return prompt }
        return nil
    }
}

/// The terminal outcome of a dictation session, delivered exactly once to an
/// agent-initiated waiter (see `AppState.onSessionEnd`).
///
/// `cancelled` is the default when a session ends without recording a more
/// specific outcome (an abort before capture, or an error terminal that didn't
/// set one) — so a waiter is never left hanging, and per the cancel invariant a
/// cancelled session yields no transcript text.
enum SessionOutcome: Equatable {
    /// Produced final text (which may itself be any non-nil string).
    case completed(text: String)
    /// The session finalized with nothing transcribed.
    case empty
    /// Refused because a secure text field was focused.
    case secureField
    /// The user pressed Esc, or the client cancelled. No transcript is returned.
    case cancelled
    /// An audio/engine error aborted the session.
    case error(message: String)
}
