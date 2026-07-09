import XCTest
@testable import OpenWhispCore

/// Tests for the pure webhook output-target core (MAK-14): the JSON body builder,
/// the `URLRequest` builder, the HTTP-status classifier, and `WebhookConfig`
/// Codable. Everything here is deterministic and network-free — no `URLSession`,
/// no real endpoint. The app-side `WebhookOutputTarget` (the only thing that
/// touches the network) is intentionally NOT exercised here.

final class WebhookRequestTests: XCTestCase {

    private func payload(
        _ text: String = "ship it",
        language: String = "en",
        bundleID: String? = "com.example.notes",
        isLiveChunk: Bool = false
    ) -> OutputPayload {
        OutputPayload(text: text, language: language, targetAppBundleID: bundleID, isLiveChunk: isLiveChunk)
    }

    private func config(
        url: String = "https://example.com/hook",
        headers: [String: String] = [:],
        timeout: TimeInterval = 10
    ) -> WebhookConfig {
        WebhookConfig(url: url, headers: headers, timeout: timeout)
    }

    /// Decode a built request's httpBody back into a dictionary for key/value asserts.
    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    // MARK: - JSON body shape

    func testBodyHasAllContractKeysAndValues() throws {
        let request = try WebhookRequest.build(
            payload: payload("hello world", language: "de", bundleID: "com.example.editor"),
            config: config(),
            timestamp: "2026-07-09T12:00:00Z"
        )
        let json = try bodyJSON(request)
        XCTAssertEqual(json["text"] as? String, "hello world")
        XCTAssertEqual(json["language"] as? String, "de")
        XCTAssertEqual(json["appBundleID"] as? String, "com.example.editor")
        XCTAssertEqual(json["timestamp"] as? String, "2026-07-09T12:00:00Z")
        XCTAssertEqual(json.count, 4, "exactly the four contract keys")
    }

    func testBodyOmitsAppBundleIDWhenNil() throws {
        let request = try WebhookRequest.build(
            payload: payload("no app", bundleID: nil),
            config: config(),
            timestamp: "2026-07-09T12:00:00Z"
        )
        let json = try bodyJSON(request)
        XCTAssertNil(json["appBundleID"], "a nil bundle ID is omitted, not encoded as null")
        XCTAssertEqual(json["text"] as? String, "no app")
        XCTAssertEqual(json.count, 3, "three keys when the bundle ID is unknown")
    }

    func testBodyKeyOrderIsDeterministic() throws {
        // `.sortedKeys` → the encoded byte order is stable and testable.
        let body = WebhookBody(
            text: "b", language: "en", appBundleID: "com.a", timestamp: "2026-07-09T00:00:00Z"
        )
        let string = String(data: try body.encoded(), encoding: .utf8)
        XCTAssertEqual(
            string,
            #"{"appBundleID":"com.a","language":"en","text":"b","timestamp":"2026-07-09T00:00:00Z"}"#
        )
    }

    func testBodyEncodingIsStableAcrossRuns() throws {
        // Same inputs → byte-for-byte identical output (pure, no Date()).
        let p = payload("determinism", language: "fr", bundleID: "com.x")
        let ts = "2026-07-09T09:09:09Z"
        let a = try WebhookBody(payload: p, timestamp: ts).encoded()
        let b = try WebhookBody(payload: p, timestamp: ts).encoded()
        XCTAssertEqual(a, b)
    }

    // MARK: - URLRequest construction

