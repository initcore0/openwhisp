import XCTest
@testable import OpenWhispCore

/// The widened multi-word capture + learner gates (MAK-86 slice 1): a correction
/// that spans up to ~4 words, including split runs ("Parra keet" → "Parakeet")
/// and wrongly-split compounds ("open whisper" → "OpenWhisp").
final class MultiWordCorrectionTests: XCTestCase {

    private func diff(_ after: String, _ later: String) -> (inserted: String, surviving: String)? {
        EditDiff.multiWordCorrection(afterInsert: after, later: later)
    }

    private func propose(_ inserted: String, _ surviving: String) -> Vocabulary.Substitution? {
        CorrectionLearner.proposePhraseSubstitution(inserted: inserted, surviving: surviving)
    }

    // MARK: - EditDiff.multiWordCorrection captures the region

    func testSplitRunIsCaptured() {
        let r = diff("i love my Parra keet bird", "i love my Parakeet bird")
        XCTAssertEqual(r?.inserted, "Parra keet")
        XCTAssertEqual(r?.surviving, "Parakeet")
    }

    func testWronglySplitCompoundIsCaptured() {
        let r = diff("i use open whisper daily", "i use OpenWhisp daily")
        XCTAssertEqual(r?.inserted, "open whisper")
        XCTAssertEqual(r?.surviving, "OpenWhisp")
    }

    func testTwoWordPhraseFixIsCaptured() {
        let r = diff("run clod code now", "run Claude Code now")
        XCTAssertEqual(r?.inserted, "clod code")
        XCTAssertEqual(r?.surviving, "Claude Code")
    }

    func testRegionBeyondMaxWordsReturnsNil() {
        // Five changed words on the inserted side (b c d e f) exceeds the 4-word cap.
        XCTAssertNil(EditDiff.multiWordCorrection(
            afterInsert: "a b c d e f g",
            later: "a Z g",
            maxWords: 4
        ))
    }

    func testNoChangeReturnsNil() {
        XCTAssertNil(diff("hello world", "hello world"))
    }

    // MARK: - Learner gate

    func testSplitRunIsProposed() {
        let s = propose("Parra keet", "Parakeet")
        XCTAssertEqual(s?.from, "Parra keet")
        XCTAssertEqual(s?.to, "Parakeet")
    }

    func testCompoundSplitIsProposed() {
        let s = propose("open whisper", "OpenWhisp")
        XCTAssertEqual(s?.from, "open whisper")
        XCTAssertEqual(s?.to, "OpenWhisp")
    }

    func testUnrelatedPhraseRewriteIsRejected() {
        // Same-ish word count but wholesale different words → not a correction.
        XCTAssertNil(propose("send the report", "forward the document"))
    }

    func testSecretMaterialIsNeverLearned() {
        // Even if it captured as a region, a credential-shaped token blocks it.
        XCTAssertNil(propose("my key sk-abc123def456ghi", "my key redacted here"))
        XCTAssertNil(propose("token user1029384756token", "token something else"))
    }

    func testTypographyOnlyDifferenceIsRejected() {
        XCTAssertNil(propose("open \u{2018}whisper\u{2019}", "open 'whisper'"))
    }

    // MARK: - Two-layer: capture → learner

    func testCapturedSplitRunFlowsToProposal() {
        guard let pair = diff("my Parra keet sings", "my Parakeet sings") else {
            return XCTFail("expected a captured pair")
        }
        let s = CorrectionLearner.proposePhraseSubstitution(inserted: pair.inserted, surviving: pair.surviving)
        XCTAssertEqual(s?.from, "Parra keet")
        XCTAssertEqual(s?.to, "Parakeet")
    }
}
