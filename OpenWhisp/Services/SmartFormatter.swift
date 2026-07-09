import Foundation

/// Local, rule-based cleanup of dictated text — no network, no LLM.
///
/// This delivers the "smart formatting" most cloud dictation apps charge for,
/// done entirely on-device:
///   - normalize whitespace and strip whisper's leading space / stray quotes
///   - remove non-speech markers ([music], (laughter), ...)
///   - apply spoken punctuation commands ("new line", "comma", "period", ...)
///   - remove a conservative set of filler words ("um", "uh", ...)
///   - capitalize the first letter of each sentence and "i"
///
/// Everything here is deliberately conservative: when in doubt it leaves text
/// alone, because silently dropping or altering real words is worse than a
/// missed cleanup. Options gate the riskier passes (filler removal, spoken
/// punctuation) so they can be turned off.
struct SmartFormatter: PostProcessor {

    struct Options: Sendable {
        var removeFillers: Bool
        var applySpokenPunctuation: Bool
        var capitalizeSentences: Bool
        var ensureTerminalPunctuation: Bool

        // --- Opt-in structural formatting (all default OFF) -------------------
        // These are the MAK-20 "richer local formatting" rule groups. They are
        // intentionally off by default so existing behavior is byte-for-byte
        // unchanged unless a caller (or Settings) turns them on. Each group is a
        // pure, independent transform step in `format(...)`.

        /// Normalize small spelled cardinals in clearly-numeric contexts to
        /// digits, and combine year-style pairs ("twenty twenty six" -> "2026").
        var normalizeNumbers: Bool
        /// Normalize spoken currency ("five dollars" -> "$5", "ten cents" -> "10¢").
        var normalizeCurrency: Bool
        /// Turn spoken list markers at the start of a line into markdown list
        /// items ("bullet X" -> "- X", "number one X" -> "1. X").
        var spokenLists: Bool
        /// Basic markdown commands: "bold X" -> "**X**", "heading X" -> "# X".
        var basicMarkdown: Bool

        static let `default` = Options(
            removeFillers: true,
            applySpokenPunctuation: true,
            capitalizeSentences: true,
            ensureTerminalPunctuation: false,
            normalizeNumbers: false,
            normalizeCurrency: false,
            spokenLists: false,
            basicMarkdown: false
        )

        static let off = Options(
            removeFillers: false,
            applySpokenPunctuation: false,
            capitalizeSentences: false,
            ensureTerminalPunctuation: false,
            normalizeNumbers: false,
            normalizeCurrency: false,
            spokenLists: false,
            basicMarkdown: false
        )

        init(
            removeFillers: Bool,
            applySpokenPunctuation: Bool,
            capitalizeSentences: Bool,
            ensureTerminalPunctuation: Bool,
            normalizeNumbers: Bool = false,
            normalizeCurrency: Bool = false,
            spokenLists: Bool = false,
            basicMarkdown: Bool = false
        ) {
            self.removeFillers = removeFillers
            self.applySpokenPunctuation = applySpokenPunctuation
            self.capitalizeSentences = capitalizeSentences
            self.ensureTerminalPunctuation = ensureTerminalPunctuation
            self.normalizeNumbers = normalizeNumbers
            self.normalizeCurrency = normalizeCurrency
            self.spokenLists = spokenLists
            self.basicMarkdown = basicMarkdown
        }
    }

    let options: Options

    init(options: Options = .default) {
        self.options = options
    }

    func process(_ text: String, context: PostProcessContext) async throws -> String {
        format(text, language: context.language)
    }

