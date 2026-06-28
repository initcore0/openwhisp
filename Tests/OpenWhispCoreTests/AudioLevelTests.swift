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

    // MARK: - WhisperKit relative energy (already 0…1, NOT linear RMS)

    func testRelativeEnergyEndpointsAreIdentity() {
        XCTAssertEqual(AudioLevel.fromRelativeEnergy(0), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioLevel.fromRelativeEnergy(1), 1, accuracy: 0.0001)
    }

    /// The regression: WhisperKit's relative energy is already a perceptual 0…1
    /// value. It must NOT be pushed through `fromRMS` (which expects a tiny linear
    /// RMS and would map ~0.02 to ~0.57 and pin anything ≳0.3 to 1.0 — the bars sit
    /// near full and stop reacting). The direct curve must keep quiet input low.
    func testRelativeEnergyDoesNotDoubleCompress() {
        // Quiet relative energy stays clearly low (was ~0.57 under the fromRMS bug).
        XCTAssertLessThan(AudioLevel.fromRelativeEnergy(0.02), 0.2)
        // Normal speech lands mid-range, not pinned to 1.0 (was 1.0 under the bug).
        let speech = AudioLevel.fromRelativeEnergy(0.3)
        XCTAssertGreaterThan(speech, 0.25)
        XCTAssertLessThan(speech, 0.75)
        // It is genuinely below what the old fromRMS mapping produced.
        XCTAssertLessThan(AudioLevel.fromRelativeEnergy(0.3), AudioLevel.fromRMS(0.3))
    }

    func testRelativeEnergyMonotonic() {
        var last: Float = -1
        for e in stride(from: Float(0), through: 1, by: 0.1) {
            let v = AudioLevel.fromRelativeEnergy(e)
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
    }

    // MARK: - Live level from cumulative energy history

    func testLiveLevelEmptyHistoryYieldsNoUpdate() {
        XCTAssertNil(AudioLevel.liveLevel(fromEnergyHistory: []))
    }

    /// The freeze regression: history only grows, so the all-time `.max()` would pin
    /// the level at the loudest moment. The recent window must track DOWN once the
    /// speaker goes quiet.
    func testLiveLevelTracksDownAfterLoudOnset() {
        let history: [Float] = [0.9, 0.8] + Array(repeating: 0.03, count: 10)
        let level = AudioLevel.liveLevel(fromEnergyHistory: history)!
        XCTAssertLessThan(level, AudioLevel.fromRelativeEnergy(0.9))
        XCTAssertEqual(level, AudioLevel.fromRelativeEnergy(0.03), accuracy: 0.0001)
    }

    func testLiveLevelReflectsCurrentSpeech() {
        let history: [Float] = Array(repeating: 0.03, count: 20) + [0.5, 0.6]
        let level = AudioLevel.liveLevel(fromEnergyHistory: history)!
        XCTAssertEqual(level, AudioLevel.fromRelativeEnergy(0.6), accuracy: 0.0001)
    }

    func testLiveLevelWindowBoundsLookback() {
        // A loud buffer older than the window must not leak into the live level.
        let n = AudioLevel.liveEnergyWindow
        let history: [Float] = [0.9] + Array(repeating: 0.04, count: n)
        let level = AudioLevel.liveLevel(fromEnergyHistory: history)!
        XCTAssertEqual(level, AudioLevel.fromRelativeEnergy(0.04), accuracy: 0.0001)
    }
}
