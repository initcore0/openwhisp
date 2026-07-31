import Foundation

/// EXPERIMENTAL. When should the live translation-preview panel show, and when
/// should it fire the next translation?
///
/// Background: with an ASR-only engine (Parakeet / Apple Speech /
/// SpeechAnalyzer) and "Translate to English" on, `TextTranslationPolicy`
/// arms the TEXT path — the engine streams the SPOKEN language into the
/// overlay and only the FINAL transcript is translated, at paste time. So the
/// user watching the overlay sees Russian the whole way and English only after
/// the fact. The preview panel closes that gap: a second, display-only panel
/// that translates the live partial transcript as it grows, so translation
/// quality can be judged while speaking.
///
/// Display-only: nothing here ever feeds the document. The final paste keeps
/// going through the shipped text path untouched.
///
/// This type is the pure, testable half. It answers two questions:
///
///   * `shouldShowPreview` — is the preview armed at all? Exactly
///     `TextTranslationPolicy.shouldTranslateFinal` (the preview is meaningful
///     precisely when that path arms — otherwise English is already on screen,
///     or translation isn't happening) plus the experimental opt-in and a
///     non-empty transcript.
///   * `shouldFire` — should we call the translator RIGHT NOW for this text?
///     Apple's translator costs ~2.5s on the first call after a configuration
///     change and is not free afterwards, so a naive "translate every partial"
///     would queue faster than it drains. The throttle keeps one request in
///     flight at a time and only spends it on text worth translating.
public enum TranslationPreviewPolicy {

    /// How long the transcript must sit UNCHANGED before a mid-sentence chunk
    /// is worth translating. Long enough that ordinary word-by-word streaming
    /// doesn't trigger it (partials land every few hundred ms), short enough
    /// that a speaker pausing to think sees their sentence appear.
    public static let quietInterval: TimeInterval = 1.2

    /// Sentence-ending punctuation. ASCII plus the ideographic/Arabic forms, so
    /// a Japanese or Arabic dictation ends sentences too. Cyrillic and other
    /// Latin-punctuated scripts use the ASCII marks (Russian "Привет." ends a
    /// sentence here exactly like English does) — this is punctuation-based,
    /// never script-based.
    private static let sentenceEnders: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？", "؟",
    ]

    /// Is the preview armed for this session?
    ///
    /// Same inputs as `TextTranslationPolicy.shouldTranslateFinal` plus:
    ///   * `enabled` — the experimental opt-in (its own UserDefaults key, owned
    ///     by the controller, deliberately NOT an AppState property: AppState is
    ///     under the MAK-32 LOC ratchet),
    ///   * `sessionActive` — a dictation is live (recording or transcribing);
    ///     the panel is a session artifact and never outlives one,
    ///   * `text` — an empty/whitespace transcript has nothing to preview, so
    ///     the panel stays hidden until the first words land.
    public static func shouldShowPreview(
        enabled: Bool,
        sessionActive: Bool,
        text: String,
        translateToEnglish: Bool,
        language: String,
        transcriptionEngine: String,
        textTranslationAvailable: Bool
    ) -> Bool {
        guard enabled, sessionActive else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return TextTranslationPolicy.shouldTranslateFinal(
            translateToEnglish: translateToEnglish,
            language: language,
            transcriptionEngine: transcriptionEngine,
            textTranslationAvailable: textTranslationAvailable)
    }

    /// Should a translation request be issued NOW for `currentText`?
    ///
    /// - Parameters:
    ///   - currentText: the live partial transcript.
    ///   - lastTranslatedSource: the exact source string of the most recent
    ///     COMPLETED (or in-flight) request — the text whose translation is on
    ///     screen. Empty before the first request.
    ///   - secondsSinceTextChanged: how long `currentText` has been unchanged.
    ///   - translationInFlight: a request is out and hasn't resolved yet.
    ///
    /// Rules, in order:
    ///   1. Never while one is in flight — requests are serialized, so a slow
    ///      translator can't build a backlog of stale partials. When the
    ///      in-flight one lands the caller re-asks; if the transcript advanced
    ///      meanwhile this returns true again (latest-wins).
    ///   2. Nothing new to say → no.
    ///   3. The DELTA since the last translated source ends a sentence → fire
    ///      immediately (the natural, cheap moment: a complete clause).
    ///   4. Otherwise fire once the text has been quiet for `quietInterval` —
    ///      the speaker paused mid-sentence and deserves to see something.
    public static func shouldFire(
        currentText: String,
        lastTranslatedSource: String,
        secondsSinceTextChanged: TimeInterval,
        translationInFlight: Bool
    ) -> Bool {
        if translationInFlight { return false }
        let current = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return false }
        let last = lastTranslatedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        // Already translated exactly this — including the case where the engine
        // revised a partial back to what we last sent.
        guard current != last else { return false }

        if endsSentence(delta(current: current, last: last)) { return true }
        return secondsSinceTextChanged >= quietInterval
    }

    /// The new text since `last`. When the partial was REWRITTEN rather than
    /// appended to (streaming engines revise their tail), there is no clean
    /// suffix — the whole current text counts as the delta, which is the
    /// conservative answer: a rewrite that ends a sentence is still a sentence.
    static func delta(current: String, last: String) -> String {
        guard !last.isEmpty, current.hasPrefix(last) else { return current }
        return String(current.dropFirst(last.count))
    }

    /// Does this chunk end on sentence punctuation? Trailing whitespace and
    /// closing quotes/brackets are looked past, so `он сказал "привет."` counts.
    static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "»", "”", "’", ")", "]", "}", "」", "』"]
        let skippable: (Character) -> Bool = { $0.isWhitespace || closers.contains($0) }
        guard let last = text.reversed().first(where: { !skippable($0) }) else { return false }
        return sentenceEnders.contains(last)
    }
}
