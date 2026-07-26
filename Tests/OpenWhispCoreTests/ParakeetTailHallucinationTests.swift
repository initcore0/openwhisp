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

    /// Multi-token artifacts must be matched whole — stripping only the "you"
    /// of "Thank you" would leave a dangling "Thank".
    func testStripsMultiTokenArtifactWhole() {
        XCTAssertEqual(
            ParakeetTailHallucination.strip(from: "That covers everything. Thank you"),
            "That covers everything.")
    }

    func testStripsThanksForWatching() {
        XCTAssertEqual(
            ParakeetTailHallucination.strip(from: "And that's the summary. Thanks for watching"),
            "And that's the summary.")
    }

    // MARK: - The guard: never eat real speech

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
