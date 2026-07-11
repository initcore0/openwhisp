import Foundation

/// Decides when an END-OF-UTTERANCE (EOU) event should finish an AGENT-initiated
/// dictation session (MAK-46 Phase 5).
///
/// Deferred pain point: agent-initiated dictation has no human "done" signal — it
/// ends on the client stop, a timeout, or the silence detector. The Parakeet EOU
/// streaming variant emits end-of-utterance timestamps, which is a crisper "the
/// human finished speaking" signal than an energy-silence run. This policy turns
/// an EOU event into a stop decision, but only after a short settle window with no
/// new partials — so a mid-sentence EOU blip (the model marking a clause boundary)
/// doesn't cut the speaker off.
///
/// Scope is enforced by the CALLER (agent sessions only, never a user hotkey
/// session, and only when the setting is on) — this type is the pure timing rule.
/// Foundation-only + unit-tested.
struct AgentEouAutoStop {
    struct Config: Equatable {
        /// How long after the latest EOU event we must see NO new partial before
        /// finishing. A new partial (the speaker kept going) cancels the pending
        /// stop. Default 600 ms — long enough to ride through a clause-boundary
        /// EOU, short enough to feel prompt.
        var settleMs: Int = 600
        static let `default` = Config()
    }

    private let config: Config
    /// Uptime (seconds) of the most recent EOU event with no newer partial, or nil
    /// when there is no pending stop (never saw an EOU, or a partial cancelled it).
    private var pendingSince: Double?

    init(config: Config = .default) {
        self.config = config
    }

    /// Record that an EOU event fired at `now` (seconds, monotonic uptime). Arms
    /// the settle window.
    mutating func noteEou(now: Double) {
        pendingSince = now
    }

    /// Record that a new partial arrived at `now`. The speaker is still going, so
    /// cancel any pending EOU stop.
    mutating func notePartial() {
        pendingSince = nil
    }

    /// Should the session finish as of `now`? True once an EOU has been pending
    /// for at least `settleMs` with no intervening partial. Idempotent-safe: the
    /// caller clears the detector after acting, but calling again returns true
    /// until then.
    func shouldStop(now: Double) -> Bool {
        guard let since = pendingSince else { return false }
        // 0.5 ms slack absorbs float error at the exact boundary (0.6 s of
        // seconds-scale arithmetic lands a hair under 600 ms).
        return (now - since) * 1000.0 >= Double(config.settleMs) - 0.5
    }
}
