import Foundation
import Network
import os
// Same-module in the mac app glob; a separate module (imports core) in the
// SwiftPM targets. See AgentBridgeHost.swift for the guard rationale.
#if canImport(OpenWhispCore)
import OpenWhispCore
#endif

// App/SwiftPM-target only (NOT in OpenWhispCore): it uses Network.framework's
// native WebSocket stack. The protocol rules (hello validation, token auth,
// PCM→mono-16k conversion) live in core (StreamIngest.swift) and are tested.

/// EXPERIMENT (do not ship): WebSocket audio-ingest server — a remote client
/// (browser page, Windows companion, OBS plugin) streams its microphone as PCM
/// and this Mac transcribes locally.
///
/// Wire contract (see StreamIngestHello): the client connects, sends ONE text
/// message (the JSON hello: format/sampleRate/channels/clientName/token), and
/// receives a JSON ack `{"ok":true}` — or `{"ok":false,"reason":…}` followed by
/// close. Every subsequent binary message is interleaved PCM, which the server
/// converts to canonical mono Float32 @ 16 kHz and hands to `onAudio`.
///
/// **Engine/model neutrality:** audio leaves through the `onAudio` callback —
/// wire it to any transcription seam (or a file, or a test). Nothing here names
/// an engine or an LLM.
///
/// **Exposure:** loopback by default. `allowLAN: true` binds all interfaces and
/// REQUIRES a non-empty token (start throws otherwise) — a LAN-audible mic feed
/// must never be an unauthenticated endpoint.
@MainActor
final class StreamAudioIngestServer {

    struct IngestError: Error, CustomStringConvertible { let description: String }

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenWhisp", category: "StreamIngest")
    private let token: String
    private let allowLAN: Bool

    /// A client passed the hello (name from its hello). Main actor.
    var onClientConnected: ((String) -> Void)?
    /// Mono Float32 @ 16 kHz audio from the active client. Main actor.
    var onAudio: (([Float]) -> Void)?
    /// The streaming client went away. Main actor.
    var onClientDisconnected: ((String) -> Void)?

    private var listener: NWListener?
    private(set) var boundPort: UInt16?

    private let queue = DispatchQueue(label: "app.openwhisp.streamingest")
    /// Live connections, retained until closed; only touched on `queue`.
    private nonisolated(unsafe) var connections: [ObjectIdentifier: IngestConnection] = [:]

    /// One real feed plus a few strays; audio from every authed client is merged
    /// onto `onAudio`, so one-at-a-time discipline is the operator's concern (the
    /// experiment doesn't mix).
    private nonisolated static let maxConcurrentConnections = 4

    init(token: String = "", allowLAN: Bool = false) {
        self.token = token
        self.allowLAN = allowLAN
    }

    var isRunning: Bool { listener != nil }

    // MARK: - Lifecycle

    func start(port: UInt16 = 0) throws {
        guard listener == nil else { return }
        if allowLAN && token.isEmpty {
            throw IngestError(description: "LAN ingest requires a token — refusing to expose an open mic endpoint")
        }
        let params = NWParameters.tcp
        if !allowLAN {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        } else if let fixed = NWEndpoint.Port(rawValue: port), port != 0 {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: fixed)
        }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let bound = listener.port?.rawValue {
                    Task { @MainActor in self.boundPort = bound }
                }
            case .failed(let err):
                self.log.error("ingest listener failed: \(String(describing: err), privacy: .public)")
                Task { @MainActor in self.stop() }
            default:
                break
            }
        }
        let queue = self.queue
        let log = self.log
        let requiredToken = token
        listener.newConnectionHandler = { [weak self] conn in
            guard let self, self.connections.count < Self.maxConcurrentConnections else {
                conn.cancel()
                return
            }
            let session = IngestConnection(
                connection: conn, queue: queue, log: log, requiredToken: requiredToken,
                onConnected: { [weak self] name in
                    Task { @MainActor in self?.onClientConnected?(name) }
                },
                onAudio: { [weak self] samples in
                    Task { @MainActor in self?.onAudio?(samples) }
                },
                onClosed: { [weak self] closed, name in
                    self?.connections.removeValue(forKey: ObjectIdentifier(closed))
                    if let name {
                        Task { @MainActor in self?.onClientDisconnected?(name) }
                    }
                })
            self.connections[ObjectIdentifier(session)] = session
            session.start()
        }
        listener.start(queue: queue)
        self.listener = listener
        log.info("audio ingest listening (\(self.allowLAN ? "LAN" : "loopback", privacy: .public))")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        queue.async { [weak self] in
            guard let self else { return }
            for (_, conn) in self.connections { conn.forceClose() }
            self.connections.removeAll()
        }
    }
}

