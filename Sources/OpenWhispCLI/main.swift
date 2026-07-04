import Foundation
import OpenWhispCore

// The `openwhisp` CLI: an agent-callable front-end to OpenWhisp's Agent Bridge.
//
// Contract: stdout carries ONLY the result (transcript / refined text / JSON) so
// verbs compose in shell pipelines (`openwhisp dictate | pbcopy`); all progress
// and diagnostics go to stderr. Exit codes are uniform across verbs (see below).

// MARK: - Exit codes

enum ExitCode: Int32 {
    case success = 0
    case internalError = 1     // engine/LLM/unexpected failure
    case unreachable = 2       // app not running or bridge disabled
    case consentDenied = 3
    case busy = 4
    case cancelled = 5
    case timeout = 6
    case permission = 7        // mic permission / secure field / audio device
    case usage = 64            // bad arguments
    case versionMismatch = 65  // CLI newer than the app
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data("openwhisp: \(message)\n".utf8))
    exit(code.rawValue)
}

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func emitJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) {
        emit(s)
    } else {
        fail("could not encode result", .internalError)
    }
}

/// Map a bridge/client error to a message + exit code and terminate.
func failClient(_ error: Error) -> Never {
    guard let e = error as? BridgeClient.ClientError else {
        fail("\(error)", .internalError)
    }
    switch e {
    case .unreachable:
        fail("OpenWhisp is not running, or Agent Bridge is disabled in Settings → Agent Bridge", .unreachable)
    case .unsupportedVersion:
        fail("version mismatch — reinstall OpenWhisp so the bundled CLI matches the app", .versionMismatch)
    case .protocolError(let m):
        fail("protocol error: \(m)", .internalError)
    case .domain(let reason, let message, _):
        switch reason {
        case .consentDenied:                          fail(message, .consentDenied)
        case .busy:                                   fail(message, .busy)
        case .cancelled:                              fail(message, .cancelled)
        case .timeout:                                fail(message, .timeout)
        case .secureField, .micPermissionNeeded, .audioUnavailable:
            fail(message, .permission)
        case .unsupportedVersion:                     fail(message, .versionMismatch)
        default:                                      fail(message, .internalError)
        }
    }
}

// MARK: - Argument helpers

struct Args {
    private let raw: [String]
    private let valueFlags: Set<String>
    init(_ raw: [String],
         valueFlags: Set<String> = ["--instruction", "-i", "--prompt", "--timeout", "--language", "--limit"]) {
        self.raw = raw
        self.valueFlags = valueFlags
    }
    func has(_ flag: String) -> Bool { raw.contains(flag) }
    func value(_ flag: String) -> String? {
        guard let i = raw.firstIndex(of: flag), i + 1 < raw.count else { return nil }
        return raw[i + 1]
    }
    /// Positionals, excluding flags and the values that follow value-flags — so
    /// `refine -i "make formal" "the text"` yields ["the text"].
    var positionals: [String] {
        var result: [String] = []
        var skipNext = false
        for arg in raw {
            if skipNext { skipNext = false; continue }
            if valueFlags.contains(arg) { skipNext = true; continue }
            if arg.hasPrefix("-") { continue }
            result.append(arg)
        }
        return result
    }
    var positional: String? { positionals.first }
}

func connectedClient() -> BridgeClient {
    do {
        let client = try BridgeClient()
        try client.handshake(clientName: "openwhisp-cli")
        return client
    } catch { failClient(error) }
}

// MARK: - Verbs

func runStatus(_ args: Args) -> Never {
    let client = connectedClient()
    do {
        let s = try client.call(method: BridgeWire.Method.status.rawValue,
                                params: BridgeWire.NoParams(), resultType: BridgeWire.StatusResult.self)
        if args.has("--json") {
            emitJSON(s)
        } else {
            let llm = s.llmConfigured ? "configured" : "unconfigured"
            let session = s.sessionActive ? "active" : "idle"
            emit("OpenWhisp \(s.appVersion) · engine=\(s.engine) model=\(s.model) llm=\(llm) session=\(session)")
        }
        exit(ExitCode.success.rawValue)
    } catch { failClient(error) }
}

func runHistory(_ args: Args) -> Never {
    let client = connectedClient()
    let limit = args.value("--limit").flatMap(Int.init)
    do {
        let params = BridgeWire.HistoryListParams(limit: limit)
        let result = try client.call(method: BridgeWire.Method.historyList.rawValue,
                                     params: params, resultType: BridgeWire.HistoryListResult.self)
        if args.has("--json") {
            emitJSON(result)
        } else {
            for e in result.entries {
                let app = e.appName ?? e.appBundleID ?? "—"
                let text = e.text.replacingOccurrences(of: "\n", with: " ")
                let clipped = text.count > 120 ? String(text.prefix(120)) + "…" : text
                emit("\(e.date)\t\(app)\t\(clipped)")
            }
        }
        exit(ExitCode.success.rawValue) // exit 0 even when empty
    } catch { failClient(error) }
}

