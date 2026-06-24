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
