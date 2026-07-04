import Foundation
import OpenWhispCore

/// The `openwhisp mcp` stdio server: an MCP (Model Context Protocol) adapter that
/// exposes OpenWhisp's Agent Bridge tools to MCP-aware agents (Claude Code,
/// Cursor, Hermes, OpenClaw). It speaks newline-delimited JSON-RPC 2.0 on
/// stdin/stdout (MCP's stdio transport) and forwards each `tools/call` to the
/// app's control-plane socket via `BridgeClient`.
///
/// Hand-rolled rather than pulling the official Swift MCP SDK: the MCP stdio
/// surface we need (initialize / tools/list / tools/call) is small and identical
/// in shape to the JSON-RPC we already implement, and this keeps the CLI
/// dependency-free and end-to-end testable. (The SDK remains an option if a
/// richer MCP feature set is wanted later.)
///
/// ALL diagnostics go to stderr; stdout carries only protocol frames.
final class MCPServer {

    private let mcpProtocolVersionFallback = "2025-06-18"
    /// The MCP client's name, captured at `initialize` and forwarded to the bridge
    /// handshake so consent records show the real agent (e.g. "claude-code").
    private var clientName = "mcp-client"

    func run() {
        logStderr("openwhisp mcp: ready (stdio)")
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            handle(line)
        }
        logStderr("openwhisp mcp: stdin closed, exiting")
    }

    // MARK: - Dispatch

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Unparseable frame — MCP clients shouldn't send these; ignore.
            logStderr("mcp: dropping unparseable frame")
            return
        }
        let id = obj["id"] // may be Int, String, or absent (notification)
        guard let method = obj["method"] as? String else { return }
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String, !name.isEmpty {
                clientName = name
            }
            let requested = params["protocolVersion"] as? String ?? mcpProtocolVersionFallback
            respond(id: id, result: [
                "protocolVersion": requested,
                "serverInfo": ["name": "openwhisp", "version": BridgeClient.version],
                "capabilities": ["tools": [:] as [String: Any]],
                "instructions": Self.serverInstructions,
            ])
        case "notifications/initialized", "initialized":
            break // no response to a notification
        case "ping":
            respond(id: id, result: [:])
        case "tools/list":
            respond(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = callTool(name: name, arguments: arguments)
            respond(id: id, result: result)
        default:
            if id != nil {
                respondError(id: id, code: -32601, message: "method not found: \(method)")
            }
        }
    }

    // MARK: - Tool execution (forward to the bridge)

    private func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            let client = try BridgeClient()
            try client.handshake(clientName: clientName)
            switch name {
            case "openwhisp_dictate":
                let params = BridgeWire.DictateParams(
                    prompt: arguments["prompt"] as? String,
                    timeoutSeconds: arguments["timeoutSeconds"] as? Int,
                    language: arguments["language"] as? String
                )
                let r = try client.call(method: BridgeWire.Method.dictate.rawValue,
                                        params: params, resultType: BridgeWire.DictateResult.self)
                return textContent(r.text.isEmpty ? "(the user said nothing)" : r.text)

            case "openwhisp_refine":
                guard let text = arguments["text"] as? String,
                      let instruction = arguments["instruction"] as? String else {
                    return errorContent("refine requires 'text' and 'instruction'")
                }
                let r = try client.call(method: BridgeWire.Method.refine.rawValue,
                                        params: BridgeWire.RefineParams(text: text, instruction: instruction),
                                        resultType: BridgeWire.RefineResult.self)
                return textContent(r.text)

            case "openwhisp_history":
                let r = try client.call(method: BridgeWire.Method.historyList.rawValue,
                                        params: BridgeWire.HistoryListParams(limit: arguments["limit"] as? Int),
                                        resultType: BridgeWire.HistoryListResult.self)
                let lines = r.entries.map { "\($0.date)\t\($0.appName ?? $0.appBundleID ?? "—")\t\($0.text)" }
                return textContent(lines.isEmpty ? "(no dictation history)" : lines.joined(separator: "\n"))

            default:
                return errorContent("unknown tool: \(name)")
            }
        } catch let e as BridgeClient.ClientError {
            return errorContent(Self.clientErrorMessage(e))
        } catch {
            return errorContent("\(error)")
        }
    }

    // MARK: - MCP result helpers

    private func textContent(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": false]
    }
    private func errorContent(_ text: String) -> [String: Any] {
        // MCP execution errors are returned as a normal result with isError:true so
        // the model can read the message and adapt.
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    // MARK: - JSON-RPC I/O

    private func respond(id: Any?, result: [String: Any]) {
        var obj: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { obj["id"] = id }
        write(obj)
    }
    private func respondError(id: Any?, code: Int, message: String) {
        var obj: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { obj["id"] = id }
        write(obj)
    }
    private func write(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data) // unbuffered — the client sees it immediately
    }

    // MARK: - Static content

    static func clientErrorMessage(_ e: BridgeClient.ClientError) -> String {
        switch e {
        case .unreachable:
            return "OpenWhisp isn't running, or its Agent Bridge is off. Ask the user to launch OpenWhisp and enable Settings → Agent Bridge."
        case .unsupportedVersion:
            return "OpenWhisp is out of date for this adapter — the user should reinstall it."
        case .domain(_, let message, let originalText):
            if let originalText, !originalText.isEmpty {
                return "\(message) (unrefined text preserved: \(originalText))"
            }
            return message
        case .protocolError(let m):
            return "bridge protocol error: \(m)"
        }
    }

    static let serverInstructions = """
    OpenWhisp exposes on-device voice tools. Use openwhisp_dictate to ask the user \
    a question by voice instead of ending your turn with a plain-text question; \
    use openwhisp_refine to rewrite text with the user's local AI; use \
    openwhisp_history to recall what the user recently dictated. Everything runs on \
    the user's Mac — no audio or text leaves the device (unless the user has \
    explicitly enabled a cloud AI provider).
    """

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "openwhisp_dictate",
            "description": """
            Call this whenever you need to ask the user a question, get a decision, or collect \
            free-form input mid-task — instead of ending your turn with a plain-text question. It \
            shows your prompt on the user's screen and opens their OpenWhisp voice overlay; the user \
            speaks and their answer returns as transcribed text. Runs entirely on the user's Mac. Do \
            NOT use for text you already have — use openwhisp_refine for that.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "The question to show the user."],
                    "timeoutSeconds": ["type": "integer", "description": "Max seconds to wait (default 60, max 300)."],
                    "language": ["type": "string", "description": "Optional BCP-47 language hint."],
                ],
            ],
        ],
        [
            "name": "openwhisp_refine",
            "description": """
            Call this when you have text that should be rewritten per a natural-language instruction \
            using the user's own on-device LLM — cleaning up a transcript, changing tone ("make it \
            formal"), tightening wording, or applying the user's style. Same model and prompt chain as \
            the user's OpenWhisp refine hotkey.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The text to rewrite."],
                    "instruction": ["type": "string", "description": "How to rewrite it."],
                ],
                "required": ["text", "instruction"],
            ],
        ],
        [
            "name": "openwhisp_history",
            "description": """
            Call this when the user refers to something they recently dictated ("what I just said", "my \
            last dictation", "that note I dictated in Slack"). Returns recent OpenWhisp dictation \
            history, newest first, each with text, timestamp, and the app it was dictated into.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Max entries (default 20, max 200)."],
                ],
            ],
        ],
    ]
}

func logStderr(_ message: String) {
    FileHandle.standardError.write(Data(("openwhisp mcp: " + message + "\n").utf8))
}
