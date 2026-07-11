import XCTest
@testable import OpenWhispCore

/// MAK-46 Phase 5: the pure EOU-based agent auto-stop timing policy. An EOU event
/// finishes an agent session only after a settle window with no new partial, so a
/// mid-sentence clause-boundary EOU doesn't cut the speaker off.
final class AgentEouAutoStopTests: XCTestCase {

    func testNoStopBeforeAnyEou() {
        let d = AgentEouAutoStop()
        XCTAssertFalse(d.shouldStop(now: 100))
    }

    func testStopsAfterSettleWindow() {
        var d = AgentEouAutoStop(config: .init(settleMs: 600))
        d.noteEou(now: 10.0)
        XCTAssertFalse(d.shouldStop(now: 10.3), "0.3s < 0.6s settle — not yet")
        XCTAssertTrue(d.shouldStop(now: 10.6), "0.6s reached — stop")
        XCTAssertTrue(d.shouldStop(now: 11.0), "stays true until caller clears")
    }

    func testNewPartialCancelsPendingStop() {
        var d = AgentEouAutoStop(config: .init(settleMs: 600))
        d.noteEou(now: 10.0)
        // Speaker kept going — a partial arrived before the settle window elapsed.
        d.notePartial()
        XCTAssertFalse(d.shouldStop(now: 10.6), "a new partial cancelled the EOU stop")
    }

    func testLaterEouReArmsAfterAPartial() {
        var d = AgentEouAutoStop(config: .init(settleMs: 500))
        d.noteEou(now: 10.0)
        d.notePartial()               // cancel
        d.noteEou(now: 12.0)          // a fresh EOU
        XCTAssertFalse(d.shouldStop(now: 12.4))
        XCTAssertTrue(d.shouldStop(now: 12.5))
    }
}
