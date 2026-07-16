import Foundation
import Network
import XCTest

/// JSON-RPC response envelope: exactly one of result/error is set.
private struct RPCEnvelope<T: Decodable>: Decodable {
    var result: T?
    var error: RPCErrorBody?
}
private struct RPCErrorBody: Decodable { var code: Int; var message: String }

/// A minimal TLS 1.3 PSK NDJSON client for the LAN sync E2E — the phone's side of
/// the wire, distilled to what the test drives. It dials 127.0.0.1:<port>, adds the
/// SAME (psk, identity) pair the server added (identity = the peer UUID string),
/// completes the handshake, and does synchronous request/response calls over NDJSON.
final class TLSPSKClient {

    enum ClientError: Error {
        case notReady(String)
        case timeout
        case decode(String)
        case rpc(code: Int, message: String)
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "sync.e2e.client")
    private var readBuffer = Data()
    private var nextID = 0

    init(host: String = "127.0.0.1", port: UInt16, psk: Data, identity: String) throws {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        // MUST mirror the server's version range + PSK ciphersuite (LANBridgeServer
        // makeTLSParameters) — this is the same contract the iOS SyncKit client uses.
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
        let keyDD = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let idDD = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyDD as __DispatchData, idDD as __DispatchData)

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ClientError.notReady("bad port")
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    }

    /// Connect + wait for the TLS handshake to complete (or fail).
    func connect(timeout: TimeInterval = 5) throws {
        let sem = DispatchSemaphore(value: 0)
        var failure: String?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sem.signal()
            case .failed(let err):
                failure = "failed: \(err)"; sem.signal()
            case .waiting(let err):
                failure = "waiting: \(err)"; sem.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        if sem.wait(timeout: .now() + timeout) == .timedOut { throw ClientError.timeout }
        if let failure { throw ClientError.notReady(failure) }
    }

    func cancel() { connection.cancel() }

    /// Send one JSON-RPC request and decode the typed result (throws on an error
    /// response). `params` may be nil for parameterless methods.
    func call<P: Encodable, R: Decodable>(
        method: String, params: P?, resultType: R.Type, timeout: TimeInterval = 5
    ) throws -> R {
        nextID += 1
        var obj: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method]
        if let params {
            let data = try JSONEncoder().encode(params)
            obj["params"] = try JSONSerialization.jsonObject(with: data)
        }
        var line = try JSONSerialization.data(withJSONObject: obj)
        line.append(0x0A)
        try send(line)

        let respData = try readLine(timeout: timeout)
        let env: RPCEnvelope<R>
        do { env = try JSONDecoder().decode(RPCEnvelope<R>.self, from: respData) }
        catch { throw ClientError.decode("\(error): \(String(data: respData, encoding: .utf8) ?? "")") }
        if let e = env.error { throw ClientError.rpc(code: e.code, message: e.message) }
        guard let r = env.result else { throw ClientError.decode("no result/error") }
        return r
    }

    // MARK: - Framing

    private func send(_ data: Data) throws {
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        connection.send(content: data, completion: .contentProcessed { e in err = e; sem.signal() })
        _ = sem.wait(timeout: .now() + 5)
        if let err { throw err }
    }

    private func readLine(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[readBuffer.startIndex..<nl])
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                if line.isEmpty { continue }
                return line
            }
            if Date() > deadline { throw ClientError.timeout }
            let chunk = try receiveOnce(timeout: deadline.timeIntervalSinceNow)
            if chunk.isEmpty { continue }
            readBuffer.append(chunk)
        }
    }

    private func receiveOnce(timeout: TimeInterval) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var out = Data()
        var failed: Error?
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data { out = data }
            if let error { failed = error }
            if isComplete && out.isEmpty { failed = ClientError.notReady("connection closed") }
            sem.signal()
        }
        if sem.wait(timeout: .now() + max(0.1, timeout)) == .timedOut { throw ClientError.timeout }
        if let failed { throw failed }
        return out
    }
}
