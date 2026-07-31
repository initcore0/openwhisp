import XCTest
@testable import OpenWhispCore

/// EXPERIMENTAL live translation-preview panel: when is it armed, and when may
/// it spend a translator call?
///
/// The throttle is the interesting half. Apple's on-device translator costs
/// ~2.5s on its first call after a configuration change, while a streaming
/// engine emits partials every few hundred ms — so "translate every partial"
/// would queue faster than it drains and the panel would fall minutes behind.
/// These tests pin the three rules that keep it honest: serialize (one request
/// at a time), spend on sentence boundaries, and otherwise wait for quiet.
final class TranslationPreviewPolicyTests: XCTestCase {

    // MARK: - Arming (shouldShowPreview)

    private func armed(
        enabled: Bool = true,
        sessionActive: Bool = true,
        text: String = "Привет",
        translate: Bool = true,
        language: String = "ru",
        engine: String = EngineCapabilities.parakeet,
        available: Bool = true
    ) -> Bool {
        TranslationPreviewPolicy.shouldShowPreview(
            enabled: enabled, sessionActive: sessionActive, text: text,
            translateToEnglish: translate, language: language,
            transcriptionEngine: engine, textTranslationAvailable: available)
    }

    /// The whole point of the feature: an ASR-only engine + translate on +
    /// non-English speech is exactly the case where the live overlay shows the
    /// SPOKEN language and English appears only at paste.
    func testArmsForEveryASROnlyEngineWhenTextPathArms() {
        for engine in [EngineCapabilities.parakeet,
                       EngineCapabilities.appleSpeech,
                       EngineCapabilities.speechAnalyzer] {
            XCTAssertTrue(armed(engine: engine), "preview should arm for \(engine)")
        }
    }

    /// The preview is an opt-in experiment; off by default means off.
    func testDisabledTogglePreventsArming() {
        XCTAssertFalse(armed(enabled: false))
    }

    /// The panel is a session artifact — no live dictation, no panel.
    func testNoSessionNoPreview() {
        XCTAssertFalse(armed(sessionActive: false))
    }

    /// Nothing spoken yet → nothing to preview. Whitespace counts as empty, so
    /// the panel doesn't flash on a blank partial.
    func testEmptyOrWhitespaceTextHidesPreview() {
        XCTAssertFalse(armed(text: ""))
        XCTAssertFalse(armed(text: "   \n "))
    }

    /// Arming is delegated to `TextTranslationPolicy.shouldTranslateFinal`, so
    /// every reason THAT path stays dark also darkens the preview: translate
    /// off, English speech, no macOS 15 translator, or an engine that already
    /// translates natively (whisper — its live text is English already).
    func testArmingMirrorsTextTranslationPolicy() {
        XCTAssertFalse(armed(translate: false), "translate toggle off")
        XCTAssertFalse(armed(language: "en"), "English speech is a no-op")
        XCTAssertFalse(armed(language: "en-US"), "regional English too")
        XCTAssertFalse(armed(available: false), "macOS 14 has no text translator")
        XCTAssertFalse(armed(engine: EngineCapabilities.whisperKit),
                       "native-translate engine already streams English")
        // "auto" is not English — the speaker may be dictating anything.
        XCTAssertTrue(armed(language: "auto"))
    }

    // MARK: - Throttle (shouldFire)

    private func fire(
        current: String,
        last: String = "",
        quiet: TimeInterval = 0,
        inFlight: Bool = false
    ) -> Bool {
        TranslationPreviewPolicy.shouldFire(
            currentText: current, lastTranslatedSource: last,
            secondsSinceTextChanged: quiet, translationInFlight: inFlight)
    }

    /// Rule 1: serialize. Even a fully-formed new sentence waits its turn — a
    /// backlog of in-flight requests is what made the naive version useless.
    func testNeverFiresWhileOneIsInFlight() {
        XCTAssertFalse(fire(current: "Привет мир.", inFlight: true))
        XCTAssertFalse(fire(current: "Привет мир", quiet: 99, inFlight: true))
    }

