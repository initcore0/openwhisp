import XCTest
@testable import OpenWhispCore

/// Covers the Meme Generator plugin's pure layer (spike/plugin-system): the LLM
/// response parser, the template matcher, and the caption layout rules.
final class MemeGeneratorTests: XCTestCase {

    // MARK: - MemeAI.parse

    func testParsesBareJSONObject() {
        let result = MemeAI.parse("""
        {"template_query":"drake hotline bling","top_text":"writing tests","bottom_text":"shipping on friday"}
        """)
        guard case .success(let spec) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(spec.templateQuery, "drake hotline bling")
        XCTAssertEqual(spec.topText, "writing tests")
        XCTAssertEqual(spec.bottomText, "shipping on friday")
    }

    /// Small local models fence their JSON constantly; that's packaging, not content.
    func testParsesFencedJSON() {
        let result = MemeAI.parse("""
        Sure! Here you go:

        ```json
        {"template_query":"two buttons","top_text":"A","bottom_text":"B"}
        ```
        """)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateQuery, "two buttons")
        XCTAssertEqual(spec.topText, "A")
    }

    func testParsesJSONEmbeddedInProse() {
        let result = MemeAI.parse(
            "I think this works: {\"template_query\":\"success kid\",\"top_text\":\"x\",\"bottom_text\":\"y\"} — enjoy!")
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateQuery, "success kid")
    }

    /// A caption containing a brace must not end the object scan early.
    func testBracesInsideStringValuesDoNotTruncateTheScan() {
        let result = MemeAI.parse(
            "{\"template_query\":\"code\",\"top_text\":\"when you write {\",\"bottom_text\":\"and forget }\"}")
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.topText, "when you write {")
        XCTAssertEqual(spec.bottomText, "and forget }")
    }

    func testStripsSurroundingQuotesFromCaptions() {
        let result = MemeAI.parse(
            "{\"template_query\":\"x\",\"top_text\":\"\\\"quoted\\\"\",\"bottom_text\":\"'single'\"}")
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.topText, "quoted")
        XCTAssertEqual(spec.bottomText, "single")
    }

    /// Rule 4 in the prompt asks for exactly this on single-line memes.
    func testOneEmptyCaptionIsAccepted() {
        let result = MemeAI.parse(
            "{\"template_query\":\"success kid\",\"top_text\":\"it compiled\",\"bottom_text\":\"\"}")
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.bottomText, "")
    }

    func testEmptyResponseIsRejected() {
        XCTAssertEqual(rejection(MemeAI.parse("   \n ")), .empty)
    }

    func testNonJSONResponseIsRejected() {
        XCTAssertEqual(rejection(MemeAI.parse("I'm sorry, I can't help with that.")), .notJSON)
    }

    func testUnbalancedBracesAreRejected() {
        XCTAssertEqual(rejection(MemeAI.parse("{\"template_query\": \"x\"")), .notJSON)
    }

    /// An all-empty spec would render a blank caption on an arbitrary template —
    /// worse than an honest error.
    func testAllEmptyFieldsAreRejected() {
        XCTAssertEqual(
            rejection(MemeAI.parse("{\"template_query\":\"\",\"top_text\":\"\",\"bottom_text\":\"\"}")),
            .missingFields)
    }

    func testRejectionReasonsAreHumanReadable() {
        for r in [MemeAI.Rejection.empty, .notJSON, .missingFields] {
            XCTAssertFalse(r.reason.isEmpty)
        }
    }

    /// The prompt must keep captions in the user's language (PR #157 guard) while
    /// pinning the template query to English for catalog matching.
    func testPromptPinsCaptionLanguageAndEnglishTemplateQuery() {
        let prompt = MemeAI.prompt.lowercased()
        XCTAssertTrue(prompt.contains("same language"))
        XCTAssertTrue(prompt.contains("do not translate"))
        XCTAssertTrue(prompt.contains("english"))
    }

    func testUserPayloadTrimsAndLabelsTheDescription() {
        XCTAssertEqual(
            MemeAI.userPayload(description: "  a cat  "),
            "Meme description:\na cat")
    }

    private func rejection(_ result: Result<MemeAI.MemeSpec, MemeAI.Rejection>) -> MemeAI.Rejection? {
        if case .failure(let r) = result { return r }
        return nil
    }

    // MARK: - Template matching

    private let catalog: [MemeTemplate] = [
        MemeTemplate(id: "1", name: "Drake Hotline Bling", url: "u1", width: 1200, height: 1200),
        MemeTemplate(id: "2", name: "Distracted Boyfriend", url: "u2", width: 1200, height: 800),
        MemeTemplate(id: "3", name: "Two Buttons", url: "u3", width: 600, height: 908),
        MemeTemplate(id: "4", name: "Success Kid", url: "u4", width: 500, height: 500),
    ]

    func testExactNameMatchWins() {
        let match = MemeTemplateMatcher.bestMatch(for: "Two Buttons", in: catalog)
        XCTAssertEqual(match?.template.id, "3")
        XCTAssertFalse(match?.isFallback ?? true)
    }

    func testMatchIsCaseAndPunctuationInsensitive() {
        XCTAssertEqual(
            MemeTemplateMatcher.bestMatch(for: "two-buttons!", in: catalog)?.template.id, "3")
    }

    /// A partial name the user actually says ("the drake one") must find the template.
    func testPartialPhraseMatches() {
        XCTAssertEqual(
            MemeTemplateMatcher.bestMatch(for: "drake", in: catalog)?.template.id, "1")
        XCTAssertEqual(
            MemeTemplateMatcher.bestMatch(for: "distracted boyfriend", in: catalog)?.template.id, "2")
    }

    func testStopwordsAndTheWordMemeAreIgnored() {
        XCTAssertEqual(
            MemeTemplateMatcher.bestMatch(for: "the success kid meme", in: catalog)?.template.id, "4")
    }

    /// A confidently-wrong template is worse than an admitted guess.
    func testUnmatchableQueryFallsBackToMostPopularAndSaysSo() {
        let match = MemeTemplateMatcher.bestMatch(for: "zzzz qqqq", in: catalog)
        XCTAssertEqual(match?.template.id, "1", "falls back to the catalog's first (most popular) entry")
        XCTAssertTrue(match?.isFallback ?? false)
    }

    func testEmptyQueryFallsBack() {
        let match = MemeTemplateMatcher.bestMatch(for: "   ", in: catalog)
        XCTAssertTrue(match?.isFallback ?? false)
    }

    func testEmptyCatalogYieldsNoMatch() {
        XCTAssertNil(MemeTemplateMatcher.bestMatch(for: "drake", in: []))
    }

    /// Ties break on catalog order, which imgflip returns popularity-ranked.
    func testTieBreaksTowardTheMorePopularTemplate() {
        let tied = [
            MemeTemplate(id: "popular", name: "Angry Cat", url: "u", width: 10, height: 10),
            MemeTemplate(id: "less", name: "Angry Dog", url: "u", width: 10, height: 10),
        ]
        XCTAssertEqual(MemeTemplateMatcher.bestMatch(for: "angry", in: tied)?.template.id, "popular")
    }

    func testCatalogResponseDecodesImgflipShape() throws {
        let json = """
        {"success":true,"data":{"memes":[
          {"id":"181913649","name":"Drake Hotline Bling","url":"https://i.imgflip.com/30b1gx.jpg",
           "width":1200,"height":1200,"box_count":2}]}}
        """
        let decoded = try JSONDecoder().decode(
            MemeTemplateCatalogResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.templates.count, 1)
        XCTAssertEqual(decoded.templates[0].name, "Drake Hotline Bling")
    }

    func testFailedCatalogResponseYieldsNoTemplates() throws {
        let decoded = try JSONDecoder().decode(
            MemeTemplateCatalogResponse.self, from: Data("{\"success\":false}".utf8))
        XCTAssertEqual(decoded.templates.count, 0)
    }

    // MARK: - Caption layout

    /// Deterministic metrics: every character is `size * 0.5` wide.
    private func measure(_ text: String, _ size: Double) -> Double {
        Double(text.count) * size * 0.5
    }
    private func lineHeight(_ size: Double) -> Double { size * 1.2 }

    func testCaptionsAreUppercased() {
        XCTAssertEqual(MemeCaptionLayout.displayText("  hello there "), "HELLO THERE")
    }

    func testWrapBreaksOnWordBoundaries() {
        let lines = MemeCaptionLayout.wrap("one two three four", maxWidth: 10) {
            Double($0.count)
        }
        XCTAssertEqual(lines, ["one two", "three four"])
    }

    /// A single over-long word gets its own line rather than being cut mid-word —
    /// the font shrinks instead, which is what stays readable.
    func testOverlongWordIsNotBrokenMidWord() {
        let lines = MemeCaptionLayout.wrap("supercalifragilistic", maxWidth: 5) {
            Double($0.count)
        }
        XCTAssertEqual(lines, ["supercalifragilistic"])
    }

    func testWrapOfEmptyTextYieldsNoLines() {
        XCTAssertEqual(MemeCaptionLayout.wrap("   ", maxWidth: 100) { Double($0.count) }, [])
    }

    func testShortCaptionKeepsTheIdealFontSize() {
        let fit = MemeCaptionLayout.fit(
            caption: "yes", maxWidth: 400, maxHeight: 200,
            maxFontSize: 40, minFontSize: 10,
            measure: measure, lineHeight: lineHeight)
        XCTAssertEqual(fit.fontSize, 40)
        XCTAssertEqual(fit.lines, ["YES"])
    }

    /// The whole point: a long caption must shrink rather than overflow the image.
    func testLongCaptionShrinksToFit() {
        let long = "this is a very long meme caption that will absolutely not fit on one line"
        let fit = MemeCaptionLayout.fit(
            caption: long, maxWidth: 300, maxHeight: 120,
            maxFontSize: 48, minFontSize: 8,
            measure: measure, lineHeight: lineHeight)

        XCTAssertLessThan(fit.fontSize, 48, "should have shrunk")
        let widest = fit.lines.map { measure($0, fit.fontSize) }.max() ?? 0
        XCTAssertLessThanOrEqual(widest, 300)
        XCTAssertLessThanOrEqual(Double(fit.lines.count) * lineHeight(fit.fontSize), 120)
    }

    /// Clipping an absurd caption beats rendering nothing at all.
    func testImpossibleCaptionDegradesToMinimumFontRatherThanEmpty() {
        let fit = MemeCaptionLayout.fit(
            caption: String(repeating: "word ", count: 400),
            maxWidth: 50, maxHeight: 20,
            maxFontSize: 40, minFontSize: 10,
            measure: measure, lineHeight: lineHeight)
        XCTAssertEqual(fit.fontSize, 10)
        XCTAssertFalse(fit.lines.isEmpty)
    }

    func testEmptyCaptionProducesNoLines() {
        let fit = MemeCaptionLayout.fit(
            caption: "", maxWidth: 300, maxHeight: 100,
            maxFontSize: 40, minFontSize: 10,
            measure: measure, lineHeight: lineHeight)
        XCTAssertEqual(fit.lines, [])
    }

    /// Font sizes scale with the image so a 1200px and a 400px template look alike.
    func testFontSizesScaleWithImageHeight() {
        XCTAssertGreaterThan(
            MemeCaptionLayout.idealFontSize(imageHeight: 1200),
            MemeCaptionLayout.idealFontSize(imageHeight: 400))
        XCTAssertGreaterThan(
            MemeCaptionLayout.idealFontSize(imageHeight: 500),
            MemeCaptionLayout.minimumFontSize(imageHeight: 500))
    }

    func testFontSizesHaveAbsoluteFloors() {
        XCTAssertGreaterThanOrEqual(MemeCaptionLayout.idealFontSize(imageHeight: 1), 12)
        XCTAssertGreaterThanOrEqual(MemeCaptionLayout.minimumFontSize(imageHeight: 1), 8)
    }
}
