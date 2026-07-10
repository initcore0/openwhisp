import XCTest
@testable import OpenWhispCore

/// The pure propose → accept/reject state machine (MAK-41 Part C). No AX, no
/// SwiftUI — this is the plumbing the ticket asks to be fully tested: a captured
/// (inserted, surviving) pair flows through `proposeSubstitution` into a
/// user-visible proposal, an accepted proposal yields a substitution the caller
/// adds to the dictionary, and a rejected one does NOT mutate anything (and is
/// never re-proposed).
final class CorrectionProposalTests: XCTestCase {

    private let clock = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Capture → proposal

    func testCleanCorrectionBecomesProposal() {
        let (state, added) = CorrectionProposalState.empty.considering(
            inserted: "we run kubernetis in prod",
            surviving: "we run kubernetes in prod",
            existingSubstitutions: [],
            now: clock
        )
        XCTAssertEqual(added?.from, "kubernetis")
        XCTAssertEqual(added?.to, "kubernetes")
        XCTAssertEqual(state.pending.count, 1)
        XCTAssertEqual(state.pending.first?.from, "kubernetis")
    }

    func testNonCorrectionDoesNotPropose() {
        // A whole rewrite is not a single-word correction → no proposal.
        let (state, added) = CorrectionProposalState.empty.considering(
            inserted: "send the report to the team",
            surviving: "please forward this document to everyone",
            existingSubstitutions: [],
            now: clock
        )
        XCTAssertNil(added)
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testUnchangedTextDoesNotPropose() {
        let (state, added) = CorrectionProposalState.empty.considering(
            inserted: "hello world", surviving: "hello world",
            existingSubstitutions: [], now: clock
        )
        XCTAssertNil(added)
        XCTAssertTrue(state.pending.isEmpty)
    }

    // MARK: - Dedup / suppression

    func testExistingSubstitutionIsNotReProposed() {
        let existing = [Vocabulary.Substitution(from: "kubernetis", to: "kubernetes")]
        let (state, added) = CorrectionProposalState.empty.considering(
            inserted: "run kubernetis now", surviving: "run kubernetes now",
            existingSubstitutions: existing, now: clock
        )
        XCTAssertNil(added)          // already a rule
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testSamePairIsNotQueuedTwice() {
        var (state, first) = CorrectionProposalState.empty.considering(
            inserted: "run kubernetis", surviving: "run kubernetes",
            existingSubstitutions: [], now: clock
        )
        XCTAssertNotNil(first)
        let (state2, second) = state.considering(
            inserted: "kubernetis again", surviving: "kubernetes again",
            existingSubstitutions: [], now: clock
        )
        XCTAssertNil(second)         // idempotent
        XCTAssertEqual(state2.pending.count, 1)
    }

    // MARK: - Accept

    func testAcceptingYieldsSubstitutionAndRemovesFromQueue() {
        let (state, added) = CorrectionProposalState.empty.considering(
            inserted: "run kubernetis", surviving: "run kubernetes",
            existingSubstitutions: [], now: clock
        )
        let (after, accepted) = state.accepting(added!.id)
        XCTAssertEqual(accepted?.from, "kubernetis")
        XCTAssertEqual(accepted?.to, "kubernetes")
        XCTAssertTrue(after.pending.isEmpty)          // dequeued
        XCTAssertFalse(after.declinedKeys.contains(added!.key))  // NOT declined
    }

    func testAcceptedSubstitutionFoldsIntoVocabulary() {
        // The full "accept adds to the dictionary" path the ticket asks for.
        var vocab = Vocabulary(terms: [], substitutions: [])
        let (state, added) = CorrectionProposalState.empty.considering(
            inserted: "run kubernetis", surviving: "run kubernetes",
            existingSubstitutions: vocab.substitutions, now: clock
        )
        let (_, accepted) = state.accepting(added!.id)
        vocab.substitutions.append(accepted!)
        XCTAssertEqual(vocab.substitutions.count, 1)
        // And it now actually rewrites future transcripts.
        let out = VocabularySubstitutor(substitutions: vocab.substitutions)
            .apply(to: "deploy kubernetis today")
        XCTAssertEqual(out, "deploy kubernetes today")
    }

    func testAcceptingUnknownIdIsNoOp() {
        let (state, _) = CorrectionProposalState.empty.considering(
            inserted: "run kubernetis", surviving: "run kubernetes",
            existingSubstitutions: [], now: clock
        )
        let (after, accepted) = state.accepting(UUID())
        XCTAssertNil(accepted)
        XCTAssertEqual(after, state)                 // unchanged
    }

    // MARK: - Reject

    func testRejectingRemovesAndSuppressesReProposal() {
        let (state, added) = CorrectionProposalState.empty.considering(
            inserted: "run kubernetis", surviving: "run kubernetes",
            existingSubstitutions: [], now: clock
        )
        let afterReject = state.rejecting(added!.id)
        XCTAssertTrue(afterReject.pending.isEmpty)                    // gone
        XCTAssertTrue(afterReject.declinedKeys.contains(added!.key))  // remembered

        // The identical correction must NOT be re-proposed after a reject.
        let (state2, again) = afterReject.considering(
            inserted: "run kubernetis", surviving: "run kubernetes",
            existingSubstitutions: [], now: clock
        )
        XCTAssertNil(again)
        XCTAssertTrue(state2.pending.isEmpty)
    }

    func testRejectDoesNotMutateAnyVocabulary() {
        // Rejecting a proposal touches only proposal state — the dictionary is the
        // caller's and is never changed by a reject.
        let vocab = Vocabulary(terms: [], substitutions: [])
        let (state, added) = CorrectionProposalState.empty.considering(
            inserted: "run kubernetis", surviving: "run kubernetes",
            existingSubstitutions: vocab.substitutions, now: clock
        )
        _ = state.rejecting(added!.id)
        XCTAssertTrue(vocab.substitutions.isEmpty)   // untouched
    }

    // MARK: - Cap / persistence

    func testPendingQueueIsCappedDroppingOldest() {
        var state = CorrectionProposalState.empty
        // Push more than the cap of distinct corrections.
        for i in 0..<(CorrectionProposalState.maxPending + 5) {
            let from = "kubernetis\(i)"
            let to = "kubernetes\(i)"
            state = state.considering(
                inserted: from, surviving: to, existingSubstitutions: [], now: clock
            ).state
        }
        XCTAssertEqual(state.pending.count, CorrectionProposalState.maxPending)
        // Oldest (index 0) dropped; the newest survives.
        XCTAssertEqual(state.pending.last?.from, "kubernetis\(CorrectionProposalState.maxPending + 4)")
    }

    func testCodableRoundTrip() throws {
        let (state, _) = CorrectionProposalState.empty.considering(
            inserted: "run kubernetis", surviving: "run kubernetes",
            existingSubstitutions: [], now: clock
        )
        let declined = state.rejecting(UUID())   // no-op but exercises encode of declinedKeys
        let data = try JSONEncoder().encode(declined)
        let decoded = try JSONDecoder().decode(CorrectionProposalState.self, from: data)
        XCTAssertEqual(decoded, declined)
    }

    func testClearingPendingKeepsDeclined() {
        let (s1, added) = CorrectionProposalState.empty.considering(
            inserted: "a kubernetis b", surviving: "a kubernetes b",
            existingSubstitutions: [], now: clock
        )
        let s2 = s1.rejecting(added!.id)                       // one declined
        let (s3, _) = s2.considering(
            inserted: "x helo y", surviving: "x hello y",
            existingSubstitutions: [], now: clock
        )
        let cleared = s3.clearingPending()
        XCTAssertTrue(cleared.pending.isEmpty)
        XCTAssertEqual(cleared.declinedKeys, s2.declinedKeys) // declines survive
    }
}
