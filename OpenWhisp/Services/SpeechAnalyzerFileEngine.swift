import Foundation

/// Apple SpeechAnalyzer-backed `FileTranscriptionEngine` (macOS 26, MAK-59).
///
/// This is the PRIMARY SpeechAnalyzer path — the biggest, lowest-risk win in the
/// ticket. Every FILE job (meetings, the FileTranscriptionQueue, watch folders,
/// history re-transcribe) builds its engine via `AppState.makeFileEngine`, so
/// routing "speechAnalyzer" here gives every non-live path the on-device,
/// auto-punctuating analyzer (~2× faster than Whisper on files).
///
/// Live *dictation* uses `SpeechAnalyzerStreamingEngine` when a live output mode
/// is selected; this engine is the recorded-WAV path.
///
/// Like `WhisperKitEngine`/`ParakeetFileEngine`, the whisper-specific
/// `binaryPath`/`modelPath`/`backend`/`prompt` params are ignored — SpeechAnalyzer
/// is a single on-device model. Language is honored as a locale ("auto" = current
/// locale). ASR-only: it never receives the translate sentinel (LanguageResolver
/// suppresses it for this engine).
///
/// The Speech-framework calls are all behind `if #available(macOS 26, *)` via
/// `SpeechAnalyzerBridge`, so this file compiles and runs on macOS 14/15 — where
/// the engine is hidden from the picker and, if somehow reached, reports its
/// unavailability rather than crashing.
final class SpeechAnalyzerFileEngine: FileTranscriptionEngine {
    var onTranscriptionComplete: ((UUID, String) -> Void)?
    var onTranscriptionError: ((UUID, String) -> Void)?
    var onProgress: ((Int) -> Void)?
    var onWorkerStatus: ((String) -> Void)?

    init() {}

    func warmServer(binaryPath: String, modelPath: String) {
        // No external server. "Warm" = provision the on-device locale model up
        // front so the first file/meeting job doesn't pay the asset install.
        guard SpeechAnalyzerAvailability.isSupportedOS else {
            onWorkerStatus?("Apple SpeechAnalyzer needs macOS 26")
            return
        }
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let status = onWorkerStatus
            Task {
                do {
                    status?("Preparing SpeechAnalyzer model…")
                    _ = try await SpeechAnalyzerBridge.prepareTranscriber(languageSetting: "auto")
                    status?("SpeechAnalyzer ready")
                } catch {
                    status?("SpeechAnalyzer unavailable: \(error.localizedDescription)")
                }
            }
        }
        #endif
    }

    func stopServer() {
        // Nothing persistent to tear down (the analyzer is created per request).
    }

    func transcribe(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool,
        backend: WhisperBackend,
        prompt: String
    ) {
        guard SpeechAnalyzerAvailability.isSupportedOS else {
            if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
            onTranscriptionError?(
                requestID,
                "Apple SpeechAnalyzer requires macOS 26 or later. Pick another engine in Settings."
            )
            return
        }

        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await SpeechAnalyzerBridge.transcribeFile(
                        wavURL: URL(fileURLWithPath: wavPath),
                        languageSetting: language,
                        // MAK-84: custom-vocabulary + screen-context bias terms,
                        // whisper-shaped (comma-joined) — the bridge splits them
                        // into SpeechAnalyzer's contextual strings. Honored because
                        // EngineCapabilities declares speechAnalyzer vocabulary .all.
                        prompt: prompt
                    )
                    if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                    await MainActor.run { self.onTranscriptionComplete?(requestID, text) }
                } catch {
                    NSLog("[SpeechAnalyzer] file transcription failed: %@", error.localizedDescription)
                    if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                    await MainActor.run {
                        self.onTranscriptionError?(
                            requestID, "SpeechAnalyzer failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        #endif
    }
}
