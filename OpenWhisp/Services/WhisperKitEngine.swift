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

    /// WhisperKit model repo name (CoreML). "large-v3-turbo" mirrors the
    /// recommended whisper.cpp model; WhisperKit auto-downloads it on first use.
    private let modelName: String

    init(modelName: String = "large-v3-turbo") {
        self.modelName = modelName
    }

#if WHISPERKIT

    // Real implementation, compiled only when built with WHISPERKIT=1.
    // Lazily loads the WhisperKit pipeline on first transcription, reporting
    // load progress/status through the same callbacks the UI already listens to.
    private var loadedKit: Any?            // holds a WhisperKit instance (typed below)
    private var loading = false

    func warmServer(binaryPath: String, modelPath: String) {
        // WhisperKit has no separate server; warm = preload the model (best-effort).
        Task { try? await ensureLoaded() }
    }

    func stopServer() {
        // Nothing to tear down (no external process); drop the model to free memory.
        loadedKit = nil
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
                let text = try await WhisperKitBridge.transcribe(
                    kit: kit, wavPath: wavPath, task: task, prompt: prompt
                )
                if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                await MainActor.run { self.onTranscriptionComplete?(requestID, text) }
            } catch {
                if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                await MainActor.run {
                    self.onTranscriptionError?(requestID, "WhisperKit failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @discardableResult
    private func ensureLoaded() async throws -> WhisperKitHandle {
        if let kit = loadedKit as? WhisperKitHandle { return kit }
        await MainActor.run { self.onWorkerStatus?("Loading WhisperKit (\(modelName))...") }
        let kit = try await WhisperKitBridge.load(model: modelName)
        loadedKit = kit
        await MainActor.run { self.onWorkerStatus?("WhisperKit ready") }
        return kit
    }

#else

    // Stub implementation for the default (no-WhisperKit) build. Conforms to the
    // protocol so the app compiles; any attempt to use it reports unavailability
    // instead of silently failing.
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
