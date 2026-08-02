import Foundation

/// Pure text derivations the Scratchpad list + editor chrome need (MAK-95).
///
/// The list rows show a note's title and a two-line snippet. Because notes are now
/// written (and rendered) as Markdown, the raw first line of a note is very often
/// `# Meeting — Jul 28, 2026` or `## Summary` — showing the `#` marks in a compact
/// sidebar row is noise. These helpers strip the *markers* while keeping every
/// character of the actual content, so the list reads cleanly and the underlying
/// note text is untouched.
///
/// Two hard rules, both pinned by tests:
/// - **Never lose content.** Stripping removes only marker characters
///   (`#`, `*`, `_`, `` ` ``, list bullets, blockquote `>`), never words.
/// - **Never reorder.** Line order and inline order are preserved exactly.
///
/// Foundation-only so `swift test` covers them; the SwiftUI list is a thin caller.
public enum ScratchpadText {

    // MARK: - Markdown stripping

    /// Strip Markdown *markers* from a single line, leaving its text content.
    ///
    /// Handles, in order: ATX headings (`### Title` → `Title`), blockquote markers
    /// (`> quoted` → `quoted`), unordered list bullets (`- item`, `* item`,
    /// `+ item` → `item`), ordered list markers (`1. item` → `item`), horizontal
    /// rules (`---`, `***`, `___` → empty), then inline emphasis/code markers.
    ///
    /// A line that matches nothing is returned trimmed but otherwise identical —
    /// the conservative default.
    public static func strippingMarkdown(line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "" }

        // Horizontal rule: a line of only -, * or _ (3+). Renders as no text.
        if isHorizontalRule(s) { return "" }

        // Fence markers (``` / ~~~) carry no prose.
        if s.hasPrefix("```") || s.hasPrefix("~~~") { return "" }

        // Leading block markers can nest ("> - item"); peel them until stable.
        var peeled = true
        while peeled {
            peeled = false
            if let stripped = strippingHeadingMarker(s) { s = stripped; peeled = true }
            if let stripped = strippingQuoteMarker(s) { s = stripped; peeled = true }
            if let stripped = strippingListMarker(s) { s = stripped; peeled = true }
        }

