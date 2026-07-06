import XCTest
@testable import OpenWhispCore

final class BridgeWireTests: XCTestCase {

    // MARK: Version negotiation (reject-from-the-future, ConfigBundle precedent)

    func testNegotiateEqualVersionReturnsCurrent() throws {
        let v = try BridgeWire.negotiatedProtocolVersion(clientProtocolVersion: BridgeWire.protocolVersion)
        XCTAssertEqual(v, BridgeWire.protocolVersion)
    }

    func testNegotiateOlderClientReturnsClientVersion() throws {
        // A client one version behind negotiates down to the shared subset.
        let older = BridgeWire.protocolVersion - 1
        if older >= 1 {
            let v = try BridgeWire.negotiatedProtocolVersion(clientProtocolVersion: older)
            XCTAssertEqual(v, older)
        }
    }

    func testNegotiateNewerClientThrowsUnsupported() {
        XCTAssertThrowsError(
            try BridgeWire.negotiatedProtocolVersion(clientProtocolVersion: BridgeWire.protocolVersion + 5)
        ) { error in
            XCTAssertEqual(
                error as? BridgeWire.NegotiationError,
                .unsupportedVersion(client: BridgeWire.protocolVersion + 5, supported: BridgeWire.protocolVersion)
            )
        }
    }

    // MARK: Envelope + id round-trips

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testRPCIDVariantsRoundTrip() throws {
        XCTAssertEqual(try roundTrip(BridgeWire.RPCID.number(42)), .number(42))
        XCTAssertEqual(try roundTrip(BridgeWire.RPCID.string("abc")), .string("abc"))
        XCTAssertEqual(try roundTrip(BridgeWire.RPCID.null), .null)
    }

