import XCTest
@testable import OpenWhispCore

/// Drives the overlay waveform from streaming-transcript growth (the WhisperKit
/// streaming path, whose native energy doesn't track the live voice). Key
/// properties: growth raises the level, time decays it, revisions/resets don't
/// spuriously pulse.
final class TranscriptActivityMeterTests: XCTestCase {

    func testStartsAtRest() {
        let m = TranscriptActivityMeter()
        XCTAssertEqual(m.level, 0)
    }

    func testGrowthRaisesLevel() {
        var m = TranscriptActivityMeter()
        let level = m.ingest(transcript: "hello there")
        XCTAssertGreaterThan(level, 0)
        XCTAssertEqual(level, m.level)
    }

    func testEvenTinyDeltaVisiblyMoves() {
        var m = TranscriptActivityMeter(minKick: 0.35)
        m.ingest(transcript: "a")            // one new char
        XCTAssertGreaterThanOrEqual(m.level, 0.35)
    }

    func testLargerDeltaKicksHarder() {
        var small = TranscriptActivityMeter()
        var big = TranscriptActivityMeter()
        small.ingest(transcript: "hi")
        big.ingest(transcript: "the quick brown fox jumped")
        XCTAssertGreaterThan(big.level, small.level)
    }

    func testKickIsClampedToOne() {
        var m = TranscriptActivityMeter(charsForFullKick: 4)
        m.ingest(transcript: String(repeating: "x", count: 500))
        XCTAssertLessThanOrEqual(m.level, 1.0)
    }

    func testDecayLowersLevelOverTime() {
        var m = TranscriptActivityMeter(decayTimeConstant: 0.45)
        m.ingest(transcript: "hello world")
        let peak = m.level
        m.decay(dt: 0.2)
        XCTAssertLessThan(m.level, peak)
        XCTAssertGreaterThan(m.level, 0)   // not instant
    }

    func testDecaySettlesToZero() {
        var m = TranscriptActivityMeter(decayTimeConstant: 0.2)
        m.ingest(transcript: "hello")
        for _ in 0..<200 { m.decay(dt: 1.0 / 30.0) }   // a few seconds of ticks
        XCTAssertEqual(m.level, 0)
    }

    /// A revision that doesn't grow the transcript (WhisperKit revises its
    /// unconfirmed tail) must NOT pulse — only net growth counts.
    func testRevisionWithoutGrowthDoesNotPulse() {
        var m = TranscriptActivityMeter()
        m.ingest(transcript: "hello world")
        m.decay(dt: 0.3)
        let before = m.level
        m.ingest(transcript: "hello word")   // same length, revised tail
        XCTAssertEqual(m.level, before, accuracy: 0.0001)
    }

    /// A shorter transcript (e.g. confirmed segments replacing a longer hypothesis)
    /// must not pulse and must not break the growth baseline for later real growth.
    func testShrinkThenGrowStillPulsesOnRealGrowth() {
        var m = TranscriptActivityMeter()
        m.ingest(transcript: "hello there friend")   // len 18
        m.decay(dt: 1.0)
        m.ingest(transcript: "hello")                // shorter — no pulse
        let afterShrink = m.level
        // Grow beyond the previous high-water mark → should pulse again.
        m.ingest(transcript: "hello there friend, how are you")
        XCTAssertGreaterThan(m.level, afterShrink)
    }

    func testAttackNeverDucksAnOngoingPulse() {
        var m = TranscriptActivityMeter()
        m.ingest(transcript: "the quick brown fox")   // big kick
        let peak = m.level
        m.ingest(transcript: "the quick brown fox!")  // tiny delta right after
        XCTAssertGreaterThanOrEqual(m.level, peak)     // took the max, didn't duck
    }

    func testResetReturnsToRest() {
        var m = TranscriptActivityMeter()
        m.ingest(transcript: "hello world")
        m.reset()
        XCTAssertEqual(m.level, 0)
        // After reset, the next transcript is treated as fresh growth.
        m.ingest(transcript: "again")
        XCTAssertGreaterThan(m.level, 0)
    }
}
