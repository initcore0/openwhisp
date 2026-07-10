import XCTest
@testable import OpenWhispCore

/// Tests for the pure crash-recovery decision (MAK-40): given a persisted capture
/// marker (present iff a prior session died mid-dictation) and whether its audio
/// still exists, decide whether to offer the user recovery. No AppKit, no disk.
final class CrashRecoveryStateTests: XCTestCase {

    private func marker() -> CaptureRecoveryMarker {
        CaptureRecoveryMarker(wavPath: "/tmp/recording_1.wav", startedAt: Date(), language: "en")
    }

    func testNoMarkerMeansNothingToRecover() {
        XCTAssertEqual(
            CrashRecoveryResolver.decide(marker: nil, markerAudioExists: false),
            .nothingToRecover
        )
    }

    func testMarkerWithMissingAudioMeansNothingToRecover() {
        // Crash before any audio flushed, or the temp file was reaped: don't nag
        // the user with a prompt that would recover nothing.
        XCTAssertEqual(
            CrashRecoveryResolver.decide(marker: marker(), markerAudioExists: false),
            .nothingToRecover
        )
    }

    func testMarkerWithSurvivingAudioOffersRecovery() {
        let m = marker()
        XCTAssertEqual(
            CrashRecoveryResolver.decide(marker: m, markerAudioExists: true),
            .offerRecovery(m)
        )
    }

    func testMarkerRoundTripsThroughCodable() throws {
        let m = marker()
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(CaptureRecoveryMarker.self, from: data)
        XCTAssertEqual(m, back)
    }
}
