import XCTest
@testable import OpenWhispCore

final class BridgeRouterTests: XCTestCase {

    private func line(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Handshake ordering

    func testFirstFrameMustBeHello() {
        let routed = BridgeRouter.route(line: line(#"{"jsonrpc":"2.0","id":1,"method":"status"}"#), hasHandshaken: false)
        guard case let .close(reason) = routed else { return XCTFail("expected close, got \(routed)") }
        XCTAssertTrue(reason.contains("bridge.hello"))
    }

    func testHelloAcceptedAsFirstFrame() {
        let routed = BridgeRouter.route(
            line: line(#"{"jsonrpc":"2.0","id":1,"method":"bridge.hello","params":{"protocolVersion":1,"clientName":"claude-code","clientVersion":"2.1.0"}}"#),
            hasHandshaken: false
        )
        guard case let .intent(.hello(id, params)) = routed else { return XCTFail("expected hello intent, got \(routed)") }
        XCTAssertEqual(id, .number(1))
        XCTAssertEqual(params.clientName, "claude-code")
        XCTAssertEqual(params.protocolVersion, 1)
    }

    func testStatusAllowedAfterHandshake() {
        let routed = BridgeRouter.route(line: line(#"{"jsonrpc":"2.0","id":"s","method":"status"}"#), hasHandshaken: true)
        guard case .intent(.status(.string("s"))) = routed else { return XCTFail("expected status intent, got \(routed)") }
    }

    // MARK: Malformed / oversized

    func testMalformedJSONCloses() {
        let routed = BridgeRouter.route(line: line("{ not json "), hasHandshaken: true)
        guard case .close = routed else { return XCTFail("expected close, got \(routed)") }
    }

    func testOversizedFrameCloses() {
        // A line one byte over the cap.
        var big = Data(count: BridgeWire.maxFrameBytes + 1)
        big[0] = UInt8(ascii: "{")
        let routed = BridgeRouter.route(line: big, hasHandshaken: true)
        guard case .close = routed else { return XCTFail("expected close, got \(routed)") }
    }

    // MARK: Unknown method (post-handshake → error, not close)

    func testUnknownMethodAfterHandshakeErrors() {
        let routed = BridgeRouter.route(line: line(#"{"jsonrpc":"2.0","id":7,"method":"frobnicate"}"#), hasHandshaken: true)
        guard case let .error(id, err) = routed else { return XCTFail("expected error, got \(routed)") }
        XCTAssertEqual(id, .number(7))
        XCTAssertEqual(err.code, BridgeWire.ErrorObject.methodNotFound)
        XCTAssertEqual(err.data?.reason, .unknownMethod)
    }

    func testUnknownMethodBeforeHandshakeCloses() {
        let routed = BridgeRouter.route(line: line(#"{"jsonrpc":"2.0","id":7,"method":"frobnicate"}"#), hasHandshaken: false)
        guard case .close = routed else { return XCTFail("expected close, got \(routed)") }
    }

    // MARK: Per-method param requirements

    func testHelloMissingParamsIsInvalidParams() {
        let routed = BridgeRouter.route(line: line(#"{"jsonrpc":"2.0","id":1,"method":"bridge.hello"}"#), hasHandshaken: false)
        guard case let .error(_, err) = routed else { return XCTFail("expected error, got \(routed)") }
        XCTAssertEqual(err.code, BridgeWire.ErrorObject.invalidParams)
    }

    func testRefineRequiresParams() {
        let routed = BridgeRouter.route(line: line(#"{"jsonrpc":"2.0","id":2,"method":"refine"}"#), hasHandshaken: true)
        guard case let .error(_, err) = routed else { return XCTFail("expected error, got \(routed)") }
        XCTAssertEqual(err.code, BridgeWire.ErrorObject.invalidParams)
    }

    func testRefineWithParams() {
        let routed = BridgeRouter.route(
            line: line(#"{"jsonrpc":"2.0","id":2,"method":"refine","params":{"text":"raw","instruction":"tighten"}}"#),
            hasHandshaken: true
        )
        guard case let .intent(.refine(_, params)) = routed else { return XCTFail("expected refine intent, got \(routed)") }
        XCTAssertEqual(params.text, "raw")
        XCTAssertEqual(params.instruction, "tighten")
    }

    func testDictateDefaultsWhenParamsAbsent() {
        let routed = BridgeRouter.route(line: line(#"{"jsonrpc":"2.0","id":3,"method":"dictate"}"#), hasHandshaken: true)
        guard case let .intent(.dictate(_, params)) = routed else { return XCTFail("expected dictate intent, got \(routed)") }
        XCTAssertNil(params.prompt)
        XCTAssertNil(params.timeoutSeconds)
    }

    func testDictateWithPrompt() {
        let routed = BridgeRouter.route(
            line: line(#"{"jsonrpc":"2.0","id":3,"method":"dictate","params":{"prompt":"Which branch?","timeoutSeconds":45}}"#),
            hasHandshaken: true
        )
        guard case let .intent(.dictate(_, params)) = routed else { return XCTFail("expected dictate intent, got \(routed)") }
        XCTAssertEqual(params.prompt, "Which branch?")
        XCTAssertEqual(params.timeoutSeconds, 45)
    }

    func testDictateStopAndCancelNeedNoParams() {
        guard case .intent(.dictateStop) = BridgeRouter.route(line: line(#"{"id":1,"method":"dictate.stop"}"#), hasHandshaken: true) else {
            return XCTFail("expected dictateStop")
        }
        guard case .intent(.dictateCancel) = BridgeRouter.route(line: line(#"{"id":1,"method":"dictate.cancel"}"#), hasHandshaken: true) else {
            return XCTFail("expected dictateCancel")
        }
    }

    func testTranscribeFileRejectedInV1() {
        let routed = BridgeRouter.route(line: line(#"{"id":1,"method":"transcribe.file","params":{"path":"/x.wav"}}"#), hasHandshaken: true)
        guard case let .error(_, err) = routed else { return XCTFail("expected error, got \(routed)") }
        XCTAssertEqual(err.data?.reason, .unknownMethod)
    }

    // MARK: Sync verbs (MAK-51 WP0b, wire v1.2)

    func testSyncManifestNeedsNoParams() {
        let routed = BridgeRouter.route(line: line(#"{"id":"m","method":"sync.manifest"}"#), hasHandshaken: true)
        guard case .intent(.syncManifest(.string("m"))) = routed else {
            return XCTFail("expected syncManifest intent, got \(routed)")
        }
    }

    func testSyncPullDefaultsWhenParamsAbsent() {
        let routed = BridgeRouter.route(line: line(#"{"id":1,"method":"sync.pull"}"#), hasHandshaken: true)
        guard case let .intent(.syncPull(_, params)) = routed else {
            return XCTFail("expected syncPull intent, got \(routed)")
        }
        XCTAssertNil(params.sinceHistoryCursor)
        XCTAssertNil(params.want)
    }

    func testSyncPullWithParams() {
        let routed = BridgeRouter.route(
            line: line(#"{"id":1,"method":"sync.pull","params":{"sinceHistoryCursor":"2026-01-01T00:00:00.000Z","want":["vocabulary","history"]}}"#),
            hasHandshaken: true
        )
        guard case let .intent(.syncPull(_, params)) = routed else {
            return XCTFail("expected syncPull intent, got \(routed)")
        }
        XCTAssertEqual(params.sinceHistoryCursor, "2026-01-01T00:00:00.000Z")
        XCTAssertEqual(params.want, [.vocabulary, .history])
    }

    func testSyncPushRequiresBundle() {
        let routed = BridgeRouter.route(line: line(#"{"id":2,"method":"sync.push"}"#), hasHandshaken: true)
        guard case let .error(_, err) = routed else { return XCTFail("expected error, got \(routed)") }
        XCTAssertEqual(err.code, BridgeWire.ErrorObject.invalidParams)
    }

    func testSyncPushWithBundle() {
        let routed = BridgeRouter.route(
            line: line(#"{"id":2,"method":"sync.push","params":{"bundle":{"schemaVersion":3},"historyEntries":[]}}"#),
            hasHandshaken: true
        )
        guard case let .intent(.syncPush(_, params)) = routed else {
            return XCTFail("expected syncPush intent, got \(routed)")
        }
        XCTAssertEqual(params.bundle.schemaVersion, 3)
        XCTAssertTrue(params.historyEntries.isEmpty)
    }

    func testSyncVerbsRequireHandshakeFirst() {
        for method in ["sync.manifest", "sync.pull", "sync.push"] {
            let routed = BridgeRouter.route(line: line(#"{"id":1,"method":"\#(method)"}"#), hasHandshaken: false)
            guard case .close = routed else {
                return XCTFail("expected close before handshake for \(method), got \(routed)")
            }
        }
    }

    // MARK: Clamping

    func testTimeoutClamping() {
        XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(nil), 60)
        XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(45), 45)
        XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(0), 1)      // floor
        XCTAssertEqual(BridgeRouter.resolvedTimeoutSeconds(9999), 300) // ceiling
    }

    func testHistoryLimitClamping() {
        XCTAssertEqual(BridgeRouter.resolvedHistoryLimit(nil), 20)
        XCTAssertEqual(BridgeRouter.resolvedHistoryLimit(5), 5)
        XCTAssertEqual(BridgeRouter.resolvedHistoryLimit(-3), 0)     // floor
        XCTAssertEqual(BridgeRouter.resolvedHistoryLimit(9999), 200) // ceiling
    }

    // MARK: id variants echoed through

    func testExplicitNullIdCollapsesToNil() {
        // The tolerant envelope treats an explicit `"id":null` the same as an
        // absent id (both correlate to nothing) — a defensible simplification.
        if case let .intent(.status(id)) = BridgeRouter.route(line: line(#"{"id":null,"method":"status"}"#), hasHandshaken: true) {
            XCTAssertNil(id)
        } else { XCTFail("expected status intent") }
    }

    func testStringIdPreserved() {
        if case let .intent(.status(id)) = BridgeRouter.route(line: line(#"{"id":"req-42","method":"status"}"#), hasHandshaken: true) {
            XCTAssertEqual(id, .string("req-42"))
        } else { XCTFail("expected status intent") }
    }
}
