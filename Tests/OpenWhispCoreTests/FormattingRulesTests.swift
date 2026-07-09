import XCTest
@testable import OpenWhispCore

/// Tests for the MAK-20 opt-in structural formatting rule groups:
/// number / currency normalization, spoken lists, and basic markdown.
///
/// Every group is OFF by default; these tests prove (a) it transforms correctly
/// when its flag is on, (b) it leaves ordinary prose alone, and (c) it is a
/// no-op when the flag is off. The pre-existing default pipeline is exercised in
/// `SmartFormatterTests` and must remain unchanged.
final class FormattingRulesTests: XCTestCase {

    // Build a formatter with exactly one rule group enabled on top of the
    // existing default behavior (caps + fillers + spoken punctuation), so we test
    // each group in a realistic pipeline, not in isolation.
    private func formatter(
        numbers: Bool = false,
        currency: Bool = false,
        lists: Bool = false,
        markdown: Bool = false
    ) -> SmartFormatter {
        SmartFormatter(options: SmartFormatter.Options(
            removeFillers: true,
            applySpokenPunctuation: true,
            capitalizeSentences: true,
            ensureTerminalPunctuation: false,
            normalizeNumbers: numbers,
            normalizeCurrency: currency,
            spokenLists: lists,
            basicMarkdown: markdown
        ))
    }

    // The stock default formatter — every new group OFF.
    private let plain = SmartFormatter(options: .default)

    // MARK: - Defaults: new groups are OFF and change nothing

    func testDefaultOptionsHaveAllNewGroupsOff() {
        let o = SmartFormatter.Options.default
        XCTAssertFalse(o.normalizeNumbers)
        XCTAssertFalse(o.normalizeCurrency)
        XCTAssertFalse(o.spokenLists)
        XCTAssertFalse(o.basicMarkdown)
    }

    func testDefaultPipelineLeavesStructuralInputAlone() {
        // With the stock default formatter, none of the new transforms fire.
        XCTAssertEqual(plain.format("five dollars", language: "en"), "Five dollars")
        XCTAssertEqual(plain.format("bullet buy milk", language: "en"), "Bullet buy milk")
        XCTAssertEqual(plain.format("bold important", language: "en"), "Bold important")
        XCTAssertEqual(plain.format("twenty twenty six", language: "en"), "Twenty twenty six")
    }

    // MARK: - Currency

    func testCurrencyDollars() {
        let f = formatter(currency: true)
        XCTAssertEqual(f.format("it costs five dollars", language: "en"), "It costs $5")
        XCTAssertEqual(f.format("one dollar please", language: "en"), "$1 please")
    }

    func testCurrencyCents() {
        let f = formatter(currency: true)
        XCTAssertEqual(f.format("that is ten cents", language: "en"), "That is 10¢")
        XCTAssertEqual(f.format("just one cent", language: "en"), "Just 1¢")
    }

    func testCurrencyWithDigitAmount() {
        let f = formatter(currency: true)
        // Already-digit amounts also collapse to the symbol form.
        XCTAssertEqual(f.format("pay 20 dollars", language: "en"), "Pay $20")
    }

    func testCurrencyCompoundAmount() {
        let f = formatter(currency: true)
        XCTAssertEqual(f.format("twenty five dollars", language: "en"), "$25")
    }

    func testCurrencyPreservesTrailingPunctuation() {
        let f = formatter(currency: true)
        // whisper may attach a period to "dollars." — it must survive on the $ form.
        XCTAssertEqual(f.format("it was five dollars. thanks", language: "en"), "It was $5. Thanks")
    }

    func testCurrencyLeavesNonNumberDollarsAlone() {
        let f = formatter(currency: true)
        // "dollars" with no preceding number is ordinary prose.
        XCTAssertEqual(f.format("i love dollars", language: "en"), "I love dollars")
        XCTAssertEqual(f.format("the dollar is strong", language: "en"), "The dollar is strong")
    }

    func testCurrencyOffIsNoOp() {
        let f = formatter(currency: false)
        XCTAssertEqual(f.format("five dollars", language: "en"), "Five dollars")
    }

    // MARK: - Numbers

    func testNumberYearPair() {
        let f = formatter(numbers: true)
        XCTAssertEqual(f.format("see you in twenty twenty six", language: "en"), "See you in 2026")
        XCTAssertEqual(f.format("back in nineteen ninety nine", language: "en"), "Back in 1999")
        XCTAssertEqual(f.format("the year twenty twenty", language: "en"), "The year 2020")
    }

    func testNumberBeforeCounterNoun() {
        let f = formatter(numbers: true)
        XCTAssertEqual(f.format("add five items", language: "en"), "Add 5 items")
        XCTAssertEqual(f.format("there are twenty three people", language: "en"), "There are 23 people")
        XCTAssertEqual(f.format("wait ten minutes", language: "en"), "Wait 10 minutes")
    }

    func testNumberLeavesBareOneAlone() {
        let f = formatter(numbers: true)
        // "one" / "a" in ordinary prose must NOT become a digit.
        XCTAssertEqual(f.format("i have one idea", language: "en"), "I have one idea")
        XCTAssertEqual(f.format("give me a minute to think", language: "en"), "Give me a minute to think")
    }

