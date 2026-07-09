import Foundation

// MARK: - Server launch retry policy

/// Pure, dependency-free decision logic for "should a failed server launch be
/// retried on a fresh port?" — shared in spirit by `WhisperEngine` and
/// `LlamaServerEngine`'s loopback-port retry (MAK-28).
///
/// The retry exists to close the port-bind race: a launch that binds a port we
/// probed-then-closed can lose it to another process, surfacing as a *health
/// failure*. Retrying on a fresh port recovers from that. But a launch that was
/// **cancelled** by a concurrent `stopServer()`/model-switch (the user tore the
/// server down, or is quitting) must NOT be retried — retrying would relaunch a
/// server the user just stopped, orphaning it (especially on quit). That is the
/// MAK-28 review's finding #2.
///
/// The decision — given the outcome of one attempt and how many attempts remain
/// — is pure and trivially unit-testable, so it lives here and both engines'
/// retry loops route through it once.
enum ServerLaunchRetry {

    /// The outcome of a single launch/health attempt, from the engine's point of
    /// view.
    enum Outcome: Equatable {
        /// The server launched and became healthy — done.
        case launched
        /// The server launched but never became healthy (crash, bad model, or a
        /// lost port-bind race). This is the ONLY outcome that should retry.
        case healthFailed
        /// The attempt was cancelled by a concurrent stop / generation
        /// invalidation / model switch — the user tore this server down. Never
        /// retry: doing so would relaunch a server the user just stopped.
        case cancelled
    }

    /// What the engine should do after an attempt.
    enum Decision: Equatable {
        /// Report success to the caller.
        case succeed
        /// Retry the launch on a fresh port (there is budget left and the
        /// failure was a retryable health failure).
        case retry
        /// Stop trying and report failure to the caller (either the failure was
        /// non-retryable — cancelled — or the retry budget is exhausted).
        case giveUp
    }

    /// Decide the next step given one attempt's `outcome` and how many attempts
    /// remain INCLUDING the one just performed (`attemptsRemaining >= 1`).
    ///
    /// - `.launched` ⇒ `.succeed`.
    /// - `.cancelled` ⇒ `.giveUp` (never retry a user-initiated teardown).
    /// - `.healthFailed` ⇒ `.retry` while `attemptsRemaining > 1`, else `.giveUp`.
    static func decide(outcome: Outcome, attemptsRemaining: Int) -> Decision {
        switch outcome {
        case .launched:
            return .succeed
        case .cancelled:
            return .giveUp
        case .healthFailed:
            return attemptsRemaining > 1 ? .retry : .giveUp
        }
    }
}
