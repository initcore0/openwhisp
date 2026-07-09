import Foundation

/// Platform glue (Process/Pipe) that actually runs the **agent-CLI enhancement
/// provider** built by the pure `AgentCLIProvider`: it resolves the executable,
/// spawns it with the operator-configured argv, feeds the transcript on **stdin**
/// (never argv — see `AgentCLIProvider` for the injection-safety story), enforces
/// a hard timeout, and resolves the result **fail-open** (any failure keeps the
/// original transcript).
///
/// This mirrors `ScriptRunner` — the same stdin→stdout, off-thread I/O, timeout,
/// and SIGTERM→SIGKILL escalation — but drives an `[argv]` from a provider config
/// instead of a single script path, and PATH-resolves a bare command name so
/// `claude`/`codex` work without the user hard-coding `/opt/homebrew/bin/…`.
///
/// It is intentionally thin: the interesting, testable decisions (argv assembly,
/// outcome resolution) live in the pure `AgentCLIProvider` in OpenWhispCore. The
/// AppState provider-selection UI that would let a user pick this as their refine
/// engine is a deferred follow-up; this is the runnable engine underneath it.
enum AgentCLIRunner {
    /// Run the transcript through the configured agent CLI.
    ///
    /// - Returns: the text to insert — the CLI's cleaned stdout on a clean
    ///   success, otherwise the ORIGINAL `input` (fail-open on missing CLI,
    ///   non-zero exit, timeout, or empty output). Never returns nil / loses text.
    static func run(_ input: String, config: AgentCLIProvider.Config) -> String {
        // Assemble argv purely (validates the config, guards against the
        // transcript ever reaching argv). A build failure = fail open.
        let command: AgentCLIProvider.Command
        switch AgentCLIProvider.buildCommand(config: config) {
        case .success(let c): command = c
        case .failure:
            return AgentCLIProvider.resolvedText(
                original: input, stdout: nil, exitCode: nil, timedOut: false, launchFailed: true
            )
        }

        // Resolve the executable: an absolute/relative path is used as-is;
        // a bare name is looked up on PATH (so `claude`/`codex` just work).
        guard let executableURL = resolveExecutable(command.executable) else {
            return AgentCLIProvider.resolvedText(
                original: input, stdout: nil, exitCode: nil, timedOut: false, launchFailed: true
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = command.arguments        // fixed args only — NO transcript

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Discard stderr so a chatty CLI can't block on a full, undrained pipe.
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            return AgentCLIProvider.resolvedText(
                original: input, stdout: nil, exitCode: nil, timedOut: false, launchFailed: true
            )
        }
        let pid = process.processIdentifier
        // Best-effort: put the child in its own process group so a timeout can
        // group-kill any subprocesses it spawned (reuses ScriptTimeoutKill's
        // policy). Races the child's exec, so it's not guaranteed — the direct
        // kill(pid) below is the guaranteed reaper.
        setpgid(pid, pid)

        // Feed the transcript on stdin off-thread, then close so the CLI sees EOF.
        // NOSIGPIPE turns a write-to-dead-reader into EPIPE (swallowed) instead of
        // SIGPIPE (which would kill the whole app).
        let stdinHandle = stdinPipe.fileHandleForWriting
        _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        let inputData = Data(input.utf8)
        let writeQueue = DispatchQueue(label: "com.openwhisp.app.agentcli-write")
        let writeGroup = DispatchGroup()
        writeQueue.async(group: writeGroup) {
            try? stdinHandle.write(contentsOf: inputData)
            try? stdinHandle.close()
        }

        // Read stdout off-thread so a chatty CLI can't deadlock us.
        var stdoutData = Data()
        let readQueue = DispatchQueue(label: "com.openwhisp.app.agentcli-read")
        let readGroup = DispatchGroup()
        readQueue.async(group: readGroup) {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Enforce the timeout: wait up to `config.timeout`, then escalate a kill.
        let deadline = DispatchTime.now() + config.timeout
        var timedOut = false
        let waitQueue = DispatchQueue(label: "com.openwhisp.app.agentcli-wait")
        let waitGroup = DispatchGroup()
        waitQueue.async(group: waitGroup) {
            process.waitUntilExit()
        }
        if waitGroup.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()                       // SIGTERM to the child
            if waitGroup.wait(timeout: .now() + 0.25) == .timedOut {
                // Escalate to SIGKILL, reusing the pure kill-target policy shared
                // with ScriptRunner: group-kill only when the child leads its own
                // group (setpgid took), always direct-kill as the guaranteed reaper.
                for target in ScriptTimeoutKill.targets(
                    pid: pid, resolvedPgid: getpgid(pid), ownPgid: getpgid(0)
                ) {
                    kill(target.killArg, SIGKILL)
                }
            }
        }

        // Establish happens-before on stdoutData: on the happy path the reader
        // hits EOF on its own; if a killed CLI left a grandchild holding the pipe,
        // force EOF by closing the read end, then join.
        if readGroup.wait(timeout: .now() + 0.5) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            readGroup.wait()
        }

        // Join the stdin feeder so we don't leak a blocked writer thread.
        if writeGroup.wait(timeout: .now() + 0.5) == .timedOut {
            try? stdinHandle.close()
            _ = writeGroup.wait(timeout: .now() + 0.5)
        }

        let exitCode: Int32? = timedOut ? nil : process.terminationStatus
        let stdout = String(data: stdoutData, encoding: .utf8)
        return AgentCLIProvider.resolvedText(
            original: input,
            stdout: stdout,
            exitCode: exitCode,
            timedOut: timedOut,
            launchFailed: false
        )
    }

    /// Resolve the configured command to an executable file URL.
    ///
    /// - A path (contains `/`) is used directly iff it's an executable file.
    /// - A bare name is looked up against `PATH` (mirroring shell resolution),
    ///   with a couple of common Homebrew locations appended so a bundled/LaunchAgent
    ///   process with a minimal PATH still finds `claude`/`codex`.
    private static func resolveExecutable(_ command: String) -> URL? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fm = FileManager.default

        if trimmed.contains("/") {
            return fm.isExecutableFile(atPath: trimmed) ? URL(fileURLWithPath: trimmed) : nil
        }

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var dirs = pathEnv.split(separator: ":").map(String.init)
        dirs.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(trimmed)
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
