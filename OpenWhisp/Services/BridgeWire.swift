import Foundation

/// The OpenWhisp **Agent Bridge** wire contract: the JSON-RPC 2.0 message shapes,
/// method/capability names, and error codes shared by the app (which runs the
/// control-plane socket server) and its adapters — the `openwhisp` CLI and the
/// `openwhisp mcp` stdio server (clients).
///
/// Foundation-only and `Codable`, so it lives in `OpenWhispCore` and the
/// serialization + version-negotiation logic is unit-tested with `swift test`.
/// The app compiles this file into the same module as `AppState` (flat `swiftc`
/// build), while the CLI target imports `OpenWhispCore` as a library — hence
/// every declaration here is `public`.
///
/// **Tolerant by design** (mirrors `ConfigBundle`): additive-only fields within a
/// `protocolVersion`, unknown request fields ignored on decode, and a handshake
/// that rejects a client claiming a *newer* protocol than this build understands.
public enum BridgeWire {

    /// Current wire protocol version. Bump on any breaking change to the shapes
    /// below. The server advertises this in `bridge.hello`; the negotiated version
    /// for a connection is `min(client, server)`.
    public static let protocolVersion = 1

    /// The one JSON-RPC frame cap the transport enforces (1 MiB). A line longer
    /// than this closes the connection — a broken/hostile client can't force the
    /// server to buffer unbounded input.
    public static let maxFrameBytes = 1 << 20

    // MARK: - Version negotiation

    public enum NegotiationError: Error, Equatable {
        /// The client's `protocolVersion` is newer than this build supports; we
        /// can't know what a higher version means, so we refuse (ConfigBundle
        /// reject-from-the-future precedent).
        case unsupportedVersion(client: Int, supported: Int)
    }

    /// Reject a client from the future; otherwise agree on the lower of the two
    /// versions so an older app and a newer CLI still speak a common subset.
    public static func negotiatedProtocolVersion(clientProtocolVersion: Int) throws -> Int {
        guard clientProtocolVersion <= protocolVersion else {
            throw NegotiationError.unsupportedVersion(
                client: clientProtocolVersion, supported: protocolVersion
            )
        }
        return Swift.min(clientProtocolVersion, protocolVersion)
    }

    // MARK: - Method + capability names

    /// Request methods a client may invoke. Notification method names live in
    /// ``Notify``. Raw values are the on-the-wire `method` strings.
    public enum Method: String, Codable, Sendable, CaseIterable {
        case hello = "bridge.hello"
        case status = "status"
        case dictate = "dictate"
        case dictateStop = "dictate.stop"
        case dictateCancel = "dictate.cancel"
        case refine = "refine"
        case historyList = "history.list"
        /// Deferred to v1.1; reserved so the name is designed once and gated by
        /// the capabilities handshake.
        case transcribeFile = "transcribe.file"
    }

    /// Server→client notification method names (no `id`, no response).
    public enum Notify {
        public static let dictateState = "dictate.state"
        public static let dictatePartial = "dictate.partial" // v1.1
        public static let consent = "bridge.consent"
    }

    /// Capability tokens advertised in `HelloResult.capabilities`. Adapters use
    /// these to hide tools the running app doesn't offer (e.g. `transcribeFile`
    /// before v1.1).
    public enum Capability {
        public static let dictate = "dictate"
        public static let refine = "refine"
        public static let history = "history"
        public static let transcribeFile = "transcribeFile" // reserved for v1.1
    }

    // MARK: - Error codes

