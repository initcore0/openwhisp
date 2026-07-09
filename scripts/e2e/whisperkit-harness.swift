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

    // Whisper hallucinates non-speech markers on silence (e.g. "[BLANK_AUDIO]",
    // "(silence)"). The app strips these in TranscriptCleaner; this bare harness
    // treats a transcript that is ONLY such markers as empty, so the silence
    // fixture asserts correctly without pulling the whole cleaner in.
    static func isEffectivelyEmpty(_ normalized: String) -> Bool {
        let markers: Set<String> = [
            // non-speech markers the app strips…
            "blank audio", "silence", "no speech", "music", "inaudible",
            "background noise", "noise", "static",
            // …and the bare-word artifacts Whisper emits on pure silence.
            "you", "thank you", "thanks for watching", "bye", "thanks",
        ]
        return normalized.isEmpty || markers.contains(normalized)
    }

    // Fraction of the expected's distinctive (3+ letter) content words that appear
    // in the transcript. A ratio tolerates Whisper's number/date normalization
    // ("four fifteen" → "415" drops those words) far better than a single key word,
    // while a low bar (a couple of content words present) still catches a wrong or
    // empty transcript. This is the fuzzy metric the determinism policy calls for.
    static func contentOverlap(expected e: String, got t: String) -> Double {
        let content = Set(e.split(separator: " ").map(String.init)
            .filter { $0.count >= 3 })
        guard !content.isEmpty else { return 1.0 }
        let gotWords = Set(t.split(separator: " ").map(String.init))
        let hits = content.filter { gotWords.contains($0) }.count
        return Double(hits) / Double(content.count)
    }
    static let overlapThreshold = 0.4

    /// Transcribe one WAV, blocking the CALLING thread until the result arrives.
    /// MUST be called off the main thread: WhisperKitEngine delivers its result
    /// via `await MainActor.run { … }` and loads the model on the main actor, so
    /// blocking the main thread here would deadlock (the completion hop can never
    /// run). `main()` therefore drives this on a background thread and keeps the
    /// main runloop spinning.
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

        // Run the (blocking) transcription loop on a background thread and keep the
        // main thread free to service the engine's MainActor completion hops. The
        // worker exit()s when done, tearing down the process.
        let worker = Thread {
            runAll(modelName: modelName, pairs: pairs)
        }
        worker.stackSize = 4 << 20
        worker.start()
        RunLoop.main.run()   // never returns; the worker calls exit().
    }

    static func runAll(modelName: String, pairs: [(String, String)]) {
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
                    // silence fixture: must transcribe to (near-)nothing, tolerating
                    // Whisper's blank-audio hallucination that the app strips.
                    if isEffectivelyEmpty(t) {
                        print("✓ \(name): silence → empty (got \"\(text)\")")
                    } else {
                        print("✗ \(name): expected empty, got \"\(t)\"")
                        failures += 1
                    }
                } else {
                    let overlap = contentOverlap(expected: e, got: t)
                    if overlap >= overlapThreshold {
                        print(String(format: "✓ %@: \"%@\" (%.0f%% content-word overlap)",
                                     name, text, overlap * 100))
                    } else {
                        print(String(format: "✗ %@: only %.0f%% overlap — got [%@] expected≈[%@]",
                                     name, overlap * 100, t, e))
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
