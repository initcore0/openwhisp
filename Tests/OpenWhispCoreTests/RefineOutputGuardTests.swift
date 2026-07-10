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

    // MARK: - Exemption resolver

    func testGuardOnByDefaultForPlainCleanup() {
        XCTAssertTrue(RefineOutputGuard.shouldLanguageGuard(
            translateToEnglish: false, mode: "rephrase",
            isSpokenInstructionRefine: false, isAgentBridgeRefine: false))
    }

    func testTranslateToEnglishNotGuarded() {
        XCTAssertFalse(RefineOutputGuard.shouldLanguageGuard(
            translateToEnglish: true, mode: "rephrase",
            isSpokenInstructionRefine: false, isAgentBridgeRefine: false))
    }

    func testImproveTranslationModeNotGuarded() {
        XCTAssertFalse(RefineOutputGuard.shouldLanguageGuard(
            translateToEnglish: false, mode: "improveTranslation",
            isSpokenInstructionRefine: false, isAgentBridgeRefine: false))
        // Case-insensitive / whitespace-tolerant.
        XCTAssertFalse(RefineOutputGuard.shouldLanguageGuard(
            translateToEnglish: false, mode: "  ImproveTranslation ",
            isSpokenInstructionRefine: false, isAgentBridgeRefine: false))
    }

    func testSpokenInstructionRefineNotGuarded() {
        XCTAssertFalse(RefineOutputGuard.shouldLanguageGuard(
            translateToEnglish: false, mode: "rephrase",
            isSpokenInstructionRefine: true, isAgentBridgeRefine: false))
    }

    func testAgentBridgeRefineNotGuarded() {
        XCTAssertFalse(RefineOutputGuard.shouldLanguageGuard(
            translateToEnglish: false, mode: "rephrase",
            isSpokenInstructionRefine: false, isAgentBridgeRefine: true))
    }

    // A user-authored Mode instruction owns the language contract (it may say
    // "translate to French") — the guard must never second-guess it.
    func testCustomModeInstructionExemptsGuard() {
        XCTAssertFalse(RefineOutputGuard.shouldLanguageGuard(
            translateToEnglish: false,
            mode: "rephrase",
            isSpokenInstructionRefine: false,
            isAgentBridgeRefine: false,
            hasCustomModeInstruction: true
        ))
        XCTAssertTrue(RefineOutputGuard.shouldLanguageGuard(
            translateToEnglish: false,
            mode: "rephrase",
            isSpokenInstructionRefine: false,
            isAgentBridgeRefine: false,
            hasCustomModeInstruction: false
        ))
    }
}
