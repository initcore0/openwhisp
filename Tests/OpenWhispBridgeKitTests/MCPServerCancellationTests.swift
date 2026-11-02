import XCTest
@testable import OpenWhispBridgeKit
@testable import OpenWhispCore

/// A bridge session whose calls for `blocking` methods park until released (or
/// a safety timeout), like a real dictate waiting on the user.
private final class BlockingSession: BridgeSession {
    let blocking: Set<String>
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    init(blocking: Set<String>) { self.blocking = blocking }

    func handshake(clientName: String) throws {}

    func call<P: Codable & Sendable, R: Decodable>(method: String, params: P?, resultType: R.Type) throws -> R {
        lock.lock(); _calls.append(method); lock.unlock()
        if blocking.contains(method) {
            started.signal()
            if release.wait(timeout: .now() + 5) == .success {
                // What the app answers once dictate.cancel lands.
                throw BridgeClient.ClientError.domain(reason: .cancelled, message: "cancelled", originalText: nil)
            }
        }
        let json = method == "dictate"
            ? #"{"text":"late answer","durationSeconds":1.0,"timedOut":false,"endedBy":"user"}"#
            : #"{"text":"done"}"#
        return try JSONDecoder().decode(R.self, from: Data(json.utf8))
    }
}

/// Collects the server's stdout frames.
private final class FrameSink {
    private let lock = NSLock()
    private var frames: [[String: Any]] = []

    func append(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.lock(); frames.append(obj); lock.unlock()
    }

    /// Response frames (not notifications) for `id`.
    func responses(id: Int) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return frames.filter { ($0["id"] as? Int) == id && $0["method"] == nil }
    }
}

/// `notifications/cancelled` handling: when an agent cancels an in-flight
/// `openwhisp_dictate`, the mic must close now (dictate.cancel over the bridge)
/// instead of staying open until the dictate timeout, and the cancelled request
/// gets no response (BUG_HUNT_2026-07, "MCP server is single-threaded").
final class MCPServerCancellationTests: XCTestCase {

    private final class CancelRecorder {
        private let lock = NSLock()
        private var _names: [String] = []
        var names: [String] { lock.lock(); defer { lock.unlock() }; return _names }
        func record(_ n: String) { lock.lock(); _names.append(n); lock.unlock() }
    }

    private func makeServer(
        session: BlockingSession, sink: FrameSink, recorder: CancelRecorder,
        cancelResults: [Bool] = [true]
    ) -> MCPServer {
        var results = cancelResults
        let resultsLock = NSLock()
        return MCPServer(
            bridgeFactory: { name in PersistentBridge(clientName: name) { _ in session } },
            cancelDictation: { name in
                recorder.record(name)
                resultsLock.lock()
                let landed = results.isEmpty ? true : results.removeFirst()
                resultsLock.unlock()
                if landed { session.release.signal() }
                return landed
            },
            cancelRetryInterval: 0.01,
            output: sink.append
        )
    }

