import Foundation

/// App-side output target (MAK-13) that hands the final transcript to a user-chosen
/// **macOS Shortcut** via the `/usr/bin/shortcuts` CLI, so dictation can flow into
/// anything the Shortcuts ecosystem reaches (Things / Reminders / Notion / an HTTP
/// request / AppleScript) without OpenWhisp building each integration. OS-mediated,
/// so no third-party code runs in our process — safe for an app holding
/// Accessibility rights.
///
/// This is the platform glue (`Process`/`Pipe`/timeout) around the pure
/// `ShortcutInvocation` builders, mirroring how `ScriptRunner` wraps the pure
/// `ScriptOutcome` resolver. It lives OUTSIDE `OpenWhispCore` (build.sh's glob picks
/// it up; `Package.swift` does not) because it links `Process`; the tested logic is
/// in `ShortcutInvocation`.
///
/// **Fail-open by contract.** Any failure to run the shortcut — a bad/empty name, a
/// launch error, a non-zero exit, or a timeout — is reported as
/// `.failedFallback(reason:)`, so the `OutputRouter` re-routes the SAME payload to
/// the normal focused-app insert. Dictation is never dropped just because a shortcut
/// was misconfigured or slow.
final class ShortcutOutputTarget: OutputTarget {
    let kind: OutputTargetKind = .shortcut

    /// The shortcut to run, by display name (as shown in Shortcuts.app / listed by
    /// `shortcuts list`).
    private let shortcutName: String
    /// Hard wall-clock budget for the shortcut run before we kill it and fail open.
    /// Shortcuts can legitimately do slow work (network calls), so this is more
    /// generous than the script post-processor's 2s, but still bounded so a hung
    /// shortcut can't stall the finalize path indefinitely.
    private let timeout: TimeInterval
    /// Path to the Shortcuts CLI (injectable for tests / non-standard installs).
    private let executablePath: String
    /// Queue the callback is delivered on (the app expects main).
    private let completionQueue: DispatchQueue

    init(
        shortcutName: String,
        timeout: TimeInterval = 20.0,
        executablePath: String = ShortcutInvocation.executablePath,
        completionQueue: DispatchQueue = .main
    ) {
        self.shortcutName = shortcutName
        self.timeout = timeout
        self.executablePath = executablePath
        self.completionQueue = completionQueue
    }

    func deliver(_ payload: OutputPayload, completion: @escaping (OutputDelivery) -> Void) {
        // Live chunks are incremental mid-session inserts; a shortcut should fire on
        // the FINAL result only. Fail open on live chunks so the router falls back to
        // the normal focused-app insert and the user still sees streaming text.
        guard !payload.isLiveChunk else {
            finish(.failedFallback(reason: "Shortcut skips live chunks"), on: completion)
            return
        }

        // Pure builder decides the argv (and rejects an empty/invalid name).
        guard let arguments = ShortcutInvocation.runArguments(name: shortcutName) else {
            finish(.failedFallback(reason: "No shortcut selected"), on: completion)
            return
        }

        // Run the (blocking, bounded) subprocess off the calling thread so a slow
        // shortcut never blocks the finalize/main thread; report the outcome back on
        // `completionQueue`.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outcome = Self.runShortcut(
                executablePath: executablePath,
                arguments: arguments,
                input: payload.text,
                timeout: timeout
            )
            finish(outcome, on: completion)
        }
    }

    private func finish(_ outcome: OutputDelivery, on completion: @escaping (OutputDelivery) -> Void) {
        completionQueue.async { completion(outcome) }
    }

    // MARK: - Enumeration

    /// Enumerate the user's shortcuts by running `shortcuts list` (one name per
    /// line) and parsing the output with the pure `ShortcutInvocation.parseList`.
    /// Returns `[]` on any failure (launch error / non-zero exit / timeout) — a
    /// picker just shows an empty list rather than surfacing an error.
    static func listShortcuts(
        executablePath: String = ShortcutInvocation.executablePath,
        timeout: TimeInterval = 10.0
    ) -> [String] {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["list"]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        var stdoutData = Data()
        let readGroup = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: readGroup) {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }

        var timedOut = false
        let waitGroup = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: waitGroup) {
            process.waitUntilExit()
        }
        if waitGroup.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()                        // SIGTERM
            if waitGroup.wait(timeout: .now() + 0.25) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = waitGroup.wait(timeout: .now() + 0.25)
            }
        }
        if readGroup.wait(timeout: .now() + 0.5) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            readGroup.wait()
        }

        // On timeout, return before touching `terminationStatus`: reading it while
        // the child could still be running (a SIGTERM-ignoring child, or the brief
        // window before SIGKILL is delivered) raises NSInvalidArgumentException.
        guard !timedOut, process.terminationStatus == 0 else { return [] }
        return ShortcutInvocation.parseList(String(data: stdoutData, encoding: .utf8))
    }

    // MARK: - Subprocess run (fail-open)

    /// Run the shortcut with `input` on stdin, enforcing `timeout`. Returns the
    /// fail-open `OutputDelivery`: `.delivered` only on a clean exit-0 run; every
    /// error path (launch failure, non-zero exit, timeout) → `.failedFallback`.
    ///
    /// Modeled on `ScriptRunner`: stdin is written off-thread (a shortcut that isn't
    /// draining stdin can't block us), stderr is discarded to /dev/null so a chatty
    /// shortcut can't deadlock on a full pipe, and a timeout escalates SIGTERM →
    /// SIGKILL.
    static func runShortcut(
        executablePath: String,
        arguments: [String],
        input: String,
        timeout: TimeInterval
    ) -> OutputDelivery {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .failedFallback(reason: "Shortcuts CLI not found")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        // Discard stdout/stderr: we only care whether the shortcut ran (exit code),
        // and undrained pipes could otherwise block a chatty shortcut on a full
        // buffer and force a spurious timeout.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failedFallback(reason: "Shortcut couldn't launch")
        }

        // Feed the transcript to the shortcut's stdin off-thread, then close so it
        // sees EOF. F_SETNOSIGPIPE turns a write-to-dead-reader into EPIPE (swallowed
        // by try?) instead of a SIGPIPE that would kill the app.
        let stdinHandle = stdinPipe.fileHandleForWriting
        _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        let writeGroup = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: writeGroup) {
            try? stdinHandle.write(contentsOf: Data(input.utf8))
            try? stdinHandle.close()
        }

        var timedOut = false
        let waitGroup = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: waitGroup) {
            process.waitUntilExit()
        }
        if waitGroup.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()                        // SIGTERM
            if waitGroup.wait(timeout: .now() + 0.25) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = waitGroup.wait(timeout: .now() + 0.25)
            }
        }

        // Join the stdin feeder so we don't leak a blocked writer thread.
        if writeGroup.wait(timeout: .now() + 0.5) == .timedOut {
            try? stdinHandle.close()
            _ = writeGroup.wait(timeout: .now() + 0.5)
        }

        if timedOut {
            return .failedFallback(reason: "Shortcut timed out")
        }
        guard process.terminationStatus == 0 else {
            return .failedFallback(reason: "Shortcut exited with code \(process.terminationStatus)")
        }
        return .delivered
    }
}
