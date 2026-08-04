import XCTest
@testable import OpenWhispCore

/// Covers the v7 algorithm change (spike/plugin-system): deterministic caption
/// extraction, host-side slot enforcement, and the constrained-decoding schemas.
///
/// ## The failure these exist to prevent
///
/// The v6 live report: "expanding brain: typing, dictating, dictating memes, dictating
/// memes by voice" picked Expanding Brain (4 slots) and rendered TWO captions. The model
/// answered in the legacy `top_text`/`bottom_text` shape, v6's backward-compatible
/// parser accepted it, and nothing compared the caption count to the template's slot
/// count. Three independent things had to be true for that bug to ship, and v7 breaks
/// all three:
///
/// 1. The captions were re-derived by an LLM even though the user had literally listed
///    them — `MemeCaptionExtraction` now reads them directly.
/// 2. A count mismatch was silently padded — `MemeAI.fit` now refits instead.
/// 3. The legacy two-caption shape was accepted anywhere — it is now accepted as final
///    only on a 2-slot template.
final class MemeSlotEnforcementTests: XCTestCase {

    // MARK: - Deterministic caption extraction
    //
    // The highest-leverage half of v7: when the user has already said the captions,
    // asking a 1.5B model to reproduce them is inventing a failure mode.

    /// THE REPRO. The exact prompt from the owner's screenshot must yield exactly four
    /// captions, in the order they were spoken, with the theme split off.
    func testTheScreenshotPromptYieldsExactlyFourCaptionsInOrder() {
        let extracted = MemeCaptionExtraction.extract(
            from: "expanding brain: typing, dictating, dictating memes, dictating memes by voice")

        guard let extracted else { return XCTFail("expected the list to be extracted") }
        XCTAssertEqual(extracted.captions, [
            "typing", "dictating", "dictating memes", "dictating memes by voice",
        ])
        XCTAssertEqual(extracted.captions.count, 4)
        XCTAssertEqual(extracted.slotCount, 4)
        // The theme is the template query, kept separate so the search isn't polluted
        // by the caption words.
        XCTAssertEqual(extracted.theme, "expanding brain")
    }

    /// The same list said with a spoken final joiner — "a, b, c and d" — is the same
    /// four captions, not three with a run-on last one.
    func testASpokenAndJoinerStillSplitsTheFinalItem() {
        let extracted = MemeCaptionExtraction.extract(
            from: "expanding brain: typing, dictating, dictating memes and dictating memes by voice")
        XCTAssertEqual(extracted?.captions, [
            "typing", "dictating", "dictating memes", "dictating memes by voice",
        ])
    }

    func testATwoItemListIsExtracted() {
        let extracted = MemeCaptionExtraction.extract(from: "drake: manual testing, automated testing")
        XCTAssertEqual(extracted?.captions, ["manual testing", "automated testing"])
        XCTAssertEqual(extracted?.theme, "drake")
    }

    /// A numbered list needs no colon — the numbering IS the enumeration signal.
    func testANumberedListIsExtractedWithoutAColon() {
        let extracted = MemeCaptionExtraction.extract(from: "1. wake up 2. write code 3. sleep")
        XCTAssertEqual(extracted?.captions, ["wake up", "write code", "sleep"])
        XCTAssertTrue(extracted?.theme.isEmpty ?? false)
    }

    /// A dictated or pasted list, one item per line.
    func testANewlineSeparatedListIsExtracted() {
        let extracted = MemeCaptionExtraction.extract(
            from: "expanding brain:\ntyping\ndictating\ndictating memes\ndictating memes by voice")
        XCTAssertEqual(extracted?.captions.count, 4)
        XCTAssertEqual(extracted?.captions.first, "typing")
        XCTAssertEqual(extracted?.theme, "expanding brain")
    }

    /// Bullet markers are syntax, never caption text.
    func testBulletMarkersAreStrippedFromItems() {
        let extracted = MemeCaptionExtraction.extract(from: "steps:\n- plan\n- build\n- ship")
        XCTAssertEqual(extracted?.captions, ["plan", "build", "ship"])
    }

    // MARK: - What must NOT be extracted
    //
    // A false positive here hijacks ordinary prose and captions the meme with sentence
    // fragments — worse than the LLM path it would be replacing.

    /// The critical negative case: commas inside a sentence are prose, not a list.
    /// Without the colon requirement this would become three captions.
    func testProseWithCommasIsNotTreatedAsAList() {
        XCTAssertNil(MemeCaptionExtraction.extract(
            from: "make me a drake meme about rust, python and go"))
    }

