import XCTest
@testable import OpenWhispCore

/// State-machine tests for `DictationSessionState` (MAK-8 step 9a — the first
/// strangler slice of the `DictationCoordinator` extraction).
///
/// 9a moves the session-state inventory off the AppKit-only `AppState` into this
/// Foundation-only value type without moving the lifecycle funnel (that is 9b).
/// These tests exercise the struct through the SAME mutation sequences the
/// production funnel performs (`beginSession` / `stop` / `complete` / `cancel` /
/// `finishSessionUI`), locking the invariants that the "never lose text" path
/// depends on:
///
///  - the **generation fence** (`activeSessionID`) is re-minted on every start
///    and every cancel, so a stale async callback can be dropped;
///  - **`reset()`** returns to a clean idle session (fresh id, everything
///    cleared) — the semantics `cancelDictation` re-arms with;
///  - the agent/user **initiator** drives `suppressOutput` exactly as
///    `beginSession` snapshots it;
///  - **restart-during-teardown** yields a fresh fence that discriminates the
///    old session from the new one.
///
/// Each transition is written as a small helper mirroring the real AppState
/// funnel step, so if a future refactor re-wires a field the wrong way the
/// mismatch fails here rather than silently at runtime.
final class DictationSessionStateTests: XCTestCase {

    // MARK: Funnel-mirroring transition helpers
    //
    // These reproduce the exact field mutations AppState performs at each
    // lifecycle site (see AppState.beginSession / cancelDictation). Keeping them
    // here means a regression in the field wiring (9b/9c) fails a fast unit test.

    /// Mirrors `AppState.beginSession(streaming:)`: fresh fence, arm the session,
    /// snapshot the streaming/output/initiator-derived flags.
    private func begin(_ s: inout DictationSessionState, streaming: Bool,
                       initiator: SessionInitiator = .user, preview: Bool = false) {
        s.sessionActive = true
        s.pendingStop = false
        s.activeSessionID = UUID()
        s.acceptingLiveChunks = streaming
        s.currentSessionText = ""
        s.openAIEnhancementEnabledForSession = true
        s.isLiveChunkSession = streaming
        s.isPreviewSession = streaming && preview
        s.sessionInitiator = initiator
        s.suppressOutput = initiator.isAgent
        s.voiceEditingActiveForSession = false
        s.voiceEditBuffer = VoiceEditBuffer()
        s.isStreamingSession = streaming
    }

    /// Mirrors `AppState.cancelDictation`: re-mint the fence and disarm.
    private func cancel(_ s: inout DictationSessionState) {
        s.activeSessionID = UUID()
        s.sessionActive = false
        s.pendingStop = false
    }

    // MARK: Fresh / idle state

    func testFreshStateIsIdle() {
        let s = DictationSessionState()
        XCTAssertFalse(s.sessionActive)
        XCTAssertFalse(s.pendingStop)
        XCTAssertFalse(s.pendingPreemptStart)
        XCTAssertFalse(s.suppressOutput)
        XCTAssertEqual(s.currentSessionText, "")
        XCTAssertEqual(s.sessionInitiator, .user)
        XCTAssertNil(s.sessionOutcome)
        XCTAssertNil(s.recorderSessionID)
        XCTAssertNil(s.profileOverrideBackup)
        XCTAssertFalse(s.isLiveChunkSession)
        XCTAssertFalse(s.isPreviewSession)
    }

    // MARK: idle -> listening -> transcribing -> inserting -> idle (happy path)

    func testHappyPathUserSessionTransitions() {
        var s = DictationSessionState()
        let idle = s.activeSessionID

        // idle -> listening
        begin(&s, streaming: false)
        XCTAssertTrue(s.sessionActive)
        XCTAssertNotEqual(s.activeSessionID, idle, "start must re-mint the fence")
        XCTAssertFalse(s.suppressOutput, "user session pastes; never suppressed")
        let listening = s.activeSessionID

        // transcribing: text accumulates under the SAME fence
        s.currentSessionText = "hello world"
        XCTAssertEqual(s.activeSessionID, listening, "capture must not change the fence")

        // inserting -> idle: the funnel records the outcome, then resets
        s.sessionOutcome = .completed(text: s.currentSessionText)
        XCTAssertEqual(s.sessionOutcome, .completed(text: "hello world"))
        s.reset()
        XCTAssertFalse(s.sessionActive)
        XCTAssertEqual(s.currentSessionText, "")
        XCTAssertNil(s.sessionOutcome)
    }