    /// Synchronous entry point (also used directly where async isn't convenient).
    func format(_ text: String, language: String = "auto") -> String {
        var s = text

        if options.applySpokenPunctuation {
            s = Self.applySpokenPunctuation(to: s)
        }
        if options.removeFillers {
            s = Self.removeFillers(from: s)
        }

        // Collapse whitespace introduced by the passes above, but preserve
        // intentional newlines from spoken "new line"/"new paragraph".
        s = Self.normalizeWhitespacePreservingNewlines(s)

        // Only apply English-centric rules for English / auto. The number,
        // currency, list and markdown groups are all spelled-English rule sets,
        // so they gate on the same flag as capitalization.
        let englishLike = language == "auto" || language == "en" || language.hasPrefix("en")

        // Structural transforms run BEFORE capitalization so the capitalizer sees
        // the final line structure (new list-item lines, headings) and capitalizes
        // the first real word of each. Currency runs before plain number
        // normalization because "five dollars" must be consumed as a unit first.
        if englishLike {
            if options.normalizeCurrency {
                s = Self.normalizeCurrency(s)
            }
            if options.normalizeNumbers {
                s = Self.normalizeNumbers(s)
            }
            if options.spokenLists {
                s = Self.applySpokenLists(s)
            }
            if options.basicMarkdown {
                s = Self.applyBasicMarkdown(s)
            }
        }

        if options.capitalizeSentences && englishLike {
            s = Self.capitalizeSentences(s)
            s = Self.capitalizeStandaloneI(s)
        }

        if options.ensureTerminalPunctuation && englishLike {
            s = Self.ensureTerminalPunctuation(s)
        }

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Spoken punctuation

    /// Map spoken punctuation words to symbols. Word-boundary matched and
    /// case-insensitive. Ordered so multi-word phrases match before single words.
    private static let punctuationReplacements: [(pattern: String, replacement: String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("open paren", "("),
        ("close paren", ")"),
        ("open quote", "\""),
        ("close quote", "\""),
        ("question mark", "?"),
        ("exclamation mark", "!"),
        ("exclamation point", "!"),
        ("semicolon", ";"),
        ("colon", ":"),
        ("comma", ","),
        ("period", "."),
        ("full stop", "."),
        ("dash", " - "),
        ("hyphen", "-")
    ]

    private static func applySpokenPunctuation(to text: String) -> String {
        var result = text
        for (word, symbol) in punctuationReplacements {
            // \b...\b word boundaries, case-insensitive. For symbols that should
            // attach to the preceding word (comma/period/etc.) we also swallow a
            // leading space so we get "word," not "word ,".
            let attachLeft = [",", ".", "?", "!", ";", ":", ")"].contains(symbol.trimmingCharacters(in: .whitespaces))
            let pattern = attachLeft
                ? "\\s*\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
                : "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            result = result.replacingOccurrences(
                of: pattern,
                with: symbol,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    // MARK: - Filler removal

    /// Conservative filler set. These are rarely meaningful content words in
    /// dictation. "like"/"so"/"you know" are intentionally EXCLUDED — too risky.
    /// "mm" is excluded too: it's the millimeters unit in dictated measurements
    /// ("3 mm wide"), and whisper renders the filler as "Hmm"/"Mm-hmm" anyway.
    private static let fillerWords = ["um", "uh", "uhh", "umm", "erm", "hmm"]

    private static func removeFillers(from text: String) -> String {
        var result = text
        for filler in fillerWords {
            // Match the filler as a standalone token, optionally followed by a
            // comma whisper sometimes attaches, and the surrounding spaces.
            let pattern = "\\b\(filler)\\b,?"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    // MARK: - Whitespace

    private static func normalizeWhitespacePreservingNewlines(_ text: String) -> String {
        // Collapse runs of spaces/tabs (not newlines) to a single space.
        var s = text.replacingOccurrences(
            of: "[ \\t]+",
            with: " ",
            options: .regularExpression
        )
        // Remove spaces that ended up before attached punctuation.
        s = s.replacingOccurrences(
            of: " +([,.;:!?\\)])",
            with: "$1",
            options: .regularExpression
        )
        // Trim spaces hugging a newline on either side, and collapse 3+ newlines to 2.
        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s
    }

    // MARK: - Capitalization

    private static func capitalizeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var capitalizeNext = true

        for c in text {
            if capitalizeNext, c.isLetter {
                // uppercased() can expand to multiple characters (ß → "SS",
                // ﬁ → "FI"), so append it as a String — forcing it back into a
                // single Character would trap.
                result.append(String(c).uppercased())
                capitalizeNext = false
            } else {
                result.append(c)
                if c == "." || c == "!" || c == "?" || c == "\n" {
                    capitalizeNext = true
                } else if c.isWhitespace {
                    // keep waiting
                } else if capitalizeNext && Self.listOrMarkdownLead.contains(c) {
                    // A leading list/heading/emphasis marker (from the opt-in
                    // structural rules) is transparent: it does not consume the
                    // pending capitalization, so the first *word* of the item is
                    // still capitalized ("- buy" -> "- Buy"). We only skip these
                    // while a capitalization is already pending — i.e. at a line
                    // start — so a stray marker mid-sentence is never affected and
                    // default behavior is unchanged.
                } else {
                    capitalizeNext = false
                }
            }
        }
        return result
    }

    /// Characters that lead a structural line (bullet, heading, emphasis) and
    /// should be skipped when deciding what word to capitalize at a line start.
    private static let listOrMarkdownLead: Set<Character> = ["-", "#", "*", ">"]

    /// Capitalize the standalone pronoun "i" -> "I".
    private static func capitalizeStandaloneI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\bi\\b",
            with: "I",
            options: [.regularExpression]
        )
    }

    private static func ensureTerminalPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return text }
        if ".!?".contains(last) { return text }
        return trimmed + "."
    }

    // MARK: - Number words (shared)

    /// Spelled cardinal words 0–19 and the tens. This is the small, closed set we
    /// convert; anything larger (hundreds, "million", ordinals) is left alone —
    /// the goal is to fix the common, unambiguous cases without ever mangling
    /// prose. "one"/"a" are excluded from *bare* conversion (see `numericContext`)
    /// because "one of them" / "a dog" are ordinary English, not numbers.
    private static let onesWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19
    ]

