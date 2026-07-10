import XCTest
@testable import OpenWhispCore

/// Covers the live-state suppression for the rotating overlay hint (MAK-25): a hint
/// may show ONLY in a calm listening/speaking user session with nothing else on the
/// overlay, and must yield to every other cue (agent, refine, lock, finalize,
/// transcript, clipboard-fallback, revert).
final class OverlayHintGateTests: XCTestCase {

    private func gate(
        phase: OverlayPhase = .listening,
        isTranscribing: Bool = false,
        agentActive: Bool = false,
        refineArmed: Bool = false,
        dictationLocked: Bool = false,
        showTranscript: Bool = false,
        clipboardFallbackActive: Bool = false,
        revertActive: Bool = false
    ) -> Bool {
        OverlayHintGate.shouldShow(
            phase: phase,
            isTranscribing: isTranscribing,
            agentActive: agentActive,
            refineArmed: refineArmed,
            dictationLocked: dictationLocked,
            showTranscript: showTranscript,
            clipboardFallbackActive: clipboardFallbackActive,
            revertActive: revertActive
        )
    }

    func testShowsInCalmListeningAndSpeaking() {
        XCTAssertTrue(gate(phase: .listening))
        XCTAssertTrue(gate(phase: .speaking))
    }

    func testSuppressedInArmingFinalizingError() {
        XCTAssertFalse(gate(phase: .arming))
        XCTAssertFalse(gate(phase: .finalizing))
        XCTAssertFalse(gate(phase: .error))
    }

    func testSuppressedWhileTranscribing() {
        XCTAssertFalse(gate(isTranscribing: true))
    }

    func testSuppressedDuringAgentSession() {
        XCTAssertFalse(gate(agentActive: true))
    }

    func testSuppressedDuringRefine() {
        XCTAssertFalse(gate(refineArmed: true))
    }

    func testSuppressedWhileLocked() {
        XCTAssertFalse(gate(dictationLocked: true))
    }

    func testSuppressedWhenTranscriptShowing() {
        XCTAssertFalse(gate(showTranscript: true))
    }

    func testSuppressedByClipboardFallbackAndRevert() {
        XCTAssertFalse(gate(clipboardFallbackActive: true))
        XCTAssertFalse(gate(revertActive: true))
    }
}
