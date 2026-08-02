import Foundation

/// Pure export rendering for Scratchpad notes (MAK-96) — the `SubtitleFormatter`
/// pattern: this decides *what bytes* a note exports to and *what the file is
/// called*; the app only runs the save panel and writes the returned string.
///
/// Foundation-only, so the slug rules and the Markdown/plain-text split are pinned
/// by `swift test` rather than checked by eye in a save dialog.
public enum ScratchpadExport {

    /// The export container format.
    public enum Format: String, CaseIterable, Equatable {
        /// Markdown — the note's raw text, unchanged. Notes ARE Markdown source.
        case md
        /// Plain text — Markdown markers stripped, content preserved.
        case txt

        public var fileExtension: String { rawValue }

        public var label: String {
            switch self {
            case .md:  return "Markdown (.md)"
            case .txt: return "Plain text (.txt)"
            }
        }
    }

    /// The bytes to write for a note in a given format.
    ///
    /// `.md` is a verbatim passthrough — the note's text is already Markdown, and
    /// re-rendering it would risk lossy round-trips. `.txt` runs the same stripper
    /// the list rows use, which removes markers only.
    ///
    /// Both formats end in exactly one trailing newline (POSIX text convention),
    /// and neither ever returns nil: an empty note exports an empty file rather
    /// than failing the save.
    public static func render(note: ScratchpadNote, format: Format) -> String {
        let body: String
        switch format {
        case .md:
            body = note.text
        case .txt:
            body = ScratchpadText.strippingMarkdown(note.text)
        }
        let trimmed = body.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }

    /// The suggested file name for a note — a slug of its (Markdown-stripped) title
    /// plus the format's extension.
    ///
    /// Falls back to a `scratchpad-<epoch>` stamp when the title slugs to nothing
    /// (an empty note, or a title of only punctuation/emoji), so the save panel is
    /// never pre-filled with a bare extension.
    public static func exportFileName(for note: ScratchpadNote, format: Format) -> String {
        let slug = slugify(ScratchpadText.listTitle(for: note.text))
        let base = slug.isEmpty ? "scratchpad-\(Int(note.createdAt.timeIntervalSince1970))" : slug
        return base + "." + format.fileExtension
    }

    /// Lowercase, ASCII-safe, hyphen-separated, length-capped.
    ///
    /// Non-alphanumerics collapse to single hyphens; leading/trailing hyphens are
    /// dropped. **Unicode letters are kept** (so a Cyrillic note gets a Cyrillic
    /// file name rather than an empty slug) — APFS is fine with them.
    public static func slugify(_ title: String, limit: Int = 48) -> String {
        // "New note" is the placeholder title, not user content — treat it as empty
        // so an untitled note falls back to the timestamp form.
        guard title != "New note" else { return "" }

        var out = ""
        var pendingHyphen = false
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingHyphen && !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(ch)
                if out.count >= limit { break }
            } else {
                pendingHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
