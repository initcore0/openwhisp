import XCTest
@testable import OpenWhispCore

/// MAK-94 — instant, honest hotkey feedback while the model is still loading.
///
/// Owner-reported gap #2: pressing Fn during the cold-start window gave no
/// feedback for several seconds. The overlay DOES show immediately (AppState sets
/// `isArming` in `beginSession`), but it said "Starting…" — indistinguishable
/// from a hang — and after 15s the `captureStartTimeout` fallback flipped it to a
/// LYING "Listening…" while nothing was capturing. These tests pin both fixes.
final class ModelLoadingOverlayTests: XCTestCase {

    // MARK: - Overlay phase

    /// Press-during-load: the overlay comes up in the loading phase immediately,
    /// naming the actual cause instead of a generic "Starting…".
    func testPressDuringModelLoadShowsLoadingPhase() {
        let phase = OverlayPhase.resolve(
            hasError: false, isCapturing: false, isTranscribing: false,
            isArming: true, audioLevel: 0, engineIsLoadingModel: true
        )
        XCTAssertEqual(phase, .loadingModel)
        XCTAssertEqual(phase.loadingCaption, "Loading model…")
    }

    /// A warm engine keeps the ordinary arming cue — `.loadingModel` must not
    /// leak into the normal press path.
    func testPressWhenReadyKeepsOrdinaryArming() {
        let phase = OverlayPhase.resolve(
            hasError: false, isCapturing: false, isTranscribing: false,
            isArming: true, audioLevel: 0, engineIsLoadingModel: false
        )
        XCTAssertEqual(phase, .arming)
        XCTAssertNil(phase.loadingCaption)
    }

    /// The handoff: when the engine's `onStarted` fires, capture is genuinely
    /// live and the phase joins the normal listening flow — even if a stale
    /// readiness observation still says "loading".
    func testCaptureGoingLiveEndsLoadingPhase() {
        let phase = OverlayPhase.resolve(
            hasError: false, isCapturing: true, isTranscribing: false,
            isArming: false, audioLevel: 0, engineIsLoadingModel: true
        )
        XCTAssertEqual(phase, .listening)
    }

    /// Full press-during-load sequence: loading → listening → speaking.
    func testLoadingToListeningToSpeakingSequence() {
        func phase(capturing: Bool, arming: Bool, loading: Bool, level: Float) -> OverlayPhase {
            OverlayPhase.resolve(
                hasError: false, isCapturing: capturing, isTranscribing: false,
                isArming: arming, audioLevel: level, engineIsLoadingModel: loading
            )
        }
        XCTAssertEqual(phase(capturing: false, arming: true, loading: true, level: 0), .loadingModel)
        XCTAssertEqual(phase(capturing: true, arming: false, loading: false, level: 0), .listening)
        XCTAssertEqual(phase(capturing: true, arming: false, loading: false, level: 0.5), .speaking)
    }

    /// Finalizing and errors still outrank the loading phase — a load in flight
    /// must not mask a terminal state.
    func testFinalizingAndErrorOutrankLoading() {
        XCTAssertEqual(
            OverlayPhase.resolve(hasError: false, isCapturing: false, isTranscribing: true,
                                 isArming: true, audioLevel: 0, engineIsLoadingModel: true),
            .finalizing
        )
        XCTAssertEqual(
            OverlayPhase.resolve(hasError: true, isCapturing: false, isTranscribing: false,
                                 isArming: true, audioLevel: 0, engineIsLoadingModel: true),
            .error
        )
    }

    /// `.loadingModel` is a pre-capture phase, so every "capture isn't live yet"
    /// call site keeps behaving — notably the hint gate, which must stay silent.
    func testLoadingModelIsPreCaptureAndSuppressesHints() {
        XCTAssertTrue(OverlayPhase.loadingModel.isPreCapture)
        XCTAssertTrue(OverlayPhase.arming.isPreCapture)
        XCTAssertFalse(OverlayPhase.listening.isPreCapture)
        XCTAssertFalse(
            OverlayHintGate.shouldShow(
                phase: .loadingModel, isTranscribing: false, agentActive: false,
                refineArmed: false, dictationLocked: false, showTranscript: false,
                clipboardFallbackActive: false, revertActive: false
            )
        )
    }

    // MARK: - Readiness-aware arming timeout

    /// The pre-MAK-94 lie: with no load in flight a missing `onStarted` is a
    /// wiring bug, so the fallback still flips to Listening (unchanged behavior).
    func testTimeoutFlipsToListeningWhenNotLoading() {
        XCTAssertEqual(
            StreamingRoutePolicy.armingTimeoutAction(engineIsLoadingModel: false, elapsed: 15),
            .beginListening
        )
    }

    /// While the model is genuinely loading, the timeout must NOT claim capture —
    /// that is precisely the fake "Listening…" over a dead mic.
    func testTimeoutDoesNotFakeListeningDuringModelLoad() {
        XCTAssertEqual(
            StreamingRoutePolicy.armingTimeoutAction(engineIsLoadingModel: true, elapsed: 15),
            .keepWaiting
        )
    }

    /// …but the wait is bounded: past the hard cap a wedged load errors loudly
    /// rather than spinning forever.
    func testWedgedLoadFailsLoudlyAtHardCap() {
        XCTAssertEqual(
            StreamingRoutePolicy.armingTimeoutAction(
                engineIsLoadingModel: true,
                elapsed: StreamingRoutePolicy.modelLoadArmingMaxWait
            ),
            .failStuck
        )
        XCTAssertFalse(StreamingRoutePolicy.stuckModelLoadMessage.isEmpty)
    }

    /// The cap comfortably exceeds the ordinary fallback so a normal cold load is
    /// never cut short.
    func testHardCapExceedsOrdinaryTimeout() {
        XCTAssertGreaterThan(
            StreamingRoutePolicy.modelLoadArmingMaxWait,
            StreamingRoutePolicy.captureStartTimeout
        )
    }

    /// The wait ends the moment readiness resolves, even mid-poll: a load that
    /// finishes at 40s flips to Listening on the next check rather than waiting
    /// out the cap.
    func testWaitEndsAsSoonAsLoadCompletes() {
        XCTAssertEqual(
            StreamingRoutePolicy.armingTimeoutAction(engineIsLoadingModel: true, elapsed: 40),
            .keepWaiting
        )
        XCTAssertEqual(
            StreamingRoutePolicy.armingTimeoutAction(engineIsLoadingModel: false, elapsed: 40),
            .beginListening
        )
    }
}
