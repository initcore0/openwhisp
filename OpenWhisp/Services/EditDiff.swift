import Foundation

/// Pure core for the self-learning dictionary's *capture* step (MAK-41 Part C).
///
/// The AX watcher (below in `AXCorrectionWatcher`, macOS-only) snapshots a text
/// field's value right AFTER OpenWhisp inserts a phrase, and again a short moment
/// LATER once the user has (maybe) typed over it. This type turns those two
/// snapshots into the single-word `(inserted, surviving)` pair that
/// `CorrectionLearner.proposeSubstitution` can judge — or `nil` when the change
/// isn't a clean, localized edit we can attribute to one word.
///
/// It is deliberately narrow. Capturing "what the user corrected" from a whole
/// field value is ambiguous in general (the user may have edited elsewhere, added
/// sentences, moved the caret). So we only report a pair when the later value is
/// the after-value with exactly ONE contiguous run replaced, and both the removed
/// and added runs are a single token. Everything else returns `nil`, and
/// `proposeSubstitution` applies its own conservative gate on top. Foundation-only
/// → lives in OpenWhispCore, fully unit-tested without AX.
enum EditDiff {

    /// Derive a single-token correction pair from the value observed right after we
    /// inserted (`afterInsert`) and the value observed later (`later`). Returns the
    /// `(inserted, surviving)` tokens to feed `proposeSubstitution`, or `nil` when
    /// the edit isn't a clean single-token, single-region change.
    ///
    /// We anchor on the longest common prefix and suffix, then EXPAND the differing
    /// region outward to the nearest whitespace on each side so we capture whole
    /// words — the char-level common prefix of "kubernetis"/"kubernetes" is
    /// "kubernet", which would otherwise leave a nonsense "i"→"e" middle. After the
    /// expansion, both differing spans must be exactly one whitespace-delimited
    /// token, or the edit spanned multiple words / regions and we return nil.
    static func singleTokenCorrection(afterInsert: String, later: String) -> (inserted: String, surviving: String)? {
        guard afterInsert != later else { return nil }

        let a = Array(afterInsert)
        let b = Array(later)

        // Longest common prefix (character level).
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }

        // Longest common suffix length, not overlapping the prefix on either side.
        var s = 0
        while s < (a.count - p) && s < (b.count - p) && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }

        // Char-level differing region: a[left..<rightA] vs b[left..<rightB].
        let left = p
        let rightA = a.count - s
        let rightB = b.count - s

        // Snap the region OUTWARD to whole-word boundaries: the char-level common
        // prefix/suffix can cut through the middle of a word (kubernet|i|s vs
        // kubernet|e|s), so walk the shared left boundary back to the previous
        // whitespace, and each right boundary forward to the next whitespace. The
        // left boundary is shared (same char offset in both), so one walk suffices.
        var wordLeft = left
        while wordLeft > 0 && !a[wordLeft - 1].isWhitespace { wordLeft -= 1 }

        var wordRightA = rightA
        while wordRightA < a.count && !a[wordRightA].isWhitespace { wordRightA += 1 }
        var wordRightB = rightB
        while wordRightB < b.count && !b[wordRightB].isWhitespace { wordRightB += 1 }

        let midA = String(a[wordLeft..<wordRightA])
        let midB = String(b[wordLeft..<wordRightB])

        // A clean one-word fix leaves exactly one token on each side after trimming.
        let removed = midA.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = midB.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !removed.isEmpty, !added.isEmpty else { return nil }
        guard isSingleToken(removed), isSingleToken(added) else { return nil }

        return (inserted: removed, surviving: added)
    }

    /// True when the string has no internal whitespace — a single word/token.
    private static func isSingleToken(_ s: String) -> Bool {
        !s.contains(where: { $0.isWhitespace })
    }
}
