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
    // A session's `start` (the clock the cap and budget key on) can age past the
    // window while its `lastActivity` (`start + seconds`, the cooldown clock) still
    // falls inside it, so `pruned()` keeps it for the cooldown. Because the cap and
    // budget decide membership on `start`, such a straddler is NOT in-window for
    // them: its cap slot has already aged out, and — crucially — it can no longer
    // shield *new* in-window starts from the cap. Earlier code counted the
    // straddler for the cap and floored its negative age-out to 0, which let new
    // starts pile up unbounded behind it (a session-cap bypass); the fix keys cap
    // membership and age-out on the same `start` clock so the invariant holds by
    // construction.

    func testStraddlingSessionDoesNotBypassCapForNewInWindowStarts() {
        // The reviewer's bypass scenario, now asserted to be throttled.
        // windowSeconds 3600, cap 1, cooldown 1. A single long session S1 starts at
        // t0 and holds the mic for 3300s, so lastActivity = t0+3300.
        var limiter = AgentRateLimiter(
            cooldownSeconds: 1, maxSessionsPerHour: 1,
            maxListeningSecondsPerHour: 0, windowSeconds: 3600
        )
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordEnd(clientName: "c", now: t0.addingTimeInterval(3300))

        // At t0+3601 S1's start (t0) has aged past the window (cutoff t0+1), so it
        // no longer occupies a cap slot even though its lastActivity (t0+3300) keeps
        // it around for the cooldown. The cap count (keyed on start) is 0, and the
        // cooldown long expired, so a fresh start is legitimately allowed here.
        let afterStraddler = t0.addingTimeInterval(3601)
        XCTAssertEqual(limiter.sessionCount(clientName: "c", now: afterStraddler), 0)
        XCTAssertEqual(limiter.check(clientName: "c", now: afterStraddler), .allow)

        // The client takes that slot: S2 starts at t0+3601. S1 still lingers in the
        // history (its lastActivity keeps it past pruning), but it must NOT shield
        // S2 from the cap.
        limiter.recordStart(clientName: "c", now: afterStraddler)

        // One second later the cap is full again — via S2's own in-window start, not
        // the stale straddler. Pre-fix this returned .allow forever (oldest stayed
        // S1 with a floored 0 age-out); now it's throttled until S2 ages out.
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(3602)) else {
            return XCTFail("expected throttled — the cap must count S2, not the aged-out straddler")
        }
        // 3600 - (3602 - 3601) = 3599, keyed on S2's start (t0+3601).
        XCTAssertEqual(retry, 3599, accuracy: 0.001)
    }

    func testStraddlerNeverAllowsUnlimitedStartsAsNewOnesPileUp() {
        // Directly exercises the pile-up the old bypass allowed: with the straddler
        // still lingering, repeatedly attempting a new start must NOT keep returning
        // .allow. After the first new in-window start is taken, further attempts are
        // throttled with a positive retryAfter derived from that in-window start.
        var limiter = AgentRateLimiter(
            cooldownSeconds: 1, maxSessionsPerHour: 1,
            maxListeningSecondsPerHour: 0, windowSeconds: 3600
        )
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordEnd(clientName: "c", now: t0.addingTimeInterval(3300)) // lastActivity t0+3300

        // Straddler's slot has aged out at t0+3601 → one start is allowed. Take it.
        let s2Start = t0.addingTimeInterval(3601)
        XCTAssertEqual(limiter.check(clientName: "c", now: s2Start), .allow)
        limiter.recordStart(clientName: "c", now: s2Start)

        // Now hammer the limiter every cooldown interval, as the reviewer's step 3
        // describes. Every one of these must be throttled — never .allow — because
        // the in-window start S2 (t0+3601) fills the cap of 1 and the straddler no
        // longer masks it.
        for offset in stride(from: 3602.0, through: 3650.0, by: 1.0) {
            let now = t0.addingTimeInterval(offset)
            guard case .throttled(let retry) = limiter.check(clientName: "c", now: now) else {
                return XCTFail("bypass: cap allowed a start at t0+\(offset) behind a lingering straddler")
            }
            // Wait is derived from S2's start (t0+3601), not the straddler: it's the
            // time until S2 ages out, always positive within the window.
            let expected = 3600 - (offset - 3601)
            XCTAssertEqual(retry, expected, accuracy: 0.001,
                           "retryAfter at t0+\(offset) must track S2's in-window start")
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

    func testStraddlingSessionDropsOutOfBudgetOnceStartAgesOut() {
        // A long session that alone exhausts the listening budget and whose start
        // has aged past the window at check time must no longer count against the
        // budget — its mic time began more than a window ago.
        var limiter = AgentRateLimiter(
            cooldownSeconds: 1, maxSessionsPerHour: 0,
            maxListeningSecondsPerHour: 600, windowSeconds: 3600
        )
        limiter.recordStart(clientName: "c", now: t0)
        limiter.recordEnd(clientName: "c", now: t0.addingTimeInterval(3300)) // 3300s > 600 budget

        // At t0+3601: S1's start (t0) has aged past the window (cutoff t0+1), so its
        // seconds no longer count toward the in-window total even though its
        // lastActivity (t0+3300) keeps it around for the cooldown. Budget is 0/600
        // and the cooldown expired → allowed. (Pre-fix, the straddler stayed in the
        // total and the wait floored to 0, incidentally also .allow — but for the
        // wrong reason; here it's because the mic time genuinely aged out.)
        XCTAssertEqual(limiter.check(clientName: "c", now: t0.addingTimeInterval(3601)), .allow)

        // While the straddler's start is still *inside* the window, its seconds do
        // count and the wait is keyed on that start — strictly positive, no floor.
        // At t0+3400 (start 3400s old) the budget is exhausted; it frees when the
        // start ages out at t0+3600, i.e. 200s.
        guard case .throttled(let retry) = limiter.check(clientName: "c", now: t0.addingTimeInterval(3400)) else {
            return XCTFail("expected throttled — budget exhausted while start is in-window")
        }
        XCTAssertEqual(retry, 200, accuracy: 0.001) // 3600 - 3400, keyed on start
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
