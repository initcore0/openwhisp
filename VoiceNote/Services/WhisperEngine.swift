import Foundation
import Darwin

// MARK: - Whisper Engine

class WhisperEngine {
    enum Backend {
        case cli
        case serverAPI
    }

    var onTranscriptionComplete: ((UUID, String) -> Void)?
    var onTranscriptionError: ((UUID, String) -> Void)?
    var onProgress: ((Int) -> Void)?
    var onWorkerStatus: ((String) -> Void)?

    private let serverPort: Int
    private let serverLock = NSLock()
    private var serverProcess: Process?
    private var serverModelPath: String?
    private var serverStdoutPipe: Pipe?
    private var serverStderrPipe: Pipe?
    private let pidFileURL: URL
    private let logFileURL: URL

    /// Generation counter, guarded by `serverLock`. Bumped every time the server
    /// state is started, stopped, or replaced. `ensureServer` snapshots it before
    /// releasing the lock to wait for health, then verifies it is unchanged before
    /// committing success — so a concurrent stop/replace can't be clobbered.
    private var serverGeneration: Int = 0

    init() {
        serverPort = Self.availableLoopbackPort() ?? 8178
        pidFileURL = Self.workerPIDFileURL()
        logFileURL = Self.logFileURL()
        Self.stopStaleServerIfNeeded(pidFileURL: pidFileURL)
        log("WhisperEngine initialized with server port \(serverPort)")
    }

    deinit {
        serverLock.lock()
        stopServerLocked()
        serverLock.unlock()
    }

    /// Transcribe a single WAV file using whisper.cpp (async — doesn't block caller).
    func transcribe(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool = true,
        backend: Backend = .cli,
        prompt: String = ""
    ) {

        guard FileManager.default.fileExists(atPath: binaryPath) else {
            log("Missing whisper binary: \(binaryPath)")
            DispatchQueue.main.async {
                self.onTranscriptionError?(requestID, "whisper binary not found at: \(binaryPath)")
            }
            return
        }

        guard FileManager.default.fileExists(atPath: modelPath) else {
            log("Missing model: \(modelPath)")
            DispatchQueue.main.async {
                self.onTranscriptionError?(requestID, "Model not found at: \(modelPath)")
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            switch backend {
            case .cli:
                DispatchQueue.main.async {
                    self.onWorkerStatus?("CLI selected")
                }
                self.transcribeWithCLI(
                    requestID: requestID,
                    binaryPath: binaryPath,
                    modelPath: modelPath,
                    language: language,
                    wavPath: wavPath,
                    deleteWhenDone: deleteWhenDone,
                    prompt: prompt
                )
            case .serverAPI:
                self.transcribeWithServerAPI(
                    requestID: requestID,
                    binaryPath: binaryPath,
                    modelPath: modelPath,
                    language: language,
                    wavPath: wavPath,
                    deleteWhenDone: deleteWhenDone,
                    prompt: prompt
                )
            }
        }
    }

    func stopServer() {
        serverLock.lock()
        stopServerLocked()
        serverLock.unlock()
        DispatchQueue.main.async {
            self.onWorkerStatus?("Stopped")
        }
    }

    func warmServer(binaryPath: String, modelPath: String) {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            DispatchQueue.main.async {
                self.onWorkerStatus?("Waiting for model")
            }
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            guard FileManager.default.fileExists(atPath: binaryPath) else {
                self.log("Cannot warm server, whisper binary missing: \(binaryPath)")
                DispatchQueue.main.async {
                    self.onWorkerStatus?("Server unavailable")
                }
                return
            }

            if self.ensureServer(binaryPath: binaryPath, modelPath: modelPath) {
                self.log("Whisper server warmed for model: \(modelPath)")
            }
        }
    }

    private func transcribeWithServerAPI(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool,
        prompt: String = ""
    ) {
        do {
            let text = try transcribeWithWorker(
                requestID: requestID,
                binaryPath: binaryPath,
                modelPath: modelPath,
                language: language,
                wavPath: wavPath,
                deleteWhenDone: deleteWhenDone,
                prompt: prompt
            )
            DispatchQueue.main.async {
                self.onTranscriptionComplete?(requestID, text)
            }
        } catch {
            if deleteWhenDone {
                try? FileManager.default.removeItem(atPath: wavPath)
            }
            let message = "Whisper Server API failed: \(error.localizedDescription)"
            log(message)
            print("[WhisperEngine] \(message)")
            DispatchQueue.main.async {
                self.onWorkerStatus?("Server API error")
                self.onTranscriptionError?(requestID, message)
            }
        }
    }

