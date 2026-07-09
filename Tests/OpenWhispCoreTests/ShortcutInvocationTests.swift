import XCTest
@testable import OpenWhispCore

/// Tests for the pure Shortcut invocation builders (MAK-13): the `shortcuts run`
/// argv, the `shortcuts list` output parser, and name validation. These are the
/// reliable coverage — the actual `Process` spawn lives in `ShortcutOutputTarget`
/// (app side) and is not exercised here.
final class ShortcutInvocationTests: XCTestCase {

    // MARK: - runArguments (argv builder)

    func testRunArgumentsFeedsStdinViaInputPathDash() {
        // The documented `shortcuts run <name> --input-path -` form: `-` = stdin.
        XCTAssertEqual(
            ShortcutInvocation.runArguments(name: "My Shortcut"),
            ["run", "My Shortcut", "--input-path", "-"]
        )
    }

    func testRunArgumentsKeepsNameWithSpacesAsOneArgument() {
        // Passed as one array element (Process gets literal argv, no shell) — spaces
        // do NOT split it into multiple arguments.
        let args = ShortcutInvocation.runArguments(name: "Add to Things Inbox")
        XCTAssertEqual(args?[1], "Add to Things Inbox")
        XCTAssertEqual(args?.count, 4)
    }

    func testRunArgumentsPreservesQuotesAndSpecialCharsVerbatim() {
        // No shell interpolation → quotes / $ / backticks are part of the name, not
        // escaped or stripped. This is exactly what makes the array form safe.
        let name = #"Weird "Name" $HOME `whoami` & done"#
        let args = ShortcutInvocation.runArguments(name: name)
        XCTAssertEqual(args?[1], name)
    }

    func testRunArgumentsTrimsSurroundingWhitespace() {
        // A name with stray leading/trailing whitespace is canonicalized (trimmed)
        // but interior spaces are preserved.
        XCTAssertEqual(
            ShortcutInvocation.runArguments(name: "  Note It  "),
            ["run", "Note It", "--input-path", "-"]
        )
    }

    func testRunArgumentsRejectsEmptyName() {
        XCTAssertNil(ShortcutInvocation.runArguments(name: ""))
    }

    func testRunArgumentsRejectsWhitespaceOnlyName() {
        XCTAssertNil(ShortcutInvocation.runArguments(name: "   \t \n  "))
    }

    func testRunArgumentsRejectsNameWithEmbeddedNewline() {
        // An interior newline can't name a real shortcut → invalid, not a broken arg.
        XCTAssertNil(ShortcutInvocation.runArguments(name: "line one\nline two"))
    }

    // MARK: - runCommand (full command incl. executable)

    func testRunCommandPrependsExecutablePath() {
        XCTAssertEqual(
            ShortcutInvocation.runCommand(name: "My Shortcut"),
            ["/usr/bin/shortcuts", "run", "My Shortcut", "--input-path", "-"]
        )
    }

    func testRunCommandUsesCustomExecutablePath() {
        XCTAssertEqual(
            ShortcutInvocation.runCommand(name: "X", executablePath: "/opt/bin/shortcuts"),
            ["/opt/bin/shortcuts", "run", "X", "--input-path", "-"]
        )
    }

    func testRunCommandRejectsEmptyName() {
        XCTAssertNil(ShortcutInvocation.runCommand(name: "  "))
    }

    func testExecutablePathIsTheCanonicalCLI() {
        XCTAssertEqual(ShortcutInvocation.executablePath, "/usr/bin/shortcuts")
    }

    // MARK: - normalizedName

    func testNormalizedNameTrimsAndReturnsCanonicalForm() {
        XCTAssertEqual(ShortcutInvocation.normalizedName("  Send to Slack  "), "Send to Slack")
    }

    func testNormalizedNameRejectsEmptyAndWhitespace() {
        XCTAssertNil(ShortcutInvocation.normalizedName(""))
        XCTAssertNil(ShortcutInvocation.normalizedName("    "))
        XCTAssertNil(ShortcutInvocation.normalizedName("\n\t"))
    }

    func testNormalizedNameRejectsCarriageReturnAndNewline() {
        XCTAssertNil(ShortcutInvocation.normalizedName("a\nb"))
        XCTAssertNil(ShortcutInvocation.normalizedName("a\r\nb"))
    }

    // MARK: - parseList (shortcuts list output → names)

    func testParseListReturnsNamesOnePerLine() {
        let out = "Add to Things\nStart Timer\nPost to Slack"
        XCTAssertEqual(
            ShortcutInvocation.parseList(out),
            ["Add to Things", "Start Timer", "Post to Slack"]
        )
    }

    func testParseListTrimsTrailingNewline() {
        // The CLI ends its output with a trailing newline — no phantom empty entry.
        XCTAssertEqual(
            ShortcutInvocation.parseList("One\nTwo\n"),
            ["One", "Two"]
        )
    }

    func testParseListDropsBlankAndWhitespaceOnlyLines() {
        let out = "One\n\n   \nTwo\n\t\nThree\n"
        XCTAssertEqual(ShortcutInvocation.parseList(out), ["One", "Two", "Three"])
    }

    func testParseListTrimsPerLineWhitespace() {
        XCTAssertEqual(
            ShortcutInvocation.parseList("  Padded Name  \n\tTabbed\t"),
            ["Padded Name", "Tabbed"]
        )
    }

    func testParseListHandlesCRLFLineEndings() {
        // "\r\n" is a single grapheme in Swift; components(separatedBy: .newlines)
        // must still split it (a naive split on "\n" would not).
        XCTAssertEqual(
            ShortcutInvocation.parseList("Alpha\r\nBeta\r\n"),
            ["Alpha", "Beta"]
        )
    }

    func testParseListPreservesOrderAndDuplicates() {
        // Two shortcuts can share a display name; we don't dedupe (order preserved).
        XCTAssertEqual(
            ShortcutInvocation.parseList("Dup\nOther\nDup"),
            ["Dup", "Other", "Dup"]
        )
    }

    func testParseListEmptyInputIsEmptyArray() {
        XCTAssertEqual(ShortcutInvocation.parseList(""), [])
        XCTAssertEqual(ShortcutInvocation.parseList("\n\n  \n"), [])
    }

    func testParseListNilInputIsEmptyArray() {
        // A process that produced no output (nil stdout) → empty list, not a crash.
        XCTAssertEqual(ShortcutInvocation.parseList(nil), [])
    }

    func testParseListKeepsInteriorSpacesInNames() {
        XCTAssertEqual(
            ShortcutInvocation.parseList("Log My Water Intake\n"),
            ["Log My Water Intake"]
        )
    }
}
