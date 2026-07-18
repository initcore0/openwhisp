import XCTest
@testable import OpenWhispBridgeKit
import OpenWhispCore

/// MAK-75: the MCP/CLI server-side self-derivation of workspace context (cwd + git
/// branch) with an explicit env opt-out, and the merge with client-supplied
/// context. Pure — injected environment/cwd/git so no real cwd or git subprocess.
final class WorkspaceContextTests: XCTestCase {

    func testSelfDerivesCwdAndBranchWhenEnabled() {
        let ctx = WorkspaceContext.resolved(
            explicit: nil,
            environment: [:],
            currentDirectory: "/Users/me/projects/OpenWhisp",
            gitBranchProvider: { _ in "mak-75-agent-context" })
        XCTAssertEqual(ctx?.cwd, "/Users/me/projects/OpenWhisp")
        XCTAssertEqual(ctx?.gitBranch, "mak-75-agent-context")
    }

    func testExplicitContextWinsOverSelfDerived() {
        let ctx = WorkspaceContext.resolved(
            explicit: BridgeWire.DictateContext(cwd: "/explicit/path", gitBranch: "explicit-branch",
                                                terms: ["Foo"]),
            environment: [:],
            currentDirectory: "/self/derived",
            gitBranchProvider: { _ in "self-branch" })
        XCTAssertEqual(ctx?.cwd, "/explicit/path")
        XCTAssertEqual(ctx?.gitBranch, "explicit-branch")
        XCTAssertEqual(ctx?.terms, ["Foo"])
    }

    func testExplicitTermsMergeWithSelfDerivedCwdBranch() {
        // Client passes only `terms`; server fills cwd + branch.
        let ctx = WorkspaceContext.resolved(
            explicit: BridgeWire.DictateContext(terms: ["RefineFlow"]),
            environment: [:],
            currentDirectory: "/Users/me/projects/OpenWhisp",
            gitBranchProvider: { _ in "main" })
        XCTAssertEqual(ctx?.cwd, "/Users/me/projects/OpenWhisp")
        XCTAssertEqual(ctx?.gitBranch, "main")
        XCTAssertEqual(ctx?.terms, ["RefineFlow"])
    }

    func testEnvOptOutDisablesSelfDerivation() {
        for value in ["0", "false", "off", "no", "FALSE", " Off "] {
            let ctx = WorkspaceContext.resolved(
                explicit: nil,
                environment: [WorkspaceContext.optOutEnvVar: value],
                currentDirectory: "/self/derived",
                gitBranchProvider: { _ in "self-branch" })
            XCTAssertNil(ctx, "opt-out value \(value) should suppress self-derivation")
        }
    }

    func testEnvOptOutStillHonorsExplicitContext() {
        // Opt-out suppresses only AUTO derivation; an explicit per-call context is
        // the user opting in and must still be sent.
        let ctx = WorkspaceContext.resolved(
            explicit: BridgeWire.DictateContext(cwd: "/explicit"),
            environment: [WorkspaceContext.optOutEnvVar: "0"],
            currentDirectory: "/self/derived",
            gitBranchProvider: { _ in "self-branch" })
        XCTAssertEqual(ctx?.cwd, "/explicit")
        XCTAssertNil(ctx?.gitBranch, "self-derived branch suppressed by opt-out")
    }

    func testNilWhenNothingToSend() {
        let ctx = WorkspaceContext.resolved(
            explicit: nil,
            environment: [WorkspaceContext.optOutEnvVar: "0"],
            currentDirectory: "/self/derived",
            gitBranchProvider: { _ in "b" })
        XCTAssertNil(ctx)
    }

    func testDetachedHeadBranchIsDropped() {
        // A "HEAD" (detached) or empty branch is not a usable bias term.
        let ctx = WorkspaceContext.resolved(
            explicit: nil,
            environment: [:],
            currentDirectory: "/Users/me/projects/OpenWhisp",
            gitBranchProvider: { _ in nil })   // provider returns nil on detached/failure
        XCTAssertEqual(ctx?.cwd, "/Users/me/projects/OpenWhisp")
        XCTAssertNil(ctx?.gitBranch)
    }

    // MARK: - MCP arg parsing

    func testDictateContextParsedFromMCPArgs() {
        let value: MCPWire.JSONValue = .object([
            "cwd": .string("/Users/me/OpenWhisp"),
            "gitBranch": .string("mak-75"),
            "terms": .array([.string("AppState.swift"), .integer(7), .string("RefineFlow")]),
        ])
        let ctx = MCPServer.dictateContext(from: value)
        XCTAssertEqual(ctx?.cwd, "/Users/me/OpenWhisp")
        XCTAssertEqual(ctx?.gitBranch, "mak-75")
        XCTAssertEqual(ctx?.terms, ["AppState.swift", "RefineFlow"], "non-string term dropped")
    }

    func testDictateContextNilForEmptyOrAbsent() {
        XCTAssertNil(MCPServer.dictateContext(from: nil))
        XCTAssertNil(MCPServer.dictateContext(from: .object([:])))
    }
}
