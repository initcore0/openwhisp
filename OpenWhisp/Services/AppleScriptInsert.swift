import Foundation

/// Pure builder for the AppleScript that inserts a transcript via System Events'
/// `keystroke` command — the third selectable insert method (MAK-42).
///
/// AppleScript / System Events `keystroke` is the fallback for apps that mangle
/// the CGEvent ⌘V paste AND don't expose a settable AX selected-text attribute
/// (many Electron apps, VNC / remote-desktop windows, non-QWERTY keyboard layouts
/// where synthesized ⌘V lands on the wrong physical key). System Events types the
/// characters as if from the keyboard, which those surfaces accept.
///
/// The transcript is UNTRUSTED text. It is NEVER concatenated into the script
/// source — a stray `"` or `\` in a transcript would otherwise break the script
/// (or, worse, inject script). Instead the script declares the text as a single
/// escaped AppleScript string LITERAL, built by `escapeStringLiteral`, and hands
/// that literal to `keystroke`. Only two characters are special inside an
/// AppleScript double-quoted string — `\` and `"` — so escaping is exactly those
/// two; every other byte (newlines, unicode, emoji) is carried verbatim by the
/// literal and reproduced by `keystroke`.
///
/// Foundation-only (pure string building) so it lives in OpenWhispCore and the
/// escaping is unit-tested without ever running osascript. `NSAppleScript`
/// execution stays in the app-only `TextInserter`.
enum AppleScriptInsert {

    /// The longest transcript we'll type via `keystroke`. System Events types at
    /// keyboard speed, synchronously, with no way to interrupt — an unbounded
    /// transcript could keep "typing" for a very long time. Beyond this the caller
    /// must fall back to paste (instant, with its own clipboard safety net).
    static let maxKeystrokeLength = 3000

    /// Whether `text` is small enough to type via `keystroke`
    /// (see `maxKeystrokeLength`); anything larger should be pasted instead.
    static func isKeystrokeSized(_ text: String) -> Bool {
        text.count <= maxKeystrokeLength
    }

    /// Escape `text` so it is a safe AppleScript double-quoted string LITERAL
    /// (WITHOUT the surrounding quotes — the caller wraps it). Inside an
    /// AppleScript `"..."` literal only backslash and double-quote need escaping;
    /// backslash MUST be escaped first so the quote-escape's own backslash isn't
    /// doubled. All other characters (newlines, tabs, unicode, emoji) pass through
    /// literally and are reproduced verbatim.
    static func escapeStringLiteral(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        return out
    }

    /// The full AppleScript source that types `text` into the frontmost app via
    /// System Events. The transcript is embedded ONLY as the escaped literal
    /// produced by `escapeStringLiteral`, assigned to a variable and passed to
    /// `keystroke` — so no transcript byte is ever interpreted as script.
    static func keystrokeScript(for text: String) -> String {
        let literal = escapeStringLiteral(text)
        return """
        tell application "System Events"
            keystroke "\(literal)"
        end tell
        """
    }
}
