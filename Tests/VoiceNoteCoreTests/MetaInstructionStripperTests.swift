import XCTest
@testable import VoiceNoteCore

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

    func testBareInRussian() {
        XCTAssertEqual(
            MetaInstructionStripper.strip("вот мой длинный текст для заметки. in Russian"),
            "вот мой длинный текст для заметки.")
    }

    // MARK: Must NOT strip (legitimate content)

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
}
