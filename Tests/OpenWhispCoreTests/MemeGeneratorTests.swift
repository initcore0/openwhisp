import XCTest
@testable import OpenWhispCore

/// Covers the Meme Generator plugin's pure layer (spike/plugin-system): the ranked
/// candidate parser, lexical ranking and search over the template catalog, the
/// caption layout rules, and the editable caption-box model.
final class MemeGeneratorTests: XCTestCase {

    // MARK: - Lexical ranking (the fallback when the model names nothing real)

    private let catalog: [MemeTemplate] = [
        MemeTemplate(id: "1", name: "Drake Hotline Bling", url: "u1", width: 1200, height: 1200),
        MemeTemplate(id: "2", name: "Distracted Boyfriend", url: "u2", width: 1200, height: 800),
        MemeTemplate(id: "3", name: "Two Buttons", url: "u3", width: 600, height: 908),
        MemeTemplate(id: "4", name: "Success Kid", url: "u4", width: 500, height: 500),
    ]

    func testRankedPutsAnExactNameFirst() {
        XCTAssertEqual(
            MemeTemplateMatcher.ranked(for: "Two Buttons", in: catalog, limit: 5).first?.id, "3")
    }

    func testRankedIsCaseAndPunctuationInsensitive() {
        XCTAssertEqual(
            MemeTemplateMatcher.ranked(for: "two-buttons!", in: catalog, limit: 5).first?.id, "3")
    }

    /// A partial name the user actually says ("the drake one") must find the template.
    func testRankedFindsPartialPhrases() {
        XCTAssertEqual(
            MemeTemplateMatcher.ranked(for: "drake", in: catalog, limit: 5).first?.id, "1")
        XCTAssertEqual(
            MemeTemplateMatcher.ranked(for: "distracted boyfriend", in: catalog, limit: 5).first?.id, "2")
    }

    func testRankedIgnoresStopwordsAndTheWordMeme() {
        XCTAssertEqual(
            MemeTemplateMatcher.ranked(for: "the success kid meme", in: catalog, limit: 5).first?.id, "4")
    }

    /// The core v2 rule: ranking REFUSES to guess. v1's `bestMatch` answered this
    /// same query with a confident Drake, which is the reported bug.
    func testRankedReturnsNothingWhenNothingScores() {
        XCTAssertEqual(MemeTemplateMatcher.ranked(for: "yoda", in: catalog, limit: 5), [])
        XCTAssertEqual(MemeTemplateMatcher.ranked(for: "zzzz qqqq", in: catalog, limit: 5), [])
    }

    func testRankedReturnsNothingForAnEmptyQuery() {
        XCTAssertEqual(MemeTemplateMatcher.ranked(for: "   ", in: catalog, limit: 5), [])
    }

    func testRankedHandlesAnEmptyCatalog() {
        XCTAssertEqual(MemeTemplateMatcher.ranked(for: "drake", in: [], limit: 5), [])
    }

    func testRankedRespectsTheLimit() {
        let many = (1...10).map {
            MemeTemplate(id: "\($0)", name: "Angry Cat \($0)", url: "u", width: 10, height: 10)
        }
        XCTAssertEqual(MemeTemplateMatcher.ranked(for: "angry cat", in: many, limit: 3).count, 3)
        XCTAssertEqual(MemeTemplateMatcher.ranked(for: "angry", in: many, limit: 0), [])
    }

    /// Ties break on catalog order, which imgflip returns popularity-ranked.
    func testRankedTieBreaksTowardTheMorePopularTemplate() {
        let tied = [
            MemeTemplate(id: "popular", name: "Angry Cat", url: "u", width: 10, height: 10),
            MemeTemplate(id: "less", name: "Angry Dog", url: "u", width: 10, height: 10),
        ]
        XCTAssertEqual(
            MemeTemplateMatcher.ranked(for: "angry", in: tied, limit: 5).map(\.id),
            ["popular", "less"])
    }

