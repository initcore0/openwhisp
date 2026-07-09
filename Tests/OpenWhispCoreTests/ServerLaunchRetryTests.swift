import XCTest
@testable import OpenWhispCore

/// Unit tests for the pure server-launch retry decision (MAK-28 review #2): the
/// loopback-port retry must recover from a lost port-bind race (a *health
/// failure*) but must NEVER relaunch a server the user just stopped (a
/// *cancellation*) — that would orphan a server, especially on quit.
final class ServerLaunchRetryTests: XCTestCase {

    // MARK: - Success short-circuits regardless of budget

    func testLaunchedSucceeds() {
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .launched, attemptsRemaining: 3),
            .succeed
        )
    }

    func testLaunchedSucceedsEvenWithOneAttemptLeft() {
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .launched, attemptsRemaining: 1),
            .succeed
        )
    }

    // MARK: - The core of review #2: cancellation must NOT retry

    func testCancelledGivesUpEvenWithBudgetLeft() {
        // A concurrent stopServer()/model-switch cancelled this launch. Even
        // with attempts remaining, retrying would relaunch a server the user
        // just tore down (an orphan on quit) — so we must give up.
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .cancelled, attemptsRemaining: 3),
            .giveUp
        )
    }

    func testCancelledGivesUpWithFullBudget() {
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .cancelled, attemptsRemaining: 10),
            .giveUp
        )
    }

    func testCancelledGivesUpAtLastAttempt() {
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .cancelled, attemptsRemaining: 1),
            .giveUp
        )
    }

    // MARK: - Health failure retries while budget remains

    func testHealthFailedRetriesWithBudget() {
        // The retryable case: a lost port-bind race surfaces as a health
        // failure. Retry on a fresh port.
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .healthFailed, attemptsRemaining: 3),
            .retry
        )
    }

    func testHealthFailedRetriesWithTwoAttemptsLeft() {
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .healthFailed, attemptsRemaining: 2),
            .retry
        )
    }

    func testHealthFailedGivesUpAtLastAttempt() {
        // Budget exhausted (this was the last attempt) — give up.
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .healthFailed, attemptsRemaining: 1),
            .giveUp
        )
    }

    func testHealthFailedGivesUpWithZeroBudget() {
        // Defensive: a non-positive budget never retries.
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .healthFailed, attemptsRemaining: 0),
            .giveUp
        )
    }

    // MARK: - The full 3-attempt sequence a health-failing launch drives

    func testThreeAttemptHealthFailureSequenceRetriesTwiceThenGivesUp() {
        // Attempt 1 of 3 and attempt 2 of 3 retry; attempt 3 of 3 gives up —
        // exactly the "up to 3 launches" bound the engines document.
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .healthFailed, attemptsRemaining: 3),
            .retry
        )
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .healthFailed, attemptsRemaining: 2),
            .retry
        )
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .healthFailed, attemptsRemaining: 1),
            .giveUp
        )
    }

    func testCancellationMidSequenceStopsRetrying() {
        // Even mid-sequence with budget left, a cancellation ends the retry
        // loop — the server the user stopped must not be relaunched.
        XCTAssertEqual(
            ServerLaunchRetry.decide(outcome: .cancelled, attemptsRemaining: 2),
            .giveUp
        )
    }
}
