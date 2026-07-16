import Foundation

/// Recovers the discrete vocabulary terms from the whisper-shaped `prompt` string
/// the engine protocol carries (MAK-71).
///
/// The transcription protocol is whisper.cpp-shaped: it passes ONE free-text
/// `initial_prompt`, because that's what whisper's decoder takes. Parakeet's CTC
/// context biasing wants the opposite — a *list* of discrete terms, each spotted
/// acoustically on its own. So the terms are joined upstream
/// (`Vocabulary.whisperPrompt`, `AppState.effectiveWhisperPrompt`: comma-joined,
/// custom vocabulary + screen-context bias terms) and split back apart here.
///
/// Round-tripping a list through a string is silly, and it exists only because
/// the protocol has no term-list channel. MAK-69 is where that gets fixed; until
/// then this is the honest adapter, kept pure so `swift test` covers it rather
/// than burying the parsing inside an engine.
public enum ParakeetVocabularyPrompt {
    /// Longer than any plausible dictation term — a prompt this long isn't a
    /// vocabulary list, it's prose, and feeding prose to a keyword spotter just
    /// wastes CTC passes on garbage.
    static let maxTermLength = 60

    /// CTC-WS skips terms under 3 characters anyway (false-positive control, per
    /// the NeMo paper); dropping them here avoids pointless tokenizer work and
    /// keeps our term count honest.
    static let minTermLength = 3

    /// Split `prompt` back into bias terms. Returns empty when there's nothing
    /// usable — the caller then takes the plain, unbiased path.
    public static func terms(from prompt: String) -> [String] {
        let candidates = prompt
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var seen = Set<String>()
        var result: [String] = []
        for term in candidates {
            guard term.count >= minTermLength, term.count <= maxTermLength else { continue }
            // Case-insensitive dedup: "Claude" and "claude" spot identically, and
            // a duplicate term is a wasted pass through the spotter.
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(term)
        }
        return result
    }
}