    func testRankedOrdersBetterMatchesFirst() {
        let ranked = MemeTemplateMatcher.ranked(for: "success kid", in: catalog, limit: 5)
        XCTAssertEqual(ranked.first?.id, "4", "the exact match outranks any partial")
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


    // MARK: - v2: ranked candidate parsing
    //
    // The rule under test is the fix for the "yoda meme → silent Drake" report: a
    // template name the model invents must be DROPPED, never fuzzy-matched.

    private let catalogNames = [
        "Drake Hotline Bling", "Distracted Boyfriend", "Two Buttons", "Success Kid",
    ]

    func testRankedParsePreservesModelOrder() {
        let result = MemeAI.parseRanked("""
        {"templates":["Two Buttons","Drake Hotline Bling"],"top_text":"ship it","bottom_text":"test it"}
        """, catalogNames: catalogNames)
        guard case .success(let spec) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(spec.templateNames, ["Two Buttons", "Drake Hotline Bling"])
        XCTAssertEqual(spec.topText, "ship it")
        XCTAssertEqual(spec.bottomText, "test it")
    }

    /// The headline bug: "yoda" is not in imgflip's top 100. The candidate must be
    /// dropped so the UI can say the corpus doesn't contain it, rather than matched
    /// onto an unrelated popular template.
    func testHallucinatedTemplateNameIsDropped() {
        let result = MemeAI.parseRanked("""
        {"templates":["Yoda","Baby Yoda"],"top_text":"do or do not","bottom_text":""}
        """, catalogNames: catalogNames)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertTrue(spec.templateNames.isEmpty)
        XCTAssertTrue(spec.hasNoUsableTemplate, "the UI needs this to show the corpus honestly")
        XCTAssertEqual(spec.topText, "do or do not", "captions survive an unusable template")
    }

    func testInventedNamesAreDroppedButValidOnesSurvive() {
        let result = MemeAI.parseRanked("""
        {"templates":["Yoda","Success Kid","Gandalf"],"top_text":"a","bottom_text":"b"}
        """, catalogNames: catalogNames)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames, ["Success Kid"])
    }

    /// Models re-capitalize and re-punctuate names constantly; that's packaging.
    func testCandidateMatchingIsCaseAndPunctuationInsensitiveAndReturnsCatalogSpelling() {
        let result = MemeAI.parseRanked("""
        {"templates":["drake hotline bling!","TWO   BUTTONS"],"top_text":"x","bottom_text":""}
        """, catalogNames: catalogNames)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(
            spec.templateNames, ["Drake Hotline Bling", "Two Buttons"],
            "returned in the catalog's own spelling so callers can look them up")
    }

    func testDuplicateCandidatesAreCollapsed() {
        XCTAssertEqual(
            MemeAI.validate(["Success Kid", "success kid", "Success  Kid"], against: catalogNames),
            ["Success Kid"])
    }

    func testCandidateListIsCappedAtFive() {
        let names = (1...10).map { "T\($0)" }
        let kept = MemeAI.validate(names, against: names)
        XCTAssertEqual(kept.count, MemeAI.maxCandidates)
        XCTAssertEqual(kept, ["T1", "T2", "T3", "T4", "T5"], "keeps the model's ranking")
    }

    /// A model that ignores the array schema and sends one string still works.
    func testSingleStringTemplateFieldIsAccepted() {
        for key in ["templates", "template", "template_query"] {
            let raw = "{\"\(key)\":\"Success Kid\",\"top_text\":\"x\",\"bottom_text\":\"\"}"
            guard case .success(let spec) = MemeAI.parseRanked(raw, catalogNames: catalogNames) else {
                return XCTFail("expected success for key \(key)")
            }
            XCTAssertEqual(spec.templateNames, ["Success Kid"], "key: \(key)")
        }
    }

