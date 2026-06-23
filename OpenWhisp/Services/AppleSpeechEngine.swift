import Foundation
import AVFoundation
import Speech

final class AppleSpeechEngine: StreamingTranscriptionEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onLevelChanged: ((Float) -> Void)?
    
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var lastPartial = ""
    private var didStop = false
    
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
        
        didStop = false
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
        
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.publishLevel(from: buffer)
        }
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            
            if let result {
                let text = result.bestTranscription.formattedString
                self.lastPartial = text
                DispatchQueue.main.async {
                    self.onPartial?(text)
                    if result.isFinal {
                        self.onFinal?(text)
                    }
                }
            }
            
            if let error, !self.didStop {
                DispatchQueue.main.async {
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
            recognitionTask?.cancel()
        } else {
            recognitionRequest?.endAudio()
            let finalText = lastPartial
            if !finalText.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.onFinal?(finalText)
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
        let normalized = max(0, min(1, rms * 8))
        DispatchQueue.main.async {
            self.onLevelChanged?(normalized)
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