    private static let tensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    /// Parse a spelled number phrase of the form <tens>[ <ones>] or a single
    /// ones/tens word into its integer value. Returns nil if `words` isn't a
    /// clean number phrase we recognize. Consumes 1–2 words (`consumed`).
    private static func parseSpelledNumber(_ words: [Substring]) -> (value: Int, consumed: Int)? {
        guard let first = words.first?.lowercased() else { return nil }
        if let tens = tensWords[first] {
            // "twenty six" -> 26 (tens + a following ones word 1–9).
            if words.count >= 2 {
                let second = words[1].lowercased()
                if let ones = onesWords[second], ones >= 1, ones <= 9 {
                    return (tens + ones, 2)
                }
            }
            return (tens, 1)
        }
        if let ones = onesWords[first] {
            return (ones, 1)
        }
        return nil
    }

    // MARK: - Currency normalization

    /// "<number> dollars" -> "$<number>", "<number> cents" -> "<number>¢".
    /// Only fires when a recognized spelled number (or already-a-digit run)
    /// directly precedes the currency unit, so ordinary words never trip it.
    private static func normalizeCurrency(_ text: String) -> String {
        // Operate per line so a trailing newline never fuses a unit word to the
        // next line's first token when we split on spaces.
        text.components(separatedBy: "\n")
            .map(normalizeCurrencyLine)
            .joined(separator: "\n")
    }

