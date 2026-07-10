import XCTest
@testable import OpenWhispCore

/// Exhaustive coverage of the hands-free toggle/lock interaction (MAK-16): the
/// pure state machine that turns trigger edges into start/stop/cancel intents in
/// both hold and toggle modes, plus the double-tap gesture and Esc-to-cancel.
/// All timing is fed explicitly via a monotonic `now`, so these are deterministic.
final class ActivationInteractionTests: XCTestCase {

    // MARK: Hold mode (press-to-talk, historical behavior)

    func testHoldModePressStartsUnlockedReleaseStops() {
        var m = ActivationInteraction(mode: .hold)
        XCTAssertEqual(m.triggerDown(now: 0), .start(locked: false))
        XCTAssertTrue(m.isActive)
        XCTAssertFalse(m.isLockedOpen)
        // Held well past the tap window, then released → stop.
        XCTAssertEqual(m.triggerUp(now: 2.0), .stop)
        XCTAssertFalse(m.isActive)
    }

    func testHoldModeQuickTapStillStartsAndStops() {
        // A quick tap in hold mode is still ordinary press-to-talk: it starts
        // unlocked and the release delivers.
        var m = ActivationInteraction(mode: .hold)
        XCTAssertEqual(m.triggerDown(now: 0), .start(locked: false))
        XCTAssertEqual(m.triggerUp(now: 0.1), .stop)
        XCTAssertFalse(m.isActive)
    }

    // MARK: Double-tap gesture → lock (from hold mode)

    func testDoubleTapStartsLockedSession() {
        var m = ActivationInteraction(mode: .hold)
        // First tap: quick down/up (ordinary dictation, but remembered).
        XCTAssertEqual(m.triggerDown(now: 0.0), .start(locked: false))
        XCTAssertEqual(m.triggerUp(now: 0.1), .stop)
        // Second tap within the gap → locked start.
        XCTAssertEqual(m.triggerDown(now: 0.3), .start(locked: true))
        XCTAssertTrue(m.isLockedOpen)   // lock decided immediately
        // Quick release locks it open (no stop on release).
        XCTAssertEqual(m.triggerUp(now: 0.4), .none)
        XCTAssertTrue(m.isActive)
        XCTAssertTrue(m.isLockedOpen)
        // A subsequent tap stops the locked session.
        XCTAssertEqual(m.triggerDown(now: 1.0), .stop)
        XCTAssertEqual(m.triggerUp(now: 1.1), .none)
        XCTAssertFalse(m.isActive)
    }

    func testSecondTapAfterGapIsNotDoubleTap() {
        var m = ActivationInteraction(mode: .hold)
        XCTAssertEqual(m.triggerDown(now: 0.0), .start(locked: false))
        XCTAssertEqual(m.triggerUp(now: 0.1), .stop)
        // Second press too late to be a double-tap → ordinary unlocked start.
        XCTAssertEqual(m.triggerDown(now: 1.0), .start(locked: false))
        XCTAssertFalse(m.isLockedOpen)
    }

    func testFirstPressHeldTooLongDisqualifiesDoubleTap() {
        var m = ActivationInteraction(mode: .hold)
        XCTAssertEqual(m.triggerDown(now: 0.0), .start(locked: false))
        // Held past the tap window → not remembered as a tap.
        XCTAssertEqual(m.triggerUp(now: 1.0), .stop)
        // Immediate next press is therefore NOT a double-tap.
        XCTAssertEqual(m.triggerDown(now: 1.1), .start(locked: false))
        XCTAssertFalse(m.isLockedOpen)
    }

    // MARK: Toggle mode (hands-free lock)

    func testToggleModeTapLocksOpen() {
        var m = ActivationInteraction(mode: .toggle)
        XCTAssertEqual(m.triggerDown(now: 0.0), .start(locked: true))
        XCTAssertTrue(m.isLockedOpen)
        XCTAssertEqual(m.triggerUp(now: 0.1), .none)   // release does NOT stop
        XCTAssertTrue(m.isActive)
        XCTAssertTrue(m.isLockedOpen)
    }

    func testToggleModeSecondTapStops() {
        var m = ActivationInteraction(mode: .toggle)
        _ = m.triggerDown(now: 0.0)
        _ = m.triggerUp(now: 0.1)
        // Stop tap: decided on the down edge, release swallowed.
        XCTAssertEqual(m.triggerDown(now: 1.0), .stop)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(m.triggerUp(now: 1.05), .none)
        XCTAssertFalse(m.isActive)
    }

    func testToggleModeLongPressDegradesToPushToTalk() {
        // Even in toggle mode, if the user HOLDS the key it behaves as
        // press-to-talk — the release ends the session, nothing is left locked.
        var m = ActivationInteraction(mode: .toggle)
        XCTAssertEqual(m.triggerDown(now: 0.0), .start(locked: true))
        XCTAssertEqual(m.triggerUp(now: 2.0), .stop)   // long hold → stop on release
        XCTAssertFalse(m.isActive)
    }

