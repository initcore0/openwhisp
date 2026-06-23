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

/// Platform-agnostic text-insertion seam (Phase 2.5 core extraction).
///
/// AppState depends on this protocol instead of the concrete macOS `TextInserter`
/// (Accessibility + Cmd+V), so a port supplies its own implementation (Windows:
/// UI Automation `ValuePattern`/`TextPattern` + `SendInput` Ctrl+V; clipboard via
/// Win32). Both calls are fire-and-forget and FIFO-ordered by the implementation
/// so rapid live-chunk insertions stay in order.
protocol TextOutput: AnyObject {
    /// Insert `text` into the focused app using `mode`, optionally restoring the
    /// prior clipboard after a paste.
    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool)
    /// Set the clipboard, ordered behind any in-flight insertions.
    func setClipboard(_ text: String)
}
