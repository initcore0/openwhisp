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
public enum SessionInitiator: Equatable {
    case user
    case agent(client: String, prompt: String?)

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    /// The claimed client name for an agent session (display-only; never trusted
    /// for authorization — the socket peer's code signature is what authorizes).
    public var clientName: String? {
        if case let .agent(client, _) = self { return client }
        return nil
    }

    /// The agent's prompt to show in the overlay, if any.
    public var prompt: String? {
        if case let .agent(_, prompt) = self { return prompt }
        return nil
    }
}

/// Decisions about the dictation-session lifecycle that must stay consistent
/// across the (ordering-sensitive) start/cancel/finish sites. Pure so the
/// invariant is unit-tested rather than re-derived at each call site.
public enum DictationSessionLifecycle {
    /// Whether `finishSessionUI` should reset the hotkey activation machine when a
    /// session ends.
    ///
    /// It must NOT reset while a preempt-replacement start is queued
    /// (`pendingPreemptStart`): there the activation machine's current state
    /// (mid-press or locked-open) describes the user's NEW session, and wiping it
    /// would swallow the upcoming release — in hold mode the preempt-started mic
    /// would then never stop on release.
    ///
    /// This is why the agent-preempt path in `startDictation` must set
    /// `pendingPreemptStart` BEFORE calling `cancelDictation` (which runs
    /// `finishSessionUI`): the flag has to be visible here, or the reset fires and
    /// the release is lost.
    public static func shouldResetActivation(pendingPreemptStart: Bool) -> Bool {
        !pendingPreemptStart
    }
}

/// The terminal outcome of a dictation session, delivered exactly once to an
/// agent-initiated waiter (see `AppState.onSessionEnd`).
///
/// `cancelled` is the default when a session ends without recording a more
/// specific outcome (an abort before capture, or an error terminal that didn't
/// set one) — so a waiter is never left hanging, and per the cancel invariant a
/// cancelled session yields no transcript text.
/// Maps a finished agent session's `SessionOutcome` (+ the timed-out / stopped
/// flags recorded during the session) onto the wire result delivered to the
/// blocked dictate caller. Pure — extracted from AppState's `onSessionEnd`
/// closure so the endedBy / error precedence is unit-testable:
///  - completed → success; endedBy = timeout > stop > user.
///  - empty     → timeout error if timed out, else an empty success.
///  - secureField / cancelled / error → the corresponding domain errors
///    (a cancel NEVER yields a transcript, per the cancel invariant).
public enum AgentDictateOutcome {
    public static func resolve(
        _ outcome: SessionOutcome, duration: Double, timedOut: Bool, stopped: Bool
    ) -> Result<BridgeWire.DictateResult, BridgeWire.ErrorObject> {
        let endedBy: BridgeWire.DictateEnd = timedOut ? .timeout : (stopped ? .stop : .user)
        switch outcome {
        case .completed(let text):
            return .success(.init(text: text, durationSeconds: duration, timedOut: timedOut, endedBy: endedBy))
        case .empty:
            return timedOut
                ? .failure(.domain(.timeout, message: "no speech within the time limit"))
                : .success(.init(text: "", durationSeconds: duration, timedOut: false, endedBy: stopped ? .stop : .user))
        case .secureField:
            return .failure(.domain(.secureField, message: "a password field was focused; dictation refused"))
        case .cancelled:
            return .failure(.domain(.cancelled, message: "the user declined to answer — do not retry"))
        case .error(let message):
            return .failure(.domain(.audioUnavailable, message: message))
        }
    }
}

/// The overlay presentation of an agent's dictate request: the attribution line
/// ("X asks: …"), the quiet client eyebrow, and the hero question. Sanitized
/// (control/bidi stripped, capped) and always framed as the CLIENT asking —
/// agent-controlled text must never read as OpenWhisp's own voice. `question` is
/// nil (not empty) when the agent gave no prompt so the overlay falls back
/// cleanly. Extracted from AppState so the framing rules are unit-testable.
public struct AgentPromptPresentation: Equatable {
    public let banner: String
    public let clientLabel: String
    public let question: String?

    public init(clientName: String, prompt: String?) {
        let displayClient = BridgeWire.sanitizedForDisplay(clientName, maxLength: 60)
        clientLabel = displayClient.isEmpty ? "An agent" : displayClient
        let displayQuestion = prompt.map { BridgeWire.sanitizedForDisplay($0, maxLength: 200) } ?? ""
        question = displayQuestion.isEmpty ? nil : displayQuestion
        banner = displayQuestion.isEmpty
            ? "\(clientLabel) asked you to dictate"
            : "\(clientLabel) asks: \(displayQuestion)"
    }
}

public enum SessionOutcome: Equatable {
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
