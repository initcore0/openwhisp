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
    ///
    /// `biasTerms` (MAK-71) enables CTC context biasing toward custom vocabulary.
    /// Empty = the plain path, byte-for-byte as before.
    static func transcribeBatch(
        handle: BatchHandle, wavURL: URL, languageCode: String?, biasTerms: [String] = []
    ) async throws -> String {
        var state = try TdtDecoderState(decoderLayers: handle.decoderLayers)
        let language: Language? = languageCode.flatMap { Language(rawValue: $0) }
        let result = try await handle.manager.transcribe(
            wavURL, decoderState: &state, language: language)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !biasTerms.isEmpty, !text.isEmpty else { return text }
        return await ParakeetVocabularyBiaser.shared.rescore(
            transcript: text, tokenTimings: result.tokenTimings, wavURL: wavURL, terms: biasTerms)
    }
}

// MARK: - CTC context biasing (MAK-71)

/// Biases a finished Parakeet transcript toward the user's vocabulary terms,
/// using FluidAudio's CTC-WS subsystem (a port of NVIDIA's word spotter,
/// arXiv:2406.07096).
///
/// **Why this exists as a second pass.** TDT v3 has no CTC head, so biasing needs
/// a separate CTC-110M model (~97.5MB) run alongside: it re-derives log-probs over
/// the same audio, spots vocabulary terms acoustically, then rescores the TDT
/// transcript where the spotter found evidence. That's why it only substitutes
/// where the acoustics agree — unlike `VocabularySubstitutor`'s blind regex.
///
/// **Fail-open, always.** Every failure path returns the original transcript. A
/// vocabulary feature must never cost the user their dictation: no model, no
/// timings, a download failure, or a throwing spotter all degrade to plain text.
///
/// Batch paths only. The streaming engine can't use this — rescoring wants the
/// full log-prob matrix over complete audio, and FluidAudio documents weak
/// streaming support (no cross-chunk detection). See MAK-71.
actor ParakeetVocabularyBiaser {
    static let shared = ParakeetVocabularyBiaser()

    private var models: CtcModels?
    private var tokenizer: CtcTokenizer?
    /// Set once a load attempt has failed, so we don't re-attempt a ~97.5MB
    /// download on every single transcription.
    private var loadFailed = false

    /// Rescore `transcript` toward `terms`. Returns the input unchanged on any
    /// failure, or when the CTC models aren't available.
    func rescore(
        transcript: String, tokenTimings: [TokenTiming]?, wavURL: URL, terms: [String]
    ) async -> String {
        // Rescoring aligns TDT words to CTC frames by time; without timings there
        // is nothing to align. FluidAudio types this as optional, so handle it.
        guard let tokenTimings, !tokenTimings.isEmpty else { return transcript }

        do {
            guard let (models, tokenizer) = try await ensureLoaded() else { return transcript }

            let vocabTerms: [CustomVocabularyTerm] = terms.compactMap { term in
                let ids = tokenizer.encode(term)
                guard !ids.isEmpty else { return nil }
                return CustomVocabularyTerm(
                    text: term, weight: nil, aliases: nil,
                    tokenIds: nil, ctcTokenIds: ids, minSimilarity: nil)
            }
            guard !vocabTerms.isEmpty else { return transcript }

            let vocabulary = CustomVocabularyContext(terms: vocabTerms)
            let samples = try Self.samples(from: wavURL)
            guard !samples.isEmpty else { return transcript }

            let spotter = CtcKeywordSpotter(models: models)
            let spotted = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: vocabulary, minScore: nil)
            guard !spotted.logProbs.isEmpty else { return transcript }

            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: vocabulary,
                config: .default,
                ctcModelDirectory: CtcModels.defaultCacheDirectory(for: models.variant))

            // Similarity/boost thresholds scale with vocabulary size. FluidAudio's
            // own benchmark calls minSimilarity the main WER-vs-recall lever and
            // tunes it against measured false-positive rates — take their tuning
            // rather than inventing numbers we haven't measured.
            let tuning = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabTerms.count)
            let output = rescorer.ctcTokenRescore(
                transcript: transcript,
                tokenTimings: tokenTimings,
                logProbs: spotted.logProbs,
                frameDuration: spotted.frameDuration,
                cbw: tuning.cbw,
                minSimilarity: tuning.minSimilarity)
            return output.text
        } catch {
            NSLog("[Parakeet] vocabulary biasing skipped: %@", error.localizedDescription)
            return transcript
        }
    }

    /// Read a WAV into the 16 kHz mono `[Float]` the CTC spotter expects.
    /// FluidAudio exposes no URL→samples helper, so this mirrors what its own
    /// benchmark CLI does: read the file, resample via the public AudioConverter.
    private static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return [] }
        try file.read(into: buffer)
        return try AudioConverter().resampleBuffer(buffer)
    }

    private func ensureLoaded() async throws -> (CtcModels, CtcTokenizer)? {
        if loadFailed { return nil }
        if let models, let tokenizer { return (models, tokenizer) }
        do {
            let loadedModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let loadedTokenizer = try await CtcTokenizer.load()
            models = loadedModels
            tokenizer = loadedTokenizer
            return (loadedModels, loadedTokenizer)
        } catch {
            // One shot: a missing/failed CTC model shouldn't re-download per file.
            loadFailed = true
            NSLog("[Parakeet] CTC biasing model unavailable: %@", error.localizedDescription)
            return nil
        }
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
