import Foundation

/// Pure decision logic for the opt-in user **script** post-processor: given the
/// raw result of running the user's script over the transcript, decide what text
/// to actually use. **Fail-open by contract** — on any failure (timeout, non-zero
/// exit, spawn error, or empty/whitespace output) the original transcript is kept,
/// so a broken script can never drop or mangle the user's dictation.
///
/// The actual process spawning + timeout is platform glue (ScriptRunner, app
/// side); this resolver is pure Foundation and unit-tested. That keeps the
/// surprising part — exactly when we discard the script output — honest and pinned.
enum ScriptOutcome: Equatable {
    /// Use the script's stdout.
    case useOutput(String)
    /// Keep the original transcript, with a reason for the status line.
    case keepOriginal(reason: String)

    /// - Parameters:
    ///   - original: the transcript fed to the script.
    ///   - stdout: the script's captured stdout (nil if it never produced any).
    ///   - exitCode: process exit status (nil if it never launched / was killed).
    ///   - timedOut: true if we killed it for exceeding the time budget.
    ///   - launchFailed: true if the process couldn't be started at all.
    static func resolve(
        original: String,
        stdout: String?,
        exitCode: Int32?,
        timedOut: Bool,
        launchFailed: Bool
    ) -> ScriptOutcome {
        if launchFailed {
            return .keepOriginal(reason: "Script couldn't run")
        }
        if timedOut {
            return .keepOriginal(reason: "Script timed out")
        }
        guard let exitCode else {
            return .keepOriginal(reason: "Script didn't finish")
        }
        guard exitCode == 0 else {
            return .keepOriginal(reason: "Script exited with code \(exitCode)")
        }
        // Trim only a single trailing newline (the conventional "echo" newline);
        // preserve any other intentional whitespace the script emitted.
        let out = Self.stripOneTrailingNewline(stdout ?? "")
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .keepOriginal(reason: "Script returned empty output")
        }
        return .useOutput(out)
    }

    /// Resolve to the text to actually use (collapses both cases to a string).
    static func resolvedText(
        original: String,
        stdout: String?,
        exitCode: Int32?,
        timedOut: Bool,
        launchFailed: Bool
    ) -> String {
        switch resolve(original: original, stdout: stdout, exitCode: exitCode,
                       timedOut: timedOut, launchFailed: launchFailed) {
        case .useOutput(let text): return text
        case .keepOriginal: return original
        }
    }

    private static func stripOneTrailingNewline(_ s: String) -> String {
        // Note: in Swift, "\r\n" is a SINGLE extended grapheme cluster (one
        // Character), so `dropLast(1)` removes the whole CRLF — using dropLast(2)
        // here would also eat the preceding character. A lone "\n" is likewise one
        // Character. So a single dropLast handles both line endings correctly.
        guard let last = s.last, last == "\n" || last == "\r\n" else { return s }
        return String(s.dropLast())
    }
}

/// Validation for a user-supplied script path, kept pure/testable.
enum ScriptPathValidator {
    enum Result: Equatable {
        case ok
        case empty
        case notFound
        case notExecutable
    }

    /// `fileExists` / `isExecutable` are injected so this is unit-testable without
    /// touching the real filesystem; the app passes FileManager-backed closures.
    static func validate(
        _ path: String,
        fileExists: (String) -> Bool,
        isExecutable: (String) -> Bool
    ) -> Result {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard fileExists(trimmed) else { return .notFound }
        guard isExecutable(trimmed) else { return .notExecutable }
        return .ok
    }
}
