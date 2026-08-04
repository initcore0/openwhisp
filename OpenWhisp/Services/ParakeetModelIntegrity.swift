import Foundation

/// Completeness verification for the Parakeet (FluidAudio) model cache.
///
/// Why this exists (fresh-install onboarding bug): FluidAudio's download gate is
/// a single-file presence check — if the variant's encoder bundle EXISTS on disk
/// (even truncated by a killed or dropped first-run download), the download is
/// skipped forever and `MLModel.load` fails on every launch with a raw `file://`
/// error. Nothing app-side could tell "installed" from "present but broken": the
/// folder-exists heuristic said installed, onboarding said "ready", and the menu
/// bar said "Model unavailable" — all at once. A variant counts as installed
/// only when every file it needs is actually there.
///
/// Pure + Foundation-only (OpenWhispCore): callers hand in the repo folder's
/// recursive file listing; the disk walk stays app-side
/// (`FluidAudioModelsLocator.fileListing`).
public enum ParakeetModelIntegrity {

    /// Completeness verdict for one variant's on-disk model cache.
    public enum Verdict: Equatable {
        /// Every required file is present — the variant counts as installed.
        case complete
        /// The repo folder exists but required files are missing — a torn
        /// download, or only a different tier's files. `missing` lists the
        /// absent relative paths (for logs/tests, not user copy).
        case incomplete(missing: [String])
        /// The repo folder isn't on disk at all.
        case notDownloaded
    }

    /// Required paths (relative to the variant's repo folder) for the manifest-
    /// verified variants. Compiled CoreML bundles (`.mlmodelc`) are directories;
    /// requiring their root `coremldata.bin` is what catches a torn bundle —
    /// the bare directory alone satisfies FluidAudio's own presence gate.
    ///
    /// Names mirror FluidAudio 0.15.5's `ModelNames` (the dependency is pinned
    /// `exact:`, so drift is a deliberate bump, not a surprise). The Unified
    /// tiers share one repo; each latency tier bakes its attention context into
    /// a distinct int8 encoder bundle (the app's default precision) alongside
    /// tier-independent decoder/joint/vocab files. The multilingual variant's
    /// layout is language-dependent, so it returns nil and is checked by the
    /// generic bundle rule instead.
    public static func requiredPaths(forVariant id: String) -> [String]? {
        switch ParakeetCatalog.normalize(id) {
        case "parakeet-unified-320ms":  return unifiedPaths(contextSuffix: "70_2_2")
        case "parakeet-unified-640ms":  return unifiedPaths(contextSuffix: "70_7_1")
        case "parakeet-unified-1120ms": return unifiedPaths(contextSuffix: "70_7_7")
        case "parakeet-eou-320ms":
            // FluidAudio nests the EOU chunk tier one level under the repo folder.
            return [
                "320ms/streaming_encoder.mlmodelc/coremldata.bin",
                "320ms/decoder.mlmodelc/coremldata.bin",
                "320ms/joint_decision.mlmodelc/coremldata.bin",
                "320ms/vocab.json",
            ]
        default:
            return nil
        }
    }

    private static func unifiedPaths(contextSuffix: String) -> [String] {
        [
            "parakeet_unified_encoder_streaming_\(contextSuffix)_int8.mlmodelc/coremldata.bin",
            "parakeet_unified_decoder.mlmodelc/coremldata.bin",
            "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin",
            "vocab.json",
        ]
    }

    // MARK: - Non-variant repos (batch TDT v3 + CTC biasing)

    /// Repo folder of the batch (TDT v3) model — `ParakeetFileEngine`'s backend
    /// for every non-live path (files, meetings, history re-transcribe). Not a
    /// ParakeetCatalog variant, so it gets its own manifest here. Mirrors
    /// FluidAudio's `Repo.parakeetV3.folderName`.
    public static let batchRepoFolder = "parakeet-tdt-0.6b-v3"

