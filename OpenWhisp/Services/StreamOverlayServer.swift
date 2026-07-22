import Foundation
import Network
import os
// Same-module in the mac app glob; a separate module (imports core) in the
// SwiftPM targets. See AgentBridgeHost.swift for the guard rationale.
#if canImport(OpenWhispCore)
import OpenWhispCore
#endif

// App/SwiftPM-target only (NOT in OpenWhispCore): it uses Network.framework.
// The pure pieces — config sanitizing, the caption reducer, SSE framing, the
// HTML page — live in core (StreamOverlay.swift) and are unit-tested there.

/// EXPERIMENT (do not ship): a loopback HTTP server that serves a live-subtitle
/// overlay page for Twitch/OBS browser sources.
///
/// `GET /` returns a self-contained HTML page styled from `StreamOverlayConfig`
/// (canvas size, font, background/text color); `GET /events` is a server-sent-
/// events stream of caption snapshots the page renders.
///
/// **Engine/model neutrality is the design constraint:** this type never names a
/// transcription engine or an LLM. Callers push text in via `publishPartial`/
/// `publishFinal` — wire those to whatever produces text (any
/// `StreamingTranscriptionEngine`'s callbacks, a test, a script). Translation is
/// an injected async closure; when nil (or when the config disables it), finals
/// pass through untouched.
@MainActor
final class StreamOverlayServer {

    /// Translates a finalized line into `targetLanguage`. Returning nil (or
    /// throwing behavior isn't modeled — just return nil) falls back to the
    /// original text, so a flaky translator degrades to untranslated captions.
    typealias Translator = @Sendable (_ text: String, _ targetLanguage: String) async -> String?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenWhisp", category: "StreamOverlay")
    private let config: StreamOverlayConfig
    private let translator: Translator?
    private var captions: StreamOverlayCaptions

    private var listener: NWListener?
    /// The port the listener actually bound. Nil until started.
    private(set) var boundPort: UInt16?

    /// Transport queue for all Network.framework callbacks.
    private let queue = DispatchQueue(label: "app.openwhisp.streamoverlay")
    /// Live connections, retained until closed (same rationale as LANBridgeServer).
    /// Only touched on `queue`.
    private nonisolated(unsafe) var connections: [ObjectIdentifier: OverlayConnection] = [:]

    /// Cap on concurrent connections — one OBS source plus a preview tab is the
    /// real workload; the cap keeps a runaway client from accumulating sockets.
    private nonisolated static let maxConcurrentConnections = 16

    /// Serializes translate→commit for finals so out-of-order translator
    /// completions can't reorder caption lines.
    private var finalChain: Task<Void, Never>?

    init(config: StreamOverlayConfig, translator: Translator? = nil) {
        let sanitized = config.sanitized()
        self.config = sanitized
        self.translator = translator
        self.captions = StreamOverlayCaptions(maxLines: sanitized.maxLines)
    }

    var isRunning: Bool { listener != nil }

    // MARK: - Lifecycle

