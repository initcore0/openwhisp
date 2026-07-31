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
    /// Mutable so appearance edits can be applied LIVE (`applyLook`) instead of
    /// restarting the listener — a restart tears down the capture session the
    /// streamer is in the middle of.
    private var config: StreamOverlayConfig
    private let translator: Translator?
    private var captions: StreamOverlayCaptions

    private var listener: NWListener?
    /// The port the listener actually bound. Nil until started.
    private(set) var boundPort: UInt16?
    /// Fired (main actor) if the listener dies AFTER a successful start() —
    /// e.g. the port was grabbed between checks. Lets the owner reflect the
    /// real state instead of showing a server that silently went away.
    var onFailure: ((String) -> Void)?

    /// Transport queue for all Network.framework callbacks.
    private let queue = DispatchQueue(label: "app.openwhisp.streamoverlay")
    /// Live connections, retained until closed (same rationale as LANBridgeServer).
    /// Only touched on `queue`.
    private nonisolated(unsafe) var connections: [ObjectIdentifier: OverlayConnection] = [:]
    /// The most recent SSE frame, cached ON THE TRANSPORT QUEUE so a newly
    /// connected client can be greeted without hopping to the main actor. A
    /// synchronous main-thread wait here (the first design) froze EVERY overlay
    /// response whenever the main thread was busy (modal dialog, long task) —
    /// the transport queue is shared by all connections. Only touched on `queue`.
    private nonisolated(unsafe) var latestFrame: String = ""
    /// The page HTML served by `GET /`, cached on the transport queue for the
    /// same reason as `latestFrame`. Re-rendered on `applyLook` so a browser
    /// source reloaded after an appearance edit gets the current style baked in
    /// (live clients get it sooner, via the `style` event). Only touched on `queue`.
    private nonisolated(unsafe) var pageHTML: String = ""

    /// Cap on concurrent connections — one OBS source plus a preview tab is the
    /// real workload; the cap keeps a runaway client from accumulating sockets.
    private nonisolated static let maxConcurrentConnections = 16

    /// Serializes translate→commit for finals so out-of-order translator
    /// completions can't reorder caption lines.
    private var finalChain: Task<Void, Never>?
    /// Movie-subtitle auto-hide: rearmed on every publish; fires after
    /// `lingerSeconds` without new speech and clears the overlay.
    private var lingerTimer: Timer?
    /// The last session transcript handed to the reducer. The linger timeout
    /// retires exactly this much, so speech that resumes after the pause shows
    /// only the NEW words instead of replaying the utterance that just faded.
    private var lastPublishedTranscript: String = ""

    /// The voice-command counter's value. STATE, not config: the owner injects
    /// the restored value at init and is told about every change through
    /// `onCounterChanged` so it can persist across app restarts. A config edit
    /// (relabel, move corner) must never reset it.
    private(set) var counterCount: Int
    /// Fired (main actor) whenever `counterCount` changes, so the owner can
    /// persist the new value and show it live in settings.
    var onCounterChanged: ((Int) -> Void)?
    /// The most recent counter SSE frame, cached on the transport queue for the
    /// same reason as `latestFrame` — a client connecting mid-stream must be
    /// greeted with the CURRENT count, not a blank widget. Only touched on `queue`.
    private nonisolated(unsafe) var latestCounterFrame: String = ""

    init(config: StreamOverlayConfig, translator: Translator? = nil, counterCount: Int = 0) {
        let sanitized = config.sanitized()
        self.config = sanitized
        self.translator = translator
        self.counterCount = max(0, counterCount)
        self.captions = StreamOverlayCaptions(
            maxLines: sanitized.maxLines, charsPerLine: sanitized.charsPerLine)
    }

    /// The counter state as the page should render it right now.
    private var counterState: StreamOverlayCounterState {
        StreamOverlayCounterState(
            label: config.counterLabel, count: counterCount,
            corner: config.counterCorner, visible: config.counterEnabled)
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
                Task { @MainActor in
                    self.stop()
                    self.onFailure?(String(describing: err))
                }
            default:
                break
            }
        }
        let html = StreamOverlayPage.html(config: config)
        queue.async { [weak self] in self?.pageHTML = html }
        let queue = self.queue
        let log = self.log
        listener.newConnectionHandler = { [weak self] conn in
            guard let self, self.connections.count < Self.maxConcurrentConnections else {
                conn.cancel()
                return
            }
            let session = OverlayConnection(
                connection: conn, queue: queue, log: log,
                // Read at request time (on `queue`) so a page loaded after an
                // appearance edit is served the CURRENT look, not the look
                // frozen at listener start.
                html: { [weak self] in self?.pageHTML ?? html },
                // Runs on `queue`: greet from the queue-cached frames, never by
                // waiting on the main actor (see `latestFrame`). Both the
                // captions and the counter are seeded, so a browser source added
                // (or reconnected) mid-stream shows the running count instead of
                // waiting for the next increment.
                initialFrames: { [weak self] in
                    guard let self else { return [] }
                    return [self.latestFrame, self.latestCounterFrame].filter { !$0.isEmpty }
                },
                onClosed: { [weak self] closed in
                    self?.connections.removeValue(forKey: ObjectIdentifier(closed))
                })
            self.connections[ObjectIdentifier(session)] = session
            session.start()
        }
        // Seed the greeting cache with the current caption state so a client
        // connecting before any publish still gets a coherent (empty) snapshot.
        // Same for the counter: its persisted value must show on a page loaded
        // before anything is said.
        let seed = StreamOverlaySSE.frame(captions.snapshot)
        let counterSeed = StreamOverlaySSE.counterFrame(counterState)
        queue.async { [weak self] in
            self?.latestFrame = seed
            self?.latestCounterFrame = counterSeed
        }
        listener.start(queue: queue)
        self.listener = listener
        log.info("stream overlay listening (loopback)")
    }

    func stop() {
        lingerTimer?.invalidate()
        lingerTimer = nil
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

    /// Publish an interim hypothesis: show the trailing subtitle window of the
    /// current utterance. Partials are never translated (they change too fast
    /// to be worth a round trip). An empty partial (session reset) hides the
    /// captions immediately.
    func publishPartial(_ text: String) {
        // Counter-only mode: nothing about the caption pipeline runs (no
        // reducer churn, no linger timer, no SSE frames). Partials carry no
        // voice-command work either — detection is finals-only, see publishFinal.
        guard config.captionsEnabled else { return }
        lastPublishedTranscript = text
        broadcast(captions.setText(text))
    }

    /// Publish the finalized utterance. Two independent things happen here:
    ///
    ///  1. **Voice commands** are detected on the ORIGINAL (pre-translation)
    ///     text, synchronously, before any translation round trip. Detection is
    ///     FINALS-ONLY on purpose: a streaming engine's partials grow and get
    ///     revised ("I di" → "I died" → "I died again"), so counting them would
    ///     fire several times for one spoken phrase. The tradeoff is latency —
    ///     the counter ticks when the utterance finalizes, not the instant the
    ///     words are said. Matching the SOURCE text (not the translation) is
    ///     what lets a Russian streamer trigger on a Russian phrase while the
    ///     captions go out in English.
    ///  2. **Captions** are updated (unless captions are switched off), through
    ///     the translator when configured.
    func publishFinal(_ text: String) {
        detectVoiceCommands(in: text)

        guard config.captionsEnabled else { return }
        guard config.translationEnabled, let translator, !config.targetLanguage.isEmpty else {
            lastPublishedTranscript = text
            broadcast(captions.setText(text))
            return
        }
        let language = config.targetLanguage
        let previous = finalChain
        finalChain = Task { @MainActor [weak self] in
            await previous?.value
            let translated = await translator(text, language) ?? text
            guard let self else { return }
            // Retirement compares against what the reducer was fed, which on the
            // translated path is the TRANSLATION, not the source transcript.
            self.lastPublishedTranscript = translated
            self.broadcast(self.captions.setText(translated))
        }
    }

    /// Clear the overlay now (capture stopped). Resets retirement too — the next
    /// session's first words are new speech, not a continuation.
    func publishClear() {
        lastPublishedTranscript = ""
        // Even with captions off the reducer is reset, so re-enabling them
        // mid-stream never resurrects a previous session's retirement mark.
        let snapshot = captions.clear()
        guard config.captionsEnabled else { return }
        broadcast(snapshot)
    }

    // MARK: - Voice commands (phrase → counter widget)

    /// Count the configured trigger phrase in one finalized utterance and, if it
    /// fired, bump the counter and push the new state to every live page.
    ///
    /// A phrase said TWICE in one final increments by two — the streamer said it
    /// twice, and dropping the second would be a silent miscount.
    private func detectVoiceCommands(in text: String) {
        guard config.counterEnabled else { return }
        let hits = OverlayVoiceCommandMatcher.occurrences(of: config.counterPhrase, in: text)
        guard hits > 0 else { return }
        setCounter(counterCount + hits)
    }

    /// Reset the counter to zero (the settings pane's Reset button).
    func resetCounter() {
        guard counterCount != 0 else { return }
        setCounter(0)
    }

    /// Set the counter and broadcast it. Single funnel so persistence
    /// (`onCounterChanged`) and the wire can never drift apart.
    private func setCounter(_ value: Int) {
        counterCount = max(0, value)
        onCounterChanged?(counterCount)
        broadcastCounter()
    }

    /// Push the current counter state to live pages and refresh the greeting
    /// cache so a client connecting next also sees it.
    private func broadcastCounter() {
        let frame = StreamOverlaySSE.counterFrame(counterState)
        queue.async { [weak self] in
            guard let self else { return }
            self.latestCounterFrame = frame
            for (_, conn) in self.connections { conn.sendEvent(frame) }
        }
    }

    // MARK: - Live appearance edits

    /// Apply an appearance change WITHOUT restarting the listener, so the
    /// streamer can tune font/size/colors/wrapping while captions are running.
    ///
    /// Restarting was the old behavior and it stopped the capture session
    /// (`stopServer` ends capture) — a font tweak silently killed the dictation.
    /// Here the CSS-level fields ride a `style` SSE event to every live page,
    /// and the wrap-level fields (`maxLines`/`charsPerLine`) are rebuilt into the
    /// reducer and re-broadcast so the change is visible on the CURRENT text
    /// rather than only on the next utterance.
    ///
    /// The port is not part of `StreamOverlayConfig` — it lives on the
    /// coordinator, whose `port.didSet` still does a full (debounced) restart,
    /// since the listener is bound to it.
    func applyLook(_ newConfig: StreamOverlayConfig) {
        let sanitized = newConfig.sanitized()
        guard sanitized != config else { return }
        let rewrapNeeded = sanitized.maxLines != config.maxLines
            || sanitized.charsPerLine != config.charsPerLine
        // The counter's rendered state is label + count + corner + visibility;
        // the count can't change here, so any of the other three means the live
        // pages need a fresh `counter` frame. (The corner also rides `style`,
        // but the counter frame is what un/hides the widget.)
        let counterWidgetChanged = sanitized.counterLabel != config.counterLabel
            || sanitized.counterCorner != config.counterCorner
            || sanitized.counterEnabled != config.counterEnabled
        // Switching captions OFF mid-stream must blank whatever is on screen —
        // the page hides the block, but a stale frame would flash back if
        // captions are re-enabled later.
        let captionsSwitchedOff = !sanitized.captionsEnabled && config.captionsEnabled
        config = sanitized

        // Re-render the page for future loads (OBS "refresh browser source").
        let html = StreamOverlayPage.html(config: sanitized)
        let styleFrame = StreamOverlaySSE.styleFrame(sanitized)
        queue.async { [weak self] in
            guard let self else { return }
            self.pageHTML = html
            for (_, conn) in self.connections { conn.sendEvent(styleFrame) }
        }

        if counterWidgetChanged { broadcastCounter() }

        if captionsSwitchedOff {
            // Clear the reducer AND the cached greeting frame directly (the
            // normal `broadcast` path is gated on captionsEnabled, which is
            // already false by now).
            lastPublishedTranscript = ""
            lingerTimer?.invalidate()
            lingerTimer = nil
            let cleared = StreamOverlaySSE.frame(captions.clear())
            queue.async { [weak self] in
                guard let self else { return }
                self.latestFrame = cleared
                for (_, conn) in self.connections { conn.sendEvent(cleared) }
            }
            return
        }

        guard rewrapNeeded, config.captionsEnabled else { return }
        // Rebuild the reducer at the new geometry, carrying the retirement mark
        // and revision so a rewrap can neither resurrect faded speech nor emit a
        // frame the page will discard as stale.
        let wasVisible = !captions.snapshot.lines.isEmpty
        captions = captions.resized(
            maxLines: sanitized.maxLines, charsPerLine: sanitized.charsPerLine)
        // Only re-show while captions are actually on screen; rewrapping during
        // the silent gap would flash the faded text back up.
        guard wasVisible else { return }
        broadcast(captions.setText(lastPublishedTranscript))
    }

    private func broadcast(_ snapshot: StreamOverlayCaptions.Snapshot) {
        // Movie-subtitle auto-hide: any visible captions (re)arm the silence
        // timer; when it fires with nothing new said, the overlay goes blank.
        // A clear (empty) frame doesn't rearm — it IS the hidden state.
        lingerTimer?.invalidate()
        lingerTimer = nil
        if !snapshot.lines.isEmpty {
            lingerTimer = Timer.scheduledTimer(
                withTimeInterval: TimeInterval(config.lingerSeconds), repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    // RETIRE, don't just clear: the engine's transcript keeps
                    // growing across the pause, so without marking this text as
                    // spent the next partial would replay the utterance that
                    // just faded out. Retiring makes resumed speech start clean.
                    self.broadcast(self.captions.retire(upTo: self.lastPublishedTranscript))
                }
            }
        }
        let frame = StreamOverlaySSE.frame(snapshot)
        queue.async { [weak self] in
            guard let self else { return }
            self.latestFrame = frame
            for (_, conn) in self.connections { conn.sendEvent(frame) }
        }
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
    /// Returns the page HTML to serve; called on the transport queue at request
    /// time so appearance edits reach newly loaded pages.
    private let html: () -> String
    /// Returns the cached SSE frames a newly connected client is greeted with
    /// (captions + counter); called on the transport queue.
    private let initialFrames: () -> [String]
    private let onClosed: (OverlayConnection) -> Void
    private var closedFired = false

    private var buffer = Data()
    /// True once this connection upgraded to the SSE stream.
    private var streaming = false

    /// A request head larger than this is hostile for a GET-only server.
    private static let maxHeadBytes = 16 * 1024

    init(
        connection: NWConnection, queue: DispatchQueue, log: Logger,
        html: @escaping () -> String,
        initialFrames: @escaping () -> [String],
        onClosed: @escaping (OverlayConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.log = log
        self.html = html
        self.initialFrames = initialFrames
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
            respond(status: "200 OK", contentType: "text/html; charset=utf-8", body: html())
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
            // mid-session shows the captions already on screen and the running
            // counter value. Reads the queue-cached frames — never blocks on the
            // main actor.
            let greeting = self.initialFrames().joined()
            if !greeting.isEmpty {
                self.connection.send(
                    content: Data(greeting.utf8),
                    completion: .contentProcessed { _ in })
            }
        })
    }
}