    /// Required paths for the batch model at the app's default int8 encoder
    /// precision — FluidAudio's `ModelNames.ASR.requiredModelsV3(.int8)` plus
    /// the vocabulary JSON its `AsrModels.load` also needs.
    public static let batchRequiredPaths: [String] = [
        "Preprocessor.mlmodelc/coremldata.bin",
        "Encoder.mlmodelc/coremldata.bin",
        "Decoder.mlmodelc/coremldata.bin",
        "JointDecisionv3.mlmodelc/coremldata.bin",
        "parakeet_vocab.json",
    ]

    /// Repo folder of the CTC-WS vocabulary-biasing model (MAK-71). Unlike the
    /// other repos FluidAudio keeps the `-coreml` suffix in this folder name.
    public static let ctcBiasRepoFolder = "parakeet-ctc-110m-coreml"

    /// Required paths for the CTC biasing model: the two CoreML bundles plus
    /// BOTH root JSONs — `vocab.json` (`CtcModels.load`) and `tokenizer.json`
    /// (`CtcTokenizer.load`). FluidAudio's own presence gate never checks the
    /// tokenizer, so a cache missing only that file loads the models fine and
    /// then fails tokenization — same torn-cache family, different file.
    public static let ctcBiasRequiredPaths: [String] = [
        "MelSpectrogram.mlmodelc/coremldata.bin",
        "AudioEncoder.mlmodelc/coremldata.bin",
        "vocab.json",
        "tokenizer.json",
    ]

    /// Verify a variant against its repo folder's recursive file listing
    /// (relative paths; nil = the folder doesn't exist).
    ///
    /// Manifest variants check their exact required paths — which also treats a
    /// repo holding only a DIFFERENT tier's encoder as not-installed (correct:
    /// FluidAudio still has this tier's download ahead of it). Variants without
    /// a manifest fall back to the generic rule.
    public static func verdict(forVariant id: String, listing: Set<String>?) -> Verdict {
        guard let listing else { return .notDownloaded }
        if let required = requiredPaths(forVariant: id) {
            return verdict(requiredPaths: required, listing: listing)
        }
        return genericVerdict(listing: listing)
    }

    /// Verify an explicit manifest (the batch/CTC repos, which aren't catalog
    /// variants) against a repo folder's recursive file listing.
    public static func verdict(requiredPaths: [String], listing: Set<String>?) -> Verdict {
        guard let listing else { return .notDownloaded }
        let missing = requiredPaths.filter { !listing.contains($0) }
        return missing.isEmpty ? .complete : .incomplete(missing: missing.sorted())
    }

    /// Generic rule for manifest-less variants: the folder must hold at least
    /// one model bundle, and every compiled `.mlmodelc` bundle must contain its
    /// root `coremldata.bin`. (`.mlpackage` is FluidAudio's accepted uncompiled
    /// fallback layout and has no single sentinel file to check.)
    private static func genericVerdict(listing: Set<String>) -> Verdict {
        var mlmodelcBundles = Set<String>()
        var hasUncompiledBundle = false
        for path in listing {
            let components = path.split(separator: "/")
            for (index, component) in components.enumerated() {
                if component.hasSuffix(".mlmodelc") {
                    mlmodelcBundles.insert(components[0...index].joined(separator: "/"))
                } else if component.hasSuffix(".mlpackage") {
                    hasUncompiledBundle = true
                }
            }
        }
        guard hasUncompiledBundle || !mlmodelcBundles.isEmpty else {
            return .incomplete(missing: ["<any model bundle>"])
        }
        let missing = mlmodelcBundles
            .map { "\($0)/coremldata.bin" }
            .filter { !listing.contains($0) }
            .sorted()
        return missing.isEmpty ? .complete : .incomplete(missing: missing)
    }
}

/// User-facing copy for Parakeet model failures. One place so the menu row,
/// onboarding failure card, and Settings agree — and so the raw CoreML
/// `Unable to load model: file://…` string never reaches the UI again.
public enum ParakeetFailureCopy {
    /// The fetch itself failed (offline first run, HuggingFace hiccup).
    public static let downloadFailed = "download failed — check your connection"
    /// The bytes are down but the model can't load, and the automatic
    /// purge-and-redownload repair didn't fix it.
    public static let loadFailed =
        "the model couldn't be loaded — use Redownload Model in Settings → Models"
}
