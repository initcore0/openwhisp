import Foundation

/// How dictated text is delivered into the focused app.
///
/// - `directAX`: write at the caret / over the selection via the platform
///   accessibility API — never touches the clipboard (preserves copied content).
/// - `paste`: set the clipboard and synthesize a paste keystroke (the universal
///   fallback).
/// - `auto`: try the accessibility path, fall back to paste.
///
/// Foundation-only (just a string-backed enum) so it lives in OpenWhispCore and
/// is shared by every platform's inserter.
enum InsertionMode: String {
    case auto
    case directAX
    case paste
}

/// Result of an insertion attempt, reported back so the UI can tell the user when
/// text couldn't be placed and was left on the clipboard instead (never lost).
enum InsertionOutcome: Equatable {
    /// Text was inserted (AX) or pasted into the focused app.
    case inserted
    /// Insertion couldn't be confirmed; the text was left on the clipboard for the
    /// user to paste manually (⌘V). Surfaced in the overlay.
    case copiedToClipboard
}

/// Pure decision logic for verifying an Accessibility insert "took". Foundation-only
/// and string-based so it lives in OpenWhispCore and is unit-tested without AX.
enum InsertVerifier {
    /// After an AX set, decide whether the insert is reflected in the element's
    /// re-read value. `current` is the value read back (nil = element exposes no
    /// readable value, so we can't verify).
    ///
    /// Returns:
    ///   - `true`  → verified: the re-read value contains our text.
    ///   - `false` → contradicted: value is readable but does NOT contain our text →
    ///               AX silently failed; caller should fall back to paste.
    ///   - `nil`   → unverifiable: no readable value → trust the AX status code.
    static func axInsertReflected(expected: String, current: String?) -> Bool? {
        let needle = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        guard let current else { return nil }   // can't read → can't verify
        return current.contains(needle)
    }
}

/// Platform-agnostic text-insertion seam (Phase 2.5 core extraction).
///
/// AppState depends on this protocol instead of the concrete macOS `TextInserter`
/// (Accessibility + Cmd+V), so a port supplies its own implementation (Windows:
/// UI Automation `ValuePattern`/`TextPattern` + `SendInput` Ctrl+V; clipboard via
/// Win32). Both calls are fire-and-forget and FIFO-ordered by the implementation
/// so rapid live-chunk insertions stay in order.
protocol TextOutput: AnyObject {
    /// Insert `text` into the focused app using `mode`, optionally restoring the
    /// prior clipboard after a paste. `completion` (optional, called on the main
    /// thread) reports whether the insert was confirmed or fell back to the
    /// clipboard — live-chunk inserts pass nil.
    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool,
                completion: ((InsertionOutcome) -> Void)?)
    /// Set the clipboard, ordered behind any in-flight insertions.
    func setClipboard(_ text: String)
}

extension TextOutput {
    /// Convenience for the common fire-and-forget call (no outcome needed).
    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool) {
        insert(text, mode: mode, restoreClipboard: restoreClipboard, completion: nil)
    }
}
