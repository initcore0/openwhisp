import XCTest
@testable import OpenWhispCore

final class ScriptOutcomeTests: XCTestCase {
    private let original = "the original transcript"

    // MARK: Success

    func testSuccessfulRunUsesOutput() {
        let outcome = ScriptOutcome.resolve(
            original: original, stdout: "TRANSFORMED", exitCode: 0, timedOut: false, launchFailed: false
        )
        XCTAssertEqual(outcome, .useOutput("TRANSFORMED"))
    }

    func testStripsExactlyOneTrailingNewline() {
        // The conventional echo newline is removed; internal newlines preserved.
        XCTAssertEqual(
            ScriptOutcome.resolvedText(original: original, stdout: "a\nb\n", exitCode: 0, timedOut: false, launchFailed: false),
            "a\nb"
        )
        // CRLF also handled.
        XCTAssertEqual(
            ScriptOutcome.resolvedText(original: original, stdout: "x\r\n", exitCode: 0, timedOut: false, launchFailed: false),
            "x"
        )
        // Two trailing newlines -> only one stripped (the script meant the blank line).
        XCTAssertEqual(
            ScriptOutcome.resolvedText(original: original, stdout: "x\n\n", exitCode: 0, timedOut: false, launchFailed: false),
            "x\n"
        )
    }

    // MARK: Fail-open branches all keep the original

    func testLaunchFailureKeepsOriginal() {
        let o = ScriptOutcome.resolve(original: original, stdout: nil, exitCode: nil, timedOut: false, launchFailed: true)
        XCTAssertEqual(o, .keepOriginal(reason: "Script couldn't run"))
    }

    func testTimeoutKeepsOriginal() {
        let o = ScriptOutcome.resolve(original: original, stdout: "partial", exitCode: nil, timedOut: true, launchFailed: false)
        XCTAssertEqual(o, .keepOriginal(reason: "Script timed out"))
    }

    func testNonZeroExitKeepsOriginal() {
        let o = ScriptOutcome.resolve(original: original, stdout: "junk", exitCode: 3, timedOut: false, launchFailed: false)
        XCTAssertEqual(o, .keepOriginal(reason: "Script exited with code 3"))
    }

    func testNilExitWithoutTimeoutKeepsOriginal() {
        let o = ScriptOutcome.resolve(original: original, stdout: "x", exitCode: nil, timedOut: false, launchFailed: false)
        XCTAssertEqual(o, .keepOriginal(reason: "Script didn't finish"))
    }

    func testEmptyOutputKeepsOriginal() {
        let o = ScriptOutcome.resolve(original: original, stdout: "", exitCode: 0, timedOut: false, launchFailed: false)
        XCTAssertEqual(o, .keepOriginal(reason: "Script returned empty output"))
    }

    func testWhitespaceOnlyOutputKeepsOriginal() {
        let o = ScriptOutcome.resolve(original: original, stdout: "   \n  ", exitCode: 0, timedOut: false, launchFailed: false)
        XCTAssertEqual(o, .keepOriginal(reason: "Script returned empty output"))
    }

    func testNilStdoutWithZeroExitKeepsOriginal() {
        let o = ScriptOutcome.resolve(original: original, stdout: nil, exitCode: 0, timedOut: false, launchFailed: false)
        XCTAssertEqual(o, .keepOriginal(reason: "Script returned empty output"))
    }

    // resolvedText collapses keepOriginal cases back to the input.
    func testResolvedTextFallsBackToOriginalOnFailure() {
        XCTAssertEqual(
            ScriptOutcome.resolvedText(original: original, stdout: nil, exitCode: nil, timedOut: true, launchFailed: false),
            original
        )
    }
}