    // MARK: agent initiator drives suppressOutput

    func testAgentSessionSuppressesOutput() {
        var s = DictationSessionState()
        begin(&s, streaming: true,
              initiator: .agent(client: "claude-code", prompt: "Which branch?"))
        XCTAssertTrue(s.suppressOutput, "agent session returns the transcript, never pastes")
        XCTAssertTrue(s.sessionInitiator.isAgent)
        XCTAssertEqual(s.sessionInitiator.clientName, "claude-code")
    }

    func testAgentBiasTermsRideOnTheInitiatorAndVanishOnReset() {
        var s = DictationSessionState()
        begin(&s, streaming: true,
              initiator: .agent(client: "cli", prompt: nil, biasTerms: ["MAK", "OpenWhisp"]))
        XCTAssertEqual(s.sessionInitiator.agentBiasTerms, ["MAK", "OpenWhisp"])
        s.reset()
        XCTAssertEqual(s.sessionInitiator, .user)
        XCTAssertTrue(s.sessionInitiator.agentBiasTerms.isEmpty,
                      "bias terms exist only while the initiator is .agent")
    }

    // MARK: cancel path — the fence re-mints and no transcript survives

    func testCancelReMintsFenceAndDisarms() {
        var s = DictationSessionState()
        begin(&s, streaming: false)
        let live = s.activeSessionID
        s.currentSessionText = "half a sentence"

        cancel(&s)
        XCTAssertNotEqual(s.activeSessionID, live, "cancel must re-mint the fence")
        XCTAssertFalse(s.sessionActive)
        XCTAssertFalse(s.pendingStop)
    }

    func testStaleCallbackAfterCancelIsDiscriminatedByFence() {
        var s = DictationSessionState()
        begin(&s, streaming: true)
        let captured = s.activeSessionID   // an async transcription callback captured this

        cancel(&s)
        // The late callback checks its captured id against the live fence and drops
        // itself — this is the "never leak a cancelled session's text" guard.
        XCTAssertNotEqual(captured, s.activeSessionID)
    }

    // MARK: pending-stop before the grant callback armed recording

    func testPendingStopIsHonoredAndClearedByReset() {
        var s = DictationSessionState()
        begin(&s, streaming: false)
        // Stop arrived before recording actually started.
        s.pendingStop = true
        XCTAssertTrue(s.pendingStop)
        s.reset()
        XCTAssertFalse(s.pendingStop)
    }

    // MARK: restart-during-teardown

    func testRestartDuringTeardownGetsAFreshFence() {
        var s = DictationSessionState()
        begin(&s, streaming: true)
        let first = s.activeSessionID

        // Teardown of the first session begins (cancel), then the preempt-replacement
        // start arms immediately — the classic agent-preempt-then-user-start race.
        s.pendingPreemptStart = true
        cancel(&s)
        begin(&s, streaming: false)   // the user's replacement session
        let second = s.activeSessionID

        XCTAssertNotEqual(first, second,
                          "the replacement session must not share the torn-down session's fence")
        XCTAssertTrue(s.sessionActive)
    }

    // MARK: profile-override backup round-trips through the state

    func testProfileOverrideBackupRoundTrip() {
        var s = DictationSessionState()
        s.profileOverrideBackup = ProfileOverrideBackup(
            language: "de", translateToEnglish: true, outputMode: "preview", aiCleanup: false)
        s.suppressSettingsPersistence = true

        let backup = s.profileOverrideBackup
        XCTAssertEqual(backup?.language, "de")
        XCTAssertEqual(backup?.translateToEnglish, true)
        XCTAssertEqual(backup?.outputMode, "preview")
        XCTAssertEqual(backup?.aiCleanup, false)

        // Restore clears both, mirroring restoreProfileOverridesIfNeeded.
        s.profileOverrideBackup = nil
        s.suppressSettingsPersistence = false
        XCTAssertNil(s.profileOverrideBackup)
        XCTAssertFalse(s.suppressSettingsPersistence)
    }

