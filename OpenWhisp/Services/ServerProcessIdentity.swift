import Foundation

// MARK: - Server process identity

/// Pure, dependency-free decision logic for "do we own this subprocess?" —
/// shared by `WhisperEngine` and `LlamaServerEngine` before they signal a
/// PID reaped from a stale PID file.
///
/// Signalling a bare PID read from disk is a PID-reuse TOCTOU: after a crash +
/// PID reuse the persisted PID can point at an *unrelated* user process (e.g. a
/// user's own Homebrew or manually-built `whisper-server`). Killing that would
/// be a real, user-visible bug. So before we ever `kill()` a reaped PID we
/// resolve its executable path (via libproc) and require BOTH:
///
///   1. the executable basename matches the one we launched, AND
///   2. the executable resolves under a path we own (the app bundle's
///      Resources dir, or a known dev-build dir).
///
/// The path-resolution + `kill()` parts are inherently impure (they touch the
/// live process table), but the *decision* — given a resolved path, an expected
/// basename, and the set of owned prefixes — is pure and is the sharpest part of
/// the bug. It lives here so it is unit-tested once for both engines.
enum ServerProcessIdentity {

    /// Returns true only if `executablePath` names a process we own — i.e. its
    /// basename equals `expectedBasename` AND it resolves under one of
    /// `ownedPrefixes`.
    ///
    /// Conservative by construction: an empty `executablePath` (path could not
    /// be resolved) or an empty `ownedPrefixes` (nothing is owned) both return
    /// false, so a caller that fails to resolve the path never signals an
    /// unknown process.
    ///
    /// - Parameters:
    ///   - executablePath: absolute path of the candidate process's executable,
    ///     as returned by `proc_pidpath`. Empty string ⇒ unresolved ⇒ false.
    ///   - ownedPrefixes: directory paths we consider ours (app-bundle resource
    ///     dir, dev-build dir). A candidate must live under one of these.
    ///   - expectedBasename: the executable name we launched (e.g.
    ///     `"whisper-server"`, `"llama-server"`).
    static func isOwnedServerProcess(
        executablePath: String,
        ownedPrefixes: [String],
        expectedBasename: String
    ) -> Bool {
        guard !executablePath.isEmpty else { return false }
        guard (executablePath as NSString).lastPathComponent == expectedBasename else {
            return false
        }
        for rawPrefix in ownedPrefixes {
            guard !rawPrefix.isEmpty else { continue }
            // Normalise the prefix to a directory boundary so that an owned
            // dir `/foo/bin` does NOT match a sibling `/foo/bin-evil/...`.
            let prefix = rawPrefix.hasSuffix("/") ? rawPrefix : rawPrefix + "/"
            if executablePath.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }
}
