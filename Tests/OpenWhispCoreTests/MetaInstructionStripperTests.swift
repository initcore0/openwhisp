import XCTest
@testable import OpenWhispCore

final class MetaInstructionStripperTests: XCTestCase {

    // MARK: Should strip (trailing translate/transcribe instructions)

    func testTranslateThisIntoEnglish() {
        let input = "Please conduct the research again to identify which features have already been added and which ones could potentially be added. Translate this into English."
        let expected = "Please conduct the research again to identify which features have already been added and which ones could potentially be added."
        XCTAssertEqual(MetaInstructionStripper.strip(input), expected)
    }

    func testTranslateThisToEnglish() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("the meeting is at noon tomorrow. translate this to English"),
            "the meeting is at noon tomorrow.")
    }

    func testTranslateToEnglishNoThis() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("we should ship the feature soon. translate to English"),
            "we should ship the feature soon.")
    }

    func testTrailingPleaseAndPunctuation() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("call the bank in the morning, translate this into English, please."),
            "call the bank in the morning.")
    }

    func testTranscribeThis() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("here is the summary of our discussion. transcribe this"),
            "here is the summary of our discussion.")
    }

    // MARK: Must NOT strip (legitimate content)

    func testKeepsTrailingLanguageNameAsContent() {
        // A bare trailing "in <language>" is NOT a command — "…documentation in
        // English" is legitimate dictation and must survive intact.
        let s = "Can you send me the documentation in English"
        XCTAssertEqual(MetaInstructionStripper.strip(s), s)
    }

    func testKeepsRussianTrailingLanguageNameAsContent() {
        // Same for the bare Russian "на <язык>" directive.
        let s = "Я перевожу книгу на английский"
        XCTAssertEqual(MetaInstructionStripper.strip(s), s)
    }

    func testDoesNotMatchInsideWords() {
        // The command verb must start at a word boundary: "mistranslate" is
        // content, not a "translate" command ("The app might mis." bug).
        let s = "The app might mistranslate this into English"
        XCTAssertEqual(MetaInstructionStripper.strip(s), s)
    }

    func testDoesNotConsumeTrailingWordsAfterLanguage() {
        // The language slot is a whitelist, not a greedy [a-z ]+ — trailing
        // words after the language name mean this is content, not a command.
        let s = "I don't know how to translate this to English properly"
        XCTAssertEqual(MetaInstructionStripper.strip(s), s)
    }

    func testKeepsInEnglishAsContent() {
        // "...written in English" mid-sentence is content, not a trailing directive.
        let s = "the document was originally written in English and then revised"
        XCTAssertEqual(MetaInstructionStripper.strip(s), s)
    }

    func testKeepsPlainSentence() {
        let s = "let's translate the contract next week with the legal team"
        XCTAssertEqual(MetaInstructionStripper.strip(s), s)
    }

    func testDoesNotEmptyWhenOnlyInstruction() {
        // No real content before the instruction → leave it untouched rather than empty.
        XCTAssertEqual(MetaInstructionStripper.strip("translate this into English"),
                       "translate this into English")
    }

    func testEmptyInput() {
        XCTAssertEqual(MetaInstructionStripper.strip(""), "")
    }

    func testNoInstructionUnchanged() {
        let s = "just a normal note about the project status."
        XCTAssertEqual(MetaInstructionStripper.strip(s), s)
    }

    // MARK: Leading "please" / politeness lead-in (regression for the reported bug)

    func testLeadingPleaseTranslate() {
        // The reported bug: "Please translate…" left "Please" in the output.
        XCTAssertEqual(
            MetaInstructionStripper.strip("Hello, how are you? Please translate this into English."),
            "Hello, how are you?")
    }

    func testLeadingPleasePreservesPeriod() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("Hello, how are you. Please translate this into English"),
            "Hello, how are you.")
    }

    func testCouldYouLeadIn() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("the meeting is at noon, could you translate this to English please"),
            "the meeting is at noon.")
    }

    func testKindlyLeadIn() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("ship it on Friday, kindly translate to English"),
            "ship it on Friday.")
    }

    // MARK: Terminal punctuation preserved

    func testPreservesQuestionMark() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("are we still on for tomorrow? translate this to English"),
            "are we still on for tomorrow?")
    }

    func testPreservesExclamation() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("that's amazing! translate this to English"),
            "that's amazing!")
    }

    func testLeadingPleaseDoesNotOverStrip() {
        let s = "please review the document by Monday"
        XCTAssertEqual(MetaInstructionStripper.strip(s), s)
    }

    // MARK: Russian translate command (dictated in RU with translate-on)

    // These are the exact transcripts whisper produced for the reported bug — the
    // Russian command must be stripped BEFORE the text reaches the LLM, else the
    // model "executes" it and bakes the instruction into the translated output.
    func testRussianTranslateStrippedExclamation() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("Всем привет! Пожалуйста, переведи на английский!"),
            "Всем привет!")
    }

    func testRussianTranslateStrippedPeriod() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("Всем привет, пожалуйста переведи на английский."),
            "Всем привет.")
    }

    func testRussianTranslateNoPolitenessLead() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("Привет всем. Переведи на английский."),
            "Привет всем.")
    }

    func testRussianTranslateWithObjectWord() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("Запиши заметку про встречу переведи это на английский"),
            "Запиши заметку про встречу.")
    }

    func testRussianCommandOnlyIsLeftUntouched() {
        // No real content before the command — never empty the text.
        let s = "Переведи на английский."
        XCTAssertEqual(MetaInstructionStripper.strip(s), s)
    }

    func testRussianMentioningLanguageIsNotStripped() {
        // "учу английский язык" is ordinary content, not a "на <язык>" directive.
        let s = "Я учу английский язык каждый день."
        XCTAssertEqual(MetaInstructionStripper.strip(s), s)
    }
}