        return strippingInlineMarkers(s).trimmingCharacters(in: .whitespaces)
    }

    /// Strip Markdown markers from a whole document, line by line. Blank results
    /// from marker-only lines (fences, horizontal rules) collapse away, so a
    /// snippet never begins with empty lines.
    public static func strippingMarkdown(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { strippingMarkdown(line: String($0)) }
            .joined(separator: "\n")
    }

    // MARK: - List row derivations

    /// The title shown in the note list: the first line that has content once its
    /// Markdown markers are stripped, capped at `limit` characters with an ellipsis.
    ///
    /// Deliberately separate from `ScratchpadNote.displayTitle` (which keeps the raw
    /// first line and is part of the persisted-format-adjacent contract): this is the
    /// presentation-layer variant, so a `# Meeting — …` note titles as `Meeting — …`.
    public static func listTitle(for text: String, limit: Int = 60) -> String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map { strippingMarkdown(line: String($0)) }
            .first(where: { !$0.isEmpty }) ?? ""
        if line.isEmpty { return "New note" }
        return capped(line, limit: limit)
    }

    /// The snippet under the title: up to `maxLines` lines of stripped body text,
    /// skipping the title line itself and any blank/marker-only lines. Each line is
    /// capped so a single long paragraph can't blow out the row.
    ///
    /// Returns `""` when the note has no body beyond its title (the row then shows
    /// only the title, rather than a stray empty second line).
    public static func snippet(for text: String, maxLines: Int = 2, lineLimit: Int = 100) -> String {
        var lines: [String] = []
        var seenTitle = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = strippingMarkdown(line: String(raw))
            if stripped.isEmpty { continue }
            if !seenTitle { seenTitle = true; continue }  // that was the title line
            lines.append(capped(stripped, limit: lineLimit))
            if lines.count == maxLines { break }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Provenance

    /// The human-readable provenance line under the editor, derived purely from the
    /// note's timestamps — "Dictated 3:14 PM · typed 3:20 PM", or "New note" when the
    /// note has never been dictated or typed into.
    ///
    /// Moved out of the AppKit controller (MAK-95) so it is covered by `swift test`.
    /// The `DateFormatter` is cached: this used to allocate one per keystroke.
    public static func provenanceLine(_ note: ScratchpadNote?) -> String {
        guard let note else { return "" }
        var parts: [String] = []
        if let d = note.lastDictatedAt { parts.append("dictated \(timeFormatter.string(from: d))") }
        if let t = note.lastTypedAt { parts.append("typed \(timeFormatter.string(from: t))") }
        if parts.isEmpty { return "New note" }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// The SF Symbol that represents a note's origin in the list row. Symbols only —
    /// never an emoji or a unicode glyph (house style).
    public static func originSymbol(_ origin: ScratchpadNote.Origin) -> String? {
        switch origin {
        case .dictated: return "mic"
        case .typed:    return "keyboard"
        case .mixed:    return "mic.badge.plus"
        case .empty:    return nil
        }
    }

    /// Accessibility label for the origin glyph (VoiceOver reads this, not the symbol).
    public static func originLabel(_ origin: ScratchpadNote.Origin) -> String {
        switch origin {
        case .dictated: return "Dictated"
        case .typed:    return "Typed"
        case .mixed:    return "Dictated and typed"
        case .empty:    return "Empty"
        }
    }

    // MARK: - Internals

    /// Shared short-time formatter. Cached because the provenance line is recomputed
    /// on every edit; `DateFormatter()` construction is expensive.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func capped(_ s: String, limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    /// `---`, `***`, `___` (3 or more of a single rule character, nothing else).
    static func isHorizontalRule(_ s: String) -> Bool {
        let compact = s.filter { !$0.isWhitespace }
        guard compact.count >= 3 else { return false }
        guard let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// `#`–`######` followed by a space. Returns nil when the line is not a heading
    /// (including `#tag`, which has no space after the hashes — a P3 tag, not a heading).
    static func strippingHeadingMarker(_ s: String) -> String? {
        var hashes = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", hashes < 6 {
            hashes += 1
            idx = s.index(after: idx)
        }
        guard hashes > 0, idx < s.endIndex, s[idx] == " " else { return nil }
        // Also drop a closing run of hashes ("## Title ##").
        var body = String(s[idx...]).trimmingCharacters(in: .whitespaces)
        while body.hasSuffix("#") { body.removeLast() }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// `> quoted` (or bare `>`).
    static func strippingQuoteMarker(_ s: String) -> String? {
        guard s.hasPrefix(">") else { return nil }
        return String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// `- item` / `* item` / `+ item` / `1. item` / `2) item`.
    /// Requires the space after the marker, so `*bold*` is not mistaken for a bullet.
    static func strippingListMarker(_ s: String) -> String? {
        guard let first = s.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let rest = s.dropFirst()
            guard rest.first == " " else { return nil }
            return String(rest).trimmingCharacters(in: .whitespaces)
        }
        // Ordered: digits then '.' or ')' then a space.
        var digits = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber, digits < 9 {
            digits += 1
            idx = s.index(after: idx)
        }
        guard digits > 0, idx < s.endIndex, s[idx] == "." || s[idx] == ")" else { return nil }
        let afterPunct = s.index(after: idx)
        guard afterPunct < s.endIndex, s[afterPunct] == " " else { return nil }
        return String(s[afterPunct...]).trimmingCharacters(in: .whitespaces)
    }

    /// Remove inline emphasis / code / link markers, keeping the text between them.
    /// `[label](url)` keeps `label`. Unbalanced markers are left alone (a lone `*`
    /// in prose stays a `*`).
    static func strippingInlineMarkers(_ s: String) -> String {
        var out = strippingLinks(s)
        for marker in ["***", "___", "**", "__", "*", "_", "`"] {
            out = removingPairedMarker(out, marker: marker)
        }
        return out
    }

    /// `[label](target)` → `label`; bare `[label]` is left alone.
    static func strippingLinks(_ s: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "[") {
            guard let close = rest[open...].firstIndex(of: "]"),
                  rest.index(after: close) < rest.endIndex,
                  rest[rest.index(after: close)] == "(",
                  let paren = rest[close...].firstIndex(of: ")")
            else {
                // Not a link — emit through the '[' and continue scanning after it.
                out += rest[..<rest.index(after: open)]
                rest = rest[rest.index(after: open)...]
                continue
            }
            out += rest[..<open]
            out += rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: paren)...]
        }
        out += rest
        return out
    }

    /// Drop `marker` only when it appears an even number of times (balanced), so an
    /// asymmetric `*` in ordinary prose survives untouched.
    static func removingPairedMarker(_ s: String, marker: String) -> String {
        guard s.contains(marker) else { return s }
        let parts = s.components(separatedBy: marker)
        // n occurrences → n+1 parts. Balanced means n is even → parts.count is odd.
        guard parts.count >= 3, parts.count % 2 == 1 else { return s }
        return parts.joined()
    }
}
