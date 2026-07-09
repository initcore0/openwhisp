import Foundation

/// Rewrites spoken *filename* forms into editor `@`-mentions so an AI-native
/// editor (Cursor / Windsurf) can trigger its own file autocomplete.
///
///   "main dot t s"        -> "@main.ts"
///   "index dot j s x"     -> "@index.jsx"
///   "at main"             -> "@main"
///   "open main dot t s and fix it" -> "open @main.ts and fix it"
///
/// This is a PURE, local, offline text transform — no network, no AX, no LLM.
/// (Reading the workspace file list over AX to pick the right extension is a
/// documented stretch goal, not implemented here.)
///
/// ## Scope
///
/// This transform is intended to run ONLY in a per-app mode for Cursor /
/// Windsurf, where an `@name.ext` is a meaningful file reference. It is shipped
/// here as the pure, tested core; the per-app enablement (run it only when the
/// frontmost app is Cursor/Windsurf) is a deliberate follow-up and is NOT wired
/// into `AppState` by this change.
///
/// ## Conservatism (why it won't mangle prose)
///
/// Like `MetaInstructionStripper` and `SmartFormatter`, this is deliberately
/// timid: it rewrites only *clear* filename forms and otherwise leaves text
/// byte-for-byte alone. Two — and only two — cues trigger a rewrite:
///
///   1. **"<name> dot <ext>"** — the literal spoken "dot" followed by an
///      extension we recognize. The extension is either a whole known-extension
///      word ("swift", "json", "python" is NOT a file ext so it's ignored) or a
///      run of adjacent single spoken letters that JOIN into a known extension
///      ("t s" -> "ts", "j s x" -> "jsx"). If what follows "dot" is not a
///      recognized extension, nothing is rewritten — so "dot product" and
///      "twelve dot five" stay exactly as dictated.
///
///   2. **"at <name>"** — the explicit leading "at" cue, which the editor's
///      own file-mention syntax mirrors. This is the ambiguous one: "at noon",
///      "at lunch", "at least" are ordinary English. So the bare "at <name>"
///      form fires ONLY when <name> is a plausible bare filename — a single
///      identifier token that is NOT one of the common prose words that follow
///      "at" (a curated stop-list: noon, lunch, home, work, night, least,
///      most, all, once, …). When "at" is followed by a "<name> dot <ext>"
///      form, that is unambiguous and always fires ("at main dot t s"
///      -> "@main.ts"). When in doubt, the "at" is left as the ordinary word.
///
/// Everything else in the sentence is passed through untouched.
enum FileTagTransform {

    /// File extensions we recognize as spoken-letter runs and as whole words.
    /// Kept intentionally to the common dev set from the ticket. Lowercased.
    static let knownExtensions: Set<String> = [
        "ts", "tsx", "js", "jsx", "py", "rs", "go", "swift",
        "md", "json", "css", "html"
    ]

    /// Single spoken letters that can be joined into an extension. We only ever
    /// join *single-character* tokens (each is one letter), so "t s" -> "ts"
    /// but "main ts" (a whole word) is never treated as letters to join.
    private static let singleLetters: Set<Character> =
        Set("abcdefghijklmnopqrstuvwxyz")

    /// Common words that legitimately follow "at" in ordinary prose. A bare
    /// "at <word>" is left alone when <word> is in this set, so "at noon",
    /// "at lunch", "at least" never become file mentions. This is the crux of
    /// the "at noon"-style boundary: the ambiguous bare form is opt-OUT on
    /// these words rather than opt-in on a filename allow-list (an allow-list
    /// can't know every project's filenames).
    private static let atStopWords: Set<String> = [
        // time / place
        "noon", "midnight", "night", "dawn", "dusk", "home", "work", "school",
        "lunch", "dinner", "breakfast", "bed", "sea", "sunrise", "sunset",
        // "at <superlative/quantifier>" idioms
        "least", "most", "best", "worst", "large", "length", "once", "all",
        "first", "last", "times", "hand", "stake", "risk", "odds", "ease",
        "will", "fault", "peace", "war", "play", "rest", "heart", "issue",
        // articles / pronouns / connectives that can follow "at"
        "the", "a", "an", "my", "your", "our", "his", "her", "their", "its",
        "this", "that", "these", "those", "some", "any", "no", "one", "two",
        "them", "you", "me", "us", "him", "it", "which", "what", "where",
        "when", "how", "who", "and", "or", "but", "so"
    ]

