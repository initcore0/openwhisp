import Foundation
import Darwin

// MARK: - Managed server process (app-only glue)

/// The shared *mechanical* subprocess lifecycle for OpenWhisp's two bundled
/// loopback servers — whisper-server (transcription) and llama-server (built-in
/// refine). Before MAK-21 each engine carried its own byte-for-byte copy of:
///
///   * `terminateAsync` — SIGTERM now, escalate to SIGKILL after ~2s, gated on
///     `Process.isRunning` (never on path identity — see the note below).
///   * log-drain pipes — two `Pipe`s whose `readabilityHandler`s forward child
///     stdout/stderr to `print` and unhook themselves on EOF.
///   * loopback-port acquisition — bind-probe a candidate in a disjoint range.
///   * stale-PID reaping — read a persisted PID and, only if it is alive AND
///     resolves to an executable we own, SIGTERM→SIGKILL it (PID-reuse safe).
///   * PID-file write + append-only engine log.
///
/// This type owns ALL of that. What it deliberately does NOT own is each engine's
/// bespoke concurrency state machine (generation counter, health-wait join /
/// coalescing, idle teardown): those invariants differ between the engines and
/// live on. `ManagedServerProcess` is stateless glue the engines call under
/// their own `serverLock`.
///
/// App-only (imports Darwin + Process); its pure decision inputs
/// (`ManagedServerSpec`, `StalePIDReaper`, `ServerProcessIdentity`) live in core
/// and are unit-tested.
enum ManagedServerProcess {

    // MARK: Port acquisition (TOCTOU-hardened)

    /// A loopback port whose bind-probe socket is held OPEN by the reservation.
    ///
    /// This is the MAK-21 fix for the llama-server port TOCTOU (a bind-then-close
    /// race). The old code bound a probe socket, closed it, returned the bare
    /// port int, and only much later spawned the child that re-binds it — a wide
    /// window in which another process (or a concurrent in-process start of the
    /// *sibling* engine) could claim the number. `ReservedPort` keeps the probe
    /// socket open from discovery until the instant before `spawn` runs
    /// `process.run()`, so:
    ///
    ///   1. a concurrent in-process `reservePort` can't `bind()` the same number
    ///      (the held socket owns it), closing the sibling-race window entirely; and
    ///   2. the gap between "we chose this port" and "the child binds it" shrinks
    ///      to the few instructions between `close()` and `run()`.
    ///
    /// The socket sets `SO_REUSEADDR` (as before) so the child — launched with the
    /// same option — can re-bind the moment we release it. The reservation MUST be
    /// released (via `spawn`, which consumes it, or `release()`); dropping it on
    /// the floor leaks the fd, so callers pass it straight into `spawn`.
    final class ReservedPort {
        let port: Int
        private var socketFD: Int32
        private var released = false

        fileprivate init(port: Int, socketFD: Int32) {
            self.port = port
            self.socketFD = socketFD
        }

        /// Close the held probe socket so the child can bind the port. Idempotent.
        func release() {
            guard !released else { return }
            released = true
            close(socketFD)
            socketFD = -1
        }

        deinit { release() }
    }

    /// Reserve a free loopback port inside `range`, holding its bind-probe socket
    /// open in the returned `ReservedPort` (see that type). Probes candidates in
    /// randomised order and returns the first that binds. Returns nil if the whole
    /// range is taken — the caller then keeps its previously-picked port and still
    /// attempts a launch, matching prior behavior.
    ///
    /// Binding an explicit candidate (not port 0) is what keeps whisper and llama
    /// in disjoint ranges; port 0 would let the kernel hand either engine any
    /// ephemeral port, re-opening the sibling collision.
    static func reservePort(in range: ClosedRange<Int>) -> ReservedPort? {
        for candidate in range.shuffled() {
            if let fd = boundLoopbackSocket(candidate) {
                return ReservedPort(port: candidate, socketFD: fd)
            }
        }
        return nil
    }

    /// Attempts to bind `port` on 127.0.0.1. On success returns the OPEN socket
    /// fd (the caller owns it, via `ReservedPort`); on failure closes any socket
    /// and returns nil.
    private static func boundLoopbackSocket(_ port: Int) -> Int32? {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }

