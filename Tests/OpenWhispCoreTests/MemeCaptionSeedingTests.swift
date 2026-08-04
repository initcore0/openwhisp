import XCTest
@testable import OpenWhispCore

/// The captions→boxes decision, tested against the SAME function the app calls (v8).
///
/// ## The gap these close
///
/// v7 fixed the four-captions bug and shipped tests that passed — but those tests
/// re-implemented the app's sequence (extract → replace → fit → seed) inside the test
/// body, with `slots: 4` written as a literal. The code that actually chained those
/// steps lived in `plugins/MemeGenerator/MemeGeneratorModel.swift`, which compiles only
/// under `PLUGINS=1` and is outside the `swift test` target, so the chain itself was
/// untested by construction. A test spelling out the right sequence proves nothing about
/// an app that performs a different one — which is exactly what v6 did:
///
/// ```swift
/// seedBoxes(captions: spec.captions, slots: slots)   // v6: no extraction, no fit
/// ```
///
/// `MemeCaptionSeeding.resolve` now owns that chain, and the app is a call to it. These
/// tests drive `resolve` with a raw model reply, so a regression anywhere in the
/// sequence fails here on a stock `swift test` run.
final class MemeCaptionSeedingTests: XCTestCase {

    /// THE REPRO, end to end through the real decision.
    ///
    /// The owner's prompt, the model answering in the legacy `top_text`/`bottom_text`
    /// shape with the user's FIRST and LAST items (the screenshot exactly), and a 4-slot
    /// Expanding Brain. Four boxes, four captions, in order, no refit.
    func testTheScreenshotReproSeedsFourBoxesFromTheUsersOwnWords() {
        let description =
            "expanding brain: typing, dictating, dictating memes, dictating memes by voice"

        // What the v6 failure looked like on the wire: two captions, first and last.
        let raw = #"""
        {"templates":["Expanding Brain"],"top_text":"typing",
         "bottom_text":"dictating memes by voice","reason":"escalation"}
        """#
        guard case .success(let spec) = MemeAI.parseRanked(
            raw, catalogNames: ["Expanding Brain", "Drake Hotline Bling"])
        else { return XCTFail("the legacy shape must still parse") }

        // Precondition: the model really did return only two captions.
        XCTAssertEqual(spec.captions.count, 2)
        XCTAssertTrue(spec.wasLegacyShape)

        let seed = MemeCaptionSeeding.resolve(
            description: description,
            specCaptions: spec.captions,
            wasLegacyShape: spec.wasLegacyShape,
            templateSlots: 4)

        // The heart of it: four boxes carrying the user's own four items, in order.
        XCTAssertEqual(seed.boxes.count, 4, "a 4-slot template gets four boxes")
        XCTAssertEqual(seed.boxes.map(\.text), [
            "typing", "dictating", "dictating memes", "dictating memes by voice",
        ])
        XCTAssertEqual(seed.slots, 4)
        XCTAssertTrue(seed.boxes.allSatisfy { !$0.text.isEmpty }, "no blank panels")
        XCTAssertNil(seed.refit, "the user's own four captions already fit")
        XCTAssertTrue(seed.captionsCameFromUser)

        // The exact v6 signature must be gone: never two filled boxes carrying the
        // first and last items.
        let filled = seed.boxes.filter { !$0.text.isEmpty }
        XCTAssertNotEqual(
            filled.map(\.text), ["typing", "dictating memes by voice"],
            "the v6 collapse: first and last item, seeded top/bottom")
    }

    /// Slot GEOMETRY, not just the text: four boxes must be four distinct stacked
    /// positions, not two top/bottom ones with extras piled on.
    func testTheReproSeedsFourDistinctStackedSlots() {
        let seed = MemeCaptionSeeding.resolve(
            description: "expanding brain: typing, dictating, dictating memes, dictating memes by voice",
            specCaptions: ["typing", "by voice"],
            wasLegacyShape: true,
            templateSlots: 4)

        let centersY = seed.boxes.map(\.centerY)
        XCTAssertEqual(Set(centersY).count, 4, "four distinct vertical positions")
        XCTAssertEqual(centersY, centersY.sorted(), "panel order runs top to bottom")

        // The classic 2-slot layout puts captions at 0.12/0.88. A 4-slot template must
        // NOT reuse those — that is the visual signature of the bug.
        XCTAssertNotEqual(centersY.first, 0.12, "not the classic top caption position")
        XCTAssertNotEqual(centersY.last, 0.88, "not the classic bottom caption position")
    }

    /// The other half of rule 2: the geometry comes from the TEMPLATE, so the same
    /// four-item description on a 2-slot template does not invent four boxes.
    func testTheTemplateOwnsTheSlotCountNotTheCaptionList() {
        let seed = MemeCaptionSeeding.resolve(
            description: "drake: manual testing, automated testing, prod, prayer",
            specCaptions: ["a", "b"],
            wasLegacyShape: true,
            templateSlots: 2)

        XCTAssertEqual(seed.boxes.count, 2, "a 2-slot template gets exactly two boxes")
        // Four captions for two slots is a mismatch, and a mismatch REFITS rather than
        // dropping the extras silently.
        XCTAssertEqual(seed.refit?.slots, 2)
        XCTAssertEqual(seed.refit?.from.count, 4)
    }

    /// Ordinary prose still goes through the model, unchanged: no extraction, and the
    /// model's captions are what get seeded.
    func testProseKeepsTheModelsCaptions() {
        let seed = MemeCaptionSeeding.resolve(
            description: "make me a drake meme about rust and go",
            specCaptions: ["rust", "go"],
            wasLegacyShape: true,
            templateSlots: 2)

        XCTAssertEqual(seed.boxes.map(\.text), ["rust", "go"])
        XCTAssertFalse(seed.captionsCameFromUser)
        XCTAssertNil(seed.refit, "two captions fill a two-slot template")
    }

    /// A short model answer on a 4-slot template — prose, so no extraction to save it —
    /// must refit rather than render two captions and two blanks. This is the v6 bug's
    /// other entry point, and the refit must be REACHABLE from the resolve the app calls.
    func testAShortProseAnswerOnAFourSlotTemplateOwesARefit() {
        let seed = MemeCaptionSeeding.resolve(
            description: "an expanding brain meme about testing",
            specCaptions: ["typing", "by voice"],
            wasLegacyShape: true,
            templateSlots: 4)

        XCTAssertEqual(seed.boxes.count, 4, "the boxes still match the template")
        guard let refit = seed.refit else {
            return XCTFail("a 2-of-4 answer must owe a refit, not render two blanks")
        }
        XCTAssertEqual(refit.slots, 4)
        XCTAssertEqual(refit.from, ["typing", "by voice"])
        XCTAssertEqual(refit.status, "Model wrote 2 of 4 — refitting…")
    }

    /// No template chosen yet falls back to the classic default rather than crashing or
    /// seeding zero boxes.
    func testNoTemplateFallsBackToTheClassicDefault() {
        let seed = MemeCaptionSeeding.resolve(
            description: "something funny", specCaptions: ["a", "b"], templateSlots: nil)
        XCTAssertEqual(seed.slots, MemeCaptionSlots.default)
        XCTAssertEqual(seed.boxes.count, MemeCaptionSlots.default)
    }

    /// An empty answer seeds empty boxes to type into and owes NO refit — asking a model
    /// to rewrite nothing into four somethings is how you get four hallucinations.
    func testAnEmptyAnswerSeedsEmptyBoxesWithoutARefit() {
        let seed = MemeCaptionSeeding.resolve(
            description: "an expanding brain meme", specCaptions: [], templateSlots: 4)
        XCTAssertEqual(seed.boxes.count, 4)
        XCTAssertTrue(seed.boxes.allSatisfy { $0.text.isEmpty })
        XCTAssertNil(seed.refit)
    }

    // MARK: - The template query comes from the same extraction

    /// A list-shaped description searches on its THEME and prefers the item count, so
    /// the caption words don't pollute the template match.
    func testAListSearchesOnItsThemeAndPrefersItsItemCount() {
        let search = MemeCaptionSeeding.templateQuery(
            for: "expanding brain: typing, dictating, dictating memes, dictating memes by voice")
        XCTAssertEqual(search.query, "expanding brain")
        XCTAssertEqual(search.preferredSlots, 4)
    }

    /// Prose searches on itself and expresses no slot preference.
    func testProseSearchesOnTheWholeDescription() {
        let search = MemeCaptionSeeding.templateQuery(for: "a drake meme about rust and go")
        XCTAssertEqual(search.query, "a drake meme about rust and go")
        XCTAssertNil(search.preferredSlots)
    }

    /// A themeless list still reports its slot count — the numbering is the enumeration
    /// signal — but has no better query than the description itself.
    func testAThemelessListStillReportsItsSlotCount() {
        let search = MemeCaptionSeeding.templateQuery(for: "1. wake up 2. write code 3. sleep")
        XCTAssertEqual(search.query, "1. wake up 2. write code 3. sleep")
        XCTAssertEqual(search.preferredSlots, 3)
    }
}
