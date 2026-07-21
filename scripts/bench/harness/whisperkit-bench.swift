// WhisperKit bench harness (MAK-79). Compiled WITH `-D WHISPERKIT` and linked
// against the WhisperKit dep + the app's WhisperKitEngine sources (same recipe
// as scripts/e2e-whisperkit.sh), so it runs the REAL on-device engine over the
// fixtures through its FILE path and emits BENCH TSV lines (see BenchCommon).
//
// Usage: whisperkit-bench <model> <wav> <txt> [<wav> <txt> ...]

import Foundation

@main
struct WhisperKitBench {
    /// Transcribe one WAV, blocking off the main thread (the engine hops its
    /// completion to the main actor — see the e2e harness note). Returns the
    /// transcript and the wall-clock seconds spent in transcribe().
    static func transcribeOne(engine: WhisperKitEngine, wavPath: String) -> (String, Double) {
        let sema = DispatchSemaphore(value: 0)
        var text = ""
        var failed: String? = nil
        let id = UUID()
        engine.onTranscriptionComplete = { rid, t in
            guard rid == id else { return }
            text = t; sema.signal()
        }
        engine.onTranscriptionError = { rid, msg in
            guard rid == id else { return }
            failed = msg; sema.signal()
        }
        let start = Date()
        engine.transcribe(
            requestID: id, binaryPath: "", modelPath: "", language: "en",
            wavPath: wavPath, deleteWhenDone: false, backend: .cli, prompt: "")
        if sema.wait(timeout: .now() + 600) == .timedOut {
            FileHandle.standardError.write(Data("  timeout after 600s\n".utf8))
            return ("", 600)
        }
        let elapsed = Date().timeIntervalSince(start)
        if let failed {
            FileHandle.standardError.write(Data("  error: \(failed)\n".utf8))
            return ("", elapsed)
        }
        return (text, elapsed)
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3, args.count % 2 == 1 else {
            FileHandle.standardError.write(Data(
                "usage: whisperkit-bench <model> <wav> <txt> [<wav> <txt> ...]\n".utf8))
            exit(64)
        }
        let model = args[0]
        let pairs = stride(from: 1, to: args.count, by: 2).map { (args[$0], args[$0 + 1]) }

        let worker = Thread { runAll(model: model, pairs: pairs) }
        worker.stackSize = 8 << 20
        worker.start()
        RunLoop.main.run()
    }

    static func runAll(model: String, pairs: [(String, String)]) {
        let engine = WhisperKitEngine(modelName: model)
        // Warm the model once (download/compile) so the first fixture's timing is
        // not skewed by a one-off load; the warm-up transcript is discarded.
        FileHandle.standardError.write(Data("WhisperKit: warming model \(model)…\n".utf8))
        _ = transcribeOne(engine: engine, wavPath: pairs[0].0)

        for (wav, txt) in pairs {
            let name = (wav as NSString).lastPathComponent
            let audioSec = WavDuration.seconds(path: wav)
            let (text, proc) = transcribeOne(engine: engine, wavPath: wav)
            Bench.emit(engine: "WhisperKit", model: model, fixture: name,
                       audioSec: audioSec, procSec: proc,
                       reference: Bench.loadReference(txt), transcript: text)
        }
        exit(0)
    }
}