func runDictate(_ args: Args) -> Never {
    // Finish/abort verbs run from a SECOND terminal (or a `&`-backgrounded first
    // one): the `dictate` call blocks until the session ends, so the human's
    // "I'm done" / "never mind" has to come in on its own connection.
    //   openwhisp dictate --stop     finish now, return what was captured (endedBy=stop)
    //   openwhisp dictate --cancel    discard — return NO transcript (Esc equivalent)
    if args.has("--stop") { runDictateStop(args) }
    if args.has("--cancel") { runDictateCancel(args) }

    let client = connectedClient()
    let params = BridgeWire.DictateParams(
        prompt: args.value("--prompt"),
        timeoutSeconds: args.value("--timeout").flatMap(Int.init),
        language: args.value("--language")
    )
    do {
        let result = try client.call(method: BridgeWire.Method.dictate.rawValue,
                                     params: params, resultType: BridgeWire.DictateResult.self)
        if args.has("--json") { emitJSON(result) } else { emit(result.text) } // stdout = transcript only
        exit(ExitCode.success.rawValue)
    } catch { failClient(error) }
}

/// `openwhisp dictate --stop`: finish an in-flight agent dictation and let it
/// return the captured transcript. No-op (stopped:false) if nothing is listening.
func runDictateStop(_ args: Args) -> Never {
    let client = connectedClient()
    do {
        let result = try client.call(method: BridgeWire.Method.dictateStop.rawValue,
                                     params: BridgeWire.NoParams(), resultType: BridgeWire.DictateStopResult.self)
        if args.has("--json") {
            emitJSON(result)
        } else if !result.stopped {
            // Diagnostic to stderr (stdout stays result-only); still exit 0.
            FileHandle.standardError.write(Data("openwhisp: no agent dictation is active\n".utf8))
        }
        exit(ExitCode.success.rawValue)
    } catch { failClient(error) }
}

/// `openwhisp dictate --cancel`: abort an in-flight agent dictation. Per the
/// cancel invariant the blocked `dictate` call returns NO transcript.
func runDictateCancel(_ args: Args) -> Never {
    let client = connectedClient()
    do {
        let result = try client.call(method: BridgeWire.Method.dictateCancel.rawValue,
                                     params: BridgeWire.NoParams(), resultType: BridgeWire.DictateCancelResult.self)
        if args.has("--json") {
            emitJSON(result)
        } else if !result.cancelled {
            FileHandle.standardError.write(Data("openwhisp: no agent dictation is active\n".utf8))
        }
        exit(ExitCode.success.rawValue)
    } catch { failClient(error) }
}