    private static func normalizeCurrencyLine(_ text: String) -> String {
        var out: [String] = []
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        var i = 0
        while i < words.count {
            // Determine the numeric value preceding a currency unit.
            let (amount, consumed) = leadingNumber(from: Array(words[i...]))
            if let amount = amount {
                let unitIndex = i + consumed
                if unitIndex < words.count {
                    let token = words[unitIndex]
                    let unit = token.lowercased()
                        .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
                    // Preserve any sentence punctuation that whisper attached to
                    // the unit word ("dollars." -> "$5.").
                    let trailing = trailingPunctuation(token)
                    if unit == "dollars" || unit == "dollar" {
                        out.append("$\(amount)\(trailing)")
                        i = unitIndex + 1
                        continue
                    }
                    if unit == "cents" || unit == "cent" {
                        out.append("\(amount)¢\(trailing)")
                        i = unitIndex + 1
                        continue
                    }
                }
            }
            out.append(String(words[i]))
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// Trailing punctuation (.,!?) of a token, as a String (may be empty).
    private static func trailingPunctuation(_ token: Substring) -> String {
        let punct = CharacterSet(charactersIn: ".,!?")
        var suffix = ""
        for ch in token.reversed() {
            if ch.unicodeScalars.allSatisfy({ punct.contains($0) }) {
                suffix.insert(ch, at: suffix.startIndex)
            } else {
                break
            }
        }
        return suffix
    }

    /// If the token stream begins with a number (a digit run OR a spelled number
    /// phrase), return its integer value and how many tokens it consumed. Used by
    /// currency so "$5" and "$twenty five" both resolve to the digit amount.
    private static func leadingNumber(from words: [Substring]) -> (Int?, Int) {
        guard let first = words.first else { return (nil, 0) }
        let bare = first.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        if let digits = Int(bare) {
            return (digits, 1)
        }
        if let parsed = parseSpelledNumber(words) {
            return (parsed.value, parsed.consumed)
        }
        return (nil, 0)
    }

    // MARK: - Number normalization

    /// Convert small spelled cardinals to digits, but only in contexts where a
    /// digit is clearly intended, and combine year-style pairs.
    ///
    /// Two safe cases are handled:
    ///  1. Year pairs: "<tens+ones> <tens+ones>" where each half is 10–99 and the
    ///     phrase reads like a spoken year -> "twenty twenty six" -> "2026".
    ///  2. A spelled number immediately followed by a unit/counter noun
    ///     ("five items", "twenty three people") -> "5 items", "23 people".
    ///
    /// Bare "one"/"a" and standalone numbers in plain prose are deliberately left
    /// alone — converting "I have one idea" to "I have 1 idea" is the kind of
    /// over-eager transform this rule set refuses to make.
    private static func normalizeNumbers(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map(normalizeNumbersLine)
            .joined(separator: "\n")
    }

    private static func normalizeNumbersLine(_ text: String) -> String {
        var out: [String] = []
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        var i = 0
        while i < words.count {
            // Case 1: year pair — two spelled halves each in 20–99 (or a teen +
            // tens) that combine to a plausible year like 1900–2099.
            if let year = parseYearPair(Array(words[i...])) {
                out.append(String(year.value))
                i += year.consumed
                continue
            }
            // Case 2: spelled number directly before a counter noun.
            if let parsed = parseSpelledNumber(Array(words[i...])) {
                let nounIndex = i + parsed.consumed
                if nounIndex < words.count,
                   isCounterNoun(words[nounIndex]) {
                    out.append(String(parsed.value))
                    i += parsed.consumed
                    continue
                }
            }
            out.append(String(words[i]))
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// Recognize a spoken-year pair: "<X hundred> " isn't handled, but
    /// "twenty twenty", "twenty twenty six", "nineteen ninety nine" are. Each
    /// half must be a two-word-or-less spelled number in 10–99; combine as
    /// firstHalf*100 + secondHalf and accept only 1000–2099.
    private static func parseYearPair(_ words: [Substring]) -> (value: Int, consumed: Int)? {
        guard let firstHalf = parseSpelledNumber(words) else { return nil }
        guard firstHalf.value >= 10, firstHalf.value <= 20 else { return nil }
        let rest = Array(words[firstHalf.consumed...])
        guard let secondHalf = parseSpelledNumber(rest) else { return nil }
        guard secondHalf.value >= 0, secondHalf.value <= 99 else { return nil }
        let year = firstHalf.value * 100 + secondHalf.value
        guard year >= 1000, year <= 2099 else { return nil }
        return (year, firstHalf.consumed + secondHalf.consumed)
    }

    /// Nouns that read as counters after a number, so "five <noun>" clearly means
    /// the digit 5. Kept small and unambiguous. Matched case-insensitively and
    /// tolerant of trailing punctuation.
    private static let counterNouns: Set<String> = [
        "items", "item", "people", "person", "things", "thing",
        "times", "steps", "step", "points", "point", "days", "day",
        "weeks", "week", "months", "month", "years", "year", "hours",
        "hour", "minutes", "minute", "seconds", "second", "dollars",
        "dollar", "cents", "cent", "percent", "files", "file", "lines",
        "line", "words", "word", "pages", "page", "tasks", "task"
    ]

    private static func isCounterNoun(_ token: Substring) -> Bool {
        let bare = token.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;"))
        return counterNouns.contains(bare)
    }

    // MARK: - Spoken lists

    /// Turn spoken list markers at the start of a line into markdown list items.
    ///  - "bullet X"      -> "- X"
    ///  - "number one X"  -> "1. X"  (and two/three/… -> 2./3./…)
    /// Only fires at the very start of a line (after optional whitespace), so a
    /// "bullet" in the middle of a sentence is untouched.
    private static func applySpokenLists(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let transformed = lines.map { line -> String in
            let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
            let body = line.dropFirst(leading.count)

            // "bullet X" / "bullet point X" -> "- X"
            if let rest = matchLeadingWord(body, "bullet point") ?? matchLeadingWord(body, "bullet") ?? matchLeadingWord(body, "dash") {
                return "\(leading)- \(rest)"
            }

            // "number one X" -> "1. X"
            let tokens = body.split(separator: " ", omittingEmptySubsequences: true)
            if tokens.count >= 2, tokens[0].lowercased() == "number" {
                if let n = onesWords[tokens[1].lowercased()], n >= 1 {
                    let rest = tokens.dropFirst(2).joined(separator: " ")
                    let sep = rest.isEmpty ? "" : " "
                    return "\(leading)\(n).\(sep)\(rest)"
                }
            }
            return line
        }
        return transformed.joined(separator: "\n")
    }

    /// If `text` begins (case-insensitively) with the whole word(s) `word`
    /// followed by a space, return the remainder (trimmed of the leading space);
    /// otherwise nil. Whole-word: "bulletin" does not match "bullet".
    private static func matchLeadingWord(_ text: Substring, _ word: String) -> String? {
        let lower = text.lowercased()
        let prefix = word.lowercased() + " "
        guard lower.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        return String(rest)
    }

    // MARK: - Basic markdown

    /// Basic spoken markdown commands, applied per line:
    ///  - "heading X" / "header X"        -> "# X"
    ///  - "bold X" (rest of line)         -> "**X**"
    ///  - "italic X" (rest of line)       -> "*X*"
    /// These only fire when the command word STARTS the line, which is the clear
    /// "format the following as …" intent; a stray "bold" mid-sentence is left
    /// alone to avoid mangling prose.
    private static func applyBasicMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let transformed = lines.map { line -> String in
            let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
            let body = line.dropFirst(leading.count)

            if let rest = matchLeadingWord(body, "heading") ?? matchLeadingWord(body, "header") {
                return "\(leading)# \(rest)"
            }
            if let rest = matchLeadingWord(body, "bold"), !rest.isEmpty {
                let (core, trailing) = splitTrailingPunctuation(rest)
                return "\(leading)**\(core)**\(trailing)"
            }
            if let rest = matchLeadingWord(body, "italic"), !rest.isEmpty {
                let (core, trailing) = splitTrailingPunctuation(rest)
                return "\(leading)*\(core)*\(trailing)"
            }
            return line
        }
        return transformed.joined(separator: "\n")
    }

    /// Split a run's trailing sentence punctuation off so emphasis wraps the words
    /// only: "world." -> ("world", "."). Keeps the marker outside the ** **.
    private static func splitTrailingPunctuation(_ s: String) -> (core: String, trailing: String) {
        let punct = CharacterSet(charactersIn: ".,!?;:")
        var trailing = ""
        var core = s
        while let last = core.last, last.unicodeScalars.allSatisfy({ punct.contains($0) }) {
            trailing.insert(last, at: trailing.startIndex)
            core.removeLast()
        }
        return (core, trailing)
    }
}
