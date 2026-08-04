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
final class ParakeetStreamingEngine: NSObject, StreamingTranscriptionEngine {
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

    /// Fires on the main actor whenever the model's readiness changes (MAK-94):
    /// `.downloading` → `.loading` → `.ready`/`.failed`. This is the signal that
    /// makes the previously invisible cold-start wait observable — the pre-MAK-94
    /// code could only see "a prefetch is in flight", which conflated the
    /// first-run download with the several-second CoreML load that happens on
    /// EVERY launch. The owner (`ModelReadinessTracker`, outside AppState)
    /// forwards it into a `@Published`.
    ///
    /// Set by whoever owns the engine instance; nil for every other caller.
    @MainActor var onReadinessChanged: ((EngineReadiness) -> Void)?

    /// Whether a loaded streaming session is resident right now — the one true
    /// "can start capturing without waiting" signal for Parakeet.
    @MainActor var isSessionLoaded: Bool {
#if PARAKEET
        session != nil
#else
        false
#endif
    }

    /// ParakeetCatalog variant id (see ParakeetCatalog).
    private let variantID: String

    /// Emit a readiness transition to the owner (main-actor hop already implied
    /// by the annotation). Kept tiny so both build flavors share it.
    @MainActor
    func reportReadiness(_ readiness: EngineReadiness) {
        onReadinessChanged?(readiness)
    }

    /// Pinned input-device UID for the next session ("" = system default).
    @MainActor private var selectedDeviceID = ""

    func selectDevice(_ deviceID: String) {
        MainActor.assumeIsolated {
            selectedDeviceID = deviceID
        }
    }

