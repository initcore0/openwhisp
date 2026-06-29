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
/// freed regardless. WhisperKit's load is the realistic case where the caller must
/// not be wedged forever, which this delivers.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation operationLabel: String = "Operation",
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw TimeoutError(operation: operationLabel, seconds: seconds)
        }
        // The first task to finish wins; cancel the rest (the sleeper, or the slow
        // operation if the timeout fired first).
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TimeoutError(operation: operationLabel, seconds: seconds)
        }
        return result
    }
}