    private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}"#
    private func dictate(id: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"openwhisp_dictate","arguments":{"prompt":"q?"}}}"#
    }
    private func refine(id: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"openwhisp_refine","arguments":{"text":"a","instruction":"b"}}}"#
    }
    private func cancelled(_ requestID: String) -> String {
        #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(requestID),"reason":"user pressed Esc"}}"#
    }

    func testCancelStopsTheRunningDictationAndSuppressesItsReply() {
        let session = BlockingSession(blocking: ["dictate"])
        let sink = FrameSink(), recorder = CancelRecorder()
        let server = makeServer(session: session, sink: sink, recorder: recorder)

        let fed = expectation(description: "stdin loop never blocked")
        DispatchQueue.global().async {
            server.handle(self.initialize)
            server.handle(self.dictate(id: 7))
            XCTAssertEqual(session.started.wait(timeout: .now() + 5), .success)
            server.handle(self.cancelled("7"))
            fed.fulfill()
        }
        // Before the fix, handle(tools/call) blocked until the dictate returned,
        // so the cancel could not even be read.
        wait(for: [fed], timeout: 3)
        server.waitForIdle()

        XCTAssertEqual(recorder.names, ["claude-code"], "dictate.cancel sent once, as the MCP client")
        XCTAssertTrue(sink.responses(id: 7).isEmpty, "a cancelled request gets no response")
        XCTAssertEqual(sink.responses(id: 1).count, 1, "initialize still answered")
    }

    func testCancelIsRetriedUntilASessionExistsToCancel() {
        // e.g. the dictate is still waiting on the consent prompt: nothing to
        // cancel yet, but the session must not open later and listen to no one.
        let session = BlockingSession(blocking: ["dictate"])
        let sink = FrameSink(), recorder = CancelRecorder()
        let server = makeServer(session: session, sink: sink, recorder: recorder,
                                cancelResults: [false, false, true])

        server.handle(initialize)
        server.handle(dictate(id: 3))
        XCTAssertEqual(session.started.wait(timeout: .now() + 5), .success)
        server.handle(cancelled("3"))
        server.waitForIdle()

        XCTAssertEqual(recorder.names.count, 3)
        XCTAssertTrue(sink.responses(id: 3).isEmpty)
    }

    func testStringRequestIDIsMatched() {
        let session = BlockingSession(blocking: ["dictate"])
        let sink = FrameSink(), recorder = CancelRecorder()
        let server = makeServer(session: session, sink: sink, recorder: recorder)

        server.handle(#"{"jsonrpc":"2.0","id":"req-a","method":"tools/call","params":{"name":"openwhisp_dictate","arguments":{}}}"#)
        XCTAssertEqual(session.started.wait(timeout: .now() + 5), .success)
        server.handle(cancelled(#""req-a""#))
        server.waitForIdle()
        XCTAssertEqual(recorder.names.count, 1)
    }

    func testCancelForAQueuedCallSkipsItEntirely() {
        let session = BlockingSession(blocking: ["dictate"])
        let sink = FrameSink(), recorder = CancelRecorder()
        let server = makeServer(session: session, sink: sink, recorder: recorder)

        server.handle(dictate(id: 1))
        XCTAssertEqual(session.started.wait(timeout: .now() + 5), .success)
        server.handle(refine(id: 2))      // queued behind the dictate
        server.handle(cancelled("2"))     // cancelled before it ever runs
        XCTAssertTrue(recorder.names.isEmpty, "no dictate.cancel for a queued non-dictate call")
        session.release.signal()          // let the dictate finish
        server.waitForIdle()

        XCTAssertEqual(session.calls, ["dictate"], "the cancelled refine never reached the bridge")
        XCTAssertTrue(sink.responses(id: 2).isEmpty)
        XCTAssertEqual(sink.responses(id: 1).count, 1, "the un-cancelled dictate is still answered")
    }

    func testCancelForARunningNonDictateOnlySuppressesTheReply() {
        let session = BlockingSession(blocking: ["refine"])
        let sink = FrameSink(), recorder = CancelRecorder()
        let server = makeServer(session: session, sink: sink, recorder: recorder)

        server.handle(refine(id: 5))
        XCTAssertEqual(session.started.wait(timeout: .now() + 5), .success)
        server.handle(cancelled("5"))
        session.release.signal()
        server.waitForIdle()

        XCTAssertTrue(recorder.names.isEmpty, "refine has no bridge cancel verb")
        XCTAssertTrue(sink.responses(id: 5).isEmpty)
    }

    func testUnknownOrFinishedRequestIDIsIgnored() {
        let session = BlockingSession(blocking: [])
        let sink = FrameSink(), recorder = CancelRecorder()
        let server = makeServer(session: session, sink: sink, recorder: recorder)

        server.handle(dictate(id: 9))
        server.waitForIdle()
        XCTAssertEqual(sink.responses(id: 9).count, 1)
        server.handle(cancelled("9"))   // already answered
        server.handle(cancelled("404")) // never seen
        server.waitForIdle()
        XCTAssertTrue(recorder.names.isEmpty)
        XCTAssertEqual(sink.responses(id: 9).count, 1)
    }

    func testStdinClosingCancelsTheRunningDictation() {
        // The client process went away: nobody will ever read the answer.
        let session = BlockingSession(blocking: ["dictate"])
        let sink = FrameSink(), recorder = CancelRecorder()
        let server = makeServer(session: session, sink: sink, recorder: recorder)

        server.handle(dictate(id: 4))
        XCTAssertEqual(session.started.wait(timeout: .now() + 5), .success)
        server.stdinClosed()

        XCTAssertEqual(recorder.names.count, 1)
        XCTAssertTrue(sink.responses(id: 4).isEmpty)
    }

    func testPingIsAnsweredWhileADictateIsInFlight() {
        let session = BlockingSession(blocking: ["dictate"])
        let sink = FrameSink(), recorder = CancelRecorder()
        let server = makeServer(session: session, sink: sink, recorder: recorder)

        server.handle(dictate(id: 1))
        XCTAssertEqual(session.started.wait(timeout: .now() + 5), .success)
        server.handle(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        XCTAssertEqual(sink.responses(id: 2).count, 1, "answered without waiting for the dictate")
        session.release.signal()
        server.waitForIdle()
    }

    // MARK: - Tracker

    func testTrackerStateMachine() {
        let t = MCPRequestTracker()
        t.enqueue(.number(1), isDictate: true)
        t.enqueue(.number(2), isDictate: false)
        XCTAssertEqual(t.cancel(.number(2)), .suppressOnly, "queued")
        XCTAssertFalse(t.start(.number(2)), "cancelled while queued → skip")
        XCTAssertFalse(t.finish(.number(2)))

        XCTAssertTrue(t.start(.number(1)))
        XCTAssertEqual(t.runningDictation(), .number(1))
        XCTAssertEqual(t.cancel(.number(1)), .cancelDictation)
        XCTAssertEqual(t.cancel(.number(1)), .ignore, "second cancel is a no-op")
        XCTAssertTrue(t.isRunningAndCancelled(.number(1)))
        XCTAssertFalse(t.finish(.number(1)), "no reply for a cancelled call")
        XCTAssertFalse(t.isRunningAndCancelled(.number(1)))
        XCTAssertEqual(t.cancel(.number(1)), .ignore, "finished")
    }
}
