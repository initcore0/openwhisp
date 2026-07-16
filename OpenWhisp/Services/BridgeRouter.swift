import Foundation

/// Pure routing + validation for the Agent Bridge control plane: it turns one raw
/// NDJSON request line into a typed ``Intent`` (or a ready-to-send error, or a
/// decision to close), with no sockets, no I/O, and no app dependencies. The
/// fiddly rules — handshake-must-come-first, unknown methods, malformed frames,
/// per-method param requirements — live here so they can be unit-tested;
/// `AgentBridgeServer` executes the intents this returns.
public enum BridgeRouter {

    /// A validated client intent, carrying the JSON-RPC id to answer on.
    public enum Intent: Equatable {
        case hello(id: BridgeWire.RPCID?, params: BridgeWire.HelloParams)
        case status(id: BridgeWire.RPCID?)
        case dictate(id: BridgeWire.RPCID?, params: BridgeWire.DictateParams)
        case dictateStop(id: BridgeWire.RPCID?)
        case dictateCancel(id: BridgeWire.RPCID?)
        case refine(id: BridgeWire.RPCID?, params: BridgeWire.RefineParams)
        case historyList(id: BridgeWire.RPCID?, params: BridgeWire.HistoryListParams)
        // P2P sync (MAK-51 WP0b, wire v1.2). Handlers live behind AgentBridgeHost;
        // the mac-side real handlers are WP6-mac.
        case syncManifest(id: BridgeWire.RPCID?)
        case syncPull(id: BridgeWire.RPCID?, params: BridgeWire.SyncPullParams)
        case syncPush(id: BridgeWire.RPCID?, params: BridgeWire.SyncBundleResult)
    }

    /// The outcome of routing one line.
    public enum Routed: Equatable {
        /// Dispatch this intent (hop to the host and reply).
        case intent(Intent)
        /// Reply with this error, then keep the connection open.
        case error(id: BridgeWire.RPCID?, error: BridgeWire.ErrorObject)
        /// Close the connection with no reply — a handshake violation or an
        /// unparseable/oversized frame (no oracle to a hostile client).
        case close(reason: String)
    }

    /// Route one NDJSON line. `hasHandshaken` is false until a `bridge.hello` has
    /// been accepted on this connection.
    public static func route(line: Data, hasHandshaken: Bool) -> Routed {
        // Oversized frames never reach here in the server (the read loop caps at
        // maxFrameBytes and closes), but guard anyway so the pure router is
        // self-contained and testable.
        guard line.count <= BridgeWire.maxFrameBytes else {
            return .close(reason: "frame exceeds \(BridgeWire.maxFrameBytes) bytes")
        }

        let envelope: BridgeWire.RequestEnvelope
        do {
            envelope = try JSONDecoder().decode(BridgeWire.RequestEnvelope.self, from: line)
        } catch {
            // Malformed JSON or a non-request object: close (do not leak a parse
            // oracle). This is a protocol violation, not a recoverable call.
            return .close(reason: "malformed frame")
        }

        let id = envelope.id

        // Handshake ordering: the very first frame MUST be bridge.hello.
        guard let method = BridgeWire.Method(rawValue: envelope.method) else {
            if !hasHandshaken { return .close(reason: "first frame must be bridge.hello") }
            return .error(
                id: id,
                error: BridgeWire.ErrorObject(
                    code: BridgeWire.ErrorObject.methodNotFound,
                    message: "unknown method '\(envelope.method)'",
                    data: BridgeWire.ErrorData(reason: .unknownMethod)
                )
            )
        }

        if !hasHandshaken && method != .hello {
            return .close(reason: "first frame must be bridge.hello, got '\(envelope.method)'")
        }

        switch method {
        case .hello:
            guard let params = decodeParams(BridgeWire.HelloParams.self, from: line) else {
                return invalidParams(id, "bridge.hello requires protocolVersion, clientName, clientVersion")
            }
            return .intent(.hello(id: id, params: params))

        case .status:
            return .intent(.status(id: id))

        case .dictate:
            // All params optional; absent → server defaults.
            let params = decodeParams(BridgeWire.DictateParams.self, from: line) ?? BridgeWire.DictateParams()
            return .intent(.dictate(id: id, params: params))

        case .dictateStop:
            return .intent(.dictateStop(id: id))

        case .dictateCancel:
            return .intent(.dictateCancel(id: id))

        case .refine:
            guard let params = decodeParams(BridgeWire.RefineParams.self, from: line) else {
                return invalidParams(id, "refine requires text and instruction")
            }
            return .intent(.refine(id: id, params: params))

        case .historyList:
            let params = decodeParams(BridgeWire.HistoryListParams.self, from: line) ?? BridgeWire.HistoryListParams()
            return .intent(.historyList(id: id, params: params))

        case .transcribeFile:
            // Reserved for v1.1; the capabilities handshake keeps clients from
            // sending it, but reject explicitly if one does.
            return .error(
                id: id,
                error: BridgeWire.ErrorObject.domain(
                    .unknownMethod, message: "transcribe.file is not available in this version"
                )
            )

        case .syncManifest:
            // No params; the host answers with the local manifest.
            return .intent(.syncManifest(id: id))

        case .syncPull:
            // All params optional (absent cursor → full; absent `want` → all
            // sections), so a bare `sync.pull` is a valid first-full-sync request.
            let params = decodeParams(BridgeWire.SyncPullParams.self, from: line) ?? BridgeWire.SyncPullParams()
            return .intent(.syncPull(id: id, params: params))

        case .syncPush:
            // A push MUST carry a bundle to merge — an absent/mistyped payload is
            // invalidParams, mirroring refine's required-params contract.
            guard let params = decodeParams(BridgeWire.SyncBundleResult.self, from: line) else {
                return invalidParams(id, "sync.push requires a bundle (and optional historyEntries)")
            }
            return .intent(.syncPush(id: id, params: params))
        }
    }

    /// Clamp a requested dictate timeout into the allowed range, applying the
    /// default when absent.
    public static func resolvedTimeoutSeconds(_ requested: Int?) -> Int {
        let v = requested ?? BridgeWire.DictateParams.defaultTimeoutSeconds
        return min(max(v, 1), BridgeWire.DictateParams.maxTimeoutSeconds)
    }

    /// Clamp a requested history limit into the allowed range, applying the
    /// default when absent.
    public static func resolvedHistoryLimit(_ requested: Int?) -> Int {
        let v = requested ?? BridgeWire.HistoryListParams.defaultLimit
        return min(max(v, 0), BridgeWire.HistoryListParams.maxLimit)
    }

    // MARK: - Private

    private static func decodeParams<P: Decodable>(_ type: P.Type, from line: Data) -> P? {
        // The envelope was already decoded once; re-decode the same line as a
        // typed Request to pull params. A missing/mistyped params object yields nil.
        return (try? JSONDecoder().decode(ParamsEnvelope<P>.self, from: line))?.params
    }

    /// Just the `params` slot of a request line, for re-decoding by type.
    private struct ParamsEnvelope<T: Decodable>: Decodable { var params: T? }

    private static func invalidParams(_ id: BridgeWire.RPCID?, _ message: String) -> Routed {
        .error(
            id: id,
            error: BridgeWire.ErrorObject(
                code: BridgeWire.ErrorObject.invalidParams,
                message: message,
                data: BridgeWire.ErrorData(reason: .malformedRequest)
            )
        )
    }
}
