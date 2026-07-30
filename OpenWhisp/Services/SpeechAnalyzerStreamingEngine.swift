import Foundation
import AVFoundation
import Speech

/// Apple SpeechAnalyzer-backed `StreamingTranscriptionEngine` (macOS 26, MAK-59).
///
/// The live-dictation variant of the SpeechAnalyzer engine: `AppState` routes
/// here only when a live output mode is selected (StreamingRoutePolicy) — the
/// recorded-file path uses `SpeechAnalyzerFileEngine`. Structurally it mirrors
/// `AppleSpeechEngine` (the legacy SFSpeechRecognizer streamer): an
/// `AVAudioEngine` mic tap feeds audio, partial/final hypotheses and levels come
/// back via callbacks, and session state is `@MainActor`-confined with a
/// generation fence so late callbacks from a torn-down session can't leak.
///
/// The difference: audio is pushed into an `AnalyzerInput` `AsyncStream` (the
/// SpeechAnalyzer contract) instead of an `SFSpeechAudioBufferRecognitionRequest`,
/// and results carry `isFinal` (volatile vs finalized) rather than a task-level
/// final. Auto-punctuating and fully on-device; ASR-only (no translate).
///
/// All Speech-framework calls are behind `if #available(macOS 26, *)`, so the
/// type compiles and links on macOS 14/15 — where the engine is hidden and, if
/// reached, `start()` throws an unavailability error.
// NSObject so the AVAudioEngineConfigurationChange observer can be
// selector-based (the block API takes a hard `@Sendable` closure whose captures
// here are non-Sendable) — same shape as ParakeetStreamingEngine.
final class SpeechAnalyzerStreamingEngine: NSObject, StreamingTranscriptionEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?
    var onStarted: (() -> Void)?

    // Mic + analyzer handles, main-actor confined (start/stop are @MainActor).
    @MainActor private var audioEngine: AVAudioEngine?
    @MainActor private var recognitionTask: Task<Void, Never>?
    @MainActor private var selectedDeviceID = ""

    // --- Session state (mirrors AppleSpeechEngine's fence) ---
    @MainActor private var lastPartial = ""
    /// The latest VOLATILE (not yet finalized) hypothesis text. SpeechTranscriber
    /// finalizes lazily — typically a sentence behind the speech — so at hotkey
    /// release the trailing sentence is usually still volatile. The delivered
    /// final must include it (the partial preview already showed it); dropping
    /// it loses the user's last words. Cleared when a finalized result
    /// supersedes it.
    @MainActor private var lastVolatile = ""
    @MainActor private var finalDelivered = false
    @MainActor private var generation = 0
    /// True while a settle-check for a configuration-change notification is
    /// already scheduled — further notifications in that window coalesce into
    /// the pending check instead of stacking checks (a storm posts several).
    @MainActor private var configChangeCheckPending = false
    /// Capture rebuilds performed for the CURRENT capture session; reset in
    /// `runStart`. Compared against `CaptureConfigChangePolicy.maxRestartsPerSession`.
    @MainActor private var configRestartsThisSession = 0

    /// What the mid-session configuration-change restart needs to rebuild capture
    /// into the live analyzer stream (see `armConfigChangeObserver`). Non-nil
    /// exactly while the observer is armed; cleared on every teardown path.
    @MainActor private var restartContext: RestartContext?

    private struct RestartContext {
        let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
        let myGeneration: Int
    }

    func selectDevice(_ deviceID: String) {
        MainActor.assumeIsolated { selectedDeviceID = deviceID }
    }

    func start(language: String, prompt: String) throws {
        // `prompt` carries the whisper-shaped (comma-joined) vocabulary + screen-
        // context bias terms. MAK-84 wires them into SpeechAnalyzer's
        // contextual-strings context (see runStart), so this is the `.all`
        // vocabulary declaration for speechAnalyzer in EngineCapabilities —
        // offered iff honored, on the streaming path too.
        try MainActor.assumeIsolated {
            try runStart(language: language, prompt: prompt)
        }
    }

    @MainActor
    private func runStart(language: String, prompt: String) throws {
        stop(cancel: true)

        guard SpeechAnalyzerAvailability.isSupportedOS else {
            throw SpeechAnalyzerBridge.BridgeError.unavailableOS
        }

        generation += 1
        finalDelivered = false
        lastPartial = ""
        lastVolatile = ""
        configRestartsThisSession = 0
        let myGeneration = generation

        // Compile gate: the analyzer code below needs the macOS 26 SDK. On older
        // toolchains isSupportedOS above is always false, so this is unreachable —
        // the #else keeps the compiler satisfied about the throwing path.
        #if compiler(>=6.2)
        guard #available(macOS 26, *) else {
            throw SpeechAnalyzerBridge.BridgeError.unavailableOS
        }

        let (engine, micFormat) = try makeRoutedEngine()

        // RAW mic-buffer stream: the tap pushes untouched mic-format buffers; the
        // recognition task converts each to the ANALYZER'S required format before
        // wrapping it in AnalyzerInput. SpeechAnalyzer traps (EXC_BREAKPOINT in
        // SpeechRecognizerWorker.preRunRecognition) when fed audio that isn't in
        // its `bestAvailableAudioFormat` — the mic's native format almost never
        // is — so conversion is a correctness requirement, not an optimization.
        // (The file path is immune: `analyzeSequence(from: AVAudioFile)` converts
        // internally.)
        let (rawStream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)

        // Drive the analyzer on a detached task; hop to the main actor to publish
        // partial/final under the generation fence.
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (transcriber, _) = try await SpeechAnalyzerBridge.prepareTranscriber(
                    languageSetting: language)
                let analyzer = SpeechAnalyzer(modules: [transcriber])

                // Custom-vocabulary biasing (MAK-84): attach the bias terms via the
                // analyzer's contextual-strings context BEFORE start(inputSequence:).
                // Empty prompt → empty context → the plain unbiased path.
                try await analyzer.setContext(SpeechAnalyzerBridge.makeContext(prompt: prompt))

                // Resolve the analyzer's required input format and build the
                // converter OFF the tap thread. A nil format means no module can
                // take audio at all — fail fast with a readable error instead of
                // letting the framework trap later.
                guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber])
                else {
                    throw SpeechAnalyzerBridge.BridgeError.noResult
                }
                // Fail fast when the start-time mic format can't reach the
                // analyzer format at all — feeding unconverted audio would trap
                // the framework (see the raw-stream comment above).
                if analyzerFormat != micFormat,
                   AVAudioConverter(from: micFormat, to: analyzerFormat) == nil {
                    throw SpeechAnalyzerBridge.BridgeError.unsupportedLocale(
                        "mic format \(micFormat) can't convert to the analyzer format")
                }
                // Per-buffer ADAPTIVE conversion, not one converter pinned to
                // `micFormat`: after a mid-session capture restart (see
                // `armConfigChangeObserver`) the replacement device's format
                // usually differs, and a converter pinned to the start-time
                // format would reject — drop — every buffer from the new device:
                // capture restarted, transcript still silently dead.
                let converter = AdaptiveFormatConverter(analyzerFormat: analyzerFormat)
                let inputStream = rawStream.compactMap { buffer -> AnalyzerInput? in
                    guard let converted = converter.convert(buffer)
                    else { return nil } // drop an unconvertible buffer, never trap
                    return AnalyzerInput(buffer: converted)
                }
                try await analyzer.start(inputSequence: inputStream)

                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run {
                        guard self.generation == myGeneration else { return }
                        if isFinal {
                            // Accumulate finalized segments; the finalized text
                            // supersedes the volatile hypothesis it replaces.
                            self.lastVolatile = ""
                            let combined = self.appendFinalized(text)
                            self.onPartial?(combined)
                        } else {
                            self.lastVolatile = text
                            self.onPartial?(self.lastPartial + text)
                        }
                    }
                }
                // Stream ended (endAudio): deliver the finalized transcript.
                await MainActor.run {
                    guard self.generation == myGeneration, !self.finalDelivered else { return }
                    self.finalDelivered = true
                    self.onFinal?(self.finalWithVolatileTail())
                }
            } catch {
                await MainActor.run {
                    guard self.generation == myGeneration else { return }
                    if !self.finalDelivered {
                        self.onError?(error.localizedDescription)
                    }
                }
            }
        }

        try startCapture(
            engine: engine, format: micFormat,
            continuation: continuation, myGeneration: myGeneration)
        // Model load can lag the tap install; onStarted signals genuine capture.
        // The tap is installed and the engine is running, so fire it now.
        onStarted?()
        #else
        throw SpeechAnalyzerBridge.BridgeError.unavailableOS
        #endif
    }

    /// Build a fresh AVAudioEngine routed to the pinned (or default) input and
    /// return it with its tap format. Shared by session start and the
    /// mid-session configuration-change restart. Same policy as
    /// AppleSpeechEngine: a disconnected pinned device falls back to the system
    /// default; a connected one that fails to route is a hard error.
    @MainActor
    private func makeRoutedEngine() throws -> (AVAudioEngine, AVAudioFormat) {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Route BEFORE reading the format (the format follows the device).
        switch AudioInputRoutingPolicy.decide(
            microphoneID: selectedDeviceID,
            deviceResolved: AudioInputRouter.canResolve(uid: selectedDeviceID)
        ) {
        case .systemDefault:
            break
        case .useDevice(let uid):
            guard let device = AudioInputRouter.resolve(uid: uid),
                  AudioInputRouter.apply(device, to: engine) else {
                throw SpeechAnalyzerBridge.BridgeError.unsupportedLocale(
                    AudioInputRoutingPolicy.unresolvedMessage(uid: uid))
            }
        case .fallbackToDefault(let uid):
            NSLog("[SpeechAnalyzerStreamingEngine] pinned mic '%@' disconnected — capturing system default", uid)
        }

        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw SpeechAnalyzerBridge.BridgeError.unsupportedLocale("no audio input device")
        }
        return (engine, micFormat)
    }

    /// Install the tap on `engine`, start it, and arm the configuration-change
    /// observer. Shared by session start and the mid-session restart — both
    /// yield into the SAME raw-buffer stream, so the analyzer sees one
    /// continuous sample sequence (the adaptive converter absorbs a format
    /// change across the restart).
    @MainActor
    private func startCapture(
        engine: AVAudioEngine,
        format: AVAudioFormat,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        myGeneration: Int
    ) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            continuation.yield(buffer)
            self?.publishLevel(from: buffer)
        }
        audioEngine = engine
        engine.prepare()
        try engine.start()
        armConfigChangeObserver(for: engine, continuation: continuation, myGeneration: myGeneration)
    }

    /// Converts tap buffers to the analyzer's required format, REBUILDING the
    /// converter whenever the incoming format changes (a mid-session capture
    /// restart lands on a device with a different native format).
    ///
    /// `@unchecked Sendable` because the `compactMap` transform that owns it is
    /// `@Sendable`: the mutable converter is touched only from the recognition
    /// task's SEQUENTIAL stream consumption (one buffer at a time, in order),
    /// so there is no concurrent access to lock against.
    private final class AdaptiveFormatConverter: @unchecked Sendable {
        private let analyzerFormat: AVAudioFormat
        private var converter: AVAudioConverter?

        init(analyzerFormat: AVAudioFormat) {
            self.analyzerFormat = analyzerFormat
        }

        /// nil when the buffer can't be represented in the analyzer format
        /// (converter build or conversion failure) — the caller drops it.
        func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            if buffer.format == analyzerFormat { return buffer } // feed as-is
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            }
            guard let converter else { return nil }
            return SpeechAnalyzerStreamingEngine.convert(buffer, with: converter, to: analyzerFormat)
        }
    }

    /// Watch for the input device disconnecting / switching / renegotiating its
    /// format mid-session. AVAudioEngine STOPS rendering when that happens, so
    /// without this the session keeps showing "Listening…" while capturing
    /// nothing — every word after the change is silently lost. Capture is
    /// REBUILT onto the same raw-buffer stream: the analyzer keeps everything
    /// already captured and the dictation continues, losing only the glitch
    /// itself. Rebuild failure (e.g. no input device left) surfaces on the
    /// session error path. Same pattern as ParakeetStreamingEngine.
    @MainActor
    private func armConfigChangeObserver(
        for engine: AVAudioEngine,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        myGeneration: Int
    ) {
        removeConfigChangeObserver()
        restartContext = RestartContext(continuation: continuation, myGeneration: myGeneration)
        // Selector-based on purpose: the block observer API takes a hard
        // `@Sendable` closure, and every capture it needs (self, the
        // continuation) is non-Sendable — the selector target keeps the compile
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
    /// the session state lives. Same hop shape as the result callbacks.
    @objc private func inputConfigurationDidChange(_ note: Notification) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handleInputConfigurationChange() }
        }
    }

    /// Do NOT restart here — schedule a settle-check instead. Restarting on
    /// every notification was the v1.0.12 dead-mic regression (Parakeet, PR
    /// #227): the notification also fires for changes our own teardown+rebuild
    /// causes, so a reflexive handler loops teardown→rebuild→notification
    /// forever and the mic never captures. The settle delay coalesces the storm
    /// and lets the io unit finish renegotiating; the check then rebuilds only
    /// if the engine actually STOPPED.
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
        // Same session fence as the result hops: a stop or a newer session owns
        // the mic now — touch nothing. This engine has no didStop flag;
        // `finalDelivered` is its "session over" marker (a cancel bumps the
        // generation instead). Teardown also clears the context.
        guard let context = restartContext else { return }
        switch CaptureConfigChangePolicy.action(
            generationMatches: generation == context.myGeneration,
            didStop: finalDelivered,
            engineStillRunning: audioEngine?.isRunning ?? false,
            restartsUsed: configRestartsThisSession
        ) {
        case .ignore:
            return
        case .restartCapture:
            configRestartsThisSession += 1
            NSLog("[SpeechAnalyzerStreamingEngine] capture stopped after an input configuration change — restarting (%d/%d)",
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
                    continuation: context.continuation, myGeneration: context.myGeneration)
            } catch {
                onError?(CaptureConfigChangePolicy.restartFailedMessage(
                    underlying: error.localizedDescription))
            }
        case .giveUp:
            NSLog("[SpeechAnalyzerStreamingEngine] input device keeps stopping capture after %d rebuilds — giving up",
                  configRestartsThisSession)
            removeConfigChangeObserver()
            if let stale = audioEngine {
                stale.inputNode.removeTap(onBus: 0)
                stale.stop()
            }
            audioEngine = nil
            onError?(CaptureConfigChangePolicy.gaveUpMessage)
        }
    }

    /// Convert one mic-format buffer to the analyzer's required format. Returns
    /// nil (caller drops the buffer) on any conversion failure — a dropped chunk
    /// degrades the transcript; an unconverted chunk traps the Speech framework.
    /// (Plain AVFoundation, so it compiles on every toolchain — no compiler gate.)
    private static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, out.frameLength > 0 else { return nil }
        return out
    }

    /// Append a finalized segment to the running transcript and return the whole.
    @MainActor
    private func appendFinalized(_ segment: String) -> String {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return lastPartial }
        lastPartial = lastPartial.isEmpty ? trimmed : lastPartial + " " + trimmed
        return lastPartial
    }

    /// The transcript to deliver as the final: every finalized segment plus the
    /// trailing volatile hypothesis (joined the same way `appendFinalized` joins
    /// segments). The analyzer is never explicitly finalized on stop, so without
    /// the tail any session with at least one finalized segment would lose its
    /// last (still-volatile) sentence — text the live preview already showed.
    @MainActor
    private func finalWithVolatileTail() -> String {
        let tail = lastVolatile.trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return lastPartial }
        return lastPartial.isEmpty ? tail : lastPartial + " " + tail
    }

    func stop(cancel: Bool) {
        MainActor.assumeIsolated { runStop(cancel: cancel) }
    }

    @MainActor
    private func runStop(cancel: Bool) {
        removeConfigChangeObserver()
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil

        if cancel {
            // Invalidate NOW so any in-flight result hops fail the fence.
            generation += 1
            recognitionTask?.cancel()
            recognitionTask = nil
        } else {
            // Deliver the accumulated final (finalized segments + volatile tail).
            // The results loop may also deliver one when the stream ends; the
            // finalDelivered guard keeps it single.
            let myGeneration = generation
            if !finalDelivered {
                finalDelivered = true
                onFinal?(finalWithVolatileTail())
            }
            // Let the task wind down; its late final is fenced out by the guard.
            let task = recognitionTask
            recognitionTask = nil
            Task { @MainActor in
                guard self.generation == myGeneration else { return }
                task?.cancel()
            }
        }
    }

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sum += sample * sample
            }
        }
        let divisor = Float(max(1, channelCount * frameCount))
        let rms = sqrt(sum / divisor)
        let normalized = AudioLevel.fromRMS(rms)
        DispatchQueue.main.async {
            self.onLevelChanged?(normalized, normalized)
        }
    }
}
