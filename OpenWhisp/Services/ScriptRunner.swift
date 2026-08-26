import Foundation

/// Runs a user-supplied script over the transcript: writes the text to the
/// script's stdin, reads stdout, enforces a hard timeout, and resolves the result
/// **fail-open** via `ScriptOutcome` (any failure keeps the original transcript).
///
/// This is the platform glue (Process/Pipe) around the pure `ScriptOutcome`
/// resolver. It is intentionally synchronous with a short timeout: the script
/// runs only at finalization (the UI already shows "Polishing…/Done"), it's
/// opt-in and off by default, and a bounded blocking call avoids weaving a new
/// async hop — and its session-race surface — into the finalize path.
enum ScriptRunner {
    /// - Returns: the text to insert (script output on success, else the input).
    ///
    /// The FAIL-OPEN entry point, and the right one for the dictation finalize path:
    /// the user's words must survive a broken script. A caller that asked for a
    /// TRANSFORM (a plugin's `runScript` step) wants `outcome(for:scriptPath:)` instead,
    /// which keeps "it failed" distinguishable from "it echoed its input".
    static func run(_ input: String, scriptPath: String, timeout: TimeInterval = 2.0) -> String {
        switch outcome(for: input, scriptPath: scriptPath, timeout: timeout) {
        case .useOutput(let text): return text
        case .keepOriginal: return input
        }
    }

    /// Run the script and report WHAT HAPPENED, not just what text to use.
    ///
    /// Same hardened subprocess as `run` — stdin only, bounded timeout, SIGTERM→SIGKILL
    /// with the `ScriptTimeoutKill` policy — differing only in that the caller gets to
    /// decide what a failure means. Extracted so a plugin step can refuse rather than
    /// silently pass its input through; there is exactly one process-spawning
    /// implementation and both entry points share it.
    static func outcome(
        for input: String, scriptPath: String, timeout: TimeInterval = 2.0
    ) -> ScriptOutcome {
        let path = scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return ScriptOutcome.resolve(
                original: input, stdout: nil, exitCode: nil, timedOut: false, launchFailed: true
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Discard stderr to /dev/null so a script writing lots of stderr can't
        // block on a full, undrained pipe buffer (which would force a timeout).
        process.standardError = FileHandle.nullDevice
        // We TRY to put the script in its own process group (see setpgid below) so
        // a timeout can group-kill any subprocesses it spawned — grandchildren that
        // would otherwise keep the stdout pipe open and the reader blocked. But that
        // placement is BEST-EFFORT (it races the child's exec), so it is not
        // guaranteed; the direct `kill(pid)` on timeout is the guaranteed reaper of
        // the main child. See ScriptTimeoutKill for the exact escalation policy.
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            return ScriptOutcome.resolve(
                original: input, stdout: nil, exitCode: nil, timedOut: false, launchFailed: true
            )
        }
        let pid = process.processIdentifier
        // Try to put the child in its own process group so we can later
        // SIGKILL(-pgid) to reap daemonized grandchildren. This is best-effort: it
        // races the child's exec, and once exec'd it fails with EACCES, leaving the
        // child in OUR group. We don't rely on it succeeding — the timeout path
        // re-reads the child's actual group and only group-kills when the placement
        // demonstrably took (see ScriptTimeoutKill), always reaping the child
        // directly regardless.
        setpgid(pid, pid)

        // Feed stdin on a background queue, then close so the script sees EOF.
        // Off-thread because write(2) blocks once the ~64 KiB pipe buffer fills:
        // a script that isn't draining stdin would otherwise hang the finalize
        // thread before the timeout below is even armed. F_SETNOSIGPIPE makes a
        // write to a dead reader fail with EPIPE (swallowed by `try?`) instead of
        // raising SIGPIPE, whose default disposition would kill the whole app.
        let stdinHandle = stdinPipe.fileHandleForWriting
        _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        let inputData = Data(input.utf8)
        let writeQueue = DispatchQueue(label: "com.openwhisp.app.script-write")
        let writeGroup = DispatchGroup()
        writeQueue.async(group: writeGroup) {
            try? stdinHandle.write(contentsOf: inputData)
            try? stdinHandle.close()
        }

        // Read stdout on a background queue so a chatty script can't deadlock us
        // by filling the pipe buffer while we wait on termination.
        var stdoutData = Data()
        let readQueue = DispatchQueue(label: "com.openwhisp.app.script-read")
        let readGroup = DispatchGroup()
        readQueue.async(group: readGroup) {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Enforce the timeout: wait up to `timeout`, then kill.
        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        let waitQueue = DispatchQueue(label: "com.openwhisp.app.script-wait")
        let waitGroup = DispatchGroup()
        waitQueue.async(group: waitGroup) {
            process.waitUntilExit()
        }
        if waitGroup.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()                       // SIGTERM to the child
            if waitGroup.wait(timeout: .now() + 0.25) == .timedOut {
                // Escalate to SIGKILL. Re-read the child's ACTUAL process group
                // (setpgid above is best-effort) and let the pure policy decide the
                // targets: it group-kills only when the child leads its own group —
                // never our group — and always kills the child directly as the
                // guaranteed reaper.
                for target in ScriptTimeoutKill.targets(
                    pid: pid, resolvedPgid: getpgid(pid), ownPgid: getpgid(0)
                ) {
                    kill(target.killArg, SIGKILL)
                }
            }
        }

        // We must touch `stdoutData` only AFTER the reader block completes (else a
        // data race). On the happy path the child has exited, the write end is
        // closed, and the reader hits EOF on its own — give it a brief grace.
        if readGroup.wait(timeout: .now() + 0.5) == .timedOut {
            // A killed script left a grandchild holding the pipe open, so the
            // reader is still blocked. Force EOF by closing the read end, then wait
            // for the (now-unblocked) reader to finish — this prevents an orphaned
            // reader thread/FD leak and still establishes the happens-before edge
            // we need before reading `stdoutData`.
            try? stdoutPipe.fileHandleForReading.close()
            readGroup.wait()
        }

        // Join the stdin feeder so we don't leak a blocked writer thread. On the
        // happy path the script drained stdin or exited (write got EPIPE). If an
        // orphan of a killed script still holds the read end, close our write end
        // to release the writer — mirroring the stdout handling above — with a
        // bounded second wait rather than risking an indefinite hang.
        if writeGroup.wait(timeout: .now() + 0.5) == .timedOut {
            try? stdinHandle.close()
            _ = writeGroup.wait(timeout: .now() + 0.5)
        }

        let exitCode: Int32? = timedOut ? nil : process.terminationStatus
        let stdout = String(data: stdoutData, encoding: .utf8)
        return ScriptOutcome.resolve(
            original: input,
            stdout: stdout,
            exitCode: exitCode,
            timedOut: timedOut,
            launchFailed: false
        )
    }
}
