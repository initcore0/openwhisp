import Foundation

/// Inline `#tag` extraction for the Scratchpad (MAK-97).
///
/// Tags are **derived, never stored**: `scratchpad.json`'s format is a versioned
/// contract shared with the iOS companion, so adding a `tags` field would be a
/// migration. Instead the tag set is recomputed from the note body — which also
/// means editing the text is the only way to manage tags, and they can never drift
/// out of sync with what the note actually says.
///
/// ## What counts as a tag
///
/// `#` + at least one **letter**, where the `#` is at the start of the text or
/// preceded by a non-alphanumeric, non-`/` character. After the first letter,
/// letters, digits, `-` and `_` continue the tag.
///
/// The three negatives that motivated those rules, all pinned by tests:
/// - `#1` — issue/number references, not tags. (First char must be a letter.)
/// - `issue#5`, `C#` — mid-word `#`. (The preceding char must not be alphanumeric.)
/// - `https://example.com/#fragment` — URL fragments. (The preceding char must
///   not be `/`.)
///
/// Unicode-aware throughout: `#идея` and `#日本語` are tags, because `isLetter` is
/// a Unicode property, not an ASCII range.
public enum ScratchpadTags {

    /// Extract a note's tags: ordered by first appearance, de-duplicated,
    /// lowercased (so `#Work` and `#work` are one tag).
    public static func tags(in text: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            guard chars[i] == "#" else { i += 1; continue }

            // The character before '#' must not be alphanumeric (mid-word) or '/'
            // (a URL fragment). Start-of-text is fine.
            if i > 0 {
                let prev = chars[i - 1]
                if prev.isLetter || prev.isNumber || prev == "/" || prev == "#" {
                    i += 1
                    continue
                }
            }

            // The first tag character must be a letter — rules out "#1" and a bare "#".
            let start = i + 1
            guard start < chars.count, chars[start].isLetter else { i += 1; continue }

            var end = start
            while end < chars.count, isTagBody(chars[end]) { end += 1 }

            let tag = String(chars[start..<end]).lowercased()
            if seen.insert(tag).inserted { found.append(tag) }
            i = end
        }

        return found
    }

    /// Tags for a note.
    public static func tags(in note: ScratchpadNote) -> [String] { tags(in: note.text) }

    /// The union of every note's tags, ordered alphabetically for a stable menu.
    public static func allTags(in notes: [ScratchpadNote]) -> [String] {
        var seen = Set<String>()
        for note in notes { for tag in tags(in: note) { seen.insert(tag) } }
        return seen.sorted()
    }

    /// Every tag with the number of notes carrying it, ordered by count (descending)
    /// then alphabetically — the order the tag-filter menu shows.
    public static func tagCounts(in notes: [ScratchpadNote]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in tags(in: note) { counts[tag, default: 0] += 1 }
        }
        return counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    /// True when a note carries `tag` (compared case-insensitively).
    public static func note(_ note: ScratchpadNote, hasTag tag: String) -> Bool {
        tags(in: note).contains(tag.lowercased())
    }

    /// Letters, digits, `-` and `_` continue a tag. Everything else ends it —
    /// notably `.`, `,`, `)` and `/`, so `#work.` and `(#idea)` tag cleanly.
    static func isTagBody(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "-" || ch == "_"
    }
}
