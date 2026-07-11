import Foundation

/// How dictated text is delivered into the focused app.
///
/// - `directAX`: write at the caret / over the selection via the platform
///   accessibility API — never touches the clipboard (preserves copied content).
/// - `paste`: set the clipboard and synthesize a paste keystroke (the universal
///   fallback).
/// - `appleScript`: type the text via AppleScript / System Events `keystroke` —
///   for apps that mangle CGEvent ⌘V and don't expose a settable AX value
///   (Electron, VNC / remote desktop, non-QWERTY layouts). Never touches the
///   clipboard. See `AppleScriptInsert`.
/// - `auto`: try the accessibility path, fall back to paste.
///
/// Foundation-only (just a string-backed enum) so it lives in OpenWhispCore and
/// is shared by every platform's inserter.
public enum InsertionMode: String {
    case auto
    case directAX
    case paste
    case appleScript

    /// Human-readable label for the settings picker.
    public var label: String {
        switch self {
        case .auto:        return "Auto (accessibility, then paste)"
        case .directAX:    return "Accessibility (no clipboard)"
        case .paste:       return "Paste (⌘V)"
        case .appleScript: return "AppleScript keystroke (Electron / VNC / non-QWERTY)"
        }
    }

    /// Parse a stored id, falling back to `.auto` for unknown values.
    public static func from(id: String) -> InsertionMode {
        InsertionMode(rawValue: id) ?? .auto
    }
}

/// Result of an insertion attempt, reported back so the UI can tell the user when
/// text couldn't be placed and was left on the clipboard instead (never lost).
public enum InsertionOutcome: Equatable {
    /// Text was inserted (AX) or pasted into the focused app.
    case inserted
    /// Insertion couldn't be confirmed; the text was left on the clipboard for the
    /// user to paste manually (⌘V). Surfaced in the overlay.
    case copiedToClipboard
}

/// Pure decision logic for verifying an Accessibility insert "took". Foundation-only
/// and string-based so it lives in OpenWhispCore and is unit-tested without AX.
public enum InsertVerifier {
    /// After an AX set, decide whether the insert is reflected in the element's
    /// re-read value. `before` is the value read just BEFORE the set and `current`
    /// the value read after (nil = element exposes no readable value).
    ///
    /// The before-snapshot guards both directions of a bare contains() check:
    /// a value that already held the dictated phrase must not verify a set the
    /// app silently ignored (text would be dropped), and a value the app changed
    /// but transformed must not be treated as a failure (paste would duplicate).
    ///
    /// Returns:
    ///   - `true`  → verified: the value changed and now contains our text
    ///               (compared after typographic normalization, so smart-quote /
    ///               dash substitution by the app still verifies).
    ///   - `false` → contradicted: value is readable and either UNCHANGED by the
    ///               set without containing our text (AX silently failed), or
    ///               changed but emptied/shrunk without containing it (the app
    ///               reset the field — a successful insert of non-empty text
    ///               cannot shrink the value) → caller should fall back to paste.
    ///   - `nil`   → unverifiable: no readable value; value unchanged but the text
    ///               was already present before the set (can't distinguish a no-op
    ///               replacement from an ignored set); or value GREW without
    ///               containing the text even normalized (app rewrote it —
    ///               autocorrect, markdown rendering; pasting would duplicate) →
    ///               trust the AX status code.
    public static func axInsertReflected(expected: String, before: String?, current: String?) -> Bool? {
        let needle = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        guard let current else { return nil }   // can't read → can't verify
        let containsNeedle = normalize(current).contains(normalize(needle))
        if current == before {
            return containsNeedle ? nil : false
        }
        if containsNeedle { return true }
        // Changed but our text is absent: split by growth. A cleared or shrunken
        // field after a "successful" set is the discard signature — the text is
        // nowhere; paste must recover it. A grown field means the app accepted
        // the text in altered form; pasting would insert a duplicate.
        return current.count < (before?.count ?? 0) || current.isEmpty ? false : nil
    }

    /// Fold the typographic substitutions apps commonly apply to inserted text
    /// (smart quotes, dashes, ellipsis, non-breaking spaces) so they don't defeat
    /// the contains() check.
    private static func normalize(_ s: String) -> String { foldTypography(s) }

    /// Shared typographic normalization: map the smart quotes/dashes/ellipsis/NBSP an
    /// app substitutes on insert back to their plain forms. Exposed so the overlay
    /// revert's suffix match (`ReplaceLastInsertion`) folds the same way this verifier
    /// does — otherwise a smart-quoting field (Notes/Pages/Mail) defeats the match.
    public static func foldTypography(_ s: String) -> String {
        var out = s
        for (fancy, plain) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""),
                               ("\u{201D}", "\""), ("\u{2013}", "-"), ("\u{2014}", "-"),
                               ("\u{2026}", "..."), ("\u{00A0}", " ")] {
            out = out.replacingOccurrences(of: fancy, with: plain)
        }
        return out
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

    /// Attempt an in-place SWAP of the text we just inserted for `raw`, used by the
    /// overlay "revert to original" (MAK-35). Only mutates the focused field when it
    /// still ends with exactly `inserted` (via `ReplaceLastInsertion` + AX), so it
    /// can't clobber the user's own edits; otherwise it's a no-op. Reports `true`
    /// only when the replace was performed and verified — the caller keeps the raw
    /// words on the clipboard as a fallback either way. Default: no-op returning
    /// `false` (ports/fakes without AX rely on the clipboard fallback).
    func replaceLastInsertion(inserted: String, raw: String,
                              completion: @escaping (Bool) -> Void)
}

extension TextOutput {
    /// Convenience for the common fire-and-forget call (no outcome needed).
    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool) {
        insert(text, mode: mode, restoreClipboard: restoreClipboard, completion: nil)
    }

    /// Default: no in-place replace available (e.g. non-AX ports, sink targets, test
    /// doubles) — report failure so the caller falls back to the clipboard copy.
    func replaceLastInsertion(inserted: String, raw: String,
                              completion: @escaping (Bool) -> Void) {
        completion(false)
    }
}
