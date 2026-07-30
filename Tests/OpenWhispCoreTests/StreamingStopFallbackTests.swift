import XCTest
@testable import OpenWhispCore

/// The stuck-session stop fallback (`StreamingRoutePolicy.runStopFallback`) —
/// the guard timer AppState.stopAppleSpeech arms when a streaming session stops.
///
/// The regression under test (parakeet-dropout follow-up): the fallback used to
/// be a one-shot 2s deadline. A long dictation leaves Parakeet's runStop
/// draining the queued audio feed through the decoder before `finish()`, which
/// can outlast that window — the timer fired first with the STALE streamingText,
/// set appleDidCompleteFinal, and the engine's genuine final (holding the tail
/// words) was dropped by the completion guard. The loop must instead RE-ARM
/// while the engine reports `isFinalizing`.
///
/// Each test scripts the probes the way AppState wires them: `sleep` counts
/// polls instead of waiting, `isSessionStillWaiting` is the session fence
/// (flips false once the genuine final was handled or the session rotated), and
/// `isEngineFinalizing` is the engine's drain signal.
@MainActor
final class StreamingStopFallbackTests: XCTestCase {

    /// Baseline (pre-existing behavior preserved): an engine that never reports
    /// finalizing — Apple Speech, or a torn-down/deallocated engine — falls back
    /// on the FIRST poll, so genuinely stuck sessions still recover at the
    /// original 2s latency.
    func testStuckSessionCompletesOnFirstPoll() async {
        var completions = 0
        var polls = 0
        await StreamingRoutePolicy.runStopFallback(
            sleep: { _ in polls += 1 },
            isSessionStillWaiting: { true },
            isEngineFinalizing: { false },
            completeFallback: { completions += 1 }
        )
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(polls, 1, "stuck-session recovery latency must stay one interval")
    }

    /// THE bug: engine drains a decode backlog for several polls (a long
    /// dictation), then delivers its genuine final — the fence flips to done.
    /// The fallback must never have fired; firing would have completed the
    /// session with the stale partial and the guard would drop the real final's
    /// tail words. Fails with the old one-shot behavior (completion at poll 1).
    func testRearmsThroughSlowEngineDrainAndNeverClobbersGenuineFinal() async {
        var completions = 0
        var polls = 0
        await StreamingRoutePolicy.runStopFallback(
            sleep: { _ in polls += 1 },
            // Polls 1–3: still finalizing (6s of drain, past the old 2s one-shot).
            // Poll 4: the genuine final landed — session no longer waiting.
            isSessionStillWaiting: { polls < 4 },
            isEngineFinalizing: { true },
            completeFallback: { completions += 1 }
        )
        XCTAssertEqual(completions, 0, "the genuine final must win — no stale-partial completion")
        XCTAssertEqual(polls, 4)
    }

    /// The engine's stop chain finished (finalizing flips false) but its final
    /// still rides a main-actor Task hop into the completion handler. The single
    /// grace poll must hold fire across that gap; by the next poll the final has
    /// landed and the fence ends the loop silently.
    func testGracePollCoversFinalDeliveryHop() async {
        var completions = 0
        var polls = 0
        await StreamingRoutePolicy.runStopFallback(
            sleep: { _ in polls += 1 },
            // Poll 3: the hopped final was handled — session done.
            isSessionStillWaiting: { polls < 3 },
            // Finalizing only on poll 1; cleared by poll 2 (runStop returned).
            isEngineFinalizing: { polls == 1 },
            completeFallback: { completions += 1 }
        )
        XCTAssertEqual(completions, 0, "completing inside the delivery-hop gap clobbers the final")
    }

    /// The grace is ONE poll, not forever: if finalizing ends and no final ever
    /// arrives (an exit path that delivers nothing), the fallback still fires —
    /// the session must not wedge at "Finalizing...".
    func testGraceIsSinglePollThenFallbackFires() async {
        var completions = 0
        var polls = 0
        await StreamingRoutePolicy.runStopFallback(
            sleep: { _ in polls += 1 },
            isSessionStillWaiting: { true },
            isEngineFinalizing: { polls == 1 },
            completeFallback: { completions += 1 }
        )
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(polls, 3, "re-arm (finalizing), grace, fire")
    }

    /// Hard cap: an engine hung inside its finalize (reports finalizing forever)
    /// must not wedge the session — the fallback fires once maxWait elapses.
    func testHardCapFiresEvenWhileEngineStillReportsFinalizing() async {
        var completions = 0
        var polls = 0
        await StreamingRoutePolicy.runStopFallback(
            interval: 2, maxWait: 30,
            sleep: { _ in polls += 1 },
            isSessionStillWaiting: { true },
            isEngineFinalizing: { true },
            completeFallback: { completions += 1 }
        )
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(polls, 15, "15 × 2s polls = the 30s cap")
    }

    /// Session fence: once the session rotated (or the final was already
    /// handled), the loop ends without touching anything — the engine probe must
    /// not even be consulted (a rapid follow-up session could otherwise be
    /// finalized early by this session's leftover timer).
    func testCollapsedFenceEndsLoopWithoutFiring() async {
        var completions = 0
        await StreamingRoutePolicy.runStopFallback(
            sleep: { _ in },
            isSessionStillWaiting: { false },
            isEngineFinalizing: {
                XCTFail("fence must short-circuit before the engine probe")
                return true
            },
            completeFallback: { completions += 1 }
        )
        XCTAssertEqual(completions, 0)
    }

    /// The protocol default: engines that don't implement the signal (Apple
    /// Speech, SpeechAnalyzer, the lean-build stubs, test fakes) report
    /// not-finalizing, which preserves the original one-deadline behavior.
    func testEngineIsFinalizingDefaultsToFalse() {
        final class BareEngine: StreamingTranscriptionEngine {
            var onPartial: ((String) -> Void)?
            var onFinal: ((String) -> Void)?
            var onError: ((String) -> Void)?
            var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?
            var onStarted: (() -> Void)?
            func selectDevice(_ deviceID: String) {}
            func start(language: String, prompt: String) throws {}
            func stop(cancel: Bool) {}
        }
        XCTAssertFalse(BareEngine().isFinalizing)
    }
}
