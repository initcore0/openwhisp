import XCTest
@testable import OpenWhispCore

/// Tests for the `openwhisp://` URL scheme parser — the security boundary for the
/// Raycast/Alfred launcher control surface (MAK-37). Covers the happy path (host
/// form + chained query form), parameter validation, and a battery of hostile
/// inputs that must be rejected as a whole (nothing partially executed).
final class URLSchemeTests: XCTestCase {

    private func parse(_ s: String) -> URLScheme.Parsed {
        guard let url = URL(string: s) else { return .rejected(.notOurScheme) }
        return URLScheme.parse(url)
    }

    private func commands(_ s: String) -> [URLScheme.Command]? {
        if case let .commands(c) = parse(s) { return c }
        return nil
    }

    private func rejection(_ s: String) -> URLScheme.Rejection? {
        if case let .rejected(r) = parse(s) { return r }
        return nil
    }

    // MARK: Host form — single verb

    func testRecordHostForm() {
        XCTAssertEqual(commands("openwhisp://record"), [.record])
    }

    func testPasteLastHostForm() {
        XCTAssertEqual(commands("openwhisp://paste-last-result"), [.pasteLast])
    }

    func testRefineHostFormWithInstruction() {
        // "make it formal" percent-encoded.
        XCTAssertEqual(
            commands("openwhisp://refine?instruction=make%20it%20formal"),
            [.refine(instruction: "make it formal", text: nil)]
        )
    }

    func testRefineHostFormWithTextAndInstruction() {
        XCTAssertEqual(
            commands("openwhisp://refine?instruction=fix&text=helo%20wrld"),
            [.refine(instruction: "fix", text: "helo wrld")]
        )
    }

    func testSwitchModeHostFormWithKey() {
        XCTAssertEqual(commands("openwhisp://switch-mode?key=email"), [.switchMode(key: "email")])
    }

    func testActivateModeHostFormWithKey() {
        XCTAssertEqual(commands("openwhisp://activate-mode?key=slack"), [.activateMode(key: "slack")])
    }

    // MARK: Scheme + verb are case-insensitive

    func testSchemeCaseInsensitive() {
        XCTAssertEqual(commands("OpenWhisp://record"), [.record])
    }

    func testVerbCaseInsensitive() {
        XCTAssertEqual(commands("openwhisp://RECORD"), [.record])
    }

    // MARK: Chained query form

    func testChainedActivateThenRecord() {
        // "activate my email mode, then start recording" — the point of chaining.
        XCTAssertEqual(
            commands("openwhisp://?switch-mode=email&record"),
            [.switchMode(key: "email"), .record]
        )
    }

    func testChainedPreservesOrder() {
        XCTAssertEqual(
            commands("openwhisp://?record&paste-last-result"),
            [.record, .pasteLast]
        )
    }

    func testChainedRefineViaParamKey() {
        // refine's instruction supplied as a following param key.
        XCTAssertEqual(
            commands("openwhisp://?refine&instruction=tighten"),
            [.refine(instruction: "tighten", text: nil)]
        )
    }

    // MARK: Rejections — wrong scheme / no command

    func testWrongSchemeRejected() {
        XCTAssertEqual(rejection("https://example.com/record"), .notOurScheme)
    }

    func testEmptyURLRejected() {
        XCTAssertEqual(rejection("openwhisp://"), .noCommand)
    }

    func testQueryWithNoVerbKeysRejected() {
        // Only parameter keys, no verb → no command.
        XCTAssertEqual(rejection("openwhisp://?instruction=foo&key=bar"), .noCommand)
    }

    // MARK: Rejections — unknown verb (the allow-list is the boundary)

    func testUnknownVerbHostFormRejected() {
        XCTAssertEqual(rejection("openwhisp://frobnicate"), .unknownVerb("frobnicate"))
    }

