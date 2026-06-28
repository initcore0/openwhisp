import Foundation

/// Experimental real-time WhisperKit engine (streaming partials).
///
/// Unlike `WhisperKitEngine` (file transcription), this conforms to
/// `StreamingTranscriptionEngine` — the same seam Apple Speech uses — because
/// WhisperKit's `AudioStreamTranscriber` OWNS the microphone and transcribes
/// continuously, emitting a growing transcript. It runs its own energy-based VAD,
/// so silence is skipped rather than transcribed (no "dead air" chunks). This is
/// what lets the WhisperKit backend stream a live preview the way Apple Speech does
/// — but with Whisper-quality multilingual accuracy.
///
/// **Build:** real implementation only under `#if WHISPERKIT`; otherwise a stub
/// that reports unavailability, so the default build is unaffected.
final class WhisperKitStreamingEngine: StreamingTranscriptionEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onLevelChanged: ((Float) -> Void)?

    /// WhisperKit model id (its own namespace). Defaults to the staged `small`
    /// (multilingual EN+RU) — the same model the file engine uses.
    private let modelName: String

    init(modelName: String = "openai_whisper-small") {
        self.modelName = modelName
    }

#if WHISPERKIT

    private var loadedKit: WhisperKitHandle?
    @MainActor private var inFlightLoad: Task<WhisperKitHandle, Error>?

    // The running stream + its lifecycle. `runTask` is the start pipeline; the
    // transcriber drives the mic and pushes state diffs to `handleState`.
    private var transcriber: WhisperKitStreamHandle?
    private var runTask: Task<Void, Never>?

    // Last confirmed transcript we emitted as a partial — used so we only forward
    // forward-progress (monotonic confirmed text), avoiding paste churn from the
    // unconfirmed/hypothesis tail.
    @MainActor private var lastConfirmedText: String = ""
    @MainActor private var didFinish: Bool = false

    func start(language: String) throws {
        let task = WhisperKitTaskMapper.map(languageSetting: language)
        Task { @MainActor in
            self.lastConfirmedText = ""
            self.didFinish = false
        }
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let kit = try await self.ensureLoaded()
                let handle = try WhisperKitBridge.makeStreamHandle(
                    kit: kit,
                    task: task,
                    languageOverride: nil
                ) { [weak self] newState in
                    Task { @MainActor in self?.handleState(newState) }
                }
                self.transcriber = handle
                try await handle.start()
            } catch {
                NSLog("[WhisperKitStream] start error: %@", error.localizedDescription)
                await MainActor.run {
                    guard !self.didFinish else { return }
                    self.onError?("WhisperKit streaming failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop(cancel: Bool) {
        let handle = transcriber
        transcriber = nil
        runTask?.cancel()
        runTask = nil
        Task { @MainActor in
            self.didFinish = true
            await handle?.stop()
            if !cancel {
                // Final = the full assembled transcript (confirmed + any trailing
                // unconfirmed text), so the last words aren't lost.
                let full = handle?.fullText() ?? ""
                let final = full.isEmpty ? self.lastConfirmedText : full
                self.onFinal?(final.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// Translate a WhisperKit stream state into our callbacks.
    @MainActor
    private func handleState(_ state: WhisperKitStreamState) {
        if let level = state.peakEnergy {
            onLevelChanged?(level)
        }
        // Emit the FULL current transcript (confirmed + unconfirmed) as the live
        // partial. WhisperKit only promotes segments to `confirmedSegments` after
        // several accumulate, so a short utterance stays entirely unconfirmed —
        // emitting confirmed-only would show nothing until stop. AppState's partial
        // handler diffs against what it already pasted (`liveDelta`), so revising the
        // unconfirmed tail is handled the same way Apple Speech's partials are.
        let text = state.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastConfirmedText else { return }
        lastConfirmedText = text
        onPartial?(text)
    }

    @discardableResult
    private func ensureLoaded() async throws -> WhisperKitHandle {
        if let kit = loadedKit { return kit }
        let task = await loadTaskOnMain()
        let kit = try await task.value
        loadedKit = kit
        return kit
    }

    @MainActor
    private func loadTaskOnMain() -> Task<WhisperKitHandle, Error> {
        if let existing = inFlightLoad { return existing }
        let name = modelName
        let task = Task<WhisperKitHandle, Error> {
            NSLog("[WhisperKitStream] loading model '%@'…", name)
            let kit = try await WhisperKitBridge.load(model: name)
            NSLog("[WhisperKitStream] model loaded.")
            return kit
        }
        inFlightLoad = task
        return task
    }

#else

    func start(language: String) throws {
        onError?("WhisperKit backend isn't available in this build. Rebuild with WHISPERKIT=1 (see docs/WHISPERKIT_PILOT.md).")
    }

    func stop(cancel: Bool) {}

#endif
}
