import Foundation
import AVFoundation
import Speech

final class AppleSpeechEngine: StreamingTranscriptionEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?
    var onStarted: (() -> Void)?

    // AVAudioEngine / recognizer handles. Touched only on the main actor (start and
    // stop are @MainActor-only callers — see the note below), so they stay confined
    // alongside the session-state fields.
    @MainActor private var audioEngine: AVAudioEngine?
    @MainActor private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @MainActor private var recognitionTask: SFSpeechRecognitionTask?
    @MainActor private var recognizer: SFSpeechRecognizer?

    // --- Session state ---
    //
    // These four fields are the shared mutable state the recognition callback used
    // to race on. The `SFSpeechRecognitionTask` result closure runs on an ARBITRARY
    // Speech-framework thread; if it read/wrote these directly it would race with
    // start()/stop() on the main actor (MAK-29). They are now @MainActor-isolated,
    // and the callback hops onto the main actor before touching any of them — the
    // generation gate then reads a coherent value, and `lastPartial` is never stored
    // from two threads at once. `text` is captured locally in the callback, so the
    // only value crossing threads is that immutable String.
    @MainActor private var lastPartial = ""
    @MainActor private var didStop = false
    /// True once onFinal has fired for the current session (genuine or
    /// synthesized) — the stop() fallback checks it before synthesizing.
    @MainActor private var finalDelivered = false
    /// Session generation, bumped on every start() AND on stop(cancel: true).
    /// stop(cancel: false) leaves the recognition task running so it can deliver
    /// its genuine final; the generation check keeps that orphaned task's late
    /// callbacks (and the synthesized-final fallback) from leaking into the next
    /// session. The cancel-time bump matters because a cancelled task can still
    /// dispatch a result between the cancel and the next start() — without it,
    /// that callback would pass the gate and be attributed to the new session.
    @MainActor private var generation = 0

    /// Pinned input-device UID for the next session ("" = system default). Applied
    /// per-engine in `start()`; no global default mutation needed because Apple
    /// Speech uses its own `AVAudioEngine` whose input node we can retarget directly.
    @MainActor private var selectedDeviceID = ""

    func selectDevice(_ deviceID: String) {
        // Callers are @MainActor (AppState); pinning is a plain main-actor store.
        MainActor.assumeIsolated {
            selectedDeviceID = deviceID
        }
    }

    static func requestAuthorization(_ completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status)
            }
        }
    }

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func start(language: String) throws {
        // All callers are @MainActor (AppState). assumeIsolated documents and enforces
        // that invariant so the @MainActor session state below can be touched without
        // an async hop (which would let two rapid start/stop calls reorder). The same
        // pattern is used by WhisperKitStreamingEngine.
        try MainActor.assumeIsolated {
            try runStart(language: language)
        }
    }

    @MainActor
    private func runStart(language: String) throws {
        stop(cancel: true)

        generation += 1
        didStop = false
        finalDelivered = false
        lastPartial = ""

        let localeIdentifier = language == "auto" ? Locale.current.identifier : language
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        guard let recognizer else {
            throw AppleSpeechError.unavailable("Apple Speech does not support \(localeIdentifier).")
        }
        guard recognizer.isAvailable else {
            throw AppleSpeechError.unavailable("Apple Speech is not currently available.")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Route to the selected input device BEFORE reading the format (the format
        // follows the device). A non-empty selection that can't be resolved is a
        // hard error — never silently fall back to the system default (that was the
        // bug where picking a non-default mic still captured the built-in one).
        switch AudioInputRoutingPolicy.decide(
            microphoneID: selectedDeviceID,
            deviceResolved: AudioInputRouter.canResolve(uid: selectedDeviceID)
        ) {
        case .systemDefault:
            break                                   // input node already follows the default
        case .useDevice(let uid):
            // Resolved above; a nil here or a setDeviceID failure is still a hard
            // error — don't fall through to the default node.
            guard let device = AudioInputRouter.resolve(uid: uid),
                  AudioInputRouter.apply(device, to: engine) else {
                throw AppleSpeechError.unavailable(AudioInputRoutingPolicy.unresolvedMessage(uid: uid))
            }
        case .unresolved(let uid):
            throw AppleSpeechError.unavailable(AudioInputRoutingPolicy.unresolvedMessage(uid: uid))
        }

        let format = input.outputFormat(forBus: 0)
        // With no input device the format is 0 Hz / 0 ch and installTap raises
        // an ObjC NSException that Swift try/catch can't intercept (app crash).
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppleSpeechError.unavailable("No audio input device available.")
        }

        // The tap closure runs on an audio thread but touches no shared session
        // state — it only appends the buffer to the (thread-safe) request and reads
        // the buffer to publish a level. Nothing here races with start()/stop().
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.publishLevel(from: buffer)
        }

        let myGeneration = generation
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // This closure runs on an ARBITRARY Speech-framework thread. Capture the
            // immutable result/error values locally and hop onto the main actor before
            // touching ANY session state — that is what makes the generation gate and
            // the lastPartial store race-free (MAK-29). `text` is the only value that
            // crosses the thread boundary; the shared fields never do.
            //
            // The hop uses DispatchQueue.main.async, not an unstructured Task: the main
            // queue preserves submission order (FIFO), so partials are applied in the
            // same order SFSpeechRecognizer delivers them from its serial callback.
            // (Separately-created Tasks carry no ordering guarantee — a reordered pair
            // could let lastPartial regress and make the 0.8s stop-fallback synthesize a
            // final from a stale partial.) The main queue IS the MainActor executor, so
            // MainActor.assumeIsolated inside it is sound and lets the body touch the
            // @MainActor session state synchronously.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == myGeneration else { return }

                    if let text {
                        self.lastPartial = text
                        self.onPartial?(text)
                        if isFinal, !self.finalDelivered {
                            self.finalDelivered = true
                            self.onFinal?(text)
                        }
                    }

                    if let errorDescription, !self.didStop {
                        self.onError?(errorDescription)
                    }
                }
            }
        }

        audioEngine = engine
        recognitionRequest = request
        self.recognizer = recognizer

        engine.prepare()
        try engine.start()
        // The tap is installed and the AVAudioEngine is running — capture is
        // live NOW. This engine's start is fully synchronous, so the signal
        // fires before runStart returns (unlike the chained engines).
        onStarted?()
    }

    func stop(cancel: Bool = false) {
        // Callers are @MainActor (AppState); the session state below is main-confined.
        MainActor.assumeIsolated {
            runStop(cancel: cancel)
        }
    }

    @MainActor
    private func runStop(cancel: Bool) {
        didStop = true

        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        if cancel {
            // Invalidate the session NOW, not at the next start(): the cancelled
            // task's already-dispatched callbacks (and any main-queue hops still
            // in flight) must fail the generation gate immediately.
            generation += 1
            recognitionTask?.cancel()
        } else {
            recognitionRequest?.endAudio()
            // Leave the task running: its genuine final (post-endAudio, often
            // containing trailing words absent from the last partial) is
            // preferred. Only synthesize a final from the latest partial if it
            // hasn't arrived after a grace period. The engine owns final
            // delivery — an empty final is delivered too (no-speech sessions
            // produce no genuine final because the recognizer reports that as
            // an error, swallowed after didStop), so the session always ends
            // without leaning on AppState's watchdog. The generation check
            // drops the fallback if a new session started meanwhile.
            recognitionTask?.finish()
            let myGeneration = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == myGeneration, !self.finalDelivered else { return }
                    self.finalDelivered = true
                    self.onFinal?(self.lastPartial)
                }
            }
        }

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        recognizer = nil
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
            // fromRMS is the absolute curve, so display and VAD levels coincide.
            self.onLevelChanged?(normalized, normalized)
        }
    }
}

enum AppleSpeechError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}
