// Parakeet bench harness (MAK-79). Compiled WITH `-D PARAKEET` and linked
// against the FluidAudio dep + the app's ParakeetBridge source, so it runs the
// REAL ParakeetFileEngine backend (TDT v3 batch) over the fixtures through the
// SAME loadBatch/transcribeBatch calls the app makes. Emits BENCH TSV lines.
//
// FluidAudio stages the TDT v3 CoreML model on first use (HuggingFace →
// ~/Library/Application Support/FluidAudio/Models/, ~600 MB) — expected, needs
// network the first time. Auto language (nil hint), no vocabulary biasing.
//
// Usage: parakeet-bench <wav> <txt> [<wav> <txt> ...]

import Foundation

@main
struct ParakeetBench {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2, args.count % 2 == 0 else {
            FileHandle.standardError.write(Data(
                "usage: parakeet-bench <wav> <txt> [<wav> <txt> ...]\n".utf8))
            exit(64)
        }
        let pairs = stride(from: 0, to: args.count, by: 2).map { (args[$0], args[$0 + 1]) }

        FileHandle.standardError.write(Data("Parakeet: loading TDT v3 (first run downloads ~600 MB)…\n".utf8))
        let handle: ParakeetBridge.BatchHandle
        do {
            handle = try await ParakeetBridge.loadBatch()
        } catch {
            FileHandle.standardError.write(Data("Parakeet load failed: \(error)\n".utf8))
            exit(70)
        }

        for (wav, txt) in pairs {
            let name = (wav as NSString).lastPathComponent
            let url = URL(fileURLWithPath: wav)
            let audioSec = WavDuration.seconds(path: wav)
            let start = Date()
            let text: String
            do {
                text = try await ParakeetBridge.transcribeBatch(
                    handle: handle, wavURL: url, languageCode: nil, biasTerms: [])
            } catch {
                FileHandle.standardError.write(Data("  error on \(name): \(error)\n".utf8))
                text = ""
            }
            let proc = Date().timeIntervalSince(start)
            Bench.emit(engine: "Parakeet", model: "TDT v3 (batch/file)",
                       fixture: name, audioSec: audioSec, procSec: proc,
                       reference: Bench.loadReference(txt), transcript: text)
        }
        exit(0)
    }
}
