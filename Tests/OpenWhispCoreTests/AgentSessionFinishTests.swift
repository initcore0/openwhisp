import XCTest
@testable import OpenWhispCore

/// MAK-76: the pure finish-state machine for agent-initiated dictation — the
/// tap-to-toggle finish control and the autoSubmit confirm/append window.
final class AgentSessionFinishTests: XCTestCase {

    // MARK: defaults

    func testDefaultIsAutoSubmit() {
        let m = AgentSessionFinish()
        XCTAssertTrue(m.autoSubmit, "default must match legacy immediate-return behavior")
        XCTAssertEqual(m.confirmWindow, AgentSessionFinish.defaultConfirmWindow)
        XCTAssertEqual(AgentSessionFinish.defaultConfirmWindow, 4.0)
    }

    // MARK: tap-to-toggle (the human's deliberate finish)

    func testHotkeyTapWhileCapturingFinishesNow() {
        // A tap always finishes now — this overrides a pending EOU / silence wait.
        for autoSubmit in [true, false] {
            let m = AgentSessionFinish(autoSubmit: autoSubmit)
            XCTAssertEqual(m.action(for: .hotkeyTap, in: .capturing), .finishNow)
        }
    }

    func testHotkeyTapDuringConfirmWindowReopensForAppend() {
        // autoSubmit off: an auto-stop opened the confirm window; a tap there means
        // "I have more" — re-open the mic rather than submit a half thought.
        let m = AgentSessionFinish(autoSubmit: false)
        let action = m.action(for: .hotkeyTap, in: .confirming)
        XCTAssertEqual(action, .reopenForAppend)
        XCTAssertEqual(m.next(after: action, in: .confirming), .capturing,
                       "append returns to capturing")
    }

    // MARK: autoSubmit ON — auto-stop finalizes immediately (legacy)

    func testAutoStopWithAutoSubmitFinishesNow() {
        let m = AgentSessionFinish(autoSubmit: true)
        XCTAssertEqual(m.action(for: .autoStopFired, in: .capturing), .finishNow)
    }

    // MARK: autoSubmit OFF — auto-stop opens the confirm window

    func testAutoStopWithoutAutoSubmitOpensConfirmWindow() {
        let m = AgentSessionFinish(autoSubmit: false)
        let action = m.action(for: .autoStopFired, in: .capturing)
        XCTAssertEqual(action, .beginConfirmWindow)
        XCTAssertEqual(m.next(after: action, in: .capturing), .confirming)
    }

    func testConfirmWindowElapsedSubmits() {
        let m = AgentSessionFinish(autoSubmit: false)
        XCTAssertEqual(m.action(for: .confirmWindowElapsed, in: .confirming), .finishNow)
    }

    // MARK: no-op / guard transitions

    func testAutoStopDuringConfirmIsNoop() {
        // Capture is already paused; a second auto-stop signal must not double-act.
        let m = AgentSessionFinish(autoSubmit: false)
        XCTAssertEqual(m.action(for: .autoStopFired, in: .confirming), .none)
    }

    func testConfirmWindowElapsedWhileCapturingIsNoop() {
        // No window is armed while capturing — an elapsed signal is meaningless.
        let m = AgentSessionFinish(autoSubmit: false)
        XCTAssertEqual(m.action(for: .confirmWindowElapsed, in: .capturing), .none)
    }

    // MARK: handle() — the phase-owning app entry point

    func testHandleAdvancesPhase() {
        var m = AgentSessionFinish(autoSubmit: false)
        XCTAssertEqual(m.phase, .capturing)
        XCTAssertEqual(m.handle(.autoStopFired), .beginConfirmWindow)
        XCTAssertEqual(m.phase, .confirming)
        XCTAssertEqual(m.handle(.hotkeyTap), .reopenForAppend)
        XCTAssertEqual(m.phase, .capturing)
        XCTAssertEqual(m.handle(.hotkeyTap), .finishNow)
    }

    // MARK: extracted AppState helpers (MAK-76 ratchet extraction)

    func testAgentDictateOutcomeResolution() {
        typealias R = AgentDictateOutcome
        // completed: endedBy precedence timeout > stop > user.
        XCTAssertEqual(R.resolve(.completed(text: "hi"), duration: 2, timedOut: false, stopped: false),
                       .success(.init(text: "hi", durationSeconds: 2, timedOut: false, endedBy: .user)))
        XCTAssertEqual(R.resolve(.completed(text: "hi"), duration: 2, timedOut: false, stopped: true),
                       .success(.init(text: "hi", durationSeconds: 2, timedOut: false, endedBy: .stop)))
        XCTAssertEqual(R.resolve(.completed(text: "hi"), duration: 2, timedOut: true, stopped: true),
                       .success(.init(text: "hi", durationSeconds: 2, timedOut: true, endedBy: .timeout)))
        // empty: timeout error when timed out, else empty success.
        if case .failure(let err) = R.resolve(.empty, duration: 1, timedOut: true, stopped: false) {
            XCTAssertEqual(err.code, BridgeWire.ErrorObject.domain(.timeout, message: "x").code)
        } else { XCTFail("expected timeout error") }
        XCTAssertEqual(R.resolve(.empty, duration: 1, timedOut: false, stopped: true),
                       .success(.init(text: "", durationSeconds: 1, timedOut: false, endedBy: .stop)))
        // cancelled never yields a transcript.
        if case .success = R.resolve(.cancelled, duration: 1, timedOut: false, stopped: false) {
            XCTFail("cancel must be an error")
        }
    }

    func testAgentPromptPresentation() {
        let p = AgentPromptPresentation(clientName: "claude-code", prompt: "Deploy now?")
        XCTAssertEqual(p.banner, "claude-code asks: Deploy now?")
        XCTAssertEqual(p.clientLabel, "claude-code")
        XCTAssertEqual(p.question, "Deploy now?")
        let anon = AgentPromptPresentation(clientName: "", prompt: nil)
        XCTAssertEqual(anon.banner, "An agent asked you to dictate")
        XCTAssertEqual(anon.clientLabel, "An agent")
        XCTAssertNil(anon.question)
    }

    // MARK: a full autoSubmit-off round: speak → auto-stop → append → tap-finish

    func testFullAppendThenFinishFlow() {
        let m = AgentSessionFinish(autoSubmit: false)
        var phase: AgentSessionFinish.Phase = .capturing

        // Speaker pauses → auto-stop → confirm window.
        var a = m.action(for: .autoStopFired, in: phase)
        XCTAssertEqual(a, .beginConfirmWindow)
        phase = m.next(after: a, in: phase)
        XCTAssertEqual(phase, .confirming)

        // User taps to add more → back to capturing.
        a = m.action(for: .hotkeyTap, in: phase)
        XCTAssertEqual(a, .reopenForAppend)
        phase = m.next(after: a, in: phase)
        XCTAssertEqual(phase, .capturing)

        // User taps again to finish → done now.
        a = m.action(for: .hotkeyTap, in: phase)
        XCTAssertEqual(a, .finishNow)
    }
}