    // MARK: recorder-session fence (the once-wired callback discriminator)

    func testRecorderSessionIDTracksTheStartingSession() {
        var s = DictationSessionState()
        begin(&s, streaming: true)
        s.recorderSessionID = s.activeSessionID
        let started = s.recorderSessionID

        // A stale .stopped from a cancelled session lands after the next begins.
        cancel(&s)
        begin(&s, streaming: true)
        XCTAssertNotEqual(started, s.activeSessionID,
                          "the new session's fence differs from the recorder's starting id, so a "
                          + "stale recorder state change is dropped")
    }

    // MARK: reset() is total (every field returns to the idle default)

    func testResetIsTotal() {
        var s = DictationSessionState()
        begin(&s, streaming: true,
              initiator: .agent(client: "cli", prompt: "p", biasTerms: ["x"]), preview: true)
        s.currentSessionText = "text"
        s.recorderSessionID = UUID()
        s.appleLiveInsertedText = "apple"
        s.appleDidCompleteFinal = true
        s.isAppleSpeechSession = true
        s.voiceEditingActiveForSession = true
        s.sessionOutcome = .completed(text: "text")
        s.modeRefineInstructionOverride = "mode"
        s.presetRefineInstructionOverride = "preset"
        s.sessionInsertionModeOverride = .paste
        s.suppressSettingsPersistence = true
        s.profileOverrideBackup = ProfileOverrideBackup(
            language: "de", translateToEnglish: true, outputMode: "preview", aiCleanup: false)

        s.reset()

        // reset() mints a fresh fence (that is the point — a new idle session), so
        // normalize the two ids before comparing every other field for equality.
        var normalized = s
        var expected = DictationSessionState()
        expected.activeSessionID = s.activeSessionID
        normalized.activeSessionID = s.activeSessionID
        XCTAssertEqual(normalized, expected,
                       "reset must equal a freshly constructed idle state apart from the fresh fence")
    }

    func testResetClearsEveryTrackedFieldExplicitly() {
        var s = DictationSessionState()
        begin(&s, streaming: true,
              initiator: .agent(client: "cli", prompt: "p"), preview: true)
        s.currentSessionText = "text"
        s.sessionOutcome = .cancelled
        s.recorderSessionID = UUID()

        s.reset()

        XCTAssertFalse(s.sessionActive)
        XCTAssertFalse(s.pendingStop)
        XCTAssertFalse(s.pendingPreemptStart)
        XCTAssertFalse(s.acceptingLiveChunks)
        XCTAssertFalse(s.isStreamingSession)
        XCTAssertFalse(s.isLiveChunkSession)
        XCTAssertFalse(s.isPreviewSession)
        XCTAssertFalse(s.isAppleSpeechSession)
        XCTAssertFalse(s.suppressOutput)
        XCTAssertFalse(s.voiceEditingActiveForSession)
        XCTAssertFalse(s.suppressSettingsPersistence)
        XCTAssertEqual(s.currentSessionText, "")
        XCTAssertEqual(s.appleLiveInsertedText, "")
        XCTAssertFalse(s.appleDidCompleteFinal)
        XCTAssertEqual(s.sessionInitiator, .user)
        XCTAssertNil(s.sessionOutcome)
        XCTAssertNil(s.recorderSessionID)
        XCTAssertNil(s.profileOverrideBackup)
        XCTAssertNil(s.modeRefineInstructionOverride)
        XCTAssertNil(s.presetRefineInstructionOverride)
        XCTAssertNil(s.sessionInsertionModeOverride)
        XCTAssertEqual(s.voiceEditBuffer, VoiceEditBuffer())
    }
}
