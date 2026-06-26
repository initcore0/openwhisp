import XCTest
@testable import OpenWhispCore

/// Covers the overlay phase decision, with focus on the `.arming` window — the
/// readiness cue that fixes the lost-leading-audio bug by telling the user not to
/// speak until capture is genuinely live.
final class OverlayPhaseTests: XCTestCase {

    private func resolve(
        hasError: Bool = false,
        isCapturing: Bool = false,
        isTranscribing: Bool = false,
        isArming: Bool = false,
        audioLevel: Float = 0
    ) -> OverlayPhase {
        OverlayPhase.resolve(
            hasError: hasError,
            isCapturing: isCapturing,
            isTranscribing: isTranscribing,
            isArming: isArming,
            audioLevel: audioLevel
        )
    }

    // MARK: - Arming window

    /// The instant the hotkey is pressed: session begun, capture not yet live.
    /// This is exactly when the user must NOT speak — the overlay must say so.
    func testArmingWhenSessionBegunButCaptureNotLive() {
        XCTAssertEqual(resolve(isArming: true), .arming)
    }

    /// Capture going live is the single signal that ends arming, even if AppState
    /// hasn't yet cleared isArming (lockstep is enforced, but be defensive).
    func testCaptureLiveEndsArmingEvenIfArmingFlagStale() {
        XCTAssertEqual(resolve(isCapturing: true, isArming: true), .listening)
    }

    /// Once capture is live and quiet, we show the green "speak now" listening cue.
    func testListeningWhenLiveAndQuiet() {
        XCTAssertEqual(resolve(isCapturing: true, audioLevel: 0.0), .listening)
    }

    /// Speech energy while live → speaking cue.
    func testSpeakingWhenLiveAndLoud() {
        XCTAssertEqual(resolve(isCapturing: true, audioLevel: 0.5), .speaking)
    }

    /// A loud buffer during the arming gap must NOT be read as "speaking" — capture
    /// isn't live, so any energy is pre-capture and the user should still wait.
    func testArmingTakesPrecedenceOverAudioLevel() {
        XCTAssertEqual(resolve(isArming: true, audioLevel: 0.9), .arming)
    }

    // MARK: - Finalizing / error precedence

    func testFinalizingWhileTranscribing() {
        XCTAssertEqual(resolve(isTranscribing: true), .finalizing)
    }

    /// Transcribing outranks a not-yet-cleared arming flag (capture already ended).
    func testFinalizingOutranksArming() {
        XCTAssertEqual(resolve(isTranscribing: true, isArming: true), .finalizing)
    }

    /// Error only wins once nothing is actively capturing or transcribing, matching
    /// the prior overlay behavior (no red flicker mid-session).
    func testErrorOnlyWhenIdle() {
        XCTAssertEqual(resolve(hasError: true), .error)
        // An error set while still capturing/transcribing does not flicker red.
        XCTAssertEqual(resolve(hasError: true, isCapturing: true), .listening)
        XCTAssertEqual(resolve(hasError: true, isCapturing: true, audioLevel: 0.5), .speaking)
        XCTAssertEqual(resolve(hasError: true, isTranscribing: true), .finalizing)
    }

    func testSpeakingThresholdBoundary() {
        // Default threshold is 0.06: strictly greater than → speaking.
        XCTAssertEqual(resolve(isCapturing: true, audioLevel: 0.06), .listening)
        XCTAssertEqual(resolve(isCapturing: true, audioLevel: 0.061), .speaking)
    }
}
