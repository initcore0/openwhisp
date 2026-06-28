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
}
