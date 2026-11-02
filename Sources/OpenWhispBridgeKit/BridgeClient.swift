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
///
/// Every step is bounded: connect, each write, and each response read have a
/// deadline (see ``BridgeTimeouts``), so a wedged app surfaces as
/// ``ClientError/timedOut(method:seconds:)`` instead of hanging the caller.
public final class BridgeClient {

    /// Failure modes, mapped to CLI exit codes by the caller.
    public enum ClientError: Error {
        /// Socket missing or refused — app not running, or the bridge is off.
        case unreachable
        /// The app rejected our protocol version (CLI newer than the app).
        case unsupportedVersion
        /// A well-formed error response, carrying its domain reason + message.
        case domain(reason: BridgeWire.ErrorCode?, message: String, originalText: String?)
        /// A malformed/unexpected response.
        case protocolError(String)
        /// The app accepted the connection but didn't answer `method` within
        /// `seconds` (or wouldn't take the request). It may be frozen or busy.
        /// The request may or may not have run, so callers must NOT blindly
        /// retry it — and the connection is no longer usable.
        case timedOut(method: String, seconds: TimeInterval)
    }

    /// Computes a call's response deadline from its method and (for `dictate`)
    /// its own `timeoutSeconds`. Injectable so tests can use short deadlines.
    public typealias ResponseDeadline = (_ method: String, _ dictateTimeoutSeconds: Int?) -> TimeInterval

    private let fd: Int32
    private let responseDeadline: ResponseDeadline
    private var readBuffer = Data()
    private var nextRequestID = 0

    /// Recent history from the handshake — capabilities the app advertised.
    private(set) var capabilities: [String] = []

    // MARK: - Connect + handshake

    /// Connect to the running app's socket (discovered via the pointer file /
    /// default App Support path).
    public convenience init() throws {
        // Discovery contract (pointer file for the $TMPDIR fallback, default App
        // Support path) is defined once in BridgeWire.SocketLocation.
        try self.init(socketPath: BridgeWire.SocketLocation.discoverSocketPath())
    }

    /// Connect to the socket at `socketPath`.
    public init(
        socketPath path: String,
        connectTimeout: TimeInterval = BridgeTimeouts.connectSeconds,
        writeTimeout: TimeInterval = BridgeTimeouts.writeSeconds,
        responseDeadline: @escaping ResponseDeadline = BridgeTimeouts.responseDeadline
    ) throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw ClientError.unreachable }
        // If the app dies mid-call, our write must fail with EPIPE, not raise a
        // SIGPIPE that kills the CLI before it can print a diagnostic.
        _ = fcntl(sock, F_SETNOSIGPIPE, 1)

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
        guard Self.connect(sock, to: &addr, timeout: connectTimeout) else {
            close(sock); throw ClientError.unreachable
        }
        Self.setSendTimeout(sock, seconds: writeTimeout)
        self.fd = sock
        self.responseDeadline = responseDeadline
    }

    deinit { close(fd) }

    /// Connect with a deadline: non-blocking connect, then poll for writability.
    private static func connect(_ sock: Int32, to addr: inout sockaddr_un, timeout: TimeInterval) -> Bool {
        let flags = fcntl(sock, F_GETFL)
        guard flags >= 0, fcntl(sock, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        defer { _ = fcntl(sock, F_SETFL, flags) } // back to blocking for the calls

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ap -> Int32 in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, len)
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS || errno == EAGAIN else { return false }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Self.pollMillis(timeout)) == 1 else { return false }
        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &soLen) == 0 else { return false }
        return soError == 0
    }

    private static func setSendTimeout(_ sock: Int32, seconds: TimeInterval) {
        let whole = Int(seconds)
        var tv = timeval(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
        _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func pollMillis(_ seconds: TimeInterval) -> Int32 {
        Int32(min(max(seconds * 1000, 0), Double(Int32.max)).rounded(.up))
    }

    /// Perform the mandatory handshake. Returns the app version; stores
    /// capabilities. Throws `.unsupportedVersion` if the app is too old for us.
    @discardableResult
    public func handshake(clientName: String, clientVersion: String = BridgeClient.version) throws -> BridgeWire.HelloResult {
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

    public func call<P: Codable & Sendable, R: Decodable>(method: String, params: P?, resultType: R.Type) throws -> R {
        nextRequestID += 1
        let id = nextRequestID
        let request = BridgeWire.Request(id: .number(id), method: method, params: params)
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)

        let dictateTimeout = (params as? BridgeWire.DictateParams)?.timeoutSeconds
        let budget = responseDeadline(method, dictateTimeout)
        let deadline = Date().addingTimeInterval(budget)

        try writeAll(data, method: method, budget: budget)
        let line = try readResponseLine(deadline: deadline, method: method, budget: budget)
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

    private func writeAll(_ data: Data, method: String, budget: TimeInterval) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // SO_SNDTIMEO expired: the app isn't draining its socket.
                    throw ClientError.timedOut(method: method, seconds: budget)
                }
                if n <= 0 { throw ClientError.unreachable }
                offset += n
            }
        }
    }

    /// Read one newline-terminated JSON response, buffering any surplus. Gives
    /// up with `.timedOut` once `deadline` passes without a complete line.
    private func readResponseLine(deadline: Date, method: String, budget: TimeInterval) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[readBuffer.startIndex..<nl])
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                if line.isEmpty { continue }
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ClientError.timedOut(method: method, seconds: budget) }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Self.pollMillis(remaining))
            if ready < 0 {
                if errno == EINTR { continue }
                throw ClientError.unreachable
            }
            if ready == 0 { continue } // re-checks the deadline above
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { throw ClientError.unreachable } // EOF before a full line
            readBuffer.append(contentsOf: chunk[0..<n])
            if readBuffer.count > BridgeWire.maxFrameBytes {
                throw ClientError.protocolError("response exceeded frame cap")
            }
        }
    }

    // MARK: - Client identity

    public static let version: String = "0.1.0"

    private static func parentProcessName() -> String? {
        // A best-effort display hint only (never trusted for authorization). The
        // MCP adapter forwards the real client name via handshake; the bare CLI
        // leaves this nil.
        return nil
    }
}
