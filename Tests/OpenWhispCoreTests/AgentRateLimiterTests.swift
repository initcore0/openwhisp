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
        limiter.record(clientName: "c", now: t0)
        // 3s later: still inside the 10s cooldown → 7s to wait.
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(3)) else {
            return XCTFail("expected throttled")
        }
        XCTAssertEqual(retry, 7, accuracy: 0.001)
    }

    func testCooldownExpires() {
        var limiter = AgentRateLimiter(cooldownSeconds: 10, maxSessionsPerHour: 0)
        limiter.record(clientName: "c", now: t0)
        XCTAssertEqual(limiter.check(clientName: "c", now: t0.addingTimeInterval(10)), .allow)
        XCTAssertEqual(limiter.check(clientName: "c", now: t0.addingTimeInterval(11)), .allow)
    }

    func testCooldownIsPerClient() {
        var limiter = AgentRateLimiter(cooldownSeconds: 10, maxSessionsPerHour: 0)
        limiter.record(clientName: "a", now: t0)
        // A different client isn't throttled by a's start.
        XCTAssertEqual(limiter.check(clientName: "b", now: t0.addingTimeInterval(1)), .allow)
    }

    // MARK: Sessions-per-hour cap

    func testCapBlocksAfterQuota() {
        var limiter = AgentRateLimiter(cooldownSeconds: 0, maxSessionsPerHour: 3, windowSeconds: 3600)
        // Three accepted starts spread out so the cooldown never binds.
        limiter.record(clientName: "c", now: t0)
        limiter.record(clientName: "c", now: t0.addingTimeInterval(60))
        limiter.record(clientName: "c", now: t0.addingTimeInterval(120))
        // Fourth within the hour → throttled until the oldest (t0) ages out at t0+3600.
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(200)) else {
            return XCTFail("expected throttled")
        }
        XCTAssertEqual(retry, 3400, accuracy: 0.001) // 3600 - 200
    }

    func testCapSlidesAsStartsAgeOut() {
        var limiter = AgentRateLimiter(cooldownSeconds: 0, maxSessionsPerHour: 2, windowSeconds: 3600)
        limiter.record(clientName: "c", now: t0)
        limiter.record(clientName: "c", now: t0.addingTimeInterval(100))
        // Full at t0+200.
        XCTAssertFalse(isAllowed(limiter.check(clientName: "c", now: t0.addingTimeInterval(200))))
        // Once the first start ages out (just past t0+3600), a slot frees up.
        XCTAssertTrue(isAllowed(limiter.check(clientName: "c", now: t0.addingTimeInterval(3601))))
    }

    func testCapZeroDisablesWindowLimit() {
        var limiter = AgentRateLimiter(cooldownSeconds: 0, maxSessionsPerHour: 0)
        for i in 0..<100 { limiter.record(clientName: "c", now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(limiter.check(clientName: "c", now: t0.addingTimeInterval(100)), .allow)
    }

    // MARK: Both limits together — retryAfter is the max wait

    func testRetryAfterIsMaxOfCooldownAndCap() {
        var limiter = AgentRateLimiter(cooldownSeconds: 30, maxSessionsPerHour: 2, windowSeconds: 3600)
        limiter.record(clientName: "c", now: t0)
        limiter.record(clientName: "c", now: t0.addingTimeInterval(3595))
        // At t0+3600: cap says wait ~3600 (oldest ages out at t0+3600, i.e. now),
        // but cooldown from the 3595 start says wait 25s more. Cap is essentially
        // satisfied; cooldown dominates.
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(3600)) else {
            return XCTFail("expected throttled")
        }
        XCTAssertEqual(retry, 25, accuracy: 0.001) // 30 - (3600 - 3595)
    }

    // MARK: forget / count

    func testForgetClearsBudget() {
        var limiter = AgentRateLimiter(cooldownSeconds: 10, maxSessionsPerHour: 1)
        limiter.record(clientName: "c", now: t0)
        XCTAssertFalse(isAllowed(limiter.check(clientName: "c", now: t0.addingTimeInterval(1))))
        limiter.forget(clientName: "c")
        XCTAssertTrue(isAllowed(limiter.check(clientName: "c", now: t0.addingTimeInterval(1))))
    }

    func testSessionCountPrunesOldStarts() {
        var limiter = AgentRateLimiter(cooldownSeconds: 0, maxSessionsPerHour: 10, windowSeconds: 3600)
        limiter.record(clientName: "c", now: t0)
        limiter.record(clientName: "c", now: t0.addingTimeInterval(1800))
        XCTAssertEqual(limiter.sessionCount(clientName: "c", now: t0.addingTimeInterval(1800)), 2)
        // Past the window, the first start no longer counts.
        XCTAssertEqual(limiter.sessionCount(clientName: "c", now: t0.addingTimeInterval(3700)), 1)
    }

    // MARK: helpers

    private func isAllowed(_ d: AgentRateLimiter.Decision) -> Bool { d == .allow }
}
