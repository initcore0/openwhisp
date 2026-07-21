import Foundation

/// A learned-correction the app is *offering* the user — MAK-41's accept/reject
/// surface. It is NEVER applied silently: a wrong auto-learned rule would rewrite
/// every future transcript, so a candidate from `CorrectionLearner` only becomes a
/// real `Vocabulary.Substitution` when the user accepts it here.
///
/// Pure and Foundation-only so it lives in `OpenWhispCore` and the whole
/// propose → accept/reject state machine is unit-tested without any AX or SwiftUI.
struct CorrectionProposal: Codable, Identifiable, Equatable {
    let id: UUID
    /// The misrecognition to catch next time (what we inserted).
    let from: String
    /// The user's correction (what survived their edit).
    let to: String
    /// When the correction was observed.
    let date: Date

    init(id: UUID = UUID(), from: String, to: String, date: Date = Date()) {
        self.id = id
        self.from = from
        self.to = to
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
    }

    /// The substitution this proposal becomes when accepted. Starred false, usage
    /// zero — a fresh rule the user just approved.
    var substitution: Vocabulary.Substitution {
        Vocabulary.Substitution(from: from, to: to)
    }

    /// Case-insensitive identity of a from→to pair, so "Clod→Claude" and
    /// "clod→claude" don't stack up as separate proposals and a decline of one
    /// suppresses the other. Trims surrounding whitespace.
    static func key(from: String, to: String) -> String {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(f)\u{1F}\(t)"
    }

    var key: String { Self.key(from: from, to: to) }
}

/// The user-facing state of the self-learning dictionary: the queue of pending
/// correction proposals plus the set of pairs the user already *declined* (so we
/// never nag them with the same rejected fix again).
///
/// Every transition is a pure value-semantic function — this is the tested state
/// machine the ticket asks for. `AppState` owns one instance, feeds it observed
/// `(inserted, surviving)` pairs, and renders `pending` in the editor; accept/
/// reject flow through here and, on accept, the caller folds the returned
/// substitution into the real `Vocabulary`.
struct CorrectionProposalState: Codable, Equatable {
    /// Proposals awaiting the user's accept/reject, oldest first.
    private(set) var pending: [CorrectionProposal]
    /// Case-insensitive from→to keys the user has declined; a matching candidate is
    /// silently dropped instead of re-proposed.
    private(set) var declinedKeys: Set<String>

    /// Hard cap on the pending queue so a noisy capture path can't grow it without
    /// bound. When full, the OLDEST pending proposal is dropped to make room for a
    /// newer one (recent corrections are the more relevant to offer).
    static let maxPending = 20

    init(pending: [CorrectionProposal] = [], declinedKeys: Set<String> = []) {
        self.pending = pending
        self.declinedKeys = declinedKeys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pending = try c.decodeIfPresent([CorrectionProposal].self, forKey: .pending) ?? []
        declinedKeys = try c.decodeIfPresent(Set<String>.self, forKey: .declinedKeys) ?? []
    }

    static let empty = CorrectionProposalState()

    // MARK: - Transitions (pure)

    /// Consider an observed insert→edit pair. Runs `CorrectionLearner` to decide if
    /// it's a clean single-word correction; if so — and it isn't already pending,
    /// already a rule (`existingSubstitutions`), or previously declined — enqueue a
    /// proposal. Returns the new state and, when a proposal was actually added, it
    /// (so the caller can surface a prompt). Idempotent for a pair already queued.
    ///
    /// - Parameters:
    ///   - inserted: the exact text OpenWhisp inserted.
    ///   - surviving: the text left in the field after the user finished editing.
    ///   - existingSubstitutions: the user's current rules, so we never propose a
    ///     fix they already have (case-insensitively).
    ///   - now: injected clock for deterministic tests.
    func considering(
        inserted: String,
        surviving: String,
        existingSubstitutions: [Vocabulary.Substitution],
        now: Date = Date()
    ) -> (state: CorrectionProposalState, added: CorrectionProposal?) {
        guard let candidate = CorrectionLearner.proposeSubstitution(inserted: inserted, surviving: surviving) else {
            return (self, nil)
        }
        let key = CorrectionProposal.key(from: candidate.from, to: candidate.to)

        // Already declined → respect that, never re-nag.
        if declinedKeys.contains(key) { return (self, nil) }
        // Already queued (same pair) → idempotent, don't duplicate.
        if pending.contains(where: { $0.key == key }) { return (self, nil) }
        // Already a rule the user has → nothing to learn.
        let existingKeys = Set(existingSubstitutions.map { CorrectionProposal.key(from: $0.from, to: $0.to) })
        if existingKeys.contains(key) { return (self, nil) }

        let proposal = CorrectionProposal(from: candidate.from, to: candidate.to, date: now)
        var copy = self
        copy.pending.append(proposal)
        // Trim from the front (oldest) if we exceeded the cap.
        if copy.pending.count > Self.maxPending {
            copy.pending.removeFirst(copy.pending.count - Self.maxPending)
        }
        return (copy, proposal)
    }

