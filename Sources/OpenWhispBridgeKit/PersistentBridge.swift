import Foundation
import OpenWhispCore

/// A bridge session: connect + handshake once, then issue typed calls. Abstracts
/// ``BridgeClient`` so the MCP adapter's cache/retry logic can be unit-tested
/// against a fake.
public protocol BridgeSession: AnyObject {
    func handshake(clientName: String) throws
    func call<P: Codable & Sendable, R: Decodable>(method: String, params: P?, resultType: R.Type) throws -> R
}

extension BridgeClient: BridgeSession {
    public func handshake(clientName: String) throws {
        _ = try handshake(clientName: clientName, clientVersion: BridgeClient.version)
    }
}

/// Opens a freshly connected + handshaked ``BridgeSession``. Injected into
/// ``PersistentBridge`` so tests can substitute a fake transport.
public typealias BridgeSessionFactory = (_ clientName: String) throws -> BridgeSession

/// Caches ONE bridge connection per adapter process instead of reconnecting +
/// re-handshaking on every `tools/call`.
///
/// The app can restart under a running adapter (the MCP server outlives an app
/// relaunch), which invalidates a cached socket. So on a transport failure —
/// `ClientError.unreachable` (socket gone) or `.protocolError` (a stale/garbled
/// frame) — the cache is dropped and the call is retried exactly once on a fresh
/// connection. A second failure propagates: the app is genuinely down.
///
/// A timeout (`ClientError.timedOut`) drops the cache but is NOT retried: the
/// app may be wedged or still running the request.
///
/// Domain errors (`ClientError.domain`, e.g. `busy` / `consentDenied` /
/// `llmUnavailable`) are NOT transport failures — they mean the bridge answered.
/// They propagate immediately without dropping the cache or retrying, so consent
/// stays a per-call server-side decision (unchanged by caching).
public final class PersistentBridge {
    private let clientName: String
    private let connect: BridgeSessionFactory
    private var cached: BridgeSession?

    public init(clientName: String, connect: @escaping BridgeSessionFactory = { name in
        let client = try BridgeClient()
        try client.handshake(clientName: name)
        return client
    }) {
        self.clientName = clientName
        self.connect = connect
    }

    private func session() throws -> BridgeSession {
        if let cached { return cached }
        let s = try connect(clientName)
        cached = s
        return s
    }

    private func dropCache() { cached = nil }

    /// Issue a typed call, transparently (re)connecting. On a transport failure,
    /// drop the cached connection and retry once on a fresh one.
    public func call<P: Codable & Sendable, R: Decodable>(
        method: String, params: P?, resultType: R.Type
    ) throws -> R {
        do {
            return try session().call(method: method, params: params, resultType: resultType)
        } catch let e as BridgeClient.ClientError where Self.isTransportFailure(e) {
            // Stale connection (app restarted, or a garbled frame). Reconnect once.
            dropCache()
            return try session().call(method: method, params: params, resultType: resultType)
        } catch let e as BridgeClient.ClientError {
            // A timeout leaves the socket desynced (a late reply would be read as
            // the NEXT call's answer), so drop it — but never retry: the app may
            // be wedged, or may still be running the request (a re-sent dictate
            // would reopen the mic).
            if case .timedOut = e { dropCache() }
            throw e
        }
    }

    /// Transport-level failures worth a reconnect-and-retry, vs. domain errors
    /// (the bridge answered) which must propagate unchanged.
    static func isTransportFailure(_ e: BridgeClient.ClientError) -> Bool {
        switch e {
        case .unreachable, .protocolError: return true
        case .unsupportedVersion, .domain, .timedOut: return false
        }
    }
}