    func testOrdinaryProseWithNoEnumerationFallsThroughToTheLLM() {
        XCTAssertNil(MemeCaptionExtraction.extract(
            from: "a meme where the guy is looking at rust and his girlfriend is python"))
    }

    /// A colon followed by clause-length items is prose that happens to have a colon —
    /// captions are short by definition.
    func testAColonFollowedBySentenceLengthItemsIsNotAList() {
        XCTAssertNil(MemeCaptionExtraction.extract(
            from: "steps: first you plan the whole thing out carefully, "
                + "then you throw it away entirely"))
    }

    /// One item is a phrase, not a list — otherwise every description ending in a colon
    /// would be hijacked.
    func testASingleItemIsNotAList() {
        XCTAssertNil(MemeCaptionExtraction.extract(from: "drake: shipping on friday"))
    }

    func testAnEmptyDescriptionExtractsNothing() {
        XCTAssertNil(MemeCaptionExtraction.extract(from: "   "))
    }

    /// Past the slot ceiling no template could hold the captions, so the extraction
    /// would be discarded anyway.
    func testAListLongerThanTheSlotCeilingIsRefused() {
        let items = (1...12).map { "item\($0)" }.joined(separator: ", ")
        XCTAssertNil(MemeCaptionExtraction.extract(from: "many: \(items)"))
    }

    // MARK: - Host-side slot enforcement
    //
    // The rule: a caption count that doesn't match the template is REFITTED, never
    // silently rendered.

    /// The v6 bug, now caught. Two captions on a four-slot template must refit.
    func testTwoCaptionsOnAFourSlotTemplateRefitRatherThanRender() {
        let fit = MemeAI.fit(captions: ["ship it", "test it"], slots: 4, wasLegacyShape: true)
        guard case .refit(let from, let to) = fit else {
            return XCTFail("expected a refit, got \(fit)")
        }
        XCTAssertEqual(from, ["ship it", "test it"])
        XCTAssertEqual(to, 4)
        XCTAssertTrue(fit.needsRefit)
    }

    /// The legacy shape is final ONLY when the template really is two-slot.
    func testTheLegacyShapeIsAcceptedAsFinalOnATwoSlotTemplate() {
        let fit = MemeAI.fit(captions: ["ship it", "test it"], slots: 2, wasLegacyShape: true)
        guard case .ready(let captions) = fit else {
            return XCTFail("expected ready, got \(fit)")
        }
        XCTAssertEqual(captions, ["ship it", "test it"])
        XCTAssertFalse(fit.needsRefit)
    }

    /// A matching count renders as-is regardless of which wire shape produced it — the
    /// COUNT is what decides, not the spelling.
    func testAMatchingCountIsReadyWhicheverShapeItCameFrom() {
        let array = MemeAI.fit(captions: ["a", "b", "c", "d"], slots: 4, wasLegacyShape: false)
        XCTAssertFalse(array.needsRefit)
        let legacy = MemeAI.fit(captions: ["a", "b"], slots: 2, wasLegacyShape: true)
        XCTAssertFalse(legacy.needsRefit)
    }

    /// Too MANY captions is also a mismatch — four captions on a 2-slot Drake would
    /// otherwise silently drop the punchline.
    func testTooManyCaptionsAlsoRefit() {
        let fit = MemeAI.fit(captions: ["a", "b", "c", "d"], slots: 2)
        guard case .refit(_, let to) = fit else { return XCTFail("expected a refit") }
        XCTAssertEqual(to, 2)
    }

    /// Empty captions never refit: there is no joke to preserve, and asking a model to
    /// turn nothing into four somethings is a hallucination generator.
    func testEmptyCaptionsSeedBlankBoxesRatherThanRefitting() {
        XCTAssertFalse(MemeAI.fit(captions: [], slots: 4).needsRefit)
        XCTAssertFalse(MemeAI.fit(captions: ["", "  "], slots: 4).needsRefit)
    }

    /// The refit target is clamped like every other slot count, so a corrupt cache
    /// can't ask for 900 captions.
    func testTheRefitTargetIsClamped() {
        let fit = MemeAI.fit(captions: ["a"], slots: 900)
        guard case .refit(_, let to) = fit else { return XCTFail("expected a refit") }
        XCTAssertEqual(to, MemeCaptionSlots.maximum)
    }