    /// Accept a pending proposal by id: remove it from the queue and return the
    /// `Substitution` the caller should add to the real `Vocabulary`. Returns nil
    /// (state unchanged) if the id isn't pending. Accepting does NOT add the pair to
    /// `declinedKeys` — the user wanted it.
    func accepting(_ id: CorrectionProposal.ID) -> (state: CorrectionProposalState, accepted: Vocabulary.Substitution?) {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return (self, nil) }
        var copy = self
        let proposal = copy.pending.remove(at: idx)
        return (copy, proposal.substitution)
    }

    /// Reject a pending proposal by id: remove it and remember the pair as declined
    /// so the identical correction is never proposed again. No-op if not pending.
    func rejecting(_ id: CorrectionProposal.ID) -> CorrectionProposalState {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        let proposal = copy.pending.remove(at: idx)
        copy.declinedKeys.insert(proposal.key)
        return copy
    }

    /// Enqueue a proposal for an ALREADY-VALIDATED candidate substitution (the
    /// caller — `CorrectionLearningPipeline` — has already run the learner). Same
    /// de-dup rules as `considering(inserted:surviving:…)`: skip if declined,
    /// already pending, or already a rule is the caller's job (it checks existing
    /// rules before calling). Returns the new state and, when added, the proposal.
    func considering(
        candidate: Vocabulary.Substitution,
        now: Date = Date()
    ) -> (state: CorrectionProposalState, added: CorrectionProposal?) {
        let key = CorrectionProposal.key(from: candidate.from, to: candidate.to)
        if declinedKeys.contains(key) { return (self, nil) }
        if pending.contains(where: { $0.key == key }) { return (self, nil) }

        let proposal = CorrectionProposal(from: candidate.from, to: candidate.to, date: now)
        var copy = self
        copy.pending.append(proposal)
        if copy.pending.count > Self.maxPending {
            copy.pending.removeFirst(copy.pending.count - Self.maxPending)
        }
        return (copy, proposal)
    }

    /// Remove one pending proposal by id WITHOUT marking it declined — used when a
    /// repeated correction auto-adds the rule, so the now-redundant prompt is
    /// simply dropped (the user got the fix they were making). No-op if not pending.
    func clearingPending(id: CorrectionProposal.ID) -> CorrectionProposalState {
        guard pending.contains(where: { $0.id == id }) else { return self }
        var copy = self
        copy.pending.removeAll { $0.id == id }
        return copy
    }

    /// Clear the whole pending queue (e.g. a "dismiss all" affordance). Does NOT
    /// mark them declined — they're just cleared, and could be re-proposed later.
    func clearingPending() -> CorrectionProposalState {
        var copy = self
        copy.pending.removeAll()
        return copy
    }
}

/// Loads/saves the correction-proposal state as JSON in Application Support —
/// same local-only pattern as history/vocabulary. Nothing here leaves the machine.
enum CorrectionProposalStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("correction-proposals.json")
    }

    static func load() -> CorrectionProposalState {
        JSONStore.load(from: fileURL, default: .empty, label: "CorrectionProposalStore")
    }

    static func save(_ state: CorrectionProposalState) {
        JSONStore.save(state, to: fileURL, label: "CorrectionProposalStore")
    }
}
