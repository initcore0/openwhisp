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

/// Covers the post-dictation overlay "revert to original" affordance decision
/// (MAK-35 follow-up): it shows only when the newest history entry actually has raw
/// words to restore AND the overlay is settled (not mid-session/refine).
final class OverlayRevertTests: XCTestCase {

    private func target(
        mostRecentRevertTarget: String? = "raw words",
        isRecording: Bool = false,
        isTranscribing: Bool = false,
        isArming: Bool = false,
        refineArmed: Bool = false
    ) -> String? {
        OverlayRevert.target(
            mostRecentRevertTarget: mostRecentRevertTarget,
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            isArming: isArming,
            refineArmed: refineArmed
        )
    }

    func testShownWhenSettledAndRevertTargetPresent() {
        XCTAssertEqual(target(), "raw words")
    }

    func testHiddenWhenNoRevertTarget() {
        // The AI didn't change the words (or there's no history) → nothing to revert.
        XCTAssertNil(target(mostRecentRevertTarget: nil))
    }

    func testHiddenWhenRevertTargetEmpty() {
        XCTAssertNil(target(mostRecentRevertTarget: ""))
    }

    func testHiddenWhileRecording() {
        // A new session is live — the previous revert must not linger.
        XCTAssertNil(target(isRecording: true))
    }

    func testHiddenWhileTranscribing() {
        // Finalizing/polishing: the entry isn't recorded yet, so there's nothing
        // stable to revert to on screen.
        XCTAssertNil(target(isTranscribing: true))
    }

    func testHiddenWhileArming() {
        XCTAssertNil(target(isArming: true))
    }

    func testHiddenWhileRefining() {
        // Refine (a spoken-instruction rewrite) owns the overlay; the revert control
        // would compete with the refine instruction row.
        XCTAssertNil(target(refineArmed: true))
    }
}

/// Covers the in-place replacement decision for the overlay revert: swap the just-
/// inserted dictation for the raw words, but ONLY when the field still ends with
/// exactly what we inserted (so we never clobber the user's own content).
final class ReplaceLastInsertionTests: XCTestCase {

    private func newValue(_ current: String?, inserted: String, raw: String) -> String? {
        ReplaceLastInsertion.newValue(currentValue: current, inserted: inserted, raw: raw)
    }

    func testReplacesWhenFieldEndsWithInsertedText() {
        // The field holds prior content + our inserted (cleaned) text; we swap just
        // the inserted slice for the raw words, leaving the prefix untouched.
        XCTAssertEqual(
            newValue("Notes: Hello, team.", inserted: "Hello, team.", raw: "um hello team"),
            "Notes: um hello team"
        )
    }

    func testReplacesWhenFieldHasTrailingSpaceFromInsert() {
        // addTrailingSpace mode leaves a single space after the inserted text; the
        // replacement preserves that same trailing space.
        XCTAssertEqual(
            newValue("Hello, team. ", inserted: "Hello, team.", raw: "um hello team"),
            "um hello team "
        )
    }

    func testReplacesWholeFieldWhenItIsOnlyOurInsertion() {
        XCTAssertEqual(
            newValue("Hello, team.", inserted: "Hello, team.", raw: "um hello team"),
            "um hello team"
        )
    }

    func testSkipsWhenFieldDoesNotEndWithInsertedText() {
        // The user typed after the paste — the field no longer ends with our text, so
        // a blind replace could delete their words. Skip (→ clipboard fallback).
        XCTAssertNil(newValue("Hello, team. and more", inserted: "Hello, team.", raw: "um hello team"))
    }

    func testSkipsWhenValueUnreadable() {
        XCTAssertNil(newValue(nil, inserted: "Hello, team.", raw: "um hello team"))
    }

    func testSkipsWhenInsertedEmpty() {
        XCTAssertNil(newValue("anything", inserted: "   ", raw: "um hello team"))
    }

    func testSkipsWhenRawEqualsInsertedNoOp() {
        // Raw == inserted (trimmed): reverting would change nothing.
        XCTAssertNil(newValue("Hello team", inserted: "Hello team", raw: " Hello team "))
    }

    func testMatchesFieldThatSmartQuotedTheInsertedText() {
        // A smart-quoting field (Notes/Pages/Mail) rendered our straight quote as a
        // curly one. The folded suffix still matches, and the returned value keeps the
        // user's byte-exact prefix while restoring the raw words.
        let field = "Note: I said \u{201C}hi\u{201D}."          // curly quotes in the field
        let inserted = "I said \"hi\"."                          // straight quotes we sent
        XCTAssertEqual(newValue(field, inserted: inserted, raw: "i said hi"), "Note: i said hi")
    }

    func testMatchesFieldThatRenderedEllipsis() {
        // The field folded "..." to a single "…" glyph; the fold-aware suffix walk still
        // finds our slice and leaves the prefix intact.
        let field = "wait\u{2026}"                                // "wait…"
        XCTAssertEqual(newValue(field, inserted: "wait...", raw: "wait dot dot dot"),
                       "wait dot dot dot")
    }

    func testKeepsPrefixByteExactAcrossSmartPunctuation() {
        // The user's own prefix also contains a curly apostrophe; it must survive the
        // revert unchanged (we only replace OUR slice, matched on the folded form).
        let field = "It\u{2019}s done. I said \u{201C}go\u{201D}."
        let inserted = "I said \"go\"."
        XCTAssertEqual(newValue(field, inserted: inserted, raw: "i said go"),
                       "It\u{2019}s done. i said go")
    }

    /// End-to-end composition of the two halves `AppState.revertLastDictation` runs:
    /// (1) the overlay shows the affordance because the newest entry has a revertTarget;
    /// (2) reverting swaps the field's inserted text for that raw target in place; and
    /// (3) afterward the reverted entry exposes no revertTarget, so the control hides
    /// and a second revert is a no-op — matching the History revert's clear-rawText.
    func testRevertRoundTripAcrossOverlayAndFieldDecisions() {
        let raw = "um so like i think we should ship it"
        let final = "I think we should ship it."
        // A dictation with an AI-cleanup change: the entry keeps the raw baseline.
        let entry = TranscriptionEntry(
            text: final, date: Date(), appBundleID: nil, appName: nil, rawText: raw
        )

        // (1) The overlay offers revert in a settled state.
        let shown = OverlayRevert.target(
            mostRecentRevertTarget: entry.revertTarget,
            isRecording: false, isTranscribing: false, isArming: false, refineArmed: false
        )
        XCTAssertEqual(shown, raw)

        // (2) The field (holding the inserted final text + trailing space) swaps to raw.
        XCTAssertEqual(
            ReplaceLastInsertion.newValue(currentValue: final + " ", inserted: final, raw: raw),
            raw + " "
        )

        // (3) After the revert clears rawText, the affordance hides — no double revert.
        let reverted = TranscriptionEntry(
            id: entry.id, text: raw, date: entry.date,
            appBundleID: nil, appName: nil, rawText: nil
        )
        XCTAssertNil(OverlayRevert.target(
            mostRecentRevertTarget: reverted.revertTarget,
            isRecording: false, isTranscribing: false, isArming: false, refineArmed: false
        ))
    }
}
