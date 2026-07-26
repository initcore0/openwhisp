import Foundation

/// Strips the silence hallucination Parakeet appends to a finished dictation.
///
/// **Why this exists.** At stop we call FluidAudio's `finish()`, which runs
/// `processAvailableWindows(isFinal: true)`. That final window is assembled as a
/// zero-filled `[Float](repeating: 0, count: config.windowSamples)` buffer with
/// only `validCount` real samples copied in — so everything past the user's last
/// word is digital silence. The windower also sets `holdbackFrames: 0` on that
/// plan (`isLast` → no right-context guard), so the greedy RNNT decoder decodes
/// straight into the padding. Parakeet's most likely emission for near-silent
/// frames is the token "You" — the same family of artifact as Whisper's
/// "Thank you." / "Thanks for watching." on trailing silence.
///
/// The result is a bare word appended to the end of the final transcript, always
/// the same handful of tokens, never mid-utterance. It's library behavior we
/// can't configure away, so we strip it client-side.
///
/// **Deliberately narrow.** "you" is an extremely common real English word, and
/// plenty of real dictations legitimately end in it ("…that's up to you",
/// "thank you"). Stripping every trailing "you" would corrupt real speech — a far
/// worse failure than leaving an occasional artifact. So a candidate is removed
/// ONLY when every guard below holds:
///
///  1. It is the LAST token of the transcript.
///  2. It matches a known artifact phrase exactly (case-insensitive), ignoring
///     surrounding punctuation.
///  3. The text BEFORE it already ends in terminal punctuation (`.`/`!`/`?`/`…`).
///     A hallucination is decoded as its own utterance, so the real speech that
///     precedes it has already been closed off. In genuine speech the word is
///     part of the final clause ("up to you") and the preceding token is a plain
///     word, not a sentence end — which is what makes this guard discriminating.
///  4. Something real survives the strip (never blank the whole transcript).
///
/// Guard 3 is what makes this safe: "It's up to you." keeps its "you" (preceded
/// by "to"), while "Let's ship it. You" loses the stray tail.
///
/// Guard 3 does NOT protect phrases that are genuinely dictated as their own
/// closing sentence — "Please send the report. Thank you" or "See you at five.
/// Bye" end in terminal punctuation + a standalone closer exactly like the
/// artifact would. So the phrase list holds ONLY what Parakeet has actually
/// been observed to emit on silence (a bare "You"), not the Whisper folklore
/// family ("Thank you." / "Thanks for watching.") — those are common REAL
/// dictation endings (emails, chat sign-offs), and stripping them would
/// silently delete the user's words. If another artifact is ever observed,
/// it needs a discriminator stronger than guard 3 before joining the list.
///
/// Pure + Foundation-only so `swift test` covers it directly.
public enum ParakeetTailHallucination {

    /// Phrases Parakeet emits when decoding trailing zero-padding. Lowercased,
    /// punctuation-free; matched against the final token(s) of the transcript.
    /// ONLY observed artifacts belong here — every entry is a real-word phrase
    /// guard 3 can't always distinguish from genuine speech, so each addition
    /// is new risk of eating the user's words (see the type comment).
    static let artifactPhrases: Set<String> = [
        "you",
    ]

    /// Sentence-ending punctuation that marks the preceding speech as closed.
    private static let terminalPunctuation: Set<Character> = [".", "!", "?", "…"]

    /// Characters trimmed off a token before comparing it to `artifactPhrases`.
    private static let strippablePunctuation = CharacterSet(charactersIn: ".,!?;:…\"'“”‘’)")

    /// Remove a trailing silence-hallucination phrase from `text`, if one is
    /// present under all four guards. Returns `text` unchanged otherwise.
    ///
    /// Apply ONLY to a Parakeet FINAL transcript — not to partials (the artifact
    /// only appears on the zero-padded final flush) and not to other engines
    /// (their tails fail differently; Whisper's are already handled as bracketed
    /// non-speech markers by `TranscriptCleaner`).
    public static func strip(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { return text }

        // Try the longest phrases first so a multi-token phrase would win over
        // its own last word (a bare-"you" match inside "…done. Thank you" is
        // then rejected by guard 3 — "Thank" isn't terminal punctuation).
        let maxPhraseTokens = artifactPhrases.map { $0.split(separator: " ").count }.max() ?? 1

        for phraseLength in stride(from: min(maxPhraseTokens, tokens.count - 1), through: 1, by: -1) {
            let candidate = tokens.suffix(phraseLength)
                .map { normalize($0) }
                .joined(separator: " ")
            guard artifactPhrases.contains(candidate) else { continue }

            let remaining = tokens.dropLast(phraseLength)
            let head = remaining.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Guard 4: never blank the transcript.
            guard !head.isEmpty else { continue }
            // Guard 3: the real speech must already be closed off.
            guard let last = head.last, terminalPunctuation.contains(last) else { continue }
            return head
        }
        return text
    }

    /// Lowercase a token and strip surrounding punctuation, so "You." and "you"
    /// compare equal.
    private static func normalize(_ token: String) -> String {
        token.trimmingCharacters(in: strippablePunctuation).lowercased()
    }
}
