import Foundation
import OpenWhispCore

/// The `openwhisp mcp` stdio server: an MCP (Model Context Protocol) adapter that
/// exposes OpenWhisp's Agent Bridge tools to MCP-aware agents (Claude Code,
/// Cursor, Hermes, OpenClaw). It speaks newline-delimited JSON-RPC 2.0 on
/// stdin/stdout (MCP's stdio transport) and forwards each `tools/call` to the
/// app's control-plane socket via a persistent ``PersistentBridge``.
///
/// Hand-rolled rather than pulling the official Swift MCP SDK: the MCP stdio
/// surface we need (initialize / tools/list / tools/call) is small. The JSON-RPC
/// framing reuses the tested ``BridgeWire`` envelopes (`RPCID`, `ErrorObject`)
/// plus a minimal ``MCPWire.JSONValue`` for MCP's heterogeneous `params` /
/// `content` slots (see MCPWire.swift). (The SDK remains an option if a richer
/// MCP feature set is wanted later.)
///
/// ALL diagnostics go to stderr; stdout carries only protocol frames.
public final class MCPServer {

    private let mcpProtocolVersionFallback = "2025-06-18"
    /// The MCP client's name, captured at `initialize` and forwarded to the bridge
    /// handshake so consent records show the real agent (e.g. "claude-code").
    /// Written on the stdin thread, read on the worker and cancel threads.
    private var clientName: String {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _clientName }
        set { stateLock.lock(); defer { stateLock.unlock() }; _clientName = newValue }
    }
    private var _clientName = "mcp-client"
    private let stateLock = NSLock()

    /// One cached bridge connection for this adapter process, built lazily on the
    /// first `tools/call` (after `initialize` has set ``clientName``). Reconnects
    /// transparently across an app restart. Nil until the first tool call, and
    /// injectable for tests.
    private var bridge: PersistentBridge?
    private let bridgeFactory: (String) -> PersistentBridge

    /// Serializes every stdout frame. `dictate` streams `notifications/progress`
    /// from a background timer thread while the main loop may also write, so all
    /// writes go through this lock to avoid interleaved JSON on the wire.
    private let writeLock = NSLock()

    /// How often to emit a keep-alive progress notification during a blocking
    /// `dictate`. Kept comfortably under Cursor's ~60s tool-call timeout.
    /// Overridable via `OPENWHISP_MCP_PROGRESS_INTERVAL` (seconds) for tuning/tests;
    /// clamped to a sane floor so it can't be set to a busy-loop.
    private let progressIntervalSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["OPENWHISP_MCP_PROGRESS_INTERVAL"],
           let v = Double(raw), v >= 0.1 {
            return v
        }
        return 10
    }()

    /// Tool calls run here, one at a time, so the stdin loop stays free to read
    /// `notifications/cancelled` (and answer `ping`) while a dictate blocks.
    /// Serial, which also keeps the single cached ``bridge`` single-threaded.
    private let workQueue = DispatchQueue(label: "com.openwhisp.mcp.tools")
    /// Runs `dictate.cancel` (and its retries) off the stdin thread.
    private let cancelQueue = DispatchQueue(label: "com.openwhisp.mcp.cancel")
    let requests = MCPRequestTracker()

    /// Stops an in-flight agent dictation over a SEPARATE short-lived bridge
    /// connection (the cached one is blocked waiting on the dictate). Returns
    /// whether a session was actually cancelled.
    public typealias DictationCanceller = (_ clientName: String) throws -> Bool
    private let cancelDictation: DictationCanceller
    /// How long to wait between `dictate.cancel` attempts while the cancelled
    /// dictate is still in flight (e.g. still in the consent prompt, where there
    /// is no session to cancel yet).
    private let cancelRetryInterval: TimeInterval
    private let output: (Data) -> Void

    /// - Parameters:
    ///   - bridgeFactory: builds the per-process bridge once `clientName` is
    ///     known. Defaults to a real ``PersistentBridge``; tests inject a fake.
    ///   - cancelDictation: issues `dictate.cancel`; tests inject a fake.
    ///   - output: where protocol frames go (stdout by default).
    public init(
        bridgeFactory: @escaping (String) -> PersistentBridge = { PersistentBridge(clientName: $0) },
        cancelDictation: @escaping DictationCanceller = MCPServer.cancelDictationOverBridge,
        cancelRetryInterval: TimeInterval = 1.0,
        output: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) }
    ) {
        self.bridgeFactory = bridgeFactory
        self.cancelDictation = cancelDictation
        self.cancelRetryInterval = cancelRetryInterval
        self.output = output
    }

    public func run() {
        logStderr("openwhisp mcp: ready (stdio)")
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            handle(line)
        }
        logStderr("openwhisp mcp: stdin closed, exiting")
        stdinClosed()
    }

    /// The client is gone: treat everything in flight as cancelled (so a running
    /// dictate doesn't keep the mic open until its timeout), then let the worker
    /// drain before the process exits.
    func stdinClosed() {
        if requests.cancelAll(), let id = requests.runningDictation() {
            cancelQueue.async { self.cancelRunningDictation(id) }
        }
        waitForIdle()
    }

    /// Block until every queued tool call has finished (tests + shutdown).
    func waitForIdle() {
        workQueue.sync {}
        cancelQueue.sync {}
    }

    /// The default ``DictationCanceller``: connect, handshake as `clientName`,
    /// call `dictate.cancel`. Unguarded on the app side, and it only ever ends an
    /// AGENT session — never the user's own dictation.
    public static func cancelDictationOverBridge(clientName: String) throws -> Bool {
        let client = try BridgeClient()
        try client.handshake(clientName: clientName)
        let r = try client.call(method: BridgeWire.Method.dictateCancel.rawValue,
                                params: BridgeWire.NoParams(),
                                resultType: BridgeWire.DictateCancelResult.self)
        return r.cancelled
    }

    // MARK: - Dispatch

    /// Decode one stdio line into a typed ``MCPWire.IncomingMessage`` and route it.
    /// Kept separate from `run()` so it's unit-testable without stdio.
    func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(MCPWire.IncomingMessage.self, from: data) else {
            // Unparseable frame — MCP clients shouldn't send these; ignore.
            logStderr("mcp: dropping unparseable frame")
            return
        }
        dispatch(message)
    }

    /// Route a decoded message. Writes the response frame (if any) via `write`.
    /// A notification (`id == nil`) never produces a response. Never blocks on
    /// the bridge: `tools/call` is queued onto ``workQueue``.
    func dispatch(_ message: MCPWire.IncomingMessage) {
        // `initialize` carries a side effect (capture the client name for the
        // bridge handshake) — apply it before building the reply.
        if message.method == "initialize",
           let name = message.params?["clientInfo"]?["name"]?.stringValue, !name.isEmpty {
            clientName = name
        }

        // `tools/call` is the only method with side effects (it forwards to the
        // bridge and may stream progress), so it's handled here; everything else
        // is a pure request→reply resolved by `controlResponse`.
        if message.method == "tools/call" {
            let name = message.params?["name"]?.stringValue ?? ""
            let arguments = message.params?["arguments"] ?? .object([:])
            // MCP progress: the client MAY pass params._meta.progressToken; if so,
            // we stream notifications/progress against it while the call runs.
            let progressToken = message.params?["_meta"]?["progressToken"]
            let id = message.id
            requests.enqueue(id, isDictate: name == "openwhisp_dictate")
            workQueue.async {
                // Cancelled while still queued: never run it, never answer it.
                guard self.requests.start(id) else { self.requests.finish(id); return }
                let result = self.callTool(name: name, arguments: arguments, progressToken: progressToken)
                // A cancelled request gets no response (MCP cancellation contract).
                if self.requests.finish(id) { self.respond(id: id, result: result.asJSON) }
            }
            return
        }

        // The client abandoned an earlier request (e.g. the user pressed Esc in
        // the agent). For a running dictate, close the mic now instead of letting
        // the overlay listen until the dictate timeout (up to 300s).
        if message.method == "notifications/cancelled" {
            guard let requestID = Self.rpcID(from: message.params?["requestId"]) else { return }
            switch requests.cancel(requestID) {
            case .ignore, .suppressOnly: break
            case .cancelDictation:
                cancelQueue.async { self.cancelRunningDictation(requestID) }
            }
            return
        }

        switch controlResponse(for: message) {
        case .result(let id, let value): respond(id: id, result: value)
        case .error(let id, let code, let message): respondError(id: id, code: code, message: message)
        case .none: break // a notification, or a no-reply method
        }
    }

    /// The reply (if any) for every non-`tools/call` method — pure, so it's
    /// unit-testable without stdio. A notification or a `default`-with-no-id
    /// yields `.none`.
    enum ControlReply: Equatable {
        case result(id: BridgeWire.RPCID?, value: MCPWire.JSONValue)
        case error(id: BridgeWire.RPCID?, code: Int, message: String)
        case none
    }

    func controlResponse(for message: MCPWire.IncomingMessage) -> ControlReply {
        let id = message.id
        switch message.method {
        case "initialize":
            let requested = message.params?["protocolVersion"]?.stringValue ?? mcpProtocolVersionFallback
            return .result(id: id, value: .object([
                "protocolVersion": .string(requested),
                "serverInfo": .object(["name": .string("openwhisp"),
                                       "version": .string(BridgeClient.version)]),
                "capabilities": .object(["tools": .object([:])]),
                "instructions": .string(Self.serverInstructions),
            ]))
        case "notifications/initialized", "initialized", "notifications/cancelled":
            return .none // no response to a notification
        case "ping":
            return .result(id: id, value: .object([:]))
        case "tools/list":
            return .result(id: id, value: .object(["tools": Self.toolDefinitions]))
        default:
            guard id != nil else { return .none }
            return .error(id: id, code: BridgeWire.ErrorObject.methodNotFound,
                          message: "method not found: \(message.method)")
        }
    }

    // MARK: - Cancellation

    /// Issue `dictate.cancel` until it lands or the dictate returns. One attempt
    /// is usually enough; the retry covers a dictate that has no session yet
    /// (still waiting on the consent prompt, or not yet received by the app) —
    /// otherwise the session would open AFTER the cancel and listen until its
    /// timeout for an agent that's gone.
    func cancelRunningDictation(_ id: BridgeWire.RPCID) {
        let name = clientName
        while requests.isRunningAndCancelled(id) {
            do {
                if try cancelDictation(name) { return }
            } catch {
                // The app is unreachable/wedged: the dictate call will fail on
                // its own (it has a response deadline). Nothing more to do here.
                logStderr("dictate.cancel failed: \(error)")
                return
            }
            Thread.sleep(forTimeInterval: cancelRetryInterval)
        }
    }

    /// A `notifications/cancelled` `requestId` (string or integer) as an RPC id.
    static func rpcID(from value: MCPWire.JSONValue?) -> BridgeWire.RPCID? {
        guard let value else { return nil }
        if let s = value.stringValue { return .string(s) }
        if let i = value.intValue { return .number(i) }
        return nil
    }

    // MARK: - Tool execution (forward to the bridge)

    /// The bridge for this process, built on first use (clientName is set by then).
    private func currentBridge() -> PersistentBridge {
        if let bridge { return bridge }
        let b = bridgeFactory(clientName)
        bridge = b
        return b
    }

    func callTool(
        name: String, arguments: MCPWire.JSONValue, progressToken: MCPWire.JSONValue? = nil
    ) -> MCPWire.ToolResult {
        let bridge = currentBridge()
        do {
            switch name {
            case "openwhisp_dictate":
                // MAK-75: merge any explicit `context` the client passed with
                // self-derived cwd + git branch (the stdio child runs in the
                // client's working dir). Gated by an env opt-out. nil when there's
                // nothing to send, keeping the wire field absent for old servers.
                let explicitContext = Self.dictateContext(from: arguments["context"])
                let resolvedContext = WorkspaceContext.resolved(explicit: explicitContext)
                let params = BridgeWire.DictateParams(
                    prompt: arguments["prompt"]?.stringValue,
                    timeoutSeconds: arguments["timeoutSeconds"]?.intValue,
                    language: arguments["language"]?.stringValue,
                    context: resolvedContext,
                    autoSubmit: arguments["autoSubmit"]?.boolValue
                )
                // dictate blocks until the user finishes (or the timeout). When the
                // client passed a progressToken, emit keep-alive progress against
                // it so long answers don't trip an agent's tool-call timeout
                // (Cursor ~60s). No token → no emitter at all.
                var progress: ProgressEmitter?
                if let progressToken {
                    progress = ProgressEmitter(
                        token: progressToken,
                        interval: progressIntervalSeconds,
                        total: params.timeoutSeconds.map(Double.init),
                        server: self
                    )
                    progress?.start()
                }
                // stop() BEFORE the result is returned/written, and it drains any
                // in-flight tick — the response must be the last frame for this
                // request (no progress after completion).
                defer { progress?.stop() }
                let r = try bridge.call(method: BridgeWire.Method.dictate.rawValue,
                                        params: params, resultType: BridgeWire.DictateResult.self)
                return .text(r.text.isEmpty ? "(the user said nothing)" : r.text)

            case "openwhisp_refine":
                guard let text = arguments["text"]?.stringValue,
                      let instruction = arguments["instruction"]?.stringValue else {
                    return .text("refine requires 'text' and 'instruction'", isError: true)
                }
                let r = try bridge.call(method: BridgeWire.Method.refine.rawValue,
                                        params: BridgeWire.RefineParams(text: text, instruction: instruction),
                                        resultType: BridgeWire.RefineResult.self)
                return .text(r.text)

            case "openwhisp_transcribe_file":
                guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
                    return .text("transcribe_file requires 'path' (an absolute path to an audio file)", isError: true)
                }
                // A long file can take a while to decode + transcribe; emit
                // keep-alive progress against the client's token (like dictate) so
                // the tool call doesn't trip an agent's ~60s timeout. No token → no
                // emitter. `total` is unknown up front, so send an indeterminate
                // stream.
                var progress: ProgressEmitter?
                if let progressToken {
                    progress = ProgressEmitter(
                        token: progressToken, interval: progressIntervalSeconds,
                        total: nil, server: self)
                    progress?.start()
                }
                defer { progress?.stop() }
                let r = try bridge.call(
                    method: BridgeWire.Method.transcribeFile.rawValue,
                    params: BridgeWire.TranscribeFileParams(
                        path: path, language: arguments["language"]?.stringValue),
                    resultType: BridgeWire.TranscribeFileResult.self)
                return .text(r.text.isEmpty ? "(no speech found in the file)" : r.text)

            case "openwhisp_history":
                let r = try bridge.call(method: BridgeWire.Method.historyList.rawValue,
                                        params: BridgeWire.HistoryListParams(limit: arguments["limit"]?.intValue),
                                        resultType: BridgeWire.HistoryListResult.self)
                let lines = r.entries.map { "\($0.date)\t\($0.appName ?? $0.appBundleID ?? "—")\t\($0.text)" }
                return .text(lines.isEmpty ? "(no dictation history)" : lines.joined(separator: "\n"))

            default:
                return .text("unknown tool: \(name)", isError: true)
            }
        } catch let e as BridgeClient.ClientError {
            return .text(Self.clientErrorMessage(e), isError: true)
        } catch {
            return .text("\(error)", isError: true)
        }
    }

    // MARK: - JSON-RPC I/O

    private func respond(id: BridgeWire.RPCID?, result: MCPWire.JSONValue) {
        write(MCPWire.ResultResponse(id: id, result: result))
    }
    private func respondError(id: BridgeWire.RPCID?, code: Int, message: String) {
        write(MCPWire.ErrorResponse(id: id, error: BridgeWire.ErrorObject(code: code, message: message)))
    }
    private func write<T: Encodable>(_ frame: T) {
        guard var data = try? JSONEncoder().encode(frame) else { return }
        data.append(0x0A)
        // Serialize: the progress thread, the tool worker and the stdin loop all
        // write here.
        writeLock.lock()
        defer { writeLock.unlock() }
        output(data) // unbuffered — the client sees it immediately
    }

    /// Emit one `notifications/progress` frame for `token`. `progress` is a
    /// monotonically increasing value; `total`, when known, is the timeout so a
    /// client can render a bar. No `id` — it's a notification.
    fileprivate func sendProgress(
        token: MCPWire.JSONValue, progress: Double, total: Double?, message: String?
    ) {
        var params: [String: MCPWire.JSONValue] = [
            "progressToken": token, "progress": .number(progress),
        ]
        if let total { params["total"] = .number(total) }
        if let message { params["message"] = .string(message) }
        write(MCPWire.OutgoingNotification(method: "notifications/progress", params: .object(params)))
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
        case .timedOut(let method, let seconds):
            return "OpenWhisp didn't answer '\(method)' within \(Int(seconds))s — the app may be frozen or busy. Ask the user to check that OpenWhisp is responsive (or restart it)."
        }
    }

    static let serverInstructions = """
    OpenWhisp exposes on-device voice tools. Use openwhisp_dictate to ask the user \
    a question by voice instead of ending your turn with a plain-text question; \
    use openwhisp_refine to rewrite text with the user's local AI; use \
    openwhisp_history to recall what the user recently dictated; use openwhisp_transcribe_file to \
    transcribe a local audio/video file on-device. Everything runs on \
    the user's Mac — no audio or text leaves the device (unless the user has \
    explicitly enabled a cloud AI provider).
    """

    /// Parse the optional `context` tool argument into a ``BridgeWire.DictateContext``
    /// (MAK-75). Returns nil when absent or carrying nothing usable, so the caller
    /// falls back to pure self-derivation.
    static func dictateContext(from value: MCPWire.JSONValue?) -> BridgeWire.DictateContext? {
        guard let value else { return nil }
        let ctx = BridgeWire.DictateContext(
            cwd: value["cwd"]?.stringValue,
            gitBranch: value["gitBranch"]?.stringValue,
            terms: value["terms"]?.stringArrayValue
        )
        return ctx.isEmpty ? nil : ctx
    }

    /// The MCP `tools/list` payload, as typed ``MCPWire.JSONValue`` so it encodes
    /// through the same path as every other frame.
    static let toolDefinitions: MCPWire.JSONValue = .array([
        .object([
            "name": .string("openwhisp_dictate"),
            "description": .string("""
            Call this whenever you need to ask the user a question, get a decision, or collect \
            free-form input mid-task — instead of ending your turn with a plain-text question. It \
            shows your prompt on the user's screen and opens their OpenWhisp voice overlay; the user \
            speaks and their answer returns as transcribed text. Runs entirely on the user's Mac. Do \
            NOT use for text you already have — use openwhisp_refine for that.
            """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object(["type": .string("string"),
                                       "description": .string("The question to show the user.")]),
                    "timeoutSeconds": .object(["type": .string("integer"),
                                               "description": .string("Max seconds to wait (default 60, max 300).")]),
                    "language": .object(["type": .string("string"),
                                         "description": .string("Optional BCP-47 language hint.")]),
                    "context": .object([
                        "type": .string("object"),
                        "description": .string("""
                        Optional workspace context to bias recognition toward dev terms the user \
                        might speak — a branch name, a file name, the project name. Used locally \
                        only. The server auto-derives cwd + git branch from its own working \
                        directory, so you rarely need to pass this; supply `terms` (e.g. recently \
                        edited file names or symbols) to add more.
                        """),
                        "properties": .object([
                            "cwd": .object(["type": .string("string"),
                                            "description": .string("Working directory (path or basename).")]),
                            "gitBranch": .object(["type": .string("string"),
                                                  "description": .string("Checked-out git branch.")]),
                            "terms": .object(["type": .string("array"),
                                              "items": .object(["type": .string("string")]),
                                              "description": .string("Extra identifiers: file names, symbols, jargon.")]),
                        ]),
                    ]),
                    "autoSubmit": .object(["type": .string("boolean"),
                                           "description": .string("Whether the user's answer is returned immediately when they stop speaking (default true). Set false to give the user a brief window to add more before the answer is submitted.")]),
                ]),
            ]),
        ]),
        .object([
            "name": .string("openwhisp_refine"),
            "description": .string("""
            Call this when you have text that should be rewritten per a natural-language instruction \
            using the user's own on-device LLM — cleaning up a transcript, changing tone ("make it \
            formal"), tightening wording, or applying the user's style. Same model and prompt chain as \
            the user's OpenWhisp refine hotkey.
            """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string"),
                                     "description": .string("The text to rewrite.")]),
                    "instruction": .object(["type": .string("string"),
                                            "description": .string("How to rewrite it.")]),
                ]),
                "required": .array([.string("text"), .string("instruction")]),
            ]),
        ]),
        .object([
            "name": .string("openwhisp_history"),
            "description": .string("""
            Call this when the user refers to something they recently dictated ("what I just said", "my \
            last dictation", "that note I dictated in Slack"). Returns recent OpenWhisp dictation \
            history, newest first, each with text, timestamp, and the app it was dictated into.
            """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("integer"),
                                      "description": .string("Max entries (default 20, max 200).")]),
                ]),
            ]),
        ]),
        .object([
            "name": .string("openwhisp_transcribe_file"),
            "description": .string("""
            Call this to transcribe a local audio or video file — the user hands you (or you already \
            have) a path to a recording and you need the words. Give the absolute path; OpenWhisp \
            decodes it (wav, mp3, m4a, mp4, and more) and transcribes it on the user's Mac with their \
            configured engine. Everything stays on-device. OpenWhisp only reads the file you name — \
            this does not give you any new file access.
            """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"),
                                     "description": .string("Absolute path to the audio/video file to transcribe.")]),
                    "language": .object(["type": .string("string"),
                                         "description": .string("Optional BCP-47 language hint (e.g. \"en\", \"es\").")]),
                ]),
                "required": .array([.string("path")]),
            ]),
        ]),
    ])
}

