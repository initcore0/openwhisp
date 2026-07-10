import XCTest
@testable import OpenWhispBridgeKit
@testable import OpenWhispCore

/// A scripted in-memory ``BridgeSession``. Each connection instance records the
/// calls made through it and returns a queued outcome per call.
final class FakeBridgeSession: BridgeSession {
    enum Outcome {
        case ok        // return a decoded-from-empty-shaped result
        case fail(BridgeClient.ClientError)
    }

    let id: Int
    var handshakes = 0
    var calls: [String] = []
    private var outcomes: [Outcome]
    private let resultJSON: (String) -> String

    init(id: Int, outcomes: [Outcome], resultJSON: @escaping (String) -> String = { _ in "{}" }) {
        self.id = id
        self.outcomes = outcomes
        self.resultJSON = resultJSON
    }

    func handshake(clientName: String) throws { handshakes += 1 }

    func call<P: Codable & Sendable, R: Decodable>(
        method: String, params: P?, resultType: R.Type
    ) throws -> R {
        calls.append(method)
        let outcome = outcomes.isEmpty ? .ok : outcomes.removeFirst()
        switch outcome {
        case .fail(let e): throw e
        case .ok:
            let data = Data(resultJSON(method).utf8)
            return try JSONDecoder().decode(R.self, from: data)
        }
    }
}

final class PersistentBridgeTests: XCTestCase {

    /// Build a PersistentBridge whose factory hands out the given fake sessions
    /// in order, and records how many connections were opened.
    private func makeBridge(_ sessions: [FakeBridgeSession]) -> (PersistentBridge, () -> Int) {
        var queue = sessions
        var opened = 0
        let bridge = PersistentBridge(clientName: "test-agent") { _ in
            opened += 1
            let s = queue.removeFirst()
            try s.handshake(clientName: "test-agent")
            return s
        }
        return (bridge, { opened })
    }

    private func statusResult() -> String {
        // A minimal valid StatusResult JSON so the typed decode succeeds.
        """
        {"appVersion":"1","engine":"e","model":"m","sessionActive":false,\
        "llmConfigured":true,"llmProvider":"local","sendsTextToCloud":false,"historyEnabled":true}
        """
    }

    func testConnectsAndHandshakesOncePerProcess() throws {
        let s = FakeBridgeSession(id: 1, outcomes: [.ok, .ok]) { _ in self.statusResult() }
        let (bridge, opened) = makeBridge([s])

        _ = try bridge.call(method: "status", params: BridgeWire.NoParams(), resultType: BridgeWire.StatusResult.self)
        _ = try bridge.call(method: "status", params: BridgeWire.NoParams(), resultType: BridgeWire.StatusResult.self)

        XCTAssertEqual(opened(), 1, "one connection reused across calls")
        XCTAssertEqual(s.handshakes, 1, "handshake only once")
        XCTAssertEqual(s.calls.count, 2)
    }

    func testRetriesOnceOnUnreachableWithFreshConnection() throws {
        let dead = FakeBridgeSession(id: 1, outcomes: [.fail(.unreachable)])
        let fresh = FakeBridgeSession(id: 2, outcomes: [.ok]) { _ in self.statusResult() }
        let (bridge, opened) = makeBridge([dead, fresh])

        let r = try bridge.call(method: "status", params: BridgeWire.NoParams(), resultType: BridgeWire.StatusResult.self)
        XCTAssertEqual(r.appVersion, "1")
        XCTAssertEqual(opened(), 2, "dropped stale connection and reconnected once")
        XCTAssertEqual(fresh.handshakes, 1)
    }

    func testRetriesOnceOnProtocolError() throws {
        let dead = FakeBridgeSession(id: 1, outcomes: [.fail(.protocolError("garbled"))])
        let fresh = FakeBridgeSession(id: 2, outcomes: [.ok]) { _ in self.statusResult() }
        let (bridge, _) = makeBridge([dead, fresh])
        XCTAssertNoThrow(try bridge.call(method: "status", params: BridgeWire.NoParams(), resultType: BridgeWire.StatusResult.self))
    }

    func testSecondTransportFailurePropagates() throws {
        let dead1 = FakeBridgeSession(id: 1, outcomes: [.fail(.unreachable)])
        let dead2 = FakeBridgeSession(id: 2, outcomes: [.fail(.unreachable)])
        let (bridge, opened) = makeBridge([dead1, dead2])
        XCTAssertThrowsError(try bridge.call(method: "status", params: BridgeWire.NoParams(), resultType: BridgeWire.StatusResult.self)) { err in
            guard case BridgeClient.ClientError.unreachable = err else {
                return XCTFail("expected unreachable, got \(err)")
            }
        }
        XCTAssertEqual(opened(), 2, "retried exactly once")
    }

    func testDomainErrorPropagatesWithoutRetry() throws {
        let s = FakeBridgeSession(id: 1, outcomes: [.fail(.domain(reason: .busy, message: "busy", originalText: nil))])
        let (bridge, opened) = makeBridge([s])
        XCTAssertThrowsError(try bridge.call(method: "dictate", params: BridgeWire.NoParams(), resultType: BridgeWire.DictateResult.self)) { err in
            guard case BridgeClient.ClientError.domain(let reason, _, _) = err, reason == .busy else {
                return XCTFail("expected domain(busy), got \(err)")
            }
        }
        XCTAssertEqual(opened(), 1, "domain error is not a transport failure — no reconnect")
    }

    func testUnsupportedVersionPropagatesWithoutRetry() throws {
        let s = FakeBridgeSession(id: 1, outcomes: [.fail(.unsupportedVersion)])
        let (bridge, opened) = makeBridge([s])
        XCTAssertThrowsError(try bridge.call(method: "status", params: BridgeWire.NoParams(), resultType: BridgeWire.StatusResult.self))
        XCTAssertEqual(opened(), 1)
    }

    func testTransportClassification() {
        XCTAssertTrue(PersistentBridge.isTransportFailure(.unreachable))
        XCTAssertTrue(PersistentBridge.isTransportFailure(.protocolError("x")))
        XCTAssertFalse(PersistentBridge.isTransportFailure(.unsupportedVersion))
        XCTAssertFalse(PersistentBridge.isTransportFailure(.domain(reason: nil, message: "", originalText: nil)))
    }
}
