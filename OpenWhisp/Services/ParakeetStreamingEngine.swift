import Foundation
import AVFoundation

/// True-streaming Parakeet engine (MAK-46 spike): NVIDIA Parakeet on CoreML via
/// FluidAudio's cache-aware streaming managers. Unlike WhisperKit's streaming
/// pilot (whole-window re-transcription), these models are architecturally
/// streaming — partials trail the voice by the variant's chunk latency (0.32 s
/// for the default tier), which is what makes dictation feel realtime.
///
/// Conforms to `StreamingTranscriptionEngine` (the Apple Speech seam): it owns
/// the microphone via its own AVAudioEngine tap, feeds buffers to FluidAudio,
/// and emits the growing transcript through `onPartial`. AppState's existing
/// delta-paste/live-preview path handles the rest unchanged.
///
/// **Build:** real implementation only under `#if PARAKEET` (build.sh
/// PARAKEET=1); otherwise a stub that reports unavailability, so the default
/// build is unaffected. See docs/PARAKEET_SPIKE.md.
final class ParakeetStreamingEngine: StreamingTranscriptionEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?

    /// FluidAudio `StreamingModelVariant` raw value (see ParakeetCatalog).
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

    // AVAudioEngine + FluidAudio manager handles. Main-actor confined alongside
    // the session state (same pattern as AppleSpeechEngine / WhisperKitStreamingEngine).
    @MainActor private var audioEngine: AVAudioEngine?
    /// The loaded FluidAudio streaming manager, cached across sessions (models
    /// stay resident; `reset()` clears per-session decode state).
    @MainActor private var manager: ParakeetBridge.Manager?
    @MainActor private var inFlightLoad: Task<ParakeetBridge.Manager, Error>?
    /// Ordered buffer feed: the tap yields into this continuation and a single
    /// consumer task appends to the (actor) manager. Unstructured Tasks from the
    /// tap thread would race each other and interleave audio out of order.
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
            self.lastPartial = ""
            self.didStop = false
            // Strong capture on purpose: the chain must keep the engine alive
            // until its lifecycle work completes (see WhisperKitStreamingEngine).
            self.lifecycle.enqueue {
                await self.runStart(language: language)
            }
        }
    }

    @MainActor
    private func runStart(language: String) async {
        do {
            // The streaming variants are English-only (see ParakeetCatalog); a
            // non-English fixed language is a configuration the engine can't
            // honor. "auto" and en* proceed; anything else errors up front
            // rather than silently transcribing to English.
            if let message = ParakeetLanguageGate.refusalMessage(languageSetting: language) {
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

            let manager = try await ensureLoaded()
            try await manager.reset()

            generation += 1
            let myGeneration = generation

            // Partials arrive on the manager's actor; hop to main and gate on
            // generation before touching session state.
            await manager.setPartialTranscriptCallback { [weak self] text in
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
            feedTask = Task { [weak self] in
                do {
                    for await buffer in stream {
                        // appendAudio accepts any format (resamples to 16 kHz
                        // mono internally); processBufferedAudio decodes any
                        // complete chunks and fires the partial callback.
                        try await manager.appendAudio(buffer)
                        try await manager.processBufferedAudio()
                    }
                } catch {
                    NSLog("[Parakeet] stream feed error: %@", error.localizedDescription)
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == myGeneration, !self.didStop else { return }
                        self.onError?("Parakeet streaming failed: \(error.localizedDescription)")
                    }
                }
            }

            // The tap closure runs on an audio thread but touches no session
            // state — it only yields the buffer (ordered, single tap thread)
            // and publishes a level.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.feedBuffer(buffer)
                self?.publishLevel(from: buffer)
            }

            audioEngine = engine
            engine.prepare()
            try engine.start()
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

        guard let manager else { return }
        if cancel {
            try? await manager.reset()
            return
        }
        do {
            // finish() flushes remaining audio through the model and returns
            // the final transcript.
            let final = try await manager.finish()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onFinal?(final.isEmpty ? lastPartial : final)
        } catch {
            NSLog("[Parakeet] finish error: %@", error.localizedDescription)
            // Fall back to the last partial rather than erroring the session —
            // the user's words are already on screen in preview mode.
            onFinal?(lastPartial)
        }
    }

    /// Kick a background model load/download so selecting the engine (not the
    /// first dictation) pays the one-time HuggingFace download. Idempotent.
    func prefetch() {
        MainActor.assumeIsolated {
            _ = loadTaskOnMain()
        }
    }

    private nonisolated func feedBuffer(_ buffer: AVAudioPCMBuffer) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.feedContinuation?.yield(buffer)
            }
        }
    }

    @discardableResult
    private func ensureLoaded() async throws -> ParakeetBridge.Manager {
        if let manager = await currentManager() { return manager }
        let task = await loadTaskOnMain()
        do {
            let manager = try await task.value
            await storeManager(manager)
            return manager
        } catch {
            await clearFailedLoad(task)
            throw error
        }
    }

    @MainActor private func currentManager() -> ParakeetBridge.Manager? { manager }
    @MainActor private func storeManager(_ m: ParakeetBridge.Manager) { manager = m }

    @MainActor
    private func clearFailedLoad(_ failed: Task<ParakeetBridge.Manager, Error>) {
        if inFlightLoad == failed { inFlightLoad = nil }
    }

    @MainActor
    private func loadTaskOnMain() -> Task<ParakeetBridge.Manager, Error> {
        if let existing = inFlightLoad { return existing }
        let variant = variantID
        let task = Task<ParakeetBridge.Manager, Error> {
            NSLog("[Parakeet] loading variant '%@'…", variant)
            let manager = try await ParakeetBridge.load(variantID: variant)
            NSLog("[Parakeet] variant loaded.")
            return manager
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
        onError?("The Parakeet engine isn't available in this build. Rebuild with PARAKEET=1 (see docs/PARAKEET_SPIKE.md).")
    }

    func stop(cancel: Bool) {}

    func prefetch() {}

#endif
}
