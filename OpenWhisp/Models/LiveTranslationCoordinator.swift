import Foundation
#if canImport(OpenWhispCore)
import OpenWhispCore
#endif

/// Dual-runtime live-translation coordinator (`DualRuntimeTranslationPolicy`).
///
/// Owns the WHOLE translate-while-you-dictate feature except the two thin hooks
/// AppState keeps (arm at streaming start, substitute the final at finalize) —
/// mirroring the `StreamOverlayCoordinator` decomposition so AppState barely
/// grows under the MAK-32 ratchet.
///
/// When a session dictates a non-English language with "Translate to English" on
/// but the fast streaming engine can't translate (Parakeet), this coordinator:
///
///   * tees the engine's mic frames (`StreamingTranscriptionEngine.onAudioBuffer`)
///     into a `TranslationChunker` — NO second microphone,
///   * writes each utterance chunk to a temp 16 kHz mono WAV and runs a
///     whisper-family FILE engine with the translate task, ONE job at a time,
///     bounded queue (drop-oldest),
///   * emits ordered English segments to the overlay's translated track live,
///   * hands AppState the concatenated English transcript as the session's FINAL
///     pasted text (`finalTranslation()`), draining in-flight work under a
///     timeout so a wedged translator can't hang the session; falls back to the
///     original transcript when translation produced nothing.
///
/// Engine/model neutrality: it depends on the `FileTranscriptionEngine` protocol
/// and a `Config` AppState injects (whisper model paths, backend, engine factory)
/// — it never names a concrete engine, so its ordering/drop/drain logic is
/// testable with a fake engine.
@MainActor
final class LiveTranslationCoordinator {

    /// How to run one translate job + where translated segments go. Injected by
    /// AppState (which owns the whisper model paths, warm-server backend, and the
    /// overlay). The engine factory ALWAYS builds a whisper-family engine — the
    /// active streaming engine may be Parakeet, which can't translate.
    struct Config {
        let makeEngine: () -> FileTranscriptionEngine
        /// Resolved fresh per job so a mid-run settings change (model, backend) is
        /// honored — AppState reads its live `modelPath`/`whisperBackend`/binary.
        let resolvePaths: () -> (binary: String, model: String, backend: WhisperBackend)
        let scratchDirectory: URL
        /// Fires (main actor) with each finished English segment, in chunk order —
        /// AppState routes it to the overlay's translated caption track.
        let onSegment: (String) -> Void
    }

    /// Max chunks waiting behind the in-flight translation before drop-oldest.
    /// Small: past a few seconds of backlog a caption is too stale to be useful.
    private static let maxPending = 6
    /// How long `finalTranslation()` waits for in-flight/queued work to drain
    /// before giving up and using whatever segments already landed.
    private static let drainTimeout: Double = 6.0

    /// True for the CURRENT session: the dual path is armed and the tap attached.
    private(set) var active = false

    private let config: Config
    private var chunker = TranslationChunker()
    /// The pure ordering/backpressure core — single in-flight, drop-oldest,
    /// in-order segments (tested in core).
    private var queue = TranslationSegmentQueue(maxPending: LiveTranslationCoordinator.maxPending)
    /// Maps the concrete engine request UUID for the in-flight job back to its
    /// queue dispatch id.
    private var inFlightRequest: (uuid: UUID, queueID: Int)?
    /// The translate engine, created on first use and REUSED for every job.
    /// Must be retained here: the completion callbacks capture self weakly, so a
    /// per-job local engine could deallocate mid-request (no completion ever
    /// fires → the queue slot wedges until the drain timeout). Reuse also keeps
    /// the CLI backend from paying a full model load per chunk.
    private var translateEngine: FileTranscriptionEngine?
    private var finishing = false
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []

    init(config: Config) {
        self.config = config
    }

    // MARK: - AppState hooks (thin surface)

