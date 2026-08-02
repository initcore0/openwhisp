import Foundation

/// Search + tag filtering for the Scratchpad note list (MAK-97).
///
/// Pure and Foundation-only: the SwiftUI list binds to `filtered(notes:query:tag:)`
/// and does no matching of its own, so the Cyrillic/case behavior is pinned by
/// `swift test` rather than discovered by typing into the app.
///
/// Matching is **case- and diacritic-insensitive** over the note's FULL text (not
/// just its title) — the pad is where long dictations land, so the sentence you
/// remember is usually in the body. `localizedStandardContains` gives the
/// Finder-like behavior users expect, and it is correct for non-Latin scripts,
/// unlike a naive `lowercased().contains`.
public enum ScratchpadFilter {

    /// Does a note match a free-text query? An empty/whitespace-only query matches
    /// everything (an empty search box is not a filter).
    public static func matches(note: ScratchpadNote, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return note.text.localizedStandardContains(needle)
    }

    /// Narrow `notes` by a query and/or a tag, **preserving the input order**
    /// (the store's most-recently-updated-first ordering).
    ///
    /// The two filters AND together: with both a query and a tag set, a note must
    /// satisfy both. A nil/empty tag is not a filter.
    public static func filtered(
        notes: [ScratchpadNote],
        query: String = "",
        tag: String? = nil
    ) -> [ScratchpadNote] {
        let wantedTag = tag?.trimmingCharacters(in: .whitespaces).lowercased()
        return notes.filter { note in
            guard matches(note: note, query: query) else { return false }
            guard let wantedTag, !wantedTag.isEmpty else { return true }
            return ScratchpadTags.note(note, hasTag: wantedTag)
        }
    }

    /// Every occurrence of `query` in `text`, case-insensitively, as character
    /// ranges — the editor highlights these so a filtered-to note shows WHERE
    /// the match is (the reported gap: global search found the note, but a long
    /// meeting transcript gave no clue where the word was). Non-overlapping,
    /// left-to-right; diacritic-sensitive on purpose (matches the visible text
    /// the way the find bar does). Empty/whitespace query → no ranges.
    public static func matchRanges(of query: String, in text: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: needle, options: .caseInsensitive, range: from..<text.endIndex) {
            ranges.append(r)
            from = r.upperBound
        }
        return ranges
    }
}