        // Set SO_REUSEADDR so that the server (launched with the same option) can
        // re-bind this port the instant we release the probe socket. (This does
        // not by itself eliminate the race; the held socket + late release does.)
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
        guard bindResult == 0 else {
            close(socketFD)
            return nil
        }
        return socketFD
    }

    // MARK: Spawn

    /// A launched child plus the two log-drain pipes that must be retained (and
    /// later unhooked in `stopDraining`) for its lifetime.
    struct Launched {
        let process: Process
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
    }

    /// Spawn `executablePath` with `arguments`, wiring stdout/stderr to log-drain
    /// pipes tagged `spec.logTag`. Consumes `reservation`, releasing its held
    /// probe socket the instant before `process.run()` so the child can bind the
    /// port with the smallest possible race window (MAK-21 TOCTOU fix).
    ///
    /// Throws whatever `Process.run()` throws (spawn failure). On success returns
    /// the retained `Launched` bundle; the caller records it under its lock and
    /// is responsible for later `stopDraining` + `terminateAsync`.
    static func spawn(
        executablePath: String,
        arguments: [String],
        spec: ManagedServerSpec,
        releasing reservation: ReservedPort?
    ) throws -> Launched {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let tag = spec.logTag
        let drain: (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: unhook, or the dispatch read source fires forever.
                handle.readabilityHandler = nil
                return
            }
            if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                print("[\(tag)] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = drain
        stderrPipe.fileHandleForReading.readabilityHandler = drain
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Release the reserved port's socket as LATE as possible — right before
        // the child binds it — then launch.
        reservation?.release()
        try process.run()

        return Launched(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
    }

    /// Unhook a launched pair of pipes' readability handlers. Call under the
    /// engine's lock as the first step of teardown, before `terminateAsync`,
    /// mirroring the old inline `stopServerLocked` sequence.
    static func stopDraining(stdoutPipe: Pipe?, stderrPipe: Pipe?) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
    }

    // MARK: Terminate

    /// SIGTERM the process now, then escalate to SIGKILL on a background queue if
    /// it hasn't exited within ~2s. Never blocks the caller: `stopServer()` is
    /// invoked synchronously from the main actor (backend switch, quit, Settings
    /// toggles) with the engine's `serverLock` held, and a busy server can take
    /// seconds to finish its graceful shutdown. Its SIGTERM handler closes the
    /// listen socket immediately, so a replacement server can bind the port while
    /// the old one drains.
    ///
    /// Both signals target the RETAINED `Process`: SIGKILL is only sent while
    /// `process.isRunning` is still true, and a running child has NOT been reaped
    /// by Foundation's waitpid — so its PID cannot have been recycled out from
    /// under us. The path-prefix identity gate (`ServerProcessIdentity`)
    /// deliberately does NOT apply here: it exists to guard a bare PID read from a
    /// stale PID file (`reapStaleServer`), where recycling IS the risk. Applying
    /// it here would strand a server we legitimately launched but whose path is
    /// outside the owned prefixes (e.g. a `whisper-server` sibling to a
    /// user-selected Homebrew whisper-cli) — SIGTERM ignored mid-inference,
    /// SIGKILL never sent, leaking RAM + the bound port. See MAK-27 review #1.
    static func terminateAsync(_ process: Process) {
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<20 where process.isRunning {
                Thread.sleep(forTimeInterval: 0.1)
            }
            // Gate the SIGKILL on `isRunning` (not on path identity): a still-
            // running retained child hasn't been reaped, so `pid` is guaranteed
            // to still name it.
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: PID file

    /// Write `pid` to `spec.pidFileURL`, creating the Caches dir if needed. Errors
    /// are logged, not thrown — a missing PID file only weakens next-launch stale
    /// reaping, it doesn't break the running server.
    static func writePID(_ pid: Int32, spec: ManagedServerSpec) {
        let pidFileURL = spec.pidFileURL
        do {
            try FileManager.default.createDirectory(
                at: pidFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "\(pid)".write(to: pidFileURL, atomically: true, encoding: .utf8)
        } catch {
            print("[\(spec.logTag)] failed to write PID: \(error.localizedDescription)")
        }
    }

    // MARK: Stale reaping

    /// If `spec.pidFileURL` names a live process we own, stop it (SIGTERM, then
    /// SIGKILL after 0.5s if still alive), then delete the file. Called from each
    /// engine's `init()` to clean up a server orphaned by a previous crash/kill.
    ///
    /// PID-reuse safe: after a crash + PID reuse the persisted PID can point at an
    /// UNRELATED process (e.g. a user's own Homebrew server), which we must never
    /// kill. So we re-verify identity — liveness (`kill(pid, 0)`) AND an owned
    /// executable path (`ServerProcessIdentity`) — immediately before EACH signal;
    /// between SIGTERM and SIGKILL the PID can be recycled, so a liveness-only
    /// re-check would let us SIGKILL whatever inherited the number.
    static func reapStaleServer(spec: ManagedServerSpec, ownedPrefixes: [String]) {
        let pidFileURL = spec.pidFileURL
        let raw = try? String(contentsOf: pidFileURL, encoding: .utf8)
        guard let pid = StalePIDReaper.candidatePID(fromFileContents: raw) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            return
        }

        let isOwned: (Int32) -> Bool = { candidate in
            kill(candidate, 0) == 0 && isOwnServerProcess(
                pid: candidate,
                expectedBasename: spec.executableBasename,
                ownedPrefixes: ownedPrefixes
            )
        }

        guard isOwned(pid) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            return
        }

        print("[\(spec.logTag)] stopping stale \(spec.executableBasename) pid \(pid)")
        kill(pid, SIGTERM)
        Thread.sleep(forTimeInterval: 0.5)
        if isOwned(pid) {
            kill(pid, SIGKILL)
        }

        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// True only if `pid`'s resolved executable basename matches
    /// `expectedBasename` AND it lives under one of `ownedPrefixes`. Resolves the
    /// path via libproc; returns false if it can't, so we never signal an unknown
    /// process. The decision is the pure, unit-tested `ServerProcessIdentity`.
    static func isOwnServerProcess(
        pid: Int32,
        expectedBasename: String,
        ownedPrefixes: [String]
    ) -> Bool {
        // proc_pidpath wants PROC_PIDPATHINFO_MAXSIZE (== 4*MAXPATHLEN) of space;
        // that C macro isn't importable into Swift, so use its expansion directly.
        // A smaller buffer can truncate long paths, causing a real stale server to
        // fail the name check and not be cleaned up.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        return ServerProcessIdentity.isOwnedServerProcess(
            executablePath: path,
            ownedPrefixes: ownedPrefixes,
            expectedBasename: expectedBasename
        )
    }

    // MARK: Logging

    /// Append `message` (ISO-8601 timestamped) to `spec.logFileURL`, creating the
    /// Caches dir on first write. The engine's append-only log; errors are printed
    /// but never thrown.
    static func appendLog(_ message: String, spec: ManagedServerSpec) {
        let logFileURL = spec.logFileURL
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
            print("[\(spec.logTag)] log write failed: \(error.localizedDescription)")
        }
    }
}
