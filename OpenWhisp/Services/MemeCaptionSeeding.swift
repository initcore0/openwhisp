import Foundation

/// The whole "captions → boxes" decision, in one pure place (spike v8).
///
/// ## Why this type exists — the test gap that let v6 ship
///
/// v6 rendered the owner's four-item Expanding Brain prompt as TWO captions. The fix
/// (v7) was real, but it was verified by tests that re-implemented the app's steps
/// rather than calling the app's code: each core piece — `MemeCaptionExtraction`,
/// `RankedSpec.replacingCaptions`, `MemeAI.fit`, `MemeCaptionLayout.seedBoxes` — was
/// proved correct in isolation, while the code that CHAINS them lived in
/// `MemeGeneratorModel.applyRanked`, inside `plugins/`, which compiles only under
/// `PLUGINS=1` and is outside the `swift test` target.
///
/// So the sequence was untested by construction, and a test asserting "extract, then
/// replace, then fit with slots: 4" could pass forever while the app passed
/// `spec.captions` straight to `seedBoxes` — which is precisely what v6 did:
///
/// ```swift
/// let slots = picks.first?.captionSlots ?? MemeCaptionSlots.default
/// seedBoxes(captions: spec.captions, slots: slots)   // v6 — no extraction, no fit
/// ```
///
/// The two filled boxes were the legacy `top_text`/`bottom_text` pair, padded out with
/// blanks by `seedBoxes` and rendered without complaint.
///
/// This type moves that chain OUT of the plugin. `resolve` takes everything the
/// decision depends on — the user's description, the model's answer, and the chosen
/// template's slot count — and returns the boxes plus whether a refit is owed. The
/// plugin keeps only what genuinely needs AppKit: assigning `boxes`, merging the
/// user's hand-added boxes, and running the async refit round-trip.
///
/// The property that matters: a caption-count regression now fails `swift test`
/// against the SAME function the app calls, on a stock build, with no `PLUGINS=1`.
public enum MemeCaptionSeeding {

    /// A resolved seeding decision: the boxes to show now, and what is still owed.
    public struct Seed: Equatable, Sendable {
        /// The boxes to put on the canvas, one per slot the template really has.
        public let boxes: [MemeCaptionLayout.CaptionBox]

        /// The captions those boxes carry, before layout — kept so a caller (and a
        /// test) can assert the TEXT decision separately from the geometry.
        public let captions: [String]

        /// The slot count the boxes were laid out for: the template's own structure,
        /// clamped. Never an assumed pair.
        public let slots: Int

        /// The refit round-trip owed for this seed, or nil when the captions already
        /// fill the template. Non-nil is not an error — the boxes are still valid and
        /// are shown immediately; the refit is a visible correction that follows.
        public let refit: Refit?

        /// True when the captions came from the user's own words rather than the
        /// model's. Drives the status line, and is the signal that no LLM caption
        /// round-trip was needed at all.
        public let captionsCameFromUser: Bool

        public init(
            boxes: [MemeCaptionLayout.CaptionBox], captions: [String], slots: Int,
            refit: Refit? = nil, captionsCameFromUser: Bool = false
        ) {
            self.boxes = boxes
            self.captions = captions
            self.slots = slots
            self.refit = refit
            self.captionsCameFromUser = captionsCameFromUser
        }
    }

    /// A second round-trip owed because the caption count didn't match the template.
    public struct Refit: Equatable, Sendable {
        /// The captions to rewrite.
        public let from: [String]
        /// How many captions the template needs.
        public let slots: Int
        /// The status line to show while it runs — honest about the shortfall.
        public var status: String { MemeAI.refitStatus(wrote: from.count, of: slots) }

        public init(from: [String], slots: Int) {
            self.from = from
            self.slots = slots
        }
    }

    /// Decide the boxes for a ranked answer, given the template that will hold them.
    ///
    /// The order of the three rules is the whole design, and each one removes a way the
    /// v6 bug could come back:
    ///
    /// 1. **The user's own words win.** When the description was list-shaped
    ///    ("expanding brain: a, b, c, d") those items ARE the captions, verbatim and in
    ///    order, and the model's captions are discarded. A model cannot return the wrong
    ///    number of captions for a question that was never asked.
    /// 2. **The geometry comes from the template**, never from the caption count. A
    ///    4-slot template lays out four boxes whether the model wrote one caption or
    ///    seven, so an N≠2 template can never render as a classic two-liner.
    /// 3. **A count mismatch refits rather than padding.** Two captions on a four-slot
    ///    template is not "two captions and two blanks", it is the wrong answer, and it
    ///    is sent back to be rewritten.
    ///
    /// - Parameters:
    ///   - description: what the user typed or dictated — read for a caption list first.
    ///   - specCaptions: the captions the model returned.
    ///   - wasLegacyShape: whether those came from `top_text`/`bottom_text`.
    ///   - templateSlots: the chosen template's own slot count, or nil when there is no
    ///     template yet (falls back to the classic default, as every path always has).
    public static func resolve(
        description: String,
        specCaptions: [String],
        wasLegacyShape: Bool = false,
        templateSlots: Int?
    ) -> Seed {
        let extracted = MemeCaptionExtraction.extract(from: description)

        // Rule 1: the user's own list wins over whatever the model wrote.
        let captions = extracted?.captions ?? specCaptions
        // Captions taken from the user are never "legacy shaped" — they didn't come
        // from a top/bottom pair, and treating them as such would misreport the status.
        let legacy = extracted == nil ? wasLegacyShape : false

        // Rule 2: the geometry is the TEMPLATE's, always.
        let slots = MemeCaptionSlots.clamp(templateSlots ?? MemeCaptionSlots.default)

        // Rule 3: a mismatch is refitted, not padded.
        let fit = MemeAI.fit(captions: captions, slots: slots, wasLegacyShape: legacy)

        let boxes = MemeCaptionLayout.seedBoxes(captions: fit.captions, slots: slots)
        let refit: Refit? = {
            guard case .refit(let from, let target) = fit else { return nil }
            return Refit(from: from, slots: target)
        }()

        return Seed(
            boxes: boxes, captions: fit.captions, slots: slots, refit: refit,
            captionsCameFromUser: extracted != nil)
    }

    /// The template search query for a description, and the slot count to prefer.
    ///
    /// Lives here rather than in the plugin for the same reason as `resolve`: it is a
    /// pure decision derived from the SAME extraction, and splitting the two across the
    /// test boundary is how they would drift. When the description is list-shaped the
    /// theme ("expanding brain") is the query — searching with the caption words in it
    /// would score the template against text that is about to become its captions — and
    /// the item count is the slot count to prefer.
    public static func templateQuery(for description: String) -> (query: String, preferredSlots: Int?) {
        guard let extracted = MemeCaptionExtraction.extract(from: description) else {
            return (description, nil)
        }
        // A themeless list ("1. a 2. b") still tells us the slot count, but has no
        // better query than the description itself.
        let query = extracted.theme.isEmpty ? description : extracted.theme
        return (query, extracted.slotCount)
    }
}
