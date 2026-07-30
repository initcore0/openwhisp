import XCTest
@testable import OpenWhispCore

/// Pins the gates for the mid-session `AVAudioEngineConfigurationChange`
/// recovery (Parakeet streaming). Two regressions meet here:
///
/// - Without any restart, a device disconnect leaves the session showing
///   "Listening…" while capturing NOTHING (the pre-v1.0.12 word-loss bug).
/// - With a REFLEXIVE restart, the notification the rebuild itself posts loops
///   teardown→rebuild forever (~4/s) and the mic is dead for EVERY session
///   (the v1.0.12 regression). Hence the settle-check inputs: the restart is
///   allowed only when the engine genuinely STOPPED, within a per-session
///   budget that fails loudly when exhausted.
final class CaptureConfigChangePolicyTests: XCTestCase {

    func testStoppedEngineInLiveSessionRestartsCapture() {
        XCTAssertEqual(
            CaptureConfigChangePolicy.action(
                generationMatches: true, didStop: false,
                engineStillRunning: false, restartsUsed: 0),
            .restartCapture
        )
    }

    /// THE v1.0.12 dead-mic gate: a notification that leaves the engine running
    /// (a transient renegotiation — including the one our own rebuild posts)
    /// must NOT trigger a rebuild. Restarting a running engine re-perturbs the
    /// device and self-sustains the loop.
    func testRunningEngineIgnoresNotification() {
        XCTAssertEqual(
            CaptureConfigChangePolicy.action(
                generationMatches: true, didStop: false,
                engineStillRunning: true, restartsUsed: 0),
            .ignore
        )
        // Running trumps everything else — even with budget left.
        XCTAssertEqual(
            CaptureConfigChangePolicy.action(
                generationMatches: true, didStop: false,
                engineStillRunning: true, restartsUsed: 2),
            .ignore
        )
    }

    /// A device that keeps stopping capture exhausts the budget and fails
    /// LOUDLY instead of looping silently.
    func testBudgetExhaustedGivesUp() {
        XCTAssertEqual(
            CaptureConfigChangePolicy.action(
                generationMatches: true, didStop: false,
                engineStillRunning: false,
                restartsUsed: CaptureConfigChangePolicy.maxRestartsPerSession),
            .giveUp
        )
        // The last budgeted restart is still allowed.
        XCTAssertEqual(
            CaptureConfigChangePolicy.action(
                generationMatches: true, didStop: false,
                engineStillRunning: false,
                restartsUsed: CaptureConfigChangePolicy.maxRestartsPerSession - 1),
            .restartCapture
        )
    }

    func testStoppedSessionIgnores() {
        // stop() ran but the generation hasn't rotated yet (runStop is queued
        // behind the chain): the mic is being torn down — don't rebuild it.
        XCTAssertEqual(
            CaptureConfigChangePolicy.action(
                generationMatches: true, didStop: true,
                engineStillRunning: false, restartsUsed: 0),
            .ignore
        )
    }

    func testSupersededSessionIgnores() {
        // A newer session bumped the generation: the notification belongs to a
        // torn-down capture and must not touch the successor's mic.
        for didStop in [false, true] {
            XCTAssertEqual(
                CaptureConfigChangePolicy.action(
                    generationMatches: false, didStop: didStop,
                    engineStillRunning: false, restartsUsed: 0),
                .ignore
            )
        }
    }

    /// The settle delay exists to coalesce the notification storm and let the
    /// io unit finish renegotiating before `isRunning` is read; sub-100ms would
    /// read mid-change state and re-enter the loop.
    func testSettleDelayIsMeaningful() {
        XCTAssertGreaterThanOrEqual(CaptureConfigChangePolicy.settleDelay, 0.1)
        XCTAssertLessThanOrEqual(CaptureConfigChangePolicy.settleDelay, 1.0)
    }

    func testRestartFailedMessageCarriesUnderlyingReason() {
        let message = CaptureConfigChangePolicy.restartFailedMessage(
            underlying: "No audio input device available.")
        XCTAssertTrue(message.contains("Microphone changed mid-dictation"))
        XCTAssertTrue(message.contains("No audio input device available."))
    }

    func testGaveUpMessageIsUserActionable() {
        XCTAssertTrue(CaptureConfigChangePolicy.gaveUpMessage.contains("dictation stopped"))
    }
}
