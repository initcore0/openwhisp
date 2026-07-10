import XCTest
@testable import OpenWhispCore

/// Covers the rotating first-run overlay hint logic (MAK-25): the auto-off window,
/// per-session rotation, and permanent dismissal — all pure, independent of the
/// overlay's live-state suppression (which is tested separately via the overlay).
final class HintRotationTests: XCTestCase {

    private let deck: [TipsCatalog.Hint] = [
        .init(id: "a", text: "A"),
        .init(id: "b", text: "B"),
        .init(id: "c", text: "C"),
    ]

    // MARK: - Auto-off window

    func testActiveWithinWindow() {
        XCTAssertTrue(HintRotation.active(sessionCount: 1))
        XCTAssertTrue(HintRotation.active(sessionCount: 10))
    }

    func testInactivePastWindow() {
        XCTAssertFalse(HintRotation.active(sessionCount: 11))
        XCTAssertFalse(HintRotation.active(sessionCount: 100))
    }

    func testInactiveBeforeFirstSession() {
        // 0 (or negative) means no counted session yet — nothing to show.
        XCTAssertFalse(HintRotation.active(sessionCount: 0))
    }

    func testHintNilPastWindow() {
        XCTAssertNil(HintRotation.hint(sessionCount: 11, dismissed: [], hints: deck))
    }

    func testCustomWindowSize() {
        XCTAssertTrue(HintRotation.active(sessionCount: 3, sessionsToShow: 3))
        XCTAssertFalse(HintRotation.active(sessionCount: 4, sessionsToShow: 3))
    }

    // MARK: - Rotation

    func testRotatesThroughDeckBySession() {
        XCTAssertEqual(HintRotation.hint(sessionCount: 1, dismissed: [], hints: deck)?.id, "a")
        XCTAssertEqual(HintRotation.hint(sessionCount: 2, dismissed: [], hints: deck)?.id, "b")
        XCTAssertEqual(HintRotation.hint(sessionCount: 3, dismissed: [], hints: deck)?.id, "c")
    }

    func testRotationWrapsWhenWindowOutlastsDeck() {
        // Deck of 3, session 4 wraps back to the first.
        XCTAssertEqual(HintRotation.hint(sessionCount: 4, dismissed: [], hints: deck)?.id, "a")
        XCTAssertEqual(HintRotation.hint(sessionCount: 5, dismissed: [], hints: deck)?.id, "b")
    }

    // MARK: - Dismissal

    func testDismissedHintIsSkipped() {
        // With "a" dismissed, the live deck is [b, c]; session 1 lands on the first live one.
        let h = HintRotation.hint(sessionCount: 1, dismissed: ["a"], hints: deck)
        XCTAssertEqual(h?.id, "b")
    }

    func testDismissedHintNeverReappearsAcrossWindow() {
        for session in 1...10 {
            let h = HintRotation.hint(sessionCount: session, dismissed: ["b"], hints: deck)
            XCTAssertNotEqual(h?.id, "b", "dismissed hint reappeared at session \(session)")
        }
    }

    func testAllDismissedYieldsNil() {
        XCTAssertNil(HintRotation.hint(sessionCount: 1, dismissed: ["a", "b", "c"], hints: deck))
    }

    func testEmptyDeckYieldsNil() {
        XCTAssertNil(HintRotation.hint(sessionCount: 1, dismissed: [], hints: []))
    }

    // MARK: - Real shipped deck

    func testShippedDeckRotatesAndAutoOffs() {
        // The real deck produces a hint on session 1 and none past the window.
        XCTAssertNotNil(HintRotation.hint(sessionCount: 1, dismissed: []))
        XCTAssertNil(HintRotation.hint(sessionCount: HintRotation.sessionsToShow + 1, dismissed: []))
    }
}