    /// Rule 2: a sentence boundary in the NEW text is the cheap, natural moment
    /// to spend a call — no waiting for quiet.
    func testFiresImmediatelyOnSentenceBoundary() {
        XCTAssertTrue(fire(current: "Привет, как дела?"))
        XCTAssertTrue(fire(current: "Это тест."), "Cyrillic text with an ASCII period")
        XCTAssertTrue(fire(current: "Стоп!"))
        XCTAssertTrue(fire(current: "Ну…"))
        XCTAssertTrue(fire(current: "これはテストです。"), "ideographic full stop")
        XCTAssertTrue(fire(current: "هل هذا اختبار؟"), "Arabic question mark")
    }

    /// Trailing whitespace and closing quotes/brackets don't hide the period.
    func testSentenceBoundaryLooksPastClosersAndWhitespace() {
        XCTAssertTrue(fire(current: "Он сказал «привет.»  "))
        XCTAssertTrue(fire(current: "Готово (наконец.)"))
        XCTAssertTrue(fire(current: "Это тест.   "))
    }

    /// Only the DELTA counts: the previous sentence's period was already spent,
    /// so an unfinished continuation must wait for quiet rather than re-firing
    /// on every partial.
    func testAlreadySpentSentenceDoesNotKeepFiring() {
        let last = "Это тест."
        XCTAssertFalse(fire(current: last + " Ещё", last: last),
                       "the new words don't end a sentence — wait for quiet")
        XCTAssertTrue(fire(current: last + " Ещё одно предложение.", last: last),
                      "the new words DO end a sentence")
    }

    /// Rule 3: mid-sentence text still gets translated once the speaker pauses.
    func testDebounceFiresAfterQuietInterval() {
        let text = "Привет мир"
        XCTAssertFalse(fire(current: text, quiet: 0.2), "still streaming")
        XCTAssertFalse(fire(current: text, quiet: TranslationPreviewPolicy.quietInterval - 0.1))
        XCTAssertTrue(fire(current: text, quiet: TranslationPreviewPolicy.quietInterval))
        XCTAssertTrue(fire(current: text, quiet: 3))
    }

    /// Nothing new to translate → don't spend a call, however long it's been
    /// quiet. This is what stops the debounce from firing forever on a finished
    /// transcript.
    func testUnchangedSourceNeverRefires() {
        XCTAssertFalse(fire(current: "Это тест.", last: "Это тест.", quiet: 99))
        XCTAssertFalse(fire(current: "Это тест.  ", last: "Это тест.", quiet: 99),
                       "whitespace-only growth isn't new text")
        XCTAssertFalse(fire(current: "", last: "Это тест.", quiet: 99))
    }

    /// Latest-wins: a result landing for STALE source text must immediately
    /// re-fire for what's on screen now. Modelled here as the moment the
    /// in-flight flag clears while the transcript has moved on — even with zero
    /// quiet time, because the delta ends a sentence.
    func testRefiresWhenResultLandsForStaleSource() {
        let translated = "Первое предложение."
        let current = translated + " Второе предложение."
        XCTAssertFalse(fire(current: current, last: translated, inFlight: true))
        XCTAssertTrue(fire(current: current, last: translated, inFlight: false))
    }

    /// A streaming engine that REWRITES its tail (rather than appending) has no
    /// clean suffix; the whole current text is the delta, so a rewrite that now
    /// ends in a period still counts as a sentence.
    func testRewrittenPartialTreatsWholeTextAsDelta() {
        XCTAssertEqual(
            TranslationPreviewPolicy.delta(current: "Привет мир", last: "Пока"),
            "Привет мир")
        XCTAssertEqual(
            TranslationPreviewPolicy.delta(current: "Привет мир", last: "Привет "),
            "мир")
        XCTAssertTrue(fire(current: "Привет мир.", last: "Пока друг"),
                      "rewritten tail ending in a period fires")
    }

    /// A word with no punctuation and no pause never fires — the case that
    /// would otherwise flood the translator.
    func testStreamingWordsWithoutPauseOrPunctuationDoNotFire() {
        var last = ""
        for word in ["Привет", "Привет мир", "Привет мир как", "Привет мир как дела"] {
            XCTAssertFalse(fire(current: word, last: last, quiet: 0.1),
                           "mid-stream partial \(word) should not fire")
            last = ""
        }
    }
}
