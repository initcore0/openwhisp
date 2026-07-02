import Foundation

/// Error thrown when an awaited operation exceeds its deadline.
struct TimeoutError: Error, LocalizedError, Equatable {
    /// The label of the operation that timed out (for the user-facing message).
    let operation: String
    let seconds: Double
    var errorDescription: String? {
        "\(operation) timed out after \(Int(seconds))s."
    }
}

/// Run an async operation with a wall-clock timeout. If `operation` doesn't finish
/// within `seconds`, the timeout wins, the operation Task is cancelled, and a
/// `TimeoutError` is thrown.
///
/// Foundation-only (lives in OpenWhispCore, unit-tested) so it can guard any async
/// work. Its first use is the WhisperKit model load, whose cold ANE/CoreML
/// specialization can stall indefinitely (the documented "stuck" hang) — a bounded
/// timeout turns a force-quit into a clear, retryable error.
///
/// Note: Swift can't forcibly kill a non-cooperative task, so a callee that ignores
/// cancellation keeps running in the background until it returns; the caller is
/// freed regardless. That's why this races two UNSTRUCTURED tasks through a
/// continuation instead of using a task group: a throwing task group awaits its
/// cancelled children before rethrowing, so a wedged, cancellation-ignoring callee
/// (exactly the ANE stall this guards against) would block the timeout forever.
/// Here the loser is cancelled and abandoned — a truly wedged operation lingers
/// detached until it returns, but the caller gets its TimeoutError on time.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation operationLabel: String = "Operation",
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = TimeoutRace()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let operationTask = Task {
                let result: Result<T, Error>
                do { result = .success(try await operation()) }
                catch { result = .failure(error) }
                guard race.claim() else { return }
                race.cancelAll()   // stop the still-sleeping watchdog
                continuation.resume(with: result)
            }
            let watchdog = Task {
                let timedOut: Bool
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    timedOut = true
                } catch {
                    // Sleep cancelled: either the operation won (claim below loses)
                    // or the caller was cancelled — surface cancellation, not a
                    // bogus timeout.
                    timedOut = false
                }
                guard race.claim() else { return }
                race.cancelAll()   // cancel the (possibly non-cooperative) operation
                continuation.resume(throwing: timedOut
                    ? TimeoutError(operation: operationLabel, seconds: seconds)
                    : CancellationError())
            }
            race.register([operationTask, watchdog])
        }
    } onCancel: {
        race.cancelAll()
    }
}

/// Coordination for the timeout race: a lock-guarded once-flag so exactly one of
/// {operation, watchdog} resumes the continuation, plus the task handles so the
/// winner (or the caller's cancellation) can cancel the loser.
private final class TimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var cancelled = false
    private var tasks: [Task<Void, Never>] = []

    /// True exactly once — for whichever side finishes first.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    func register(_ racers: [Task<Void, Never>]) {
        lock.lock(); defer { lock.unlock() }
        tasks = racers
        // The caller may have been cancelled before registration completed.
        if cancelled { racers.forEach { $0.cancel() } }
    }

    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        tasks.forEach { $0.cancel() }
    }
}