    /// Domain error codes, carried in ``ErrorData/reason``. The JSON-RPC numeric
    /// `code` on ``ErrorObject`` conveys transport-level classification; this enum
    /// conveys what actually happened so the CLI can map it to an exit code and an
    /// agent can decide whether to retry.
    public enum ErrorCode: String, Codable, Sendable, Equatable, CaseIterable {
        /// A session (user- or agent-initiated) is already active; the human
        /// always wins the mic. No queueing — the caller may retry after waiting.
        case busy
        /// This client has hit its dictation rate limit (a per-client cooldown
        /// between sessions and/or a sessions-per-hour cap). Distinct from
        /// ``busy``: nothing else is using the mic — this client is deliberately
        /// throttled so an always-allowed agent can't hold the mic continuously.
        /// ``ErrorData/retryAfterSeconds`` carries when it may try again.
        case rateLimited
        /// The user pressed Esc / the client called `dictate.cancel`. Per the
        /// cancel invariant, a cancelled dictate returns NO transcript text.
        case cancelled
        /// `timeoutSeconds` elapsed with nothing transcribed.
        case timeout
        /// The user (or a stored policy) denied this client's request.
        case consentDenied
        /// A secure text field was focused; agent dictation refuses.
        case secureField
        /// No usable LLM is configured, the bundled model is missing, or a local
        /// generation failed. On `refine`, ``ErrorData/originalText`` carries the
        /// caller's text back so the agent can proceed unrefined.
        case llmUnavailable
        /// Agent-initiated cloud LLM use is disabled. The user's provider is
        /// OpenAI and they have not enabled "Allow agents to use cloud AI".
        case cloudRefineDisabled
        /// The microphone permission is not yet granted; the bridge will not
        /// surface the TCC prompt on an agent's behalf.
        case micPermissionNeeded
        /// (v1.1) `transcribe.file` was given an unsupported audio format.
        case unsupportedFormat
        /// The client's `protocolVersion` is newer than this build supports.
        case unsupportedVersion
        /// A microphone/audio device error aborted the session.
        case audioUnavailable
        /// History is off in Settings; `history.list` returns an empty list, but
        /// this code exists for callers that want the explicit signal.
        case historyDisabled
        /// The first frame wasn't `bridge.hello`, or a frame was malformed /
        /// oversized.
        case malformedRequest
        /// Unknown method name.
        case unknownMethod
        /// An unexpected server-side failure.
        case internalError
    }

    // MARK: - JSON-RPC envelope

    /// A JSON-RPC 2.0 id: a string, an integer, or null. Modeled precisely so the
    /// server can echo the client's id back unchanged.
    public enum RPCID: Codable, Sendable, Equatable {
        case string(String)
        case number(Int)
        case null

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let i = try? c.decode(Int.self) {
                self = .number(i)
            } else if let s = try? c.decode(String.self) {
                self = .string(s)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "JSON-RPC id must be string, number, or null"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            case .null: try c.encodeNil()
            }
        }
    }

    /// The minimal envelope the server decodes first, to learn `id` + `method`
    /// before re-decoding the same line as a typed ``Request``. `params` is
    /// intentionally omitted here (its type isn't known until `method` is read).
    public struct RequestEnvelope: Codable, Sendable, Equatable {
        public var jsonrpc: String
        public var id: RPCID?
        public var method: String

        public init(jsonrpc: String = "2.0", id: RPCID?, method: String) {
            self.jsonrpc = jsonrpc
            self.id = id
            self.method = method
        }

        // Tolerant decode: `method` is required, but a client (or a `nc` tester)
        // that omits `jsonrpc`/`id` is accepted rather than silently closed.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.method = try c.decode(String.self, forKey: .method)
            self.jsonrpc = try c.decodeIfPresent(String.self, forKey: .jsonrpc) ?? "2.0"
            self.id = try c.decodeIfPresent(RPCID.self, forKey: .id)
        }
    }

    /// A typed request. Decode a line with `Params == Never`-shaped stubs by using
    /// ``NoParams`` for parameterless methods.
    public struct Request<Params: Codable & Sendable>: Codable, Sendable {
        public var jsonrpc: String
        public var id: RPCID?
        public var method: String
        public var params: Params?

        public init(id: RPCID?, method: String, params: Params?) {
            self.jsonrpc = "2.0"
            self.id = id
            self.method = method
            self.params = params
        }
    }

    /// A typed response. Exactly one of `result` / `error` is set.
    public struct Response<Result: Codable & Sendable>: Codable, Sendable {
        public var jsonrpc: String
        public var id: RPCID?
        public var result: Result?
        public var error: ErrorObject?

        public init(id: RPCID?, result: Result) {
            self.jsonrpc = "2.0"
            self.id = id
            self.result = result
            self.error = nil
        }

        public init(id: RPCID?, error: ErrorObject) {
            self.jsonrpc = "2.0"
            self.id = id
            self.result = nil
            self.error = error
        }
    }

    /// A server→client notification: no `id`, never answered.
    public struct Notification<Params: Codable & Sendable>: Codable, Sendable {
        public var jsonrpc: String
        public var method: String
        public var params: Params

        public init(method: String, params: Params) {
            self.jsonrpc = "2.0"
            self.method = method
            self.params = params
        }
    }

    /// Placeholder params for methods that take no arguments.
    public struct NoParams: Codable, Sendable, Equatable {
        public init() {}
    }
}

