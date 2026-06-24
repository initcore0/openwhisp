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
    static func run(_ input: String, scriptPath: String, timeout: TimeInterval = 2.0) -> String {
        let path = scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return ScriptOutcome.resolvedText(
                original: input, stdout: nil, exitCode: nil, timedOut: false, launchFailed: true
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()   // swallow stderr; never block on it

        do {
            try process.run()
        } catch {
            return ScriptOutcome.resolvedText(
                original: input, stdout: nil, exitCode: nil, timedOut: false, launchFailed: true
            )
        }

        // Feed stdin then close so the script sees EOF. Guard the write — a script
        // that exits without reading would otherwise raise SIGPIPE.
        let handle = stdinPipe.fileHandleForWriting
        let inputData = Data(input.utf8)
        try? handle.write(contentsOf: inputData)
        try? handle.close()

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
            process.terminate()                       // SIGTERM
            if waitGroup.wait(timeout: .now() + 0.25) == .timedOut {
                kill(process.processIdentifier, SIGKILL)  // hard stop if it ignores SIGTERM
            }
        }
        _ = readGroup.wait(timeout: .now() + 0.5)

        let exitCode: Int32? = timedOut ? nil : process.terminationStatus
        let stdout = String(data: stdoutData, encoding: .utf8)
        return ScriptOutcome.resolvedText(
            original: input,
            stdout: stdout,
            exitCode: exitCode,
            timedOut: timedOut,
            launchFailed: false
        )
    }
}
