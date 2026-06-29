import Foundation

/// Experimental WhisperKit-backed `FileTranscriptionEngine` (pilot).
///
/// WhisperKit (Argmax, MIT) is a Swift-native CoreML/ANE Whisper runtime. This
/// engine conforms to the SAME `FileTranscriptionEngine` protocol as the
/// whisper.cpp `WhisperEngine`, so it drops into AppState's existing pipeline
/// unchanged (request → onTranscriptionComplete/Error) — the payoff of the
/// Phase 2.5 transcription seam. This first pilot does FILE transcription only
/// (WAV → text); true streaming partials are a later step.
///
/// **Build:** WhisperKit is a SwiftPM dependency, but the app is compiled with a
/// raw `swiftc` glob (see build.sh), so WhisperKit is OPT-IN at build time:
/// `WHISPERKIT=1 ./build.sh` links it and defines the `WHISPERKIT` flag. Without
/// that flag (the default build), this compiles to a stub that reports
/// unavailability via `onTranscriptionError`, so the normal build is unaffected.
/// See docs/WHISPERKIT_PILOT.md.
final class WhisperKitEngine: FileTranscriptionEngine {
    var onTranscriptionComplete: ((UUID, String) -> Void)?
    var onTranscriptionError: ((UUID, String) -> Void)?
    var onProgress: ((Int) -> Void)?
    var onWorkerStatus: ((String) -> Void)?

    /// WhisperKit CoreML model identifier — a name from WhisperKit's OWN repo
    /// namespace (e.g. "openai_whisper-large-v3-v20240930_turbo_632MB"), NOT a
    /// whisper.cpp GGML model name. WhisperKit auto-downloads it on first use.
    /// Defaults to the large-v3 turbo CoreML build (mirrors the recommended
    /// whisper.cpp model).
    private let modelName: String

    // Pilot default is `small` (multilingual, EN+RU). It's a locally-converted
    // CoreML model under Application Support, loaded via `modelFolder`. `small` is
    // the pragmatic pilot choice: its encoder is ~7× smaller than large-v3-turbo,
    // whose first-load CoreML specialization is slow and memory-heavy enough to be
    // unusable on a 16 GB Mac. NOTE: WhisperKitBridge.load() pins the audio encoder
    // to the GPU (.cpuAndGPU) — the ANE specialization of `small`'s encoder can
    // stall indefinitely on macOS 26, which was the real "stuck" hang. large-v3-turbo
    // can be staged/selected too, but isn't the default. See docs/WHISPERKIT_PILOT.md.
    init(modelName: String = "openai_whisper-small") {
        self.modelName = modelName
    }

#if WHISPERKIT

    // Real implementation, compiled only when built with WHISPERKIT=1.
    // Lazily loads the WhisperKit pipeline on first transcription, reporting
    // load progress/status through the same callbacks the UI already listens to.
    //
    // CONCURRENCY: the first load triggers a slow one-time CoreML/ANE compile
    // (minutes for the large encoder). In liveChunks mode several transcribe()
    // tasks arrive almost at once; without coordination each would start its OWN
    // load and the parallel ANE compiles thrash and never finish (the cold-start
    // "stuck" bug). We therefore keep a SINGLE shared load Task — the first caller
    // creates it, everyone else awaits the same one. The Task property is only
    // touched on the main actor (see loadTaskOnMain) so the check-and-set is atomic.
    private var loadedKit: WhisperKitHandle?
    @MainActor private var inFlightLoad: Task<WhisperKitHandle, Error>?

    // Sticky language for the "auto" setting. We detect the spoken language ONCE
    // (on the first chunk) and reuse it for the rest of the session — per-2s-chunk
    // auto-detection is unreliable and makes Whisper flap (e.g. emit English for
    // Russian speech). Coalesced through a single Task so concurrent live chunks
    // don't each run their own detection. Touched only on the main actor.
    @MainActor private var stickyLanguage: String?
    @MainActor private var inFlightDetect: Task<String, Error>?

    /// Download + stage a WhisperKit model for the in-app model manager, reporting
    /// 0…1 progress. Available only in a WhisperKit build; the stub (below) throws.
    static func downloadModel(_ model: String, onProgress: @escaping (Double) -> Void) async throws {
        try await WhisperKitBridge.downloadModel(model, onProgress: onProgress)
    }

    func warmServer(binaryPath: String, modelPath: String) {
        // WhisperKit has no separate server; warm = preload the model (best-effort).
        // Doing this when the engine is selected turns the slow first-load into a
        // background warm-up instead of blocking the first dictation.
        // Timed (instrumentation builds): start of warm → model ready. This is the
        // "how long until the first dictation can run" number.
        Task {
            try? await Instrumentation.measure("whisperkit.warm") {
                try await self.ensureLoaded()
            }
        }
    }

