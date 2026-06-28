import XCTest
@testable import OpenWhispCore

/// The shared perceptual loudness→0…1 normalizer used by every capture path. The
/// key property: normal speech should swing across most of the range (the old
/// `rms * 8` left it near zero), while silence stays ~0 and loud stays ~1.
final class AudioLevelTests: XCTestCase {

    func testSilenceIsZero() {
        XCTAssertEqual(AudioLevel.fromRMS(0), 0)
        // Below the floor (~ -52 dB) clamps to 0.
        XCTAssertEqual(AudioLevel.fromDB(-80), 0, accuracy: 0.0001)
    }

    func testLoudIsOne() {
        XCTAssertEqual(AudioLevel.fromRMS(1.0), 1, accuracy: 0.0001)   // 0 dBFS → above ceil
        XCTAssertEqual(AudioLevel.fromDB(0), 1, accuracy: 0.0001)
    }

    func testNormalSpeechUsesMidUpperRange() {
        // Typical speech RMS ~0.05 (≈ -26 dBFS) should land comfortably mid-range,
        // not pinned near zero like the old linear `rms * 8` (which gave ~0.4 but
        // collapsed for quieter speech). Here it should be a lively value.
        let mid = AudioLevel.fromRMS(0.05)
        XCTAssertGreaterThan(mid, 0.45)
        XCTAssertLessThan(mid, 0.95)
    }

    func testMonotonicAndClamped() {
        var last: Float = -1
        for db in stride(from: Float(-80), through: 10, by: 5) {
            let v = AudioLevel.fromDB(db)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 1)
            XCTAssertGreaterThanOrEqual(v, last)   // non-decreasing in loudness
            last = v
        }
    }

    func testRelativeEnergyMatchesRMSMapping() {
        // fromRelativeEnergy treats its input as a linear amplitude → same curve.
        XCTAssertEqual(AudioLevel.fromRelativeEnergy(0.05), AudioLevel.fromRMS(0.05), accuracy: 0.0001)
        XCTAssertEqual(AudioLevel.fromRelativeEnergy(0), 0)
    }

    // MARK: - Cumulative energy history (WhisperKit bufferEnergy)

    func testEmptyHistoryYieldsNoUpdate() {
        // No buffers yet → nil so the caller holds the prior level.
        XCTAssertNil(AudioLevel.fromCumulativeEnergyHistory([]))
    }

    /// The regression: WhisperKit's `bufferEnergy` is a cumulative, ever-growing
    /// history. A loud onset must NOT pin the indicator high once the speaker goes
    /// quiet — the live level must follow the RECENT window, not the all-time max.
    func testRecentWindowTracksDownAfterLoudOnset() {
        // Loud onset early, then a long quiet tail (more than the trailing window).
        let history: [Float] = [0.9, 0.8] + Array(repeating: 0.02, count: 10)
        let level = AudioLevel.fromCumulativeEnergyHistory(history)!
        // Whole-history `.max()` (the old bug) would map 0.9 → ~1.0 and freeze there.
        XCTAssertLessThan(level, AudioLevel.fromRelativeEnergy(0.9))
        // It should instead reflect the quiet recent buffers.
        XCTAssertEqual(level, AudioLevel.fromRelativeEnergy(0.02), accuracy: 0.0001)
    }

    func testRecentWindowReflectsCurrentSpeech() {
        // Quiet history, then a loud current window → indicator rises.
        let history: [Float] = Array(repeating: 0.02, count: 20) + [0.5, 0.6]
        let level = AudioLevel.fromCumulativeEnergyHistory(history)!
        XCTAssertEqual(level, AudioLevel.fromRelativeEnergy(0.6), accuracy: 0.0001)
    }

    func testWindowSizeBoundsHowFarBackItLooks() {
        // A loud buffer just outside the trailing window must not leak into the level.
        let n = AudioLevel.recentEnergyWindow
        let history: [Float] = [0.9] + Array(repeating: 0.03, count: n)
        let level = AudioLevel.fromCumulativeEnergyHistory(history)!
        XCTAssertEqual(level, AudioLevel.fromRelativeEnergy(0.03), accuracy: 0.0001)
    }
}