    func testRPCIDDecodesFromRawJSON() throws {
        func decode(_ json: String) throws -> BridgeWire.RPCID {
            try JSONDecoder().decode(BridgeWire.RPCID.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode("7"), .number(7))
        XCTAssertEqual(try decode("\"id-7\""), .string("id-7"))
        XCTAssertEqual(try decode("null"), .null)
        XCTAssertThrowsError(try decode("{}"))
    }

    func testRequestEnvelopePeekIgnoresParams() throws {
        // The server first decodes only id+method; a params object of any shape
        // must not break the peek.
        let line = Data(#"{"jsonrpc":"2.0","id":3,"method":"dictate","params":{"prompt":"hi","timeoutSeconds":45}}"#.utf8)
        let env = try JSONDecoder().decode(BridgeWire.RequestEnvelope.self, from: line)
        XCTAssertEqual(env.method, "dictate")
        XCTAssertEqual(env.id, .number(3))
        XCTAssertEqual(env.jsonrpc, "2.0")

        // ...then re-decode the SAME line as a typed request.
        let req = try JSONDecoder().decode(BridgeWire.Request<BridgeWire.DictateParams>.self, from: line)
        XCTAssertEqual(req.params?.prompt, "hi")
        XCTAssertEqual(req.params?.timeoutSeconds, 45)
    }

    func testRequestEnvelopeToleratesUnknownFields() throws {
        // Forward-compat: a field a newer client adds must not break decoding.
        let line = Data(#"{"jsonrpc":"2.0","id":"x","method":"status","futureField":true}"#.utf8)
        let env = try JSONDecoder().decode(BridgeWire.RequestEnvelope.self, from: line)
        XCTAssertEqual(env.method, "status")
        XCTAssertEqual(env.id, .string("x"))
    }

    func testResultResponseRoundTrips() throws {
        let resp = BridgeWire.Response(
            id: .number(9),
            result: BridgeWire.RefineResult(text: "polished")
        )
        let decoded = try roundTrip(resp)
        XCTAssertEqual(decoded.id, .number(9))
        XCTAssertEqual(decoded.result?.text, "polished")
        XCTAssertNil(decoded.error)
    }

    func testErrorResponseRoundTripsWithDomainReason() throws {
        let resp = BridgeWire.Response<BridgeWire.RefineResult>(
            id: .number(9),
            error: .domain(.llmUnavailable, message: "no model configured", originalText: "raw text")
        )
        let decoded = try roundTrip(resp)
        XCTAssertNil(decoded.result)
        XCTAssertEqual(decoded.error?.code, BridgeWire.ErrorObject.serverError)
        XCTAssertEqual(decoded.error?.data?.reason, .llmUnavailable)
        XCTAssertEqual(decoded.error?.data?.originalText, "raw text")
    }

    // MARK: Payload round-trips + wire-key stability

    func testHelloRoundTrip() throws {
        let params = BridgeWire.HelloParams(
            protocolVersion: 1, clientName: "claude-code", clientVersion: "2.1.0",
            parentProcess: "node"
        )
        XCTAssertEqual(try roundTrip(params), params)

        let result = BridgeWire.HelloResult(
            protocolVersion: 1, appVersion: "0.9.0",
            capabilities: [BridgeWire.Capability.dictate, BridgeWire.Capability.refine, BridgeWire.Capability.history],
            clientId: "c-1", consent: .granted
        )
        XCTAssertEqual(try roundTrip(result), result)
    }

    func testHelloConsentScopesRoundTripAndAdditive() throws {
        // The per-scope posture map round-trips...
        let result = BridgeWire.HelloResult(
            protocolVersion: 1, appVersion: "0.9.0", capabilities: [],
            clientId: "c-1", consent: .pending,
            consentScopes: ["dictate": .granted, "history": .pending, "refine": .denied]
        )
        XCTAssertEqual(try roundTrip(result), result)

        // ...and is ADDITIVE: a hello from an older server (no consentScopes key)
        // still decodes, with the map nil.
        let oldWire = Data("""
        {"protocolVersion":1,"appVersion":"0.8.0","capabilities":[],"clientId":"c","consent":"granted"}
        """.utf8)
        let decoded = try JSONDecoder().decode(BridgeWire.HelloResult.self, from: oldWire)
        XCTAssertEqual(decoded.consent, .granted)
        XCTAssertNil(decoded.consentScopes)
    }

    func testDictateResultOmitsCancel() {
        // Compile-time guarantee that DictateEnd has no `cancelled` case — a
        // cancelled dictate can only surface as an error, never a result.
        XCTAssertEqual(Set(["user", "timeout", "stop"]),
                       Set([BridgeWire.DictateEnd.user, .timeout, .stop].map(\.rawValue)))
    }

    func testStatusResultRoundTrip() throws {
        let s = BridgeWire.StatusResult(
            appVersion: "0.9.0", engine: "whispercpp", model: "base.en",
            sessionActive: false, llmConfigured: true, llmProvider: "local",
            sendsTextToCloud: false, historyEnabled: true
        )
        XCTAssertEqual(try roundTrip(s), s)
    }

    func testMethodRawValuesAreStable() {
        XCTAssertEqual(BridgeWire.Method.hello.rawValue, "bridge.hello")
        XCTAssertEqual(BridgeWire.Method.dictateCancel.rawValue, "dictate.cancel")
        XCTAssertEqual(BridgeWire.Method.historyList.rawValue, "history.list")
        XCTAssertEqual(BridgeWire.Method(rawValue: "refine"), .refine)
        XCTAssertNil(BridgeWire.Method(rawValue: "nope"))
    }

    func testDefaultsAndCaps() {
        XCTAssertEqual(BridgeWire.DictateParams.defaultTimeoutSeconds, 60)
        XCTAssertEqual(BridgeWire.DictateParams.maxTimeoutSeconds, 300)
        XCTAssertEqual(BridgeWire.HistoryListParams.defaultLimit, 20)
        XCTAssertEqual(BridgeWire.HistoryListParams.maxLimit, 200)
        XCTAssertEqual(BridgeWire.maxFrameBytes, 1 << 20)
    }

    // MARK: History date coding (ISO-8601 boundary)

    func testHistoryEntryDateIsISO8601String() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000) // fixed instant
        let iso = BridgeWire.iso8601String(from: when)
        let entry = BridgeWire.HistoryEntryDTO(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!,
            text: "hello", date: iso, appBundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack", initiator: "user"
        )
        let decoded = try roundTrip(entry)
        XCTAssertEqual(decoded, entry)
        // The wire date parses back to (approximately) the same instant.
        let parsed = BridgeWire.date(fromISO8601: decoded.date)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001)
    }

