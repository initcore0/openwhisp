import Foundation

/// Parakeet-backed `FileTranscriptionEngine` (MAK-46): NVIDIA Parakeet TDT v3 on
/// CoreML via FluidAudio's batch `AsrManager`. This is the BACKGROUND / file path
/// — meetings (MAK-50/52), the FileTranscriptionQueue, watch folders, and history
/// re-transcribe (MAK-40) all build their engine via `AppState.makeFileEngine`,
/// so routing "parakeet" here gives every non-live path Parakeet transcription.
///
/// Live *dictation* stays on `ParakeetStreamingEngine` (true streaming is the
/// point of Parakeet) — this engine is never used for the hotkey streaming path.
///
/// Unlike whisper.cpp, TDT v3 is a single on-device CoreML model: the
/// whisper-specific `binaryPath`/`modelPath`/`backend`/`prompt` params are
/// ignored (exactly as `WhisperKitEngine` ignores them). Language is honored as a
/// v3 script hint when a fixed language is set; "auto" lets the model decide.
/// TDT v3 covers 25 European languages (incl. Russian), so — unlike the
/// English-only streaming variants — the file path is genuinely multilingual.
///
/// **Build:** real implementation only under `#if PARAKEET`; otherwise a stub that
/// reports unavailability (mirrors WhisperKitEngine). See docs/PARAKEET.md.
final class ParakeetFileEngine: FileTranscriptionEngine {
    var onTranscriptionComplete: ((UUID, String) -> Void)?
    var onTranscriptionError: ((UUID, String) -> Void)?
    var onProgress: ((Int) -> Void)?
    var onWorkerStatus: ((String) -> Void)?

    init() {}

#if PARAKEET

    // Single shared load Task, observed on the main actor so concurrent requests
    // (liveChunks / queued meeting chunks) coalesce onto ONE download+load rather
    // than each starting their own (the WhisperKitEngine load-stampede fix).
    @MainActor private var loadedHandle: ParakeetBridge.BatchHandle?
    @MainActor private var inFlightLoad: Task<ParakeetBridge.BatchHandle, Error>?
    /// Bumped by stopServer(): a load begun before a stop must not repopulate the
    /// cached handle when it completes.
    @MainActor private var loadGeneration = 0

    func warmServer(binaryPath: String, modelPath: String) {
        // No external server; warm = preload the CoreML model so the first file
        // job (or meeting) doesn't pay the download/compile.
        Task {
            try? await Instrumentation.measure("parakeet.file.warm") {
                try await self.ensureLoaded()
            }
        }
    }

    func stopServer() {
        Task { @MainActor in
            self.inFlightLoad?.cancel()
            self.inFlightLoad = nil
            self.loadedHandle = nil
            self.loadGeneration += 1
        }
    }

    func transcribe(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool,
        backend: WhisperBackend,
        prompt: String
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let handle = try await self.ensureLoaded()
                let languageCode = ParakeetLanguageHint.batchLanguageCode(from: language)
                let text = try await ParakeetBridge.transcribeBatch(
                    handle: handle,
                    wavURL: URL(fileURLWithPath: wavPath),
                    languageCode: languageCode,
                    biasTerms: ParakeetVocabularyPrompt.terms(from: prompt)
                )
                if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                await MainActor.run { self.onTranscriptionComplete?(requestID, text) }
            } catch {
                NSLog("[Parakeet] file transcription failed: %@", error.localizedDescription)
                if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                await MainActor.run {
                    self.onTranscriptionError?(requestID, "Parakeet failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @discardableResult
    private func ensureLoaded() async throws -> ParakeetBridge.BatchHandle {
        let (generation, task) = await loadTaskOnMain()
        do {
            let handle = try await task.value
            await storeHandle(handle, generation: generation)
            return handle
        } catch {
            await clearFailedLoad(task)
            throw error
        }
    }

    @MainActor
    private func storeHandle(_ handle: ParakeetBridge.BatchHandle, generation: Int) {
        guard generation == loadGeneration else { return }
        loadedHandle = handle
    }

    @MainActor
    private func clearFailedLoad(_ failed: Task<ParakeetBridge.BatchHandle, Error>) {
        if inFlightLoad == failed { inFlightLoad = nil }
    }

    @MainActor
    private func loadTaskOnMain() -> (generation: Int, task: Task<ParakeetBridge.BatchHandle, Error>) {
        if let handle = loadedHandle { return (loadGeneration, Task { handle }) }
        if let existing = inFlightLoad { return (loadGeneration, existing) }
        let status = onWorkerStatus
        let task = Task<ParakeetBridge.BatchHandle, Error> {
            NSLog("[Parakeet] loading TDT v3 batch model…")
            await MainActor.run { status?("Preparing Parakeet model…") }
            let handle = try await ParakeetBridge.loadBatch()
            NSLog("[Parakeet] TDT v3 batch model loaded.")
            await MainActor.run { status?("Parakeet ready") }
            return handle
        }
        inFlightLoad = task
        return (loadGeneration, task)
    }

#else

    func warmServer(binaryPath: String, modelPath: String) {
        onWorkerStatus?("Parakeet not built in (rebuild with PARAKEET=1)")
    }

    func stopServer() {}

    func transcribe(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool,
        backend: WhisperBackend,
        prompt: String
    ) {
        if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
        onTranscriptionError?(
            requestID,
            "The Parakeet engine isn't available in this build. Rebuild with PARAKEET=1 (see docs/PARAKEET.md)."
        )
    }

#endif
}
