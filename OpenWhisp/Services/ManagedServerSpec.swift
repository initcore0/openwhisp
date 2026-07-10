import Foundation

// MARK: - Managed server spec (pure)

/// The identity of a bundled loopback server that `ManagedServerProcess` manages
/// — the pure, dependency-free naming/verification rules that used to be
/// copy-pasted between `WhisperEngine` and `LlamaServerEngine`.
///
/// This holds only *values and decisions* (basenames, cache-relative file names,
/// the owned-path predicate) so it can be unit-tested with `swift test` without
/// touching `Process`, sockets, or the live process table. The impure glue
/// (spawning, signalling, socket binding) lives in `ManagedServerProcess`, which
/// is app-only.
struct ManagedServerSpec {
    /// Executable basename we launch and are willing to signal, e.g.
    /// `"whisper-server"` / `"llama-server"`.
    let executableBasename: String
    /// Tag used for `[whisper-server]` / `[llama-server]` log-drain lines and
    /// `print` diagnostics.
    let logTag: String
    /// PID file name inside the app's Caches dir, e.g. `"whisper-server.pid"`.
    let pidFileName: String
    /// Engine log file name inside the app's Caches dir, e.g.
    /// `"whisper-engine.log"`.
    let logFileName: String

    /// The app's Caches directory for OpenWhisp. Both the PID file and the log
    /// file live here.
    static func cachesDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.openwhisp.app")
    }

    var pidFileURL: URL { Self.cachesDirectory().appendingPathComponent(pidFileName) }
    var logFileURL: URL { Self.cachesDirectory().appendingPathComponent(logFileName) }
}

// MARK: - Stale-PID reaping decision (pure)

/// The pure decision half of `stopStaleServerIfNeeded`: given the raw contents of
/// a PID file, decide what PID (if any) is a *candidate* for reaping. The impure
/// half — probing liveness (`kill(pid, 0)`), resolving the executable path, and
/// actually signalling — stays in `ManagedServerProcess`, but the parsing and the
/// "is this even a plausible PID" gate are pure and unit-tested here.
enum StalePIDReaper {

    /// Parses the trimmed contents of a PID file into a signal-eligible PID.
    ///
    /// Returns nil (⇒ nothing to reap, and the caller deletes the stale file)
    /// when the file is absent/empty, non-numeric, or names a non-positive PID.
    /// A positive PID is only a *candidate*: the caller must still verify it is
    /// alive AND owned (via `ServerProcessIdentity`) before signalling — this
    /// function deliberately does not touch the live process table.
    static func candidatePID(fromFileContents raw: String?) -> Int32? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed), pid > 0 else { return nil }
        return pid
    }
}