    func testHistoryListResultRoundTrip() throws {
        let entry = BridgeWire.HistoryEntryDTO(
            id: UUID(), text: "note", date: BridgeWire.iso8601String(from: Date(timeIntervalSince1970: 0)),
            appBundleID: nil, appName: nil, initiator: "agent"
        )
        let result = BridgeWire.HistoryListResult(entries: [entry])
        XCTAssertEqual(try roundTrip(result), result)
    }

    // MARK: Notification shape (no id)

    func testNotificationHasNoIdOnTheWire() throws {
        let note = BridgeWire.Notification(
            method: BridgeWire.Notify.dictateState,
            params: BridgeWire.DictateStateParams(state: .listening)
        )
        let json = try JSONEncoder().encode(note)
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertNil(obj?["id"], "notifications must not carry an id")
        XCTAssertEqual(obj?["method"] as? String, "dictate.state")
    }

    // MARK: Display sanitation (consent window + overlay attribution)

    func testSanitizedForDisplayStripsControlAndBidi() {
        // Newlines collapse, C0/C1 controls and bidi overrides are stripped — an
        // agent-supplied name/prompt can't reshape OpenWhisp's own UI text.
        XCTAssertEqual(BridgeWire.sanitizedForDisplay("a\nb", maxLength: 60), "a b")
        XCTAssertEqual(BridgeWire.sanitizedForDisplay("a\tb\u{07}c", maxLength: 60), "abc")
        XCTAssertEqual(BridgeWire.sanitizedForDisplay("a\u{202E}bc", maxLength: 60), "abc")
    }

    func testSanitizedForDisplayCollapsesUnicodeLineBreaks() {
        // U+2028/U+2029/NEL are mandatory breaks for CoreText — they must
        // collapse like \n or a prompt could inject lines that render as
        // OpenWhisp's own voice in the overlay/consent UI.
        XCTAssertEqual(BridgeWire.sanitizedForDisplay("a\u{2028}b", maxLength: 60), "a b")
        XCTAssertEqual(BridgeWire.sanitizedForDisplay("a\u{2029}b", maxLength: 60), "a b")
        XCTAssertEqual(BridgeWire.sanitizedForDisplay("a\u{85}b", maxLength: 60), "a b")
    }

    func testSanitizedForDisplayTrimsAndCaps() {
        XCTAssertEqual(BridgeWire.sanitizedForDisplay("  hi  ", maxLength: 60), "hi")
        XCTAssertEqual(BridgeWire.sanitizedForDisplay(String(repeating: "x", count: 70), maxLength: 60),
                       String(repeating: "x", count: 60) + "…")
        XCTAssertEqual(BridgeWire.sanitizedForDisplay("\u{202E}\n ", maxLength: 60), "")
    }

    // MARK: Socket location (the server↔client discovery contract)

    func testSocketLocationContract() {
        XCTAssertEqual(BridgeWire.SocketLocation.socketFileName, "agent.sock")
        XCTAssertEqual(BridgeWire.SocketLocation.pointerFileName, "agent.sock.path")
        XCTAssertTrue(BridgeWire.SocketLocation.defaultSocketPath().hasSuffix("OpenWhisp/agent.sock"))
    }
}
