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
final class SpeechAnalyzerStreamingEngine: StreamingTranscriptionEngine {
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
    @MainActor private var finalDelivered = false
    @MainActor private var generation = 0

    func selectDevice(_ deviceID: String) {
        MainActor.assumeIsolated { selectedDeviceID = deviceID }
    }

    func start(language: String) throws {
        try MainActor.assumeIsolated {
            try runStart(language: language)
        }
    }

    @MainActor
    private func runStart(language: String) throws {
        stop(cancel: true)

        guard SpeechAnalyzerAvailability.isSupportedOS else {
            throw SpeechAnalyzerBridge.BridgeError.unavailableOS
        }

        generation += 1
        finalDelivered = false
        lastPartial = ""
        let myGeneration = generation

        // Compile gate: the analyzer code below needs the macOS 26 SDK. On older
        // toolchains isSupportedOS above is always false, so this is unreachable —
        // the #else keeps the compiler satisfied about the throwing path.
        #if compiler(>=6.2)
        guard #available(macOS 26, *) else {
            throw SpeechAnalyzerBridge.BridgeError.unavailableOS
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Route to the pinned input device BEFORE reading the format (same policy
        // as AppleSpeechEngine — a non-empty unresolved selection is a hard error,
        // never a silent fallback to the built-in mic).
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
        case .unresolved(let uid):
            throw SpeechAnalyzerBridge.BridgeError.unsupportedLocale(
                AudioInputRoutingPolicy.unresolvedMessage(uid: uid))
        }

        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw SpeechAnalyzerBridge.BridgeError.unsupportedLocale("no audio input device")
        }

        // The AnalyzerInput stream: the mic tap pushes buffers into `continuation`,
        // the analyzer consumes them on its own actor.
        let (inputStream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            continuation.yield(AnalyzerInput(buffer: buffer))
            self?.publishLevel(from: buffer)
        }

        // Drive the analyzer on a detached task; hop to the main actor to publish
        // partial/final under the generation fence.
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (transcriber, _) = try await SpeechAnalyzerBridge.prepareTranscriber(
                    languageSetting: language)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                try await analyzer.start(inputSequence: inputStream)

                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run {
                        guard self.generation == myGeneration else { return }
                        if isFinal {
                            // Accumulate finalized segments; volatile results
                            // update the tail preview only.
                            let combined = self.appendFinalized(text)
                            self.onPartial?(combined)
                        } else {
                            self.onPartial?(self.lastPartial + text)
                        }
                    }
                }
                // Stream ended (endAudio): deliver the finalized transcript.
                await MainActor.run {
                    guard self.generation == myGeneration, !self.finalDelivered else { return }
                    self.finalDelivered = true
                    self.onFinal?(self.lastPartial)
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

        audioEngine = engine
        engine.prepare()
        try engine.start()
        // Model load can lag the tap install; onStarted signals genuine capture.
        // The tap is installed and the engine is running, so fire it now.
        onStarted?()
        #else
        throw SpeechAnalyzerBridge.BridgeError.unavailableOS
        #endif
    }

    /// Append a finalized segment to the running transcript and return the whole.
    @MainActor
    private func appendFinalized(_ segment: String) -> String {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return lastPartial }
        lastPartial = lastPartial.isEmpty ? trimmed : lastPartial + " " + trimmed
        return lastPartial
    }

    func stop(cancel: Bool) {
        MainActor.assumeIsolated { runStop(cancel: cancel) }
    }

    @MainActor
    private func runStop(cancel: Bool) {
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
            // Deliver the accumulated final. The results loop may also deliver one
            // when the stream ends; the finalDelivered guard keeps it single.
            let myGeneration = generation
            if !finalDelivered {
                finalDelivered = true
                onFinal?(lastPartial)
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