    func testToggleModeStartStopStartCycles() {
        var m = ActivationInteraction(mode: .toggle)
        // Lock open.
        XCTAssertEqual(m.triggerDown(now: 0.0), .start(locked: true))
        XCTAssertEqual(m.triggerUp(now: 0.1), .none)
        // Stop.
        XCTAssertEqual(m.triggerDown(now: 1.0), .stop)
        XCTAssertEqual(m.triggerUp(now: 1.1), .none)
        // Lock open again cleanly.
        XCTAssertEqual(m.triggerDown(now: 2.0), .start(locked: true))
        XCTAssertTrue(m.isLockedOpen)
    }

    // MARK: Esc-to-cancel

    func testEscCancelsLockedSession() {
        var m = ActivationInteraction(mode: .toggle)
        _ = m.triggerDown(now: 0.0)
        _ = m.triggerUp(now: 0.1)
        XCTAssertTrue(m.isLockedOpen)
        XCTAssertEqual(m.cancel(), .cancel)
        XCTAssertFalse(m.isActive)
        // A fresh tap starts clean afterward.
        XCTAssertEqual(m.triggerDown(now: 1.0), .start(locked: true))
    }

    func testEscCancelsHeldSession() {
        var m = ActivationInteraction(mode: .hold)
        _ = m.triggerDown(now: 0.0)
        XCTAssertEqual(m.cancel(), .cancel)
        XCTAssertFalse(m.isActive)
        // The now-stale release must not resurrect a session.
        XCTAssertEqual(m.triggerUp(now: 0.5), .none)
        XCTAssertFalse(m.isActive)
    }

    func testEscWhenIdleIsNoOp() {
        var m = ActivationInteraction(mode: .toggle)
        XCTAssertEqual(m.cancel(), .none)
    }

    // MARK: reset (session ended by another path — silence auto-stop, preempt)

    func testResetReturnsToIdleWithoutIntent() {
        var m = ActivationInteraction(mode: .toggle)
        _ = m.triggerDown(now: 0.0)
        _ = m.triggerUp(now: 0.1)
        XCTAssertTrue(m.isActive)
        m.reset()   // e.g. silence safety auto-stop finished the session
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(m.isLockedOpen)
        // Next tap starts a clean locked session.
        XCTAssertEqual(m.triggerDown(now: 1.0), .start(locked: true))
    }

    // MARK: Config knobs

    func testCustomTapDurationBoundary() {
        let cfg = ActivationInteraction.Config(maxTapDuration: 0.2, doubleTapGap: 0.4)
        var m = ActivationInteraction(mode: .toggle, config: cfg)
        _ = m.triggerDown(now: 0.0)
        // Exactly at the boundary counts as a tap → locks open.
        XCTAssertEqual(m.triggerUp(now: 0.2), .none)
        XCTAssertTrue(m.isLockedOpen)
    }

    func testJustOverTapDurationIsHold() {
        let cfg = ActivationInteraction.Config(maxTapDuration: 0.2, doubleTapGap: 0.4)
        var m = ActivationInteraction(mode: .toggle, config: cfg)
        _ = m.triggerDown(now: 0.0)
        // Just past the boundary → treated as a hold, release stops.
        XCTAssertEqual(m.triggerUp(now: 0.21), .stop)
        XCTAssertFalse(m.isActive)
    }

    // MARK: Integration — lock + silence safety auto-stop compose

    /// The exact composition AppState performs for a hands-free session: a tap
    /// locks the mic open (`ActivationInteraction`), and the `SilenceAutoStop`
    /// safety net finishes the forgotten session after a long silence. When the
    /// safety fires, AppState calls `reset()` on the interaction machine (mirrored
    /// here) so the NEXT tap starts a clean session rather than reading as a stop.
    func testLockedSessionSilenceSafetyAutoStopThenCleanRestart() {
        var interaction = ActivationInteraction(mode: .toggle)
        // Long hangover, like AppState.lockSafetyConfig (shortened here for the test).
        var safety = SilenceAutoStop(config: .init(silenceToStop: 2.0, minSpeechToArm: 0.3))

        // Tap → locked open.
        XCTAssertEqual(interaction.triggerDown(now: 0.0), .start(locked: true))
        XCTAssertEqual(interaction.triggerUp(now: 0.1), .none)
        XCTAssertTrue(interaction.isLockedOpen)

        // Speak for a while (arms the detector), then go silent.
        var t = 0.2
        var fired = false
        // ~0.5s of speech.
        while t < 0.7 {
            fired = safety.ingest(level: 0.5, now: t) || fired
            t += 0.05
        }
        XCTAssertTrue(safety.isArmed)
        XCTAssertFalse(fired, "must not fire while speaking")
        // Then silence past the hangover.
        while t < 3.2 {
            fired = safety.ingest(level: 0.0, now: t) || fired
            t += 0.05
        }
        XCTAssertTrue(fired, "safety auto-stop fires after the long silence")

        // AppState finishes the session and resets the interaction machine.
        interaction.reset()
        XCTAssertFalse(interaction.isActive)
        XCTAssertFalse(interaction.isLockedOpen)

        // The next tap starts a fresh locked session (not a stop).
        XCTAssertEqual(interaction.triggerDown(now: 5.0), .start(locked: true))
        XCTAssertTrue(interaction.isLockedOpen)
    }
}
