import Cocoa

/// Inserts text into the active application.
///
/// This is now a thin compatibility shim over `TextInserter`, which owns the
/// actual strategy (Accessibility direct-insert vs Cmd+V paste) and the single
/// serial queue that keeps rapid live-chunk insertions FIFO-ordered. Keeping
/// this type lets existing call sites stay unchanged while gaining the
/// clipboard-preserving AX path.
enum KeyboardSynthesizer {

    /// Insert `text` into the focused app using `mode` (default `.auto`:
    /// try Accessibility, fall back to paste). Fire-and-forget; runs off-main.
    static func typeViaPaste(
        _ text: String,
        mode: InsertionMode = .auto,
        restoreClipboard: Bool = false,
        targetApplication: NSRunningApplication? = nil
    ) {
        TextInserter.insert(
            text,
            mode: mode,
            restoreClipboard: restoreClipboard,
            targetApplication: targetApplication
        )
    }

    /// Set the clipboard, FIFO-ordered behind any in-flight insertions.
    static func setClipboard(_ text: String) {
        TextInserter.setClipboard(text)
    }
}
