import Foundation
import Darwin

// MARK: - Llama Server Engine
//
// Manages a bundled llama.cpp `llama-server` as a loopback subprocess for the
// built-in (offline) text-refinement provider. It is a near-clone of
// `WhisperEngine`'s server half (loopback port, /health poll, generation-counter
// concurrency guard, PID-file stale reaping) with two additions that matter for
// an LLM:
//
//   * LAZY start — the server is launched on the first refinement, not at app
//     launch, so we don't hold ~0.7-1.5 GB resident when the feature is idle.
//   * IDLE teardown — after a quiet period the server is stopped to free RAM.
//     An in-flight request count keeps teardown from killing a live generation.
//
// It owns its own port and PID file, and bundles its dylibs under
// Resources/llama/lib, so it never collides with whisper-server (different ggml
// ABI — see scripts/bundle-llama-runtime.sh).
//
// Pure Foundation/Darwin/Process — no compile-time dependency on llama being
// built. If the binary is absent, `ensureRunning` fails gracefully at runtime so
// a whisper-only build still compiles and runs.
final class LlamaServerEngine {

    enum LlamaError: LocalizedError {
        case unavailable
        case modelMissing

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The built-in LLM server could not be started or did not become healthy."
            case .modelMissing:
                return "The built-in LLM model file was not found. Download it in Settings."
            }
        }
    }

    /// Loopback port the server binds. Re-picked (under `serverLock`) at each
    /// (re)launch rather than cached once at init — see MAK-28. Read by
    /// `baseURL`/`port`/`healthCheck` while a launched server owns it.
    private var serverPort: Int
    private let serverLock = NSLock()
    private var serverProcess: Process?
    private var serverModelPath: String?
    private var serverStdoutPipe: Pipe?
    private var serverStderrPipe: Pipe?
    private let pidFileURL: URL

    /// Generation counter, guarded by `serverLock`. Bumped on every start/stop/
    /// replace so a concurrent operation can detect that the process it was
    /// waiting on is no longer current. Mirrors WhisperEngine.
    private var serverGeneration: Int = 0

    // Concurrent-start coalescing: while a start for `startingModelPath` is in
    // flight, additional ensureRunning callers for the SAME model enqueue their
    // completions here instead of tearing down and relaunching.
    private var starting = false
    private var startingModelPath: String?
    private var pendingCompletions: [(Result<Void, Error>) -> Void] = []

    // Idle teardown.
    private var idleTimer: DispatchSourceTimer?
    private let idleQueue = DispatchQueue(label: "com.openwhisp.llama.idle")
    /// Seconds of inactivity before the server is torn down. Tunable; lowered in
    /// the dual-engine (resident whisper-server) configuration.
    var idleTimeout: TimeInterval = 90
    private var inFlight = 0

    init() {
        serverPort = Self.availableLoopbackPort(in: Self.portRange) ?? Self.portRange.lowerBound
        pidFileURL = Self.serverPIDFileURL()
        Self.stopStaleServerIfNeeded(pidFileURL: pidFileURL)
        log("LlamaServerEngine initialized with server port \(serverPort)")
    }

    deinit {
        serverLock.lock()
        stopServerLocked()
        serverLock.unlock()
    }

    /// Base URL the OpenAI-compatible client should POST to, e.g.
    /// "http://127.0.0.1:54321/v1". The port is re-picked per (re)launch
    /// (MAK-28), so callers read this fresh AFTER `ensureRunning` reports the
    /// server healthy — which is when the current port is committed.
    var baseURL: String {
        serverLock.lock()
        defer { serverLock.unlock() }
        return "http://127.0.0.1:\(serverPort)/v1"
    }
    var port: Int {
        serverLock.lock()
        defer { serverLock.unlock() }
        return serverPort
    }

    /// Path of the model the server is currently loaded with, or nil if no server
    /// is running. Used by the dev status indicator to show what's actually live
    /// (which can differ briefly from the selected model during a switch/teardown).
    var runningModelPath: String? {
        serverLock.lock()
        defer { serverLock.unlock() }
        return (serverProcess?.isRunning == true) ? serverModelPath : nil
    }

    /// PID of the running llama-server, or nil if stopped. For the dev HUD's
    /// per-process memory/CPU sampling.
    var runningPID: Int32? {
        serverLock.lock()
        defer { serverLock.unlock() }
        guard let p = serverProcess, p.isRunning else { return nil }
        return p.processIdentifier
    }

    // MARK: - Lazy start

    /// Ensure a healthy llama-server is running for `modelPath`. Lazy: starts the
    /// process if needed, reuses it if already healthy on the same model, relaunches
    /// if the model changed. Coalesces concurrent starts for the same model.
    /// Completion runs off the main thread.
    ///
    /// `attemptsRemaining` bounds the MAK-28 retry: a launch that fails its
    /// health check (the way a lost port-bind race surfaces) re-drives this
    /// method on a FRESH port until the budget is exhausted. Callers use the
    /// default; the retry supplies a decremented value.
    func ensureRunning(
        modelPath: String,
        attemptsRemaining: Int = 3,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            completion(.failure(LlamaError.modelMissing))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            self.serverLock.lock()

            // Fast path: already healthy on this exact model. healthCheck()
            // can block for up to ~1.2s, so probe WITHOUT the lock (a blocked
            // lock stalls main-actor callers like requestStarted) and
            // re-validate the generation before committing, mirroring
            // waitForHealth.
            if !self.starting,
               self.serverModelPath == modelPath,
               self.serverProcess?.isRunning == true {
                let probedGeneration = self.serverGeneration
                self.serverLock.unlock()
                let healthy = self.healthCheck()
                self.serverLock.lock()
                if healthy, self.serverGeneration == probedGeneration {
                    self.serverLock.unlock()
                    self.noteActivity()
                    completion(.success(()))
                    return
                }
                // Unhealthy, or stopped/replaced while probing — fall through
                // (lock re-held) to coalesce or relaunch.
            }

            // Coalesce: a start for the SAME model is already in flight — wait on it.
            if self.starting, self.startingModelPath == modelPath {
                self.pendingCompletions.append(completion)
                self.serverLock.unlock()
                return
            }

            // Model differs or server is dead — tear down and (re)launch.
            self.stopServerLocked()

            guard let serverPath = self.serverBinaryPath() else {
                self.serverLock.unlock()
                self.log("llama-server binary unavailable")
                completion(.failure(LlamaError.unavailable))
                return
            }

            // Pick a FRESH port for this launch instead of reusing the one cached
            // at init. Reusing one port across restarts widens the window in which
            // the child hasn't bound yet and something else can claim it; re-picking
            // (plus the retry below) is the MAK-28 fix. Keep the previous port if
            // discovery fails so we still attempt a launch.
            if let freshPort = Self.availableLoopbackPort(in: Self.portRange) {
                self.serverPort = freshPort
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: serverPath)
            process.arguments = [
                "--host", "127.0.0.1",
                "--port", "\(self.serverPort)",
                "-m", modelPath,
                "-c", "2048",
                "-ngl", "99",
                "--no-webui"
            ]
            self.log("Starting llama-server: \(serverPath) \(process.arguments?.joined(separator: " ") ?? "")")

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // EOF: unhook, or the dispatch read source fires forever.
                    handle.readabilityHandler = nil
                    return
                }
                if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                    print("[llama-server] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                    print("[llama-server] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                self.serverLock.unlock()
                self.log("Failed to start llama-server: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            self.serverGeneration += 1
            let myGeneration = self.serverGeneration
            self.serverProcess = process
            self.serverModelPath = modelPath
            self.serverStdoutPipe = stdoutPipe
            self.serverStderrPipe = stderrPipe
            self.starting = true
            self.startingModelPath = modelPath
            self.pendingCompletions = [completion]
            self.writeServerPID(process.processIdentifier)

            self.serverLock.unlock()

            // Wait for health WITHOUT holding the lock. llama load is heavier
            // than whisper's, so allow a longer timeout.
            let healthy = self.waitForHealth(timeout: 60, generation: myGeneration, process: process)

            self.serverLock.lock()

            // A concurrent stop/replace happened — our process is no longer
            // current. stopServerLocked already drained-and-failed our waiters,
            // and a NEWER start may have installed its own starting state and
            // waiters, which we must not touch.
            guard self.serverGeneration == myGeneration, self.serverProcess === process else {
                self.serverLock.unlock()
                if process.isRunning { process.terminate() }
                return
            }

            self.starting = false
            self.startingModelPath = nil
            let waiters = self.pendingCompletions
            self.pendingCompletions = []

            if healthy, process.isRunning {
                self.scheduleIdleTeardownLocked()
                self.serverLock.unlock()
                self.log("llama-server healthy on port \(self.serverPort) for \(modelPath)")
                waiters.forEach { $0(.success(())) }
            } else {
                self.stopServerLocked()
                self.serverLock.unlock()
                if attemptsRemaining > 1 {
                    // A failed launch (e.g. a lost port-bind race — MAK-28)
                    // surfaces here as a health failure. stopServerLocked reset
                    // the start/coalesce state and bumped the generation, so
                    // re-driving ensureRunning starts a clean attempt on a FRESH
                    // port. Re-drive once per waiter: the first relaunches, the
                    // rest coalesce onto it via the normal in-flight path.
                    self.log("llama-server failed health check; retrying on a fresh port (\(attemptsRemaining - 1) left)")
                    for waiter in waiters {
                        self.ensureRunning(
                            modelPath: modelPath,
                            attemptsRemaining: attemptsRemaining - 1,
                            completion: waiter
                        )
                    }
                } else {
                    self.log("llama-server failed health check")
                    waiters.forEach { $0(.failure(LlamaError.unavailable)) }
                }
            }
        }
    }

    // MARK: - In-flight tracking + idle teardown

    /// Call when a refinement request starts so idle teardown can't kill a live
    /// generation.
    func requestStarted() {
        serverLock.lock()
        inFlight += 1
        serverLock.unlock()
    }

    /// Call when a refinement request finishes (success or failure). Re-arms the
    /// idle timer from the END of the request.
    func requestFinished() {
        serverLock.lock()
        inFlight = max(0, inFlight - 1)
        scheduleIdleTeardownLocked()
        serverLock.unlock()
    }

    /// Re-arm the idle teardown timer.
    func noteActivity() {
        serverLock.lock()
        scheduleIdleTeardownLocked()
        serverLock.unlock()
    }

    /// Must be called with `serverLock` held — `idleTimer` is guarded by it
    /// (it's mutated from the start path, the timer's own handler, and
    /// main-actor callers via noteActivity/requestFinished).
    private func scheduleIdleTeardownLocked() {
        let timer = DispatchSource.makeTimerSource(queue: idleQueue)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.serverLock.lock()
            if self.inFlight > 0 {
                // Don't kill a live generation — reschedule.
                self.scheduleIdleTeardownLocked()
            } else {
                self.stopServerLocked()
            }
            self.serverLock.unlock()
        }
        // Replace any existing timer.
        idleTimer?.cancel()
        idleTimer = timer
        timer.resume()
    }

    func stopServer() {
        serverLock.lock()
        stopServerLocked()
        serverLock.unlock()
    }

    /// Must be called with `serverLock` held. Bumps `serverGeneration` so any
    /// in-progress start/health-wait bails out instead of committing, and fails
    /// any completions queued on an in-flight start — their server is going
    /// away, and leaving them queued would let a NEW start's epilogue drain
    /// waiters that were never its own (or drop them entirely).
    private func stopServerLocked() {
        serverGeneration += 1
        idleTimer?.cancel()
        idleTimer = nil

        starting = false
        startingModelPath = nil
        let dropped = pendingCompletions
        pendingCompletions = []
        if !dropped.isEmpty {
            // Off the lock — a completion may re-enter the engine.
            DispatchQueue.global(qos: .userInitiated).async {
                dropped.forEach { $0(.failure(LlamaError.unavailable)) }
            }
        }

        serverStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        serverStderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = serverProcess, process.isRunning {
            Self.terminateAsync(process)
        }
        serverProcess = nil
        serverModelPath = nil
        serverStdoutPipe = nil
        serverStderrPipe = nil
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// SIGTERM the process now, then escalate to SIGKILL on a background queue
    /// if it hasn't exited within ~2s. Never blocks the caller: `stopServer()`
    /// runs synchronously on the main actor (Settings toggles, quit) with
    /// `serverLock` held, and llama-server can take seconds to free a large
    /// model. Its SIGTERM handler closes the listen socket immediately, so a
    /// replacement server can bind the port while the old one drains. Mirrors
    /// WhisperEngine.terminateAsync.
    ///
    /// The graceful `terminate()` targets the retained `Process` (Foundation
    /// reaps it via waitpid, so it can't hit a recycled PID). The raw SIGKILL
    /// escalation uses the cached numeric PID, so before sending it we re-verify
    /// the PID still names OUR llama-server — otherwise, if the child exited and
    /// its PID was recycled in the escalation window, we'd SIGKILL an unrelated
    /// process. `process.isRunning` alone doesn't close that window.
    private static func terminateAsync(_ process: Process) {
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<20 where process.isRunning {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning, isOwnLlamaServerProcess(pid: pid) {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Binary resolution

    private func serverBinaryPath() -> String? {
        Self.resolvedServerBinaryPath()
    }

    /// Whether this build can run the built-in LLM at all — i.e. a llama-server
    /// binary exists (bundled in Resources/llama, or a dev build). False for an
    /// app packaged without the llama runtime; the Settings UI uses this to say
    /// so explicitly instead of failing every refine with a vague error.
    static func runtimeAvailable() -> Bool {
        resolvedServerBinaryPath() != nil
    }

    private static func resolvedServerBinaryPath() -> String? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("llama/llama-server")
            .path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        let defaultPath = "\(NSHomeDirectory())/llama.cpp/build/bin/llama-server"
        if FileManager.default.isExecutableFile(atPath: defaultPath) {
            return defaultPath
        }

        return nil
    }

    // MARK: - Health

    /// Polls `/health` until it succeeds, the timeout elapses, the child dies,
    /// or the server generation changes (a concurrent stop/replace). Runs
    /// WITHOUT `serverLock`.
    private func waitForHealth(timeout: TimeInterval, generation: Int, process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            serverLock.lock()
            let cancelled = serverGeneration != generation
            serverLock.unlock()
            if cancelled { return false }
            if healthCheck() { return true }
            // Child died (crash, bad model, failed bind) — fail fast instead
            // of polling a dead server for the rest of the timeout.
            if !process.isRunning { return false }
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
            // llama-server returns 200 once the model is loaded and ready.
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                ok = true
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.2)
        return ok
    }

    // MARK: - Port discovery

    /// Loopback port range this engine picks from. Disjoint from
    /// `WhisperEngine.portRange` so the two engines probing concurrently at
    /// startup can never land on the same candidate — the "sibling race" in
    /// MAK-28. Llama uses the upper band; whisper the lower.
    static let portRange: ClosedRange<Int> = 8678...9177

    /// Probes for a free loopback port inside `range` by attempting to bind each
    /// candidate (randomised order) and returning the first that binds. There is
    /// still a race window before the child re-binds it, closed by the caller
    /// retrying with a fresh port on a failed launch (MAK-28). Binding an
    /// explicit candidate (not port 0) is what keeps whisper and llama in
    /// disjoint ranges.
    private static func availableLoopbackPort(in range: ClosedRange<Int>) -> Int? {
        for candidate in range.shuffled() {
            if canBindLoopbackPort(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Attempts to bind `port` on 127.0.0.1; true iff the bind succeeds. Closes
    /// the probe socket before returning.
    private static func canBindLoopbackPort(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    // MARK: - PID file + stale reaping

    private func writeServerPID(_ pid: Int32) {
        do {
            try FileManager.default.createDirectory(
                at: pidFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "\(pid)".write(to: pidFileURL, atomically: true, encoding: .utf8)
        } catch {
            print("[LlamaServerEngine] failed to write PID: \(error.localizedDescription)")
        }
    }

    private static func serverPIDFileURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.openwhisp.app/llama-server.pid")
    }

    static func logFileURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.openwhisp.app/llama-engine.log")
    }

    private static func stopStaleServerIfNeeded(pidFileURL: URL) {
        guard
            let rawPID = try? String(contentsOf: pidFileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int32(rawPID),
            pid > 0
        else { return }

        // Only signal if the PID is alive AND its executable is actually OUR
        // llama-server (basename + path inside the app bundle or dev build dir).
        // After a crash + PID reuse the persisted PID can point at an unrelated
        // process — e.g. a user's Homebrew llama-server — which we must never
        // kill. Re-verify identity immediately before EACH signal: between
        // SIGTERM and the SIGKILL escalation the PID can be recycled, so a
        // liveness-only re-check would let us SIGKILL whatever inherited it.
        guard kill(pid, 0) == 0, isOwnLlamaServerProcess(pid: pid) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            return
        }

        print("[LlamaServerEngine] stopping stale llama-server pid \(pid)")
        kill(pid, SIGTERM)
        Thread.sleep(forTimeInterval: 0.5)
        if kill(pid, 0) == 0, isOwnLlamaServerProcess(pid: pid) {
            kill(pid, SIGKILL)
        }

        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// True only if `pid`'s executable basename is `llama-server` AND it resolves
    /// inside our app bundle (Resources/llama) or the dev build dir
    /// (llama.cpp/build/bin). Returns false if the path can't be resolved, so we
    /// never signal an unknown process. Shares the decision logic with
    /// WhisperEngine via `ServerProcessIdentity`.
    private static func isOwnLlamaServerProcess(pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        return ServerProcessIdentity.isOwnedServerProcess(
            executablePath: path,
            ownedPrefixes: ownedServerPrefixes(),
            expectedBasename: "llama-server"
        )
    }

    /// Directory prefixes under which a llama-server we launched can live: the
    /// app bundle's `Resources/llama` dir and the dev build dir. Kept in sync
    /// with `resolvedServerBinaryPath()`'s resolution order.
    private static func ownedServerPrefixes() -> [String] {
        var prefixes: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("llama").path {
            prefixes.append(bundled)
        }
        prefixes.append("\(NSHomeDirectory())/llama.cpp/build/bin")
        return prefixes
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let logFileURL = Self.logFileURL()
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
            print("[LlamaServerEngine] log write failed: \(error.localizedDescription)")
        }
    }
}
