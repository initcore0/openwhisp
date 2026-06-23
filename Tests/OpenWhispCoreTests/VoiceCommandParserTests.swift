import XCTest
@testable import OpenWhispCore

final class VoiceCommandParserTests: XCTestCase {
    private let p = VoiceCommandParser(wakeWord: "voice note")
    private let pNoWake = VoiceCommandParser(wakeWord: "")

    func testTrailingImperative() {
        let r = pNoWake.parse("we should ship the feature tomorrow. Make this formal")
        XCTAssertEqual(r?.content, "we should ship the feature tomorrow.")
        XCTAssertEqual(r?.instruction.lowercased(), "make this formal")
    }

    func testTranslateThisTo() {
        let r = pNoWake.parse("hello how are you. translate this to Russian")
        XCTAssertEqual(r?.content, "hello how are you.")
        XCTAssertEqual(r?.instruction.lowercased(), "translate this to russian")
    }

    func testWakeWordForm() {
        let r = p.parse("the meeting is at noon, voice note make this shorter")
        // content gets terminal punctuation restored
        XCTAssertEqual(r?.content, "the meeting is at noon.")
        XCTAssertEqual(r?.instruction.lowercased(), "make this shorter")
    }

    func testSummarizeThis() {
        let r = pNoWake.parse("here are the three main points we discussed today at length. summarize this")
        XCTAssertEqual(r?.content, "here are the three main points we discussed today at length.")
        XCTAssertEqual(r?.instruction.lowercased(), "summarize this")
    }

    // False positives that MUST NOT be treated as commands:

    func testPlainSentenceNotACommand() {
        XCTAssertNil(pNoWake.parse("make sure to call the bank tomorrow"))
    }

    func testMakeItHappenWholeMessage() {
        XCTAssertNil(pNoWake.parse("make it happen"))
    }

    func testLongCommandClauseIgnored() {
        XCTAssertNil(pNoWake.parse("hi there friend. make this much more formal and professional and polished please thanks"))
    }

    func testMidSentenceVerbNotACommand() {
        XCTAssertNil(pNoWake.parse("I think we should rewrite this module next sprint"))
    }

    func testSingleSentenceNoCommand() {
        XCTAssertNil(pNoWake.parse("just a normal sentence"))
    }

    func testWakeWordButNoContent() {
        XCTAssertNil(p.parse("voice note make this formal"))
    }

    // MARK: Telegram-post built-in action

    func testTelegramPostEnglish() {
        let r = pNoWake.parse("We shipped dark mode and faster sync. Make a telegram post.")
        XCTAssertEqual(r?.action, .telegramPost)
        XCTAssertEqual(r?.content, "We shipped dark mode and faster sync.")
    }

    func testTelegramPostPhraseVariants() {
        XCTAssertEqual(pNoWake.parse("the release is live and tested, make this a telegram post")?.action, .telegramPost)
        XCTAssertEqual(pNoWake.parse("our feature is great, post to telegram")?.action, .telegramPost)
    }

    func testTelegramPostRussian() {
        let r = pNoWake.parse("Мы выпустили обновление с тёмной темой. Сделай пост для телеграм.")
        XCTAssertEqual(r?.action, .telegramPost)
        XCTAssertEqual(r?.content, "Мы выпустили обновление с тёмной темой.")
    }

    func testTelegramNotTriggeredByMention() {
        // "telegram" as content, not a trailing command, must not fire.
        XCTAssertNil(pNoWake.parse("I sent the file to him on telegram yesterday"))
        XCTAssertNil(pNoWake.parse("please add my telegram handle to the contact list"))
    }

    func testTelegramPostNeedsContent() {
        // Pure command, no preceding content -> not a command (don't empty text).
        XCTAssertNil(pNoWake.parse("make a telegram post"))
    }

    func testGenericCommandHasNoAction() {
        XCTAssertNil(pNoWake.parse("ship it on Friday. make this formal")?.action)
    }
}
