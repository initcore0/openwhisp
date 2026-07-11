import Foundation

/// Catalog of the Parakeet streaming-model variants OpenWhisp exposes (MAK-46).
/// Foundation-only so it lives in OpenWhispCore and is unit-tested; the `id`
/// strings are FluidAudio's `StreamingModelVariant` raw values (for the English
/// families) matched by the engine at start time (a mismatch falls back to the
/// default variant, so a stale stored id can't crash a session).
///
/// Two model families are represented:
///   - English streaming (Unified / EOU) — FluidAudio `StreamingModelVariant`s,
///     `multilingual == false`. Punctuation + 0.32 s latency (Unified).
///   - Nemotron multilingual streaming — a SEPARATE FluidAudio manager type
///     (`StreamingNemotronMultilingualAsrManager`), `multilingual == true` with a
///     `multilingualChunkMs` tier. ~40 languages (auto-detect), higher latency.
enum ParakeetCatalog {
    struct Variant: Equatable {
        /// FluidAudio `StreamingModelVariant` raw value (English families), or an
        /// OpenWhisp-local id for the multilingual variant (not a FluidAudio enum).
        let id: String
        let name: String
        let detail: String
        /// Approximate on-disk size of the CoreML model repo.
        let size: String
        /// True for the Nemotron multilingual manager (auto-detect ~40 langs).
        /// Drives the variant-aware language gate + the bridge's manager choice.
        let multilingual: Bool
        /// Chunk-size tier (ms) for the multilingual manager; nil for English
        /// variants. FluidAudio ships 560 / 1120 / 2240 ms tiers.
        let multilingualChunkMs: Int?
        /// True when the variant's manager emits end-of-utterance timestamps
        /// (only the EOU family). Gates the engine's per-buffer EOU poll AND the
        /// agent EOU auto-stop arming — the single source of truth.
        let emitsEou: Bool

        init(
            id: String, name: String, detail: String, size: String,
            multilingual: Bool = false, multilingualChunkMs: Int? = nil,
            emitsEou: Bool = false
        ) {
            self.id = id
            self.name = name
            self.detail = detail
            self.size = size
            self.multilingual = multilingual
            self.multilingualChunkMs = multilingualChunkMs
            self.emitsEou = emitsEou
        }
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
            id: "parakeet-unified-640ms",
            name: "Parakeet Unified — efficient",
            detail: "0.64 s latency with punctuation — same accuracy as realtime at a fraction of the CPU. English only.",
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
            size: "~150 MB",
            emitsEou: true
        ),
        Variant(
            id: "nemotron-multilingual-1120ms",
            name: "Parakeet Multilingual",
            detail: "~40 languages (auto-detect), with punctuation. 1.1 s latency — slower than the English tiers.",
            size: "~600 MB",
            multilingual: true,
            multilingualChunkMs: 1120
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

    /// Whether the given variant id is a multilingual (Nemotron) variant.
    static func isMultilingual(_ id: String) -> Bool {
        variant(for: id).multilingual
    }

    /// Whether the given variant id's manager emits end-of-utterance events.
    static func emitsEou(_ id: String) -> Bool {
        variant(for: id).emitsEou
    }
}
