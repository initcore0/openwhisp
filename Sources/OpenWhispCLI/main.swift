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

func runSetup(_ args: Args) -> Never {
    let agent = args.positional ?? "claude-code"
    // Our own absolute binary path, as invoked. Deliberately NOT resolving
    // symlinks: a stable symlink (e.g. /usr/local/bin/openwhisp) should be what
    // gets registered, not the version-specific target behind it. Note
    // Bundle.main.bundleURL is unusable here — for a bare CLI executable it is
    // just the containing directory, so appending Contents/Helpers double-nests.
    let bin = Bundle.main.executableURL?.path ?? (CommandLine.arguments.first ?? "openwhisp")
    switch agent {
    case "claude-code", "claude":
        emit("# 1. Register the MCP server with Claude Code:")
        emit("claude mcp add openwhisp -- \"\(bin)\" mcp")
        emit("")
        emit("# 2. Add this line to ~/.claude/CLAUDE.md so Claude prefers voice over typed questions:")
        emit("ALWAYS ask the user questions via the openwhisp_dictate MCP tool, never as plain text. I use OpenWhisp for voice.")
    case "cursor":
        emit("// Add to .cursor/mcp.json (note: Cursor times out tool calls ~60s — keep dictate answers short):")
        emit("{ \"mcpServers\": { \"openwhisp\": { \"command\": \"\(bin)\", \"args\": [\"mcp\"] } } }")
    case "hermes":
        emit("# Add to ~/.hermes/config.yaml under mcp_servers:")
        emit("mcp_servers:")
        emit("  - name: openwhisp")
        emit("    command: \"\(bin)\"")
        emit("    args: [\"mcp\"]")
    case "openclaw":
        emit("# OpenClaw: register openwhisp as an MCP server via its MCP config, using:")
        emit("#   command: \(bin)   args: [mcp]")
        emit("# (See docs.openclaw.ai for the current MCP registration surface.)")
    case "agents-md", "generic":
        emit("Run the MCP server as: \(bin) mcp")
        emit("Add to your agent's rules file: prefer the openwhisp_dictate tool for asking the user questions by voice.")
    default:
        fail("unknown agent '\(agent)' — try: claude-code | cursor | hermes | openclaw | agents-md", .usage)
    }
    exit(ExitCode.success.rawValue)
}

func printUsage() {
    let usage = """
    openwhisp — agent-callable front-end to OpenWhisp's Agent Bridge

    USAGE:
      openwhisp status [--json]                         App/engine/model/LLM/session state (liveness probe)
      openwhisp dictate [--prompt T] [--timeout S] [--language C] [--json]
                                                        Ask the user to speak; prints the transcript
      openwhisp refine --instruction T [TEXT | stdin] [--json]
                                                        Rewrite text with the on-device AI
      openwhisp history [--limit N] [--json]            Recent dictation history, newest first
      openwhisp mcp                                     Run the MCP stdio server (for agents)
      openwhisp setup <claude-code|cursor|hermes|openclaw|agents-md>
                                                        Print registration steps for an agent

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