/// One WebSocket ingest session: text hello → ack (or reject+close) → binary
/// PCM frames through the converter. All state is confined to the transport queue.
private final class IngestConnection {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let log: Logger
    private let requiredToken: String
    private let onConnected: (String) -> Void
    private let onAudio: ([Float]) -> Void
    private let onClosed: (IngestConnection, String?) -> Void
    private var closedFired = false

    /// Set once the hello is accepted.
    private var converter: StreamIngestAudioConverter?
    private var clientName: String?

    /// A client that hasn't completed its hello within this window is dropped.
    private static let helloTimeout: TimeInterval = 10

    init(
        connection: NWConnection, queue: DispatchQueue, log: Logger, requiredToken: String,
        onConnected: @escaping (String) -> Void,
        onAudio: @escaping ([Float]) -> Void,
        onClosed: @escaping (IngestConnection, String?) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.log = log
        self.requiredToken = requiredToken
        self.onConnected = onConnected
        self.onAudio = onAudio
        self.onClosed = onClosed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive()
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in
            guard let self, self.converter == nil else { return }
            self.log.notice("ingest: hello timeout; closing")
            self.close()
        }
    }

    private func close() {
        connection.cancel()
        guard !closedFired else { return }
        closedFired = true
        onClosed(self, clientName)
    }

    /// Server-initiated teardown; suppresses onClosed. Transport queue only.
    func forceClose() {
        closedFired = true
        connection.cancel()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, let context {
                let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                switch meta?.opcode {
                case .text:
                    self.handleHello(data)
                case .binary:
                    if var converter = self.converter {
                        let samples = converter.consume(data)
                        self.converter = converter
                        if !samples.isEmpty { self.onAudio(samples) }
                    }
                case .close:
                    self.close()
                    return
                default:
                    break
                }
            }
            if error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func handleHello(_ data: Data) {
        guard converter == nil else { return }  // hello is once
        guard let hello = try? JSONDecoder().decode(StreamIngestHello.self, from: data) else {
            reject(reason: "malformed hello")
            return
        }
        switch StreamIngestHandshake.evaluate(hello, requiredToken: requiredToken) {
        case .rejected(let reason):
            log.notice("ingest: hello rejected — \(reason, privacy: .public)")
            reject(reason: reason)
        case .accepted:
            converter = StreamIngestAudioConverter(hello: hello)
            clientName = hello.clientName
            sendText(#"{"ok":true}"#)
            log.info("ingest: client connected (\(hello.sampleRate, privacy: .public) Hz x\(hello.channels, privacy: .public))")
            onConnected(hello.clientName)
        }
    }

    private func reject(reason: String) {
        let escaped = reason.replacingOccurrences(of: "\"", with: "'")
        sendText(#"{"ok":false,"reason":"\#(escaped)"}"#) { [weak self] in self?.close() }
    }

    private func sendText(_ text: String, then completion: (() -> Void)? = nil) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(
            content: Data(text.utf8), contentContext: context,
            completion: .contentProcessed { _ in completion?() })
    }
}