    private func transcribeWithCLI(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool,
        prompt: String = ""
    ) {

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            var arguments = [
                "-m", modelPath,
                "-f", wavPath,
                "-l", language == "auto" ? "auto" : language,
                "--no-timestamps",
                "-otxt",
                "-nt"
            ]
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPrompt.isEmpty {
                arguments.append(contentsOf: ["--prompt", trimmedPrompt])
            }
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()

                // Drain stdout and stderr concurrently. Reading them serially
                // can deadlock: if whisper-cli fills the stderr pipe buffer while
                // we block on stdout, the child stalls and never exits.
                var stderrData = Data()
                let stderrGroup = DispatchGroup()
                stderrGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    stderrGroup.leave()
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                stderrGroup.wait()
                process.waitUntilExit()
                if deleteWhenDone {
                    try? FileManager.default.removeItem(atPath: wavPath)
                }

                let exitCode = process.terminationStatus
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !stderr.isEmpty {
                    self.log("CLI stderr: \(stderr.prefix(2000))")
                    print("[WhisperEngine] stderr: \(stderr)")
                }

                if exitCode == 0 {
                    let text = (String(data: stdoutData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")

                    print("[WhisperEngine] result (exit=\(exitCode)): \"\(text)\" (len=\(text.count))")
                    self.log("CLI result exit=\(exitCode), textLen=\(text.count)")

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
                    self.log("CLI error exit=\(exitCode), stderr=\(stderr.prefix(2000))")
                    DispatchQueue.main.async {
                        self.onTranscriptionError?(requestID, "whisper exited with code \(exitCode): \(stderr)")
                    }
                }
            } catch {
                if deleteWhenDone {
                    try? FileManager.default.removeItem(atPath: wavPath)
                }
                print("[WhisperEngine] FAILED to run: \(error.localizedDescription)")
                log("CLI failed to run: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onTranscriptionError?(requestID, "Failed to run whisper: \(error.localizedDescription)")
                }
            }
    }

    private func transcribeWithWorker(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool,
        prompt: String = ""
    ) throws -> String {
        guard ensureServer(binaryPath: binaryPath, modelPath: modelPath) else {
            throw WhisperWorkerError.unavailable
        }

        let text = try postInference(wavPath: wavPath, language: language, prompt: prompt)
        guard !text.isEmpty else {
            throw WhisperWorkerError.emptyTranscript
        }
        if deleteWhenDone {
            try? FileManager.default.removeItem(atPath: wavPath)
        }
        return text
    }

    private func ensureServer(binaryPath: String, modelPath: String) -> Bool {
        // --- Phase 1: snapshot / start under the lock -------------------------
        serverLock.lock()

        if serverModelPath == modelPath, serverProcess?.isRunning == true, healthCheck() {
            serverLock.unlock()
            return true
        }

        // Tear down any existing/mismatched server before starting a new one.
        stopServerLocked()

        guard let serverPath = serverBinaryPath(for: binaryPath) else {
            serverLock.unlock()
            log("whisper-server unavailable next to \(binaryPath)")
            DispatchQueue.main.async {
                self.onWorkerStatus?("Worker unavailable")
            }
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = [
            "--host", "127.0.0.1",
            "--port", "\(serverPort)",
            "-m", modelPath,
            "--no-timestamps"
        ]
        log("Starting whisper-server: \(serverPath) \(process.arguments?.joined(separator: " ") ?? "")")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                print("[whisper-server] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                print("[whisper-server] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            DispatchQueue.main.async {
                self.onWorkerStatus?("Loading on port \(self.serverPort)...")
            }
            try process.run()
        } catch {
            serverLock.unlock()
            log("Failed to start worker: \(error.localizedDescription)")
            print("[WhisperEngine] failed to start worker: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.onWorkerStatus?("Worker unavailable")
            }
            return false
        }

        // Commit the freshly-started process into shared state and bump the
        // generation so a concurrent stop/replace can be detected after we
        // release the lock.
        serverGeneration += 1
        let myGeneration = serverGeneration
        serverProcess = process
        serverModelPath = modelPath
        serverStdoutPipe = stdoutPipe
        serverStderrPipe = stderrPipe
        writeWorkerPID(process.processIdentifier)

        serverLock.unlock()

        // --- Phase 2: wait for health WITHOUT holding the lock ---------------
        // `stopServer()` can bump `serverGeneration` to make this loop bail early.
        let healthy = waitForHealth(timeout: 45, generation: myGeneration)

        // --- Phase 3: re-acquire to commit success or tear down on failure ---
        serverLock.lock()
        defer { serverLock.unlock() }

        // If a concurrent stop/replace happened, the process we started is no
        // longer the current one — don't touch shared state, just bail.
        guard serverGeneration == myGeneration, serverProcess === process else {
            // Our process was already torn down (or replaced) by someone else.
            if process.isRunning {
                process.terminate()
            }
            return false
        }

        if healthy, process.isRunning {
            DispatchQueue.main.async {
                self.onWorkerStatus?("Loaded on port \(self.serverPort)")
            }
            return true
        }

        // Health failed (or process died): tear down the server we own.
        stopServerLocked()
        DispatchQueue.main.async {
            self.onWorkerStatus?("Worker unavailable")
        }
        return false
    }

    /// Must be called with `serverLock` held. Bumps `serverGeneration` so any
    /// in-progress `ensureServer`/`waitForHealth` for the current server bails
    /// out instead of committing or blocking on the doomed process.
    private func stopServerLocked() {
        // Invalidate any in-progress health wait for the current generation.
        serverGeneration += 1

        serverStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        serverStderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = serverProcess, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        serverProcess = nil
        serverModelPath = nil
        serverStdoutPipe = nil
        serverStderrPipe = nil
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func serverBinaryPath(for cliPath: String) -> String? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("whisper/whisper-server")
            .path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        let cliURL = URL(fileURLWithPath: cliPath)
        let sibling = cliURL.deletingLastPathComponent().appendingPathComponent("whisper-server").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }

        let defaultPath = "\(NSHomeDirectory())/whisper.cpp/build/bin/whisper-server"
        if FileManager.default.isExecutableFile(atPath: defaultPath) {
            return defaultPath
        }

        return nil
    }

    /// Polls `/health` until it succeeds, the timeout elapses, or the server
    /// generation changes out from under us (set by `stopServer()` /
    /// `stopServerLocked()`). Runs WITHOUT `serverLock` held so a concurrent
    /// stop can bail it out early. Returns false if cancelled.
    private func waitForHealth(timeout: TimeInterval, generation: Int) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Bail early if our server was stopped or replaced.
            serverLock.lock()
            let cancelled = serverGeneration != generation
            serverLock.unlock()
            if cancelled {
                return false
            }
            if healthCheck() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func healthCheck() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1

        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                ok = true
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.2)
        return ok
    }

    private func postInference(wavPath: String, language: String, prompt: String = "") throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/inference") else {
            throw WhisperWorkerError.invalidURL
        }

        let boundary = "VoiceNoteBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(
            boundary: boundary,
            wavPath: wavPath,
            language: language,
            prompt: prompt
        )
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: wavPath)[.size] as? NSNumber)?.int64Value ?? -1
        log("Server API POST /inference port=\(serverPort), wav=\(URL(fileURLWithPath: wavPath).lastPathComponent), bytes=\(fileSize), language=\(language)")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 130)

        if let resultError {
            throw resultError
        }

        guard let http = resultResponse as? HTTPURLResponse, let resultData else {
            throw WhisperWorkerError.emptyResponse
        }

        guard http.statusCode == 200 else {
            let message = String(data: resultData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            // Avoid persisting full response bodies: on some servers an error
            // body can echo back request content (potentially transcript text).
            #if DEBUG
            log("Server API HTTP \(http.statusCode): \(message.prefix(2000))")
            #else
            log("Server API HTTP \(http.statusCode) (\(resultData.count) bytes)")
            #endif
            throw WhisperWorkerError.serverError(message)
        }

        struct InferenceResponse: Decodable {
            let text: String?
        }

        let decoded = try JSONDecoder().decode(InferenceResponse.self, from: resultData)
        let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Do NOT log the raw body: it contains the transcript and is written to
        // a persistent, never-rotated cache log. Only record the length.
        log("Server API response HTTP \(http.statusCode), textLen=\(text.count)")
        print("[WhisperEngine] worker result: \"\(text)\" (len=\(text.count))")
        return text
    }

    private func multipartBody(boundary: String, wavPath: String, language: String, prompt: String = "") throws -> Data {
        var data = Data()

        func appendField(_ name: String, _ value: String) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            data.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("response_format", "json")
        appendField("temperature", "0.0")
        appendField("temperature_inc", "0.2")
        appendField("no_speech_thold", "0.6")
        appendField("no_timestamps", "true")
        appendField("language", language == "auto" ? "auto" : language)
        appendField("suppress_non_speech", "true")
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            // whisper-server accepts an initial "prompt" to bias recognition.
            appendField("prompt", trimmedPrompt)
        }

        let fileURL = URL(fileURLWithPath: wavPath)
        let fileData = try Data(contentsOf: fileURL)
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        data.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        data.append(fileData)
        data.append("\r\n".data(using: .utf8)!)
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }

    private static func availableLoopbackPort() -> Int? {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }

        // Set SO_REUSEADDR so that if whisper-server is launched with the same
        // option, it can re-bind this port without a stale-binding rejection.
        // (This does not eliminate the bind-then-close race; it only avoids
        // SO_REUSEADDR-related rebind failures on the discovered port.)
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard nameResult == 0 else { return nil }

        return Int(UInt16(bigEndian: boundAddr.sin_port))
    }

    private func writeWorkerPID(_ pid: Int32) {
        do {
            try FileManager.default.createDirectory(
                at: pidFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "\(pid)".write(to: pidFileURL, atomically: true, encoding: .utf8)
        } catch {
            print("[WhisperEngine] failed to write worker PID: \(error.localizedDescription)")
        }
    }

    private static func workerPIDFileURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.encryptedcat.voicenote/whisper-server.pid")
    }

    static func logFileURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.encryptedcat.voicenote/whisper-engine.log")
    }

    private func log(_ message: String) {
        do {
            try FileManager.default.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
            if FileManager.default.fileExists(atPath: logFileURL.path),
               let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                handle.write(Data(line.utf8))
            } else {
                try line.write(to: logFileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[WhisperEngine] log write failed: \(error.localizedDescription)")
        }
    }

    private static func stopStaleServerIfNeeded(pidFileURL: URL) {
        guard
            let rawPID = try? String(contentsOf: pidFileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int32(rawPID),
            pid > 0
        else { return }

        // Only signal if the PID is alive AND its executable is actually a
        // whisper-server. After a crash + PID reuse the persisted PID can point
        // at an unrelated user process — never kill that. If we can't resolve
        // the path, err on the side of NOT killing.
        if kill(pid, 0) == 0, isWhisperServerProcess(pid: pid) {
            print("[WhisperEngine] stopping stale whisper-server pid \(pid)")
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.5)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }

        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// Resolves the executable path of `pid` via libproc and returns true only
    /// if its last path component is `whisper-server`. Returns false if the path
    /// cannot be resolved (so callers won't signal an unknown process).
    private static func isWhisperServerProcess(pid: Int32) -> Bool {
        // proc_pidpath wants PROC_PIDPATHINFO_MAXSIZE (== 4*MAXPATHLEN) of space;
        // that C macro isn't importable into Swift, so use its expansion directly.
        // A smaller buffer (e.g. MAXPATHLEN) can truncate long paths, causing a
        // real stale whisper-server to fail the name check and not be cleaned up.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        return (path as NSString).lastPathComponent == "whisper-server"
    }
}

enum WhisperWorkerError: LocalizedError {
    case invalidURL
    case emptyResponse
    case serverError(String)
    case unavailable
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid whisper worker URL."
        case .emptyResponse:
            return "Whisper worker returned an empty response."
        case .serverError(let message):
            return message
        case .unavailable:
            return "whisper-server could not be started or did not become healthy."
        case .emptyTranscript:
            return "whisper-server returned an empty transcript. Check language/model settings or the log file."
        }
    }
}