    /// Rewrite spoken filename forms in `text` to `@name.ext` / `@name`.
    /// Returns the input unchanged when no clear filename form is present.
    static func transform(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Tokenize on whitespace, but keep each token's trailing punctuation so
        // "fix it." / "main," survive. We rebuild the string from tokens with a
        // single space, which matches how whisper output already reads; the
        // callers run whitespace normalization anyway.
        let rawTokens = text.split(separator: " ", omittingEmptySubsequences: false)
        guard !rawTokens.isEmpty else { return text }

        var out: [String] = []
        out.reserveCapacity(rawTokens.count)

        var i = 0
        while i < rawTokens.count {
            let token = rawTokens[i]

            // --- Cue 2: leading "at" -------------------------------------------
            // "at" must be a bare lowercased word (no attached punctuation) to be
            // read as the mention cue. "at," / "at." are sentence prose.
            if wordEquals(token, "at") {
                if let (mention, consumed) = matchAtMention(rawTokens, from: i) {
                    out.append(mention)
                    i += consumed
                    continue
                }
                // Not a filename form — fall through, emit "at" verbatim.
            }

            // --- Cue 1: "<name> dot <ext>" -------------------------------------
            // Only when the CURRENT token is a plain identifier immediately
            // followed by "dot" and a recognized extension.
            if let (bare, consumed) = matchNameDotExt(rawTokens, from: i) {
                out.append("@\(bare)")
                i += consumed
                continue
            }

            out.append(String(token))
            i += 1
        }

        return out.joined(separator: " ")
    }

    // MARK: - "at <name>" / "at <name> dot <ext>"

    /// Match the "at" mention cue starting at `start` (which is the "at" token).
    /// Returns the rewritten "@…" mention and how many tokens were consumed
    /// (including the "at"), or nil if this "at" is ordinary prose.
    private static func matchAtMention(
        _ tokens: [Substring], from start: Int
    ) -> (mention: String, consumed: Int)? {
        let nameIndex = start + 1
        guard nameIndex < tokens.count else { return nil }

        // Prefer the unambiguous "at <name> dot <ext>" form first — it always
        // fires regardless of the name, because "dot <ext>" is itself a strong
        // filename cue ("at main dot t s" -> "@main.ts").
        if let (bare, consumed) = matchNameDotExt(tokens, from: nameIndex) {
            // consumed counts from nameIndex; add 1 for the "at" token.
            return ("@\(bare)", consumed + 1)
        }

        // Bare "at <name>": fire only when <name> is a plausible filename — a
        // single identifier token that isn't a common "at <word>" prose word.
        let nameToken = tokens[nameIndex]
        let (core, trailing) = splitTrailingPunctuation(nameToken)
        guard isBareFilenameName(core) else { return nil }
        return ("@\(core)\(trailing)", 2)
    }

