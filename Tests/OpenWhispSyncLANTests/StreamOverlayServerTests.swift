import XCTest
import Network
@testable import OpenWhispSyncLAN
import OpenWhispCore

/// EXPERIMENT (stream overlay): drive the REAL loopback HTTP/SSE server — page
/// fetch, health, the SSE greeting, live caption broadcast, and the injected
/// (engine/model-free) translator hook. The pure caption/config/HTML logic is
/// covered in Tests/OpenWhispCoreTests/StreamOverlayTests.swift.
final class StreamOverlayServerTests: XCTestCase {

    /// A minimal raw-TCP HTTP client: sends one request and accumulates whatever
    /// the server writes (so it can observe an SSE stream that never closes).
    private final class RawClient: @unchecked Sendable {
        private let connection: NWConnection
        private let lock = NSLock()
        private var buffer = Data()

        init(port: UInt16) {
            connection = NWConnection(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: DispatchQueue(label: "overlay-test-client"))
            pump()
        }

        private func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data {
                    self.lock.lock()
                    self.buffer.append(data)
                    self.lock.unlock()
                }
                if isComplete || error != nil { return }
                self.pump()
            }
        }

        func send(_ request: String) {
            connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        }

        var received: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self)
        }

        /// Poll until `predicate` matches the accumulated bytes (or time out).
        func wait(timeout: TimeInterval = 5, for predicate: @escaping (String) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if predicate(received) { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return predicate(received)
        }

        func close() { connection.cancel() }
    }

    @MainActor
    private func startServer(
        config: StreamOverlayConfig = StreamOverlayConfig(),
        translator: StreamOverlayServer.Translator? = nil
    ) throws -> (StreamOverlayServer, UInt16) {
        let server = StreamOverlayServer(config: config, translator: translator)
        try server.start()
        let deadline = Date().addingTimeInterval(5)
        while server.boundPort == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard let port = server.boundPort else { throw XCTSkip("listener did not bind in time") }
        return (server, port)
    }

    @MainActor
    func testServesOverlayPageWithConfiguredDisplay() throws {
        let config = StreamOverlayConfig(
            canvasWidth: 1280, canvasHeight: 720, fontSize: 64, textColor: "#FFEE00")
        let (server, port) = try startServer(config: config)
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("</html>") }, "page never arrived: \(client.received.prefix(200))")
        let page = client.received
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(page.contains("width: 1280px"))
        XCTAssertTrue(page.contains("color: #FFEE00"))
    }

    @MainActor
    func testHealthAndNotFound() throws {
        let (server, port) = try startServer()
        defer { server.stop() }

        let health = RawClient(port: port)
        defer { health.close() }
        health.send("GET /healthz HTTP/1.1\r\n\r\n")
        XCTAssertTrue(health.wait { $0.contains("ok") && $0.hasPrefix("HTTP/1.1 200") })

        let missing = RawClient(port: port)
        defer { missing.close() }
        missing.send("GET /nope HTTP/1.1\r\n\r\n")
        XCTAssertTrue(missing.wait { $0.hasPrefix("HTTP/1.1 404") })
    }

    @MainActor
    func testSSEStreamsGreetingThenLiveCaptions() throws {
        let (server, port) = try startServer()
        defer { server.stop() }

        // Captions published before the client connects arrive in the greeting.
        server.publishFinal("hello twitch")

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(
            client.wait { $0.contains("text/event-stream") && $0.contains("hello twitch") },
            "greeting snapshot missing: \(client.received.prefix(300))")

        // Live partial + final broadcast to the open stream. Movie-subtitle
        // semantics: the current utterance REPLACES what's shown.
        server.publishPartial("second li")
        XCTAssertTrue(client.wait { $0.contains("second li") })
        server.publishFinal("second line")
        XCTAssertTrue(client.wait { $0.contains("\"lines\":[\"second line\"]") },
                      "final not broadcast: \(client.received.suffix(300))")
    }

    @MainActor
    func testCaptionsWindowAndAutoHideAfterSilence() throws {
        var config = StreamOverlayConfig()
        config.maxLines = 2
        config.charsPerLine = 16
        config.lingerSeconds = 1
        let (server, port) = try startServer(config: config)
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("text/event-stream") })

        // A long utterance wraps to 16-char lines and only the LAST TWO show.
        server.publishPartial("subtitles behave like in the movies now")
        XCTAssertTrue(client.wait { $0.contains("\"lines\":[\"like in the\",\"movies now\"]") },
                      "windowed frame missing: \(client.received.suffix(400))")

        // After lingerSeconds of silence the overlay hides itself. Matched by
        // revision: the seed greeting is an empty frame too, so a bare
        // `"lines":[]` would pass before the linger timer ever fired.
        XCTAssertTrue(client.wait(timeout: 5) { $0.contains("\"lines\":[],\"revision\":2") },
                      "auto-hide frame missing: \(client.received.suffix(400))")
    }

    /// The reported bug, end to end: after the silence auto-hide, resuming speech
    /// re-showed the utterance that had just faded. The engine keeps growing the
    /// same session transcript, so the auto-hide must RETIRE it, not just blank
    /// the screen.
    @MainActor
    func testResumingAfterAutoHideShowsOnlyTheNewWords() throws {
        var config = StreamOverlayConfig()
        config.lingerSeconds = 1
        let (server, port) = try startServer(config: config)
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("text/event-stream") })

        server.publishPartial("hello there friends")
        XCTAssertTrue(client.wait { $0.contains("\"lines\":[\"hello there friends\"]") })
        // Silence: the overlay hides AND retires what was on screen. Match the
        // auto-hide by its REVISION — the seed greeting is also an empty frame,
        // and matching that would race ahead of the linger timer.
        XCTAssertTrue(client.wait(timeout: 5) { $0.contains("\"lines\":[],\"revision\":2") },
                      "auto-hide frame missing: \(client.received.suffix(400))")

        // Speech resumes — the engine's transcript still carries the old words.
        server.publishPartial("hello there friends welcome back")
        XCTAssertTrue(client.wait { $0.contains("\"lines\":[\"welcome back\"]") },
                      "resumed speech should show ONLY new words, got: \(client.received.suffix(400))")
        XCTAssertFalse(
            client.received.contains("\"lines\":[\"hello there friends welcome back\"]"),
            "the faded utterance must never be replayed")
    }

    /// The second reported bug: editing the appearance restarted the server,
    /// which stopped the capture session. Appearance now applies LIVE — the
    /// listener keeps running (same bound port, same SSE connection) and the
    /// page receives a `style` event.
    @MainActor
    func testApplyLookRestylesLiveWithoutRestartingTheServer() throws {
        let (server, port) = try startServer(
            config: StreamOverlayConfig(fontSize: 48, textColor: "#FFFFFF"))
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("text/event-stream") })
        server.publishPartial("captions running")
        XCTAssertTrue(client.wait { $0.contains("captions running") })

        var edited = StreamOverlayConfig()
        edited.fontSize = 96
        edited.textColor = "#FF0000"
        server.applyLook(edited)

        // The SAME connection receives the restyle — no restart, no dropped client.
        XCTAssertTrue(client.wait { $0.contains("event: style") && $0.contains("\"fontSize\":96") },
                      "style event missing: \(client.received.suffix(400))")
        XCTAssertEqual(server.boundPort, port, "the listener must not be rebound")
        XCTAssertTrue(server.isRunning)

        // A page loaded AFTER the edit gets the new look baked in.
        let fresh = RawClient(port: port)
        defer { fresh.close() }
        fresh.send("GET / HTTP/1.1\r\n\r\n")
        XCTAssertTrue(fresh.wait { $0.contains("</html>") })
        XCTAssertTrue(fresh.received.contains("font-size: 96px"),
                      "re-rendered page should carry the edited look")
        XCTAssertTrue(fresh.received.contains("color: #FF0000"))
    }

    /// A live wrap edit re-shows the CURRENT text at the new geometry (so the
    /// streamer sees the effect immediately) without resurrecting retired speech.
    @MainActor
    func testApplyLookRewrapsTheTextOnScreen() throws {
        var config = StreamOverlayConfig()
        config.maxLines = 3
        config.charsPerLine = 40
        config.lingerSeconds = 30      // keep it on screen for the whole test
        let (server, port) = try startServer(config: config)
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("text/event-stream") })

        server.publishPartial("subtitles behave like in the movies now")
        XCTAssertTrue(client.wait { $0.contains("subtitles behave like in the movies") })

        var edited = config
        edited.maxLines = 2
        edited.charsPerLine = 16
        server.applyLook(edited)

        XCTAssertTrue(client.wait { $0.contains("\"lines\":[\"like in the\",\"movies now\"]") },
                      "rewrapped frame missing: \(client.received.suffix(400))")
    }

    @MainActor
    func testInjectedTranslatorRewritesFinalsOnly() throws {
        // The translator is a plain closure — no engine, no model — proving the
        // seam works without either being involved.
        let config = StreamOverlayConfig(translationEnabled: true, targetLanguage: "es")
        let (server, port) = try startServer(config: config, translator: { text, lang in
            "[\(lang)] \(text)"
        })
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("text/event-stream") })

        server.publishPartial("hola in prog")
        XCTAssertTrue(client.wait { $0.contains("hola in prog") }, "partials pass through untranslated")
        server.publishFinal("good morning")
        XCTAssertTrue(client.wait { $0.contains("[es] good morning") },
                      "translated final missing: \(client.received.suffix(300))")
    }
}
