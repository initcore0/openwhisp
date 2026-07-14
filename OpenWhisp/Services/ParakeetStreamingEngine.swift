import Foundation
import AVFoundation

/// True-streaming Parakeet engine (MAK-46): NVIDIA Parakeet on CoreML via
/// FluidAudio's cache-aware streaming managers. Unlike WhisperKit's streaming
/// pilot (whole-window re-transcription), these models are architecturally
/// streaming — partials trail the voice by the variant's chunk latency (0.32 s
/// for the default Unified tier), which is what makes dictation feel realtime.
///
/// Conforms to `StreamingTranscriptionEngine` (the Apple Speech seam): it owns
/// the microphone via its own AVAudioEngine tap, feeds buffers to FluidAudio,
/// and emits the growing transcript through `onPartial`. AppState's existing
/// delta-paste/live-preview path handles the rest unchanged.
///
/// The engine talks only to `ParakeetStreamSession` (in ParakeetBridge), which
/// hides FluidAudio's two manager shapes — the English families
/// (`any StreamingAsrManager`) and the Nemotron multilingual actor. The variant's
/// `multilingual` flag (ParakeetCatalog) picks the manager; multilingual variants
/// honor the language hint, English variants ignore it.
///
/// **Build:** real implementation only under `#if PARAKEET` (build.sh
/// PARAKEET=1); otherwise a stub that reports unavailability, so the default
/// build is unaffected. See docs/PARAKEET.md.
final class ParakeetStreamingEngine: StreamingTranscriptionEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?
    var onStarted: (() -> Void)?

    /// Fires when the underlying manager reports a NEW end-of-utterance event
    /// (only the EOU variant exposes these). Used by the agent-dictate EOU
    /// auto-stop (MAK-46 Phase 5); nil for every other caller. Fires on the main
    /// actor. Non-EOU variants never call it.
    var onEouDetected: (() -> Void)?

    /// ParakeetCatalog variant id (see ParakeetCatalog).
    private let variantID: String

    /// Pinned input-device UID for the next session ("" = system default).
    @MainActor private var selectedDeviceID = ""

    func selectDevice(_ deviceID: String) {
        MainActor.assumeIsolated {
            selectedDeviceID = deviceID
        }
    }

    init(variantID: String = ParakeetCatalog.defaultVariantID) {
        self.variantID = ParakeetCatalog.normalize(variantID)
    }