final class ScriptTimeoutKillTests: XCTestCase {
    // Happy path: setpgid took, so the child leads its own group (pgid == pid) and
    // that group is not ours. Group-kill FIRST (reap grandchildren), then the
    // direct kill as the guaranteed reaper.
    func testChildLeadsOwnGroupKillsGroupThenDirect() {
        let targets = ScriptTimeoutKill.targets(pid: 4321, resolvedPgid: 4321, ownPgid: 999)
        XCTAssertEqual(targets, [.group(4321), .direct(4321)])
        // Group target is negated for kill(2); direct is the raw pid.
        XCTAssertEqual(targets.map(\.killArg), [-4321, 4321])
        XCTAssertEqual(targets.map(\.isGroup), [true, false])
    }

    // setpgid lost the race: the child stayed in OUR group (pgid == ownPgid). We
    // must NOT group-kill (that would signal OpenWhisp itself) — only the direct
    // kill, which still reaps the main child.
    func testChildInOwnProcessGroupOnlyDirectKill() {
        let ourPgid: Int32 = 501
        let targets = ScriptTimeoutKill.targets(pid: 4321, resolvedPgid: ourPgid, ownPgid: ourPgid)
        XCTAssertEqual(targets, [.direct(4321)])
        XCTAssertFalse(targets.contains { $0.isGroup })
    }

    // Child is in some OTHER group that is neither our group nor a group it leads
    // (pgid != pid). Don't group-kill an unrelated group; direct-kill only.
    func testChildInForeignNonLedGroupOnlyDirectKill() {
        let targets = ScriptTimeoutKill.targets(pid: 4321, resolvedPgid: 7777, ownPgid: 999)
        XCTAssertEqual(targets, [.direct(4321)])
    }

    // getpgid failed (returns -1). Treat as "no reliable group" — direct-kill only.
    func testFailedPgidLookupOnlyDirectKill() {
        let targets = ScriptTimeoutKill.targets(pid: 4321, resolvedPgid: -1, ownPgid: 999)
        XCTAssertEqual(targets, [.direct(4321)])
    }

    // Defensive: an invalid pid yields no targets (never kill(0)/kill(-1)).
    func testNonPositivePidYieldsNoTargets() {
        XCTAssertEqual(ScriptTimeoutKill.targets(pid: 0, resolvedPgid: 0, ownPgid: 999), [])
        XCTAssertEqual(ScriptTimeoutKill.targets(pid: -5, resolvedPgid: -5, ownPgid: 999), [])
    }

    // The direct kill is ALWAYS present (guaranteed reaper), in every branch.
    func testDirectKillAlwaysPresentForValidPid() {
        for pgid: Int32 in [4321, 501, 7777, -1] {
            let targets = ScriptTimeoutKill.targets(pid: 4321, resolvedPgid: pgid, ownPgid: 501)
            XCTAssertTrue(targets.contains(.direct(4321)),
                          "direct kill must always be present for pgid=\(pgid)")
            XCTAssertEqual(targets.last, .direct(4321),
                           "direct kill must be last for pgid=\(pgid)")
        }
    }
}

final class ScriptPathValidatorTests: XCTestCase {
    func testEmptyPath() {
        XCTAssertEqual(
            ScriptPathValidator.validate("  ", fileExists: { _ in true }, isExecutable: { _ in true }),
            .empty
        )
    }
    func testNotFound() {
        XCTAssertEqual(
            ScriptPathValidator.validate("/x", fileExists: { _ in false }, isExecutable: { _ in false }),
            .notFound
        )
    }
    func testNotExecutable() {
        XCTAssertEqual(
            ScriptPathValidator.validate("/x", fileExists: { _ in true }, isExecutable: { _ in false }),
            .notExecutable
        )
    }
    func testOK() {
        XCTAssertEqual(
            ScriptPathValidator.validate("/x", fileExists: { _ in true }, isExecutable: { _ in true }),
            .ok
        )
    }
    func testTrimsPathBeforeValidating() {
        var checkedPath: String?
        _ = ScriptPathValidator.validate("  /usr/bin/tr  ",
            fileExists: { p in checkedPath = p; return true },
            isExecutable: { _ in true })
        XCTAssertEqual(checkedPath, "/usr/bin/tr", "path should be trimmed before the existence check")
    }
}