    /// The status line is honest about the shortfall rather than a generic spinner —
    /// the user is about to watch the captions change and deserves to know why.
    func testTheRefitStatusNamesBothCounts() {
        let status = MemeAI.refitStatus(wrote: 2, of: 4)
        XCTAssertTrue(status.contains("2"))
        XCTAssertTrue(status.contains("4"))
        XCTAssertTrue(status.lowercased().contains("refitting"))
    }

    /// A refit still seeds the captions it has, so the user sees the joke land while
    /// the second round-trip runs rather than staring at an empty canvas.
    func testARefitStillCarriesTheCaptionsToSeedMeanwhile() {
        let fit = MemeAI.fit(captions: ["ship it", "test it"], slots: 4)
        XCTAssertEqual(fit.captions, ["ship it", "test it"])
    }

    // MARK: - Slot GEOMETRY for N≠2 (the screenshot's second bug)
    //
    // Captions must ALWAYS seed into the template's own slot geometry. A 4-slot
    // template can never render as a classic top/bottom pair, whatever the model wrote.

    /// Two captions arriving for a four-slot template still produce FOUR boxes in the
    /// four-panel layout — never two boxes at the classic 0.12/0.88 positions.
    func testTwoCaptionsOnAFourSlotTemplateStillSeedFourPanelBoxes() {
        let boxes = MemeCaptionLayout.seedBoxes(captions: ["ship it", "test it"], slots: 4)

        XCTAssertEqual(boxes.count, 4, "a 4-slot template must always get 4 boxes")
        // The classic pair — the wrong answer — is exactly these two centers.
        let classic = MemeCaptionLayout.seedBoxes(captions: ["a", "b"], slots: 2)
        XCTAssertNotEqual(boxes.prefix(2).map(\.centerY), classic.map(\.centerY),
                          "must not fall back to classic top/bottom geometry")
        // Panel layout: distinct rows, left column, smaller type.
        XCTAssertEqual(Set(boxes.map(\.centerY)).count, 4, "each panel needs its own row")
        XCTAssertTrue(boxes.allSatisfy { $0.centerX == 0.30 })
        XCTAssertTrue(boxes.allSatisfy { $0.fontSizeShare < MemeCaptionLayout.CaptionBox.defaultFontSizeShare })
        // The captions that DID arrive land in panel order; the rest are typeable blanks.
        XCTAssertEqual(boxes.map(\.text), ["ship it", "test it", "", ""])
    }

    /// The four extracted captions fill all four panels in the order the user said them.
    func testTheExtractedListSeedsEveryPanelInSpokenOrder() {
        let extracted = MemeCaptionExtraction.extract(
            from: "expanding brain: typing, dictating, dictating memes, dictating memes by voice")
        let boxes = MemeCaptionLayout.seedBoxes(
            captions: extracted?.captions ?? [], slots: 4)

        XCTAssertEqual(boxes.map(\.text), [
            "typing", "dictating", "dictating memes", "dictating memes by voice",
        ])
        XCTAssertEqual(boxes.map(\.centerY), boxes.map(\.centerY).sorted(),
                       "panel order must read top-to-bottom")
    }

    // MARK: - Slot-count preference in the shortlist

    /// A known caption count puts exact-slot templates first — but never removes the
    /// others, because hiding a template the user described is the bug this plugin
    /// already fixed once.
    func testAKnownSlotCountReordersWithoutFiltering() {
        let two = MemeTemplate(
            id: "a", name: "Drake Hotline Bling", url: "u", width: 1, height: 1,
            source: .imgflip, keywords: [], captionSlots: 2)
        let four = MemeTemplate(
            id: "b", name: "Expanding Brain", url: "u", width: 1, height: 1,
            source: .imgflip, keywords: [], captionSlots: 4)

        let ordered = MemeTemplateCatalog.reorder([two, four], preferringSlots: 4)
        XCTAssertEqual(ordered.map(\.id), ["b", "a"], "the 4-slot template comes first")
        XCTAssertEqual(ordered.count, 2, "nothing is filtered out")

        // No preference expressed leaves the order exactly as the ranker produced it.
        XCTAssertEqual(
            MemeTemplateCatalog.reorder([two, four], preferringSlots: nil).map(\.id), ["a", "b"])
    }

    /// Reordering is STABLE: relevance order survives within the matching group.
    func testReorderingIsStableWithinEachGroup() {
        let templates = (1...4).map { index in
            MemeTemplate(
                id: "t\(index)", name: "T\(index)", url: "u", width: 1, height: 1,
                source: .imgflip, keywords: [], captionSlots: index.isMultiple(of: 2) ? 4 : 2)
        }
        let ordered = MemeTemplateCatalog.reorder(templates, preferringSlots: 4)
        XCTAssertEqual(ordered.map(\.id), ["t2", "t4", "t1", "t3"])
    }