// Conditional `Equatable` for the generic envelopes — synthesized when the
// payload is Equatable. Handy for tests and diffing, harmless in production
// (`RPCID` and `ErrorObject` are already Equatable).
extension BridgeWire.Request: Equatable where Params: Equatable {}
extension BridgeWire.Response: Equatable where Result: Equatable {}
extension BridgeWire.Notification: Equatable where Params: Equatable {}

extension BridgeWire {

    public struct ErrorObject: Codable, Sendable, Equatable, Error {
        /// JSON-RPC numeric code. `-32601` method not found, `-32602` invalid
        /// params, `-32700` parse error, `-32600` invalid request; all domain
        /// failures use `-32000` (server error) with the specifics in ``data``.
        public var code: Int
        public var message: String
        public var data: ErrorData?

        public init(code: Int, message: String, data: ErrorData? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        // JSON-RPC reserved codes.
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let serverError = -32000

        /// Build a domain error (`serverError` code + a `reason`).
        public static func domain(
            _ reason: ErrorCode, message: String,
            originalText: String? = nil, retryAfterSeconds: Int? = nil
        ) -> ErrorObject {
            ErrorObject(
                code: serverError,
                message: message,
                data: ErrorData(reason: reason, originalText: originalText, retryAfterSeconds: retryAfterSeconds)
            )
        }
    }

    public struct ErrorData: Codable, Sendable, Equatable {
        public var reason: ErrorCode?
        /// On `refine` failure, the caller's original text — so an agent can
        /// proceed unrefined (mirrors the overlay's insert-unrefined fallback).
        /// NEVER used to smuggle a cancelled dictation's transcript.
        public var originalText: String?
        /// On a ``ErrorCode/rateLimited`` refusal, whole seconds the client should
        /// wait before retrying `dictate` (ceil of the true wait, so a retry after
        /// this many seconds is guaranteed past the limit). Absent otherwise.
        public var retryAfterSeconds: Int?

        public init(reason: ErrorCode? = nil, originalText: String? = nil, retryAfterSeconds: Int? = nil) {
            self.reason = reason
            self.originalText = originalText
            self.retryAfterSeconds = retryAfterSeconds
        }
    }

    // MARK: - bridge.hello

    public struct HelloParams: Codable, Sendable, Equatable {
        public var protocolVersion: Int
        public var clientName: String
        public var clientVersion: String
        /// A best-effort hint (e.g. the bare CLI's parent process name); never
        /// trusted for authorization.
        public var parentProcess: String?

        public init(
            protocolVersion: Int, clientName: String, clientVersion: String,
            parentProcess: String? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.parentProcess = parentProcess
        }
    }

    public enum ConsentState: String, Codable, Sendable, Equatable {
        case granted, pending, denied
    }

    public struct HelloResult: Codable, Sendable, Equatable {
        public var protocolVersion: Int
        public var appVersion: String
        public var capabilities: [String]
        public var clientId: String
        /// Summary posture across every scope: `.granted` only when ALL scopes
        /// are already allowed, `.denied` only when all are denied, else
        /// `.pending`. Too lossy on its own once consent is per-scope — read
        /// ``consentScopes`` for the actionable state.
        public var consent: ConsentState
        /// Per-scope posture, keyed by scope name ("dictate"/"history"/"refine").
        /// Additive (older servers omit it; tolerant decode makes that nil).
        public var consentScopes: [String: ConsentState]?