func logStderr(_ message: String) {
    FileHandle.standardError.write(Data(("openwhisp mcp: " + message + "\n").utf8))
}

/// Drives periodic MCP `notifications/progress` frames on a background thread
/// while a blocking bridge call (currently `dictate`) is in flight. `progress`
/// reports monotonic elapsed seconds measured from `start()` — a wall-clock
/// quantity, so it strictly increases per notification (an MCP requirement)
/// even under timer coalescing, and may exceed `total` briefly while the final
/// transcription runs. When the dictate timeout is known it's sent as `total`
/// so a client can render a determinate bar.
private final class ProgressEmitter {
    private let token: MCPWire.JSONValue
    private let interval: TimeInterval
    private let total: Double?
    private weak var server: MCPServer?
    private let queue = DispatchQueue(label: "com.openwhisp.mcp.progress")
    private var timer: DispatchSourceTimer?
    private var startedAt: DispatchTime = .now()

    init(token: MCPWire.JSONValue, interval: TimeInterval, total: Double?, server: MCPServer) {
        self.token = token
        self.interval = interval
        self.total = total
        self.server = server
    }

    func start() {
        startedAt = .now()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // First tick after one interval (an immediate 0-progress frame is noise).
        // Generous leeway: a keep-alive that arrives at 10.8s instead of 10.0s is
        // equally alive, and coalesced wakeups are cheaper on battery.
        t.schedule(deadline: .now() + interval, repeating: interval,
                   leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                                 - self.startedAt.uptimeNanoseconds) / 1_000_000_000
            self.server?.sendProgress(
                token: self.token, progress: elapsed, total: self.total,
                message: "listening…"
            )
        }
        timer = t
        t.resume()
    }

    /// Cancels the timer AND waits out any tick already running on the queue, so
    /// after stop() returns no further progress frame can be written — the
    /// caller's response is guaranteed to be the last frame for the request.
    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }
}
