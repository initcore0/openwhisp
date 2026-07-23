import Foundation
import CoreAudio   // AudioDeviceID (the input-device id threaded to WhisperKit)

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
    var onStarted: (() -> Void)?
    /// Declared no-op: WhisperKit can translate itself, so the dual-runtime path
    /// (which gates on `EngineCapabilities.providesAudioTap == false` here) never
    /// tees from it. Present only to satisfy the protocol.
    var onAudioBuffer: (([Float]) -> Void)?

    /// WhisperKit model id (its own namespace). Defaults to the staged `small`
    /// (multilingual EN+RU) — the same model the file engine uses.
    private let modelName: String

    /// Pinned input-device UID for the next session ("" = system default). Resolved
    /// to a CoreAudio device in `runStart` and passed straight into WhisperKit's
    /// `AudioStreamTranscriber(inputDeviceID:)` (our fork backports upstream #503's
    /// passthrough), so capture targets the device directly — no system-default swap.
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

    // Last confirmed transcript we emitted as a partial — used so we only forward
    // forward-progress (monotonic confirmed text), avoiding paste churn from the
    // unconfirmed/hypothesis tail.
    @MainActor private var lastConfirmedText: String = ""
    @MainActor private var didFinish: Bool = false
    /// Whether this stream's `onStarted` already fired. AudioStreamTranscriber
    /// installs the tap inside `handle.start()`, which doesn't return until the
    /// stream ENDS — so the first state diff (they arrive per buffer, energy
    /// updates included, even in silence) is the earliest proof the engine is
    /// consuming audio. Reset per stream in `runStart`.
    @MainActor private var startedNotified: Bool = false

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

    func start(language: String, prompt: String) throws {
        let task = WhisperKitTaskMapper.map(languageSetting: language)
        // Enqueue SYNCHRONOUSLY on the main actor so call order == enqueue order
        // (a stop() immediately followed by start() must serialize in that order).
        // All callers are @MainActor (AppState); an outer Task hop here would let two
        // rapid calls reorder. assumeIsolated documents and enforces that invariant.
        MainActor.assumeIsolated {
            self.lastConfirmedText = ""
            self.didFinish = false
            // Snapshot the session-bound callbacks at ENQUEUE time (see
            // SessionCallbacks): runStart can sit awaiting the model load while a
            // cancel+restart rebinds these properties to the NEXT session, and a
            // fire-time read would deliver this superseded start's signals with
            // the successor's sessionID — through AppState's session fence.
            let callbacks = SessionCallbacks(
                started: self.onStarted, partial: self.onPartial,
                level: self.onLevelChanged, error: self.onError)
            // Strong capture on purpose: the chain must keep the engine alive until
            // its lifecycle work completes. AppState may drop its (only) reference
            // right after stop() (e.g. rebuildFileEngine swaps the engine), and a
            // weak self here would dealloc the engine before the queued teardown
            // runs — leaving the mic streaming forever. The Task releases the
            // closure when it finishes, so this is not a retain cycle.
            self.lifecycle.enqueue {
                await self.runStart(task: task, prompt: prompt, callbacks: callbacks)
            }
        }
    }

    /// Session-bound callbacks snapshotted when the start was enqueued, so a
    /// superseded start fires the OLD session's closures (whose stale sessionID
    /// the AppState fence drops) instead of leaking "started"/partials/errors
    /// into the successor session. Same fix as ParakeetStreamingEngine.
    private struct SessionCallbacks {
        let started: (() -> Void)?
        let partial: ((String) -> Void)?
        let level: ((_ display: Float, _ vad: Float) -> Void)?
        let error: ((String) -> Void)?
    }

    /// The start pipeline, run inside the serialized lifecycle chain (so any prior
    /// stop's teardown has already completed — no installTap race, no sleep needed).
    @MainActor
    private func runStart(task: WhisperKitTaskMapper.Resolved, prompt: String, callbacks: SessionCallbacks) async {
        do {
            // Resolve the selected input device. It's passed straight into
            // AudioStreamTranscriber(inputDeviceID:) (our WhisperKit fork backports
            // upstream #503), which forwards it to startRecordingLive — WhisperKit
            // captures the chosen device directly, no system-default swap needed. A
            // pinned but DISCONNECTED device falls back to the system default so the
            // session can run (the AirPods-disconnect hang); a CONNECTED device that
            // fails to resolve at application time stays a hard error.
            let inputDeviceID: AudioDeviceID?
            switch AudioInputRoutingPolicy.decide(
                microphoneID: selectedDeviceID,
                deviceResolved: AudioInputRouter.canResolve(uid: selectedDeviceID)
            ) {
            case .systemDefault:
                inputDeviceID = nil
            case .useDevice(let uid):
                // Resolve to the concrete device id. A nil here (device vanished
                // between canResolve and now) is treated as unresolved — a hard error,
                // NOT a silent nil that would fall back to the system default.
                guard let id = AudioInputRouter.resolve(uid: uid)?.deviceID else {
                    callbacks.error?(AudioInputRoutingPolicy.unresolvedMessage(uid: uid))
                    return
                }
                inputDeviceID = id
            case .fallbackToDefault(let uid):
                NSLog("[WhisperKitStreamingEngine] pinned mic '%@' disconnected — capturing system default", uid)
                inputDeviceID = nil
            }

            let kit = try await ensureLoaded()
            generation += 1
            startedNotified = false
            let myGeneration = generation
            let handle = try WhisperKitBridge.makeStreamHandle(
                kit: kit,
                task: task,
                languageOverride: nil,
                inputDeviceID: inputDeviceID,
                prompt: prompt
            ) { [weak self] newState in
                Task { @MainActor in
                    guard let self, self.generation == myGeneration else { return }
                    self.handleState(newState, callbacks: callbacks)
                }
            }
            transcriber = handle
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
                    callbacks.error?("WhisperKit streaming failed: \(error.localizedDescription)")
                }
            }
        } catch {
            NSLog("[WhisperKitStream] start error: %@", error.localizedDescription)
            guard !didFinish else { return }
            callbacks.error?("WhisperKit streaming failed: \(error.localizedDescription)")
        }
    }

    func stop(cancel: Bool) {
        // Synchronous main-actor enqueue (see start) so stop→start order is preserved.
        MainActor.assumeIsolated {
            // Snapshot the final callback at ENQUEUE time, mirroring start()'s
            // SessionCallbacks: runStop can sit in the chain behind a slow
            // finalizeTail while AppState admits the next session and rebinds
            // onFinal to it — a fire-time read would deliver THIS session's
            // final with the successor's sessionID, straight through AppState's
            // session fence.
            let final = self.onFinal
            // Strong capture (see start): teardown must run even if the caller drops
            // its reference to this engine immediately after enqueueing the stop.
            self.lifecycle.enqueue {
                await self.runStop(cancel: cancel, final: final)
            }
        }
    }

    /// The stop pipeline, run inside the serialized lifecycle chain. Awaiting the
    /// transcriber's `stop()` here is what guarantees the mic/input node is released
    /// before any queued start proceeds.
    @MainActor
    private func runStop(cancel: Bool, final deliverFinal: ((String) -> Void)?) async {
        let handle = transcriber
        transcriber = nil
        didFinish = true
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
            deliverFinal?(final.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Translate a WhisperKit stream state into our callbacks.
    @MainActor
    private func handleState(_ state: WhisperKitStreamState, callbacks: SessionCallbacks) {
        // First state diff for this stream = capture is live (tap installed,
        // buffers flowing). Fires before any partial from the same diff so the
        // session leaves arming before text starts arriving.
        if !startedNotified {
            startedNotified = true
            callbacks.started?()
        }
        if let level = state.peakEnergy {
            // vadLevel is the absolute-curve reading; the display level's
            // silence-referenced scale must never reach the fixed VAD gates.
            // (Fallback only for the rare startup tick before audioEnergy fills.)
            callbacks.level?(level, state.vadLevel ?? level)
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
        callbacks.partial?(text)
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

    func start(language: String, prompt: String) throws {
        onError?("WhisperKit backend isn't available in this build. Rebuild with WHISPERKIT=1 (see docs/WHISPERKIT_PILOT.md).")
    }

    func stop(cancel: Bool) {}

#endif
}