#if PARAKEET

    // AVAudioEngine + FluidAudio session handles. Main-actor confined alongside
    // the session state (same pattern as AppleSpeechEngine / WhisperKitStreamingEngine).
    @MainActor private var audioEngine: AVAudioEngine?
    /// The loaded FluidAudio streaming session, cached across sessions (models
    /// stay resident; `reset()` clears per-session decode state).
    @MainActor private var session: (any ParakeetStreamSession)?
    @MainActor private var inFlightLoad: Task<any ParakeetStreamSession, Error>?
    /// Ordered buffer feed: the tap yields into the continuation (captured
    /// directly in the tap closure — yield is Sendable/thread-safe, so no
    /// per-buffer main-actor hop) and a single detached consumer task appends
    /// to the (actor) manager. Unstructured Tasks from the tap thread would
    /// race each other and interleave audio out of order. This stored copy
    /// exists ONLY so teardown (runStop / feed-loop error) can finish() it.
    @MainActor private var feedContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    @MainActor private var feedTask: Task<Void, Never>?

    @MainActor private var lastPartial = ""
    @MainActor private var didStop = false
    /// Session generation, bumped on every start and stop — late partial
    /// callbacks from a torn-down session fail the gate instead of leaking into
    /// the next one (same rationale as the other streaming engines).
    @MainActor private var generation = 0
    /// Serialized start/stop lifecycle so a stop's mic teardown always completes
    /// before the next start installs its tap (see SerialTaskChain).
    @MainActor private let lifecycle = SerialTaskChain()

    func start(language: String) throws {
        // All callers are @MainActor (AppState); synchronous enqueue preserves
        // call order (a stop() immediately followed by start() must serialize).
        MainActor.assumeIsolated {
            // Strong capture on purpose: the chain must keep the engine alive
            // until its lifecycle work completes (see WhisperKitStreamingEngine).
            self.lifecycle.enqueue {
                await self.runStart(language: language)
            }
        }
    }

    @MainActor
    private func runStart(language: String) async {
        // Reset per-session flags ON the serialized chain, not at enqueue time:
        // a fast stop→start enqueues runStop BEFORE this runStart, and its
        // didStop=true must not poison the new session (an enqueue-time reset
        // would run first and then be clobbered by the queued runStop).
        lastPartial = ""
        didStop = false
        do {
            // Variant-aware language gate: English-only variants refuse a FIXED
            // non-English language up front (never silently mangle it); the
            // multilingual variant accepts any language ("auto" for unknowns).
            if let message = ParakeetLanguageGate.refusalMessage(
                languageSetting: language,
                multilingual: ParakeetCatalog.isMultilingual(variantID)
            ) {
                onError?(message)
                return
            }

            let engine = AVAudioEngine()
            let input = engine.inputNode

            // Route to the selected input device BEFORE reading the format.
            // An unresolved pinned device is a hard error, never a silent
            // fall-back to the system default (same policy as Apple Speech).
            switch AudioInputRoutingPolicy.decide(
                microphoneID: selectedDeviceID,
                deviceResolved: AudioInputRouter.canResolve(uid: selectedDeviceID)
            ) {
            case .systemDefault:
                break
            case .useDevice(let uid):
                guard let device = AudioInputRouter.resolve(uid: uid),
                      AudioInputRouter.apply(device, to: engine) else {
                    onError?(AudioInputRoutingPolicy.unresolvedMessage(uid: uid))
                    return
                }
            case .unresolved(let uid):
                onError?(AudioInputRoutingPolicy.unresolvedMessage(uid: uid))
                return
            }

            let format = input.outputFormat(forBus: 0)
            // 0 Hz / 0 ch (no input device) would make installTap raise an ObjC
            // NSException that Swift can't catch — guard it out.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                onError?("No audio input device available.")
                return
            }

            let session = try await ensureLoaded()
            try await session.reset()
            // Multilingual variants take the language hint; English adapters no-op.
            await session.setLanguage(ParakeetLanguageHint.multilingualLanguageCode(from: language))

            generation += 1
            let myGeneration = generation

            // Partials arrive on the manager's actor; hop to main and gate on
            // generation before touching session state.
            await session.setPartialCallback { [weak self] text in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == myGeneration else { return }
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, trimmed != self.lastPartial else { return }
                        self.lastPartial = trimmed
                        self.onPartial?(trimmed)
                    }
                }
            }

            // Single ordered consumer: tap thread → AsyncStream → manager actor.
            let (stream, continuation) = AsyncStream.makeStream(
                of: AVAudioPCMBuffer.self,
                bufferingPolicy: .unbounded
            )
            feedContinuation = continuation
            // Poll for end-of-utterance events only on variants whose manager
            // actually emits them (the EOU family) — `onEouDetected` is wired
            // unconditionally by AppState, so gating on the callback alone would
            // put two extra actor hops on EVERY buffer of every session.
            let pollsEou = ParakeetCatalog.emitsEou(variantID)
            // Detached ON PURPOSE: the loop must NOT inherit the main actor —
            // otherwise every buffer (~50/s) pays main-thread hops just to run
            // the append/process awaits, which starves the UI. All session
            // state it touches goes through explicit MainActor.run hops.
            feedTask = Task.detached { [weak self] in
                // EOU bookkeeping lives off-main in the loop: hop to the main
                // actor only when a NEW event actually arrived, not per buffer.
                var lastEouCount = 0
                do {
                    for await buffer in stream {
                        // appendAudio accepts any format (resamples to 16 kHz
                        // mono internally); processBuffered decodes any complete
                        // chunks and fires the partial callback.
                        try await session.appendAudio(buffer)
                        try await session.processBuffered()
                        // A grown timestamp count is a new end-of-utterance event.
                        if pollsEou {
                            let count = await session.eouTimestampsMs().count
                            if count > lastEouCount {
                                lastEouCount = count
                                await MainActor.run { [weak self] in
                                    guard let self, self.generation == myGeneration, !self.didStop else { return }
                                    self.onEouDetected?()
                                }
                            }
                        }
                    }
                } catch {
                    NSLog("[Parakeet] stream feed error: %@", error.localizedDescription)
                    await MainActor.run { [weak self] in
                        // Generation gate doubles as the runStop race guard: if
                        // a stop already superseded this session, its teardown
                        // owns the engine/continuation and we must not touch them.
                        guard let self, self.generation == myGeneration, !self.didStop else { return }
                        // The consumer is dead — tear the mic down too, or the
                        // tap keeps the mic hot and the continuation buffers
                        // yielded audio unbounded until the next session.
                        if let audioEngine = self.audioEngine {
                            audioEngine.inputNode.removeTap(onBus: 0)
                            audioEngine.stop()
                        }
                        self.audioEngine = nil
                        self.feedContinuation?.finish()
                        self.feedContinuation = nil
                        self.onError?("Parakeet streaming failed: \(error.localizedDescription)")
                    }
                }
            }

            // The tap closure runs on an audio thread but touches no session
            // state — AsyncStream.Continuation.yield is Sendable + thread-safe,
            // so it yields straight from the audio thread (no main-actor hop
            // per buffer) and publishes a level.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                continuation.yield(buffer)
                self?.publishLevel(from: buffer)
            }

            audioEngine = engine
            engine.prepare()
            try engine.start()
            // Tap installed + AVAudioEngine running: audio is flowing into the
            // feed stream. Everything above (model load/first-run download,
            // reset, callback wiring) was the arming gap this signal closes.
            onStarted?()
        } catch {
            NSLog("[Parakeet] start error: %@", error.localizedDescription)
            guard !didStop else { return }
            onError?("Parakeet streaming failed: \(error.localizedDescription)")
        }
    }

    func stop(cancel: Bool) {
        MainActor.assumeIsolated {
            self.lifecycle.enqueue {
                await self.runStop(cancel: cancel)
            }
        }
    }

    /// Cancel any in-flight model load/download and forget it. Called when this
    /// engine instance is being DISCARDED (e.g. `rebuildFileEngine` replaces it
    /// after a variant switch) so a ~600 MB download for the old variant isn't
    /// orphaned — `stop(cancel:)` only tears down the mic/session, never the load
    /// Task. Idempotent and safe to call with no load in flight.
    @MainActor
    func cancelLoading() {
        inFlightLoad?.cancel()
        inFlightLoad = nil
    }

    @MainActor
    private func runStop(cancel: Bool) async {
        didStop = true
        // Supersede the session so late partial hops are dropped.
        generation += 1

        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil

        // End the feed and WAIT for queued buffers to reach the manager, so
        // finish() below sees the audio tail (the last words of the dictation).
        feedContinuation?.finish()
        feedContinuation = nil
        await feedTask?.value
        feedTask = nil

        guard let session else { return }
        if cancel {
            try? await session.reset()
            return
        }
        do {
            // finish() flushes remaining audio through the model and returns
            // the final transcript.
            let final = try await session.finish()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onFinal?(final.isEmpty ? lastPartial : final)
        } catch {
            NSLog("[Parakeet] finish error: %@", error.localizedDescription)
            // Fall back to the last partial rather than erroring the session —
            // the user's words are already on screen in preview mode.
            onFinal?(lastPartial)
        }
    }

    /// Load/download the variant's model and return when it's staged (or the
    /// load failed). Awaitable so AppState can clear the "Downloading…" badge
    /// the moment the fetch actually completes — event-driven, no disk polling.
    /// Idempotent: joins the in-flight load / returns immediately when cached.
    ///
    /// Returns `true` when the model is loaded/staged, `false` when the load
    /// failed (e.g. offline first-run). The caller uses this to surface a
    /// retryable failure instead of leaving the UI on a perpetual spinner — the
    /// model download is otherwise the only signal Parakeet exposes.
    @MainActor
    @discardableResult
    func prefetchAwaiting() async -> Bool {
        // Route through ensureLoaded so a FAILED load clears `inFlightLoad`
        // (clearFailedLoad) before the error is swallowed — otherwise a failed
        // download poisons the cache and later prefetches no-op forever.
        do {
            _ = try await ensureLoaded()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func ensureLoaded() async throws -> any ParakeetStreamSession {
        if let session = await currentSession() { return session }
        let task = await loadTaskOnMain()
        do {
            let session = try await task.value
            await storeSession(session)
            return session
        } catch {
            await clearFailedLoad(task)
            throw error
        }
    }

    @MainActor private func currentSession() -> (any ParakeetStreamSession)? { session }
    @MainActor private func storeSession(_ s: any ParakeetStreamSession) { session = s }

    @MainActor
    private func clearFailedLoad(_ failed: Task<any ParakeetStreamSession, Error>) {
        if inFlightLoad == failed { inFlightLoad = nil }
    }

    @MainActor
    private func loadTaskOnMain() -> Task<any ParakeetStreamSession, Error> {
        if let existing = inFlightLoad { return existing }
        let variant = variantID
        let task = Task<any ParakeetStreamSession, Error> {
            NSLog("[Parakeet] loading variant '%@'…", variant)
            let session = try await ParakeetBridge.loadStreamSession(variantID: variant)
            NSLog("[Parakeet] variant loaded.")
            return session
        }
        inFlightLoad = task
        return task
    }

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                sum += samples[frame] * samples[frame]
            }
        }
        let rms = sqrt(sum / Float(max(1, channelCount * frameCount)))
        let normalized = AudioLevel.fromRMS(rms)
        DispatchQueue.main.async {
            // fromRMS is the absolute curve, so display and VAD levels coincide.
            self.onLevelChanged?(normalized, normalized)
        }
    }

#else

    func start(language: String) throws {
        onError?("The Parakeet engine isn't available in this build. Rebuild with PARAKEET=1 (see docs/PARAKEET.md).")
    }

    func stop(cancel: Bool) {}

    @discardableResult
    func prefetchAwaiting() async -> Bool { false }

    @MainActor
    func cancelLoading() {}

#endif
}
