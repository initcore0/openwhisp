import XCTest
@testable import OpenWhispCore

/// The capture→decide→vocabulary decision core (MAK-86 slice 1). These tests drive
/// the REAL pipeline — the same `CorrectionLearningPipeline.decide` AppState calls
/// from the AX watcher callback — with fabricated `(inserted, surviving)` pairs (a
/// stand-in "AX event source"), so the confidence weighting + proposal/auto-add
/// branching is regression-tested without any AppKit or AX plumbing.
final class CorrectionLearningPipelineTests: XCTestCase {

    /// A tiny fake for the AX watcher's role: it just feeds pairs into the pipeline
    /// and threads the resulting state, exactly like AppState's real callback, but
    /// with a synthetic "vocabulary" the auto-add path folds rules into.
    private struct FakeCaptureSource {
        var state = CorrectionLearningPipeline.State()
        var vocabulary: [Vocabulary.Substitution] = []
        private(set) var lastOutcome: CorrectionLearningPipeline.Outcome = .ignored

        mutating func observe(inserted: String, surviving: String) {
            let (next, outcome) = CorrectionLearningPipeline.decide(
                inserted: inserted,
                surviving: surviving,
                existingSubstitutions: vocabulary,
                state: state
            )
            state = next
            lastOutcome = outcome
            if case let .autoAdded(sub, _) = outcome {
                let key = CorrectionProposal.key(from: sub.from, to: sub.to)
                if !vocabulary.contains(where: { CorrectionProposal.key(from: $0.from, to: $0.to) == key }) {
                    vocabulary.append(sub)
                }
            }
        }
    }

    // MARK: - First sighting = proposal, second = auto-add (N=2)

    func testFirstObservationProposesSecondAutoAdds() {
        var src = FakeCaptureSource()

        src.observe(inserted: "kubernetis", surviving: "kubernetes")
        guard case let .proposed(p) = src.lastOutcome else {
            return XCTFail("first sighting should propose, got \(src.lastOutcome)")
        }
        XCTAssertEqual(p.from, "kubernetis")
        XCTAssertTrue(src.vocabulary.isEmpty, "proposal must not touch the vocabulary")
        XCTAssertEqual(src.state.proposals.pending.count, 1)

        // Same correction seen a second time crosses the threshold → auto-add.
        src.observe(inserted: "kubernetis", surviving: "kubernetes")
        guard case let .autoAdded(sub, superseded) = src.lastOutcome else {
            return XCTFail("second sighting should auto-add, got \(src.lastOutcome)")
        }
        XCTAssertEqual(sub.from, "kubernetis")
        XCTAssertEqual(sub.to, "kubernetes")
        XCTAssertEqual(src.vocabulary.count, 1, "auto-add folds the rule into the vocabulary")
        XCTAssertNotNil(superseded, "the now-redundant pending proposal is superseded")
        XCTAssertTrue(src.state.proposals.pending.isEmpty, "the pending proposal was dropped")
    }

    func testMultiWordCorrectionAutoAddsOnRepeat() {
        var src = FakeCaptureSource()
        src.observe(inserted: "Parra keet", surviving: "Parakeet")
        XCTAssertEqual(src.state.proposals.pending.first?.from, "Parra keet")

        src.observe(inserted: "Parra keet", surviving: "Parakeet")
        XCTAssertEqual(src.vocabulary.first?.from, "Parra keet")
        XCTAssertEqual(src.vocabulary.first?.to, "Parakeet")
    }

    // MARK: - De-dup / respect existing state

    func testAlreadyARuleIsIgnoredAndUncounted() {
        var src = FakeCaptureSource()
        src.vocabulary = [Vocabulary.Substitution(from: "kubernetis", to: "kubernetes")]

        src.observe(inserted: "kubernetis", surviving: "kubernetes")
        XCTAssertEqual(src.lastOutcome, .ignored)
        // Not counted: an existing rule must never re-enter the confidence tally.
        XCTAssertTrue(src.state.confidence.counts.isEmpty)
    }

    func testDeclinedPairIsIgnoredAndNeverAutoAdds() {
        var src = FakeCaptureSource()
        // First, propose then reject (as AppState does), forgetting the tally.
        src.observe(inserted: "cat", surviving: "bat")
        guard case let .proposed(p) = src.lastOutcome else { return XCTFail("expected proposal") }
        src.state.confidence = src.state.confidence.forgetting(from: p.from, to: p.to)
        src.state.proposals = src.state.proposals.rejecting(p.id)

        // Now, however many times it recurs, it stays ignored (declined).
        src.observe(inserted: "cat", surviving: "bat")
        XCTAssertEqual(src.lastOutcome, .ignored)
        src.observe(inserted: "cat", surviving: "bat")
        XCTAssertEqual(src.lastOutcome, .ignored)
        XCTAssertTrue(src.vocabulary.isEmpty)
    }

    // MARK: - Non-corrections

    func testUnlearnableEditIsIgnored() {
        var src = FakeCaptureSource()
        src.observe(inserted: "hello world", surviving: "hello world and lots more text")
        XCTAssertEqual(src.lastOutcome, .ignored)
        XCTAssertTrue(src.state.confidence.counts.isEmpty)
    }

    func testSecretShapedCorrectionIsIgnored() {
        var src = FakeCaptureSource()
        src.observe(inserted: "key sk-abc123def456ghi", surviving: "key redacted value")
        XCTAssertEqual(src.lastOutcome, .ignored)
        XCTAssertTrue(src.vocabulary.isEmpty)
    }

    // MARK: - Threshold documentation guard

    func testAutoAddThresholdIsTwo() {
        // Locks the documented N=2 so a change to the constant is a conscious edit.
        XCTAssertEqual(CorrectionConfidenceState.autoAddThreshold, 2)
    }
}
