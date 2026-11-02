import Foundation
import Darwin

// Connection limits + socket timeouts for the app's UNIX-socket Agent Bridge
// (AgentBridgeServer, app-only). Kept in core so `swift test` drives the real
// read loop over a socket pair; the server just calls into it.

/// Limits and timeouts for Agent Bridge connections.
public enum BridgeConnectionPolicy {

    /// Max connections served at once. Each holds a thread; a legit setup has
    /// one cached connection per MCP adapter (one per agent session) plus the
    /// odd short-lived CLI call, so this is generous. Over the cap a connection
    /// gets a `busy` error frame and is closed.
    public static let maxConcurrentConnections = 32

    /// SO_RCVTIMEO tick: how often a connection thread waiting for the next
    /// request wakes up to notice `stop()` or idleness.
    public static let readPollSeconds: TimeInterval = 5

    /// A connection with no traffic between requests for this long is closed.
    /// Time spent running a request (a dictate can block for minutes) doesn't
    /// count. A cached MCP adapter connection just reconnects on its next call.
    public static let idleTimeoutSeconds: TimeInterval = 300

    /// SO_SNDTIMEO: a peer that won't read our reply for this long is wedged.
    public static let writeTimeoutSeconds: TimeInterval = 10

    /// What to do when a read wakes up with no data.
    public enum ReadTimeoutVerdict: Equatable {
        case keepWaiting
        case closeIdle
        case closeStopped
    }

    public static func afterReadTimeout(
        idleFor: TimeInterval, isRunning: Bool, idleTimeout: TimeInterval = idleTimeoutSeconds
    ) -> ReadTimeoutVerdict {
        if !isRunning { return .closeStopped }
        return idleFor >= idleTimeout ? .closeIdle : .keepWaiting
    }

    /// The NDJSON frame sent to a connection rejected over the cap, so the client
    /// sees a clear `busy` error instead of an "app not running" EOF.
    public static func busyRejectionFrame() -> Data {
        let response = BridgeWire.Response<BridgeWire.NoParams>(
            id: .null,
            error: .domain(.busy, message: "OpenWhisp has too many open Agent Bridge connections (max \(maxConcurrentConnections)); try again shortly")
        )
        var data = (try? JSONEncoder().encode(response)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Set SO_RCVTIMEO / SO_SNDTIMEO on a socket.
    public static func setTimeouts(fd: Int32, read: TimeInterval, write: TimeInterval) {
        var r = timeval(seconds: read)
        var w = timeval(seconds: write)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &r, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &w, socklen_t(MemoryLayout<timeval>.size))
    }
}

private extension timeval {
    init(seconds: TimeInterval) {
        let whole = Int(seconds)
        self.init(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
    }
}

/// Counts live connections against a cap. Thread-safe.
public final class BridgeConnectionLimiter: @unchecked Sendable {
    public let limit: Int
    private let lock = NSLock()
    private var _active = 0

    public init(limit: Int = BridgeConnectionPolicy.maxConcurrentConnections) {
        self.limit = limit
    }

    public var active: Int {
        lock.lock(); defer { lock.unlock() }
        return _active
    }

    /// Take a slot. False when the cap is reached — reject the connection.
    public func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _active < limit else { return false }
        _active += 1
        return true
    }

    /// Give a slot back (once per successful ``tryAcquire()``).
    public func release() {
        lock.lock(); defer { lock.unlock() }
        _active = max(0, _active - 1)
    }
}

/// Reads one Agent Bridge connection with bounded waits: the socket gets
/// SO_RCVTIMEO/SO_SNDTIMEO, and ``next()`` returns `.idleTimeout` or `.stopped`
/// instead of blocking forever on a peer that went quiet.
public final class BridgeConnectionReader {

    public enum Event: Equatable {
        case data(Data)
        /// EOF or a socket error: the peer is gone.
        case closed
        /// No traffic for the idle timeout.
        case idleTimeout
        /// The server is shutting down.
        case stopped
    }

    private let fd: Int32
    private let idleTimeout: TimeInterval
    private let isRunning: () -> Bool
    private var lastActivity = Date()
    private var chunk = [UInt8](repeating: 0, count: 16384)

    public init(
        fd: Int32,
        pollInterval: TimeInterval = BridgeConnectionPolicy.readPollSeconds,
        idleTimeout: TimeInterval = BridgeConnectionPolicy.idleTimeoutSeconds,
        writeTimeout: TimeInterval = BridgeConnectionPolicy.writeTimeoutSeconds,
        isRunning: @escaping () -> Bool
    ) {
        self.fd = fd
        self.idleTimeout = idleTimeout
        self.isRunning = isRunning
        BridgeConnectionPolicy.setTimeouts(fd: fd, read: pollInterval, write: writeTimeout)
    }

    /// Restart the idle clock. Call after finishing a request, so time spent
    /// running it (a long dictate) doesn't count as idle.
    public func markActive() { lastActivity = Date() }

    /// Block until bytes arrive, the peer closes, the connection idles out, or
    /// the server stops — never longer than the poll interval past the latter two.
    public func next() -> Event {
        while true {
            guard isRunning() else { return .stopped }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                lastActivity = Date()
                return .data(Data(chunk[0..<n]))
            }
            if n == 0 { return .closed }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK: // SO_RCVTIMEO tick
                switch BridgeConnectionPolicy.afterReadTimeout(
                    idleFor: Date().timeIntervalSince(lastActivity),
                    isRunning: isRunning(), idleTimeout: idleTimeout) {
                case .keepWaiting: continue
                case .closeIdle: return .idleTimeout
                case .closeStopped: return .stopped
                }
            default:
                return .closed
            }
        }
    }
}
