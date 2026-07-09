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
    var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?

    /// WhisperKit model id (its own namespace). Defaults to the staged `small`
    /// (multilingual EN+RU) — the same model the file engine uses.
    private let modelName: String

    /// Pinned input-device UID for the next session ("" = system default).
    ///
    /// Unlike Apple Speech, WhisperKit 1.0.0 owns the mic through
    /// `AudioStreamTranscriber` → `AudioProcessor.startRecordingLive()`, which is
    /// called with NO device (an internal API in a pinned remote dependency we can't
    /// patch). WhisperKit's engine setup binds whatever the SYSTEM DEFAULT input is
    /// at start. So the only way to route it to the selected device is to swap the
    /// system default around stream start and restore it — see `deviceOverride`.
    private var selectedDeviceID = ""

    func selectDevice(_ deviceID: String) {
        selectedDeviceID = deviceID
    }

    init(modelName: String = "openai_whisper-small") {
        self.modelName = modelName
    }

#if WHISPERKIT

    private var loadedKit: WhisperKitHandle?
    @MainActor private var inFlightLoad: Task<WhisperKitHandle, Error>?

    // The running stream. The transcriber drives the mic and pushes state diffs to
    // `handleState`. Touched only on the main actor (via the serialized chain).
    @MainActor private var transcriber: WhisperKitStreamHandle?

    // Live system-default-input swap for the current session (nil when routing to the
    // system default). Engaged just before the stream starts and restored once the
    // engine is bound to the device (or on any teardown/error path). Main-actor only.
    @MainActor private var deviceOverride: AudioInputRouter.DefaultInputOverride?

    // Last confirmed transcript we emitted as a partial — used so we only forward
    // forward-progress (monotonic confirmed text), avoiding paste churn from the
    // unconfirmed/hypothesis tail.
    @MainActor private var lastConfirmedText: String = ""
    @MainActor private var didFinish: Bool = false

    /// Stream generation, bumped when a stream starts (runStart) and when one is
    /// torn down (runStop). Each stream's state callback captures its own
    /// generation and drops itself once superseded — otherwise a state diff
    /// already hopping to the main actor when stop ran would land in the NEXT
    /// session (didFinish alone can't catch that: start() resets it to false
    /// before the stale hop is delivered).
    @MainActor private var generation = 0

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
            // Strong capture on purpose: the chain must keep the engine alive until
            // its lifecycle work completes. AppState may drop its (only) reference
            // right after stop() (e.g. rebuildFileEngine swaps the engine), and a
            // weak self here would dealloc the engine before the queued teardown
            // runs — leaving the mic streaming forever. The Task releases the
            // closure when it finishes, so this is not a retain cycle.
            self.lifecycle.enqueue {
                await self.runStart(task: task)
            }
        }
    }

    /// The start pipeline, run inside the serialized lifecycle chain (so any prior
    /// stop's teardown has already completed — no installTap race, no sleep needed).
    @MainActor
    private func runStart(task: WhisperKitTaskMapper.Resolved) async {
        do {
            // Route to the selected input device. WhisperKit binds the SYSTEM DEFAULT
            // input when its engine starts (no per-engine device seam in 1.0.0), so a
            // pinned device requires swapping the default around stream start and
            // restoring it once the engine is bound. An unresolved pinned device is a
            // hard error — never silently capture the default.
            //
            // RESOLVE here (fail fast before the possibly-slow model load) but ENGAGE
            // the swap only after ensureLoaded() below — the global default must not
            // stay changed for the whole model load (cold start can be seconds), only
            // for the brief window until the capture engine binds the device.
            let deviceToRoute: AudioDevice?
            switch AudioInputRoutingPolicy.decide(
                microphoneID: selectedDeviceID,
                deviceResolved: AudioInputRouter.canResolve(uid: selectedDeviceID)
            ) {
            case .systemDefault:
                deviceToRoute = nil
            case .useDevice(let uid):
                deviceToRoute = AudioInputRouter.resolve(uid: uid)
            case .unresolved(let uid):
                onError?(AudioInputRoutingPolicy.unresolvedMessage(uid: uid))
                return
            }

            let kit = try await ensureLoaded()
            generation += 1
            let myGeneration = generation
            let handle = try WhisperKitBridge.makeStreamHandle(
                kit: kit,
                task: task,
                languageOverride: nil
            ) { [weak self] newState in
                Task { @MainActor in
                    guard let self, self.generation == myGeneration else { return }
                    self.handleState(newState)
                }
            }
            transcriber = handle

            // Engage the default swap NOW (model loaded; the stream is about to grab
            // the mic). Restored once the engine binds the device (poll below) or on
            // any teardown/error path.
            if let device = deviceToRoute {
                let override = AudioInputRouter.DefaultInputOverride()
                if override.engage(device) { deviceOverride = override }
            }
            // `start()` runs the realtime loop until stopped; it returns when the
            // stream ends. Don't block the chain on it (a stop must be able to run),
            // so drive it in a detached child whose lifetime the stop tears down.
            // Startup failures (AVAudioEngine won't start, input device gone, tap
            // failure) throw from start() — surface them instead of leaving the
            // session silently dead behind a "Listening..." UI. Guard on the handle
            // still being current: a late failure from a torn-down session must not
            // fire onError into a newly started one.
            Task { @MainActor [weak self] in
                do {
                    try await handle.start()
                } catch {
                    NSLog("[WhisperKitStream] stream error: %@", error.localizedDescription)
                    guard let self, self.transcriber === handle, !self.didFinish else { return }
                    self.restoreDeviceOverride()   // startup failed; undo the default swap
                    self.onError?("WhisperKit streaming failed: \(error.localizedDescription)")
                }
            }
            // Restore the system default promptly once WhisperKit's engine is bound to
            // the (now-default) device: the AudioUnit holds its CurrentDevice after
            // start, so the global default can go back with no effect on capture. This
            // keeps the user's default changed for a sub-second window, not the whole
            // session. Falls through to runStop's restore if the engine never binds.
            if deviceOverride != nil {
                restoreOverrideWhenCaptureLive(handle: handle, generation: myGeneration)
            }
        } catch {
            NSLog("[WhisperKitStream] start error: %@", error.localizedDescription)
            restoreDeviceOverride()
            guard !didFinish else { return }
            onError?("WhisperKit streaming failed: \(error.localizedDescription)")
        }
    }

    /// Poll (bounded) for WhisperKit's capture engine to start, then restore the
    /// system-default-input override. The device binding survives the restore. If the
    /// engine never comes up within the budget the override is left for `runStop` to
    /// restore, so the default is never stranded.
    @MainActor
    private func restoreOverrideWhenCaptureLive(handle: WhisperKitStreamHandle, generation: Int) {
        Task { @MainActor [weak self] in
            // ~2s budget at 50ms granularity: engine start is normally tens of ms;
            // this only needs to outlast a slow cold start of the AVAudioEngine graph.
            for _ in 0..<40 {
                guard let self, self.generation == generation, self.transcriber === handle,
                      !self.didFinish else { return }
                if handle.isCapturing() {
                    self.restoreDeviceOverride()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Restore the system default input if this session swapped it. Idempotent.
    @MainActor
    private func restoreDeviceOverride() {
        deviceOverride?.restore()
        deviceOverride = nil
    }

    func stop(cancel: Bool) {
        // Synchronous main-actor enqueue (see start) so stop→start order is preserved.
        MainActor.assumeIsolated {
            // Strong capture (see start): teardown must run even if the caller drops
            // its reference to this engine immediately after enqueueing the stop.
            self.lifecycle.enqueue {
                await self.runStop(cancel: cancel)
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
        // Safety net: if the stream ended before the capture-live poll restored the
        // system default (very short session, or the engine never bound), restore it
        // now so the user's default input is never left changed. Idempotent.
        restoreDeviceOverride()
        // Supersede the stream's generation so state callbacks it already
        // dispatched are dropped — they must not fire onPartial into whatever
        // session starts next. The final below is unaffected: it's computed
        // directly from the handle, not delivered through the state callback.
        generation += 1
        await handle?.stop()
        if !cancel {
            // Flush the undecoded tail first: the realtime loop only decodes once
            // ≥1 s of new audio accumulates, so a quick hotkey release strands the
            // last words (for refine, the whole spoken instruction) in the buffer.
            // finalizeTail() decodes them; nil = everything was already decoded.
            // Falls back to the assembled transcript (confirmed + unconfirmed).
            let full = await handle?.finalizeTail() ?? handle?.fullText() ?? ""
            let final = full.isEmpty ? lastConfirmedText : full
            onFinal?(final.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Translate a WhisperKit stream state into our callbacks.
    @MainActor
    private func handleState(_ state: WhisperKitStreamState) {
        if let level = state.peakEnergy {
            // vadLevel is the absolute-curve reading; the display level's
            // silence-referenced scale must never reach the fixed VAD gates.
            // (Fallback only for the rare startup tick before audioEnergy fills.)
            onLevelChanged?(level, state.vadLevel ?? level)
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
