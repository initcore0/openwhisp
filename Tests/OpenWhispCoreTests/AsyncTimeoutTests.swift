import XCTest
@testable import OpenWhispCore

/// The async timeout guard used to bound the WhisperKit cold-start load so a stall
/// surfaces a retryable error instead of wedging the app.
final class AsyncTimeoutTests: XCTestCase {

    func testReturnsValueWhenOperationFinishesInTime() async throws {
        let value = try await withTimeout(seconds: 5, operation: "fast") {
            return 42
        }
        XCTAssertEqual(value, 42)
    }

    func testThrowsTimeoutWhenOperationTooSlow() async {
        do {
            _ = try await withTimeout(seconds: 0.05, operation: "slow") {
                try await Task.sleep(nanoseconds: 2_000_000_000)   // 2s, well past the 50ms limit
                return 1
            }
            XCTFail("expected a timeout")
        } catch let error as TimeoutError {
            XCTAssertEqual(error.operation, "slow")
            XCTAssertEqual(error.seconds, 0.05)
        } catch {
            XCTFail("expected TimeoutError, got \(error)")
        }
    }

    func testPropagatesOperationError() async {
        struct Boom: Error {}
        do {
            _ = try await withTimeout(seconds: 5, operation: "boom") {
                throw Boom()
            }
            XCTFail("expected the operation's error")
        } catch is Boom {
            // expected — the operation's own error wins, not a timeout
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }

    func testTimeoutErrorMessageMentionsOperation() {
        let e = TimeoutError(operation: "Loading model", seconds: 120)
        XCTAssertEqual(e.errorDescription, "Loading model timed out after 120s.")
    }

    /// The fast path shouldn't wait anywhere near the (large) timeout — a quick
    /// operation returns promptly even with a long deadline.
    func testFastOperationDoesNotWaitForLongTimeout() async throws {
        let start = Date()
        _ = try await withTimeout(seconds: 600, operation: "quick") { return true }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    /// Regression: the timeout must fire even when the operation IGNORES
    /// cancellation — the WhisperKit ANE/CoreML stall this guard exists for. The
    /// old task-group implementation awaited the cancelled (wedged) child before
    /// rethrowing, so the caller never got the error. A never-resumed continuation
    /// simulates the non-cooperative stall: it suspends forever and never observes
    /// cancellation.
    func testTimesOutWhenOperationIgnoresCancellation() async {
        let start = Date()
        do {
            _ = try await withTimeout(seconds: 0.1, operation: "wedged") {
                await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in
                    // Never resumed — the operation is wedged for good.
                }
            }
            XCTFail("expected a timeout")
        } catch let error as TimeoutError {
            XCTAssertEqual(error.operation, "wedged")
            // The caller must be freed at the deadline, not wedged behind the op.
            XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
        } catch {
            XCTFail("expected TimeoutError, got \(error)")
        }
    }

    /// Cancelling the caller while the operation is in flight frees the caller
    /// promptly (with CancellationError, not a bogus TimeoutError).
    func testCallerCancellationFreesTheAwait() async {
        let task = Task { () -> Bool in
            do {
                _ = try await withTimeout(seconds: 600, operation: "cancelled") {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return 1
                }
                return false
            } catch {
                return error is CancellationError
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)   // let the op start
        task.cancel()
        let sawCancellation = await task.value
        XCTAssertTrue(sawCancellation)
    }
}
