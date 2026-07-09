import Foundation

/// Turns a "user typed over what we inserted" edit into a *proposed* vocabulary
/// substitution — the tested core of MAK-41's auto-learn-dictionary feature.
///
/// The AppKit side (a follow-up) watches the focused field via the same AX /
/// insert-verification path OpenWhisp already runs, captures what it INSERTED and
/// the text that SURVIVED after the user finished editing, and hands both strings
/// here. This type decides whether that edit looks like a small, deliberate
/// *correction* of a single word — the only case worth learning — and if so
/// returns a `from → to` `Substitution` the user can accept.
///
/// It is intentionally CONSERVATIVE. A wrong auto-learned rule silently rewrites
/// future transcriptions, so the bar for proposing one is high: we only fire on an
/// unambiguous single-token change and return `nil` for everything else. Pure and
/// Foundation-only so it lives in OpenWhispCore and is unit-tested without AX.
enum CorrectionLearner {

    /// Propose a substitution from an insert→edit pair, or `nil` if the edit isn't
    /// a clear single-word correction.
    ///
    /// Heuristics (all must hold to propose):
    ///  1. **Both sides non-empty.** An empty inserted or surviving string is a
    ///     deletion / no-op, never a correction.
    ///  2. **Something actually changed** after typographic normalization. We fold
    ///     smart quotes / dashes / ellipsis / nbsp exactly the way
    ///     `InsertVerifier.normalize` does, so an app swapping `'` for `’` or `-`
    ///     for `—` in the inserted text does NOT read as a user correction.
    ///  3. **Same token count.** Adding or removing whole words is a rewrite, an
    ///     appended sentence, or a deletion — not a one-word fix. Requiring equal
    ///     word counts rejects all of those.
    ///  4. **Exactly one token differs.** With the sequences aligned position for
    ///     position, precisely one word must differ (case- and content-wise). Zero
    ///     differing tokens means only whitespace/typography changed (nothing to
    ///     learn); two or more means the edit is ambiguous — we can't attribute it
    ///     to a single misrecognition — so we bail.
    ///  5. **The changed token is a plausible correction of the same word**, not a
    ///     swap for an unrelated one. We accept a pure casing fix (`claude` →
    ///     `Claude`) unconditionally, and otherwise require the two tokens to be
    ///     *similar* — a small edit distance relative to length (`kubernetis` →
    ///     `kubernetes`). A wholesale word swap (`cat` → `elephant`) is rejected.
    ///
    /// The proposed substitution's `from` is the ORIGINAL (inserted) token — the
    /// misrecognition to catch next time — and `to` is the user's corrected token,
    /// both taken from the ORIGINAL (un-normalized) strings so the stored rule
    /// carries the real characters the user typed.
    static func proposeSubstitution(inserted: String, surviving: String) -> Vocabulary.Substitution? {
        // (1) reject empties outright.
        let insTrimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        let survTrimmed = surviving.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insTrimmed.isEmpty, !survTrimmed.isEmpty else { return nil }

        // (2) if normalization collapses the two to the same string, only
        // typography/whitespace differs — nothing a substitution should learn.
        guard normalize(insTrimmed) != normalize(survTrimmed) else { return nil }

        // Tokenize on whitespace. Keep the original-cased tokens for the proposal;
        // compare on normalized tokens so a smart-quote apostrophe inside a word
        // doesn't count as a difference.
        let insTokens = tokenize(insTrimmed)
        let survTokens = tokenize(survTrimmed)

        // (3) same number of words, or it's an add/remove/rewrite, not a fix.
        guard insTokens.count == survTokens.count, !insTokens.isEmpty else { return nil }

        // (4) find the differing positions (compared normalized).
        var diffIndices: [Int] = []
        for i in insTokens.indices where normalize(insTokens[i]) != normalize(survTokens[i]) {
            diffIndices.append(i)
        }
        guard diffIndices.count == 1, let idx = diffIndices.first else { return nil }

        let fromToken = insTokens[idx]
        let toToken = survTokens[idx]

        // (5) accept only if it's a plausible correction of the *same* word.
        guard isPlausibleCorrection(from: fromToken, to: toToken) else { return nil }

        return Vocabulary.Substitution(from: fromToken, to: toToken)
    }

    // MARK: - Heuristic helpers

    /// A change is a plausible single-word correction when it's either a pure
    /// casing fix, or the two tokens are *similar* — a small Levenshtein distance
    /// relative to the longer token's length. This admits typo/spelling fixes
    /// (`kubernetis` → `kubernetes`, distance 1) while rejecting unrelated word
    /// swaps (`cat` → `elephant`).
    private static func isPlausibleCorrection(from: String, to: String) -> Bool {
        let a = normalize(from)
        let b = normalize(to)
        guard a != b else { return false }

        // Pure casing fix: same letters, different case — always learn it.
        if a.lowercased() == b.lowercased() { return true }

        let distance = levenshtein(a.lowercased(), b.lowercased())
        let longer = max(a.count, b.count)
        guard longer > 0 else { return false }

        // Require the two words to share most of their characters. Allow a slightly
        // looser threshold for longer words (where a single typo is a smaller
        // fraction) but cap the absolute distance so short unrelated words like
        // "cat" → "dog" (distance 3) or "cat" → "bat" (distance 1 but a real word
        // swap risk) don't sneak through: for short tokens we demand distance 1.
        if longer <= 4 { return distance == 1 }
        let ratio = Double(distance) / Double(longer)
        return distance <= 3 && ratio <= 0.34
    }

    /// Split on whitespace, dropping empties. Punctuation stays attached to its
    /// token (so `"kubernetis."` is one token) — we only care about word-level
    /// substitution and the substitutor matches whole phrases anyway.
    private static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Classic iterative Levenshtein edit distance (insert/delete/substitute = 1).
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1,        // deletion
                              curr[j - 1] + 1,    // insertion
                              prev[j - 1] + cost) // substitution
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }

    /// Fold the typographic substitutions apps commonly apply to inserted text
    /// (smart quotes, dashes, ellipsis, non-breaking spaces). Mirrors
    /// `InsertVerifier.normalize` so smart-quote / dash differences between the
    /// inserted and surviving text don't manufacture bogus proposals.
    private static func normalize(_ s: String) -> String {
        var out = s
        for (fancy, plain) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""),
                               ("\u{201D}", "\""), ("\u{2013}", "-"), ("\u{2014}", "-"),
                               ("\u{2026}", "..."), ("\u{00A0}", " ")] {
            out = out.replacingOccurrences(of: fancy, with: plain)
        }
        return out
    }
}
