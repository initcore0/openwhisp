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

    func testCursorFreshFileWritesServer() {
        let out = AgentSetup.cursorMcpJSON(existing: nil, binaryPath: "/bin/openwhisp")
        XCTAssertNotNil(out)
        let root = decode(out!)
        let servers = root["mcpServers"] as? [String: Any]
        let ow = servers?["openwhisp"] as? [String: Any]
        XCTAssertEqual(ow?["command"] as? String, "/bin/openwhisp")
        XCTAssertEqual(ow?["args"] as? [String], ["mcp"])
    }

    func testCursorPreservesOtherServers() {
        let existing = """
        { "mcpServers": { "other": { "command": "/x", "args": ["y"] } } }
        """.data(using: .utf8)!
        let out = AgentSetup.cursorMcpJSON(existing: existing, binaryPath: "/bin/openwhisp")!
        let servers = decode(out)["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?["other"], "existing servers must be preserved")
        XCTAssertNotNil(servers?["openwhisp"])
    }

    func testCursorIdempotentWhenIdentical() {
        let first = AgentSetup.cursorMcpJSON(existing: nil, binaryPath: "/bin/openwhisp")!
        let second = AgentSetup.cursorMcpJSON(existing: first, binaryPath: "/bin/openwhisp")
        XCTAssertNil(second, "identical entry → no rewrite")
    }

    func testCursorUpdatesWhenPathChanged() {
        let first = AgentSetup.cursorMcpJSON(existing: nil, binaryPath: "/old/openwhisp")!
        let second = AgentSetup.cursorMcpJSON(existing: first, binaryPath: "/new/openwhisp")
        XCTAssertNotNil(second, "a changed binary path must rewrite")
        let ow = (decode(second!)["mcpServers"] as? [String: Any])?["openwhisp"] as? [String: Any]
        XCTAssertEqual(ow?["command"] as? String, "/new/openwhisp")
    }

    func testCursorMalformedExistingStartsFresh() {
        let garbage = "not json at all".data(using: .utf8)!
        let out = AgentSetup.cursorMcpJSON(existing: garbage, binaryPath: "/bin/openwhisp")
        XCTAssertNotNil(out, "malformed existing file should not throw; start fresh")
        XCTAssertNotNil((decode(out!)["mcpServers"] as? [String: Any])?["openwhisp"])
    }
}
