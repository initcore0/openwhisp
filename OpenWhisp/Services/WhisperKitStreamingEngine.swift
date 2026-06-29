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

    /// In-flight stop, so a quick start() (e.g. the double-tap instruction step)
    /// waits for the previous stream's mic/AVAudioEngine to fully release before
    /// grabbing it again — otherwise the new `installTap` races the old teardown and
    /// throws (the "Streaming Error" on re-press).
    private var stopTask: Task<Void, Never>?

    func start(language: String) throws {
        let task = WhisperKitTaskMapper.map(languageSetting: language)
        Task { @MainActor in
            self.lastConfirmedText = ""
            self.didFinish = false
        }
        let priorStop = stopTask
        runTask = Task { [weak self] in
            guard let self else { return }
            // Wait out any previous stop so the mic is free before we re-acquire it,
            // plus a short settle so the old AVAudioEngine fully releases the input
            // node (avoids the installTap race on a quick double-tap restart).
            if priorStop != nil {
                await priorStop?.value
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
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
        let task = Task { @MainActor in
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
        stopTask = task
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
        do {
            let kit = try await task.value
            loadedKit = kit
            return kit
        } catch {
            // Failed (e.g. timed-out cold start): clear the cached Task so the next
            // attempt retries from scratch rather than re-awaiting the same failure.
            await clearFailedLoad(task)
            throw error
        }
    }

    @MainActor
    private func clearFailedLoad(_ failed: Task<WhisperKitHandle, Error>) {
        if inFlightLoad == failed { inFlightLoad = nil }
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
