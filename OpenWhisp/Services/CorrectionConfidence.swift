import Foundation

/// Repeated-correction confidence weighting for the self-learning dictionary
/// (MAK-86 slice 1).
///
/// The capture path (`AXCorrectionWatcher` → `CorrectionLearner`) turns a
/// post-insert edit into a candidate `(from → to)` substitution. Historically a
/// single candidate was queued as a PROPOSAL the user had to accept. That's the
/// right bar for a correction seen ONCE — it could be a one-off typo or an
/// accidental edit. But a correction the user makes the SAME way repeatedly is a
/// strong, self-consistent signal: the user keeps fixing the same misrecognition,
/// so it earns auto-promotion into the vocabulary without a per-instance prompt.
///
/// This pure type counts observations of each `from→to` pair (keyed
/// case-insensitively, the same way `CorrectionProposal.key` de-dupes) and
/// decides, per observation, whether the pair is still a *candidate* (surface a
/// proposal) or has crossed the confidence threshold and should be *auto-added*.
///
/// ## Threshold
///
/// `autoAddThreshold = 2`: the SECOND identical observation auto-adds. The first
/// observation is a candidate (proposal); on the second, we've seen the user make
/// the exact same correction twice, which is strong enough to skip the prompt.
/// Two (not three) keeps the flywheel responsive — the whole point of the loop is
/// to widen accuracy with minimal friction — while still requiring corroboration,
/// so a single stray edit never silently rewrites future transcripts. Documented
/// here as the single source of truth; change it here and the tests follow.
///
/// ## Persistence / contract
///
/// Persisted as its OWN JSON file (`correction-confidence.json`), NOT folded into
/// `vocabulary.json` — the vocabulary format is an iOS-shared, additive-only
/// contract, and observation counts are a local learning detail the companion
/// never needs. Foundation-only → lives in OpenWhispCore and is fully unit-tested.
struct CorrectionConfidenceState: Codable, Equatable {

    /// Observation counts per case-insensitive `from→to` key. A key is removed
    /// once it auto-adds (it's now a real rule; keeping a stale counter would only
    /// grow the file).
    private(set) var counts: [String: Int]

    /// How many identical observations promote a candidate to an auto-add. See the
    /// type doc for the rationale; N=2 (the second observation auto-adds).
    static let autoAddThreshold = 2

    init(counts: [String: Int] = [:]) {
        self.counts = counts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
    }

    static let empty = CorrectionConfidenceState()

    /// The decision for a single observation of a candidate substitution.
    enum Decision: Equatable {
        /// Not yet corroborated — surface a proposal for the user to accept.
        case candidate
        /// Threshold reached — fold the substitution straight into the vocabulary.
        case autoAdd
    }

    /// Record one observation of `candidate` and decide what to do with it.
    ///
    /// Increments the pair's observation count; when it reaches
    /// `autoAddThreshold` the pair is cleared from the counter and the decision is
    /// `.autoAdd`, otherwise `.candidate`. Pure/value-semantic: returns the new
    /// state alongside the decision so the caller (AppState) persists it and acts.
    ///
    /// - Parameter candidate: the `from→to` the learner already validated.
    func observing(
        _ candidate: Vocabulary.Substitution
    ) -> (state: CorrectionConfidenceState, decision: Decision) {
        let key = CorrectionProposal.key(from: candidate.from, to: candidate.to)
        var copy = self
        let next = (copy.counts[key] ?? 0) + 1
        if next >= Self.autoAddThreshold {
            copy.counts[key] = nil          // promoted → stop tracking
            return (copy, .autoAdd)
        }
        copy.counts[key] = next
        return (copy, .candidate)
    }

    /// Forget an in-flight candidate's tally (e.g. the user DECLINED the proposal,
    /// so repeated observations should not silently auto-add it later). No-op if
    /// the key isn't tracked.
    func forgetting(from: String, to: String) -> CorrectionConfidenceState {
        let key = CorrectionProposal.key(from: from, to: to)
        guard counts[key] != nil else { return self }
        var copy = self
        copy.counts[key] = nil
        return copy
    }
}

/// Loads/saves the correction-confidence counters as JSON in Application Support —
/// the same local-only pattern as history/vocabulary/proposals. Never synced.
enum CorrectionConfidenceStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("correction-confidence.json")
    }

    static func load() -> CorrectionConfidenceState {
        JSONStore.load(from: fileURL, default: .empty, label: "CorrectionConfidenceStore")
    }

    static func save(_ state: CorrectionConfidenceState) {
        JSONStore.save(state, to: fileURL, label: "CorrectionConfidenceStore")
    }
}
