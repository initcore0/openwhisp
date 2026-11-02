import Foundation
import OpenWhispCore

/// Self-derives workspace context (cwd + git branch) for the `openwhisp mcp`
/// stdio server, so the MCP dictate path gets agent-context vocabulary (MAK-75)
/// with ZERO client changes: the server runs as a stdio child in the MCP client's
/// working directory, so `FileManager.currentDirectoryPath` IS the project the
/// agent is working in, and `git` in that dir yields the checked-out branch.
///
/// An explicit `context` in the tool call always wins over — and is merged with —
/// the self-derived values, and the whole thing is gated by an env opt-out so a
/// user who doesn't want their cwd/branch primed can turn it off entirely.
///
/// The derived context is data ABOUT the client's own workspace, used locally to
/// prime recognition + (for a local LLM) cleanup. It never leaves the machine and
/// is never persisted.
public enum WorkspaceContext {

    /// Set this env var to `0`/`false`/`off`/`no` in the MCP client's environment
    /// to disable server-side cwd + git-branch derivation. An explicit `context`
    /// argument in the tool call is still honored (the user opted in per call);
    /// only the automatic self-derivation is suppressed. Modeled on the existing
    /// `OPENWHISP_MCP_PROGRESS_INTERVAL` env convention.
    public static let optOutEnvVar = "OPENWHISP_MCP_WORKSPACE_CONTEXT"

    /// Whether server-side self-derivation is enabled, per the env opt-out. Default
    /// on (absent/empty → enabled).
    public static func selfDerivationEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[optOutEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return true }
        switch raw {
        case "0", "false", "off", "no": return false
        default: return true
        }
    }

    /// Resolve the `DictateContext` to send with an MCP dictate call, merging an
    /// explicit client-supplied `explicit` (highest priority) with self-derived
    /// cwd/branch (when enabled). Returns nil when there's nothing to send (no
    /// explicit context and self-derivation off/empty) so the wire field stays
    /// absent — old-server-compatible.
    ///
    /// Pure w.r.t. its injected inputs (`environment`, `currentDirectory`,
    /// `gitBranchProvider`) so `swift test` covers the merge without touching the
    /// real cwd or spawning git.
    public static func resolved(
        explicit: BridgeWire.DictateContext?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: @autoclosure () -> String? = FileManager.default.currentDirectoryPath,
        gitBranchProvider: (String) -> String? = { WorkspaceContext.gitBranch(inDirectory: $0) }
    ) -> BridgeWire.DictateContext? {
        var cwd = explicit?.cwd
        var branch = explicit?.gitBranch
        let terms = explicit?.terms

        if selfDerivationEnabled(environment: environment) {
            let dir = currentDirectory()
            // Only self-derive a value the client didn't already give us.
            if (cwd?.isEmpty ?? true), let dir, !dir.isEmpty { cwd = dir }
            if (branch?.isEmpty ?? true), let dir, !dir.isEmpty,
               let b = gitBranchProvider(dir), !b.isEmpty {
                branch = b
            }
        }

        let resolved = BridgeWire.DictateContext(cwd: cwd, gitBranch: branch, terms: terms)
        return resolved.isEmpty ? nil : resolved
    }

    /// How long `git rev-parse` may take before the branch is skipped. The MCP
    /// dictate path resolves context BEFORE its keep-alive progress starts, so a
    /// git that stalls (cwd on a hung network/FUSE mount, a slow wrapper) must not
    /// eat the agent's ~60s tool-call budget.
    public static let gitTimeoutSeconds: TimeInterval = 2

    /// Best-effort current git branch for `directory` via `git rev-parse
    /// --abbrev-ref HEAD`. Returns nil on any failure (not a repo, git missing,
    /// detached HEAD → "HEAD", or git not finishing within `timeout`). Never
    /// throws; a missing branch just means no branch-derived bias terms.
    public static func gitBranch(
        inDirectory directory: String, timeout: TimeInterval = gitTimeoutSeconds
    ) -> String? {
        guard let out = runCapturingStdout(
            executable: "/usr/bin/env",
            arguments: ["git", "-C", directory, "rev-parse", "--abbrev-ref", "HEAD"],
            timeout: timeout
        ) else { return nil }
        let branch = String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A detached HEAD reports the literal "HEAD" — no branch name to bias with.
        guard !branch.isEmpty, branch != "HEAD" else { return nil }
        return branch
    }

    /// Run a short-lived command and return its stdout, or nil when it can't
    /// start, exits non-zero, or doesn't finish within `timeout` (it is then
    /// terminated and NOT waited on further).
    static func runCapturingStdout(executable: String, arguments: [String], timeout: TimeInterval) -> Data? {
        // `Process` doesn't exist on iOS — and neither does the MCP stdio server
        // this derivation serves. BridgeKit ships to the iOS companion as a
        // library (CLAUDE.md contract), so the subprocess path is macOS-only;
        // iOS callers just get "no branch".
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        // The process has exited, so its end of the pipe is closed and this read
        // can't block (the output is a single short line, well under the pipe
        // buffer, so waiting for exit before reading can't deadlock either).
        return pipe.fileHandleForReading.readDataToEndOfFile()
        #else
        return nil
        #endif
    }
}
