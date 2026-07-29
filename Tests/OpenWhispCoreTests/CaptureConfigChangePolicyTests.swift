import XCTest
@testable import OpenWhispCore

/// Pins the gates for the mid-session `AVAudioEngineConfigurationChange`
/// recovery (Parakeet streaming): a live session restarts capture; a stale or
/// stopped session ignores the notification. Without the restart, a device
/// disconnect/format renegotiation leaves the session showing "Listening…"
/// while capturing NOTHING — words are silently lost for the session's
/// remainder (the bug this policy exists to close).
final class CaptureConfigChangePolicyTests: XCTestCase {

    func testLiveSessionRestartsCapture() {
        XCTAssertEqual(
            CaptureConfigChangePolicy.action(generationMatches: true, didStop: false),
            .restartCapture
        )
    }

    func testStoppedSessionIgnores() {
        // stop() ran but the generation hasn't rotated yet (runStop is queued
        // behind the chain): the mic is being torn down — don't rebuild it.
        XCTAssertEqual(
            CaptureConfigChangePolicy.action(generationMatches: true, didStop: true),
            .ignore
        )
    }

    func testSupersededSessionIgnores() {
        // A newer session bumped the generation: the notification belongs to a
        // torn-down capture and must not touch the successor's mic.
        XCTAssertEqual(
            CaptureConfigChangePolicy.action(generationMatches: false, didStop: false),
            .ignore
        )
        XCTAssertEqual(
            CaptureConfigChangePolicy.action(generationMatches: false, didStop: true),
            .ignore
        )
    }

    func testRestartFailedMessageCarriesUnderlyingReason() {
        let message = CaptureConfigChangePolicy.restartFailedMessage(
            underlying: "No audio input device available.")
        XCTAssertTrue(message.contains("Microphone changed mid-dictation"))
        XCTAssertTrue(message.contains("No audio input device available."))
    }
}
