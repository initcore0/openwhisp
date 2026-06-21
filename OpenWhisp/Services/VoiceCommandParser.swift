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

    struct Result: Equatable {
        let content: String
        let instruction: String
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

        // 2) Trailing imperative form: find the last sentence and check if it
        //    starts with a recognized command lead.
        if let r = matchTrailingImperative(in: trimmed) { return r }

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
