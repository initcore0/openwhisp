import Foundation
import AVFoundation
import Speech

final class AppleSpeechEngine: StreamingTranscriptionEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?
    
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var lastPartial = ""
    private var didStop = false
    /// True once onFinal has fired for the current session (genuine or
    /// synthesized) — the stop() fallback checks it before synthesizing.
    private var finalDelivered = false
    /// Session generation, bumped on every start() AND on stop(cancel: true).
    /// stop(cancel: false) leaves the recognition task running so it can deliver
    /// its genuine final; the generation check keeps that orphaned task's late
    /// callbacks (and the synthesized-final fallback) from leaking into the next
    /// session. The cancel-time bump matters because a cancelled task can still
    /// dispatch a result between the cancel and the next start() — without it,
    /// that callback would pass the gate and be attributed to the new session.
    private var generation = 0
    
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
        let format = input.outputFormat(forBus: 0)
        // With no input device the format is 0 Hz / 0 ch and installTap raises
        // an ObjC NSException that Swift try/catch can't intercept (app crash).
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppleSpeechError.unavailable("No audio input device available.")
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.publishLevel(from: buffer)
        }

        let myGeneration = generation
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.generation == myGeneration else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                self.lastPartial = text
                DispatchQueue.main.async {
                    guard self.generation == myGeneration else { return }
                    self.onPartial?(text)
                    if result.isFinal, !self.finalDelivered {
                        self.finalDelivered = true
                        self.onFinal?(text)
                    }
                }
            }

            if let error, !self.didStop {
                DispatchQueue.main.async {
                    guard self.generation == myGeneration else { return }
                    self.onError?(error.localizedDescription)
                }
            }
        }
        
        audioEngine = engine
        recognitionRequest = request
        self.recognizer = recognizer
        
        engine.prepare()
        try engine.start()
    }
    
    func stop(cancel: Bool = false) {
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
                guard let self, self.generation == myGeneration, !self.finalDelivered else { return }
                self.finalDelivered = true
                self.onFinal?(self.lastPartial)
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