    func testRankedParseDigsJSONOutOfFencedProse() {
        let result = MemeAI.parseRanked("""
        Let me think — Drake fits best here.

        ```json
        {"templates":["Drake Hotline Bling"],"top_text":"no","bottom_text":"yes"}
        ```
        """, catalogNames: catalogNames)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames, ["Drake Hotline Bling"])
    }

    func testRankedParseRejectsNonJSON() {
        XCTAssertEqual(
            rejection(MemeAI.parseRanked("I can't help with that.", catalogNames: catalogNames)),
            .notJSON)
    }

    func testRankedParseRejectsEmpty() {
        XCTAssertEqual(rejection(MemeAI.parseRanked("  ", catalogNames: catalogNames)), .empty)
    }

    /// No template AND no captions is nothing at all — reject rather than render.
    func testRankedParseRejectsWhenNothingUsableCameBack() {
        XCTAssertEqual(
            rejection(MemeAI.parseRanked(
                "{\"templates\":[\"Yoda\"],\"top_text\":\"\",\"bottom_text\":\"\"}",
                catalogNames: catalogNames)),
            .missingFields)
    }

    func testEmptyCatalogDropsEveryCandidate() {
        XCTAssertEqual(MemeAI.validate(["Drake Hotline Bling"], against: []), [])
    }

    private func rejection(_ result: Result<MemeAI.RankedSpec, MemeAI.Rejection>) -> MemeAI.Rejection? {
        if case .failure(let r) = result { return r }
        return nil
    }

    // MARK: - v2: the ranked prompt

    func testRankedPromptForbidsInventingNamesAndPinsCaptionLanguage() {
        let prompt = MemeAI.rankedPrompt.lowercased()
        XCTAssertTrue(prompt.contains("copied exactly"))
        XCTAssertTrue(prompt.contains("do not invent"))
        XCTAssertTrue(prompt.contains("same language"))
        XCTAssertTrue(prompt.contains("do not translate"))
    }

    func testRankedPayloadNumbersTheCatalogAndCarriesTheDescription() {
        let payload = MemeAI.rankedUserPayload(
            description: "  two buttons about deploys  ",
            templateNames: ["Drake Hotline Bling", "Two Buttons"])
        XCTAssertTrue(payload.contains("1. Drake Hotline Bling"))
        XCTAssertTrue(payload.contains("2. Two Buttons"))
        XCTAssertTrue(payload.contains("two buttons about deploys"))
        XCTAssertFalse(payload.contains("  two buttons about deploys  "), "description is trimmed")
    }

    /// Short-context local models can't take a 100-name list; truncation drops the
    /// least popular entries because the catalog is popularity-ordered.
    func testRankedPayloadTruncatesTheCatalogToTheLimit() {
        let names = (1...20).map { "Template \($0)" }
        let payload = MemeAI.rankedUserPayload(description: "x", templateNames: names, limit: 5)
        XCTAssertTrue(payload.contains("5. Template 5"))
        XCTAssertFalse(payload.contains("6. Template 6"))
    }

    // MARK: - Browse all: search filter

    func testSearchIsCaseInsensitiveSubstringOverNames() {
        XCTAssertEqual(
            MemeTemplateMatcher.search("DRAKE", in: catalog).map(\.id), ["1"])
        XCTAssertEqual(
            MemeTemplateMatcher.search("button", in: catalog).map(\.id), ["3"])
    }

    /// v3 REQUIRED every token to appear, which is what made a content description
    /// unsearchable (see `testWorstDayDescriptionFindsTheBartTemplate`). v4 ranks
    /// instead: a query spanning two templates surfaces BOTH rather than neither.
    func testAPartialTokenMatchStillSurfacesTheTemplate() {
        XCTAssertEqual(
            MemeTemplateMatcher.search("drake bling", in: catalog).map(\.id), ["1"])

        let both = MemeTemplateMatcher.search("drake buttons", in: catalog).map(\.id)
        XCTAssertTrue(both.contains("1"), "the Drake half of the query must still match")
        XCTAssertTrue(both.contains("3"), "the Buttons half must too — v3 returned nothing here")
    }

    /// More matched tokens ranks higher. This is the ordering the whole v4 change
    /// exists to produce.
    func testMoreMatchedTokensRanksHigher() {
        let hits = MemeTemplateMatcher.search("drake hotline bling", in: catalog).map(\.id)
        XCTAssertEqual(hits.first, "1")
    }

    func testSearchIgnoresPunctuation() {
        XCTAssertEqual(
            MemeTemplateMatcher.search("two-buttons!", in: catalog).map(\.id), ["3"])
    }

    func testEmptySearchReturnsTheWholeCatalogInOrder() {
        XCTAssertEqual(
            MemeTemplateMatcher.search("   ", in: catalog).map(\.id), ["1", "2", "3", "4"])
    }

    /// The whole point of Browse all: no fallback, ever. An empty grid is the honest
    /// answer for a query the corpus can't serve — this is the "yoda" case, and
    /// neither surviving entry point is allowed to invent a substitute.
    func testSearchNeverFallsBackToAPopularTemplate() {
        XCTAssertEqual(MemeTemplateMatcher.search("yoda", in: catalog), [])
        XCTAssertEqual(
            MemeTemplateMatcher.ranked(for: "yoda", in: catalog, limit: 5), [],
            "ranking refuses too — v1's bestMatch answered Drake here, which was the bug")
    }

    /// Equal scores fall back to the catalog's own order, which IS the popularity
    /// ranking — so ranking never reshuffles templates it has no reason to separate.
    func testEquallyScoringHitsKeepPopularityOrder() {
        let hits = MemeTemplateMatcher.search("bling boyfriend", in: catalog).map(\.id)
        XCTAssertEqual(hits, ["1", "2"], "same score (one token each) -> catalog order")
    }

    // MARK: - Caption box model

    /// Deterministic metrics for the box layout: every character is `size * 0.5`
    /// wide, and a named font is 20% wider so per-box faces are observably used.
    private func boxMeasure(_ text: String, _ size: Double, _ fontName: String?) -> Double {
        Double(text.count) * size * 0.5 * (fontName == nil ? 1.0 : 1.2)
    }

    func testSeedBoxesArePlacedTopAndBottom() {
        let boxes = MemeCaptionLayout.seedBoxes(topText: "up", bottomText: "down")
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes[0].text, "up")
        XCTAssertEqual(boxes[1].text, "down")
        XCTAssertLessThan(boxes[0].centerY, 0.5, "origin is TOP-left, so the top box has small y")
        XCTAssertGreaterThan(boxes[1].centerY, 0.5)
        XCTAssertEqual(boxes[0].centerX, 0.5)
    }

    /// Empty captions still get a box — the editor needs a handle to type into.
    func testSeedBoxesExistEvenForEmptyCaptions() {
        XCTAssertEqual(MemeCaptionLayout.seedBoxes(topText: "", bottomText: "").count, 2)
    }

    /// Normalized coordinates are the whole reason the box model exists: the same box
    /// must land proportionally identically on a preview and on a full-res export.
    func testNormalizedGeometryScalesWithImageSize() {
        let box = MemeCaptionLayout.CaptionBox(text: "hi", centerX: 0.25, centerY: 0.75)

        let small = MemeCaptionLayout.layout(
            box: box, imageWidth: 400, imageHeight: 400, measure: boxMeasure)
        let large = MemeCaptionLayout.layout(
            box: box, imageWidth: 1200, imageHeight: 1200, measure: boxMeasure)

        XCTAssertEqual(small.centerX, 100)
        XCTAssertEqual(large.centerX, 300)
        XCTAssertEqual(large.centerX / small.centerX, 3, accuracy: 0.0001)
        XCTAssertEqual(large.fontSize / small.fontSize, 3, accuracy: 0.0001,
                       "font size is a share of height, so it scales too")
    }

    func testBoxCenterIsInPixelsWithTopLeftOrigin() {
        let box = MemeCaptionLayout.CaptionBox(text: "hi", centerX: 0.5, centerY: 0.1)
        let layout = MemeCaptionLayout.layout(
            box: box, imageWidth: 1000, imageHeight: 500, measure: boxMeasure)
        XCTAssertEqual(layout.centerX, 500)
        XCTAssertEqual(layout.centerY, 50, "0.1 of the height, measured from the TOP")
        XCTAssertLessThan(layout.blockTopY, layout.centerY)
    }

    func testBoxTextIsUppercasedAndWrappedToTheBoxWidth() {
        var box = MemeCaptionLayout.CaptionBox(text: "one two three four five", centerX: 0.5, centerY: 0.5)
        box.widthShare = 0.5
        let layout = MemeCaptionLayout.layout(
            box: box, imageWidth: 400, imageHeight: 400, measure: boxMeasure)

        XCTAssertGreaterThan(layout.lines.count, 1, "should have wrapped")
        XCTAssertTrue(layout.lines.allSatisfy { $0 == $0.uppercased() })
        let widest = layout.lines.map { boxMeasure($0, layout.fontSize, nil) }.max() ?? 0
        XCTAssertLessThanOrEqual(widest, layout.maxWidth)
    }

    /// The user's font size is a ceiling: a caption too long for its box shrinks
    /// rather than overflowing.
    func testOversizedCaptionShrinksBelowTheRequestedFontSize() {
        var box = MemeCaptionLayout.CaptionBox(
            text: "a very long caption that cannot possibly fit at full size",
            centerX: 0.5, centerY: 0.5)
        box.fontSizeShare = 0.3
        box.widthShare = 0.3

        let layout = MemeCaptionLayout.layout(
            box: box, imageWidth: 400, imageHeight: 400, measure: boxMeasure)
        XCTAssertLessThan(layout.fontSize, 400 * 0.3)
        XCTAssertGreaterThan(layout.fontSize, 0)
    }

    func testPerBoxFontNameIsPassedToTheMeasurer() {
        var plain = MemeCaptionLayout.CaptionBox(text: "one two three", centerX: 0.5, centerY: 0.5)
        plain.widthShare = 0.4
        var named = plain
        named.fontName = "Impact"

        let a = MemeCaptionLayout.layout(box: plain, imageWidth: 400, imageHeight: 400, measure: boxMeasure)
        let b = MemeCaptionLayout.layout(box: named, imageWidth: 400, imageHeight: 400, measure: boxMeasure)

        XCTAssertEqual(b.fontName, "Impact")
        XCTAssertNotEqual(
            a.lines, b.lines,
            "the wider face must wrap differently — proof the font name reached the metrics")
    }

    func testClampKeepsBoxesOnTheCanvas() {
        let wild = MemeCaptionLayout.CaptionBox(
            text: "x", centerX: -3, centerY: 9,
            fontSizeShare: 99, widthShare: 50)
        let safe = MemeCaptionLayout.clamped(wild)
        XCTAssertEqual(safe.centerX, 0)
        XCTAssertEqual(safe.centerY, 1)
        XCTAssertEqual(safe.fontSizeShare, MemeCaptionLayout.CaptionBox.maximumFontSizeShare)
        XCTAssertEqual(safe.widthShare, 1)
    }

    func testClampRaisesATinyFontToTheReadableFloor() {
        let tiny = MemeCaptionLayout.CaptionBox(
            text: "x", centerX: 0.5, centerY: 0.5, fontSizeShare: 0.0001)
        XCTAssertEqual(
            MemeCaptionLayout.clamped(tiny).fontSizeShare,
            MemeCaptionLayout.CaptionBox.minimumFontSizeShare)
    }

    func testClampPreservesIdentityAndText() {
        let box = MemeCaptionLayout.CaptionBox(text: "keep me", centerX: 5, centerY: 0.5)
        let safe = MemeCaptionLayout.clamped(box)
        XCTAssertEqual(safe.id, box.id)
        XCTAssertEqual(safe.text, "keep me")
    }

    /// Out-of-range geometry must not survive into the render either — layout
    /// clamps on the way through, so a corrupt box can't draw off-canvas.
    func testLayoutClampsBeforeResolvingPixels() {
        let box = MemeCaptionLayout.CaptionBox(text: "x", centerX: 4, centerY: -1)
        let layout = MemeCaptionLayout.layout(
            box: box, imageWidth: 200, imageHeight: 200, measure: boxMeasure)
        XCTAssertEqual(layout.centerX, 200)
        XCTAssertEqual(layout.centerY, 0)
    }

    /// Empty boxes are dropped at render time but kept in the editor — the export
    /// and the box list are allowed to differ by exactly the empty ones.
    func testEmptyBoxesAreDroppedFromTheRenderList() {
        let boxes = [
            MemeCaptionLayout.CaptionBox(text: "visible", centerX: 0.5, centerY: 0.2),
            MemeCaptionLayout.CaptionBox(text: "   ", centerX: 0.5, centerY: 0.8),
        ]
        let layouts = MemeCaptionLayout.layout(
            boxes: boxes, imageWidth: 400, imageHeight: 400, measure: boxMeasure)
        XCTAssertEqual(layouts.count, 1)
        XCTAssertEqual(layouts[0].lines, ["VISIBLE"])
    }

    func testLayoutPreservesBoxIdentityForHitTesting() {
        let boxes = MemeCaptionLayout.seedBoxes(topText: "a", bottomText: "b")
        let layouts = MemeCaptionLayout.layout(
            boxes: boxes, imageWidth: 400, imageHeight: 400, measure: boxMeasure)
        XCTAssertEqual(layouts.map(\.id), boxes.map(\.id))
    }

    func testBlockHeightMatchesLineCountTimesLineHeight() {
        var box = MemeCaptionLayout.CaptionBox(text: "one two three four", centerX: 0.5, centerY: 0.5)
        box.widthShare = 0.4
        let layout = MemeCaptionLayout.layout(
            box: box, imageWidth: 400, imageHeight: 400, measure: boxMeasure)
        XCTAssertEqual(
            layout.blockHeight,
            Double(layout.lines.count) * layout.fontSize * MemeCaptionLayout.lineHeightRatio,
            accuracy: 0.0001)
    }

    /// Successive "Add text box" clicks must not stack invisibly on top of each other.
    func testNewBoxCentersDoNotCollideForSuccessiveAdds() {
        let ys = (0..<5).map { MemeCaptionLayout.newBoxCenter(existingCount: $0).y }
        XCTAssertEqual(Set(ys).count, ys.count, "each new box lands somewhere free")
        XCTAssertTrue(ys.allSatisfy { $0 > 0 && $0 < 1 })
    }

    func testNewBoxCentersWrapRatherThanRunOffTheCanvas() {
        for count in 0..<40 {
            let center = MemeCaptionLayout.newBoxCenter(existingCount: count)
            XCTAssertTrue(center.y > 0 && center.y < 1, "count \(count)")
            XCTAssertEqual(center.x, 0.5)
        }
    }

    /// An edited meme exports under the name the user sees, not the AI's originals.
    func testFileNameFollowsTheEditedBoxes() {
        let boxes = [
            MemeCaptionLayout.CaptionBox(text: "Ship It", centerX: 0.5, centerY: 0.2),
            MemeCaptionLayout.CaptionBox(text: "   ", centerX: 0.5, centerY: 0.5),
            MemeCaptionLayout.CaptionBox(text: "On Friday", centerX: 0.5, centerY: 0.8),
        ]
        XCTAssertEqual(MemeCaptionLayout.suggestedFileName(boxes: boxes), "ship-it-on-friday.png")
    }

    func testFileNameFallsBackWhenEveryBoxIsEmpty() {
        XCTAssertEqual(
            MemeCaptionLayout.suggestedFileName(boxes: [
                MemeCaptionLayout.CaptionBox(text: "", centerX: 0.5, centerY: 0.5)
            ]),
            "meme.png")
    }

    /// Boxes are persisted/carried between templates, so the Codable shape matters.
    func testCaptionBoxRoundTripsThroughCodable() throws {
        var box = MemeCaptionLayout.CaptionBox(text: "keep", centerX: 0.3, centerY: 0.7)
        box.fontName = "Impact"
        box.fontSizeShare = 0.09
        let decoded = try JSONDecoder().decode(
            MemeCaptionLayout.CaptionBox.self,
            from: try JSONEncoder().encode(box))
        XCTAssertEqual(decoded, box)
    }
}
