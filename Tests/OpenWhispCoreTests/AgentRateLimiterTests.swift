import XCTest
@testable import OpenWhispCore

final class AgentRateLimiterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Cooldown

    func testFirstStartAlwaysAllowed() {
        let limiter = AgentRateLimiter(cooldownSeconds: 5, maxSessionsPerHour: 30)
        XCTAssertEqual(limiter.check(clientName: "c", now: t0), .allow)
    }

    func testCooldownBlocksBackToBack() {
        var limiter = AgentRateLimiter(cooldownSeconds: 10, maxSessionsPerHour: 0)
        limiter.recordStart(clientName: "c", now: t0)
        // 3s later: still inside the 10s cooldown → 7s to wait.
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(3)) else {
            return XCTFail("expected throttled")
        }
        XCTAssertEqual(retry, 7, accuracy: 0.001)
    }

    func testCooldownExpires() {
        var limiter = AgentRateLimiter(cooldownSeconds: 10, maxSessionsPerHour: 0)
        limiter.recordStart(clientName: "c", now: t0)
        XCTAssertEqual(limiter.check(clientName: "c", now: t0.addingTimeInterval(10)), .allow)
        XCTAssertEqual(limiter.check(clientName: "c", now: t0.addingTimeInterval(11)), .allow)
    }

    func testCooldownIsPerClient() {
        var limiter = AgentRateLimiter(cooldownSeconds: 10, maxSessionsPerHour: 0)
        limiter.recordStart(clientName: "a", now: t0)
        // A different client isn't throttled by a's start.
        XCTAssertEqual(limiter.check(clientName: "b", now: t0.addingTimeInterval(1)), .allow)
    }

    // MARK: Sessions-per-hour cap

    func testCapBlocksAfterQuota() {
        var limiter = AgentRateLimiter(cooldownSeconds: 0, maxSessionsPerHour: 3, windowSeconds: 3600)
        // Three accepted starts spread out so the cooldown never binds.
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordStart(clientName: "c", now: t0.addingTimeInterval(60))
        limiter.recordStart(clientName: "c", now: t0.addingTimeInterval(120))
        // Fourth within the hour → throttled until the oldest (t0) ages out at t0+3600.
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(200)) else {
            return XCTFail("expected throttled")
        }
        XCTAssertEqual(retry, 3400, accuracy: 0.001) // 3600 - 200
    }

    func testCapSlidesAsStartsAgeOut() {
        var limiter = AgentRateLimiter(cooldownSeconds: 0, maxSessionsPerHour: 2, windowSeconds: 3600)
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordStart(clientName: "c", now: t0.addingTimeInterval(100))
        // Full at t0+200.
        XCTAssertFalse(isAllowed(limiter.check(clientName: "c", now: t0.addingTimeInterval(200))))
        // Once the first start ages out (just past t0+3600), a slot frees up.
        XCTAssertTrue(isAllowed(limiter.check(clientName: "c", now: t0.addingTimeInterval(3601))))
    }

    func testCapZeroDisablesWindowLimit() {
        var limiter = AgentRateLimiter(cooldownSeconds: 0, maxSessionsPerHour: 0)
        for i in 0..<100 { limiter.recordStart(clientName: "c", now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(limiter.check(clientName: "c", now: t0.addingTimeInterval(100)), .allow)
    }

    // MARK: Both limits together — retryAfter is the max wait

    func testRetryAfterIsMaxOfCooldownAndCap() {
        var limiter = AgentRateLimiter(cooldownSeconds: 30, maxSessionsPerHour: 2, windowSeconds: 3600)
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordStart(clientName: "c", now: t0.addingTimeInterval(3595))
        // At t0+3600: cap says wait ~3600 (oldest ages out at t0+3600, i.e. now),
        // but cooldown from the 3595 start says wait 25s more. Cap is essentially
        // satisfied; cooldown dominates.
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(3600)) else {
            return XCTFail("expected throttled")
        }
        XCTAssertEqual(retry, 25, accuracy: 0.001) // 30 - (3600 - 3595)
    }

    // MARK: Cooldown runs from the session's END

    func testCooldownRunsFromSessionEnd() {
        var limiter = AgentRateLimiter(cooldownSeconds: 10, maxSessionsPerHour: 0, maxListeningSecondsPerHour: 0)
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordEnd(clientName: "c", now: t0.addingTimeInterval(60))
        // 5s after the END (65s after the start): a start-to-start cooldown would
        // long since have passed, but the inter-session gap hasn't.
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(65)) else {
            return XCTFail("expected throttled")
        }
        XCTAssertEqual(retry, 5, accuracy: 0.001)
        XCTAssertEqual(limiter.check(clientName: "c", now: t0.addingTimeInterval(70)), .allow)
    }

    // MARK: Listening-time budget

    func testListeningBudgetBlocksWhenExhausted() {
        var limiter = AgentRateLimiter(
            cooldownSeconds: 0, maxSessionsPerHour: 0,
            maxListeningSecondsPerHour: 600, windowSeconds: 3600
        )
        // Two 300s (max-length) sessions → 600s of mic time, the whole budget.
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordEnd(clientName: "c", now: t0.addingTimeInterval(300))
        limiter.recordStart(clientName: "c", now: t0.addingTimeInterval(400))
        limiter.recordEnd(clientName: "c", now: t0.addingTimeInterval(700))
        // Throttled until the FIRST session ages out (t0+3600) and frees 300s.
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(800)) else {
            return XCTFail("expected throttled")
        }
        XCTAssertEqual(retry, 2800, accuracy: 0.001) // 3600 - 800
        // Once it has aged out, half the budget is back.
        XCTAssertEqual(limiter.check(clientName: "c", now: t0.addingTimeInterval(3601)), .allow)
    }

    func testListeningBudgetIgnoresShortSessions() {
        var limiter = AgentRateLimiter(
            cooldownSeconds: 0, maxSessionsPerHour: 0,
            maxListeningSecondsPerHour: 600, windowSeconds: 3600
        )
        // Many short answers stay well under the budget.
        for i in 0..<20 {
            let start = t0.addingTimeInterval(Double(i) * 60)
            limiter.recordStart(clientName: "c", now: start)
            limiter.recordEnd(clientName: "c", now: start.addingTimeInterval(10))
        }
        XCTAssertEqual(limiter.check(clientName: "c", now: t0.addingTimeInterval(1200)), .allow)
    }

    func testRecordEndWithoutStartIsNoOp() {
        var limiter = AgentRateLimiter()
        limiter.recordEnd(clientName: "c", now: t0) // must not crash or record
        XCTAssertEqual(limiter.sessionCount(clientName: "c", now: t0), 0)
    }

    // MARK: Long session straddling the window edge (MAK-31)
    //
    // A session's `start` (the clock the cap and budget age-outs use) can predate
    // the window while its `lastActivity` (`start + seconds`, the cooldown clock)
    // still falls inside it, so `pruned()` keeps it. The age-out math must never go
    // negative in that case, and cap membership must follow the same clock.

    func testCapAgeOutFlooredWhenStraddlingSessionStartPredatesWindow() {
        // windowSeconds 3600. A single very long session: starts at t0, holds the
        // mic for 3300s, so lastActivity = t0+3300. The cap is 1, so this session
        // alone fills it.
        var limiter = AgentRateLimiter(
            cooldownSeconds: 1, maxSessionsPerHour: 1,
            maxListeningSecondsPerHour: 0, windowSeconds: 3600
        )
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordEnd(clientName: "c", now: t0.addingTimeInterval(3300))

        // At t0+3601 the start (t0) already predates the window (cutoff t0+1), but
        // lastActivity (t0+3300) survives pruning, so the session is still counted
        // as in-window membership — matching the cooldown clock.
        let now = t0.addingTimeInterval(3601)
        XCTAssertEqual(limiter.sessionCount(clientName: "c", now: now), 1)

        // The cap is full (1/1), so the cap branch runs with oldest.start = t0,
        // which is *before* the window: the raw age-out is 3600 - 3601 = -1. The
        // floor pins it to 0, so the cap contributes no wait and — the cooldown
        // having long expired — the client is allowed. The invariant we lock: the
        // decision is never a *negative* throttle, and here it resolves to .allow.
        switch limiter.check(clientName: "c", now: now) {
        case .allow:
            break
        case .throttled(let retry):
            XCTAssertGreaterThanOrEqual(retry, 0, "cap age-out must never be negative")
        }
    }

    func testCapAgeOutUsesStartClockForInWindowStraddlingSession() {
        // Same straddling shape, but checked while the start is still *inside* the
        // window, so the age-out is legitimately positive and its exact value pins
        // that the cap measures from `start` (not `lastActivity`).
        var limiter = AgentRateLimiter(
            cooldownSeconds: 0, maxSessionsPerHour: 1,
            maxListeningSecondsPerHour: 0, windowSeconds: 3600
        )
        limiter.recordStart(clientName: "c", now: t0)                       // start = t0
        limiter.recordEnd(clientName: "c", now: t0.addingTimeInterval(3000)) // lastActivity = t0+3000

        // At t0+3100: start (t0) is 3100s old, lastActivity (t0+3000) is 100s old.
        // Cap is full → wait for the start to age out at t0+3600, i.e. 500s. A
        // lastActivity-keyed age-out would instead say 3600 - 100 = 3500 (wrong).
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(3100)) else {
            return XCTFail("expected throttled — cap is full")
        }
        XCTAssertEqual(retry, 500, accuracy: 0.001) // 3600 - 3100, keyed on start
    }

    func testBudgetWaitFlooredWhenStraddlingSessionStartPredatesWindow() {
        // A long session that alone exhausts the listening budget and whose start
        // predates the window at check time.
        var limiter = AgentRateLimiter(
            cooldownSeconds: 1, maxSessionsPerHour: 0,
            maxListeningSecondsPerHour: 600, windowSeconds: 3600
        )
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordEnd(clientName: "c", now: t0.addingTimeInterval(3300)) // 3300s > 600 budget

        // At t0+3601: start predates the window, lastActivity (t0+3300) keeps the
        // session alive, budget is exhausted → the wait loop runs. Pre-fix it would
        // compute 3600 - 3601 = -1; the floor keeps it >= 0.
        let now = t0.addingTimeInterval(3601)
        switch limiter.check(clientName: "c", now: now) {
        case .allow:
            break
        case .throttled(let retry):
            XCTAssertGreaterThanOrEqual(retry, 0, "budget wait must never be negative")
        }
    }

    // MARK: forget / count

    func testForgetClearsBudget() {
        var limiter = AgentRateLimiter(cooldownSeconds: 10, maxSessionsPerHour: 1)
        limiter.recordStart(clientName: "c", now: t0)
        XCTAssertFalse(isAllowed(limiter.check(clientName: "c", now: t0.addingTimeInterval(1))))
        limiter.forget(clientName: "c")
        XCTAssertTrue(isAllowed(limiter.check(clientName: "c", now: t0.addingTimeInterval(1))))
    }

    func testSessionCountPrunesOldStarts() {
        var limiter = AgentRateLimiter(cooldownSeconds: 0, maxSessionsPerHour: 10, windowSeconds: 3600)
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordStart(clientName: "c", now: t0.addingTimeInterval(1800))
        XCTAssertEqual(limiter.sessionCount(clientName: "c", now: t0.addingTimeInterval(1800)), 2)
        // Past the window, the first start no longer counts.
        XCTAssertEqual(limiter.sessionCount(clientName: "c", now: t0.addingTimeInterval(3700)), 1)
    }

    // MARK: helpers

    private func isAllowed(_ d: AgentRateLimiter.Decision) -> Bool { d == .allow }
}
