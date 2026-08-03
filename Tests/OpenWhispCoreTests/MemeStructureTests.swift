import XCTest
@testable import OpenWhispCore

/// Covers the v6 algorithm upgrade to the Meme Generator plugin (spike/plugin-system):
/// per-template caption STRUCTURE, numbered candidate references, the caption refit on
/// a candidate switch, the regenerate-preservation rule, and the learned per-template
/// affinity boost.
///
/// The through-line for all five: v5's pipeline hard-coded "every meme is top and
/// bottom, and the model copies names verbatim". Both assumptions were wrong for most
/// of the corpus, and both had the data to do better sitting unused on the wire.
final class MemeStructureTests: XCTestCase {

    // MARK: - Slot counts off the wire
    //
    // Both catalogs have carried the structure all along; v5 decoded it into nothing.

    func testImgflipBoxCountBecomesCaptionSlots() throws {
        let json = """
        {"success":true,"data":{"memes":[
          {"id":"1","name":"Distracted Boyfriend","url":"u","width":1200,"height":800,"box_count":3},
          {"id":"2","name":"Expanding Brain","url":"u","width":857,"height":1202,"box_count":4}
        ]}}
        """
        let decoded = try JSONDecoder().decode(
            MemeTemplateCatalogResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.templates.map(\.captionSlots), [3, 4])
    }

    /// A response without the field must not fail the whole catalog — it degrades to
    /// the classic two-slot meme, which is what v5 did for everything.
    func testImgflipWithoutBoxCountDefaultsToTwoSlots() throws {
        let json = """
        {"success":true,"data":{"memes":[
          {"id":"1","name":"Drake","url":"u","width":1200,"height":1200}
        ]}}
        """
        let decoded = try JSONDecoder().decode(
            MemeTemplateCatalogResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.templates.first?.captionSlots, MemeCaptionSlots.default)
        XCTAssertEqual(MemeCaptionSlots.default, 2)
    }

    /// memegen calls the same thing `lines`. Shapes taken from the live API.
    func testMemegenLinesBecomeCaptionSlots() throws {
        let json = """
        [
          {"id":"db","name":"Distracted Boyfriend","blank":"b","keywords":[],"lines":3},
          {"id":"gb","name":"Galaxy Brain","blank":"b","keywords":[],"lines":4},
          {"id":"drake","name":"Drakeposting","blank":"b","keywords":[],"lines":2}
        ]
        """
        let decoded = try JSONDecoder().decode(
            MemegenTemplateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.templates.map(\.captionSlots), [3, 4, 2])
    }

    func testMemegenWithoutLinesDefaultsToTwoSlots() throws {
        let json = """
        [{"id":"x","name":"Something","blank":"b","keywords":[]}]
        """
        let decoded = try JSONDecoder().decode(
            MemegenTemplateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.templates.first?.captionSlots, 2)
    }

    /// A source reporting 0 must never produce a template with no way to type on it.
    func testZeroAndNegativeSlotCountsAreClampedUp() throws {
        let json = """
        {"success":true,"data":{"memes":[
          {"id":"1","name":"Zero","url":"u","width":1,"height":1,"box_count":0},
          {"id":"2","name":"Negative","url":"u","width":1,"height":1,"box_count":-4}
        ]}}
        """
        let decoded = try JSONDecoder().decode(
            MemeTemplateCatalogResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.templates.map(\.captionSlots),
                       [MemeCaptionSlots.minimum, MemeCaptionSlots.minimum])
    }

    /// And an absurd one must not seed a screenful of boxes to delete by hand.
    func testAbsurdSlotCountIsClampedDown() {
        let template = MemeTemplate(
            id: "x", name: "X", url: "u", width: 1, height: 1, captionSlots: 400)
        XCTAssertEqual(template.captionSlots, MemeCaptionSlots.maximum)
        XCTAssertEqual(MemeCaptionSlots.maximum, 8)
    }

    /// A cache written by a v5 build has no `captionSlots`. Dropping it would make the
    /// first launch after the upgrade look like the offline bug the plugin already fixed.
    func testAV5CacheWithoutSlotsStillDecodesAtTheDefault() throws {
        let json = """
        {"id":"imgflip:1","name":"Drake","url":"u","width":1200,"height":1200,
         "source":"imgflip","keywords":[]}
        """
        let decoded = try JSONDecoder().decode(MemeTemplate.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.captionSlots, MemeCaptionSlots.default)
    }

