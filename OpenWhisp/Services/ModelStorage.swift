import Foundation

/// Pure model-storage accounting for the Settings "Storage" view: given the set of
/// installed models (each already measured on disk by the caller), it sorts them,
/// sums the total, and formats byte counts. Foundation-only so it lives in
/// OpenWhispCore and is unit-tested; the actual disk walk (which model dirs exist,
/// how big each is) stays app-side in AppState.
enum ModelStorage {

    /// Which subsystem a model belongs to — drives the section label + icon and the
    /// "is this the active one" check.
    enum Kind: String, Equatable, Codable {
        case whisperKit      // CoreML .mlmodelc folder
        case whisperCpp      // whisper.cpp GGML .bin
        case bundledLLM      // built-in llama.cpp GGUF
        case parakeet        // FluidAudio CoreML repo folder (streaming + batch)

        var displayName: String {
            switch self {
            case .whisperKit: return "WhisperKit (CoreML)"
            case .whisperCpp: return "Whisper Local (whisper.cpp)"
            case .bundledLLM: return "Built-in LLM"
            case .parakeet: return "Parakeet (CoreML)"
            }
        }
    }

    /// One installed model as shown in the Storage list.
    struct Item: Equatable, Identifiable {
        /// Stable identity for the row + the delete target — the on-disk path.
        var id: String { path }
        let kind: Kind
        /// Human label (e.g. "Small (multilingual)" or the file name).
        let label: String
        /// Absolute path to the model file or folder (the delete target).
        let path: String
        /// Total bytes on disk.
        let bytes: Int64
        /// True if this is the model the app is currently configured to use — the UI
        /// warns/guards before removing it (it would force a re-download).
        let isActive: Bool
    }

    /// Sort for display: by kind (whisperKit, whisperCpp, bundledLLM), then largest
    /// first within a kind, then label for stability.
    static func sorted(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            if a.kind != b.kind { return kindRank(a.kind) < kindRank(b.kind) }
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            return a.label < b.label
        }
    }

    /// Total bytes across all items — the "N GB used by models" figure.
    static func totalBytes(_ items: [Item]) -> Int64 {
        items.reduce(0) { $0 + max(0, $1.bytes) }
    }

    private static func kindRank(_ kind: Kind) -> Int {
        switch kind {
        case .whisperKit: return 0
        case .parakeet:   return 1
        case .whisperCpp: return 2
        case .bundledLLM: return 3
        }
    }

    /// A human label for a FluidAudio Models repo folder (the immediate children of
    /// `~/Library/Application Support/FluidAudio/Models/`). Pure so the mapping is
    /// unit-tested; the disk walk stays app-side. Unknown folders (a future
    /// FluidAudio repo) fall back to the raw folder name so nothing is hidden.
    static func parakeetRepoLabel(forFolder folder: String) -> String {
        switch folder {
        case "parakeet-tdt-0.6b-v3":     return "Parakeet TDT v3 (batch, 25 languages)"
        case "parakeet-unified-en-0.6b": return "Parakeet Unified (English streaming)"
        case "parakeet-eou-streaming":   return "Parakeet EOU (English streaming, light)"
        case "nemotron-multilingual":    return "Parakeet Multilingual (streaming, ~40 languages)"
        default:                          return folder
        }
    }

    /// Format a byte count for display (e.g. "1.5 GB", "464 MB", "2.7 MB", "0 KB").
    /// Uses binary-ish thresholds with `ByteCountFormatter` (.file style = decimal on
    /// macOS, which matches how Finder reports sizes).
    static func format(bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: max(0, bytes))
    }

    // MARK: - Disk measurement (moved from AppState under the MAK-32 ratchet)

    /// Allocated size of a directory tree (bytes) — regular files only.
    static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let vals = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            total += Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Allocated size of a single file (bytes).
    static func fileSize(at url: URL) -> Int64 {
        let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
    }
}
