// Real-engine E2E harness (Tier-2 / nightly, driven by scripts/e2e-whisperkit.sh).
//
// Compiled WITH `-D WHISPERKIT` and linked against the WhisperKit dep + the app's
// WhisperKitEngine/WhisperKitBridge sources, so it runs the REAL on-device
// transcription engine against fixture WAVs — the accuracy check plain
// `swift test` can't do (WhisperKitEngine is app-target-only and behind the
// WHISPERKIT flag). Not part of the SwiftPM package; the runner scripts the
// swiftc invocation.
//
// Usage:
//   whisperkit-harness <model-name> <fixture.wav> <fixture.txt> [<wav> <txt> ...]
// Exit 0 iff every fixture's transcript fuzzily matches its expected text
// (key-phrase containment on normalized text — never exact, per the determinism
// policy). The `silence.wav` fixture (empty .txt) must produce empty output.

import Foundation

// A transcription result: text on success, message on failure. (Result's failure
// type must be an Error, so a plain enum is simpler here.)
enum TranscribeResult {
    case success(String)
    case failure(String)
}

@main
struct Harness {
    // Normalize for fuzzy comparison: lowercase, strip non-alphanumerics, collapse
    // whitespace. Mirrors the shell `norm` in e2e-smoke.sh.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func transcribeOne(engine: WhisperKitEngine, wavPath: String) -> TranscribeResult {
        let sema = DispatchSemaphore(value: 0)
        var outcome: TranscribeResult = .failure("no result")
        let id = UUID()
        engine.onTranscriptionComplete = { rid, text in
            guard rid == id else { return }
            outcome = .success(text); sema.signal()
        }
        engine.onTranscriptionError = { rid, msg in
            guard rid == id else { return }
            outcome = .failure(msg); sema.signal()
        }
        engine.transcribe(
            requestID: id, binaryPath: "", modelPath: "", language: "en",
            wavPath: wavPath, deleteWhenDone: false, backend: .cli, prompt: ""
        )
        // Generous timeout: first load can download/compile the model.
        if sema.wait(timeout: .now() + 600) == .timedOut {
            return .failure("timeout after 600s")
        }
        return outcome
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3, args.count % 2 == 1 else {
            FileHandle.standardError.write(Data(
                "usage: whisperkit-harness <model> <wav> <txt> [<wav> <txt> ...]\n".utf8))
            exit(64)
        }

        let modelName = args[0]
        let pairs = stride(from: 1, to: args.count, by: 2).map { (args[$0], args[$0 + 1]) }

        let engine = WhisperKitEngine(modelName: modelName)
        var failures = 0

        for (wav, txt) in pairs {
            let name = (wav as NSString).lastPathComponent
            let expected = (try? String(contentsOfFile: txt, encoding: .utf8)) ?? ""
            switch transcribeOne(engine: engine, wavPath: wav) {
            case .failure(let msg):
                print("✗ \(name): engine error: \(msg)")
                failures += 1
            case .success(let text):
                let t = normalize(text)
                let e = normalize(expected)
                if e.isEmpty {
                    // silence fixture: must transcribe to (near-)nothing.
                    if t.isEmpty {
                        print("✓ \(name): silence → empty (correct)")
                    } else {
                        print("✗ \(name): expected empty, got \"\(t)\"")
                        failures += 1
                    }
                } else {
                    // Longest expected word as the key phrase — distinctive enough
                    // that containment is a meaningful match (not "the").
                    let key = e.split(separator: " ").map(String.init)
                        .max(by: { $0.count < $1.count }) ?? ""
                    if !key.isEmpty && t.contains(key) {
                        print("✓ \(name): \"\(text)\" (matched key phrase \"\(key)\")")
                    } else {
                        print("✗ \(name): got [\(t)] expected≈[\(e)]")
                        failures += 1
                    }
                }
            }
        }

        if failures == 0 {
            print("\nAll \(pairs.count) fixtures passed real-engine transcription.")
            exit(0)
        } else {
            print("\n\(failures)/\(pairs.count) fixtures FAILED.")
            exit(1)
        }
    }
}
