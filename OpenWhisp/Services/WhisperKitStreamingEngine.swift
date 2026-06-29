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

    // The running stream. The transcriber drives the mic and pushes state diffs to
    // `handleState`. Touched only on the main actor (via the serialized chain).
    @MainActor private var transcriber: WhisperKitStreamHandle?

    // Last confirmed transcript we emitted as a partial — used so we only forward
    // forward-progress (monotonic confirmed text), avoiding paste churn from the
    // unconfirmed/hypothesis tail.
    @MainActor private var lastConfirmedText: String = ""
    @MainActor private var didFinish: Bool = false

    /// Serialized lifecycle: every start/stop is appended to this chain, so a stop's
    /// mic/AVAudioEngine teardown ALWAYS completes before the next start's
    /// `installTap` runs. Replaces the old fire-and-forget stopTask + 150ms magic
    /// sleep, which raced on a quick double-tap restart (the "Streaming Error" on
    /// re-press). See `SerialTaskChain`.
    @MainActor private let lifecycle = SerialTaskChain()

    func start(language: String) throws {
        let task = WhisperKitTaskMapper.map(languageSetting: language)
        // Enqueue SYNCHRONOUSLY on the main actor so call order == enqueue order
        // (a stop() immediately followed by start() must serialize in that order).
        // All callers are @MainActor (AppState); an outer Task hop here would let two
        // rapid calls reorder. assumeIsolated documents and enforces that invariant.
        MainActor.assumeIsolated {
            self.lastConfirmedText = ""
            self.didFinish = false
            self.lifecycle.enqueue { [weak self] in
                await self?.runStart(task: task)
            }
        }
    }

    /// The start pipeline, run inside the serialized lifecycle chain (so any prior
    /// stop's teardown has already completed — no installTap race, no sleep needed).
    @MainActor
    private func runStart(task: WhisperKitTaskMapper.Resolved) async {
        do {
            let kit = try await ensureLoaded()
            let handle = try WhisperKitBridge.makeStreamHandle(
                kit: kit,
                task: task,
                languageOverride: nil
            ) { [weak self] newState in
                Task { @MainActor in self?.handleState(newState) }
            }
            transcriber = handle
            // `start()` runs the realtime loop until stopped; it returns when the
            // stream ends. Don't block the chain on it (a stop must be able to run),
            // so drive it in a detached child whose lifetime the stop tears down.
            Task { try? await handle.start() }
        } catch {
            NSLog("[WhisperKitStream] start error: %@", error.localizedDescription)
            guard !didFinish else { return }
            onError?("WhisperKit streaming failed: \(error.localizedDescription)")
        }
    }

    func stop(cancel: Bool) {
        // Synchronous main-actor enqueue (see start) so stop→start order is preserved.
        MainActor.assumeIsolated {
            self.lifecycle.enqueue { [weak self] in
                await self?.runStop(cancel: cancel)
            }
        }
    }

    /// The stop pipeline, run inside the serialized lifecycle chain. Awaiting the
    /// transcriber's `stop()` here is what guarantees the mic/input node is released
    /// before any queued start proceeds.
    @MainActor
    private func runStop(cancel: Bool) async {
        let handle = transcriber
        transcriber = nil
        didFinish = true
        await handle?.stop()
        if !cancel {
            // Final = the full assembled transcript (confirmed + any trailing
            // unconfirmed text), so the last words aren't lost.
            let full = handle?.fullText() ?? ""
            let final = full.isEmpty ? lastConfirmedText : full
            onFinal?(final.trimmingCharacters(in: .whitespacesAndNewlines))
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
