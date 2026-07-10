import XCTest
@testable import OpenWhispCore

/// The pure prefix/suffix diff that turns "field value after insert" +
/// "field value later" into a single-token (inserted, surviving) pair (MAK-41
/// Part C capture core). Anything that isn't a clean one-word, one-region edit
/// must return nil so we never feed a noisy pair to the learner.
final class EditDiffTests: XCTestCase {

    private func diff(_ after: String, _ later: String) -> (inserted: String, surviving: String)? {
        EditDiff.singleTokenCorrection(afterInsert: after, later: later)
    }

    func testSingleWordSpellingFixIsCaptured() {
        let r = diff("we run kubernetis in prod", "we run kubernetes in prod")
        XCTAssertEqual(r?.inserted, "kubernetis")
        XCTAssertEqual(r?.surviving, "kubernetes")
    }

    func testCasingFixIsCaptured() {
        let r = diff("i talked to claude today", "i talked to Claude today")
        XCTAssertEqual(r?.inserted, "claude")
        XCTAssertEqual(r?.surviving, "Claude")
    }

    func testFixAtStartIsCaptured() {
        let r = diff("anthropic makes claude", "Anthropic makes claude")
        XCTAssertEqual(r?.inserted, "anthropic")
        XCTAssertEqual(r?.surviving, "Anthropic")
    }

    func testFixAtEndIsCaptured() {
        let r = diff("we use kubernetis", "we use kubernetes")
        XCTAssertEqual(r?.inserted, "kubernetis")
        XCTAssertEqual(r?.surviving, "kubernetes")
    }

    func testNoChangeReturnsNil() {
        XCTAssertNil(diff("hello world", "hello world"))
    }

    func testAppendedTextReturnsNil() {
        // User kept typing a whole new sentence — not a localized single-word fix.
        XCTAssertNil(diff("hello world", "hello world and then a lot more text"))
    }

    func testTwoSeparateWordEditsReturnNil() {
        // Two regions changed → the middle spans multiple tokens → nil.
        XCTAssertNil(diff("claude and anthropic rock", "Claude and Anthropic rock"))
    }

    func testMultiWordReplacementReturnsNil() {
        // One region but multiple tokens added → not a single-word correction.
        XCTAssertNil(diff("send the report", "send the final report"))
    }

    func testWordDeletionReturnsNil() {
        // Removed a word entirely (added side empty after trim) → nil.
        XCTAssertNil(diff("the quick brown fox", "the quick  fox"))
    }

    func testWholeFieldClearedReturnsNil() {
        XCTAssertNil(diff("kubernetis", ""))
    }

    // The capture core hands off to proposeSubstitution, which is the FINAL gate.
    func testCapturedPairFlowsToProposal() {
        guard let pair = diff("we run kubernetis now", "we run kubernetes now") else {
            return XCTFail("expected a captured pair")
        }
        let proposal = CorrectionLearner.proposeSubstitution(inserted: pair.inserted, surviving: pair.surviving)
        XCTAssertEqual(proposal?.from, "kubernetis")
        XCTAssertEqual(proposal?.to, "kubernetes")
    }

    func testCapturedUnrelatedSwapIsRejectedByProposal() {
        // EditDiff captures it (single token, single region), but proposeSubstitution
        // rejects an unrelated word swap — the two-layer gate holds.
        guard let pair = diff("i saw a cat there", "i saw a elephant there") else {
            return XCTFail("expected a captured pair")
        }
        XCTAssertNil(CorrectionLearner.proposeSubstitution(inserted: pair.inserted, surviving: pair.surviving))
    }
}