    func stopServer() {
        // Nothing to tear down (no external process); drop the model to free memory.
        loadedKit = nil
        Task { @MainActor in
            self.inFlightLoad = nil
            // Forget the detected language so the next session re-detects.
            self.stickyLanguage = nil
            self.inFlightDetect = nil
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
                let kit = try await self.ensureLoaded()
                let task = WhisperKitTaskMapper.map(languageSetting: language)
                // For "auto" (no explicit language, not translating) detect the
                // language ONCE per session and pin it — per-chunk auto-detect flaps
                // (e.g. transcribes Russian speech as English). Explicit-language
                // and translate tasks bypass this entirely.
                var override: String? = nil
                if task.language == nil && !task.translate {
                    override = try await self.stickyAutoLanguage(kit: kit, wavPath: wavPath)
                }
                let text = try await WhisperKitBridge.transcribe(
                    kit: kit, wavPath: wavPath, task: task, languageOverride: override, prompt: prompt
                )
                if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                await MainActor.run { self.onTranscriptionComplete?(requestID, text) }
            } catch {
                NSLog("[WhisperKit] transcription failed: %@", error.localizedDescription)
                if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                await MainActor.run {
                    self.onTranscriptionError?(requestID, "WhisperKit failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @discardableResult
    private func ensureLoaded() async throws -> WhisperKitHandle {
        if let kit = loadedKit { return kit }
        // Coalesce concurrent loads into ONE shared Task, created/observed on the
        // main actor so the check-and-create is atomic (prevents the load stampede).
        let task = await loadTaskOnMain()
        do {
            let kit = try await task.value
            loadedKit = kit
            return kit
        } catch {
            // The shared load failed (e.g. timed-out cold start). Clear the cached
            // Task so the NEXT attempt starts a fresh load instead of re-awaiting
            // the same failure forever — this is the retry path. Only clear if it's
            // still THIS task (a concurrent retry may have already replaced it).
            await clearFailedLoad(task)
            throw error
        }
    }

    /// Drop the cached load Task if it's the one that just failed, so a later
    /// `ensureLoaded()` retries from scratch.
    @MainActor
    private func clearFailedLoad(_ failed: Task<WhisperKitHandle, Error>) {
        if inFlightLoad == failed { inFlightLoad = nil }
    }

    /// Returns the single in-flight load Task, creating it on first call. All the
    /// state access happens on the main actor, so concurrent callers can't each
    /// spawn their own load.
    @MainActor
    private func loadTaskOnMain() -> Task<WhisperKitHandle, Error> {
        if let existing = inFlightLoad { return existing }
        let name = modelName
        let status = onWorkerStatus
        let task = Task<WhisperKitHandle, Error> {
            NSLog("[WhisperKit] loading model '%@'…", name)
            await MainActor.run { status?("Preparing WhisperKit model…") }
            let kit = try await WhisperKitBridge.load(model: name)
            NSLog("[WhisperKit] model loaded.")
            await MainActor.run { status?("WhisperKit ready") }
            return kit
        }
        inFlightLoad = task
        return task
    }

    func resetSession() {
        // New dictation → forget the previously detected language so we re-detect.
        Task { @MainActor in
            self.stickyLanguage = nil
            self.inFlightDetect = nil
        }
    }

    /// Resolve the sticky auto-detected language: return the cached value if we
    /// already detected one this session, otherwise detect on this chunk and cache
    /// it. Concurrent live chunks coalesce onto a single detection Task (created on
    /// the main actor so the check-and-set is atomic), so we detect exactly once.
    private func stickyAutoLanguage(kit: WhisperKitHandle, wavPath: String) async throws -> String {
        let task = await detectTaskOnMain(kit: kit, wavPath: wavPath)
        let lang = try await task.value
        await MainActor.run { self.stickyLanguage = lang }
        return lang
    }

    @MainActor
    private func detectTaskOnMain(kit: WhisperKitHandle, wavPath: String) -> Task<String, Error> {
        if let cached = stickyLanguage { return Task { cached } }
        if let existing = inFlightDetect { return existing }
        let task = Task<String, Error> {
            try await WhisperKitBridge.detectLanguage(kit: kit, wavPath: wavPath)
        }
        inFlightDetect = task
        return task
    }

#else

    // Stub implementation for the default (no-WhisperKit) build. Conforms to the
    // protocol so the app compiles; any attempt to use it reports unavailability
    // instead of silently failing.
    struct WhisperKitUnavailable: Error, LocalizedError {
        var errorDescription: String? { "WhisperKit isn't available in this build (WHISPERKIT=0)." }
    }

    static func downloadModel(_ model: String, onProgress: @escaping (Double) -> Void) async throws {
        throw WhisperKitUnavailable()
    }

    func warmServer(binaryPath: String, modelPath: String) {
        onWorkerStatus?("WhisperKit not built in (rebuild with WHISPERKIT=1)")
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
            "WhisperKit backend isn't available in this build. Rebuild with WHISPERKIT=1 (see docs/WHISPERKIT_PILOT.md)."
        )
    }

#endif
}
