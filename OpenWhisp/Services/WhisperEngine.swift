import Foundation
import Darwin

// MARK: - Whisper Engine

class WhisperEngine: FileTranscriptionEngine {
    /// The backend enum now lives in OpenWhispCore as `WhisperBackend` so the
    /// `FileTranscriptionEngine` protocol can name it; kept as a typealias so the
    /// engine body and `.cli`/`.serverAPI` references are unchanged.
    typealias Backend = WhisperBackend

    var onTranscriptionComplete: ((UUID, String) -> Void)?
    var onTranscriptionError: ((UUID, String) -> Void)?
    var onProgress: ((Int) -> Void)?
    var onWorkerStatus: ((String) -> Void)?

    /// Loopback port the server binds. Re-picked (under `serverLock`) at each
    /// (re)launch inside `ensureServerOnce` rather than cached once at init —
    /// see MAK-28. Now that it is a `var` mutated under the lock, every read
    /// outside the lock goes through `currentPort` (a lock-guarded snapshot) so
    /// there is no TSan-visible data race and a caller can't poll a concurrent
    /// relaunch's port on behalf of the old generation. Reads WITH the lock held
    /// (the launch path) touch `serverPort` directly.
    private var serverPort: Int

    /// Thread-safe snapshot of `serverPort` for reads that run WITHOUT
    /// `serverLock` held (`healthCheck`, `postInference`).
    private var currentPort: Int {
        serverLock.lock()
        defer { serverLock.unlock() }
        return serverPort
    }
    private let serverLock = NSLock()
    private var serverProcess: Process?
    private var serverModelPath: String?
    private var serverStdoutPipe: Pipe?
    private var serverStderrPipe: Pipe?

    /// Identity (basename, PID/log file names, log tag) of the whisper-server
    /// this engine manages. Drives the shared `ManagedServerProcess` glue.
    private static let serverSpec = ManagedServerSpec(
        executableBasename: "whisper-server",
        logTag: "whisper-server",
        pidFileName: "whisper-server.pid",
        logFileName: "whisper-engine.log"
    )

    /// Generation counter, guarded by `serverLock`. Bumped every time the server
    /// state is started, stopped, or replaced. `ensureServer` snapshots it before
    /// releasing the lock to wait for health, then verifies it is unchanged before
    /// committing success — so a concurrent stop/replace can't be clobbered.
    private var serverGeneration: Int = 0

    /// Generation whose startup (`waitForHealth`) is currently in flight, or nil.
    /// Guarded by `serverLock`. Lets a concurrent `ensureServer` for the same
    /// model JOIN the in-progress startup instead of tearing down a server that
    /// is running but not yet healthy (still loading its model).
    private var startingGeneration: Int?

    init() {
        // The init-time port is a placeholder; each (re)launch reserves a FRESH
        // port (MAK-28). Reserve-and-immediately-release here just to seed a
        // plausible value for logging.
        if let reservation = ManagedServerProcess.reservePort(in: Self.portRange) {
            serverPort = reservation.port
            reservation.release()
        } else {
            serverPort = Self.portRange.lowerBound
        }
        ManagedServerProcess.reapStaleServer(spec: Self.serverSpec, ownedPrefixes: Self.ownedServerPrefixes())
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
            // Map the engine-facing language setting to whisper's (source
            // language, translate) params — the translate-to-English sentinel
            // becomes (-l auto --translate); see WhisperTask.
            let task = WhisperTask.resolve(languageSetting: language)
            var arguments = [
                "-m", modelPath,
                "-f", wavPath,
                "-l", task.language,
                "--no-timestamps",
                "-nt"
            ]
            if task.translate {
                arguments.append("--translate")
            }
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

        // Classify the server's answer. A 200 whose transcript is empty/
        // whitespace-only is NOT an error — it's the "no speech detected" case,
        // and we return "" so the caller delivers it via onTranscriptionComplete
        // exactly like the CLI path's no-op (MAK-23). Only genuine failures
        // (non-200, malformed body) throw. Transport-level errors (network,
        // no HTTPURLResponse) are thrown from postInference before we get here.
        let outcome = try postInference(wavPath: wavPath, language: language, prompt: prompt)
        if deleteWhenDone {
            try? FileManager.default.removeItem(atPath: wavPath)
        }
        switch outcome {
        case .cleanEmpty:
            return ""
        case .transcript(let text):
            return text
        case .error(let message):
            throw WhisperWorkerError.serverError(message)
        }
    }

