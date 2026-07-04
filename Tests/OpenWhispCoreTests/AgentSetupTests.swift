import XCTest
@testable import OpenWhispCore

final class AgentSetupTests: XCTestCase {

    // MARK: - CLAUDE.md append

    func testAppendToMissingFileCreatesLine() {
        let out = AgentSetup.claudeMdAppending(to: nil)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("openwhisp_dictate"))
        XCTAssertTrue(out!.contains(AgentSetup.claudeMarker))
        XCTAssertTrue(out!.hasSuffix("\n"))
    }

    func testAppendToEmptyFileCreatesLine() {
        let out = AgentSetup.claudeMdAppending(to: "")
        XCTAssertEqual(out, AgentSetup.claudeGuidanceLine() + "\n")
    }

    func testAppendPreservesExistingContent() {
        let existing = "# My rules\n\nBe concise.\n"
        let out = AgentSetup.claudeMdAppending(to: existing)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.hasPrefix(existing), "existing content must be preserved verbatim")
        XCTAssertTrue(out!.contains(AgentSetup.claudeMarker))
    }

    func testAppendIsIdempotentOnMarker() {
        // Second run: the marker is already present → no-op (nil).
        let first = AgentSetup.claudeMdAppending(to: "# rules\n")!
        let second = AgentSetup.claudeMdAppending(to: first)
        XCTAssertNil(second, "re-running setup must not duplicate the guidance line")
    }

    func testAppendIdempotentEvenIfProseEdited() {
        // The user kept the marker but reworded the sentence — still a no-op.
        let edited = "# rules\n\nAsk me by voice please. \(AgentSetup.claudeMarker)\n"
        XCTAssertNil(AgentSetup.claudeMdAppending(to: edited))
    }

    func testAppendInsertsGapWhenNoTrailingNewline() {
        let existing = "no trailing newline"
        let out = AgentSetup.claudeMdAppending(to: existing)!
        XCTAssertTrue(out.hasPrefix("no trailing newline\n\n"))
    }

    // MARK: - claude mcp add args

    func testClaudeMcpAddArguments() {
        let args = AgentSetup.claudeMcpAddArguments(binaryPath: "/Apps/OpenWhisp.app/Contents/Helpers/openwhisp")
        XCTAssertEqual(args, ["mcp", "add", "openwhisp", "--",
                              "/Apps/OpenWhisp.app/Contents/Helpers/openwhisp", "mcp"])
    }

    // MARK: - Cursor mcp.json merge

    private func decode(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Unwrap the `.write` payload, failing the test on any other outcome.
    private func writtenData(_ result: AgentSetup.CursorMergeResult,
                             file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard case .write(let data) = result else {
            XCTFail("expected .write, got \(result)", file: file, line: line)
            return Data()
        }
        return data
    }

    func testCursorFreshFileWritesServer() {
        let out = writtenData(AgentSetup.cursorMcpJSON(existing: nil, binaryPath: "/bin/openwhisp"))
        let servers = decode(out)["mcpServers"] as? [String: Any]
        let ow = servers?["openwhisp"] as? [String: Any]
        XCTAssertEqual(ow?["command"] as? String, "/bin/openwhisp")
        XCTAssertEqual(ow?["args"] as? [String], ["mcp"])
        // .withoutEscapingSlashes: paths must stay human-readable in the config.
        XCTAssertTrue(String(data: out, encoding: .utf8)!.contains("/bin/openwhisp"))
    }

    func testCursorPreservesOtherServers() {
        let existing = """
        { "mcpServers": { "other": { "command": "/x", "args": ["y"] } } }
        """.data(using: .utf8)!
        let out = writtenData(AgentSetup.cursorMcpJSON(existing: existing, binaryPath: "/bin/openwhisp"))
        let servers = decode(out)["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?["other"], "existing servers must be preserved")
        XCTAssertNotNil(servers?["openwhisp"])
    }

    func testCursorIdempotentWhenIdentical() {
        let first = writtenData(AgentSetup.cursorMcpJSON(existing: nil, binaryPath: "/bin/openwhisp"))
        let second = AgentSetup.cursorMcpJSON(existing: first, binaryPath: "/bin/openwhisp")
        XCTAssertEqual(second, .alreadyConfigured, "identical entry → no rewrite")
    }

    func testCursorUpdatesWhenPathChanged() {
        let first = writtenData(AgentSetup.cursorMcpJSON(existing: nil, binaryPath: "/old/openwhisp"))
        let second = writtenData(AgentSetup.cursorMcpJSON(existing: first, binaryPath: "/new/openwhisp"))
        let ow = (decode(second)["mcpServers"] as? [String: Any])?["openwhisp"] as? [String: Any]
        XCTAssertEqual(ow?["command"] as? String, "/new/openwhisp")
    }

    func testCursorUnparseableExistingIsRefusedNotClobbered() {
        // Cursor tolerates JSONC (comments, trailing commas); JSONSerialization
        // doesn't. An unparseable file must be REFUSED — "starting fresh" would
        // silently destroy every other server the user configured.
        let jsonc = """
        { "mcpServers": { /* my servers */ "other": { "command": "/x" }, } }
        """.data(using: .utf8)!
        XCTAssertEqual(AgentSetup.cursorMcpJSON(existing: jsonc, binaryPath: "/bin/openwhisp"),
                       .unparseable)
        let garbage = "not json at all".data(using: .utf8)!
        XCTAssertEqual(AgentSetup.cursorMcpJSON(existing: garbage, binaryPath: "/bin/openwhisp"),
                       .unparseable)
    }

    func testCursorEmptyExistingWritesFresh() {
        // An EMPTY file is not user data — writing fresh is fine.
        let out = AgentSetup.cursorMcpJSON(existing: Data(), binaryPath: "/bin/openwhisp")
        XCTAssertNotNil((decode(writtenData(out))["mcpServers"] as? [String: Any])?["openwhisp"])
    }

    // MARK: - claude mcp add command line

    func testClaudeMcpAddCommandLineMatchesArguments() {
        // The printed command is derived from the executed arguments — quoting
        // only where needed — so the two can't drift.
        XCTAssertEqual(
            AgentSetup.claudeMcpAddCommandLine(binaryPath: "/Apps/OpenWhisp.app/Contents/Helpers/openwhisp"),
            "claude mcp add openwhisp -- /Apps/OpenWhisp.app/Contents/Helpers/openwhisp mcp"
        )
        XCTAssertEqual(
            AgentSetup.claudeMcpAddCommandLine(binaryPath: "/App Store/openwhisp"),
            "claude mcp add openwhisp -- \"/App Store/openwhisp\" mcp"
        )
    }
}
