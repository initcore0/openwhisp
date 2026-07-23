import XCTest
@testable import OpenWhispCore

/// `LiveTranscriptDelta` — the pure paste-delta rule extracted from AppState
/// (MAK-32): a streaming session pastes only the trailing extension of the
/// hypothesis, and pastes nothing when the recognizer rewrote earlier words.
final class LiveTranscriptDeltaTests: XCTestCase {

    func testExtensionYieldsTrimmedTail() {
        XCTAssertEqual(LiveTranscriptDelta.delta(previous: "hello", current: "hello world"), "world")
        XCTAssertEqual(LiveTranscriptDelta.delta(previous: "", current: "hi"), "hi")
    }

    func testRewriteYieldsNothing() {
        // Not a pure extension — pasting would duplicate text.
        XCTAssertEqual(LiveTranscriptDelta.delta(previous: "hello there", current: "hallo there friend"), "")
        // Shrinking or unchanged hypotheses paste nothing.
        XCTAssertEqual(LiveTranscriptDelta.delta(previous: "hello world", current: "hello"), "")
        XCTAssertEqual(LiveTranscriptDelta.delta(previous: "same", current: "same"), "")
    }

    func testLockSafetyPresetsKeepTheLongHangover() {
        // The extracted presets must keep the 8s "walked away" backstop; quiet
        // mode lowers the level gates but never the hangover.
        XCTAssertEqual(SilenceAutoStop.Config.lockSafety.silenceToStop, 8.0)
        XCTAssertEqual(SilenceAutoStop.Config.quietLockSafety.silenceToStop, 8.0)
        XCTAssertLessThan(
            SilenceAutoStop.Config.quietLockSafety.speechLevel,
            SilenceAutoStop.Config.lockSafety.speechLevel)
    }
}
