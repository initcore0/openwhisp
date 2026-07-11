import Foundation

/// Catalog of the Parakeet streaming-model variants OpenWhisp exposes (MAK-46
/// spike). Foundation-only so it lives in OpenWhispCore and is unit-tested; the
/// `id` strings are FluidAudio's `StreamingModelVariant` raw values, matched by
/// the engine at start time (a mismatch falls back to the default variant, so a
/// stale stored id can't crash a session).
///
/// Only English variants for now: FluidAudio's true-streaming multilingual model
/// (Nemotron streaming multilingual) uses a separate manager type and is a
/// deliberate follow-up — see docs/PARAKEET_SPIKE.md.
enum ParakeetCatalog {
    struct Variant: Equatable {
        /// FluidAudio `StreamingModelVariant` raw value.
        let id: String
        let name: String
        let detail: String
        /// Approximate on-disk size of the CoreML model repo.
        let size: String
    }

    /// Variants offered in Settings, best-default first. All stream partials as
    /// you speak; latency = how far the recognizer trails your voice.
    static let variants: [Variant] = [
        Variant(
            id: "parakeet-unified-320ms",
            name: "Parakeet Unified — realtime",
            detail: "0.32 s latency with punctuation and capitalization. English only.",
            size: "~600 MB"
        ),
        Variant(
            id: "parakeet-unified-1120ms",
            name: "Parakeet Unified — accurate",
            detail: "1.1 s latency, best streaming accuracy. English only.",
            size: "~600 MB"
        ),
        Variant(
            id: "parakeet-eou-320ms",
            name: "Parakeet EOU — ultra light",
            detail: "120M model, lowest footprint. No punctuation — relies on AI cleanup. English only.",
            size: "~150 MB"
        ),
    ]

    static let defaultVariantID = "parakeet-unified-320ms"

    /// Resolve a stored variant setting to a known catalog id. Unknown/stale ids
    /// (e.g. a variant removed after a FluidAudio bump) snap to the default
    /// rather than erroring a session.
    static func normalize(_ storedID: String) -> String {
        variants.contains { $0.id == storedID } ? storedID : defaultVariantID
    }

    static func variant(for id: String) -> Variant {
        let normalized = normalize(id)
        return variants.first { $0.id == normalized } ?? variants[0]
    }
}
