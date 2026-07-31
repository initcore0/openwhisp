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
        translator: StreamOverlayServer.Translator? = nil,
        counterCount: Int = 0
    ) throws -> (StreamOverlayServer, UInt16) {
        let server = StreamOverlayServer(
            config: config, translator: translator, counterCount: counterCount)
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

    // MARK: - Voice-command counter (the wiring reality check)

    /// A counter config the tests share: trigger phrase, label, corner.
    private func counterConfig(
        phrase: String = "I died again",
        captionsEnabled: Bool = true
    ) -> StreamOverlayConfig {
        var config = StreamOverlayConfig()
        config.counterEnabled = true
        config.counterPhrase = phrase
        config.counterLabel = "Deaths"
        config.counterCorner = .topRight
        config.captionsEnabled = captionsEnabled
        return config
    }

    /// THE wiring test: a matching FINAL on the real publish path that a live
    /// session uses must emit a `counter` SSE frame with count=1 — and a
    /// non-matching final must emit nothing.
    @MainActor
    func testMatchingFinalIncrementsTheCounterOverSSE() throws {
        let (server, port) = try startServer(config: counterConfig())
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        // The greeting seeds the counter at its persisted value (0 here).
        XCTAssertTrue(client.wait { $0.contains("event: counter") && $0.contains("\"count\":0") },
                      "counter greeting missing: \(client.received.prefix(400))")

        // A final with no trigger phrase must NOT bump the counter.
        server.publishFinal("chat, what do you think of this build")
        XCTAssertTrue(client.wait { $0.contains("this build") }, "caption should still flow")
        XCTAssertFalse(client.received.contains("\"count\":1"),
                       "a non-matching final must not increment: \(client.received.suffix(400))")
        XCTAssertEqual(server.counterCount, 0)

        // The real thing: the streamer says the phrase.
        server.publishFinal("oh no, I died again!")
        XCTAssertTrue(
            client.wait { $0.contains("event: counter") && $0.contains("\"count\":1") },
            "counter frame missing after a matching final: \(client.received.suffix(500))")
        XCTAssertEqual(server.counterCount, 1)
        // The frame carries what the page renders.
        XCTAssertTrue(client.received.contains("\"label\":\"Deaths\""))
        XCTAssertTrue(client.received.contains("\"corner\":\"topRight\""))
        XCTAssertTrue(client.received.contains("\"visible\":true"))
    }

    /// Counter-only mode: captions off, counter live. No caption frames are
    /// broadcast at all, but the counter still increments — the scenario the
    /// feature exists for.
    @MainActor
    func testCounterStillCountsWithCaptionsDisabled() throws {
        let (server, port) = try startServer(config: counterConfig(captionsEnabled: false))
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("event: counter") })

        server.publishPartial("I died ag")
        server.publishFinal("I died again")
        XCTAssertTrue(client.wait { $0.contains("\"count\":1") },
                      "counter must work with captions off: \(client.received.suffix(400))")
        // Not one word of the transcript went out as a caption.
        XCTAssertFalse(client.received.contains("I died again"),
                       "captions are off — no caption text may be broadcast: \(client.received.suffix(500))")
        XCTAssertFalse(client.received.contains("I died ag"))

        // And the served page renders the captions block hidden.
        let page = RawClient(port: port)
        defer { page.close() }
        page.send("GET / HTTP/1.1\r\n\r\n")
        XCTAssertTrue(page.wait { $0.contains("</html>") })
        XCTAssertTrue(page.received.contains("<div id=\"captions\" class=\"hidden\">"))
    }

    /// Saying the phrase twice in one utterance counts twice — dropping the
    /// second would be a silent miscount.
    @MainActor
    func testRepeatedPhraseInOneFinalCountsTwice() throws {
        let (server, port) = try startServer(config: counterConfig())
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("event: counter") })

        server.publishFinal("I died again and then I died again")
        XCTAssertTrue(client.wait { $0.contains("\"count\":2") },
                      "two occurrences should count twice: \(client.received.suffix(400))")
        XCTAssertEqual(server.counterCount, 2)
    }

    /// Partials must never count: a streaming engine grows its hypothesis, so
    /// counting them would fire several times for one spoken phrase.
    @MainActor
    func testPartialsDoNotIncrementTheCounter() throws {
        let (server, port) = try startServer(config: counterConfig())
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("event: counter") })

        // The growing hypothesis passes THROUGH the completed phrase repeatedly.
        server.publishPartial("I died")
        server.publishPartial("I died again")
        server.publishPartial("I died again and")
        XCTAssertTrue(client.wait { $0.contains("I died again and") })
        XCTAssertEqual(server.counterCount, 0, "partials must not count")

        server.publishFinal("I died again and that's it")
        XCTAssertTrue(client.wait { $0.contains("\"count\":1") })
        XCTAssertEqual(server.counterCount, 1, "exactly one increment for one spoken phrase")
    }

    /// Detection runs on the ORIGINAL text, before translation — so a Russian
    /// streamer triggers on a Russian phrase while captions go out translated.
    @MainActor
    func testCounterMatchesSourceTextNotTheTranslation() throws {
        var config = counterConfig(phrase: "я снова умер")
        config.translationEnabled = true
        config.targetLanguage = "en"
        let (server, port) = try startServer(config: config, translator: { _, _ in "I died again" })
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("event: counter") })

        server.publishFinal("ну всё, я снова умер!")
        XCTAssertTrue(client.wait { $0.contains("\"count\":1") },
                      "Cyrillic trigger on the source text missed: \(client.received.suffix(500))")
        XCTAssertTrue(client.wait { $0.contains("I died again") }, "the caption is still translated")
    }

    /// A page connecting mid-stream must be greeted with the RUNNING count, not
    /// a blank widget — and the persisted value must survive a restart.
    @MainActor
    func testNewClientIsGreetedWithTheCurrentCount() throws {
        let (server, port) = try startServer(config: counterConfig(), counterCount: 41)
        defer { server.stop() }

        server.publishFinal("I died again")
        XCTAssertEqual(server.counterCount, 42, "the restored count continues, it doesn't restart")

        let latecomer = RawClient(port: port)
        defer { latecomer.close() }
        latecomer.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(
            latecomer.wait { $0.contains("event: counter") && $0.contains("\"count\":42") },
            "a client connecting mid-stream must see the running count: \(latecomer.received.prefix(600))")
    }

    /// The owner persists through `onCounterChanged`; reset zeroes both the
    /// value and the live pages.
    @MainActor
    func testResetZeroesTheCounterAndNotifiesTheOwner() throws {
        let (server, port) = try startServer(config: counterConfig(), counterCount: 7)
        defer { server.stop() }

        var persisted: [Int] = []
        server.onCounterChanged = { persisted.append($0) }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("\"count\":7") })

        server.publishFinal("I died again")
        XCTAssertTrue(client.wait { $0.contains("\"count\":8") })
        server.resetCounter()
        XCTAssertTrue(client.wait { $0.contains("\"count\":0") },
                      "reset must reach the page: \(client.received.suffix(400))")
        XCTAssertEqual(server.counterCount, 0)
        XCTAssertEqual(persisted, [8, 0], "every change is handed to the owner to persist")
    }

    /// A disabled counter never fires, whatever is said.
    @MainActor
    func testDisabledCounterNeverIncrements() throws {
        var config = counterConfig()
        config.counterEnabled = false
        let (server, port) = try startServer(config: config)
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("text/event-stream") })

        server.publishFinal("I died again")
        XCTAssertTrue(client.wait { $0.contains("I died again") }, "captions still flow")
        XCTAssertEqual(server.counterCount, 0)
        XCTAssertFalse(client.received.contains("\"count\":1"))
    }

    /// Relabeling / moving the counter applies LIVE (same rule as the caption
    /// look) and must NOT reset the tally.
    @MainActor
    func testApplyLookUpdatesTheCounterWidgetWithoutResettingTheCount() throws {
        let (server, port) = try startServer(config: counterConfig(), counterCount: 3)
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("\"count\":3") })

        var edited = counterConfig()
        edited.counterLabel = "Deaths this stream"
        edited.counterCorner = .bottomLeft
        server.applyLook(edited)

        XCTAssertTrue(
            client.wait { $0.contains("\"label\":\"Deaths this stream\"") && $0.contains("\"corner\":\"bottomLeft\"") },
            "relabel/move must reach live pages: \(client.received.suffix(500))")
        XCTAssertEqual(server.counterCount, 3, "a config edit must never reset the tally")
    }

    /// Switching captions OFF mid-stream blanks what's on screen and stops
    /// caption frames, while the counter keeps working.
    @MainActor
    func testApplyLookCanTurnCaptionsOffMidStream() throws {
        var config = counterConfig()
        config.lingerSeconds = 30      // don't let the auto-hide do the blanking
        let (server, port) = try startServer(config: config)
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("text/event-stream") })

        server.publishPartial("captions running here")
        XCTAssertTrue(client.wait { $0.contains("captions running here") })

        var edited = config
        edited.captionsEnabled = false
        server.applyLook(edited)
        XCTAssertTrue(client.wait { $0.contains("\"lines\":[]") },
                      "turning captions off must blank the screen: \(client.received.suffix(400))")

        // Nothing further is captioned, but the counter still counts.
        server.publishFinal("I died again")
        XCTAssertTrue(client.wait { $0.contains("\"count\":1") })
        XCTAssertFalse(client.received.contains("\"lines\":[\"I died again\"]"),
                       "no caption frames after captions were switched off")
    }

    @MainActor
    func testFailedTranslationKeepsOriginalCaption() throws {
        // The never-lose-text rule at the seam the app now wires live (Apple
        // Translation returns nil on missing assets / timeout): a translator
        // that fails must degrade to the ORIGINAL caption line, never drop it.
        let config = StreamOverlayConfig(translationEnabled: true, targetLanguage: "es")
        let (server, port) = try startServer(config: config, translator: { _, _ in nil })
        defer { server.stop() }

        let client = RawClient(port: port)
        defer { client.close() }
        client.send("GET /events HTTP/1.1\r\n\r\n")
        XCTAssertTrue(client.wait { $0.contains("text/event-stream") })

        server.publishFinal("still here")
        XCTAssertTrue(client.wait { $0.contains("still here") },
                      "untranslated fallback caption missing: \(client.received.suffix(300))")
    }
}
