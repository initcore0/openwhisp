import Foundation

/// The finish-state machine for an AGENT-initiated dictation session (MAK-76).
///
/// Historically an agent session could only end three ways: the client called
/// `dictate.stop`, the hard timeout fired, or the silence / EOU auto-stop tripped
/// — the human had NO deliberate "I'm done" control (the deferred pain point in
/// the agent-bridge follow-ups memo). And whenever capture ended, the transcript
/// was finalized and returned immediately — there was no equivalent of Claude
/// Code /voice's configurable `autoSubmit`.
///
/// This pure policy adds both, mirroring /voice's hold/tap + autoSubmit parity:
///
///  - **Tap-to-toggle finish.** During an agent session the user's dictation
///    hotkey is a manual FINISH toggle: a tap ends the session and returns the
///    transcript NOW, overriding any pending EOU / silence settle wait. (The app
///    used to preempt the agent with a fresh USER dictation on a hotkey press; for
///    agent sessions that now means "finish this answer".)
///
///  - **autoSubmit.** When `autoSubmit` is true (the default, matching today's
///    behavior) an auto-stop (EOU / silence) finalizes and returns straight away.
///    When false, an auto-stop instead opens a brief CONFIRM window: the overlay
///    invites the user to tap-to-submit-now or tap-to-append (re-open the mic for
///    more speech), and if they do nothing the window elapses and the session
///    submits anyway. A deliberate hotkey tap always submits now regardless of
///    `autoSubmit` — an explicit finish is never held.
///
/// Scope is enforced by the CALLER (agent sessions only). This type is the pure
/// decision rule: given the current phase and an input event, what should the app
/// do. Foundation-only + unit-tested; the app owns the actual mic/timer effects.
public struct AgentSessionFinish {
    /// Where the session is in its capture→finish lifecycle. `capturing` is the
    /// normal listening state; `confirming` is the post-auto-stop hold window that
    /// only exists when `autoSubmit == false`.
    public enum Phase: Equatable {
        /// The mic is open and the human is (or may be) speaking.
        case capturing
        /// An auto-stop fired with autoSubmit off: capture is paused and the
        /// overlay is inviting submit-now / append until the window elapses.
        case confirming
    }

    /// A stimulus arriving at the machine.
    public enum Event: Equatable {
        /// The user tapped the dictation hotkey (the manual finish / append toggle).
        case hotkeyTap
        /// An auto-stop detector (silence or EOU) decided the human stopped.
        case autoStopFired
        /// The confirm window elapsed with no user action.
        case confirmWindowElapsed
    }

    /// What the app should do in response. The app maps these onto its existing
    /// effects (stop capture + finalize, re-open the mic, arm a timer, …).
    public enum Action: Equatable {
        /// Nothing to do — the event doesn't apply in this phase.
        case none
        /// End capture, finalize, and return the transcript to the agent NOW.
        case finishNow
        /// Pause capture and open the confirm/append hold window (arm its timer).
        case beginConfirmWindow
        /// Re-open the mic to append more speech to the same session.
        case reopenForAppend
    }

    /// Whether an auto-stop finalizes immediately (true, the legacy behavior) or
    /// opens the confirm window (false).
    public let autoSubmit: Bool

    /// The machine's current phase. Owned here (not by the app) so AppState only
    /// relays events and applies the returned command — see `handle(_:)`.
    public private(set) var phase: Phase = .capturing

    /// How long the confirm window stays open before auto-submitting, when
    /// `autoSubmit` is false. Sane default: long enough to react, short enough not
    /// to strand the blocked agent call. The app arms a real timer for this.
    public let confirmWindow: TimeInterval

    /// Default confirm window: 4s. Comfortably under the 60s default dictate
    /// timeout, and matches the "brief" affordance the ticket asks for.
    public static let defaultConfirmWindow: TimeInterval = 4.0

    public init(autoSubmit: Bool = true, confirmWindow: TimeInterval = AgentSessionFinish.defaultConfirmWindow) {
        self.autoSubmit = autoSubmit
        self.confirmWindow = confirmWindow
    }

    /// Relay `event` through the machine: decides the action AND advances `phase`
    /// in one step. This is the app-facing entry point — AppState calls this and
    /// applies the returned command, keeping all decision logic here.
    ///
    /// Effect notes for the app (documented here so the call sites stay thin):
    ///  - `finishNow` ⇒ cancel any confirm timer + auto-stop detectors, then run
    ///    the normal agent finalize (endedBy: .user).
    ///  - `beginConfirmWindow` ⇒ show the confirm hint and arm a `confirmWindow`
    ///    timer whose expiry relays `.confirmWindowElapsed`. Capture is NOT torn
    ///    down: the streaming/recording pipelines have no resume primitive, so the
    ///    window is a live-buffer grace period — the mic stays open, audio keeps
    ///    flowing into the same session buffer (a user who keeps talking is
    ///    naturally captured), and the hard dictate timeout stays armed as the
    ///    overall ceiling. Finalize runs only on a `finishNow`.
    ///  - `reopenForAppend` ⇒ cancel the confirm timer, hide the hint, and re-arm
    ///    the silence detector so a later pause can auto-stop again.
    public mutating func handle(_ event: Event) -> Action {
        let a = action(for: event, in: phase)
        phase = next(after: a, in: phase)
        return a
    }

    /// Decide the action for `event` given the current `phase`. Pure — the caller
    /// is responsible for actually transitioning phase (via `next(after:in:)`) and
    /// running the effect.
    public func action(for event: Event, in phase: Phase) -> Action {
        switch (phase, event) {
        // A deliberate hotkey tap while capturing always finishes now — an explicit
        // human "done" is never held for a confirm window. This is what overrides a
        // pending EOU / silence settle wait.
        case (.capturing, .hotkeyTap):
            return .finishNow
        // A hotkey tap DURING the confirm hold means "I have more to say" — re-open
        // the mic to append to the same answer, rather than submitting a
        // half-finished thought. The user submits by letting the window elapse (or
        // by tapping again once back in `capturing`).
        case (.confirming, .hotkeyTap):
            return .reopenForAppend

        // An auto-stop finalizes immediately with autoSubmit on; otherwise it opens
        // the confirm window. In the confirm phase a further auto-stop is moot
        // (capture is already paused).
        case (.capturing, .autoStopFired):
            return autoSubmit ? .finishNow : .beginConfirmWindow
        case (.confirming, .autoStopFired):
            return .none

        // The confirm window elapsing submits what was captured. It's meaningless
        // while still capturing (no window is armed).
        case (.confirming, .confirmWindowElapsed):
            return .finishNow
        case (.capturing, .confirmWindowElapsed):
            return .none
        }
    }

    /// The phase the session moves to after `action` runs from `phase`. Kept next
    /// to `action(for:in:)` so the transition table is unit-tested as one unit.
    public func next(after action: Action, in phase: Phase) -> Phase {
        switch action {
        case .beginConfirmWindow:
            return .confirming
        case .reopenForAppend:
            return .capturing
        case .finishNow, .none:
            // finishNow tears the session down entirely; the phase is irrelevant
            // afterwards, so leave it unchanged and let the caller drop the machine.
            return phase
        }
    }
}
