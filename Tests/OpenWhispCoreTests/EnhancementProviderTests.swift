import XCTest
@testable import OpenWhispCore

/// Proves the *selection* logic MAK-44 wired: which provider id routes to the
/// agent-CLI refiner, and — when it does — that the persisted preset/custom fields
/// build the exact argv. The AppState glue that consumes this (`makeWholeTextRefiner`)
/// is app-only and build-verified; this pins the pure decision it delegates to.
final class EnhancementProviderTests: XCTestCase {

    // Only the agent-CLI id routes to the agent-CLI refiner. Every historical
    // provider stays on the OpenAI-service path (the default — no regression).
    func testOnlyAgentCLIIDSelectsAgentCLI() {
        XCTAssertTrue(EnhancementProvider.usesAgentCLI("agentCLI"))
        for other in ["bundled", "openai", "local", "", "AGENTCLI", "claude"] {
            XCTAssertFalse(
                EnhancementProvider.usesAgentCLI(other),
                "provider \(other) must NOT select the agent-CLI refiner"
            )
        }
    }

    // provider=agentCLI + preset=claude ⇒ the claude argv (`claude -p "<instruction>"`),
    // with the transcript nowhere in it (it goes on stdin).
    func testAgentCLIWithClaudePresetBuildsClaudeArgv() {
        let command = try! EnhancementProvider.agentCLICommand(
            presetID: "claude", customCommand: "", customArgs: [], timeout: 30
        ).get()
        XCTAssertEqual(command.executable, "claude")
        XCTAssertEqual(command.arguments, ["-p", AgentCLIProvider.defaultRefineInstruction])
    }

    // preset=codex ⇒ the codex argv. Custom fields are ignored while a built-in
    // preset is selected (they can't leak into a preset's command).
    func testAgentCLIWithCodexPresetIgnoresCustomFields() {
        let command = try! EnhancementProvider.agentCLICommand(
            presetID: "codex",
            customCommand: "evil",            // must be ignored
            customArgs: ["--do-bad-thing"],   // must be ignored
            timeout: 30
        ).get()
        XCTAssertEqual(command.executable, "codex")
        XCTAssertEqual(command.arguments, ["exec", AgentCLIProvider.defaultRefineInstruction])
    }

    // preset=custom ⇒ the user's own command + args, verbatim.
    func testAgentCLIWithCustomPresetUsesUserFields() {
        let command = try! EnhancementProvider.agentCLICommand(
            presetID: "custom",
            customCommand: "/opt/homebrew/bin/pi",
            customArgs: ["run", "--stdin"],
            timeout: 12
        ).get()
        XCTAssertEqual(command.executable, "/opt/homebrew/bin/pi")
        XCTAssertEqual(command.arguments, ["run", "--stdin"])
    }

    // The custom preset with an empty command fails closed — the app then treats the
    // provider as unconfigured (and refine keeps the original transcript).
    func testAgentCLICustomEmptyCommandFailsClosed() {
        XCTAssertEqual(
            EnhancementProvider.agentCLICommand(
                presetID: "custom", customCommand: "   ", customArgs: [], timeout: 30
            ),
            .failure(.emptyCommand)
        )
    }

    // An unknown/garbage preset id falls back to the custom fields, never to a
    // surprise built-in CLI.
    func testUnknownPresetFallsBackToCustomFields() {
        let command = try! EnhancementProvider.agentCLICommand(
            presetID: "does-not-exist",
            customCommand: "mytool",
            customArgs: ["-x"],
            timeout: 30
        ).get()
        XCTAssertEqual(command.executable, "mytool")
        XCTAssertEqual(command.arguments, ["-x"])
    }

    // Timeout is honored per selection and clamped to a >=1s floor so a 0 can't make
    // the runner kill the CLI instantly.
    func testResolveConfigHonorsAndClampsTimeout() {
        let ok = AgentCLIProvider.resolveConfig(
            presetID: "claude", customCommand: "", customArgs: [], timeout: 45
        )
        XCTAssertEqual(ok.timeout, 45)

        let clamped = AgentCLIProvider.resolveConfig(
            presetID: "claude", customCommand: "", customArgs: [], timeout: 0
        )
        XCTAssertEqual(clamped.timeout, 1.0)
    }

    // The custom-args text box (one arg per line) parses to a discrete argv, drops
    // blank lines, and keeps a spaces-containing instruction as a SINGLE arg (no
    // shell splitting — part of the injection-safety story).
    func testParseCustomArgs() {
        XCTAssertEqual(
            AgentCLIProvider.parseCustomArgs("-p\nClean this up please\n\n  \n--flag"),
            ["-p", "Clean this up please", "--flag"]
        )
        XCTAssertEqual(AgentCLIProvider.parseCustomArgs(""), [])
    }

    // Round-trip: format(parse(x)) preserves the argv (the settings field editing it).
    func testFormatCustomArgsRoundTrips() {
        let args = ["-p", "an instruction with spaces", "--json"]
        XCTAssertEqual(AgentCLIProvider.parseCustomArgs(AgentCLIProvider.formatCustomArgs(args)), args)
    }

    // Even via the selection path, a template smuggling the transcript sentinel into
    // argv is rejected — the transcript may only travel on stdin.
    func testTranscriptSentinelInCustomArgsIsRejected() {
        XCTAssertEqual(
            EnhancementProvider.agentCLICommand(
                presetID: "custom",
                customCommand: "claude",
                customArgs: ["-p", "refine: \(AgentCLIProvider.transcriptSentinel)"],
                timeout: 30
            ),
            .failure(.transcriptInArgs)
        )
    }
}