    func testRequestIsPOSTToConfiguredURL() throws {
        let request = try WebhookRequest.build(
            payload: payload(), config: config(url: "https://hooks.example.com/abc"),
            timestamp: "2026-07-09T12:00:00Z"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://hooks.example.com/abc")
    }

    func testRequestSetsContentTypeJSON() throws {
        let request = try WebhookRequest.build(
            payload: payload(), config: config(), timestamp: "2026-07-09T12:00:00Z"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testRequestAppliesCustomHeaders() throws {
        let request = try WebhookRequest.build(
            payload: payload(),
            config: config(headers: ["Authorization": "Bearer secret-token", "X-Source": "openwhisp"]),
            timestamp: "2026-07-09T12:00:00Z"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Source"), "openwhisp")
        // Content-Type is still present alongside the custom headers.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testRequestSetsTimeout() throws {
        let request = try WebhookRequest.build(
            payload: payload(), config: config(timeout: 3.5), timestamp: "2026-07-09T12:00:00Z"
        )
        XCTAssertEqual(request.timeoutInterval, 3.5, accuracy: 0.0001)
    }

    func testRequestTrimsWhitespaceInURL() throws {
        let request = try WebhookRequest.build(
            payload: payload(), config: config(url: "  https://example.com/hook  "),
            timestamp: "2026-07-09T12:00:00Z"
        )
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/hook")
    }

    // MARK: - Invalid / empty URL → no request, fail open

    func testEmptyURLThrowsInvalidURL() {
        XCTAssertThrowsError(
            try WebhookRequest.build(payload: payload(), config: config(url: ""), timestamp: "t")
        ) { error in
            XCTAssertEqual(error as? WebhookRequest.BuildError, .invalidURL(""))
        }
    }

    func testWhitespaceOnlyURLThrowsInvalidURL() {
        XCTAssertThrowsError(
            try WebhookRequest.build(payload: payload(), config: config(url: "   "), timestamp: "t")
        )
    }

    func testRelativeOrSchemelessURLThrowsInvalidURL() {
        // No scheme/host → not a valid absolute endpoint → no request built.
        XCTAssertThrowsError(
            try WebhookRequest.build(payload: payload(), config: config(url: "not a url"), timestamp: "t")
        )
        XCTAssertThrowsError(
            try WebhookRequest.build(payload: payload(), config: config(url: "/just/a/path"), timestamp: "t")
        )
    }

    func testInvalidURLReasonIsHumanReadable() {
        XCTAssertEqual(WebhookRequest.BuildError.invalidURL("").reason, "invalid webhook URL: (empty)")
        XCTAssertEqual(
            WebhookRequest.BuildError.invalidURL("nope").reason,
            "invalid webhook URL: nope"
        )
    }

    // MARK: - Status classifier

    func testClassify2xxIsDelivered() {
        XCTAssertEqual(WebhookRequest.classify(statusCode: 200), .delivered)
        XCTAssertEqual(WebhookRequest.classify(statusCode: 201), .delivered)
        XCTAssertEqual(WebhookRequest.classify(statusCode: 204), .delivered)
        XCTAssertEqual(WebhookRequest.classify(statusCode: 299), .delivered)
    }

    func testClassifyNon2xxIsFallbackWithReason() {
        for code in [400, 401, 404, 429, 500, 502, 503] {
            let outcome = WebhookRequest.classify(statusCode: code)
            guard case .failedFallback(let reason) = outcome else {
                return XCTFail("HTTP \(code) should fall back, got \(outcome)")
            }
            XCTAssertTrue(reason.contains("\(code)"), "reason should name the status: \(reason)")
        }
    }

    func testClassifyZeroOrNegativeIsFallback() {
        // 0 is the app-side sentinel for "no HTTP response" (network error/timeout).
        guard case .failedFallback(let reason) = WebhookRequest.classify(statusCode: 0) else {
            return XCTFail("status 0 should fall back")
        }
        XCTAssertFalse(reason.isEmpty)
        if case .delivered = WebhookRequest.classify(statusCode: -1) {
            XCTFail("a negative status must never be reported as delivered")
        }
    }

    // MARK: - WebhookConfig Codable

    func testWebhookConfigCodableRoundTrips() throws {
        let original = WebhookConfig(
            url: "https://n8n.example.com/webhook/xyz",
            headers: ["Authorization": "Bearer abc", "X-Env": "prod"],
            timeout: 7.5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WebhookConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testWebhookConfigDefaultsAreApplied() {
        let c = WebhookConfig(url: "https://example.com/hook")
        XCTAssertTrue(c.headers.isEmpty)
        XCTAssertEqual(c.timeout, WebhookConfig.defaultTimeout)
    }
}