    /// Ensures a healthy whisper-server is running for `modelPath`, retrying
    /// with a freshly-discovered loopback port if a launch fails to become
    /// healthy — which is how a lost port-bind race (MAK-28) surfaces. The
    /// happy path (server already healthy on this model) returns on the first
    /// attempt without re-picking a port.
    ///
    /// Retries ONLY on a health failure. If a concurrent `stopServer()` /
    /// model-switch cancels an in-flight launch, `ensureServerOnce` reports
    /// `.cancelled` and we do NOT retry — retrying would relaunch a server the
    /// user just tore down (an orphan on quit). See MAK-28 review #2. The
    /// retry-vs-cancel decision is the pure `ServerLaunchRetry.decide`.
    private func ensureServer(binaryPath: String, modelPath: String) -> Bool {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let attemptsRemaining = maxAttempts - attempt + 1
            let outcome = ensureServerOnce(binaryPath: binaryPath, modelPath: modelPath)
            switch ServerLaunchRetry.decide(outcome: outcome, attemptsRemaining: attemptsRemaining) {
            case .succeed:
                return true
            case .giveUp:
                return false
            case .retry:
                log("whisper-server launch attempt \(attempt) failed health check; retrying on a fresh port")
            }
        }
        return false
    }

    /// Outcome of a single `ensureServerOnce` attempt, routed through
    /// `ServerLaunchRetry.decide`. `.healthFailed` is retryable; `.cancelled`
    /// (a concurrent stop/generation-invalidation) is not.
    private func ensureServerOnce(binaryPath: String, modelPath: String) -> ServerLaunchRetry.Outcome {
        // --- Phase 1: snapshot / start under the lock -------------------------
        serverLock.lock()

        if serverModelPath == modelPath, serverProcess?.isRunning == true {
            // A startup for this exact server is still in flight: join it
            // (wait for health without the lock) instead of killing a server
            // that is merely still loading its model — restarting here would
            // fail the owning caller AND this one. Teardown on failure is left
            // to the owning generation's phase 3.
            if startingGeneration == serverGeneration {
                let myGeneration = serverGeneration
                let process = serverProcess
                serverLock.unlock()
                let healthy = waitForHealth(timeout: 45, generation: myGeneration, process: process)
                serverLock.lock()
                let stillCurrent = serverGeneration == myGeneration && serverProcess === process
                serverLock.unlock()
                if healthy, stillCurrent {
                    return .launched
                }
                // The joined startup was stopped/replaced out from under us
                // (generation moved) — that's a cancellation, not a health
                // failure; don't relaunch a server the owner is tearing down.
                // If it's still current but unhealthy, the owning generation's
                // phase 3 will tear it down; treat that as a health failure so
                // a retry can bring a fresh server up.
                return stillCurrent ? .healthFailed : .cancelled
            }
            // No startup pending: probe health WITHOUT the lock (healthCheck
            // blocks up to ~1.2s; holding serverLock stalls main-actor callers
            // like stopServer on backend switch/quit), then re-validate. If the
            // generation moved while probing, another caller stopped/replaced
            // the server — re-evaluate from the top instead of tearing down
            // THEIR fresh server. A passing probe on unchanged state means the
            // server is usable; a failing one means it's hung — fall through
            // to restart.
            let probedGeneration = serverGeneration
            let probedProcess = serverProcess
            serverLock.unlock()
            let probeHealthy = healthCheck()
            serverLock.lock()
            if serverGeneration != probedGeneration || serverProcess !== probedProcess {
                serverLock.unlock()
                // Re-evaluate from the top by re-entering ONCE (ensureServerOnce,
                // NOT the ensureServer wrapper) so this recursion is charged
                // against the caller's existing attempt budget rather than being
                // granted a fresh 3-attempt budget. See MAK-28 review #5.
                return ensureServerOnce(binaryPath: binaryPath, modelPath: modelPath)
            }
            if probeHealthy {
                serverLock.unlock()
                return .launched
            }
        }

        // Tear down any existing/mismatched server before starting a new one.
        stopServerLocked()

        guard let serverPath = serverBinaryPath(for: binaryPath) else {
            serverLock.unlock()
            log("whisper-server unavailable next to \(binaryPath)")
            DispatchQueue.main.async {
                self.onWorkerStatus?("Worker unavailable")
            }
            // Not a user cancellation: report as a (non-)launch failure so the
            // outer loop's give-up path fires. A retry would just fail identically
            // (the binary won't appear), but it's harmless — preserving the prior
            // retry-on-false behavior for this branch.
            return .healthFailed
        }

        // Reserve a FRESH port for this launch instead of reusing the one cached
        // at init. The reservation HOLDS its bind-probe socket open until the
        // instant before the child binds (MAK-21 TOCTOU fix), so a concurrent
        // in-process start can't pick the same port and the bind-then-child-run
        // window shrinks to a couple of instructions. Re-picking + the caller's
        // retry-on-failure is the MAK-28 fix. Keep the previous port if discovery
        // fails so we still attempt a launch.
        let reservation = ManagedServerProcess.reservePort(in: Self.portRange)
        if let reservation {
            serverPort = reservation.port
        }

        let arguments = [
            "--host", "127.0.0.1",
            "--port", "\(serverPort)",
            "-m", modelPath,
            "--no-timestamps"
        ]
        log("Starting whisper-server: \(serverPath) \(arguments.joined(separator: " "))")

        let launched: ManagedServerProcess.Launched
        do {
            // Capture the port under the lock (held here) so the deferred
            // main-thread status closure doesn't read the mutable `serverPort`
            // unsynchronized.
            let launchPort = serverPort
            DispatchQueue.main.async {
                self.onWorkerStatus?("Loading on port \(launchPort)...")
            }
            // `spawn` releases the reservation's held socket the instant before
            // `process.run()`.
            launched = try ManagedServerProcess.spawn(
                executablePath: serverPath,
                arguments: arguments,
                spec: Self.serverSpec,
                releasing: reservation
            )
        } catch {
            serverLock.unlock()
            log("Failed to start worker: \(error.localizedDescription)")
            print("[WhisperEngine] failed to start worker: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.onWorkerStatus?("Worker unavailable")
            }
            // A spawn failure is a launch failure, not a user cancellation —
            // eligible for a retry on a fresh port (matching prior behavior).
            return .healthFailed
        }

        let process = launched.process

        // Commit the freshly-started process into shared state and bump the
        // generation so a concurrent stop/replace can be detected after we
        // release the lock.
        serverGeneration += 1
        let myGeneration = serverGeneration
        startingGeneration = myGeneration
        serverProcess = process
        serverModelPath = modelPath
        serverStdoutPipe = launched.stdoutPipe
        serverStderrPipe = launched.stderrPipe
        ManagedServerProcess.writePID(process.processIdentifier, spec: Self.serverSpec)

        serverLock.unlock()

        // --- Phase 2: wait for health WITHOUT holding the lock ---------------
        // `stopServer()` can bump `serverGeneration` to make this loop bail early.
        let healthy = waitForHealth(timeout: 45, generation: myGeneration, process: process)

        // --- Phase 3: re-acquire to commit success or tear down on failure ---
        serverLock.lock()
        defer { serverLock.unlock() }

        // Our startup is no longer in flight (only clear it if a newer startup
        // hasn't claimed the marker after tearing us down).
        if startingGeneration == myGeneration {
            startingGeneration = nil
        }

        // If a concurrent stop/replace happened, the process we started is no
        // longer the current one — don't touch shared state, just bail. This is
        // a CANCELLATION (the user stopped/switched, or is quitting), NOT a
        // health failure: the outer loop must NOT retry, or attempt N+1 would
        // relaunch a server the user just tore down (an orphan on quit). This is
        // the crux of MAK-28 review #2.
        guard serverGeneration == myGeneration, serverProcess === process else {
            // Our process was already torn down (or replaced) by someone else.
            if process.isRunning {
                process.terminate()
            }
            return .cancelled
        }

        if healthy, process.isRunning {
            // Capture under the lock (held via the phase-3 defer) so the
            // deferred status closure doesn't read `serverPort` unsynchronized.
            let loadedPort = serverPort
            DispatchQueue.main.async {
                self.onWorkerStatus?("Loaded on port \(loadedPort)")
            }
            return .launched
        }

        // Health failed (or process died) while our generation is still current:
        // a lost port-bind race or a crashed child. Tear down the server we own
        // and report a retryable health failure.
        stopServerLocked()
        DispatchQueue.main.async {
            self.onWorkerStatus?("Worker unavailable")
        }
        return .healthFailed
    }

    /// Must be called with `serverLock` held. Bumps `serverGeneration` so any
    /// in-progress `ensureServer`/`waitForHealth` for the current server bails
    /// out instead of committing or blocking on the doomed process.
    private func stopServerLocked() {
        // Invalidate any in-progress health wait for the current generation.
        serverGeneration += 1

        ManagedServerProcess.stopDraining(stdoutPipe: serverStdoutPipe, stderrPipe: serverStderrPipe)
        if let process = serverProcess, process.isRunning {
            ManagedServerProcess.terminateAsync(process)
        }
        serverProcess = nil
        serverModelPath = nil
        serverStdoutPipe = nil
        serverStderrPipe = nil
        try? FileManager.default.removeItem(at: Self.serverSpec.pidFileURL)
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

    /// Polls `/health` until it succeeds, the timeout elapses, the server
    /// generation changes out from under us (set by `stopServer()` /
    /// `stopServerLocked()`), or the child process dies. Runs WITHOUT
    /// `serverLock` held so a concurrent stop can bail it out early. Returns
    /// false if cancelled.
    private func waitForHealth(timeout: TimeInterval, generation: Int, process: Process?) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Bail early if our server was stopped or replaced.
            serverLock.lock()
            let cancelled = serverGeneration != generation
            serverLock.unlock()
            if cancelled {
                return false
            }
            // Child died (crash, bad model, failed bind) — fail fast instead of
            // polling a corpse's /health for the full timeout.
            if let process, !process.isRunning {
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
        guard let url = URL(string: "http://127.0.0.1:\(currentPort)/health") else { return false }
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

    private func postInference(wavPath: String, language: String, prompt: String = "") throws -> WhisperResponseClassifier.Outcome {
        let port = currentPort
        guard let url = URL(string: "http://127.0.0.1:\(port)/inference") else {
            throw WhisperWorkerError.invalidURL
        }

        let boundary = "OpenWhispBoundary-\(UUID().uuidString)"
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
        log("Server API POST /inference port=\(port), wav=\(URL(fileURLWithPath: wavPath).lastPathComponent), bytes=\(fileSize), language=\(language)")

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

        // Classify the (status, body) pair with the pure, unit-tested core. It
        // distinguishes a real transcript, a clean "no speech" empty, and a
        // genuine failure (non-200 or malformed body) — see MAK-23.
        let outcome = WhisperResponseClassifier.classify(statusCode: http.statusCode, body: resultData)

        switch outcome {
        case .error(let message):
            // Avoid persisting full response bodies: on some servers an error
            // body can echo back request content (potentially transcript text).
            #if DEBUG
            log("Server API HTTP \(http.statusCode): \(message.prefix(2000))")
            #else
            log("Server API HTTP \(http.statusCode) (\(resultData.count) bytes)")
            #endif
        case .cleanEmpty:
            // Server ran fine but heard no speech — a clean no-op, not an error.
            log("Server API response HTTP \(http.statusCode), textLen=0 (no speech)")
            print("[WhisperEngine] worker result: \"\" (len=0, no speech)")
        case .transcript(let text):
            // Do NOT log the raw body: it contains the transcript and is written
            // to a persistent, never-rotated cache log. Only record the length.
            log("Server API response HTTP \(http.statusCode), textLen=\(text.count)")
            print("[WhisperEngine] worker result: \"\(text)\" (len=\(text.count))")
        }

        return outcome
    }

    private func multipartBody(boundary: String, wavPath: String, language: String, prompt: String = "") throws -> Data {
        var data = Data()

        func appendField(_ name: String, _ value: String) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            data.append("\(value)\r\n".data(using: .utf8)!)
        }

        // Same mapping as the CLI path (see WhisperTask): the translate-to-English
        // sentinel is sent as translate=true + language=auto.
        let task = WhisperTask.resolve(languageSetting: language)
        appendField("response_format", "json")
        appendField("temperature", "0.0")
        appendField("temperature_inc", "0.2")
        appendField("no_speech_thold", "0.6")
        appendField("no_timestamps", "true")
        appendField("language", task.language)
        if task.translate {
            appendField("translate", "true")
        }
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

    /// Loopback port range this engine picks from. Disjoint from
    /// `LlamaServerEngine.portRange` so the two engines probing concurrently at
    /// startup can never land on the same candidate — the "sibling race" in
    /// MAK-28. Whisper uses the lower half, llama the upper.
    static let portRange: ClosedRange<Int> = 8178...8677

    static func logFileURL() -> URL { serverSpec.logFileURL }

    private func log(_ message: String) {
        ManagedServerProcess.appendLog(message, spec: Self.serverSpec)
    }

    /// Directory prefixes under which a whisper-server we launched can live:
    /// the app bundle's `Resources/whisper` dir and the dev build dir. Kept in
    /// sync with `serverBinaryPath(for:)`'s resolution order.
    ///
    /// NOTE: `serverBinaryPath(for:)` can also launch a server sibling to the
    /// selected `whisper-cli` binary, but that path depends on the runtime CLI
    /// selection which isn't known here (stale reaping runs in `init()`, before
    /// any transcription). A sibling-layout server therefore won't be reaped as
    /// stale — it fails the identity check and is left alone. That is the safe
    /// direction (never signal a process we can't positively identify as ours);
    /// the far worse alternative was SIGKILLing an unrelated user process.
    private static func ownedServerPrefixes() -> [String] {
        var prefixes: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("whisper").path {
            prefixes.append(bundled)
        }
        prefixes.append("\(NSHomeDirectory())/whisper.cpp/build/bin")
        return prefixes
    }
}

enum WhisperWorkerError: LocalizedError {
    case invalidURL
    case emptyResponse
    case serverError(String)
    case unavailable
    // NOTE: `.emptyTranscript` was removed in MAK-23. An empty/whitespace-only
    // transcript from a healthy 200 is no longer an error — it is a clean
    // "no speech detected" empty (classified as `.cleanEmpty` and delivered via
    // onTranscriptionComplete(requestID, "")), matching the CLI path's no-op.
    // `.emptyResponse` still covers a genuinely absent HTTP response (no body /
    // no HTTPURLResponse), which IS a transport failure.

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
        }
    }
}
