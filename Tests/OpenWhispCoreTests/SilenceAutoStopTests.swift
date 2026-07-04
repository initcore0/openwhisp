import XCTest
@testable import OpenWhispCore

final class SilenceAutoStopTests: XCTestCase {

    // A fast config with round numbers so the arithmetic in each test is obvious.
    private func makeConfig(
        speech: Float = 0.16, silence: Float = 0.10,
        silenceToStop: TimeInterval = 1.0, minSpeechToArm: TimeInterval = 0.3
    ) -> SilenceAutoStop.Config {
        .init(speechLevel: speech, silenceLevel: silence,
              silenceToStop: silenceToStop, minSpeechToArm: minSpeechToArm)
    }

    /// Feed a run of identical samples spaced `dt` apart starting at `start`.
    /// Returns the (0-based) index of the sample that fired, or nil if none did.
    @discardableResult
    private func drive(
        _ d: inout SilenceAutoStop, level: Float, count: Int,
        dt: TimeInterval, start: TimeInterval
    ) -> Int? {
        for i in 0..<count {
            if d.ingest(level: level, now: start + Double(i) * dt) { return i }
        }
        return nil
    }

    func testLeadingSilenceNeverFires() {
        // Silence before any speech must not trigger a stop, no matter how long.
        var d = SilenceAutoStop(config: makeConfig())
        let fired = drive(&d, level: 0.0, count: 200, dt: 0.033, start: 0)
        XCTAssertNil(fired)
        XCTAssertFalse(d.isArmed)
    }

    func testFiresAfterSpeechThenSilence() {
        var d = SilenceAutoStop(config: makeConfig(silenceToStop: 1.0))
        // ~0.5s of speech at 30 Hz → arms.
        _ = drive(&d, level: 0.5, count: 15, dt: 0.033, start: 0)
        XCTAssertTrue(d.isArmed)
        // Then silence starting at t=0.5. The hangover is anchored at the START of
        // the continuous silence run, so it fires once (now − 0.5) ≥ 1.0.
        var firedAt: TimeInterval?
        for i in 0..<100 {
            let now = 0.5 + Double(i) * 0.033
            if d.ingest(level: 0.0, now: now) { firedAt = now; break }
        }
        XCTAssertNotNil(firedAt)
        // Fired no earlier than 1.0s of continuous silence...
        XCTAssertGreaterThanOrEqual(firedAt! - 0.5, 1.0)
        // ...and not egregiously late (within one sample period of the threshold).
        XCTAssertLessThan(firedAt! - 0.5, 1.0 + 0.05)
    }

    func testShortBlipDoesNotArm() {
        // A single stray loud sample is below minSpeechToArm, so a following
        // silence must not fire.
        var d = SilenceAutoStop(config: makeConfig(minSpeechToArm: 0.3))
        _ = d.ingest(level: 0.9, now: 0.0)          // one blip, dt=0 → 0 accrued
        _ = d.ingest(level: 0.9, now: 0.05)         // +0.05 accrued (< 0.3)
        XCTAssertFalse(d.isArmed)
        let fired = drive(&d, level: 0.0, count: 100, dt: 0.033, start: 0.1)
        XCTAssertNil(fired)
    }

    func testMidSentencePauseDoesNotFireEarly() {
        // Speak, pause briefly (shorter than silenceToStop), speak again, then go
        // quiet — the early pause must not end the turn.
        var d = SilenceAutoStop(config: makeConfig(silenceToStop: 1.0))
        _ = drive(&d, level: 0.5, count: 15, dt: 0.033, start: 0)     // speech, arms
        // 0.6s pause (< 1.0s) — should NOT fire.
        let pauseFired = drive(&d, level: 0.0, count: 18, dt: 0.033, start: 0.5)
        XCTAssertNil(pauseFired)
        // More speech resets the silence run.
        _ = drive(&d, level: 0.5, count: 10, dt: 0.033, start: 1.1)
        // Now a full silence should fire.
        var fired = false
        for i in 0..<100 where d.ingest(level: 0.0, now: 1.5 + Double(i) * 0.033) { fired = true; break }
        XCTAssertTrue(fired)
    }

