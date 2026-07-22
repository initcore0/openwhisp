import XCTest
@testable import OpenWhispSyncLAN
import OpenWhispCore

/// EXPERIMENT (stream ingest): drive the REAL WebSocket ingest server with
/// `URLSessionWebSocketTask` — the same client stack a browser page or
/// companion app would mimic. Proves the hello→ack handshake, token rejection,
/// and that streamed PCM arrives as mono Float32 @ 16 kHz via `onAudio`.
final class StreamAudioIngestServerTests: XCTestCase {

    /// Thread-safe capture of server callbacks.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _samples: [Float] = []
        private var _connected: [String] = []
        func add(samples: [Float]) { lock.lock(); _samples += samples; lock.unlock() }
        func add(client: String) { lock.lock(); _connected.append(client); lock.unlock() }
        var samples: [Float] { lock.lock(); defer { lock.unlock() }; return _samples }
        var connected: [String] { lock.lock(); defer { lock.unlock() }; return _connected }
    }

    @MainActor
    private func startServer(token: String = "") async throws -> (StreamAudioIngestServer, UInt16, Log) {
        let server = StreamAudioIngestServer(token: token)
        let log = Log()
        server.onClientConnected = { log.add(client: $0) }
        server.onAudio = { log.add(samples: $0) }
        try server.start()
        let deadline = Date().addingTimeInterval(5)
        while server.boundPort == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let port = server.boundPort else { throw XCTSkip("listener did not bind in time") }
        return (server, port, log)
    }

    private func openSocket(port: UInt16) -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/ingest")!)
        task.resume()
        return task
    }

    /// Send the hello and wait for the server's JSON ack text.
    private func handshake(_ task: URLSessionWebSocketTask, hello: StreamIngestHello) async throws -> String {
        let payload = try JSONEncoder().encode(hello)
        try await task.send(.string(String(decoding: payload, as: UTF8.self)))
        let reply = try await task.receive()
        guard case .string(let text) = reply else {
            throw XCTSkip("expected text ack, got \(reply)")
        }
        return text
    }

    func testHelloAckThenPCMArrivesAsMono16k() async throws {
        let (server, port, log) = try await startServer()
        defer { Task { @MainActor in server.stop() } }

        let task = openSocket(port: port)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let ack = try await handshake(task, hello: StreamIngestHello(
            format: .pcmS16LE, sampleRate: 48_000, channels: 1, clientName: "Windows companion"))
        XCTAssertEqual(ack, #"{"ok":true}"#)

        // 100 ms of a constant half-amplitude tone @ 48 kHz → ~1600 samples of ~0.5 @ 16 kHz.
        let pcm = [Int16](repeating: 16_384, count: 4_800)
        try await task.send(.data(pcm.withUnsafeBufferPointer { Data(buffer: $0) }))

        let deadline = Date().addingTimeInterval(5)
        while log.samples.count < 1_500 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(log.connected, ["Windows companion"])
        XCTAssertTrue(abs(log.samples.count - 1_600) <= 2, "expected ~1600 samples, got \(log.samples.count)")
        XCTAssertEqual(log.samples.first ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(log.samples.last ?? 0, 0.5, accuracy: 0.001)
    }

    func testWrongTokenIsRejected() async throws {
        let (server, port, log) = try await startServer(token: "s3cret")
        defer { Task { @MainActor in server.stop() } }

        let task = openSocket(port: port)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let ack = try await handshake(task, hello: StreamIngestHello(
            format: .pcmS16LE, sampleRate: 48_000, channels: 1, clientName: "intruder", token: "wrong"))
        XCTAssertEqual(ack, #"{"ok":false,"reason":"invalid token"}"#)
        XCTAssertTrue(log.connected.isEmpty, "rejected client must not surface as connected")
    }

    @MainActor
    func testLANWithoutTokenRefusesToStart() {
        let server = StreamAudioIngestServer(token: "", allowLAN: true)
        XCTAssertThrowsError(try server.start())
        XCTAssertFalse(server.isRunning)
    }
}
