#if PARAKEET
import Foundation
import FluidAudio

/// The ONLY file (with ParakeetStreamingEngine's `#if PARAKEET` body) that
/// imports FluidAudio — keeps the dependency surface isolated the same way
/// WhisperKitBridge isolates WhisperKit.
enum ParakeetBridge {
    typealias Manager = any StreamingAsrManager

    /// Create + load (downloading from HuggingFace if needed) the streaming
    /// manager for a ParakeetCatalog variant id. The id was normalized by the
    /// catalog, but an id FluidAudio doesn't know (catalog/library drift after
    /// a version bump) still falls back to the default variant rather than
    /// failing the session.
    static func load(variantID: String) async throws -> Manager {
        let variant = StreamingModelVariant(rawValue: variantID)
            ?? StreamingModelVariant(rawValue: ParakeetCatalog.defaultVariantID)
            ?? .parakeetUnified320ms
        let manager = variant.createManager()
        try await manager.loadModels()
        return manager
    }
}
#endif