    /// Is `word` acceptable as a bare "@word" mention after an explicit "at"?
    /// Conservative: a lowercase-startable identifier of at least 2 chars that
    /// is not in the `atStopWords` prose list.
    private static func isBareFilenameName(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }         // "at a" / "at I" out
        guard isIdentifierWord(word) else { return false }
        if atStopWords.contains(word.lowercased()) { return false }
        return true
    }

    // MARK: - "<name> dot <ext>"

    /// Match "<name> dot <ext>" beginning at `start` (the name token). The
    /// extension is a known-extension word OR a run of single spoken letters
    /// that join into a known extension. Returns the BARE "name.ext" (no "@" —
    /// the caller prepends exactly one) plus any trailing punctuation, and the
    /// token count consumed, or nil.
    private static func matchNameDotExt(
        _ tokens: [Substring], from start: Int
    ) -> (bare: String, consumed: Int)? {
        // name — must be a clean identifier with no attached punctuation.
        // ("main," dot ts breaks the form; "12 dot 5" is a number, not a file.)
        let (nameCore, nameTrailing) = splitTrailingPunctuation(tokens[start])
        guard isIdentifierWord(nameCore), nameTrailing.isEmpty else { return nil }

        // "dot"
        let dotIndex = start + 1
        guard dotIndex < tokens.count, wordEquals(tokens[dotIndex], "dot") else { return nil }

        // extension: whole word OR joined single letters.
        guard let ext = matchExtension(tokens, from: dotIndex + 1) else { return nil }

        // consumed: name + "dot" + extension tokens.
        return ("\(nameCore).\(ext.value)\(ext.trailing)", 2 + ext.consumed)
    }

    /// Match the extension that follows "dot". Two shapes:
    ///   - a single whole word that is a known extension ("swift", "json").
    ///   - a run of ≥2 single spoken letters that JOIN into a known extension
    ///     ("t s" -> "ts", "j s x" -> "jsx").
    /// Returns the extension text, its consumed token count, and any trailing
    /// punctuation carried on the LAST extension token (so "j s x." keeps the
    /// period outside the mention).
    private static func matchExtension(
        _ tokens: [Substring], from start: Int
    ) -> (value: String, consumed: Int, trailing: String)? {
        guard start < tokens.count else { return nil }

        // Shape A: single whole known-extension word.
        let (firstCore, firstTrailing) = splitTrailingPunctuation(tokens[start])
        let firstLower = firstCore.lowercased()
        if knownExtensions.contains(firstLower), firstCore.count >= 2 {
            return (firstLower, 1, firstTrailing)
        }

        // Shape B: a run of single spoken letters. Collect maximal run of
        // single-letter tokens (each is exactly one identifier char), then try
        // to match a KNOWN extension as a prefix of that run — longest first —
        // so "j s x" -> "jsx" but a stray "t s foo" -> "ts" leaves "foo".
        var letters: [Character] = []
        var trailingOnLast = ""
        var idx = start
        while idx < tokens.count {
            let (core, trailing) = splitTrailingPunctuation(tokens[idx])
            guard core.count == 1, let ch = core.lowercased().first,
                  singleLetters.contains(ch) else { break }
            letters.append(ch)
            trailingOnLast = trailing
            idx += 1
            // If a token carried trailing punctuation, the letter run ends here
            // (the punctuation is a boundary: "t s. next" stops after "s").
            if !trailing.isEmpty { break }
        }
        guard letters.count >= 2 else { return nil }

        // Longest known-extension prefix of the collected letters.
        // Try lengths from full run down to 2.
        var n = letters.count
        while n >= 2 {
            let candidate = String(letters.prefix(n))
            if knownExtensions.contains(candidate) {
                // trailing punctuation only applies if the matched prefix
                // reaches the last collected letter.
                let trailing = (n == letters.count) ? trailingOnLast : ""
                return (candidate, n, trailing)
            }
            n -= 1
        }
        return nil
    }

    // MARK: - Token helpers

    /// True when `token`, stripped of any trailing punctuation, equals `word`
    /// (case-insensitively) and carries no attached punctuation. Used for the
    /// literal cue words "at" and "dot", which must be clean standalone words.
    private static func wordEquals(_ token: Substring, _ word: String) -> Bool {
        // The cue words must be bare — "dot." or "at," is prose punctuation, not
        // a structural cue — so we do NOT strip punctuation before comparing.
        token.lowercased() == word
    }

    /// A word usable as a filename identifier stem: letters/digits with optional
    /// internal `_`/`-`, starting with a letter or digit. Rejects anything with
    /// embedded punctuation, symbols, or that is empty.
    private static func isIdentifierWord(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first.isNumber else { return false }
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { continue }
            return false
        }
        return true
    }

    /// Split a token into (core, trailingPunctuation), where the trailing part
    /// is a run of sentence/structural punctuation at the end (.,!?;:).
    /// "main," -> ("main", ","); "index" -> ("index", "").
    private static func splitTrailingPunctuation(_ token: Substring) -> (core: String, trailing: String) {
        let punct = CharacterSet(charactersIn: ".,!?;:)")
        var core = String(token)
        var trailing = ""
        while let last = core.last, last.unicodeScalars.allSatisfy({ punct.contains($0) }) {
            trailing.insert(last, at: trailing.startIndex)
            core.removeLast()
        }
        return (core, trailing)
    }
}
