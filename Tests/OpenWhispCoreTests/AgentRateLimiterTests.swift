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
