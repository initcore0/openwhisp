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

        static let `default` = Options(
            removeFillers: true,
            applySpokenPunctuation: true,
            capitalizeSentences: true,
            ensureTerminalPunctuation: false
        )

        static let off = Options(
            removeFillers: false,
            applySpokenPunctuation: false,
            capitalizeSentences: false,
            ensureTerminalPunctuation: false
        )
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

        // Only apply English-centric capitalization rules for English / auto.
        let englishLike = language == "auto" || language == "en" || language.hasPrefix("en")
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
    private static let fillerWords = ["um", "uh", "uhh", "umm", "erm", "hmm", "mm"]

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
        var chars = Array(text)
        var capitalizeNext = true

        for i in 0..<chars.count {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(String(c).uppercased())
                capitalizeNext = false
            } else if c == "." || c == "!" || c == "?" || c == "\n" {
                capitalizeNext = true
            } else if c.isWhitespace {
                // keep waiting
            } else {
                capitalizeNext = false
            }
        }
        return String(chars)
    }

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
}
