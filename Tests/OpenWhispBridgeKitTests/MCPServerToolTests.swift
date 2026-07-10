import XCTest
@testable import OpenWhispBridgeKit
@testable import OpenWhispCore

/// Drives `MCPServer.callTool` against a fake bridge to prove tool routing,
/// argument handling, and error surfacing — without touching a real socket.
final class MCPServerToolTests: XCTestCase {

    /// Build an MCPServer whose bridge forwards to a scripted fake session.
    private func makeServer(
        outcomes: [FakeBridgeSession.Outcome] = [.ok],
        resultJSON: @escaping (String) -> String = { _ in "{}" }
    ) -> (MCPServer, FakeBridgeSession) {
        let session = FakeBridgeSession(id: 1, outcomes: outcomes, resultJSON: resultJSON)
        let server = MCPServer { name in
            PersistentBridge(clientName: name) { _ in
                try session.handshake(clientName: name)
                return session
            }
        }
        return (server, session)
    }

    private func args(_ o: [String: MCPWire.JSONValue]) -> MCPWire.JSONValue { .object(o) }

    func testDictateRoutesAndReturnsText() {
        let (server, session) = makeServer(resultJSON: { _ in
            #"{"text":"the answer","durationSeconds":1.0,"timedOut":false,"endedBy":"user"}"#
        })
        let r = server.callTool(name: "openwhisp_dictate", arguments: args(["prompt": .string("hi?")]))
        XCTAssertFalse(r.isError)
        XCTAssertEqual(r.content.first?.text, "the answer")
        XCTAssertEqual(session.calls, ["dictate"])
    }

    func testDictateEmptyTextReadsAsUserSaidNothing() {
        let (server, _) = makeServer(resultJSON: { _ in
            #"{"text":"","durationSeconds":1.0,"timedOut":false,"endedBy":"user"}"#
        })
        let r = server.callTool(name: "openwhisp_dictate", arguments: args([:]))
        XCTAssertEqual(r.content.first?.text, "(the user said nothing)")
    }

    func testRefineRoutesWithBothArgs() {
        let (server, session) = makeServer(resultJSON: { _ in #"{"text":"polished"}"# })
        let r = server.callTool(name: "openwhisp_refine",
                                arguments: args(["text": .string("raw"), "instruction": .string("fix")]))
        XCTAssertFalse(r.isError)
        XCTAssertEqual(r.content.first?.text, "polished")
        XCTAssertEqual(session.calls, ["refine"])
    }

    func testRefineMissingArgsIsErrorAndDoesNotCallBridge() {
        let (server, session) = makeServer()
        let r = server.callTool(name: "openwhisp_refine", arguments: args(["text": .string("raw")]))
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.content.first?.text.contains("requires") ?? false)
        XCTAssertTrue(session.calls.isEmpty, "no bridge call when args are invalid")
    }

    func testHistoryFormatsEntries() {
        let (server, _) = makeServer(resultJSON: { _ in
            #"{"entries":[{"id":"11111111-1111-1111-1111-111111111111","text":"note one","date":"2026-07-09T10:00:00.000Z","appBundleID":null,"appName":"Slack","initiator":"user"}]}"#
        })
        let r = server.callTool(name: "openwhisp_history", arguments: args(["limit": .integer(5)]))
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.content.first?.text.contains("Slack") ?? false)
        XCTAssertTrue(r.content.first?.text.contains("note one") ?? false)
    }

    func testHistoryEmptyIsFriendly() {
        let (server, _) = makeServer(resultJSON: { _ in #"{"entries":[]}"# })
        let r = server.callTool(name: "openwhisp_history", arguments: args([:]))
        XCTAssertEqual(r.content.first?.text, "(no dictation history)")
    }

    func testUnknownToolIsError() {
        let (server, _) = makeServer()
        let r = server.callTool(name: "nope", arguments: args([:]))
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.content.first?.text.contains("unknown tool") ?? false)
    }

    func testBridgeUnreachableSurfacesGuidance() {
        // Both attempts fail (retry exhausted) → the client-error message is shown.
        let session = FakeBridgeSession(id: 1, outcomes: [.fail(.unreachable), .fail(.unreachable)])
        let server = MCPServer { name in
            PersistentBridge(clientName: name) { _ in
                try session.handshake(clientName: name); return session
            }
        }
        let r = server.callTool(name: "openwhisp_history", arguments: args([:]))
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.content.first?.text.contains("OpenWhisp isn't running") ?? false)
    }

    func testDomainErrorSurfacesMessage() {
        let (server, _) = makeServer(outcomes: [.fail(.domain(reason: .busy, message: "The mic is busy", originalText: nil))])
        let r = server.callTool(name: "openwhisp_dictate", arguments: args([:]))
        XCTAssertTrue(r.isError)
        XCTAssertEqual(r.content.first?.text, "The mic is busy")
    }
}
