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
        #"in (?:english|russian|spanish|french|german|italian|portuguese|japanese|chinese|korean|arabic)"#,

        // --- Russian ---
        // When dictating in Russian with translate-on, whisper renders the Russian
        // command ("переведи на английский"). It must be stripped here, before the
        // text reaches the LLM — otherwise the model treats it as content and
        // "executes" it, baking the instruction into the translated output.
        // "переведи(те)/переводи(те) [это|этот текст|текст|всё это] на <язык>"
        #"перевед[иь](?:те)?(?: (?:это|этот текст|текст|всё это|все это|сообщение))? на [а-яё]+"#,
        #"переводи(?:те)?(?: (?:это|этот текст|текст|всё это|все это|сообщение))? на [а-яё]+"#,
        // "переведи это/текст" without an explicit language.
        #"перевед[иь](?:те)? (?:это|этот текст|текст|всё это|все это|сообщение)"#,
        // bare "на английский/русский/…" as a trailing language directive.
        #"на (?:английский|русский|испанский|французский|немецкий|итальянский|португальский|японский|китайский|корейский|арабский)"#
    ]

    /// Strip a trailing translate/transcribe instruction if present. Returns the
    /// input unchanged when none is found or when stripping would empty the text.
    static func strip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        for pattern in trailingPatterns {
            // Anchor to the end. Before the command, allow a sentence separator and
            // an optional politeness lead-in — the instruction may be phrased
            // "Please translate this into English" (leading "please") or
            // "translate this to English, please" (trailing). This also covers a
            // Russian "переведите на английский" that whisper rendered in English.
            // Separators before the command exclude sentence terminators (.!?) so
            // the preceding sentence keeps its own "?"/"!"/"." (e.g. "...how are
            // you? Please translate…" → keep the "?"). Allows an optional
            // politeness lead-in ("Please"/"could you"/…) right before the command.
            let lead = #"[\s,;:-]*(?:(?:could you|can you|would you|please|kindly|пожалуйста|будьте добры|будь добр[а]?)[\s,]*)*"#
            let trail = #"(?:[\s,]*(?:please|пожалуйста))?[\s,.!?]*$"#
            let full = #"(?i)"# + lead + pattern + trail
            guard let range = trimmed.range(of: full, options: .regularExpression) else { continue }

            // The slice that precedes the matched instruction. Trim trailing
            // whitespace/separators, but remember the sentence's own terminal
            // punctuation so "...how are you?" keeps its "?" rather than being
            // turned into a period.
            let rawContent = String(trimmed[..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-\t\n"))
            let originalTerminator: Character? =
                (rawContent.last.map { ".!?".contains($0) } ?? false) ? rawContent.last : nil

            let content = rawContent
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?-\t\n"))

            // Require real content before the instruction; never empty the text.
            guard wordCount(content) >= 2 else { return trimmed }

            // Restore terminal punctuation: keep the original (?/!/.) or add "."
            // if the sentence had none, so the remaining text reads complete.
            return content + String(originalTerminator ?? ".")
        }
        return trimmed
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}
