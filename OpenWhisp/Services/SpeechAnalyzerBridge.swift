import Foundation
import AVFoundation
import Speech

/// Thin wrapper over the macOS 26 SpeechAnalyzer / SpeechTranscriber API
/// (Speech framework, MAK-59), shared by the file and streaming engines.
///
/// Everything that touches the new symbols is guarded by `if #available(macOS 26,
/// *)` and lives behind `@available` so the app still compiles/runs on macOS
/// 14/15 — the picker hides the engine there (`SpeechAnalyzerAvailability`), and
/// these entry points fail fast with a clear message if reached anyway.
///
/// SpeechAnalyzer is fully on-device and auto-punctuating. Unlike the legacy
/// `SFSpeechRecognizer` path (`AppleSpeechEngine`), it does NOT use
/// `SFSpeechRecognizer.requestAuthorization` — model assets are provisioned via
/// `AssetInventory`. It is ASR-only (no translate task).
enum SpeechAnalyzerBridge {

    enum BridgeError: LocalizedError {
        case unavailableOS
        case unsupportedLocale(String)
        case noResult

        var errorDescription: String? {
            switch self {
            case .unavailableOS:
                return "Apple SpeechAnalyzer requires macOS 26 or later."
            case .unsupportedLocale(let id):
                return "Apple SpeechAnalyzer does not support “\(id)”."
            case .noResult:
                return "Apple SpeechAnalyzer produced no transcript."
            }
        }
    }

    /// Resolve the user's language setting ("auto" = current locale) to a Locale
    /// SpeechAnalyzer supports, installing its assets on demand. Pure enough to
    /// share between paths; the caller is already gated on the OS.
    @available(macOS 26, *)
    static func prepareTranscriber(languageSetting: String) async throws -> (SpeechTranscriber, Locale) {
        let requested = languageSetting == "auto" || languageSetting.isEmpty
            ? Locale.current
            : Locale(identifier: languageSetting.replacingOccurrences(of: "_", with: "-"))

        // Snap to the closest supported locale (region-agnostic fallback).
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
            ?? (languageSetting == "auto" || languageSetting.isEmpty ? Locale.current : nil)
        guard let locale = resolved else {
            throw BridgeError.unsupportedLocale(requested.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],           // batch/final path: no volatile partials
            attributeOptions: []
        )

        // Provision the on-device model for this locale if not already installed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        return (transcriber, locale)
    }

    /// File/batch transcription: analyze a whole WAV and return the finished,
    /// auto-punctuated transcript. Runs on macOS 26 only.
    @available(macOS 26, *)
    static func transcribeFile(wavURL: URL, languageSetting: String) async throws -> String {
        let (transcriber, _) = try await prepareTranscriber(languageSetting: languageSetting)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect finalized results concurrently with feeding the file, so the
        // results stream is being drained while analysis runs.
        let collector = Task { () -> String in
            var pieces = AttributedString()
            for try await result in transcriber.results {
                pieces.append(result.text)
            }
            return String(pieces.characters)
        }

        let audioFile = try AVAudioFile(forReading: wavURL)
        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = try await collector.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
