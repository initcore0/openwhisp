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
    /// (re)launch rather than cached once at init — see MAK-28. Being a `var`
    /// mutated under the lock, reads that run WITHOUT the lock (`healthCheck`,
    /// and external callers via `baseURL`/`port`) go through the lock-guarded
    /// `port`/`baseURL` accessors, not `serverPort` directly.
    private var serverPort: Int
    private let serverLock = NSLock()
    private var serverProcess: Process?
    private var serverModelPath: String?
    private var serverStdoutPipe: Pipe?
    private var serverStderrPipe: Pipe?

    /// Identity (basename, PID/log file names, log tag) of the llama-server this
    /// engine manages. Drives the shared `ManagedServerProcess` glue.
    private static let serverSpec = ManagedServerSpec(
        executableBasename: "llama-server",
        logTag: "llama-server",
        pidFileName: "llama-server.pid",
        logFileName: "llama-engine.log"
    )

    /// This instance's spec. Defaults to the production identity; a SECOND
    /// in-process engine (the LLM Lab bench runner) must pass its own spec —
    /// with the shared PID file, one engine's init-time stale-reap would SIGTERM
    /// the OTHER engine's live server (reapStaleServer can't tell "orphan from a
    /// previous crash" from "sibling instance in this process"), and both would
    /// fight over the PID file's contents.
    private let spec: ManagedServerSpec

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
    /// the dual-engine (resident whisper-server) configuration. Written from the
    /// main actor (AppState) while `scheduleIdleTeardownLocked` reads it on
    /// background queues — guarded by `serverLock` like the rest of the state
    /// (the locked paths read `_idleTimeout` directly).
    var idleTimeout: TimeInterval {
        get { serverLock.lock(); defer { serverLock.unlock() }; return _idleTimeout }
        set { serverLock.lock(); defer { serverLock.unlock() }; _idleTimeout = newValue }
    }
    private var _idleTimeout: TimeInterval = 90
    private var inFlight = 0

    init(spec: ManagedServerSpec = LlamaServerEngine.serverSpec) {
        self.spec = spec
        // The init-time port is a placeholder; each (re)launch reserves a FRESH
        // port (MAK-28). Reserve-and-immediately-release just to seed a plausible
        // value for logging.
        if let reservation = ManagedServerProcess.reservePort(in: Self.portRange) {
            serverPort = reservation.port
            reservation.release()
        } else {
            serverPort = Self.portRange.lowerBound
        }
        ManagedServerProcess.reapStaleServer(spec: spec, ownedPrefixes: Self.ownedServerPrefixes())
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
    /// `callerHoldsRequestBracket`: pass true when the caller already ran
    /// `requestStarted()` for the request this call precedes (the production
    /// refine path does, so idle teardown can't race the gap). The busy
    /// fast-path below must not count that bracket as "another generation in
    /// flight" — otherwise its `inFlight > 0` check is a tautology on the
    /// refine path and a wedged-but-alive server is never relaunched.
    func ensureRunning(
        modelPath: String,
        attemptsRemaining: Int = 3,
        callerHoldsRequestBracket: Bool = false,
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
                // Probe missed but the child is ALIVE on the same model with a
                // request in flight: don't tear it down. The probe budget is
                // aggressive (1s request / 1.2s wait), so "busy generating" or
                // "paging the model back in" is indistinguishable from "dead" —
                // and SIGTERMing here would kill the live generation (its refine
                // falls open to raw text) and pay a full cold start. Report
                // success and let the actual request surface any real failure.
                // The idle-teardown handler applies the same inFlight courtesy.
                if self.serverGeneration == probedGeneration,
                   self.serverModelPath == modelPath,
                   self.serverProcess?.isRunning == true,
                   self.inFlight > (callerHoldsRequestBracket ? 1 : 0) {
                    self.serverLock.unlock()
                    self.noteActivity()
                    completion(.success(()))
                    return
                }
                // Unhealthy-and-idle, or stopped/replaced while probing — fall
                // through (lock re-held) to coalesce or relaunch.
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

            // Reserve a FRESH port for this launch instead of reusing the one
            // cached at init. The reservation HOLDS its bind-probe socket open
            // until the instant before the child binds (MAK-21 TOCTOU fix), so a
            // concurrent in-process start can't pick the same port and the
            // bind-then-child-run window shrinks to a couple of instructions.
            // Re-picking + the retry below is the MAK-28 fix. Keep the previous
            // port if discovery fails so we still attempt a launch.
            let reservation = ManagedServerProcess.reservePort(in: Self.portRange)
            if let reservation {
                self.serverPort = reservation.port
            }

            let arguments = [
                "--host", "127.0.0.1",
                "--port", "\(self.serverPort)",
                "-m", modelPath,
                "-c", "2048",
                "-ngl", "99",
                "--no-webui"
            ]
            self.log("Starting llama-server: \(serverPath) \(arguments.joined(separator: " "))")

            let launched: ManagedServerProcess.Launched
            do {
                // `spawn` releases the reservation's held socket the instant
                // before `process.run()`.
                launched = try ManagedServerProcess.spawn(
                    executablePath: serverPath,
                    arguments: arguments,
                    spec: self.spec,
                    releasing: reservation
                )
            } catch {
                self.serverLock.unlock()
                self.log("Failed to start llama-server: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            let process = launched.process
            self.serverGeneration += 1
            let myGeneration = self.serverGeneration
            self.serverProcess = process
            self.serverModelPath = modelPath
            self.serverStdoutPipe = launched.stdoutPipe
            self.serverStderrPipe = launched.stderrPipe
            self.starting = true
            self.startingModelPath = modelPath
            self.pendingCompletions = [completion]
            ManagedServerProcess.writePID(process.processIdentifier, spec: self.spec)

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
                        // The retry can't tell which waiter held a request
                        // bracket; pass false so the busy fast-path stays
                        // conservative (worst case: an extra relaunch).
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
        timer.schedule(deadline: .now() + _idleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.serverLock.lock()
            // Identity check: a handler that has already FIRED and is blocked on
            // the lock isn't stopped by `cancel()` — a (re)start could replace
            // this timer and spawn a fresh child while we wait, and acting then
            // would SIGTERM the seconds-old server (a warm-up has no inFlight
            // bracket to protect it). Only the CURRENT timer may act.
            guard timer === self.idleTimer else {
                self.serverLock.unlock()
                return
            }
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

        ManagedServerProcess.stopDraining(stdoutPipe: serverStdoutPipe, stderrPipe: serverStderrPipe)
        if let process = serverProcess, process.isRunning {
            ManagedServerProcess.terminateAsync(process)
        }
        serverProcess = nil
        serverModelPath = nil
        serverStdoutPipe = nil
        serverStderrPipe = nil
        try? FileManager.default.removeItem(at: spec.pidFileURL)
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
        // `serverPort` is a `var` re-picked per launch under `serverLock`;
        // healthCheck always runs WITHOUT the lock held, so read the port via the
        // lock-guarded `port` accessor to avoid a data race (MAK-28 review #3).
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
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
    /// MAK-28. Llama uses the upper band; whisper the lower. The bands (and their
    /// tested disjointness) live in the pure core `LoopbackPortRanges` (MAK-85).
    static let portRange: ClosedRange<Int> = LoopbackPortRanges.llama

    // MARK: - Logging

    static func logFileURL() -> URL { serverSpec.logFileURL }

    private func log(_ message: String) {
        ManagedServerProcess.appendLog(message, spec: spec)
    }

    // MARK: - Owned paths

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
}
