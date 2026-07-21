import Foundation

/// The pure decision core of the self-learning dictionary's capture→decide→apply
/// loop (MAK-86 slice 1). Given a captured `(inserted, surviving)` edit and the
/// current learning state, it decides — with no AppKit, no AX, no I/O — whether to
/// do nothing, surface a proposal, or auto-add a rule to the vocabulary.
///
/// It composes the three pieces the AX plumbing must stay thin over:
///  1. `CorrectionLearner` — is this a learnable correction at all? (single-word
///     gate first, then the widened multi-word/phrase gate.)
///  2. `CorrectionConfidenceState` — how many times have we now seen this exact
///     correction? Once = candidate; `autoAddThreshold` times = auto-add.
///  3. `CorrectionProposalState` — de-dupe against pending / declined / existing
///     rules so we never nag or double-add.
///
/// The app-side `AXCorrectionWatcher` supplies the pair; `AppState` owns the two
/// states and this type turns an observation into an `Outcome`. Because the whole
/// decision is a pure function of its inputs, a test can drive the REAL
/// capture→decide→vocabulary path with a fabricated pair (no AX), which is exactly
/// the wiring the ticket asks to be regression-tested.
enum CorrectionLearningPipeline {

    /// What the caller should do with an observed edit.
    enum Outcome: Equatable {
        /// Not a learnable correction, or already handled (pending/declined/rule).
        case ignored
        /// A first-seen correction: enqueue `proposal` for the user to accept.
        case proposed(CorrectionProposal)
        /// A correction seen enough times to trust: add `substitution` to the
        /// vocabulary directly (no prompt). Any matching pending proposal for the
        /// same pair should be dropped by the caller (see `supersededProposalID`).
        case autoAdded(Vocabulary.Substitution, supersededProposalID: CorrectionProposal.ID?)
    }

    /// The full learning state threaded through a single observation.
    struct State: Equatable {
        public var proposals: CorrectionProposalState
        public var confidence: CorrectionConfidenceState

        public init(
            proposals: CorrectionProposalState = .empty,
            confidence: CorrectionConfidenceState = .empty
        ) {
            self.proposals = proposals
            self.confidence = confidence
        }
    }

    /// Decide the outcome of one observed edit.
    ///
    /// - Parameters:
    ///   - inserted: exactly what OpenWhisp inserted.
    ///   - surviving: what remained after the user edited.
    ///   - existingSubstitutions: the user's current vocabulary rules, so we never
    ///     re-propose / re-add one they already have.
    ///   - state: the current proposal + confidence state.
    ///   - now: injected clock for deterministic tests.
    /// - Returns: the next `State` and the `Outcome` for the caller to act on.
    static func decide(
        inserted: String,
        surviving: String,
        existingSubstitutions: [Vocabulary.Substitution],
        state: State,
        now: Date = Date()
    ) -> (state: State, outcome: Outcome) {
        // (1) Is this a learnable correction? Try the strict single-word gate
        // first; if it declines, try the widened phrase gate (which itself falls
        // back to the single-word gate for a 1↔1 edit, so there's no double count).
        guard let candidate = learnableCandidate(inserted: inserted, surviving: surviving) else {
            return (state, .ignored)
        }

        let key = CorrectionProposal.key(from: candidate.from, to: candidate.to)

        // Already a rule the user has → nothing to learn (don't even count it).
        let existingKeys = Set(existingSubstitutions.map { CorrectionProposal.key(from: $0.from, to: $0.to) })
        if existingKeys.contains(key) { return (state, .ignored) }

        // Previously declined → respect that; don't count toward auto-add either.
        if state.proposals.declinedKeys.contains(key) { return (state, .ignored) }

        // (2) Confidence: record this observation and see if it crosses the bar.
        let (nextConfidence, decision) = state.confidence.observing(candidate)
        var newState = state
        newState.confidence = nextConfidence

        switch decision {
        case .autoAdd:
            // Trusted: this pair has been corrected `autoAddThreshold` times. Add
            // the rule directly. Drop any pending proposal for the same pair (the
            // first observation queued one) so the UI doesn't still ask.
            let superseded = newState.proposals.pending.first { $0.key == key }?.id
            if let superseded {
                newState.proposals = newState.proposals.clearingPending(id: superseded)
            }
            return (newState, .autoAdded(candidate, supersededProposalID: superseded))

        case .candidate:
            // First-seen: surface a proposal (unless already pending — idempotent).
            let (nextProposals, added) = newState.proposals.considering(
                candidate: candidate,
                now: now
            )
            newState.proposals = nextProposals
            if let added {
                return (newState, .proposed(added))
            }
            return (newState, .ignored)
        }
    }

    /// Reject the pending proposal `id`: forget its confidence tally (so a declined
    /// correction can never later cross the auto-add threshold) AND mark it declined.
    /// Returns the new state. Pure — keeps the two-store bookkeeping in core.
    static func rejecting(_ id: CorrectionProposal.ID, state: State) -> State {
        var copy = state
        if let p = state.proposals.pending.first(where: { $0.id == id }) {
            copy.confidence = copy.confidence.forgetting(from: p.from, to: p.to)
        }
        copy.proposals = copy.proposals.rejecting(id)
        return copy
    }

    /// Apply an `Outcome` to a vocabulary, returning the (possibly unchanged) new
    /// vocabulary. Only `.autoAdded` mutates it, and only when the rule isn't
    /// already present (case-insensitively). Keeps the vocabulary side-effect in
    /// core so the AppState callback stays a thin dispatch. Pure/value-semantic.
    static func applying(_ outcome: Outcome, to vocabulary: Vocabulary, now: Date = Date()) -> Vocabulary {
        guard case let .autoAdded(sub, _) = outcome else { return vocabulary }
        return vocabulary.addingSubstitutionIfAbsent(sub, now: now)
    }

    /// Run the correction gates: strict single-word first, then the widened
    /// phrase gate for multi-word / split-run / compound corrections.
    static func learnableCandidate(inserted: String, surviving: String) -> Vocabulary.Substitution? {
        if let single = CorrectionLearner.proposeSubstitution(inserted: inserted, surviving: surviving) {
            return single
        }
        return CorrectionLearner.proposePhraseSubstitution(inserted: inserted, surviving: surviving)
    }
}