func runRefine(_ args: Args) -> Never {
    guard let instruction = args.value("--instruction") ?? args.value("-i") else {
        fail("refine requires --instruction/-i", .usage)
    }
    // Text from a positional argument, else stdin (for pipelines).
    let text: String
    if let positional = args.positional {
        text = positional
    } else {
        text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    let client = connectedClient()
    do {
        let params = BridgeWire.RefineParams(text: text, instruction: instruction)
        let result = try client.call(method: BridgeWire.Method.refine.rawValue,
                                     params: params, resultType: BridgeWire.RefineResult.self)
        if args.has("--json") { emitJSON(result) } else { emit(result.text) }
        exit(ExitCode.success.rawValue)
    } catch { failClient(error) }
}

func runMCP() -> Never {
    MCPServer().run()
    exit(ExitCode.success.rawValue)
}

/// `openwhisp setup <agent>` — perform the adoption for a known agent (the
/// one-command path). By default it WRITES config (registers the MCP server,
/// appends the CLAUDE.md guidance line); `--print`/`--dry-run` restores the
/// old print-only behavior for agents/setups we can't safely automate.
///
/// Setup output is human-facing, so unlike the other verbs it prints progress to
/// STDOUT (there's no machine-readable result to keep clean); errors still exit
/// non-zero.
func runSetup(_ args: Args) -> Never {
    let agent = args.positional ?? "claude-code"
    let printOnly = args.has("--print") || args.has("--dry-run")
    // Our own absolute binary path, as invoked. Deliberately NOT resolving
    // symlinks: a stable symlink (e.g. /usr/local/bin/openwhisp) should be what
    // gets registered, not the version-specific target behind it. Note
    // Bundle.main.bundleURL is unusable here — for a bare CLI executable it is
    // just the containing directory, so appending Contents/Helpers double-nests.
    let bin = Bundle.main.executableURL?.path ?? (CommandLine.arguments.first ?? "openwhisp")

    switch agent {
    case "claude-code", "claude":
        if printOnly { printClaudeSetup(bin: bin) } else { writeClaudeSetup(bin: bin) }
    case "cursor":
        if printOnly { printCursorSetup(bin: bin) } else { writeCursorSetup(bin: bin) }
    case "hermes":
        // No stable, safe on-disk target to merge into here — print the stanza.
        printHermesSetup(bin: bin)
        if !printOnly { note("hermes has no auto-writer yet — the stanza above is ready to paste.") }
    case "openclaw":
        printOpenClawSetup(bin: bin)
        if !printOnly { note("openclaw has no auto-writer yet — register openwhisp via its MCP config.") }
    case "agents-md", "generic":
        printGenericSetup(bin: bin)
    default:
        fail("unknown agent '\(agent)' — try: claude-code | cursor | hermes | openclaw | agents-md", .usage)
    }
    exit(ExitCode.success.rawValue)
}

// MARK: setup — print (legacy / unsupported-writer agents)

private func printClaudeSetup(bin: String) {
    emit("# 1. Register the MCP server with Claude Code:")
    emit("claude mcp add openwhisp -- \"\(bin)\" mcp")
    emit("")
    emit("# 2. Add this line to ~/.claude/CLAUDE.md so Claude prefers voice over typed questions:")
    emit(AgentSetup.claudeGuidanceLine())
}
private func printCursorSetup(bin: String) {
    emit("// Add to .cursor/mcp.json (note: Cursor times out tool calls ~60s — keep dictate answers short):")
    emit("{ \"mcpServers\": { \"openwhisp\": { \"command\": \"\(bin)\", \"args\": [\"mcp\"] } } }")
}
private func printHermesSetup(bin: String) {
    emit("# Add to ~/.hermes/config.yaml under mcp_servers:")
    emit("mcp_servers:")
    emit("  - name: openwhisp")
    emit("    command: \"\(bin)\"")
    emit("    args: [\"mcp\"]")
}
private func printOpenClawSetup(bin: String) {
    emit("# OpenClaw: register openwhisp as an MCP server via its MCP config, using:")
    emit("#   command: \(bin)   args: [mcp]")
    emit("# (See docs.openclaw.ai for the current MCP registration surface.)")
}
private func printGenericSetup(bin: String) {
    emit("Run the MCP server as: \(bin) mcp")
    emit("Add to your agent's rules file: prefer the openwhisp_dictate tool for asking the user questions by voice.")
}

// MARK: setup — write (the one-command adoption path)

/// A short status line to stdout (setup is interactive/human-facing).
private func step(_ ok: Bool, _ message: String) {
    emit("\(ok ? "✓" : "•") \(message)")
}
private func note(_ message: String) {
    emit("  \(message)")
}

private func writeClaudeSetup(bin: String) {
    // 1. Register the MCP server via the Claude CLI (skip if already present).
    switch registerClaudeMCP(bin: bin) {
    case .added:        step(true, "Registered the openwhisp MCP server with Claude Code.")
    case .alreadyThere: step(true, "openwhisp MCP server already registered with Claude Code.")
    case .cliMissing:
        step(false, "The `claude` CLI isn't on your PATH — register manually:")
        note("claude mcp add openwhisp -- \"\(bin)\" mcp")
    case .failed(let msg):
        step(false, "`claude mcp add` failed: \(msg)")
        note("Run it yourself: claude mcp add openwhisp -- \"\(bin)\" mcp")
    }

    // 2. Append the guidance line to ~/.claude/CLAUDE.md (idempotent).
    let claudeMd = expandTilde("~/.claude/CLAUDE.md")
    let existing = try? String(contentsOfFile: claudeMd, encoding: .utf8)
    if let updated = AgentSetup.claudeMdAppending(to: existing) {
        if writeFileCreatingParents(path: claudeMd, contents: updated) {
            step(true, "Added the voice-first guidance line to ~/.claude/CLAUDE.md.")
        } else {
            step(false, "Couldn't write ~/.claude/CLAUDE.md — add this line yourself:")
            note(AgentSetup.claudeGuidanceLine())
        }
    } else {
        step(true, "~/.claude/CLAUDE.md already has the voice-first guidance line.")
    }

    emit("")
    emit("Done. Start a new Claude Code session (or `claude mcp list`) to pick up openwhisp.")
}

private func writeCursorSetup(bin: String) {
    // Cursor reads a project-local .cursor/mcp.json; write it in the CWD, merging.
    let path = FileManager.default.currentDirectoryPath + "/.cursor/mcp.json"
    let existing = FileManager.default.contents(atPath: path)
    if let data = AgentSetup.cursorMcpJSON(existing: existing, binaryPath: bin) {
        if writeFileCreatingParents(path: path, data: data) {
            step(true, "Wrote openwhisp into ./.cursor/mcp.json (existing servers preserved).")
            note("Cursor times out tool calls ~60s — dictate streams progress to stay alive.")
        } else {
            step(false, "Couldn't write ./.cursor/mcp.json — add it manually:")
            printCursorSetup(bin: bin)
        }
    } else {
        step(true, "./.cursor/mcp.json already has the openwhisp server.")
    }
}

// MARK: setup — I/O helpers

private enum ClaudeRegisterResult {
    case added, alreadyThere, cliMissing
    case failed(String)
}

/// Register the MCP server with Claude Code, idempotently: probe with
/// `claude mcp get openwhisp` and skip the add if it's already there.
private func registerClaudeMCP(bin: String) -> ClaudeRegisterResult {
    guard let claude = resolveExecutable("claude") else { return .cliMissing }
    // Already registered? `claude mcp get openwhisp` exits 0 when it exists.
    if runProcess(claude, ["mcp", "get", "openwhisp"]).status == 0 {
        return .alreadyThere
    }
    let add = runProcess(claude, AgentSetup.claudeMcpAddArguments(binaryPath: bin))
    if add.status == 0 { return .added }
    // Some `claude` versions exit non-zero on a duplicate; treat that as success.
    if add.combinedOutput.lowercased().contains("already exists") { return .alreadyThere }
    let detail = add.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    return .failed(detail.isEmpty ? "exit \(add.status)" : detail)
}

private func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// Write string contents, creating parent directories. Returns success.
private func writeFileCreatingParents(path: String, contents: String) -> Bool {
    writeFileCreatingParents(path: path, data: Data(contents.utf8))
}
private func writeFileCreatingParents(path: String, data: Data) -> Bool {
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return true
    } catch {
        return false
    }
}

