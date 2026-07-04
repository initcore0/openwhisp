import Foundation
import Darwin
import OpenWhispCore

/// The `result` / `error` slots of a JSON-RPC response, for typed decoding.
private struct ResponseEnvelope<T: Decodable>: Decodable {
    var result: T?
    var error: BridgeWire.ErrorObject?
}

/// A thin synchronous client for OpenWhisp's Agent Bridge control-plane socket.
/// Connects to the app's UNIX-domain socket, performs the `bridge.hello`
/// handshake, and issues typed request/response calls. Used by both the CLI
/// verbs and (later) the MCP adapter.
final class BridgeClient {

    /// Failure modes, mapped to CLI exit codes by the caller.
    enum ClientError: Error {
        /// Socket missing or refused — app not running, or the bridge is off.
        case unreachable
        /// The app rejected our protocol version (CLI newer than the app).
        case unsupportedVersion
        /// A well-formed error response, carrying its domain reason + message.
        case domain(reason: BridgeWire.ErrorCode?, message: String, originalText: String?)
        /// A malformed/unexpected response.
        case protocolError(String)
    }

    private let fd: Int32
    private var readBuffer = Data()
    private var nextRequestID = 0

    /// Recent history from the handshake — capabilities the app advertised.
    private(set) var capabilities: [String] = []

    // MARK: - Socket path

    /// The control socket path: the pointer file's contents if present (handles
    /// the `$TMPDIR` fallback), else the default App Support location.
    static func socketPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("OpenWhisp", isDirectory: true)
        let pointer = dir.appendingPathComponent("agent.sock.path")
        if let data = try? Data(contentsOf: pointer),
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return dir.appendingPathComponent("agent.sock").path
    }

    // MARK: - Connect + handshake

    init() throws {
        let path = BridgeClient.socketPath()
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw ClientError.unreachable }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { close(sock); throw ClientError.unreachable }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString { src in
                p.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                    strncpy(dst, src, capacity - 1)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ap -> Int32 in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(sock, sa, len)
            }
        }
        guard connected == 0 else { close(sock); throw ClientError.unreachable }
        self.fd = sock
    }

    deinit { close(fd) }

    /// Perform the mandatory handshake. Returns the app version; stores
    /// capabilities. Throws `.unsupportedVersion` if the app is too old for us.
    @discardableResult
    func handshake(clientName: String, clientVersion: String = BridgeClient.version) throws -> BridgeWire.HelloResult {
        let params = BridgeWire.HelloParams(
            protocolVersion: BridgeWire.protocolVersion,
            clientName: clientName,
            clientVersion: clientVersion,
            parentProcess: BridgeClient.parentProcessName()
        )
        let result: BridgeWire.HelloResult = try call(
            method: BridgeWire.Method.hello.rawValue, params: params, resultType: BridgeWire.HelloResult.self
        )
        capabilities = result.capabilities
        return result
    }

    // MARK: - Typed call

    func call<P: Codable & Sendable, R: Decodable>(method: String, params: P?, resultType: R.Type) throws -> R {
        nextRequestID += 1
        let id = nextRequestID
        let request = BridgeWire.Request(id: .number(id), method: method, params: params)
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try writeAll(data)

        let line = try readResponseLine()
        let resp: ResponseEnvelope<R>
        do {
            resp = try JSONDecoder().decode(ResponseEnvelope<R>.self, from: line)
        } catch {
            throw ClientError.protocolError("undecodable response: \(error.localizedDescription)")
        }
        if let err = resp.error {
            if err.data?.reason == .unsupportedVersion { throw ClientError.unsupportedVersion }
            throw ClientError.domain(reason: err.data?.reason, message: err.message, originalText: err.data?.originalText)
        }
        guard let result = resp.result else { throw ClientError.protocolError("response had neither result nor error") }
        return result
    }

    // MARK: - Framing

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n <= 0 { throw ClientError.unreachable }
                offset += n
            }
        }
    }

    /// Read one newline-terminated JSON response, buffering any surplus.
    private func readResponseLine() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[readBuffer.startIndex..<nl])
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                if line.isEmpty { continue }
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw ClientError.unreachable } // EOF before a full line
            readBuffer.append(contentsOf: chunk[0..<n])
            if readBuffer.count > BridgeWire.maxFrameBytes {
                throw ClientError.protocolError("response exceeded frame cap")
            }
        }
    }

    // MARK: - Client identity

    static let version: String = "0.1.0"

    private static func parentProcessName() -> String? {
        // A best-effort display hint only (never trusted for authorization). The
        // MCP adapter forwards the real client name via handshake; the bare CLI
        // leaves this nil.
        return nil
    }
}
