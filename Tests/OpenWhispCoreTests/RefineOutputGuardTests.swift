import XCTest
@testable import OpenWhispCore

/// Unit tests for the language guard that rejects AI cleanup which silently
/// translated a non-Latin dictation (the Russian → English bug).
final class RefineOutputGuardTests: XCTestCase {

    // MARK: - Rejections (the bug)

    /// Russian dictation whose "cleanup" came back English → REJECT.
    func testCyrillicInputEnglishOutputRejected() {
        let input = "Привет команда я сегодня работаю из дома и приду позже"
        let output = "Hi team, I am working from home today and will arrive later."
        XCTAssertTrue(RefineOutputGuard.outputTranslatedAway(input: input, output: output))
    }

    /// CJK (Han) dictation translated to English → REJECT.
    func testHanInputEnglishOutputRejected() {
        let input = "你好团队我今天在家工作稍后会到达办公室"
        let output = "Hi team, I am working from home today."
        XCTAssertTrue(RefineOutputGuard.outputTranslatedAway(input: input, output: output))
    }

    // MARK: - Acceptances (must never false-reject)

    /// Russian in → Russian out (a real same-language cleanup) → ACCEPT.
    func testCyrillicInputCyrillicOutputAccepted() {
        let input = "привет команда я сегодня работаю из дома"
        let output = "Привет, команда! Я сегодня работаю из дома."
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: input, output: output))
    }

    /// Latin → Latin cleanup → ACCEPT.
    func testLatinInputLatinOutputAccepted() {
        let input = "hey team i am working from home today and will be a little late"
        let output = "Hey team, I am working from home today and will be a little late."
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: input, output: output))
    }

    /// Russian prose sprinkled with English identifiers/URLs; the output keeps the
    /// Cyrillic → ACCEPT (mixed content must not trip the guard).
    func testRussianWithEnglishIdentifiersAccepted() {
        let input = "давай задеплоим ветку feature/login на staging через github actions сегодня"
        let output = "Давай задеплоим ветку feature/login на staging через GitHub Actions сегодня."
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: input, output: output))
    }

    /// Short input (< min letters) → ACCEPT even if scripts differ (too little signal).
    func testShortInputAccepted() {
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: "привет", output: "hi"))
    }

    /// Empty / whitespace inputs are safe (no letters → pass).
    func testEmptyAndWhitespaceSafe() {
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: "", output: ""))
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: "   \n\t ", output: "hello"))
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: "Привет команда как дела", output: ""))
    }

    /// Digits/punctuation/emoji are ignored, so a Russian input with numbers and
    /// emoji still counts as Russian and is guarded when translated.
    func testDigitsAndEmojiIgnoredStillRejectsTranslation() {
        let input = "встреча в 15:00 сегодня 🎉 не забудь принести отчёт пожалуйста"
        let output = "Meeting at 15:00 today 🎉, don't forget to bring the report."
        XCTAssertTrue(RefineOutputGuard.outputTranslatedAway(input: input, output: output))
    }

    // MARK: - Symmetric rejection (the English → Russian regression)

    /// English dictation whose "cleanup" came back Russian → REJECT. This is the
    /// inverse of the original bug and the one the user hit: a stale target-language
    /// picker made the polish prompt produce Russian for an English dictation.
    func testLatinInputCyrillicOutputRejected() {
        let input = "hey team i am working from home today and will arrive a little later than usual"
        let output = "Привет команда, я сегодня работаю из дома и приду немного позже обычного."
        XCTAssertTrue(RefineOutputGuard.outputTranslatedAway(input: input, output: output))
    }

    /// An INTENDED translate-to-X flow that lands in its expected script → ACCEPT.
    /// (English polished to English is the real improveTranslation contract.)
    func testExpectedScriptTranslationAccepted() {
        let input = "hey team i am working from home today and will arrive a little later than usual"
        let englishOut = "Hey team, I'm working from home today and will arrive a little later than usual."
        // English in, English out, expecting Latin → accept.
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(
            input: input, output: englishOut, expectedOutputScript: .latin))
    }

    /// An intended translation whose expected target IS the other script → ACCEPT
    /// (proves the opt-out works: e.g. a genuine translate-to-Russian flow).
    func testIntendedCyrillicTargetAccepted() {
        let input = "hey team i am working from home today and will arrive a little later than usual"
        let output = "Привет команда, я сегодня работаю из дома и приду немного позже обычного."
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(
            input: input, output: output, expectedOutputScript: .cyrillic))
    }

    /// But an intended English translation that STILL drifted to Russian is rejected
    /// even with an expected script — the drift is to a DIFFERENT script than expected.
    func testDriftAwayFromExpectedScriptRejected() {
        let input = "hey team i am working from home today and will arrive a little later than usual"
        let output = "Привет команда, я сегодня работаю из дома и приду немного позже обычного."
        XCTAssertTrue(RefineOutputGuard.outputTranslatedAway(
            input: input, output: output, expectedOutputScript: .latin))
    }

    /// Japanese mixes Kana and Han within one language; a Japanese → Japanese
    /// cleanup must never self-reject even if the dominant bucket flaps between
    /// Han and Kana across input and output. The keep-share check anchors on the
    /// INPUT's dominant script surviving in the output (it always does for real
    /// Japanese), so no rejection.
    func testJapaneseCleanupNotRejectedAcrossKanaHanMix() {
        // Kana-dominant input.
        let input = "きょうは ざいたくで しごとを します。すこし おくれて とうちゃくします。"
        // Han-heavier cleaned output of the same sentence.
        let output = "今日は在宅で仕事をします。少し遅れて到着します。"
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: input, output: output))
        // And the reverse direction.
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: output, output: input))
    }

    /// English prose whose cleanup adds foreign loanwords/names stays Latin → pass.
    func testEnglishWithLoanwordsNotRejected() {
        let input = "we met at the cafe with francois and talked about the zeitgeist of the project"
        let output = "We met at the café with François and talked about the Zeitgeist of the project."
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: input, output: output))
    }

    /// Code-mixed input (English code + Cyrillic comments) cleaned to a slightly
    /// different mix ratio must pass — the input's dominant script survives.
    func testCodeMixedCleanupNotRejected() {
        let input = "let userCount = fetchUsers().count // считаем всех активных пользователей в базе данных"
        let output = "let userCount = fetchUsers().count // Считаем всех активных пользователей в базе."
        XCTAssertFalse(RefineOutputGuard.outputTranslatedAway(input: input, output: output))
    }

    // MARK: - Language-code → script mapping

    func testScriptForLanguageCode() {
        XCTAssertEqual(RefineOutputGuard.script(forLanguageCode: "ru"), .cyrillic)
        XCTAssertEqual(RefineOutputGuard.script(forLanguageCode: " EN "), .latin)
        XCTAssertEqual(RefineOutputGuard.script(forLanguageCode: "zh"), .han)
        XCTAssertNil(RefineOutputGuard.script(forLanguageCode: "xx"))
    }

    // MARK: - Expected-cleanup-script resolver (root-cause path)

    /// The reported combo: improveTranslation mode + stale target "ru". The engine
    /// only ever translates to English, so the polish target is pinned to English —
    /// the resolver reports Latin regardless of the stale picker value, so an
    /// English → Russian output is caught (guarded), not waved through.
    func testImproveTranslationExpectsLatinEvenWithStaleRussianTarget() {
        XCTAssertEqual(
            RefineOutputGuard.expectedCleanupScript(
                translateToEnglish: true, mode: "improveTranslation",
                translationTargetLanguage: "ru"),
            .latin)
    }

    func testTranslateToEnglishExpectsLatin() {
        XCTAssertEqual(
            RefineOutputGuard.expectedCleanupScript(
                translateToEnglish: true, mode: "rephrase",
                translationTargetLanguage: "en"),
            .latin)
    }

    /// Stale-mode corner: `improveTranslation` left in settings while Translate to
    /// English is OFF. The improve-translation prompt only runs when
    /// translateToEnglish is on (CleanupIntensity.wholeTextCustomInstruction), so
    /// this session is a plain same-language cleanup — a Russian → English drift
    /// must still be caught, i.e. NO expected script. Mode alone must never relax
    /// the guard, or the original PR #157 bug comes back through stale settings.
    func testStaleImproveTranslationModeWithoutTranslateExpectsNoScript() {
        XCTAssertNil(
            RefineOutputGuard.expectedCleanupScript(
                translateToEnglish: false, mode: "improveTranslation",
                translationTargetLanguage: "ru"))
    }

    /// And the full end-to-end shape of that corner: Russian input, English output,
    /// no expected script (stale improveTranslation, translate off) → REJECT.
    func testStaleImproveTranslationModeStillCatchesRussianToEnglish() {
        let input = "Привет команда, я сегодня работаю из дома и приду немного позже обычного."
        let output = "Hi team, I am working from home today and will arrive a little later than usual."
        let expected = RefineOutputGuard.expectedCleanupScript(
            translateToEnglish: false, mode: "improveTranslation",
            translationTargetLanguage: "ru")
        XCTAssertTrue(RefineOutputGuard.outputTranslatedAway(
            input: input, output: output, expectedOutputScript: expected))
    }

    func testPlainCleanupExpectsNoScript() {
        XCTAssertNil(
            RefineOutputGuard.expectedCleanupScript(
                translateToEnglish: false, mode: "rephrase",
                translationTargetLanguage: "en"))
    }

    // MARK: - Exemption resolver

    func testGuardOnByDefaultForPlainCleanup() {
        XCTAssertTrue(RefineOutputGuard.shouldLanguageGuard(
            isSpokenInstructionRefine: false, isAgentBridgeRefine: false))
    }

    func testSpokenInstructionRefineNotGuarded() {
        XCTAssertFalse(RefineOutputGuard.shouldLanguageGuard(
            isSpokenInstructionRefine: true, isAgentBridgeRefine: false))
    }

    func testAgentBridgeRefineNotGuarded() {
        XCTAssertFalse(RefineOutputGuard.shouldLanguageGuard(
            isSpokenInstructionRefine: false, isAgentBridgeRefine: true))
    }

    // A user-authored Mode instruction owns the language contract (it may say
    // "translate to French") — the guard must never second-guess it.
    func testCustomModeInstructionExemptsGuard() {
        XCTAssertFalse(RefineOutputGuard.shouldLanguageGuard(
            isSpokenInstructionRefine: false,
            isAgentBridgeRefine: false,
            hasCustomModeInstruction: true
        ))
        XCTAssertTrue(RefineOutputGuard.shouldLanguageGuard(
            isSpokenInstructionRefine: false,
            isAgentBridgeRefine: false,
            hasCustomModeInstruction: false
        ))
    }
}