    // MARK: - Constrained decoding schemas
    //
    // The systemic fix: a schema the sampler enforces makes the bad shapes
    // unrepresentable rather than merely rejected.

    /// The refit schema pins the count on BOTH ends — that is what makes
    /// "wrote 2 of 4" impossible to emit.
    func testTheRefitSchemaPinsExactlyTheRequestedCaptionCount() throws {
        let json = try encoded(MemeAI.Schema.refit(slots: 4))

        XCTAssertTrue(json.contains("\"minItems\":4"), json)
        XCTAssertTrue(json.contains("\"maxItems\":4"), json)
        XCTAssertTrue(json.contains("\"captions\""))
        // Nothing but captions may come back.
        XCTAssertTrue(json.contains("\"additionalProperties\":false"))
    }

    func testTheRefitSchemaClampsAnAbsurdSlotCount() throws {
        let json = try encoded(MemeAI.Schema.refit(slots: 900))
        XCTAssertTrue(json.contains("\"minItems\":\(MemeCaptionSlots.maximum)"), json)
    }

    /// The ranked schema types `templates` as INTEGERS, which is what makes an invented
    /// template name unrepresentable rather than merely dropped by the parser.
    func testTheRankedSchemaForcesNumericTemplateReferences() throws {
        let json = try encoded(MemeAI.Schema.ranked())

        XCTAssertTrue(json.contains("\"integer\""), json)
        XCTAssertTrue(json.contains("\"templates\""))
        XCTAssertTrue(json.contains("\"captions\""))
        XCTAssertTrue(json.contains("\"reason\""))
        // The legacy keys are not in the schema at all, so a constrained model cannot
        // reach for them — the v6 bug's entry point is closed.
        XCTAssertFalse(json.contains("top_text"))
        XCTAssertFalse(json.contains("bottom_text"))
    }

    /// The schemas are values, not strings, so they encode to real JSON.
    func testSchemasEncodeToWellFormedJSON() throws {
        for schema in [MemeAI.Schema.ranked(), MemeAI.Schema.refit(slots: 3)] {
            let data = try JSONEncoder().encode(schema)
            let parsed = try JSONSerialization.jsonObject(with: data)
            XCTAssertTrue(parsed is [String: Any])
        }
    }

    // MARK: - The spec carries the user's own captions

    /// When a list was extracted, the model's TEMPLATE choice survives and its captions
    /// are replaced by the user's own words.
    func testReplacingCaptionsKeepsTheTemplatePickAndClearsTheLegacyFlag() {
        let spec = MemeAI.RankedSpec(
            templateNames: ["Expanding Brain"], captions: ["ship it", "test it"],
            reason: "four panels fit the escalation", wasLegacyShape: true)

        let replaced = spec.replacingCaptions(with: ["a", "b", "c", "d"])

        XCTAssertEqual(replaced.templateNames, ["Expanding Brain"])
        XCTAssertEqual(replaced.captions, ["a", "b", "c", "d"])
        XCTAssertEqual(replaced.reason, "four panels fit the escalation")
        XCTAssertFalse(replaced.wasLegacyShape, "these captions came from the user")
    }

    /// End to end on the repro, minus the network: extract → replace → fit → seed must
    /// produce four filled boxes and NO refit.
    func testTheReproEndsWithFourFilledBoxesAndNoRefit() {
        let extracted = MemeCaptionExtraction.extract(
            from: "expanding brain: typing, dictating, dictating memes, dictating memes by voice")
        guard let extracted else { return XCTFail("expected extraction") }

        // The model answered in the legacy shape — the exact v6 failure.
        let spec = MemeAI.RankedSpec(
            templateNames: ["Expanding Brain"], captions: ["typing", "by voice"],
            wasLegacyShape: true)
        let resolved = spec.replacingCaptions(with: extracted.captions)

        let fit = MemeAI.fit(
            captions: resolved.captions, slots: 4, wasLegacyShape: resolved.wasLegacyShape)
        XCTAssertFalse(fit.needsRefit, "the user's own four captions already fit")

        let boxes = MemeCaptionLayout.seedBoxes(captions: fit.captions, slots: 4)
        XCTAssertEqual(boxes.count, 4)
        XCTAssertTrue(boxes.allSatisfy { !$0.text.isEmpty }, "every panel is captioned")
    }

    // MARK: - Helper

    private func encoded(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
