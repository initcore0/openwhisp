import Foundation

/// Detects a spoken instruction at the END of a dictation and separates it from
/// the content. Lets the user say e.g. "…ship it tomorrow. Make this formal." and
/// have "ship it tomorrow." rewritten formally, with the command itself removed.
///
/// Two trigger forms (both matched only at the very end, case-insensitive):
///   1. Wake lead-in: "<wake>, <instruction>"  e.g. "voice note, make this shorter"
///   2. Imperative template: "make this/it …", "rewrite this …", "translate this to …",
///      "summarize this", etc.
///
/// Deliberately conservative — it would rather miss a command than eat real
/// words, so it requires the command clause to be a trailing minority of the
/// utterance and only fires on recognized verbs / the wake word.
struct VoiceCommandParser {
    /// Optional wake lead-in (e.g. "voice note"). Empty disables the wake form.
    var wakeWord: String

    /// Named actions to match against (built-ins overlaid with pack/user actions).
    /// Defaults to the built-ins so existing call sites keep working.
    var actions: VoiceActionRegistry = .builtins

    struct Result: Equatable {
        let content: String
        /// The free-form instruction the user spoke (for generic commands), or the
        /// matched action's first trigger phrase for a named action. AppState uses
        /// `actionID` (if set) to pick that action's prompt, falling back to the
        /// generic directive built from `instruction`.
        let instruction: String
        /// Id of the matched named action (e.g. "telegram-post"), if any.
        let actionID: String?

        init(content: String, instruction: String, actionID: String? = nil) {
            self.content = content
            self.instruction = instruction
            self.actionID = actionID
        }
    }

    /// Verb stems that begin a recognized trailing command clause.
    private static let imperativeLeads = [
        "make this", "make it",
        "rewrite this", "rewrite it", "rewrite that",
        "rephrase this", "rephrase it", "rephrase that",
        "translate this", "translate it", "translate that",
        "summarize this", "summarize that", "summarize it",
        "shorten this", "shorten it", "shorten that",
        "fix this", "fix the grammar", "fix grammar"
    ]

    func parse(_ text: String) -> Result? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1) Wake-word form: split on the LAST occurrence of "<wake>,?".
        let wake = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wake.isEmpty {
            if let r = matchWake(in: trimmed, wake: wake) { return r }
        }

        // 2) Built-in action phrases (e.g. "make a telegram post") at the end.
        if let r = matchTrailingAction(in: trimmed) { return r }

        // 3) Trailing imperative form: find the last sentence and check if it
        //    starts with a recognized command lead.
        if let r = matchTrailingImperative(in: trimmed) { return r }

        return nil
    }

    /// Match a known action's trigger phrase at the very end of the utterance. The
    /// phrase may be its own clause ("…done. Make a telegram post.") or trail
    /// directly. Phrases are tried longest-first so a specific phrase wins over a
    /// shorter substring of it (e.g. "make a telegram post" before "telegram post").
    private func matchTrailingAction(in text: String) -> Result? {
        let lower = text.lowercased()
        let candidates = actions.allPhrases
            .sorted { $0.phrase.count > $1.phrase.count }
        for candidate in candidates {
            // Allow an optional leading separator/politeness and trailing
            // punctuation around the phrase, anchored to the end.
            let pattern = #"(?i)[\s,.;:!?-]*(?:please[\s,]*)?"#
                + NSRegularExpression.escapedPattern(for: candidate.phrase)
                + #"[\s,.!?]*$"#
            guard let range = lower.range(of: pattern, options: .regularExpression) else { continue }

            // Map the lowercased match range back to the original string.
            let cutIndex = text.index(text.startIndex,
                                      offsetBy: lower.distance(from: lower.startIndex, to: range.lowerBound))
            var content = String(text[..<cutIndex])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-\t\n"))
            guard wordCount(content) >= 2 else { return nil }   // need real content
            content = restoreTerminalPunctuation(content, from: text)
            return Result(content: content, instruction: candidate.phrase, actionID: candidate.id)
        }
        return nil
    }

    private func matchWake(in text: String, wake: String) -> Result? {
        let lower = text.lowercased()
        // Find the LAST occurrence of the wake word.
        let needle = wake.lowercased()
        guard let range = lower.range(of: needle, options: .backwards) else { return nil }

        let instructionStart = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
        let instruction = String(text[instructionStart...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;\t\n"))
        guard instruction.count >= 3 else { return nil }

        // Content is everything before the wake word, minus trailing separators.
        // There must be real content before it (we never strip the whole body).
        var content = String(text[..<range.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;\t\n"))
        guard wordCount(content) >= 2 else { return nil }
        content = restoreTerminalPunctuation(content, from: text)
        return Result(content: content, instruction: instruction)
    }

    private func matchTrailingImperative(in text: String) -> Result? {
        // Split into sentence-ish chunks on . ! ? and take the last non-empty one.
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2, let last = parts.last else { return nil }

        let lastLower = last.lowercased()
        guard Self.imperativeLeads.contains(where: { lastLower.hasPrefix($0) }) else { return nil }

        // Keep the command clause itself short so a long sentence that merely
        // begins with "make it…" as real content isn't mistaken for a command.
        guard wordCount(last) <= 7 else { return nil }

        let instruction = last
        // Content = everything up to the start of the last sentence; require ≥2 words.
        guard let lastRange = text.range(of: last, options: .backwards) else { return nil }
        var content = String(text[..<lastRange.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;\t\n"))
        guard wordCount(content) >= 2 else { return nil }
        content = restoreTerminalPunctuation(content, from: text)
        return Result(content: content, instruction: instruction)
    }

    private func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    /// If the original content sentence ended with terminal punctuation that we
    /// trimmed, keep a period so the rewritten text reads as a complete sentence.
    private func restoreTerminalPunctuation(_ content: String, from original: String) -> String {
        guard let last = content.last, !".!?".contains(last) else { return content }
        return content + "."
    }

    /// Turn a recognized instruction phrase into an explicit LLM directive.
    static func directive(for instruction: String) -> String {
        "Apply this transformation to the user's text: \"\(instruction)\". "
        + "Preserve names, URLs, code, and formatting. Return only the transformed text, with no preamble."
    }
}
