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
public enum MetaInstructionStripper {

    /// Language slot of a translate command: ONE free word, optionally preceded
    /// by a whitelisted modifier for real multi-word language names ("Brazilian
    /// Portuguese", "simplified Chinese"). One free word covers essentially
    /// every language name (Ukrainian, Polish, Hindi, …) without the greed of
    /// `[a-z ]+`, which swallowed arbitrary trailing words ("…translate this to
    /// English properly" → "…how to."). The second word stays whitelisted
    /// because that's where the greed lives.
    private static let languages =
        #"(?:(?:simplified|traditional|modern|brazilian|mandarin|swiss) )?[a-z]+"#

    /// Trailing clauses to remove (matched case-insensitively at the end, after
    /// an optional sentence break). Order: longest/most-specific first.
    ///
    /// Every pattern requires an explicit translate/transcribe command verb.
    /// Bare "in English"/"на английский" directives are deliberately NOT
    /// matched: strip() runs on every final transcript, and a sentence that
    /// legitimately ends with a language name ("send me the documentation in
    /// English") must survive intact.
    private static let trailingPatterns: [String] = [
        // "translate this into/to <language>", with optional "please"
        #"translate (?:this|it|that|the (?:text|above))? ?(?:in ?to|to) "# + languages,
        #"translate (?:in ?to|to) "# + languages,
        #"translate (?:this|it|that)"#,
        // "transcribe this/it/that ..."
        #"transcribe (?:this|it|that)(?: (?:in ?to|to) "# + languages + #")?"#,

        // --- Russian ---
        // When dictating in Russian with translate-on, whisper renders the Russian
        // command ("переведи на английский"). It must be stripped here, before the
        // text reaches the LLM — otherwise the model treats it as content and
        // "executes" it, baking the instruction into the translated output.
        // "переведи(те)/переводи(те) [это|этот текст|текст|всё это] на <язык>"
        #"перевед[иь](?:те)?(?: (?:это|этот текст|текст|всё это|все это|сообщение))? на [а-яё]+"#,
        #"переводи(?:те)?(?: (?:это|этот текст|текст|всё это|все это|сообщение))? на [а-яё]+"#,
        // "переведи это/текст" without an explicit language.
        #"перевед[иь](?:те)? (?:это|этот текст|текст|всё это|все это|сообщение)"#
    ]

    /// Strip a trailing translate/transcribe instruction if present. Returns the
    /// input unchanged when none is found or when stripping would empty the text.
    public static func strip(_ text: String) -> String {
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
            // \b before the command verb: the lead can match empty, so without
            // it the pattern would match mid-word ("mistranslate this into
            // English" → "mis."). ICU's \b is Unicode-aware, so it also covers
            // the Cyrillic patterns.
            let full = #"(?i)"# + lead + #"\b"# + pattern + trail
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
