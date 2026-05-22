import Foundation

// MARK: - Whisper Engine

class WhisperEngine {
    
    var onTranscriptionComplete: ((UUID, String) -> Void)?
    var onTranscriptionError: ((UUID, String) -> Void)?
    var onProgress: ((Int) -> Void)?
    
    init() {}
    
    /// Transcribe a single WAV file using whisper.cpp (async — doesn't block caller).
    func transcribe(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool = true
    ) {
        
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            DispatchQueue.main.async {
                self.onTranscriptionError?(requestID, "whisper binary not found at: \(binaryPath)")
            }
            return
        }
        
        guard FileManager.default.fileExists(atPath: modelPath) else {
            DispatchQueue.main.async {
                self.onTranscriptionError?(requestID, "Model not found at: \(modelPath)")
            }
            return
        }
        
        // Run on background queue to not block the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = [
                "-m", modelPath,
                "-f", wavPath,
                "-l", language == "auto" ? "auto" : language,
                "--no-timestamps",
                "-otxt",
                "-nt"
            ]
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            do {
                try process.run()
                
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if deleteWhenDone {
                    try? FileManager.default.removeItem(atPath: wavPath)
                }
                
                let exitCode = process.terminationStatus
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                if !stderr.isEmpty {
                    print("[WhisperEngine] stderr: \(stderr)")
                }
                
                if exitCode == 0 {
                    let text = (String(data: stdoutData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                    
                    print("[WhisperEngine] result (exit=\(exitCode)): \"\(text)\" (len=\(text.count))")
                    
                    DispatchQueue.main.async {
                        if text.isEmpty {
                            // No speech detected — skip
                            self.onTranscriptionComplete?(requestID, "")
                        } else {
                            self.onTranscriptionComplete?(requestID, text)
                        }
                    }
                } else {
                    print("[WhisperEngine] ERROR: exit=\(exitCode), stderr=\(stderr)")
                    DispatchQueue.main.async {
                        self.onTranscriptionError?(requestID, "whisper exited with code \(exitCode): \(stderr)")
                    }
                }
            } catch {
                print("[WhisperEngine] FAILED to run: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onTranscriptionError?(requestID, "Failed to run whisper: \(error.localizedDescription)")
                }
            }
        }
    }
}