/// Locate an executable on PATH (or accept an absolute path as-is). Returns nil
/// if not found — we never shell out through `/bin/sh` to avoid quoting hazards.
private func resolveExecutable(_ name: String) -> String? {
    if name.hasPrefix("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    for dir in path.split(separator: ":") {
        let candidate = String(dir) + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

private struct ProcessResult { var status: Int32; var combinedOutput: String }

/// Run `executable args...`, capturing merged stdout+stderr. No shell involved.
private func runProcess(_ executable: String, _ args: [String]) -> ProcessResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
    } catch {
        return ProcessResult(status: -1, combinedOutput: "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return ProcessResult(status: proc.terminationStatus,
                         combinedOutput: String(data: data, encoding: .utf8) ?? "")
}

func printUsage() {
    let usage = """
    openwhisp — agent-callable front-end to OpenWhisp's Agent Bridge

    USAGE:
      openwhisp status [--json]                         App/engine/model/LLM/session state (liveness probe)
      openwhisp dictate [--prompt T] [--timeout S] [--language C] [--json]
                                                        Ask the user to speak; prints the transcript
      openwhisp dictate --stop                          Finish a running dictation now (from another shell)
      openwhisp dictate --cancel                        Discard a running dictation (returns no transcript)
      openwhisp refine --instruction T [TEXT | stdin] [--json]
                                                        Rewrite text with the on-device AI
      openwhisp history [--limit N] [--json]            Recent dictation history, newest first
      openwhisp mcp                                     Run the MCP stdio server (for agents)
      openwhisp setup <claude-code|cursor|hermes|openclaw|agents-md> [--print]
                                                        Register OpenWhisp with an agent (writes config;
                                                        --print/--dry-run only shows the steps)

    Output is result-only on stdout (composes in pipelines); diagnostics go to stderr.
    Requires OpenWhisp running with Agent Bridge enabled (Settings → Agent Bridge).
    """
    FileHandle.standardError.write(Data((usage + "\n").utf8))
}

// MARK: - Dispatch

let argv = Array(CommandLine.arguments.dropFirst())
guard let verb = argv.first else { printUsage(); exit(ExitCode.usage.rawValue) }
let rest = Args(Array(argv.dropFirst()))

switch verb {
case "status":
    runStatus(rest)
case "dictate":
    runDictate(rest)
case "refine":
    runRefine(rest)
case "history":
    runHistory(rest)
case "mcp":
    runMCP()
case "setup":
    runSetup(rest)
case "-h", "--help", "help":
    printUsage()
    exit(ExitCode.success.rawValue)
default:
    FileHandle.standardError.write(Data("openwhisp: unknown command '\(verb)'\n".utf8))
    printUsage()
    exit(ExitCode.usage.rawValue)
}
