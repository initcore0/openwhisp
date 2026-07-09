import Foundation

/// Pure builders for driving the macOS **Shortcuts** CLI (`/usr/bin/shortcuts`) as
/// an output target (MAK-13). Given a shortcut NAME, produce the exact argv to run
/// it with the transcript on stdin; and parse `shortcuts list` output into names.
///
/// This is the testable heart of the Shortcut sink: the surprising parts — how the
/// transcript is fed to the shortcut, how a name with spaces/quotes is handled, and
/// which lines of `shortcuts list` are real shortcut names — are pinned here as
/// pure Foundation logic. The actual `Process` spawn + timeout is platform glue in
/// `ShortcutOutputTarget` (app side, build.sh only), mirroring how `ScriptRunner`
/// wraps the pure `ScriptOutcome` resolver.
///
/// ## Why `--input-path -`
/// `shortcuts run --help` documents:
///
///     shortcuts run <shortcut-name-or-identifier> [--input-path <input-path>] …
///       -i, --input-path <input-path>   The input to provide to the shortcut.
///
/// `--input-path` takes a *file* path; the conventional `-` means "read stdin"
/// (the same dash convention `cat`, `tar`, etc. use). So we invoke
/// `shortcuts run <name> --input-path -` and write the transcript to the process's
/// stdin — no temp file, no shell quoting. Because argv is passed to `Process` as a
/// literal array (never through a shell), a shortcut name with spaces or quotes is
/// a single argument as-is; there is no interpolation to escape.
enum ShortcutInvocation {

    // MARK: - Name validation

    /// A shortcut name is usable iff it is non-empty after trimming surrounding
    /// whitespace/newlines. (Interior spaces are fine — many shortcuts are named
    /// "Add to Things".) Returns the trimmed name on success so callers use the
    /// canonical form, or `nil` when the name is empty/whitespace-only.
    ///
    /// A newline *inside* a name is also rejected: `shortcuts` identifies a shortcut
    /// by a single line, and an embedded newline could never match a real shortcut
    /// (and would be a sign of malformed input), so we treat it as invalid rather
    /// than silently passing a broken argument to the CLI.
    static func normalizedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Reject any interior line break. Check on Unicode scalars via the
        // `.newlines` set: in Swift `"\r\n"` is a SINGLE Character that equals
        // neither `"\n"` nor `"\r"`, so a Character-level scan would miss CRLF; the
        // scalar view catches every line terminator (LF, CR, CRLF, U+2028, …).
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    // MARK: - `shortcuts run` argv

    /// The argv (arguments AFTER the executable) to run `shortcut` named `name` with
    /// the transcript fed on **stdin** — `["run", <name>, "--input-path", "-"]`.
    ///
    /// Returns `nil` for an empty/invalid name so the caller fails open instead of
    /// invoking `shortcuts run ""` (which would error). The name is passed verbatim
    /// (trimmed) as one array element: `Process` receives argv as a real array, so
    /// spaces/quotes need no escaping — they are part of the single argument.
    ///
    /// - Parameter name: the user-chosen shortcut's name.
    static func runArguments(name: String) -> [String]? {
        guard let clean = normalizedName(name) else { return nil }
        return ["run", clean, "--input-path", "-"]
    }

    /// The full argv INCLUDING the executable path, e.g.
    /// `["/usr/bin/shortcuts", "run", "My Shortcut", "--input-path", "-"]`.
    /// Convenience for logging / a launcher that wants the complete command; the
    /// app-side runner uses `executablePath` for `Process.executableURL` and
    /// `runArguments` for `Process.arguments`.
    static func runCommand(name: String, executablePath: String = executablePath) -> [String]? {
        guard let args = runArguments(name: name) else { return nil }
        return [executablePath] + args
    }

    /// Canonical path to the Shortcuts CLI on macOS.
    static let executablePath = "/usr/bin/shortcuts"

    // MARK: - `shortcuts list` parsing

    /// Parse the stdout of `shortcuts list` (one shortcut name per line) into a
    /// clean `[String]` of names, suitable for a per-app picker.
    ///
    /// Rules, all exercised by the tests:
    /// - split on newlines (handles `\n`, `\r\n`, and a trailing newline),
    /// - trim surrounding whitespace on each line,
    /// - drop blank / whitespace-only lines,
    /// - preserve the CLI's ordering and DO NOT deduplicate (two shortcuts can
    ///   legitimately share a display name; the caller can disambiguate).
    ///
    /// `nil` (the process produced no output) is treated the same as empty → `[]`.
    ///
    /// Splitting is done with `.newlines` (a `CharacterSet`) rather than
    /// `split(separator: "\n")`: in Swift `"\r\n"` is a SINGLE extended grapheme
    /// cluster, so splitting on the `Character` `"\n"` would leave a CRLF line
    /// glued together. `components(separatedBy: .newlines)` splits on every Unicode
    /// line terminator (LF, CRLF, CR, U+2028, …) correctly.
    static func parseList(_ output: String?) -> [String] {
        guard let output else { return [] }
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