        public init(
            protocolVersion: Int, appVersion: String, capabilities: [String],
            clientId: String, consent: ConsentState,
            consentScopes: [String: ConsentState]? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.appVersion = appVersion
            self.capabilities = capabilities
            self.clientId = clientId
            self.consent = consent
            self.consentScopes = consentScopes
        }
    }

    // MARK: - status

    public struct StatusResult: Codable, Sendable, Equatable {
        public var appVersion: String
        public var engine: String
        public var model: String
        public var sessionActive: Bool
        public var llmConfigured: Bool
        public var llmProvider: String
        /// True when the configured LLM path leaves the device (provider ==
        /// openai). Lets an adapter disclose posture before calling `refine`.
        public var sendsTextToCloud: Bool
        public var historyEnabled: Bool

        public init(
            appVersion: String, engine: String, model: String, sessionActive: Bool,
            llmConfigured: Bool, llmProvider: String, sendsTextToCloud: Bool,
            historyEnabled: Bool
        ) {
            self.appVersion = appVersion
            self.engine = engine
            self.model = model
            self.sessionActive = sessionActive
            self.llmConfigured = llmConfigured
            self.llmProvider = llmProvider
            self.sendsTextToCloud = sendsTextToCloud
            self.historyEnabled = historyEnabled
        }
    }

    // MARK: - dictate

    public struct DictateParams: Codable, Sendable, Equatable {
        /// The agent's question, shown in the overlay (sanitized + client-name
        /// prefixed by the server before display).
        public var prompt: String?
        /// Defaulted server-side to 60, hard-capped at 300.
        public var timeoutSeconds: Int?
        public var language: String?

        public init(prompt: String? = nil, timeoutSeconds: Int? = nil, language: String? = nil) {
            self.prompt = prompt
            self.timeoutSeconds = timeoutSeconds
            self.language = language
        }

        public static let defaultTimeoutSeconds = 60
        public static let maxTimeoutSeconds = 300
    }

    /// How an agent-initiated dictation ended. `cancel` is absent by design: a
    /// cancel produces an error, never a result.
    public enum DictateEnd: String, Codable, Sendable, Equatable {
        case user   // user finished (hotkey tap / silence)
        case timeout
        case stop   // client called dictate.stop
    }

    public struct DictateResult: Codable, Sendable, Equatable {
        public var text: String
        public var durationSeconds: Double
        public var timedOut: Bool
        public var endedBy: DictateEnd

        public init(text: String, durationSeconds: Double, timedOut: Bool, endedBy: DictateEnd) {
            self.text = text
            self.durationSeconds = durationSeconds
            self.timedOut = timedOut
            self.endedBy = endedBy
        }
    }

    public struct DictateStopResult: Codable, Sendable, Equatable {
        public var stopped: Bool
        public init(stopped: Bool) { self.stopped = stopped }
    }

    public struct DictateCancelResult: Codable, Sendable, Equatable {
        public var cancelled: Bool
        public init(cancelled: Bool) { self.cancelled = cancelled }
    }

    /// The lifecycle phases pushed as `dictate.state` notifications while a
    /// blocking `dictate` call runs.
    public enum DictateState: String, Codable, Sendable, Equatable {
        case consentPending, starting, listening, transcribing, refining
    }

    public struct DictateStateParams: Codable, Sendable, Equatable {
        public var state: DictateState
        public init(state: DictateState) { self.state = state }
    }

    public struct DictatePartialParams: Codable, Sendable, Equatable { // v1.1
        public var text: String
        public init(text: String) { self.text = text }
    }

    public struct ConsentParams: Codable, Sendable, Equatable {
        public var consent: ConsentState
        public init(consent: ConsentState) { self.consent = consent }
    }

