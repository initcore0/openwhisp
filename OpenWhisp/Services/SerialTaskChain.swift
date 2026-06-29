import Foundation

/// Serializes async operations so they run strictly in the order enqueued, each
/// fully completing before the next begins — even when callers fire them rapidly
/// from different contexts.
///
/// Foundation-only (lives in OpenWhispCore, unit-tested). Its use is the WhisperKit
/// streaming lifecycle: a stop's mic/AVAudioEngine teardown MUST finish before the
/// next start's `installTap`, or the new tap races the old teardown (the "Streaming
/// Error" on a quick double-tap restart). Replaces an earlier fire-and-forget task
/// plus a 150ms magic sleep, which only papered over the race.
///
/// `@MainActor`-isolated so the read-modify-write of the chain tail is atomic; the
/// enqueued work itself hops wherever it needs to.
@MainActor
final class SerialTaskChain {
    /// Tail of the chain: the most recently enqueued operation (initially a no-op
    /// that's already complete).
    private var tail: Task<Void, Never> = Task {}

    init() {}

    /// Append `work` after everything enqueued so far. Returns immediately; `work`
    /// runs once all prior operations have completed.
    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let prior = tail
        tail = Task {
            await prior.value
            await work()
        }
    }

    /// Await the chain draining to the current tail (all work enqueued *so far*).
    /// Operations enqueued after this call are not awaited. Used by tests.
    func drain() async {
        await tail.value
    }
}