    init(variantID: String = ParakeetCatalog.defaultVariantID) {
        self.variantID = ParakeetCatalog.normalize(variantID)
        super.init()
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
    /// What the config-change restart needs to rebuild capture into the live
    /// session (see `armConfigChangeObserver`). Non-nil exactly while the
    /// observer is armed; cleared on every teardown path.
    @MainActor private var restartContext: RestartContext?

    private struct RestartContext {
        let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
        let callbacks: SessionCallbacks
        let myGeneration: Int
    }

    @MainActor private var lastPartial = ""
    @MainActor private var didStop = false
    /// Non-cancel stops enqueued whose `runStop` hasn't completed yet — the
    /// engine is still working toward a genuine final (feed drain + `finish()`
    /// flush). A counter, not a bool: on a fast stop→start→stop, session N+1's
    /// stop is already counted while session N's runStop is still queued, and
    /// N's completion must not clear N+1's pending finalize.
    @MainActor private var pendingFinalizeStops = 0

    /// True while a non-cancel stop is still draining/flushing toward its final.
    /// Read by AppState's stuck-session fallback; main-actor callers only (same
    /// contract as `selectDevice`).
    var isFinalizing: Bool {
        MainActor.assumeIsolated { pendingFinalizeStops > 0 }
    }
    /// True while a settle-check for a configuration-change notification is
    /// already scheduled — further notifications in that window coalesce into
    /// the pending check instead of stacking checks (a storm posts several).
    @MainActor private var configChangeCheckPending = false
    /// Capture rebuilds performed for the CURRENT capture session; reset in
    /// `runStart`. Compared against `CaptureConfigChangePolicy.maxRestartsPerSession`.
    @MainActor private var configRestartsThisSession = 0
    /// Session generation, bumped on every start and stop — late partial
    /// callbacks from a torn-down session fail the gate instead of leaking into
    /// the next one (same rationale as the other streaming engines).
    @MainActor private var generation = 0
    /// Serialized start/stop lifecycle so a stop's mic teardown always completes
    /// before the next start installs its tap (see SerialTaskChain).
    @MainActor private let lifecycle = SerialTaskChain()

    /// The session-bound callbacks a `runStart` fires, snapshotted at ENQUEUE
    /// time. `runStart` can sit awaiting a model load while a cancel+restart
    /// rebinds the engine's callback properties to the NEXT session — reading
    /// them at fire time would deliver this (superseded) start's signals with
    /// the successor's sessionID, sailing through AppState's session fence and
    /// flipping the new session to "Listening" while its own teardown+start are
    /// still queued behind this one (words spoken then are dropped — the exact
    /// bug the capture-started signal exists to close). The snapshot keeps the
    /// old session's identity, so the fence drops the stray signal.
    private struct SessionCallbacks {
        let started: (() -> Void)?
        let partial: ((String) -> Void)?
        let eou: (() -> Void)?
        let error: ((String) -> Void)?
    }

    func start(language: String, prompt: String) throws {
        // `prompt` (vocabulary bias terms) is intentionally ignored here: Parakeet
        // biases only on the batch path via FluidAudio's CTC-WS spotter (MAK-71),
        // which needs the full log-prob matrix over complete audio — the live
        // stream has no such pass. This is a DECLARED no-op, not a silent drop:
        // EngineCapabilities.vocabularySupport(parakeet) == .batchOnly, so
        // honorsStreamingVocabulary is false and AppState never hands us a
        // non-empty prompt on this path. See TranscriptionEngine.start's contract.
        //
        // All callers are @MainActor (AppState); synchronous enqueue preserves
        // call order (a stop() immediately followed by start() must serialize).
        MainActor.assumeIsolated {
            // Snapshot BEFORE the enqueue: these are still this session's own
            // bindings here; by the time runStart runs (or resumes from an
            // await) they may belong to a successor session.
            let callbacks = SessionCallbacks(
                started: self.onStarted, partial: self.onPartial,
                eou: self.onEouDetected, error: self.onError)
            // Strong capture on purpose: the chain must keep the engine alive
            // until its lifecycle work completes (see WhisperKitStreamingEngine).
            self.lifecycle.enqueue {
                await self.runStart(language: language, callbacks: callbacks)
            }
        }
    }

    @MainActor
    private func runStart(language: String, callbacks: SessionCallbacks) async {
        // Reset per-session flags ON the serialized chain, not at enqueue time:
        // a fast stop→start enqueues runStop BEFORE this runStart, and its
        // didStop=true must not poison the new session (an enqueue-time reset
        // would run first and then be clobbered by the queued runStop).
        lastPartial = ""
        didStop = false
        configRestartsThisSession = 0
        do {
            // Variant-aware language gate: English-only variants refuse a FIXED
            // non-English language up front (never silently mangle it); the
            // multilingual variant accepts any language ("auto" for unknowns).
            if let message = ParakeetLanguageGate.refusalMessage(
                languageSetting: language,
                multilingual: ParakeetCatalog.isMultilingual(variantID)
            ) {
                callbacks.error?(message)
                return
            }

            // Route + format-check BEFORE the (potentially slow) model load, so a
            // missing input device fails fast instead of after a first-run download.
            let engine: AVAudioEngine
            let format: AVAudioFormat
            do {
                (engine, format) = try makeRoutedEngine()
            } catch let setupError as CaptureSetupError {
                callbacks.error?(setupError.message)
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
                        callbacks.partial?(trimmed)
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
                                    callbacks.eou?()
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
                        self.removeConfigChangeObserver()
                        if let audioEngine = self.audioEngine {
                            audioEngine.inputNode.removeTap(onBus: 0)
                            audioEngine.stop()
                        }
                        self.audioEngine = nil
                        self.feedContinuation?.finish()
                        self.feedContinuation = nil
                        callbacks.error?("Parakeet streaming failed: \(error.localizedDescription)")
                    }
                }
            }

            try startCapture(
                engine: engine, format: format,
                continuation: continuation, callbacks: callbacks,
                myGeneration: myGeneration)
            // Tap installed + AVAudioEngine running: audio is flowing into the
            // feed stream. Everything above (model load/first-run download,
            // reset, callback wiring) was the arming gap this signal closes.
            callbacks.started?()
        } catch {
            NSLog("[Parakeet] start error: %@", error.localizedDescription)
            guard !didStop else { return }
            callbacks.error?("Parakeet streaming failed: \(error.localizedDescription)")
        }
    }

    /// Setup failure with a user-facing message (routing refused, no input
    /// device). `LocalizedError` so a generic `localizedDescription` still
    /// reads as the message.
    private struct CaptureSetupError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Build a fresh AVAudioEngine routed to the pinned (or default) input and
    /// return it with its tap format. Shared by session start and the
    /// mid-session configuration-change restart.
    @MainActor
    private func makeRoutedEngine() throws -> (AVAudioEngine, AVAudioFormat) {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Route to the selected input device BEFORE reading the format.
        // A pinned but disconnected device falls back to the system default;
        // a connected device that fails to route stays a hard error (same
        // policy as Apple Speech).
        switch AudioInputRoutingPolicy.decide(
            microphoneID: selectedDeviceID,
            deviceResolved: AudioInputRouter.canResolve(uid: selectedDeviceID)
        ) {
        case .systemDefault:
            break
        case .useDevice(let uid):
            guard let device = AudioInputRouter.resolve(uid: uid),
                  AudioInputRouter.apply(device, to: engine) else {
                throw CaptureSetupError(message: AudioInputRoutingPolicy.unresolvedMessage(uid: uid))
            }
        case .fallbackToDefault(let uid):
            NSLog("[ParakeetStreamingEngine] pinned mic '%@' disconnected — capturing system default", uid)
        }

        let format = input.outputFormat(forBus: 0)
        // 0 Hz / 0 ch (no input device) would make installTap raise an ObjC
        // NSException that Swift can't catch — guard it out.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureSetupError(message: "No audio input device available.")
        }
        return (engine, format)
    }

    /// Install the feed tap on `engine`, start it, and arm the
    /// configuration-change observer. Shared by session start and the
    /// mid-session restart — both feed the SAME continuation, so the decode
    /// session sees one continuous sample stream.
    @MainActor
    private func startCapture(
        engine: AVAudioEngine,
        format: AVAudioFormat,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        callbacks: SessionCallbacks,
        myGeneration: Int
    ) throws {
        // The tap closure runs on an audio thread but touches no session
        // state — AsyncStream.Continuation.yield is Sendable + thread-safe,
        // so it yields straight from the audio thread (no main-actor hop
        // per buffer) and publishes a level.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            continuation.yield(buffer)
            self?.publishLevel(from: buffer)
        }
        audioEngine = engine
        engine.prepare()
        try engine.start()
        armConfigChangeObserver(
            for: engine, continuation: continuation,
            callbacks: callbacks, myGeneration: myGeneration)
    }

    /// Watch for the input device disconnecting / switching / renegotiating its
    /// format mid-session. AVAudioEngine STOPS rendering when that happens, so
    /// without this the session keeps showing "Listening…" while capturing
    /// nothing — every word after the change is silently lost (AudioRecorder
    /// has the same observer; the streaming engines lacked it). Unlike the
    /// recorder's fail-only handling, capture is REBUILT onto the same feed
    /// stream: the decode session keeps everything already captured and the
    /// dictation continues, losing only the glitch itself. Rebuild failure
    /// (e.g. no input device left) surfaces on the session error path.
    @MainActor
    private func armConfigChangeObserver(
        for engine: AVAudioEngine,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        callbacks: SessionCallbacks,
        myGeneration: Int
    ) {
        removeConfigChangeObserver()
        restartContext = RestartContext(
            continuation: continuation, callbacks: callbacks, myGeneration: myGeneration)
        // Selector-based on purpose: the block observer API takes a hard
        // `@Sendable` closure, and every capture it needs (self, the session
        // callbacks) is non-Sendable — the selector target keeps the compile
        // warning-free and the context lives in `restartContext` instead.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputConfigurationDidChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine)
    }

    @MainActor
    private func removeConfigChangeObserver() {
        NotificationCenter.default.removeObserver(
            self, name: .AVAudioEngineConfigurationChange, object: nil)
        restartContext = nil
    }

    /// Fires on the notification-posting thread; hop to the main actor where
    /// the session state lives. Same hop shape as the partial callback.
    @objc private func inputConfigurationDidChange(_ note: Notification) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handleInputConfigurationChange() }
        }
    }

    /// Do NOT restart here — schedule a settle-check instead. Restarting on
    /// every notification was the v1.0.12 dead-mic regression: the notification
    /// also fires for changes our own teardown+rebuild causes (on some systems
    /// capture start itself posts one), so a reflexive handler loops
    /// teardown→rebuild→notification forever (~4/s) and the mic never captures.
    /// The settle delay coalesces the storm and lets the io unit finish
    /// renegotiating; the check then rebuilds only if the engine actually
    /// STOPPED (the real device-loss case this observer exists for).
    @MainActor
    private func handleInputConfigurationChange() {
        guard restartContext != nil, !configChangeCheckPending else { return }
        configChangeCheckPending = true
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(CaptureConfigChangePolicy.settleDelay * 1_000_000_000))
            self.configChangeCheckPending = false
            self.settleCheckConfigurationChange()
        }
    }

    @MainActor
    private func settleCheckConfigurationChange() {
        // Same session fence as the partial/EOU hops: a stop or a newer session
        // owns the mic now — touch nothing. (Teardown also clears the context.)
        guard let context = restartContext else { return }
        switch CaptureConfigChangePolicy.action(
            generationMatches: generation == context.myGeneration,
            didStop: didStop,
            engineStillRunning: audioEngine?.isRunning ?? false,
            restartsUsed: configRestartsThisSession
        ) {
        case .ignore:
            return
        case .restartCapture:
            configRestartsThisSession += 1
            NSLog("[Parakeet] capture stopped after an input configuration change — restarting (%d/%d)",
                  configRestartsThisSession, CaptureConfigChangePolicy.maxRestartsPerSession)
            removeConfigChangeObserver()
            // The session fence held, so audioEngine is the engine the observer
            // was armed for (re-arms replace the observer and context together).
            if let stale = audioEngine {
                stale.inputNode.removeTap(onBus: 0)
                stale.stop()
            }
            audioEngine = nil
            do {
                let (fresh, format) = try makeRoutedEngine()
                try startCapture(
                    engine: fresh, format: format,
                    continuation: context.continuation, callbacks: context.callbacks,
                    myGeneration: context.myGeneration)
            } catch {
                context.callbacks.error?(CaptureConfigChangePolicy.restartFailedMessage(
                    underlying: error.localizedDescription))
            }
        case .giveUp:
            NSLog("[Parakeet] input device keeps stopping capture after %d rebuilds — giving up",
                  configRestartsThisSession)
            removeConfigChangeObserver()
            if let stale = audioEngine {
                stale.inputNode.removeTap(onBus: 0)
                stale.stop()
            }
            audioEngine = nil
            context.callbacks.error?(CaptureConfigChangePolicy.gaveUpMessage)
        }
    }

    func stop(cancel: Bool) {
        MainActor.assumeIsolated {
            // Snapshot the final callback at ENQUEUE time, mirroring start()'s
            // SessionCallbacks: runStop can sit in the chain behind a slow
            // session.finish() while AppState admits the next session and
            // rebinds onFinal to it — a fire-time read would deliver THIS
            // session's final with the successor's sessionID, straight through
            // AppState's session fence.
            let final = self.onFinal
            // Report "finalizing" from ENQUEUE until runStop completes, so the
            // stuck-session fallback (StreamingRoutePolicy.runStopFallback) keeps
            // waiting for the genuine final instead of completing the session
            // with the stale last partial while the feed drain / finish() flush
            // runs — enqueue time matters because runStop can sit behind a slow
            // predecessor in the chain.
            if !cancel { self.pendingFinalizeStops += 1 }
            self.lifecycle.enqueue {
                await self.runStop(cancel: cancel, final: final)
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
    private func runStop(cancel: Bool, final deliverFinal: ((String) -> Void)?) async {
        // Balance stop(cancel:false)'s increment on EVERY exit path (no-session
        // early return, finish() error): the fallback poll must see finalizing
        // end even when no final gets delivered — its grace poll then fires the
        // stale-partial completion instead of wedging the session.
        defer { if !cancel { pendingFinalizeStops = max(0, pendingFinalizeStops - 1) } }
        didStop = true
        // Supersede the session so late partial hops are dropped.
        generation += 1

        removeConfigChangeObserver()
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
            // finish() decodes a ZERO-PADDED final window with the right-context
            // holdback disabled, so the RNNT decoder runs into digital silence and
            // reliably appends a stray "You". Strip it here — on
            // the final only, since the artifact is produced by that final flush
            // and never appears in a partial. See ParakeetTailHallucination for
            // the guards that keep a legitimate "…up to you" intact.
            let deartifacted = ParakeetTailHallucination.strip(from: final)
            deliverFinal?(deartifacted.isEmpty ? lastPartial : deartifacted)
        } catch {
            NSLog("[Parakeet] finish error: %@", error.localizedDescription)
            // Fall back to the last partial rather than erroring the session —
            // the user's words are already on screen in preview mode.
            deliverFinal?(lastPartial)
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
        // Already resident: nothing to wait through — say so and return, so a
        // redundant warm (e.g. after rebuildFileEngine) can't push the UI back
        // into a "loading" it isn't doing.
        if session != nil {
            reportReadiness(.ready)
            return true
        }
        // MAK-94: report the phase we're about to enter. FluidAudio downloads
        // into the variant's repo folder and only then compiles + loads the
        // CoreML session, so "files verified complete" is the honest
        // download/load split — and it's the LOAD that the user hits on every
        // launch after the first. Verified completeness, not folder presence: a
        // torn first-run download leaves a folder that FluidAudio's presence
        // gate accepts but that still has a (re)download ahead of it.
        // Real fractions replace the nil the moment the downloader reports.
        let onDisk = FluidAudioModelsLocator.verdict(forVariant: variantID) == .complete
        reportReadiness(onDisk ? .loading : .downloading(progress: nil))
        // Route through ensureLoaded so a FAILED load clears `inFlightLoad`
        // (clearFailedLoad) before the error is swallowed — otherwise a failed
        // download poisons the cache and later prefetches no-op forever.
        // ensureLoaded reports the terminal readiness edge (.ready/.failed)
        // itself, so the lazy session-start path stays in sync too.
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
            // Terminal readiness edge here (not only in prefetchAwaiting) so a
            // LAZY load — first dictation triggering the download — also lands
            // the menu/overlay on .ready instead of a stale "Downloading…".
            await reportReadiness(.ready)
            return session
        } catch {
            await clearFailedLoad(task)
            // Cancellation is a variant switch replacing this engine, not a
            // failure of the model — reporting it would flash a bogus error
            // (and the successor engine re-reports through its own callback).
            if !(error is CancellationError) {
                await reportReadiness(.failed(error.localizedDescription))
            }
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
        // Whole-percent throttle (ParakeetProgressThrottle, shared with the
        // batch engine) so per-byte-chunk reports don't flood the main actor.
        let throttle = ParakeetProgressThrottle()
        // Forward real download/compile progress into the readiness stream
        // (menu row + onboarding bar). Weak: a replaced engine must not keep
        // reporting into the tracker.
        let onProgress: @Sendable (ParakeetLoadPhase) -> Void = { [weak self] phase in
            switch phase {
            case .downloading(let fraction):
                guard throttle.shouldReport(fraction) else { return }
                Task { @MainActor [weak self] in
                    self?.reportReadiness(.downloading(progress: fraction))
                }
            case .compiling:
                Task { @MainActor [weak self] in
                    self?.reportReadiness(.loading)
                }
            }
        }
        let task = Task<any ParakeetStreamSession, Error> {
            NSLog("[Parakeet] loading variant '%@'…", variant)
            do {
                let session = try await ParakeetBridge.loadStreamSession(
                    variantID: variant, onProgress: onProgress)
                NSLog("[Parakeet] variant loaded.")
                return session
            } catch let error as ParakeetBridgeError {
                // Corrupt-cache repair (the fresh-install trap): the repo folder
                // exists — so FluidAudio's presence gate will skip the download
                // forever — but the model can't load (torn/interrupted first-run
                // download). Purge the variant's repo and redownload once, inside
                // the single-flight task so concurrent waiters share one repair.
                // A download error is NOT repairable by deleting bytes, and
                // cancellation never reaches here (it stays untyped).
                guard case .load(let underlying) = error,
                      let folder = ParakeetDownloadStatePolicy.repoFolder(forVariant: variant),
                      FluidAudioModelsLocator.installedFolders().contains(folder)
                else { throw error }
                NSLog(
                    "[Parakeet] load failed with model files present (%@) — purging '%@' and redownloading once",
                    underlying, folder)
                try? FluidAudioModelsLocator.removeRepoFolder(folder)
                Task { @MainActor [weak self] in
                    self?.reportReadiness(.downloading(progress: nil))
                }
                let session = try await ParakeetBridge.loadStreamSession(
                    variantID: variant, onProgress: onProgress)
                NSLog("[Parakeet] variant loaded after cache repair.")
                return session
            }
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

    func start(language: String, prompt: String) throws {
        onError?("The Parakeet engine isn't available in this build. Rebuild with PARAKEET=1 (see docs/PARAKEET.md).")
    }

    func stop(cancel: Bool) {}

    @discardableResult
    func prefetchAwaiting() async -> Bool {
        // Lean build (PARAKEET=0): there is no engine to load. Report the failure
        // so readiness settles on `.failed` instead of spinning at `.loading`.
        await MainActor.run {
            reportReadiness(.failed("this build was made without the Parakeet engine"))
        }
        return false
    }

    @MainActor
    func cancelLoading() {}

#endif
}
