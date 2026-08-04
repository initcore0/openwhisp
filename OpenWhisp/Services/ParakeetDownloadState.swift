import Foundation

/// Coarse per-variant download state for the Parakeet variant picker (MAK-46
/// Phase 4) — installed / downloading… / not downloaded — derived from (a)
/// whether the variant's model files are complete on disk and (b) whether a
/// prefetch is in flight. (Real download percentages live on the readiness
/// path — `EngineReadiness.downloading(progress:)` — not on these badges.)
///
/// Pure + Foundation-only so the mapping (variant → repo folder → state) is
/// unit-tested; the disk walk + in-flight tracking stay app-side.
public enum ParakeetDownloadState: Equatable {
    /// The variant's model files aren't (fully) on disk yet.
    case notDownloaded
    /// A prefetch/load is running.
    case downloading
    /// The variant's model files are complete on disk.
    case installed

    /// Short suffix for the variant row subtitle. `installed` returns nil (no
    /// badge needed — the row is unadorned when the model is present).
    public var badge: String? {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .downloading:   return "Downloading…"
        case .installed:     return nil
        }
    }
}

/// Maps ParakeetCatalog variant ids to the FluidAudio Models repo folder that
/// must be present for that variant, and resolves the coarse state.
public enum ParakeetDownloadStatePolicy {
    /// The repo folder name (immediate child of FluidAudio/Models) a variant
    /// stages into. Matches FluidAudio's on-disk layout (see the model dirs).
    ///
    /// The English Unified tiers share ONE repo (`parakeet-unified-en-0.6b`); the
    /// EOU and multilingual variants each have their own. A future/unknown id
    /// returns nil (treated as not-mappable → notDownloaded).
    public static func repoFolder(forVariant id: String) -> String? {
        switch ParakeetCatalog.normalize(id) {
        case "parakeet-unified-320ms", "parakeet-unified-640ms", "parakeet-unified-1120ms":
            return "parakeet-unified-en-0.6b"
        case "parakeet-eou-320ms":
            return "parakeet-eou-streaming"
        case "nemotron-multilingual-1120ms":
            return "nemotron-multilingual"
        default:
            return nil
        }
    }

    /// Resolve the state for a variant given the set of installed repo folders
    /// and the set of variant ids with a prefetch in flight.
    ///
    /// Downloading wins over installed only when the folder is NOT yet present —
    /// once the folder exists we report installed even if a warm/load is still
    /// running (the bytes are down; loading is a separate concern).
    public static func state(
        forVariant id: String,
        installedFolders: Set<String>,
        inFlightVariants: Set<String>
    ) -> ParakeetDownloadState {
        if let folder = repoFolder(forVariant: id), installedFolders.contains(folder) {
            return .installed
        }
        if inFlightVariants.contains(ParakeetCatalog.normalize(id)) {
            return .downloading
        }
        return .notDownloaded
    }

    /// Verdict-based state: `installed` means the variant's files VERIFIED
    /// complete, not merely that the repo folder exists. This is the resolver
    /// the UI should prefer — the folder-presence overload above predates
    /// `ParakeetModelIntegrity` and can call a torn first-run download
    /// "installed" (the fresh-install onboarding bug).
    public static func state(
        forVariant id: String,
        verdict: ParakeetModelIntegrity.Verdict,
        inFlightVariants: Set<String>
    ) -> ParakeetDownloadState {
        if verdict == .complete { return .installed }
        if inFlightVariants.contains(ParakeetCatalog.normalize(id)) {
            return .downloading
        }
        return .notDownloaded
    }
}
