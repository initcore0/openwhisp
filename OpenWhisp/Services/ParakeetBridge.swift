#if PARAKEET
import Foundation
import AVFoundation
import FluidAudio

/// The ONLY file (with ParakeetStreamingEngine / ParakeetFileEngine's
/// `#if PARAKEET` bodies) that imports FluidAudio — keeps the dependency surface
/// isolated the same way WhisperKitBridge isolates WhisperKit. Holds:
///   - the streaming-manager loader (`load(variantID:)`);
///   - the `ParakeetStreamSession` protocol + adapters that wrap FluidAudio's two
///     streaming manager shapes (`any StreamingAsrManager` and the Nemotron
///     multilingual actor);
///   - the batch (TDT v3) handle used by ParakeetFileEngine.
enum ParakeetBridge {

    // MARK: - Streaming manager loading

    /// Load (downloading from HuggingFace if needed) a streaming session for a
    /// ParakeetCatalog variant id. Returns the shared `ParakeetStreamSession`
    /// protocol so the engine never names a FluidAudio manager type.
    ///
    /// The id was normalized by the catalog, but an id FluidAudio doesn't know
    /// (catalog/library drift after a version bump) still falls back to the
    /// default variant rather than failing the session.
    static func loadStreamSession(variantID: String) async throws -> any ParakeetStreamSession {
        let variant = ParakeetCatalog.variant(for: variantID)
        if variant.multilingual {
            // Nemotron multilingual: separate manager type + repo download.
            let chunkMs = variant.multilingualChunkMs ?? 1120
            let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: "auto", chunkMs: chunkMs)
            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadModels(from: dir)
            return NemotronMultilingualStreamSession(manager: manager)
        }
        // English streaming families (Unified / EOU), wrapped in the unified adapter.
        let fluidVariant = StreamingModelVariant(rawValue: variant.id)
            ?? StreamingModelVariant(rawValue: ParakeetCatalog.defaultVariantID)
            ?? .parakeetUnified320ms
        let manager = fluidVariant.createManager()
        try await manager.loadModels()
        return StreamingAsrManagerSession(manager: manager)
    }

    // MARK: - Batch (TDT v3) — ParakeetFileEngine backend

    /// A loaded batch TDT v3 model + manager. Cached across requests by
    /// ParakeetFileEngine (models stay resident; the decoder state is per-call).
    struct BatchHandle {
        let manager: AsrManager
        let decoderLayers: Int
    }

    /// Download (first use) + load Parakeet TDT v3 for batch/file transcription.
    static func loadBatch() async throws -> BatchHandle {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager()
        try await manager.loadModels(models)
        let layers = await manager.decoderLayerCount
        return BatchHandle(manager: manager, decoderLayers: layers)
    }

    /// Transcribe a WAV file with the batch model. `languageCode` is the bare
    /// 2-letter hint from ParakeetLanguageHint (nil = auto); an unknown code
    /// degrades to auto inside FluidAudio (v3-only script filtering).
    static func transcribeBatch(
        handle: BatchHandle, wavURL: URL, languageCode: String?
    ) async throws -> String {
        var state = try TdtDecoderState(decoderLayers: handle.decoderLayers)
        let language: Language? = languageCode.flatMap { Language(rawValue: $0) }
        let result = try await handle.manager.transcribe(
            wavURL, decoderState: &state, language: language)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ParakeetStreamSession protocol + adapters

/// Internal streaming seam that hides FluidAudio's two incompatible manager
/// shapes (`any StreamingAsrManager` vs the Nemotron multilingual actor) behind
/// one surface. `ParakeetStreamingEngine` talks ONLY to this protocol.
protocol ParakeetStreamSession: Sendable {
    /// Register the partial-transcript callback (fires on the manager's actor).
    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async
    /// Set the language hint ("auto"/"en-US"…). English-only managers ignore it.
    func setLanguage(_ code: String) async
    /// Append an audio buffer (any format; the manager resamples to 16 kHz mono).
    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws
    /// Decode any complete buffered chunks (fires the partial callback).
    func processBuffered() async throws
    /// Flush the tail and return the final transcript.
    func finish() async throws -> String
    /// Clear per-session decode state (models stay resident).
    func reset() async throws
    /// End-of-utterance timestamps (ms) so far, for managers that expose them
    /// (the EOU variant). Empty for managers without the capability — the engine
    /// treats "grew since last poll" as a new EOU event (MAK-46 Phase 5).
    func eouTimestampsMs() async -> [Int]
}

/// Adapter over the English streaming families (`any StreamingAsrManager`:
/// Unified / EOU). These are English-only, so `setLanguage` is a no-op.
final class StreamingAsrManagerSession: ParakeetStreamSession, @unchecked Sendable {
    private let manager: any StreamingAsrManager
    init(manager: any StreamingAsrManager) { self.manager = manager }

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialTranscriptCallback(callback)
    }
    func setLanguage(_ code: String) async {}
    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws { try await manager.appendAudio(buffer) }
    func processBuffered() async throws { try await manager.processBufferedAudio() }
    func finish() async throws -> String { try await manager.finish() }
    func reset() async throws { try await manager.reset() }
    func eouTimestampsMs() async -> [Int] {
        // Only the EOU streaming manager exposes end-of-utterance timestamps.
        guard let eou = manager as? any StreamingAsrEouProvider else { return [] }
        return await eou.getEouTimestampsMs()
    }
}

/// Adapter over the Nemotron multilingual streaming actor. Its `appendAudio` is
/// synchronous (actor-isolated) and `process(samples:)` drains the buffer, so we
/// append then process; the partial callback shape matches.
final class NemotronMultilingualStreamSession: ParakeetStreamSession, @unchecked Sendable {
    private let manager: StreamingNemotronMultilingualAsrManager
    init(manager: StreamingNemotronMultilingualAsrManager) { self.manager = manager }

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialCallback(callback)
    }
    func setLanguage(_ code: String) async { await manager.setLanguage(code) }
    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        // process(audioBuffer:) resamples + appends + drains complete chunks in one
        // actor hop, which keeps ordering correct without a separate append call.
        _ = try await manager.process(audioBuffer: buffer)
    }
    func processBuffered() async throws { /* draining happens in appendAudio */ }
    func finish() async throws -> String { try await manager.finish() }
    func reset() async throws { await manager.reset() }
    func eouTimestampsMs() async -> [Int] { [] }  // no EOU capability
}
#endif
