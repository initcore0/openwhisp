// SpeechAnalyzer bench harness (MAK-79). macOS 26 only.
//
// SpeechAnalyzerBridge.transcribeFile is app-target code whose containing file
// pulls the vocabulary-bias chain (ParakeetVocabularyPrompt, …). Rather than
// link that graph, this harness inlines the SAME file-transcription call the
// bridge makes (SpeechAnalyzer + SpeechTranscriber over an AVAudioFile, plain
// unbiased path) so the bench stays a small standalone swiftc compile. Kept a
// faithful copy of SpeechAnalyzerBridge.transcribeFile's non-vocab path — if that
// path changes, mirror it here.
//
// Model assets download on first use via AssetInventory (expected; needs network
// the first time). Emits BENCH TSV lines (see BenchCommon).
//
// Usage: speechanalyzer-bench <wav> <txt> [<wav> <txt> ...]

import Foundation
import AVFoundation
import Speech

@main
struct SpeechAnalyzerBench {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2, args.count % 2 == 0 else {
            FileHandle.standardError.write(Data(
                "usage: speechanalyzer-bench <wav> <txt> [<wav> <txt> ...]\n".utf8))
            exit(64)
        }
        guard #available(macOS 26, *) else {
            FileHandle.standardError.write(Data(
                "SpeechAnalyzer requires macOS 26; this host is older.\n".utf8))
            exit(70)
        }
        let pairs = stride(from: 0, to: args.count, by: 2).map { (args[$0], args[$0 + 1]) }

        // Warm the transcriber/model once so the first fixture isn't skewed by
        // asset provisioning.
        FileHandle.standardError.write(Data("SpeechAnalyzer: warming model…\n".utf8))
        _ = try? await transcribeFile(wavURL: URL(fileURLWithPath: pairs[0].0))

        for (wav, txt) in pairs {
            let name = (wav as NSString).lastPathComponent
            let audioSec = WavDuration.seconds(path: wav)
            let start = Date()
            let text: String
            do {
                text = try await transcribeFile(wavURL: URL(fileURLWithPath: wav))
            } catch {
                FileHandle.standardError.write(Data("  error on \(name): \(error)\n".utf8))
                text = ""
            }
            let proc = Date().timeIntervalSince(start)
            Bench.emit(engine: "SpeechAnalyzer", model: "SpeechTranscriber (system)",
                       fixture: name, audioSec: audioSec, procSec: proc,
                       reference: Bench.loadReference(txt), transcript: text)
        }
        exit(0)
    }

    /// Mirror of SpeechAnalyzerBridge.transcribeFile (unbiased path, "auto"
    /// locale). See file header.
    @available(macOS 26, *)
    static func transcribeFile(wavURL: URL) async throws -> String {
        let requested = Locale.current
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
            ?? Locale.current
        let transcriber = SpeechTranscriber(
            locale: resolved, transcriptionOptions: [],
            reportingOptions: [], attributeOptions: [])

        // Provision the locale's assets on demand (AssetInventory).
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
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