    func testCaptionSlotsRoundTripThroughTheCache() throws {
        let original = MemeTemplate(
            id: "memegen:gb", name: "Galaxy Brain", url: "u", width: 0, height: 0,
            source: .memegen, keywords: [], captionSlots: 4)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemeTemplate.self, from: data)
        XCTAssertEqual(decoded.captionSlots, 4)
    }

    // MARK: - Slot geometry
    //
    // Every position is SYNTHESIZED from the count: neither key-less API ships box
    // geometry (verified against both live endpoints). These tests pin the shapes so a
    // later change to them is a deliberate act.

    func testTwoSlotsKeepTheClassicTopAndBottomLayout() {
        let centers = MemeCaptionLayout.slotCenters(slots: 2)
        XCTAssertEqual(centers.count, 2)
        XCTAssertEqual(centers[0].x, 0.5)
        XCTAssertEqual(centers[0].y, 0.12)
        XCTAssertEqual(centers[1].y, 0.88)
    }

    func testOneSlotIsASingleCenteredCaption() {
        let centers = MemeCaptionLayout.slotCenters(slots: 1)
        XCTAssertEqual(centers.count, 1)
        XCTAssertEqual(centers[0].x, 0.5)
    }

    /// The panel-meme layout: N distinct, evenly spaced positions inside the frame.
    func testPanelSlotsAreDistinctEvenlySpacedAndInsideTheFrame() {
        for count in 3...MemeCaptionSlots.maximum {
            let centers = MemeCaptionLayout.slotCenters(slots: count)
            XCTAssertEqual(centers.count, count, "slot count \(count)")

            let ys = centers.map(\.y)
            XCTAssertEqual(Set(ys.map { Int($0 * 1000) }).count, count,
                           "slot \(count): every caption needs its own position")
            XCTAssertTrue(ys.allSatisfy { $0 > 0 && $0 < 1 },
                          "slot \(count): captions must sit inside the image")
            XCTAssertEqual(ys, ys.sorted(),
                           "slot \(count): panel order must read top-to-bottom")

            // Evenly spaced: every gap the same, so no two captions crowd.
            let gaps = zip(ys.dropFirst(), ys).map { $0 - $1 }
            for gap in gaps { XCTAssertEqual(gap, gaps[0], accuracy: 0.0001) }
        }
    }

    /// Three and four slots are the panel-meme case: narrower boxes in a left column,
    /// smaller type so four captions don't overlap before anything is typed.
    func testPanelLayoutsUseNarrowerBoxesAndSmallerTypeThanTheClassicPair() {
        XCTAssertEqual(MemeCaptionLayout.slotWidthShare(slots: 2),
                       MemeCaptionLayout.CaptionBox.defaultWidthShare)
        XCTAssertEqual(MemeCaptionLayout.slotFontSizeShare(slots: 2),
                       MemeCaptionLayout.CaptionBox.defaultFontSizeShare)

        XCTAssertLessThan(MemeCaptionLayout.slotWidthShare(slots: 4),
                          MemeCaptionLayout.slotWidthShare(slots: 2))
        XCTAssertLessThan(MemeCaptionLayout.slotFontSizeShare(slots: 4),
                          MemeCaptionLayout.slotFontSizeShare(slots: 2))
    }

    func testSlotGeometryIsClampedLikeEveryOtherSlotCount() {
        XCTAssertEqual(MemeCaptionLayout.slotCenters(slots: 0).count, MemeCaptionSlots.minimum)
        XCTAssertEqual(MemeCaptionLayout.slotCenters(slots: 99).count, MemeCaptionSlots.maximum)
    }

    // MARK: - Seeding boxes from slots

    func testSeedingProducesOneBoxPerSlotInPanelOrder() {
        let boxes = MemeCaptionLayout.seedBoxes(
            captions: ["one", "two", "three", "four"], slots: 4)
        XCTAssertEqual(boxes.map(\.text), ["one", "two", "three", "four"])
        XCTAssertEqual(boxes.map(\.centerY), boxes.map(\.centerY).sorted())
    }

    /// A model that returns too many captions for the template must not render captions
    /// the template has no room for.
    func testExtraCaptionsBeyondTheSlotCountAreDropped() {
        let boxes = MemeCaptionLayout.seedBoxes(
            captions: ["a", "b", "c", "d"], slots: 2)
        XCTAssertEqual(boxes.map(\.text), ["a", "b"])
    }

    /// And one that returns too few must leave empty boxes to type into, not fewer boxes.
    func testTooFewCaptionsStillFillEverySlotWithAnEmptyBox() {
        let boxes = MemeCaptionLayout.seedBoxes(captions: ["only"], slots: 4)
        XCTAssertEqual(boxes.count, 4)
        XCTAssertEqual(boxes.map(\.text), ["only", "", "", ""])
    }

    /// The classic entry point must be exactly the 2-slot case, so the common path
    /// can't drift away from the general one.
    func testTheClassicTopBottomSeedIsTheTwoSlotCase() {
        let classic = MemeCaptionLayout.seedBoxes(topText: "up", bottomText: "down")
        let general = MemeCaptionLayout.seedBoxes(captions: ["up", "down"], slots: 2)
        XCTAssertEqual(classic.map(\.text), general.map(\.text))
        XCTAssertEqual(classic.map(\.centerY), general.map(\.centerY))
        XCTAssertEqual(classic.map(\.centerX), general.map(\.centerX))
        XCTAssertEqual(classic.count, 2)
    }

    // MARK: - Numbered candidate references
    //
    // The v6 contract: the model answers with INDICES into the shortlist it was shown.
    // Copying names verbatim is a transcription task, and it is the single most fragile
    // thing a tiny local model can be asked to do.

    private let shortlist = [
        "Drake Hotline Bling", "Distracted Boyfriend", "Two Buttons", "Success Kid",
    ]

    func testNumberedCandidatesResolveToTheShortlistEntriesTheyIndex() {
        let result = MemeAI.parseRanked("""
        {"templates":[3,1],"captions":["ship it","test it"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames, ["Two Buttons", "Drake Hotline Bling"])
    }

    /// The numbering is 1-based because that is what the payload prints. An off-by-one
    /// here would return the model's neighbour on every pick — plausible-looking wrong
    /// templates rather than an error, which is the worst kind to hunt.
    func testTheNumberingIsOneBasedMatchingWhatThePayloadPrints() {
        let payload = MemeAI.rankedUserPayload(
            description: "anything", templateNames: shortlist)
        XCTAssertTrue(payload.contains("1. Drake Hotline Bling"))

        let result = MemeAI.parseRanked(
            "{\"templates\":[1],\"captions\":[\"x\"]}", catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames, ["Drake Hotline Bling"])
        XCTAssertEqual(MemeAI.firstCandidateNumber, 1)
    }

    /// A number past the end of the list is a miscount or an invention. Clamping it to
    /// the last entry would be v1's confident-Drake bug wearing a number.
    func testOutOfRangeNumbersAreDroppedRatherThanClamped() {
        let result = MemeAI.parseRanked("""
        {"templates":[99,0,-3,2],"captions":["x"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames, ["Distracted Boyfriend"])
    }

    func testAnAllOutOfRangeAnswerLeavesNoUsableTemplate() {
        let result = MemeAI.parseRanked("""
        {"templates":[40,41],"captions":["still a joke"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertTrue(spec.hasNoUsableTemplate)
        XCTAssertEqual(spec.captions, ["still a joke"])
    }

    /// Backward compatibility: a model that ignores the numbering is no worse off.
    func testExactNamesAreStillAccepted() {
        let result = MemeAI.parseRanked("""
        {"templates":["Two Buttons","Success Kid"],"captions":["a","b"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames, ["Two Buttons", "Success Kid"])
    }

    func testNumbersAndNamesMayBeMixedInOneAnswer() {
        let result = MemeAI.parseRanked("""
        {"templates":[3,"Success Kid"],"captions":["a"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames, ["Two Buttons", "Success Kid"])
    }

    /// A model asked for numbers answering `["3"]` meant the third template — looking
    /// for a catalog entry NAMED "3" would silently throw the pick away.
    func testANumericStringIsTreatedAsAnIndexNotAName() {
        let result = MemeAI.parseRanked("""
        {"templates":["2"],"captions":["a"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames, ["Distracted Boyfriend"])
    }

    /// The dedupe is on the RESOLVED template, not on how it was written — otherwise a
    /// number and its name would occupy two slots in a five-slot strip.
    func testANumberAndItsNameCollapseToOneCandidate() {
        let result = MemeAI.parseRanked("""
        {"templates":[3,"two buttons",3],"captions":["a"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames, ["Two Buttons"])
    }

    func testNumberedCandidatesAreCappedAtFive() {
        let long = (1...12).map { "T\($0)" }
        let result = MemeAI.parseRanked("""
        {"templates":[1,2,3,4,5,6,7,8],"captions":["a"]}
        """, catalogNames: long)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames.count, MemeAI.maxCandidates)
        XCTAssertEqual(spec.templateNames, ["T1", "T2", "T3", "T4", "T5"])
    }

    /// One element of a shape we don't understand must not cost the user the good
    /// candidates beside it.
    func testAnUnparseableElementIsDroppedWithoutFailingTheWholeAnswer() {
        let result = MemeAI.parseRanked("""
        {"templates":[1,{"name":"weird"},null,3],"captions":["a"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.templateNames, ["Drake Hotline Bling", "Two Buttons"])
    }

    func testAnEmptyShortlistResolvesNothingRatherThanCrashing() {
        XCTAssertTrue(MemeAI.resolve([.index(1), .name("Drake")], shortlist: []).isEmpty)
    }

    // MARK: - Caption arrays and the legacy shape

    func testCaptionsArriveAsAnArrayInPanelOrder() {
        let result = MemeAI.parseRanked("""
        {"templates":[1],"captions":["one","two","three","four"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.captions, ["one", "two", "three", "four"])
    }

    /// v5's shape, and the one any model that has seen a two-line meme reaches for.
    ///
    /// v7 keeps DECODING it — the parser is still forgiving about packaging — but the
    /// decision about whether it may be RENDERED moved to `MemeAI.fit`, which accepts it
    /// only on a 2-slot template. See `MemeSlotEnforcementTests`.
    func testLegacyTopAndBottomTextDecodeAsATwoSlotResponse() {
        let result = MemeAI.parseRanked("""
        {"templates":[1],"top_text":"ship it","bottom_text":"test it"}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.captions, ["ship it", "test it"])
        XCTAssertEqual(spec.topText, "ship it")
        XCTAssertEqual(spec.bottomText, "test it")
        // v7: the shape is RECORDED so the host can tell a deliberate 2-slot answer
        // from a model that never engaged with the slot count.
        XCTAssertTrue(spec.wasLegacyShape)
    }

    /// The counterpart: a two-element ARRAY is not the legacy shape, even though it
    /// carries the same two strings.
    func testACaptionsArrayOfTwoIsNotFlaggedAsTheLegacyShape() {
        let result = MemeAI.parseRanked("""
        {"templates":[1],"captions":["ship it","test it"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.captions, ["ship it", "test it"])
        XCTAssertFalse(spec.wasLegacyShape)
    }

    /// A response carrying BOTH keeps the richer answer.
    func testACaptionsArrayWinsOverStrayLegacyKeys() {
        let result = MemeAI.parseRanked("""
        {"templates":[1],"captions":["a","b","c"],"top_text":"ignored","bottom_text":"also"}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.captions, ["a", "b", "c"])
    }

    /// A single-line meme in the legacy shape must not seed a trailing blank box.
    func testATrailingEmptyCaptionIsDropped() {
        let result = MemeAI.parseRanked("""
        {"templates":[1],"top_text":"one liner","bottom_text":""}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.captions, ["one liner"])
    }

    /// An INTERIOR empty means "this panel has no caption" — shifting the next one up
    /// into its place would relabel the wrong panel.
    func testAnInteriorEmptyCaptionIsKeptSoPanelsDoNotShift() {
        let result = MemeAI.parseRanked("""
        {"templates":[1],"captions":["first","","third"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.captions, ["first", "", "third"])
    }

    func testTheModelsReasonSurvivesForTheStripTooltip() {
        let result = MemeAI.parseRanked("""
        {"templates":[1],"captions":["a"],"reason":"the two-choice shape fits the dilemma"}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertEqual(spec.reason, "the two-choice shape fits the dilemma")
    }

    /// The reason is a nicety, never a reason to reject an otherwise good answer.
    func testAMissingReasonIsNotAFailure() {
        let result = MemeAI.parseRanked("""
        {"templates":[1],"captions":["a"]}
        """, catalogNames: shortlist)
        guard case .success(let spec) = result else { return XCTFail("expected success") }
        XCTAssertTrue(spec.reason.isEmpty)
    }

    func testAnAnswerWithNeitherTemplateNorCaptionIsStillRejected() {
        let result = MemeAI.parseRanked("""
        {"templates":[99],"captions":["",""]}
        """, catalogNames: shortlist)
        guard case .failure(let rejection) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(rejection, .missingFields)
    }

    // MARK: - The prompt and the payload

    /// The discarded "think first" invitation is gone; the reasoning it asked for is
    /// now a `reason` the strip actually shows.
    func testThePromptAsksForNumbersACaptionArrayAndAVisibleReason() {
        XCTAssertTrue(MemeAI.rankedPrompt.contains("NUMBERS"))
        XCTAssertTrue(MemeAI.rankedPrompt.contains("\"captions\""))
        XCTAssertTrue(MemeAI.rankedPrompt.contains("\"reason\""))
        XCTAssertTrue(MemeAI.rankedPrompt.contains("shown"),
                      "the reason has to be described as user-facing")
        XCTAssertFalse(MemeAI.rankedPrompt.contains("Think about which"),
                       "v5's discarded reasoning invitation must be gone")
    }

    /// Only NON-default counts are annotated — tagging every two-slot template would be
    /// noise on the models whose attention is the scarce resource.
    func testOnlyNonDefaultSlotCountsAreAnnotatedInThePrompt() {
        let annotated = MemeAI.slotAnnotatedLines(
            ["Drake", "Distracted Boyfriend", "Expanding Brain"], slots: [2, 3, 4])
        XCTAssertEqual(annotated, [
            "Drake",
            "Distracted Boyfriend [3 captions]",
            "Expanding Brain [4 captions]",
        ])
    }

    func testASlotArrayShorterThanTheLinesDegradesToTheDefault() {
        let annotated = MemeAI.slotAnnotatedLines(["A", "B"], slots: [4])
        XCTAssertEqual(annotated, ["A [4 captions]", "B"])
    }

    func testThePayloadCarriesTheSlotCountsAndExplainsTheUnmarkedCase() {
        let payload = MemeAI.rankedUserPayload(
            description: "two brains", templateLines: ["Drake", "Galaxy Brain"], slots: [2, 4])
        XCTAssertTrue(payload.contains("1. Drake\n"))
        XCTAssertTrue(payload.contains("2. Galaxy Brain [4 captions]"))
        XCTAssertTrue(payload.contains("two brains"))
        XCTAssertTrue(payload.contains("unmarked one takes 2"))
    }

    // MARK: - Refit on a candidate switch
    //
    // The strip promises "same joke, different template". That held while everything
    // was two-slot and breaks the moment structure varies.

    func testNoRefitIsNeededWhenTheSlotCountMatches() {
        XCTAssertFalse(MemeAI.needsRefit(captions: ["a", "b"], slots: 2))
    }

    func testARefitIsNeededWhenTheSlotCountDiffers() {
        XCTAssertTrue(MemeAI.needsRefit(captions: ["a", "b"], slots: 4))
        XCTAssertTrue(MemeAI.needsRefit(captions: ["a", "b", "c", "d"], slots: 2))
    }

    /// Nothing to refit: an empty box set is seeded locally, not rewritten by an LLM.
    func testNoRefitForCaptionsThatAreAllEmpty() {
        XCTAssertFalse(MemeAI.needsRefit(captions: ["", "  "], slots: 4))
        XCTAssertFalse(MemeAI.needsRefit(captions: [], slots: 4))
    }

    func testRefitNeedIsJudgedAgainstTheClampedSlotCount() {
        // A 1-caption box set against a template reporting 0 slots clamps to 1 — equal,
        // so no round-trip.
        XCTAssertFalse(MemeAI.needsRefit(captions: ["a"], slots: 0))
    }

    func testTheRefitPayloadCarriesTheJokeTheCurrentCaptionsAndTheTarget() {
        let payload = MemeAI.refitUserPayload(
            description: "rust versus python", captions: ["rust", "python"],
            slots: 4, templateName: "Galaxy Brain")
        XCTAssertTrue(payload.contains("rust versus python"))
        XCTAssertTrue(payload.contains("1. rust"))
        XCTAssertTrue(payload.contains("2. python"))
        XCTAssertTrue(payload.contains("Galaxy Brain"))
        XCTAssertTrue(payload.contains("4 captions"))
        XCTAssertTrue(payload.contains("Return exactly 4"))
    }

    func testTheRefitPromptPinsTheLanguageAndForbidsPadding() {
        XCTAssertTrue(MemeAI.refitPrompt.contains("SAME language"))
        XCTAssertTrue(MemeAI.refitPrompt.contains("EXACTLY"))
        XCTAssertTrue(MemeAI.refitPrompt.contains("do not repeat"))
    }

    /// The result is always exactly `slots` long — the caller seeds boxes straight from
    /// it, so a length mismatch would produce the wrong number of boxes.
    func testARefitIsPaddedUpToTheSlotCount() {
        let captions = MemeAI.parseRefit("""
        {"captions":["one","two"]}
        """, slots: 4)
        XCTAssertEqual(captions, ["one", "two", "", ""])
    }

    func testARefitIsTruncatedDownToTheSlotCount() {
        let captions = MemeAI.parseRefit("""
        {"captions":["a","b","c","d"]}
        """, slots: 2)
        XCTAssertEqual(captions, ["a", "b"])
    }

    func testARefitDigsItsJSONOutOfProse() {
        let captions = MemeAI.parseRefit("""
        Sure! Here you go:
        ```json
        {"captions":["small brain","big brain","galaxy brain"]}
        ```
        """, slots: 3)
        XCTAssertEqual(captions, ["small brain", "big brain", "galaxy brain"])
    }

    /// A failed refit must leave the user with the captions they already had — the
    /// switch itself succeeded, so nil means "keep what's there", never an error state.
    func testAnUnusableRefitReplyIsRefusedRatherThanBlankingTheCaptions() {
        XCTAssertNil(MemeAI.parseRefit("sorry, I can't do that", slots: 3))
        XCTAssertNil(MemeAI.parseRefit("", slots: 3))
        XCTAssertNil(MemeAI.parseRefit("{\"captions\":[]}", slots: 3))
        XCTAssertNil(MemeAI.parseRefit("{\"captions\":[\"\",\"\"]}", slots: 3))
        XCTAssertNil(MemeAI.parseRefit("{\"unrelated\":true}", slots: 3))
    }

    // MARK: - Regenerate preservation
    //
    // The rule: Generate replaces AI-seeded boxes and PRESERVES boxes the user added.

    func testRegenerateReplacesTheAISeededBoxes() {
        let oldSeed = MemeCaptionLayout.seedBoxes(captions: ["old top", "old bottom"], slots: 2)
        let newSeed = MemeCaptionLayout.seedBoxes(captions: ["new top", "new bottom"], slots: 2)

        let merged = MemeCaptionLayout.merging(
            seed: newSeed, into: oldSeed, seededIDs: Set(oldSeed.map(\.id)))

        XCTAssertEqual(merged.map(\.text), ["new top", "new bottom"])
    }

    /// The headline: a caption the user added by hand survives a regenerate. Silent
    /// destruction of manual work is the worst class of bug in an editor with no undo.
    func testRegeneratePreservesABoxTheUserAdded() throws {
        let oldSeed = MemeCaptionLayout.seedBoxes(captions: ["old"], slots: 1)
        let userBox = MemeCaptionLayout.CaptionBox(
            text: "mine", centerX: 0.25, centerY: 0.6)
        let existing = oldSeed + [userBox]

        let newSeed = MemeCaptionLayout.seedBoxes(captions: ["new"], slots: 1)
        let merged = MemeCaptionLayout.merging(
            seed: newSeed, into: existing, seededIDs: Set(oldSeed.map(\.id)))

        XCTAssertEqual(merged.map(\.text), ["new", "mine"])
        // Identity and geometry survive exactly — it is the same box, not a copy.
        let survivor = try XCTUnwrap(merged.first { $0.id == userBox.id })
        XCTAssertEqual(survivor.centerX, 0.25)
        XCTAssertEqual(survivor.centerY, 0.6)
    }

    /// A regenerate to a template with MORE slots keeps the user's box on the end, so
    /// panel order still reads top-to-bottom for the slots the template has.
    func testUserBoxesAreAppendedAfterTheNewSeedWhateverTheSlotCount() {
        let oldSeed = MemeCaptionLayout.seedBoxes(captions: ["a", "b"], slots: 2)
        let userBox = MemeCaptionLayout.CaptionBox(text: "mine", centerX: 0.5, centerY: 0.5)
        let newSeed = MemeCaptionLayout.seedBoxes(
            captions: ["1", "2", "3", "4"], slots: 4)

        let merged = MemeCaptionLayout.merging(
            seed: newSeed, into: oldSeed + [userBox], seededIDs: Set(oldSeed.map(\.id)))

        XCTAssertEqual(merged.map(\.text), ["1", "2", "3", "4", "mine"])
    }

    /// EDITS to a seeded box are deliberately NOT preserved: that box is the AI's
    /// answer to the old description, and a regenerate asks for a new one.
    func testAnEditedSeededBoxIsStillReplaced() {
        var seed = MemeCaptionLayout.seedBoxes(captions: ["original"], slots: 1)
        let seededIDs = Set(seed.map(\.id))
        seed[0].text = "the user retyped this"

        let merged = MemeCaptionLayout.merging(
            seed: MemeCaptionLayout.seedBoxes(captions: ["fresh"], slots: 1),
            into: seed, seededIDs: seededIDs)

        XCTAssertEqual(merged.map(\.text), ["fresh"])
    }

    /// The first generate on an empty canvas has nothing to preserve.
    func testTheFirstGenerateOnAnEmptyCanvasJustSeeds() {
        let seed = MemeCaptionLayout.seedBoxes(captions: ["a", "b"], slots: 2)
        let merged = MemeCaptionLayout.merging(seed: seed, into: [], seededIDs: [])
        XCTAssertEqual(merged.map(\.text), ["a", "b"])
    }

    /// A user who picked a template and typed BEFORE ever generating has boxes that no
    /// seed minted — those are theirs and must survive the first Generate.
    func testBoxesTypedBeforeTheFirstGenerateAreTreatedAsUserAdded() {
        let handmade = [
            MemeCaptionLayout.CaptionBox(text: "typed by hand", centerX: 0.5, centerY: 0.5)
        ]
        let merged = MemeCaptionLayout.merging(
            seed: MemeCaptionLayout.seedBoxes(captions: ["ai"], slots: 1),
            into: handmade, seededIDs: [])
        XCTAssertEqual(merged.map(\.text), ["ai", "typed by hand"])
    }

    // MARK: - The learned affinity
    //
    // Cheap supervision: a user clicking past the model's first pick is a correction.
    // The bounds matter more than the signal — an unbounded boost is a personalized
    // version of the confident-Drake bug.

    func testAPickBoostsThatTemplate() {
        var affinity = MemeTemplateAffinity()
        affinity.record(pick: "imgflip:1")
        XCTAssertEqual(affinity.boost(for: "imgflip:1"), MemeTemplateAffinity.boostPerPick)
        XCTAssertEqual(affinity.boost(for: "imgflip:2"), 0)
    }

    func testRepeatedPicksAccumulate() {
        var affinity = MemeTemplateAffinity()
        for _ in 0..<3 { affinity.record(pick: "x") }
        XCTAssertEqual(affinity.boost(for: "x"), MemeTemplateAffinity.boostPerPick * 3)
    }

    /// The cap is the load-bearing bound: past saturation the signal stops compounding,
    /// which is what stops a long-lived store from taking over the ranking.
    func testTheBoostSaturatesAtTheCapAndNeverExceedsIt() {
        var affinity = MemeTemplateAffinity()
        for _ in 0..<500 { affinity.record(pick: "x") }
        XCTAssertEqual(affinity.boost(for: "x"), MemeTemplateAffinity.maximumBoost)
    }

    func testSaturationTakesTheDocumentedNumberOfPicks() {
        var affinity = MemeTemplateAffinity()
        for _ in 0..<MemeTemplateAffinity.picksToSaturate { affinity.record(pick: "x") }
        XCTAssertEqual(affinity.boost(for: "x"), MemeTemplateAffinity.maximumBoost)
    }

    /// One correction must be able to reorder near-ties and nothing more: the boost is
    /// smaller than a single keyword-token match.
    func testOneBoostIsWorthLessThanOneKeywordMatch() {
        XCTAssertLessThan(MemeTemplateAffinity.boostPerPick, 60)
        // Even fully saturated it stays below the whole-phrase and exact-name tiers, so
        // typing a template's name always wins.
        XCTAssertLessThan(MemeTemplateAffinity.maximumBoost, 5_000)
    }

    /// A hand-edited or corrupt file must not inject a dominating boost — the store is
    /// user-writable by design, so decoding is where the cap has to hold.
    func testDecodingReAppliesTheCap() throws {
        let json = "{\"x\":999999,\"y\":-40,\"z\":0}"
        let decoded = try JSONDecoder().decode(
            MemeTemplateAffinity.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.boost(for: "x"), MemeTemplateAffinity.maximumBoost)
        XCTAssertEqual(decoded.boost(for: "y"), 0)
        XCTAssertEqual(decoded.boost(for: "z"), 0)
    }

    func testAffinityRoundTripsThroughJSON() throws {
        var affinity = MemeTemplateAffinity()
        affinity.record(pick: "imgflip:1")
        affinity.record(pick: "imgflip:1")
        affinity.record(pick: "memegen:db")

        let data = try JSONEncoder().encode(affinity)
        let decoded = try JSONDecoder().decode(MemeTemplateAffinity.self, from: data)
        XCTAssertEqual(decoded, affinity)
    }

    func testAnEmptyIDIsNotRecorded() {
        var affinity = MemeTemplateAffinity()
        affinity.record(pick: "")
        XCTAssertEqual(affinity, MemeTemplateAffinity())
    }

    func testResetForgetsEverything() {
        var affinity = MemeTemplateAffinity()
        affinity.record(pick: "x")
        affinity.reset()
        XCTAssertEqual(affinity.boost(for: "x"), 0)
    }

    // MARK: - Affinity applied to the ranking

    private let rankingCatalog: [MemeTemplate] = [
        MemeTemplate(id: "a", name: "Angry Cat", url: "u", width: 1, height: 1,
                     source: .imgflip, keywords: ["cat"]),
        MemeTemplate(id: "b", name: "Happy Cat", url: "u", width: 1, height: 1,
                     source: .imgflip, keywords: ["cat"]),
        MemeTemplate(id: "z", name: "Distracted Boyfriend", url: "u", width: 1, height: 1),
    ]

    /// The signal doing its job: a boost reorders two templates that scored the same.
    func testABoostPromotesATemplateOverAnEquallyScoringOne() {
        let plain = MemeTemplateCatalog.ranked("cat", in: rankingCatalog, limit: 5)
        XCTAssertEqual(plain.map(\.template.id), ["a", "b"])

        var affinity = MemeTemplateAffinity()
        affinity.record(pick: "b")
        let boosted = MemeTemplateCatalog.ranked(
            "cat", in: rankingCatalog, limit: 5, affinity: affinity)
        XCTAssertEqual(boosted.map(\.template.id), ["b", "a"])
    }

    /// The load-bearing safety property: a boost NEVER conjures a hit for a query that
    /// matched nothing, so "no template matches" stays reachable however much the store
    /// has learned.
    func testASaturatedBoostCannotMakeANonMatchingTemplateAppear() {
        var affinity = MemeTemplateAffinity()
        for _ in 0..<500 { affinity.record(pick: "z") }

        let hits = MemeTemplateCatalog.ranked(
            "cat", in: rankingCatalog, limit: 5, affinity: affinity)
        XCTAssertFalse(hits.contains { $0.template.id == "z" })

        let nothing = MemeTemplateCatalog.ranked(
            "submarine", in: rankingCatalog, limit: 5, affinity: affinity)
        XCTAssertTrue(nothing.isEmpty)
    }

    /// A saturated boost still can't beat an exact name match — asking for a template
    /// by name always gets that template.
    func testASaturatedBoostCannotOutrankAnExactNameMatch() {
        var affinity = MemeTemplateAffinity()
        for _ in 0..<500 { affinity.record(pick: "b") }

        let hits = MemeTemplateCatalog.ranked(
            "Angry Cat", in: rankingCatalog, limit: 5, affinity: affinity)
        XCTAssertEqual(hits.first?.template.id, "a")
    }

    /// An unfiltered Browse grid is the corpus in POPULARITY order. Floating the user's
    /// favourites to the top of it would make the grid's order mean two different
    /// things depending on whether the search box happened to be empty.
    func testAnEmptyQueryKeepsPopularityOrderRegardlessOfAffinity() {
        var affinity = MemeTemplateAffinity()
        for _ in 0..<500 { affinity.record(pick: "z") }
        let hits = MemeTemplateCatalog.ranked(
            "", in: rankingCatalog, limit: 5, affinity: affinity)
        XCTAssertEqual(hits.map(\.template.id), ["a", "b", "z"])
    }

    /// The prefilter is where the shortlist for the LLM comes from, so the boost has to
    /// reach it — that is the whole point of persisting the signal.
    func testThePrefilterHonoursTheLearnedBoost() {
        var affinity = MemeTemplateAffinity()
        affinity.record(pick: "b")
        let shortlist = MemeTemplateCatalog.prefilter(
            for: "cat", in: rankingCatalog, limit: 2, affinity: affinity)
        XCTAssertEqual(shortlist.map(\.id), ["b", "a"])
    }

    /// Default-argument behaviour: every existing call site is unchanged.
    func testRankingWithoutAnAffinityIsUnchanged() {
        XCTAssertEqual(
            MemeTemplateCatalog.ranked("cat", in: rankingCatalog, limit: 5).map(\.template.id),
            MemeTemplateCatalog.ranked("cat", in: rankingCatalog, limit: 5,
                                       affinity: MemeTemplateAffinity()).map(\.template.id))
    }

    // MARK: - Slot counts reaching the prompt

    func testPromptSlotsAlignPositionallyWithPromptLines() {
        let catalog = [
            MemeTemplate(id: "1", name: "Drake", url: "u", width: 1, height: 1,
                         captionSlots: 2),
            MemeTemplate(id: "2", name: "Galaxy Brain", url: "u", width: 1, height: 1,
                         source: .memegen, keywords: ["brain"], captionSlots: 4),
        ]
        let lines = MemeTemplateCatalog.promptLines(catalog, limit: 10)
        let slots = MemeTemplateCatalog.promptSlots(catalog, limit: 10)
        XCTAssertEqual(lines.count, slots.count)
        XCTAssertEqual(slots, [2, 4])

        let annotated = MemeAI.slotAnnotatedLines(lines, slots: slots)
        XCTAssertEqual(annotated[0], "Drake")
        XCTAssertTrue(annotated[1].hasPrefix("Galaxy Brain (brain)"))
        XCTAssertTrue(annotated[1].hasSuffix("[4 captions]"))
    }

    func testPromptSlotsRespectTheSameLimitAsTheLines() {
        let catalog = (1...5).map {
            MemeTemplate(id: "\($0)", name: "T\($0)", url: "u", width: 1, height: 1,
                         captionSlots: 3)
        }
        XCTAssertEqual(MemeTemplateCatalog.promptSlots(catalog, limit: 2).count, 2)
        XCTAssertEqual(MemeTemplateCatalog.promptSlots(catalog, limit: 0).count, 0)
    }

    // MARK: - Live drag (v9)

    private func box(_ text: String) -> MemeCaptionLayout.CaptionBox {
        MemeCaptionLayout.CaptionBox(text: text, centerX: 0.5, centerY: 0.5)
    }

    /// The dragged box renders EMPTY so its caption isn't painted twice — once burned
    /// in at the old spot and once travelling under the cursor.
    func testDraggedBoxHasItsTextHiddenFromTheRender() {
        let boxes = [box("TOP"), box("BOTTOM")]
        let hidden = MemeCaptionLayout.hidingText(of: boxes[0].id, in: boxes)

        XCTAssertEqual(hidden.map(\.text), ["", "BOTTOM"])
    }

    /// Hiding is a RENDERING concern and must not edit the document: the box survives,
    /// with its id and geometry, so the editor's selection stays valid mid-drag.
    func testHidingTextKeepsTheBoxItsIDAndItsGeometry() {
        let boxes = [box("TOP"), box("BOTTOM")]
        let hidden = MemeCaptionLayout.hidingText(of: boxes[0].id, in: boxes)

        XCTAssertEqual(hidden.count, 2)
        XCTAssertEqual(hidden.map(\.id), boxes.map(\.id))
        XCTAssertEqual(hidden[0].centerX, boxes[0].centerX)
        XCTAssertEqual(hidden[0].centerY, boxes[0].centerY)
    }

    /// At rest — nothing being dragged — the render is untouched.
    func testHidingNothingIsIdentity() {
        let boxes = [box("TOP"), box("BOTTOM")]
        XCTAssertEqual(MemeCaptionLayout.hidingText(of: nil, in: boxes), boxes)
    }

    /// An id that no longer exists (the box was deleted mid-drag) leaves every caption
    /// visible rather than blanking an arbitrary one.
    func testHidingAnUnknownIDLeavesEveryCaptionVisible() {
        let boxes = [box("TOP"), box("BOTTOM")]
        XCTAssertEqual(MemeCaptionLayout.hidingText(of: UUID(), in: boxes), boxes)
    }

    // MARK: - Runtime trace (v9)

    /// The breadcrumb must report the SLOT COUNT, because that is the field that was
    /// wrong and the trace is what finally showed it.
    ///
    /// Asserting the line's content keeps the trace honest: a trace that quietly
    /// stopped describing the decision would send the next debugging round the same
    /// way the last three went.
    func testSeedTraceReportsSlotsAndBoxCount() {
        let seed = MemeCaptionSeeding.resolve(
            description: "expanding brain: a, b, c, d",
            specCaptions: ["a", "b", "c", "d"], templateSlots: 2)
        let line = MemeTrace.seedLine(
            description: "expanding brain: a, b, c, d",
            specCaptions: ["a", "b", "c", "d"], slots: 2, seed: seed)

        XCTAssertTrue(line.contains("slots: 2"), line)
        XCTAssertTrue(line.contains("-> 2 boxes"), line)
        XCTAssertTrue(line.contains("refit: 4->2"), line)
    }

    func testExtractionTraceDistinguishesAListFromProse() {
        let list = MemeCaptionExtraction.extract(from: "brain: a, b, c, d")
        XCTAssertTrue(MemeTrace.extractionLine(list).contains("4 items"))
        XCTAssertTrue(MemeTrace.extractionLine(nil).contains("not list-shaped"))
    }
}
