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
    /// `biasTerms`: session-scoped workspace-context bias terms (MAK-75), derived
    /// from the client's cwd/branch/file names via `AgentContextVocabulary`.
    /// Carried ON the initiator so their lifecycle is exactly the agent session's
    /// — they exist only while the initiator is `.agent`, vanish when it resets to
    /// `.user`, and are never persisted anywhere.
    case agent(client: String, prompt: String?, biasTerms: [String] = [])

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    /// The claimed client name for an agent session (display-only; never trusted
    /// for authorization — the socket peer's code signature is what authorizes).
    public var clientName: String? {
        if case let .agent(client, _, _) = self { return client }
        return nil
    }

    /// The agent's prompt to show in the overlay, if any.
    public var prompt: String? {
        if case let .agent(_, prompt, _) = self { return prompt }
        return nil
    }

    /// Workspace-context bias terms for an agent session (MAK-75); empty for a
    /// user session or an agent session that passed no context.
    public var agentBiasTerms: [String] {
        if case let .agent(_, _, terms) = self { return terms }
        return []
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