    func testHysteresisBandDoesNotCountAsSilence() {
        // A level between silenceLevel and speechLevel is neither: it must not
        // advance the stop timer. Sit in the band forever after arming → no fire.
        var d = SilenceAutoStop(config: makeConfig(speech: 0.16, silence: 0.10))
        _ = drive(&d, level: 0.5, count: 15, dt: 0.033, start: 0)     // arm
        // 0.13 is in the (0.10, 0.16) dead band.
        let fired = drive(&d, level: 0.13, count: 300, dt: 0.033, start: 0.5)
        XCTAssertNil(fired)
    }

    func testDeadBandTimeDoesNotCountTowardTheHangover() {
        // A speaker trailing off in the dead band for longer than silenceToStop,
        // then one quiet dip: the dip must START the silence run, not fire
        // instantly off time retroactively counted as silence.
        var d = SilenceAutoStop(config: makeConfig(silenceToStop: 1.0))
        _ = drive(&d, level: 0.5, count: 15, dt: 0.033, start: 0)     // arm
        _ = drive(&d, level: 0.13, count: 60, dt: 0.033, start: 0.5)  // ~2s in band
        XCTAssertFalse(d.ingest(level: 0.05, now: 2.5), "first silence sample starts the run — must not fire")
        XCTAssertFalse(d.ingest(level: 0.05, now: 3.4), "0.9s of silence < 1.0s")
        XCTAssertTrue(d.ingest(level: 0.05, now: 3.5), "1.0s of continuous silence → fire")
    }

    func testSparseCadenceGapDoesNotArmOffOneBlip() {
        // Silence, a callback gap, then ONE loud transient: the gap interval must
        // not be credited as speech, so the blip cannot satisfy minSpeechToArm.
        var d = SilenceAutoStop(config: makeConfig(minSpeechToArm: 0.3))
        _ = drive(&d, level: 0.0, count: 10, dt: 0.033, start: 0)   // ambient
        _ = d.ingest(level: 0.9, now: 1.0)                          // blip after ~0.7s gap
        XCTAssertFalse(d.isArmed, "a lone transient after a gap must not arm")
        let fired = drive(&d, level: 0.0, count: 100, dt: 0.033, start: 1.1)
        XCTAssertNil(fired)
    }

    func testFiresOnlyOnceWorthOfDecision() {
        // Verify the boundary: the silence sample exactly at silenceToStop after
        // the run began fires, and it's the first one that does.
        var d = SilenceAutoStop(config: makeConfig(silenceToStop: 1.0, minSpeechToArm: 0.0))
        _ = d.ingest(level: 0.5, now: 0.0)   // speech at t=0, arms immediately (min=0)
        XCTAssertTrue(d.isArmed)
        XCTAssertFalse(d.ingest(level: 0.0, now: 0.5))  // run starts at 0.5
        XCTAssertFalse(d.ingest(level: 0.0, now: 1.49)) // 0.99 of silence < 1.0 → no
        XCTAssertTrue(d.ingest(level: 0.0, now: 1.50))  // exactly 1.0 → fire
    }

    func testNonMonotonicClockDoesNotUnderflow() {
        // A backwards time step must be clamped to 0 dt, not produce a huge/negative
        // interval that spuriously fires or arms.
        var d = SilenceAutoStop(config: makeConfig())
        _ = d.ingest(level: 0.5, now: 10.0)
        _ = d.ingest(level: 0.5, now: 9.0)   // backwards — clamp dt to 0
        // Not armed off a single non-advancing speech sample (accrued 0).
        // A subsequent silence shouldn't fire from a bogus interval.
        XCTAssertFalse(d.ingest(level: 0.0, now: 9.5))
    }

    func testDefaultConfigValues() {
        let c = SilenceAutoStop.Config.default
        XCTAssertEqual(c.speechLevel, 0.16, accuracy: 0.0001)
        XCTAssertEqual(c.silenceLevel, 0.10, accuracy: 0.0001)
        XCTAssertEqual(c.silenceToStop, 1.5, accuracy: 0.0001)
        XCTAssertLessThan(c.silenceLevel, c.speechLevel, "silence gate must sit below speech gate for hysteresis")
    }
}
