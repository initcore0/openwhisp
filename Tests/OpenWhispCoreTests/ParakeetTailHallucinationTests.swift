import XCTest
@testable import OpenWhispCore

/// Parakeet appends a silence hallucination ("You") to the final transcript,
/// because FluidAudio's `finish()` decodes a zero-padded window with the
/// right-context holdback disabled. These pin BOTH halves of the fix: the
/// artifact is removed, and legitimate speech ending in the same words is not.
final class ParakeetTailHallucinationTests: XCTestCase {

    // MARK: - The bug: strip the artifact

    func testStripsTrailingYouAfterCompletedSentence() {
        XCTAssertEqual(
            ParakeetTailHallucination.strip(from: "Let's ship the release today. You"),
            "Let's ship the release today.")
    }

    func testStripsTrailingYouWithPunctuation() {
        XCTAssertEqual(
            ParakeetTailHallucination.strip(from: "The build is green. You."),
            "The build is green.")
    }

    func testStripsRegardlessOfCase() {
        XCTAssertEqual(
            ParakeetTailHallucination.strip(from: "Done for now! you"),
            "Done for now!")
    }

    func testStripsAfterQuestionMark() {
        XCTAssertEqual(
            ParakeetTailHallucination.strip(from: "Can you review the PR? You"),
            "Can you review the PR?")
    }

    // MARK: - The guard: never eat real speech

    /// A standalone "Thank you" after a finished sentence is a genuine dictation
    /// closer (emails: "Please send the report. Thank you") that guard 3 cannot
    /// distinguish from an artifact — so it must NOT be in the phrase list, and
    /// the bare-"you" rule must not chew into it (guard 3 rejects: "Thank" is
    /// not terminal punctuation).
    func testKeepsStandaloneThankYouAfterASentence() {
        let text = "That covers everything. Thank you"
        XCTAssertEqual(ParakeetTailHallucination.strip(from: text), text)
    }

    /// Same reasoning: "Thanks for watching" / "Bye" are genuinely dictated
    /// sign-offs (a streamer's outro, a chat message). Only the observed
    /// Parakeet artifact — a bare "You" — is ever stripped.
    func testKeepsGenuineSignOffPhrases() {
        let outro = "And that's the summary. Thanks for watching"
        XCTAssertEqual(ParakeetTailHallucination.strip(from: outro), outro)
        let chat = "See you at five. Bye"
        XCTAssertEqual(ParakeetTailHallucination.strip(from: chat), chat)
    }

    /// The critical false-positive case. "you" here is the object of the real
    /// final clause; the preceding token is a plain word, not a sentence end.
    func testKeepsLegitimateTrailingYouMidSentence() {
        let text = "The choice is entirely up to you"
        XCTAssertEqual(ParakeetTailHallucination.strip(from: text), text)
    }

    func testKeepsLegitimateTrailingYouWithFinalPeriod() {
        let text = "The choice is entirely up to you."
        XCTAssertEqual(ParakeetTailHallucination.strip(from: text), text)
    }

    func testKeepsGenuineThankYouClosingASentence() {
        let text = "I really appreciate the review, thank you."
        XCTAssertEqual(ParakeetTailHallucination.strip(from: text), text)
    }

    /// No preceding terminal punctuation → not an artifact, leave it alone.
    func testKeepsTrailingYouAfterComma() {
        let text = "If that works for you, you"
        XCTAssertEqual(ParakeetTailHallucination.strip(from: text), text)
    }

    // MARK: - Degenerate inputs

    /// Never blank a transcript that is nothing but the artifact — an empty
    /// final would lose the session rather than clean it.
    func testDoesNotBlankATranscriptThatIsOnlyTheArtifact() {
        XCTAssertEqual(ParakeetTailHallucination.strip(from: "You"), "You")
    }

    func testEmptyAndWhitespacePassThrough() {
        XCTAssertEqual(ParakeetTailHallucination.strip(from: ""), "")
        XCTAssertEqual(ParakeetTailHallucination.strip(from: "   "), "   ")
    }

    func testUnaffectedTranscriptIsReturnedByteForByte() {
        let text = "Ship it and then update the changelog."
        XCTAssertEqual(ParakeetTailHallucination.strip(from: text), text)
    }
}
