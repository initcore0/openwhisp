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
        backend: Backend = .cli
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
                    deleteWhenDone: deleteWhenDone
                )
            case .serverAPI:
                self.transcribeWithServerAPI(
                    requestID: requestID,
                    binaryPath: binaryPath,
                    modelPath: modelPath,
                    language: language,
                    wavPath: wavPath,
                    deleteWhenDone: deleteWhenDone
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
        deleteWhenDone: Bool
    ) {
        do {
            let text = try transcribeWithWorker(
                requestID: requestID,
                binaryPath: binaryPath,
                modelPath: modelPath,
                language: language,
                wavPath: wavPath,
                deleteWhenDone: deleteWhenDone
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
        deleteWhenDone: Bool
    ) {

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
        deleteWhenDone: Bool
    ) throws -> String {
        guard ensureServer(binaryPath: binaryPath, modelPath: modelPath) else {
            throw WhisperWorkerError.unavailable
        }

        let text = try postInference(wavPath: wavPath, language: language)
        guard !text.isEmpty else {
            throw WhisperWorkerError.emptyTranscript
        }
        if deleteWhenDone {
            try? FileManager.default.removeItem(atPath: wavPath)
        }
        return text
    }

    private func ensureServer(binaryPath: String, modelPath: String) -> Bool {
        serverLock.lock()
        defer { serverLock.unlock() }

        if serverModelPath == modelPath, serverProcess?.isRunning == true, healthCheck() {
            return true
        }

        stopServerLocked()

        guard let serverPath = serverBinaryPath(for: binaryPath) else {
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
            serverProcess = process
            serverModelPath = modelPath
            serverStdoutPipe = stdoutPipe
            serverStderrPipe = stderrPipe
            writeWorkerPID(process.processIdentifier)

            if waitForHealth(timeout: 45), process.isRunning {
                DispatchQueue.main.async {
                    self.onWorkerStatus?("Loaded on port \(self.serverPort)")
                }
                return true
            }
        } catch {
            log("Failed to start worker: \(error.localizedDescription)")
            print("[WhisperEngine] failed to start worker: \(error.localizedDescription)")
        }

        stopServerLocked()
        DispatchQueue.main.async {
            self.onWorkerStatus?("Worker unavailable")
        }
        return false
    }

    private func stopServerLocked() {
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

    private func waitForHealth(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
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

    private func postInference(wavPath: String, language: String) throws -> String {
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
            language: language
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
            log("Server API HTTP \(http.statusCode): \(message.prefix(2000))")
            throw WhisperWorkerError.serverError(message)
        }

        struct InferenceResponse: Decodable {
            let text: String?
        }

        let decoded = try JSONDecoder().decode(InferenceResponse.self, from: resultData)
        let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawBody = String(data: resultData, encoding: .utf8) ?? ""
        log("Server API response HTTP \(http.statusCode), textLen=\(text.count), body=\(rawBody.prefix(1000))")
        print("[WhisperEngine] worker result: \"\(text)\" (len=\(text.count))")
        return text
    }

    private func multipartBody(boundary: String, wavPath: String, language: String) throws -> Data {
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

        if kill(pid, 0) == 0 {
            print("[WhisperEngine] stopping stale whisper-server pid \(pid)")
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.5)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }

        try? FileManager.default.removeItem(at: pidFileURL)
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
