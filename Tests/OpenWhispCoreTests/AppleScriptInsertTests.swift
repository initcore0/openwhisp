import XCTest
@testable import OpenWhispCore

/// The AppleScript keystroke insert method (MAK-42) embeds an UNTRUSTED transcript
/// into script source. These tests pin the escaping so quotes / backslashes /
/// newlines / unicode in a transcript can never break the script or inject code.
final class AppleScriptInsertTests: XCTestCase {

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(AppleScriptInsert.escapeStringLiteral("hello world"),
                       "hello world")
    }

    func testDoubleQuotesAreEscaped() {
        // A bare `"` would terminate the AppleScript literal early.
        XCTAssertEqual(AppleScriptInsert.escapeStringLiteral(#"say "hi""#),
                       #"say \"hi\""#)
    }

    func testBackslashIsEscaped() {
        XCTAssertEqual(AppleScriptInsert.escapeStringLiteral(#"a\b"#),
                       #"a\\b"#)
    }

    func testBackslashEscapedBeforeQuoteSoNoDoubleEscape() {
        // Order matters: escaping the quote inserts a backslash; if backslash
        // escaping ran AFTER, it would double that inserted backslash. Input
        // `\"` must become `\\\"` (escaped backslash + escaped quote), NOT `\\\\"`.
        XCTAssertEqual(AppleScriptInsert.escapeStringLiteral(#"\""#),
                       #"\\\""#)
    }

    func testNewlinesPassThroughLiterally() {
        // A real newline is valid inside an AppleScript double-quoted string and is
        // reproduced by keystroke — it must NOT be altered or escaped.
        XCTAssertEqual(AppleScriptInsert.escapeStringLiteral("line1\nline2"),
                       "line1\nline2")
    }

    func testUnicodeAndEmojiPassThrough() {
        let s = "café — naïve 日本語 🎤"
        XCTAssertEqual(AppleScriptInsert.escapeStringLiteral(s), s)
    }

    func testInjectionAttemptIsNeutralized() {
        // A transcript trying to close the string and run its own command stays
        // INSIDE the literal because both the quote and any backslash are escaped.
        let evil = #""" & (do shell script "rm -rf ~") & """#
        let escaped = AppleScriptInsert.escapeStringLiteral(evil)
        // The guarantee: every double-quote in the output is preceded by a
        // backslash, so none can terminate the enclosing literal and break out.
        let chars = Array(escaped)
        for (i, c) in chars.enumerated() where c == "\"" {
            XCTAssertTrue(i > 0 && chars[i - 1] == "\\",
                          "unescaped quote at index \(i)")
        }
    }

    func testKeystrokeSizeGuard() {
        // keystroke types synchronously at keyboard speed — over-long transcripts
        // must be refused so the caller falls back to the instant paste path.
        XCTAssertTrue(AppleScriptInsert.isKeystrokeSized(""))
        XCTAssertTrue(AppleScriptInsert.isKeystrokeSized(
            String(repeating: "a", count: AppleScriptInsert.maxKeystrokeLength)))
        XCTAssertFalse(AppleScriptInsert.isKeystrokeSized(
            String(repeating: "a", count: AppleScriptInsert.maxKeystrokeLength + 1)))
    }

    func testFullScriptWrapsEscapedLiteralInKeystroke() {
        let script = AppleScriptInsert.keystrokeScript(for: #"a"b"#)
        XCTAssertTrue(script.contains(#"keystroke "a\"b""#))
        XCTAssertTrue(script.contains(#"tell application "System Events""#))
        XCTAssertTrue(script.contains("end tell"))
    }
}