    // MARK: - refine

    public struct RefineParams: Codable, Sendable, Equatable {
        public var text: String
        public var instruction: String
        public init(text: String, instruction: String) {
            self.text = text
            self.instruction = instruction
        }
    }

    public struct RefineResult: Codable, Sendable, Equatable {
        public var text: String
        public init(text: String) { self.text = text }
    }

    // MARK: - history.list

    public struct HistoryListParams: Codable, Sendable, Equatable {
        /// Defaulted server-side to 20, hard-capped at 200.
        public var limit: Int?
        public init(limit: Int? = nil) { self.limit = limit }

        public static let defaultLimit = 20
        public static let maxLimit = 200
    }

    /// A history entry as seen on the wire. The date is an ISO-8601 string so the
    /// app's on-disk Apple-epoch encoding is never exposed across the boundary.
    public struct HistoryEntryDTO: Codable, Sendable, Equatable {
        public var id: UUID
        public var text: String
        public var date: String
        public var appBundleID: String?
        public var appName: String?
        /// "user" or "agent" — who initiated the dictation (nil for entries
        /// predating the field).
        public var initiator: String?

        public init(
            id: UUID, text: String, date: String, appBundleID: String?,
            appName: String?, initiator: String?
        ) {
            self.id = id
            self.text = text
            self.date = date
            self.appBundleID = appBundleID
            self.appName = appName
            self.initiator = initiator
        }
    }

    public struct HistoryListResult: Codable, Sendable, Equatable {
        public var entries: [HistoryEntryDTO]
        public init(entries: [HistoryEntryDTO]) { self.entries = entries }
    }

    // MARK: - Date coding

    /// Fixed ISO-8601 formatter used at the history boundary. Internet date-time
    /// with fractional seconds, always UTC, so timestamps are stable and locale-
    /// independent on the wire.
    public static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func iso8601String(from date: Date) -> String {
        iso8601.string(from: date)
    }

    public static func date(fromISO8601 string: String) -> Date? {
        iso8601.date(from: string)
    }

    // MARK: - Display sanitation

    /// Sanitize an agent-supplied string (client name, dictate prompt) for display
    /// in OpenWhisp's own UI: collapse ALL line breaks (including U+2028/U+2029/
    /// NEL, which CoreText honors as mandatory breaks — a raw "\n" check would let
    /// a prompt inject lines that read as OpenWhisp's own voice), strip control
    /// and bidi-override characters, trim, and cap the length. Display only —
    /// never authorization.
    public static func sanitizedForDisplay(_ raw: String, maxLength: Int) -> String {
        let cleaned = raw
            .components(separatedBy: .newlines).joined(separator: " ")
            .filter { !$0.unicodeScalars.contains(where: {
                $0.properties.isBidiControl || CharacterSet.controlCharacters.contains($0)
            }) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength)) + "…"
    }

    // MARK: - Socket location

    /// The server↔client socket-discovery contract, defined once for both sides:
    /// where the control socket nominally lives, and the pointer file the server
    /// writes so clients can find the `$TMPDIR` fallback used when the home path
    /// is too long for `sun_path`.
    public enum SocketLocation {
        public static let directoryName = "OpenWhisp"
        public static let socketFileName = "agent.sock"
        public static let pointerFileName = "agent.sock.path"

        /// `~/Library/Application Support/OpenWhisp`.
        public static func appSupportDirectory() -> URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            return base.appendingPathComponent(directoryName, isDirectory: true)
        }

        /// The nominal socket path (ignoring the server's long-path fallback).
        public static func defaultSocketPath() -> String {
            appSupportDirectory().appendingPathComponent(socketFileName).path
        }

        /// Client-side discovery: the pointer file's contents if present (covers
        /// the `$TMPDIR` fallback), else the default path.
        public static func discoverSocketPath() -> String {
            let pointer = appSupportDirectory().appendingPathComponent(pointerFileName)
            if let data = try? Data(contentsOf: pointer),
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
            return defaultSocketPath()
        }
    }
}