    func testInjectionishVerbRejected() {
        // Anything that isn't an allow-listed verb is rejected — no arbitrary exec.
        guard case .unknownVerb = rejection("openwhisp://exec?cmd=rm%20-rf%20~") else {
            return XCTFail("expected unknownVerb rejection")
        }
    }

    // MARK: Rejections — missing required parameters

    func testRefineWithoutInstructionRejected() {
        XCTAssertEqual(
            rejection("openwhisp://refine"),
            .missingParameter(verb: .refine, parameter: "instruction")
        )
    }

    func testRefineWithBlankInstructionRejected() {
        // Whitespace-only counts as absent.
        XCTAssertEqual(
            rejection("openwhisp://refine?instruction=%20%20"),
            .missingParameter(verb: .refine, parameter: "instruction")
        )
    }

    func testSwitchModeWithoutKeyRejected() {
        XCTAssertEqual(
            rejection("openwhisp://switch-mode"),
            .missingParameter(verb: .switchMode, parameter: "key")
        )
    }

    // MARK: Rejections — invalid parameters (opaque data, never code)

    func testKeyWithPathSeparatorRejected() {
        // A key must read like an identifier, not a path — defense in depth.
        XCTAssertEqual(
            rejection("openwhisp://switch-mode?key=..%2F..%2Fetc%2Fpasswd"),
            .invalidParameter(verb: .switchMode, parameter: "key")
        )
    }

    func testKeyWithBackslashRejected() {
        XCTAssertEqual(
            rejection("openwhisp://activate-mode?key=a%5Cb"),
            .invalidParameter(verb: .activateMode, parameter: "key")
        )
    }

    func testKeyWithNewlineRejected() {
        XCTAssertEqual(
            rejection("openwhisp://switch-mode?key=a%0Ab"),
            .invalidParameter(verb: .switchMode, parameter: "key")
        )
    }

    func testOverlongInstructionRejected() {
        let long = String(repeating: "a", count: URLScheme.maxValueLength + 1)
        XCTAssertEqual(
            rejection("openwhisp://refine?instruction=\(long)"),
            .invalidParameter(verb: .refine, parameter: "instruction")
        )
    }

    func testMaxLengthInstructionAccepted() {
        let atCap = String(repeating: "a", count: URLScheme.maxValueLength)
        XCTAssertEqual(
            commands("openwhisp://refine?instruction=\(atCap)"),
            [.refine(instruction: atCap, text: nil)]
        )
    }

    // MARK: Rejections — chaining limits

    func testTooManyChainedCommandsRejected() {
        // maxChainedCommands+1 record verbs. Query keys must be distinct to survive
        // URLComponents, so alternate record / paste-last-result... but both would
        // dedupe by position, not name — build distinct keys via repetition using
        // the two no-arg verbs interleaved isn't enough. Use enough allow-listed
        // verbs by repeating record; URLComponents keeps duplicate query items.
        let verbs = Array(repeating: "record", count: URLScheme.maxChainedCommands + 1).joined(separator: "&")
        XCTAssertEqual(rejection("openwhisp://?\(verbs)"), .tooManyCommands)
    }

    func testChainAtLimitAccepted() {
        let verbs = Array(repeating: "record", count: URLScheme.maxChainedCommands).joined(separator: "&")
        XCTAssertEqual(commands("openwhisp://?\(verbs)")?.count, URLScheme.maxChainedCommands)
    }

    // MARK: All allow-listed verbs are covered

    func testEveryVerbParsesInHostForm() {
        // A guard that adding a Verb without a host-form path is caught.
        for verb in URLScheme.Verb.allCases {
            let query: String
            switch verb {
            case .record, .pasteLast:     query = ""
            case .refine:                 query = "?instruction=x"
            case .switchMode, .activateMode: query = "?key=x"
            }
            let parsed = parse("openwhisp://\(verb.rawValue)\(query)")
            guard case .commands = parsed else {
                return XCTFail("verb \(verb.rawValue) failed to parse: \(parsed)")
            }
        }
    }
}