    func testNumberLeavesSpelledNumbersInProseAlone() {
        let f = formatter(numbers: true)
        // No counter noun, no year pair → leave it. "five" mid-sentence stays.
        XCTAssertEqual(f.format("take five and relax", language: "en"), "Take five and relax")
        XCTAssertEqual(f.format("the big three agreed", language: "en"), "The big three agreed")
    }

    func testNumberDoesNotMangleOrdinaryWords() {
        let f = formatter(numbers: true)
        // "someone", "everyone" contain "one" but must be untouched.
        XCTAssertEqual(f.format("someone told everyone", language: "en"), "Someone told everyone")
    }

    func testNumberOffIsNoOp() {
        let f = formatter(numbers: false)
        XCTAssertEqual(f.format("twenty twenty six", language: "en"), "Twenty twenty six")
        XCTAssertEqual(f.format("five items", language: "en"), "Five items")
    }

    // MARK: - Spoken lists

    func testBulletAtLineStart() {
        let f = formatter(lists: true)
        XCTAssertEqual(f.format("bullet buy milk", language: "en"), "- Buy milk")
    }

    func testBulletPointVariant() {
        let f = formatter(lists: true)
        XCTAssertEqual(f.format("bullet point call mom", language: "en"), "- Call mom")
    }

    func testNumberedListItem() {
        let f = formatter(lists: true)
        XCTAssertEqual(f.format("number one wake up", language: "en"), "1. Wake up")
        XCTAssertEqual(f.format("number three profit", language: "en"), "3. Profit")
    }

    func testListAcrossNewLines() {
        // "new line" makes a real newline; each new line-start is a list item.
        let f = formatter(lists: true)
        XCTAssertEqual(
            f.format("bullet first new line bullet second", language: "en"),
            "- First\n- Second")
    }

    func testBulletMidSentenceIsLeftAlone() {
        let f = formatter(lists: true)
        // "bullet" not at line start is ordinary prose.
        XCTAssertEqual(f.format("i dodged a bullet today", language: "en"), "I dodged a bullet today")
    }

    func testBulletinNotMistakenForBullet() {
        let f = formatter(lists: true)
        // Whole-word match: "bulletin" must not be treated as "bullet in".
        XCTAssertEqual(f.format("bulletin board update", language: "en"), "Bulletin board update")
    }

    func testListOffIsNoOp() {
        let f = formatter(lists: false)
        XCTAssertEqual(f.format("bullet buy milk", language: "en"), "Bullet buy milk")
    }

    // MARK: - Basic markdown

    func testHeading() {
        let f = formatter(markdown: true)
        XCTAssertEqual(f.format("heading introduction", language: "en"), "# Introduction")
        XCTAssertEqual(f.format("header overview", language: "en"), "# Overview")
    }

    func testBoldCommand() {
        let f = formatter(markdown: true)
        XCTAssertEqual(f.format("bold very important", language: "en"), "**Very important**")
    }

    func testBoldPreservesTrailingPunctuation() {
        let f = formatter(markdown: true)
        // Sentence punctuation stays outside the emphasis markers.
        XCTAssertEqual(f.format("bold do it now.", language: "en"), "**Do it now**.")
    }

    func testItalicCommand() {
        let f = formatter(markdown: true)
        XCTAssertEqual(f.format("italic maybe", language: "en"), "*Maybe*")
    }

    func testBoldMidSentenceIsLeftAlone() {
        let f = formatter(markdown: true)
        // "bold" not at line start is ordinary prose.
        XCTAssertEqual(f.format("she made a bold move", language: "en"), "She made a bold move")
    }

    func testMarkdownOffIsNoOp() {
        let f = formatter(markdown: false)
        XCTAssertEqual(f.format("bold important", language: "en"), "Bold important")
        XCTAssertEqual(f.format("heading intro", language: "en"), "Heading intro")
    }

    // MARK: - Independence & combination

    func testGroupsAreIndependent() {
        // Enabling currency must not enable numbers/lists/markdown behavior.
        let c = formatter(currency: true)
        XCTAssertEqual(c.format("bullet twenty twenty six", language: "en"), "Bullet twenty twenty six")

        let l = formatter(lists: true)
        XCTAssertEqual(l.format("five dollars", language: "en"), "Five dollars")
    }

    func testCurrencyAndNumbersTogether() {
        let f = formatter(numbers: true, currency: true)
        // Currency consumes "five dollars" first; the year pair still normalizes.
        XCTAssertEqual(
            f.format("it cost five dollars in twenty twenty", language: "en"),
            "It cost $5 in 2020")
    }

    func testAllGroupsTogetherOnAListOfTasks() {
        let f = formatter(numbers: true, currency: true, lists: true, markdown: true)
        let input = "heading shopping new line bullet buy five items new line bullet spend ten dollars"
        XCTAssertEqual(
            f.format(input, language: "en"),
            "# Shopping\n- Buy 5 items\n- Spend $10")
    }

    // MARK: - Non-English is untouched

    func testNonEnglishSkipsAllStructuralRules() {
        let f = formatter(numbers: true, currency: true, lists: true, markdown: true)
        // Russian: english-only rules gate off, so text is passed through.
        XCTAssertEqual(f.format("пять долларов", language: "ru"), "пять долларов")
    }
}
