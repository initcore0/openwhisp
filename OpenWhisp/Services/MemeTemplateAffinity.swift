import Foundation

/// What the user's own picks teach the ranker (spike v6).
///
/// ## The signal, and why it is worth having
///
/// Every time the user clicks past the model's first candidate — a different thumbnail
/// in the strip, or something else entirely from Browse — they have made a correction.
/// It is the cheapest supervision in the whole plugin: unambiguous, free, and produced
/// by the action the user was going to take anyway. v5 discarded all of it, so a user
/// who reached for the same template on every third meme got no better ranking on the
/// hundredth.
///
/// So each such pick BOOSTS that template's prefilter score a little. The effect is
/// deliberately small and strictly bounded, because the failure mode of a learning
/// signal is worse than the failure mode of not having one: a boost that can outrun the
/// lexical score would eventually put the user's favourite template at the top of every
/// shortlist regardless of what they said, which is a personalized version of exactly
/// the confident-Drake bug this spike exists to kill.
///
/// ## The bounds, and why each one
///
/// * **`boostPerPick` (12)** is smaller than one keyword-token match (60) and far
///   smaller than a name-token match (100). One correction can therefore reorder
///   templates that scored *nearly the same*, and can never promote an unrelated
///   template over a relevant one.
/// * **`maximumBoost` (120)** caps the total at roughly two name-token matches, reached
///   after ten picks. Past that, picking the same template again changes nothing — the
///   signal saturates instead of compounding, which is what stops a long-lived store
///   from slowly taking over the ranking.
/// * **Only templates that ALREADY MATCH are boosted.** The boost is added inside
///   `MemeTemplateCatalog.ranked`, to templates whose lexical score is already above
///   zero — never to a zero-scoring one. This is the load-bearing rule: it means the
///   "no template matches" answer stays reachable, search never invents a hit, and a
///   favourite template cannot appear for a query that has nothing to do with it.
///
/// Foundation-only and pure, so every one of those bounds is pinned by `swift test`
/// rather than asserted in a comment. The app layer owns only the JSON file.
public struct MemeTemplateAffinity: Equatable, Sendable, Codable {

    /// Accumulated boost per template id. Ids are source-qualified
    /// (`MemeTemplateCatalog.qualifiedID`) so the same-named template from two
    /// providers doesn't share a score.
    public private(set) var boosts: [String: Int]

    public init(boosts: [String: Int] = [:]) {
        self.boosts = boosts.compactMapValues { value in
            let clamped = min(max(value, 0), Self.maximumBoost)
            // A zero carries no information and would grow the file forever.
            return clamped > 0 ? clamped : nil
        }
    }

    /// What one correction is worth.
    public static let boostPerPick = 12

    /// The ceiling on any single template's accumulated boost.
    public static let maximumBoost = 120

    /// How many picks it takes to saturate — derived, not a second constant that could
    /// drift out of step with the two above.
    public static var picksToSaturate: Int {
        Int((Double(maximumBoost) / Double(boostPerPick)).rounded(.up))
    }

    /// The boost for one template. Zero for anything never picked.
    public func boost(for templateID: String) -> Int {
        boosts[templateID] ?? 0
    }

    /// Record that the user chose this template over the one that was offered first.
    ///
    /// Saturating rather than wrapping or growing: at the ceiling this is a no-op, so
    /// a user who picks the same template a thousand times ends up exactly where they
    /// were after ten.
    public mutating func record(pick templateID: String) {
        guard !templateID.isEmpty else { return }
        boosts[templateID] = min(boost(for: templateID) + Self.boostPerPick, Self.maximumBoost)
    }

    /// The same, as a value — for the pure call sites and the tests.
    public func recording(pick templateID: String) -> MemeTemplateAffinity {
        var copy = self
        copy.record(pick: templateID)
        return copy
    }

    /// Forget everything learned. Wired to nothing yet; it exists so the store has an
    /// honest way back, and so "the boosts got weird" is a recoverable state rather
    /// than a reason to hand-edit JSON.
    public mutating func reset() { boosts = [:] }

    /// Decoding re-applies the clamp, so a hand-edited or corrupt file can't inject a
    /// boost large enough to dominate the ranking. The store is user-writable by
    /// design (it's a spike, and the file is meant to be inspectable), which makes this
    /// the boundary where the cap has to be enforced rather than assumed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode([String: Int].self)) ?? [:]
        self.init(boosts: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(boosts)
    }

    /// The filename under the plugin's own directory.
    public static let fileName = "template-affinity.json"
}
