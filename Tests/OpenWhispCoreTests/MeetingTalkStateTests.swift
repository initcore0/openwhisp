import XCTest
@testable import OpenWhispCore

/// MAK-52: `MeetingTalkState` hysteresis resolver. Covers each speaker case and,
/// crucially, that jitter around the threshold does NOT flap the label.
final class MeetingTalkStateTests: XCTestCase {

    private let on = MeetingTalkState.onThreshold      // 0.22
    private let off = MeetingTalkState.offThreshold    // 0.12

    func testThresholdsAreOrdered() {
        XCTAssertGreaterThan(on, off, "on-threshold must exceed off-threshold for a valid hysteresis band")
    }

    func testSilenceWhenBothQuiet() {
        var s = MeetingTalkState()
        XCTAssertEqual(s.update(micLevel: 0, systemLevel: 0), .silence)
        XCTAssertEqual(s.update(micLevel: off - 0.01, systemLevel: off - 0.01), .silence)
    }

    func testYouWhenOnlyMicActive() {
        var s = MeetingTalkState()
        XCTAssertEqual(s.update(micLevel: on + 0.1, systemLevel: 0), .you)
    }

    func testThemWhenOnlySystemActive() {
        var s = MeetingTalkState()
        XCTAssertEqual(s.update(micLevel: 0, systemLevel: on + 0.1), .them)
    }

    func testBothWhenBothActive() {
        var s = MeetingTalkState()
        XCTAssertEqual(s.update(micLevel: on + 0.1, systemLevel: on + 0.1), .both)
    }

    func testStaysSilentJustBelowOnThreshold() {
        var s = MeetingTalkState()
        // Between off and on, having never activated, stays silent (needs to CROSS on).
        XCTAssertEqual(s.update(micLevel: on - 0.01, systemLevel: 0), .silence)
    }

    func testHysteresisSuppressesFlappingAtBoundary() {
        var s = MeetingTalkState()
        // Activate.
        XCTAssertEqual(s.update(micLevel: on + 0.05, systemLevel: 0), .you)
        // Now oscillate in the band [off, on): a naive threshold test would flap
        // between .you and .silence every frame. Hysteresis holds .you.
        let jitter: [Float] = [on - 0.01, off + 0.01, on - 0.02, off + 0.02, on - 0.005]
        for level in jitter {
            XCTAssertEqual(s.update(micLevel: level, systemLevel: 0), .you,
                           "level \(level) inside the hysteresis band must not drop the label")
        }
        // Only a real drop below off deactivates.
        XCTAssertEqual(s.update(micLevel: off - 0.01, systemLevel: 0), .silence)
    }

    func testLabelsAndGlyphsAreDistinct() {
        let speakers: [MeetingTalkState.Speaker] = [.silence, .you, .them, .both]
        XCTAssertEqual(Set(speakers.map(\.label)).count, speakers.count)
        XCTAssertEqual(Set(speakers.map(\.glyph)).count, speakers.count)
    }
}
