import Foundation

/// Removes a trailing spoken *meta-instruction* about translating or
/// transcribing — e.g. dictating in Russian with translate-to-English and
/// ending with "…translate this into English." That clause is an instruction to
/// the app, not content the user wants typed, so it's always stripped (it is
/// never legitimate dictation content).
///
/// Deliberately narrow: only translate/transcribe phrasing, only at the very
/// end, and only when real content precedes it (so a message that is *only*
/// "translate this to English" is left untouched rather than emptied).
enum MetaInstructionStripper {

    /// Trailing clauses to remove (matched case-insensitively at the end, after
    /// an optional sentence break). Order: longest/most-specific first.
    private static let trailingPatterns: [String] = [
        // "translate this into/to <language>", with optional "please"
        #"translate (?:this|it|that|the (?:text|above))? ?(?:in ?to|to) [a-z ]+"#,
        #"translate (?:in ?to|to) [a-z]+"#,
        #"translate (?:this|it|that)"#,
        // "transcribe this/it/that ..."
        #"transcribe (?:this|it|that)(?: (?:in ?to|to) [a-z]+)?"#,
        // bare "in English/Russian/..." as a trailing language directive
        #"in (?:english|russian|spanish|french|german|italian|portuguese|japanese|chinese|korean|arabic)"#
    ]

    /// Strip a trailing translate/transcribe instruction if present. Returns the
    /// input unchanged when none is found or when stripping would empty the text.
    static func strip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        for pattern in trailingPatterns {
            // Anchor to the end; allow an optional leading sentence separator and
            // an optional trailing ", please" / punctuation.
            let full = #"(?i)[\s,.;:!?-]*"# + pattern + #"(?:[\s,]*please)?[\s,.!?]*$"#
            guard let range = trimmed.range(of: full, options: .regularExpression) else { continue }

            let content = String(trimmed[..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?-\t\n"))

            // Require real content before the instruction; never empty the text.
            guard wordCount(content) >= 2 else { return trimmed }

            // Restore a terminal period so the remaining text reads complete.
            if let last = content.last, !".!?".contains(last) {
                return content + "."
            }
            return content
        }
        return trimmed
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}
