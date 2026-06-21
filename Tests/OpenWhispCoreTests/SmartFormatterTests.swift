import XCTest
@testable import OpenWhispCore

final class SmartFormatterTests: XCTestCase {
    private let f = SmartFormatter(options: .default)

    func testBasicCapitalizationAndLeadingSpace() {
        XCTAssertEqual(f.format(" hello world", language: "en"), "Hello world")
    }

    func testFillerRemoval() {
        XCTAssertEqual(f.format("um so the uh plan is good", language: "en"), "So the plan is good")
    }

    func testSpokenComma() {
        XCTAssertEqual(f.format("first comma second comma third", language: "en"), "First, second, third")
    }

    func testSpokenPeriodCapitalizesNext() {
        XCTAssertEqual(f.format("hello period how are you", language: "en"), "Hello. How are you")
    }

    func testNewLine() {
        XCTAssertEqual(f.format("line one new line line two", language: "en"), "Line one\nLine two")
    }

    func testNewParagraph() {
        XCTAssertEqual(f.format("para one new paragraph para two", language: "en"), "Para one\n\nPara two")
    }

    func testStandaloneI() {
        XCTAssertEqual(f.format("i think i am right", language: "en"), "I think I am right")
    }

    func testQuestionMark() {
        XCTAssertEqual(f.format("are you sure question mark", language: "en"), "Are you sure?")
    }

    func testDoesNotEatWordsContainingMarkers() {
        // "music" inside "musician", "um" inside "umbrella" must survive.
        XCTAssertEqual(f.format("the musician played", language: "en"), "The musician played")
        XCTAssertEqual(f.format("the umbrella um is here", language: "en"), "The umbrella is here")
    }

    func testDoesNotRemoveLike() {
        XCTAssertEqual(f.format("i like this a lot", language: "en"), "I like this a lot")
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(f.format("hello    world", language: "en"), "Hello world")
    }

    func testNonEnglishSkipsCapitalization() {
        XCTAssertEqual(f.format("привет мир", language: "ru"), "привет мир")
    }

    func testAllOffIsNearPassthrough() {
        let off = SmartFormatter(options: SmartFormatter.Options(
            removeFillers: false, applySpokenPunctuation: false,
            capitalizeSentences: false, ensureTerminalPunctuation: false))
        XCTAssertEqual(off.format("um the comma plan", language: "en"), "um the comma plan")
    }

    func testCombo() {
        XCTAssertEqual(
            f.format(" um i think comma therefore i am period done", language: "en"),
            "I think, therefore I am. Done")
    }
}