    /// Start on 127.0.0.1 (loopback ONLY — the overlay is for OBS on the same
    /// machine; nothing is exposed on the LAN). Port 0 → OS-assigned.
    func start(port: UInt16 = 0) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let bound = listener.port?.rawValue {
                    Task { @MainActor in self.boundPort = bound }
                }
            case .failed(let err):
                self.log.error("stream overlay listener failed: \(String(describing: err), privacy: .public)")
                Task { @MainActor in self.stop() }
            default:
                break
            }
        }
        let html = StreamOverlayPage.html(config: config)
        let queue = self.queue
        let log = self.log
        listener.newConnectionHandler = { [weak self] conn in
            guard let self, self.connections.count < Self.maxConcurrentConnections else {
                conn.cancel()
                return
            }
            let session = OverlayConnection(
                connection: conn, queue: queue, log: log, html: html,
                initialSnapshot: { [weak self] in
                    // Read on main so the SSE greeting matches the latest commit.
                    guard let self else { return nil }
                    return self.onMain { self.captions.snapshot }
                },
                onClosed: { [weak self] closed in
                    self?.connections.removeValue(forKey: ObjectIdentifier(closed))
                })
            self.connections[ObjectIdentifier(session)] = session
            session.start()
        }
        listener.start(queue: queue)
        self.listener = listener
        log.info("stream overlay listening (loopback)")
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

    // MARK: - Publishing captions (the engine-agnostic input seam)

    /// Publish an interim hypothesis. Broadcast immediately; partials are never
    /// translated (they change too fast to be worth a round trip).
    func publishPartial(_ text: String) {
        broadcast(captions.setPartial(text))
    }

    /// Publish a finalized line. Runs through the injected translator first when
    /// the config enables translation; commits in publish order regardless of
    /// how long each translation takes.
    func publishFinal(_ text: String) {
        guard config.translationEnabled, let translator, !config.targetLanguage.isEmpty else {
            broadcast(captions.commitFinal(text))
            return
        }
        let language = config.targetLanguage
        let previous = finalChain
        finalChain = Task { @MainActor [weak self] in
            await previous?.value
            let translated = await translator(text, language) ?? text
            guard let self else { return }
            self.broadcast(self.captions.commitFinal(translated))
        }
    }

    /// Clear the overlay (dictation session ended).
    func publishClear() {
        broadcast(captions.clear())
    }

    private func broadcast(_ snapshot: StreamOverlayCaptions.Snapshot) {
        let frame = StreamOverlaySSE.frame(snapshot)
        queue.async { [weak self] in
            guard let self else { return }
            for (_, conn) in self.connections { conn.sendEvent(frame) }
        }
    }

    /// Synchronous main-thread hop for the transport queue (never called from
    /// main, so the wait can't self-deadlock).
    private nonisolated func onMain<T>(_ body: @escaping @MainActor () -> T) -> T {
        var result: T!
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { MainActor.assumeIsolated { result = body() }; sem.signal() }
        sem.wait()
        return result
    }
}

/// One accepted HTTP connection: reads a single request head, answers it, and
/// either closes (page/health) or stays open streaming SSE frames (/events).
/// The tiny hand-rolled HTTP parser is deliberate — this is a loopback,
/// GET-only, no-body server for a local OBS source, not a general web server.
private final class OverlayConnection {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let log: Logger
    private let html: String
    private let initialSnapshot: () -> StreamOverlayCaptions.Snapshot?
    private let onClosed: (OverlayConnection) -> Void
    private var closedFired = false

    private var buffer = Data()
    /// True once this connection upgraded to the SSE stream.
    private var streaming = false

    /// A request head larger than this is hostile for a GET-only server.
    private static let maxHeadBytes = 16 * 1024

    init(
        connection: NWConnection, queue: DispatchQueue, log: Logger, html: String,
        initialSnapshot: @escaping () -> StreamOverlayCaptions.Snapshot?,
        onClosed: @escaping (OverlayConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.log = log
        self.html = html
        self.initialSnapshot = initialSnapshot
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
    }

    private func close() {
        connection.cancel()
        guard !closedFired else { return }
        closedFired = true
        onClosed(self)
    }

    /// Server-initiated teardown; suppresses onClosed (the caller is clearing the
    /// map). Must be called on the transport queue.
    func forceClose() {
        closedFired = true
        connection.cancel()
    }

    /// Push one already-framed SSE event to a streaming client. No-op for
    /// connections still reading their request. Called on the transport queue.
    func sendEvent(_ frame: String) {
        guard streaming else { return }
        connection.send(content: Data(frame.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let headEnd = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.route(head: self.buffer[..<headEnd.lowerBound])
                    return
                }
                if self.buffer.count > Self.maxHeadBytes {
                    self.close()
                    return
                }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func route(head: Data) {
        guard let requestLine = String(data: head, encoding: .utf8)?
            .split(separator: "\r\n", maxSplits: 1).first else {
            close()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(status: "405 Method Not Allowed", contentType: "text/plain", body: "GET only\n")
            return
        }
        let path = parts[1].split(separator: "?").first.map(String.init) ?? "/"
        switch path {
        case "/":
            respond(status: "200 OK", contentType: "text/html; charset=utf-8", body: html)
        case "/healthz":
            respond(status: "200 OK", contentType: "text/plain", body: "ok\n")
        case "/events":
            beginEventStream()
        default:
            respond(status: "404 Not Found", contentType: "text/plain", body: "not found\n")
        }
    }

    private func respond(status: String, contentType: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        connection.send(content: out, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func beginEventStream() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        streaming = true
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.close(); return }
            // Greet the client with the current state so a source added
            // mid-session shows the captions already on screen.
            if let snap = self.initialSnapshot() {
                self.connection.send(
                    content: Data(StreamOverlaySSE.frame(snap).utf8),
                    completion: .contentProcessed { _ in })
            }
        })
    }
}