    /// Arm for this session if the policy says so, and attach the audio tee.
    /// Returns whether the dual path is now active (AppState remembers it to gate
    /// the final substitution). Idempotent per session via `active`.
    func armIfNeeded(
        translateToEnglish: Bool,
        language: String,
        transcriptionEngine: String,
        engine: StreamingTranscriptionEngine
    ) -> Bool {
        guard DualRuntimeTranslationPolicy.shouldRun(
            translateToEnglish: translateToEnglish,
            language: language,
            transcriptionEngine: transcriptionEngine
        ) else { return false }
        resetState()
        active = true
        engine.onAudioBuffer = { [weak self] samples in
            // Runs on the engine's audio thread — hop to the main actor where the
            // chunker/queue live. The chunker is cheap; the hop keeps state single-
            // threaded.
            Task { @MainActor in self?.ingest(samples) }
        }
        return true
    }

    /// Drain in-flight work (under a timeout) and return the full English
    /// translation for the session's final text, or nil when nothing translated
    /// (AppState then keeps the original transcript rather than losing the
    /// dictation). Also flushes the chunker's tail through one last job.
    func finalTranslation() async -> String? {
        guard active else { return nil }
        if let tail = chunker.flush() { submit(tail) }
        finishing = true
        if !queue.isDrained {
            try? await withTimeout(seconds: Self.drainTimeout, operation: "Live translation drain") {
                await self.awaitDrain()
            }
        }
        let joined = queue.joinedText
        return joined.isEmpty ? nil : joined
    }

    /// Detach the tap and reset all state (session teardown).
    func teardown(engine: StreamingTranscriptionEngine?) {
        engine?.onAudioBuffer = nil
        active = false
        resetState()
    }

    // MARK: - Internals

    private func ingest(_ samples: [Float]) {
        guard active else { return }
        for chunk in chunker.ingest(samples) { submit(chunk) }
    }

    private func submit(_ chunk: [Float]) {
        let before = queue.droppedCount
        queue.enqueue(chunk)
        if queue.droppedCount > before {
            NSLog("[LiveTranslation] dropped %d oldest chunk(s) — translator behind",
                  queue.droppedCount - before)
        }
        pump()
    }

    private func pump() {
        guard inFlightRequest == nil, let dispatched = queue.next() else {
            if finishing, queue.isDrained { resolveDrain() }
            return
        }
        let paths = config.resolvePaths()
        let requestID = UUID()
        let wavURL = config.scratchDirectory
            .appendingPathComponent("livetranslate-\(requestID.uuidString).wav")
        do {
            let writer = try MeetingWAVWriter(url: wavURL, sampleRate: 16_000)
            try writer.append(dispatched.chunk)
            try writer.finalize()
        } catch {
            NSLog("[LiveTranslation] WAV write failed: %@", error.localizedDescription)
            // Complete with empty text so the queue frees the slot and moves on.
            queue.complete(id: dispatched.id, text: "")
            pump()
            return
        }
        inFlightRequest = (requestID, dispatched.id)
        let engine = translateEngine ?? config.makeEngine()
        translateEngine = engine
        engine.onTranscriptionComplete = { [weak self] id, text in
            Task { @MainActor in self?.jobFinished(uuid: id, text: text, wavURL: wavURL) }
        }
        engine.onTranscriptionError = { [weak self] id, _ in
            Task { @MainActor in self?.jobFinished(uuid: id, text: "", wavURL: wavURL) }
        }
        // WhisperTask maps the sentinel to (language: auto, translate: true).
        engine.transcribe(
            requestID: requestID,
            binaryPath: paths.binary,
            modelPath: paths.model,
            language: WhisperTask.translateToEnglishSetting,
            wavPath: wavURL.path,
            deleteWhenDone: false,
            backend: paths.backend,
            prompt: ""
        )
    }

    private func jobFinished(uuid: UUID, text: String, wavURL: URL) {
        try? FileManager.default.removeItem(at: wavURL)
        guard let inFlight = inFlightRequest, inFlight.uuid == uuid else { return }
        inFlightRequest = nil
        if let segment = queue.complete(id: inFlight.queueID, text: text) {
            config.onSegment(segment)
        }
        pump()
    }

    private func awaitDrain() async {
        if queue.isDrained { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            drainContinuations.append(cont)
        }
    }

    private func resolveDrain() {
        let conts = drainContinuations
        drainContinuations.removeAll()
        for c in conts { c.resume() }
    }

    private func resetState() {
        chunker.reset()
        queue.reset()
        inFlightRequest = nil
        finishing = false
        resolveDrain()
    }
}
