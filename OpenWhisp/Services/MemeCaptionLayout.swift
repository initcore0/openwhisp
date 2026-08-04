import Foundation

/// The pure text rules behind classic meme captioning.
///
/// Everything here is Foundation-only arithmetic and string work so `swift test`
/// pins it; the app layer owns only the actual CoreGraphics drawing. The split is
/// deliberate — line breaking and font sizing are where meme rendering actually goes
/// wrong (a long caption overflowing the image), and those are exactly the parts
/// that don't need a graphics context to verify.
public enum MemeCaptionLayout {

    /// Classic meme captions are UPPERCASE. Applied here rather than at the drawing
    /// site so the transformation is tested and so the LLM's casing never leaks
    /// through inconsistently.
    ///
    /// Uppercasing is locale-aware, which matters for the non-English captions the
    /// prompt deliberately preserves.
    public static func displayText(_ caption: String) -> String {
        caption.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Break a caption into lines that each fit `maxWidth`, given a function that
    /// measures a candidate line at the current font size.
    ///
    /// Greedy word wrapping: fill a line until the next word wouldn't fit. A single
    /// word longer than `maxWidth` is NOT broken mid-word — it gets its own line and
    /// the caller shrinks the font instead, which is what preserves readability
    /// (hyphenating "AAAAAAAAAA" helps nobody).
    ///
    /// `measure` is injected so this stays pure: tests pass a deterministic
    /// width-per-character stub, the app passes real font metrics.
    public static func wrap(
        _ text: String,
        maxWidth: Double,
        measure: (String) -> Double
    ) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return [] }

        var lines: [String] = []
        var current = ""

        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if current.isEmpty || measure(candidate) <= maxWidth {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// The result of fitting a caption into a box.
    public struct Fit: Equatable, Sendable {
        /// The wrapped lines to draw, already uppercased.
        public let lines: [String]
        /// The font size that made them fit.
        public let fontSize: Double

        public init(lines: [String], fontSize: Double) {
            self.lines = lines
            self.fontSize = fontSize
        }
    }

    /// Shrink-to-fit: find the largest font size (stepping down from `maxFontSize`)
    /// at which the wrapped caption fits within `maxWidth` × `maxHeight`.
    ///
    /// Meme captions must never overflow the image, but they also shouldn't be
    /// needlessly tiny, so this walks DOWN from the ideal size and takes the first
    /// size that fits rather than solving analytically (line count changes
    /// discontinuously with font size, so there's no clean closed form).
    ///
    /// If even `minFontSize` overflows — a genuinely enormous caption — the result is
    /// returned AT `minFontSize` anyway: clipping a too-long caption is a better
    /// failure than rendering nothing, and the caller has already been told the text
    /// is long. Honest degradation over silent emptiness.
    ///
    /// - Parameters:
    ///   - measure: `(text, fontSize) -> width` at that size.
    ///   - lineHeight: `fontSize -> line height`, so callers can pass real metrics.
    public static func fit(
        caption: String,
        maxWidth: Double,
        maxHeight: Double,
        maxFontSize: Double,
        minFontSize: Double,
        step: Double = 2,
        measure: (String, Double) -> Double,
        lineHeight: (Double) -> Double
    ) -> Fit {
        let text = displayText(caption)
        guard !text.isEmpty else { return Fit(lines: [], fontSize: maxFontSize) }
        guard maxFontSize >= minFontSize, step > 0 else {
            return Fit(lines: [text], fontSize: minFontSize)
        }

        var size = maxFontSize
        while size > minFontSize {
            let lines = wrap(text, maxWidth: maxWidth) { measure($0, size) }
            let totalHeight = Double(lines.count) * lineHeight(size)
            let widest = lines.map { measure($0, size) }.max() ?? 0
            if totalHeight <= maxHeight && widest <= maxWidth {
                return Fit(lines: lines, fontSize: size)
            }
            size -= step
        }

        // Floor: wrap at the smallest allowed size and accept it.
        let lines = wrap(text, maxWidth: maxWidth) { measure($0, minFontSize) }
        return Fit(lines: lines, fontSize: minFontSize)
    }

    // MARK: - Caption boxes (manual editor)

    /// One editable caption on the image.
    ///
    /// **Coordinates are NORMALIZED** (0…1, origin TOP-LEFT like every UI framework
    /// the editor draws in) rather than pixels. That is what lets a box dragged on a
    /// 520pt-wide preview render identically into a 1200px export, and what lets a
    /// box survive being moved to a template with different dimensions when the user
    /// picks another candidate — the whole point of the candidate strip is that the
    /// captions carry over.
    ///
    /// `fontSize` is likewise a SHARE of image height, not points, for the same
    /// reason: a 0.11 caption looks the same on a 400px and a 1200px template.
    ///
    /// `fontName` is a face name resolved by the renderer (`nil` = the renderer's
    /// default meme face). Kept as a string rather than a font object so the box
    /// model stays Foundation-only and testable.
    public struct CaptionBox: Equatable, Sendable, Identifiable, Codable {
        public let id: UUID
        /// The caption text as the user typed it. Uppercasing happens at render time
        /// so the editor shows what was typed.
        public var text: String
        /// Horizontal center, 0 = left edge, 1 = right edge.
        public var centerX: Double
        /// Vertical center, 0 = TOP edge, 1 = bottom edge.
        public var centerY: Double
        /// Font size as a share of image height.
        public var fontSizeShare: Double
        /// Width available to the box, as a share of image width.
        public var widthShare: Double
        /// Face name, or nil for the renderer's default.
        public var fontName: String?

        public init(
            id: UUID = UUID(),
            text: String,
            centerX: Double,
            centerY: Double,
            fontSizeShare: Double = CaptionBox.defaultFontSizeShare,
            widthShare: Double = CaptionBox.defaultWidthShare,
            fontName: String? = nil
        ) {
            self.id = id
            self.text = text
            self.centerX = centerX
            self.centerY = centerY
            self.fontSizeShare = fontSizeShare
            self.widthShare = widthShare
            self.fontName = fontName
        }

        /// The classic caption size — carried over from v1's fixed layout so an
        /// AI-seeded meme looks the same as it did before the editor existed.
        public static let defaultFontSizeShare: Double = 0.11
        /// Full width minus a 5% margin per side: the caption never runs to the bezel.
        public static let defaultWidthShare: Double = 0.90

        /// Slider bounds for the editor. Below the floor text is unreadable; above
        /// the ceiling a single word fills the image.
        public static let minimumFontSizeShare: Double = 0.02
        public static let maximumFontSizeShare: Double = 0.30
    }

    /// Clamp a box's geometry into the image.
    ///
    /// Applied on every drag and every slider move so a box can never be parked
    /// outside the canvas (where it would render invisibly and look like data loss).
    /// The center is clamped to the edges rather than inset by half the box height —
    /// letting a caption bleed off the edge is a legitimate meme look, and a caption
    /// the user can still grab matters more than one that is fully contained.
    public static func clamped(_ box: CaptionBox) -> CaptionBox {
        var out = box
        out.centerX = min(max(box.centerX, 0), 1)
        out.centerY = min(max(box.centerY, 0), 1)
        out.fontSizeShare = min(
            max(box.fontSizeShare, CaptionBox.minimumFontSizeShare),
            CaptionBox.maximumFontSizeShare)
        out.widthShare = min(max(box.widthShare, 0.05), 1)
        return out
    }

    /// Blank the TEXT of one box, keeping every box and all geometry.
    ///
    /// Used for the live drag: the box being dragged has its caption drawn by the drag
    /// handle, travelling with the cursor, so the burned-in render must not draw it a
    /// second time at the position the user is moving it away from.
    ///
    /// The box is emptied rather than REMOVED, and that distinction is the whole point:
    /// `boxes` is the document, indices and ids are referenced by the editor's
    /// selection, and dropping an element mid-gesture to achieve a visual effect would
    /// make a rendering concern edit the user's data. Emptying `text` changes only what
    /// is painted. `nil` returns the boxes untouched, so the resting path is identity.
    public static func hidingText(of id: UUID?, in boxes: [CaptionBox]) -> [CaptionBox] {
        guard let id else { return boxes }
        return boxes.map { box in
            guard box.id == id else { return box }
            var hidden = box
            hidden.text = ""
            return hidden
        }
    }

    /// The two boxes the AI path seeds: classic top and bottom captions.
    ///
    /// Positioned at 0.12 / 0.88 of the height — far enough in that a two-line
    /// caption still sits inside the image, which is where v1's top/bottom blocks
    /// landed. An empty caption still gets a box so the editor has something to type
    /// into rather than making the user hunt for "Add text box".
    ///
    /// Kept as the 2-slot special case of `seedBoxes(captions:slots:)` so the classic
    /// path is literally the same code and can't drift from it.
    ///
    /// **Deprecated in v8.** It hard-codes `slots: 2`, so reaching for it on ANY code
    /// path that doesn't already know the template is 2-slot is the v6 bug's exact
    /// shape: four captions in, two boxes out, no test failing. It has no production
    /// callers left — the app seeds through `MemeCaptionSeeding.resolve`, which takes
    /// the slot count from the template. Retained (deprecated rather than unavailable)
    /// because the geometry assertions in the test suite are legitimately ABOUT the
    /// 2-slot layout, and rewriting them would lose that coverage.
    @available(*, deprecated, message: """
        Hard-codes 2 slots. Use seedBoxes(captions:slots:) with the template's own \
        captionSlots, or MemeCaptionSeeding.resolve for the full decision.
        """)
    public static func seedBoxes(topText: String, bottomText: String) -> [CaptionBox] {
        seedBoxes(captions: [topText, bottomText], slots: 2)
    }

    // MARK: - Per-template caption slots

    /// Where a template's `n` caption slots sit, as normalized centers.
    ///
    /// ## The honest state of the source data
    ///
    /// The task hoped memegen would supply real box POSITIONS. It does not — verified
    /// against the live API on 2026-08-03. `GET /templates` returns
    /// `{id, name, lines, overlays, styles, blank, example, source, keywords, _self}`
    /// and the per-template `GET /templates/<id>` returns the same shape; `lines` is a
    /// COUNT and there is no geometry field anywhere in either payload. imgflip's
    /// `get_memes` is the same story — `box_count`, no rectangles. (imgflip *does*
    /// expose per-box geometry, but only through the authenticated `caption_image`
    /// endpoint, which is a captioning API we deliberately don't use: sending the
    /// user's words to someone else's server is exactly the local-first line this
    /// plugin holds.)
    ///
    /// So EVERY position here is synthesized from the count. The doc comment says so
    /// rather than implying the layout is template-accurate, because a wrong claim
    /// about provenance is how the next person ships a "fix" that removes a fallback
    /// that was never a fallback.
    ///
    /// ## The synthesized layouts, and why each shape
    ///
    /// * **1** — one centered caption near the top: the impact-font one-liner.
    /// * **2** — classic top/bottom at 0.12 / 0.88. Unchanged from v1, because this is
    ///   two thirds of the corpus (166 of memegen's 212, 66 of imgflip's 100) and
    ///   regressing the common case to gain the rare one is a bad trade.
    /// * **3 and 4** — a STACKED LEFT COLUMN: evenly spaced rows, left-aligned by
    ///   sitting at x = 0.30 with a narrower width. This is a deliberate compromise, and
    ///   it is a genuine compromise, so here is the reasoning. The 3- and 4-slot
    ///   templates that matter (Drake, Distracted Boyfriend, Expanding Brain, Galaxy
    ///   Brain) are PANEL memes: their captions belong beside or inside stacked panels,
    ///   never spread top-to-bottom across the whole frame. A stacked column lands the
    ///   captions in roughly the right band for a vertically-panelled template (Drake,
    ///   Expanding Brain — the most common panel layout by far) and merely
    ///   *approximately* right for a horizontally-panelled one (Distracted Boyfriend).
    ///   Approximately-right and draggable beats confidently-wrong and invisible: the
    ///   user sees N captions in N distinct places and moves them, instead of getting
    ///   two captions for a four-panel joke.
    /// * **5+** — the same even column at full width, since past four slots there is no
    ///   dominant convention left to approximate.
    ///
    /// The real fix is per-template geometry, which needs a data source none of the
    /// key-less APIs provide — a bundled table of hand-measured boxes for the top ~30
    /// templates would do it, and that is a deliberate non-goal.
    public static func slotCenters(slots: Int) -> [(x: Double, y: Double)] {
        let count = MemeCaptionSlots.clamp(slots)
        switch count {
        case 1:
            return [(0.5, 0.12)]
        case 2:
            return [(0.5, 0.12), (0.5, 0.88)]
        default:
            // Evenly spaced rows inside the frame, inset so the first and last aren't
            // welded to the bezel. Panel memes read top-to-bottom, so slot order is
            // top-to-bottom too — which is also the order the LLM returns captions in.
            let top = 0.14
            let bottom = 0.86
            let span = bottom - top
            let x = count <= 4 ? 0.30 : 0.5
            return (0..<count).map { index in
                let t = Double(index) / Double(count - 1)
                return (x, top + span * t)
            }
        }
    }

    /// How wide a box should be for an `n`-slot template.
    ///
    /// Narrower for the 3–4 panel layouts because those captions sit in a left column
    /// beside the artwork; a full-width box there would run straight across the panel
    /// it is labelling.
    public static func slotWidthShare(slots: Int) -> Double {
        MemeCaptionSlots.clamp(slots) <= 2 ? CaptionBox.defaultWidthShare : 0.46
    }

    /// The font share for an `n`-slot template.
    ///
    /// Stacked captions have to share the frame's height, so they start smaller — at
    /// the classic 0.11 four captions would overlap before the user typed anything.
    /// This is a CEILING (`layout` shrinks further to fit), so a short caption still
    /// renders as large as it can.
    public static func slotFontSizeShare(slots: Int) -> Double {
        MemeCaptionSlots.clamp(slots) <= 2 ? CaptionBox.defaultFontSizeShare : 0.07
    }

    /// Seed one box per caption slot, laid out for a template of that structure.
    ///
    /// The caption list is fitted to the slot count rather than trusted: a model that
    /// returns three captions for a two-slot template has its extra dropped, and one
    /// that returns two for a four-slot template gets two empty boxes to type into.
    /// Both are better than the alternatives — rendering captions the template has no
    /// room for, or silently losing the ones it does.
    ///
    /// Empty captions still get boxes, for the same reason `seedBoxes(topText:)` always
    /// did: the editor needs a handle to type into.
    public static func seedBoxes(captions: [String], slots: Int) -> [CaptionBox] {
        let count = MemeCaptionSlots.clamp(slots)
        let centers = slotCenters(slots: count)
        let width = slotWidthShare(slots: count)
        let fontSize = slotFontSizeShare(slots: count)

        return centers.enumerated().map { index, center in
            CaptionBox(
                text: index < captions.count ? captions[index] : "",
                centerX: center.x,
                centerY: center.y,
                fontSizeShare: fontSize,
                widthShare: width)
        }
    }

    // MARK: - What a regenerate is allowed to destroy

    /// Merge a fresh AI seed over the boxes already on the canvas.
    ///
    /// ## The rule, stated once: Generate replaces AI-seeded boxes and PRESERVES boxes
    /// the user added.
    ///
    /// v5's Generate assigned `boxes = seedBoxes(...)` outright, so a user who had
    /// pressed "Add text", typed a third caption, and positioned it, lost it the moment
    /// they tweaked the description and regenerated. Silent destruction of manual work
    /// is the worst class of bug in an editor, and it has no undo here.
    ///
    /// Of the two options in the brief — confirm before replacing, or preserve
    /// user-added boxes — this takes the second, deliberately:
    ///
    /// * A confirmation dialog charges EVERY regenerate (the common, harmless case:
    ///   nothing was hand-added and the user just wants a rewrite) to protect the rare
    ///   one. Generate is the plugin's primary verb and putting a modal in front of it
    ///   would be felt on every single use.
    /// * "Your own boxes survive, the AI's are rewritten" is a rule a user can hold in
    ///   their head and predict, which a dialog they dismiss reflexively is not.
    /// * It is reversible in the direction that matters: an unwanted surviving box is
    ///   one click on the trash icon, whereas a destroyed caption is retyped and
    ///   repositioned from memory.
    ///
    /// A box counts as user-added when its id is not among `seededIDs` — the ids the
    /// previous seed minted. EDITS to a seeded box (retyping it, dragging it, resizing
    /// it) are NOT preserved: that box is the AI's answer to the old description, and a
    /// regenerate is a request for a new answer, so keeping the old text would make
    /// Generate look broken. The distinction is deliberate and is what keeps the rule
    /// to one sentence.
    ///
    /// Preserved boxes keep their identity, text, and geometry exactly, and are
    /// appended AFTER the new seed so panel order still reads top-to-bottom for the
    /// slots the template actually has.
    public static func merging(
        seed: [CaptionBox], into existing: [CaptionBox], seededIDs: Set<UUID>
    ) -> [CaptionBox] {
        let userAdded = existing.filter { !seededIDs.contains($0.id) }
        return seed + userAdded
    }

    /// A box resolved into pixels for one specific image size, with its text already
    /// wrapped and shrunk to fit.
    public struct BoxLayout: Equatable, Sendable {
        public let id: UUID
        /// Wrapped, uppercased lines.
        public let lines: [String]
        /// Font size in PIXELS for this image.
        public let fontSize: Double
        /// Face name, or nil for the renderer's default.
        public let fontName: String?
        /// Box center in pixels, origin TOP-LEFT.
        public let centerX: Double
        public let centerY: Double
        /// Total height of the wrapped block, in pixels.
        public let blockHeight: Double
        /// Available width in pixels (what the text was wrapped to).
        public let maxWidth: Double

        public init(
            id: UUID, lines: [String], fontSize: Double, fontName: String?,
            centerX: Double, centerY: Double, blockHeight: Double, maxWidth: Double
        ) {
            self.id = id
            self.lines = lines
            self.fontSize = fontSize
            self.fontName = fontName
            self.centerX = centerX
            self.centerY = centerY
            self.blockHeight = blockHeight
            self.maxWidth = maxWidth
        }

        /// Y of the block's TOP edge, origin top-left. The renderer flips this into
        /// AppKit's bottom-left space; the editor uses it directly.
        public var blockTopY: Double { centerY - blockHeight / 2 }
    }

    /// The multiplier from font size to line height, shared by the layout math, the
    /// renderer, and the editor's hit-testing so all three agree on box height.
    public static let lineHeightRatio: Double = 1.15

    /// Resolve one box against an image size: normalized geometry → pixels, text
    /// wrapped and shrunk to fit the box's width.
    ///
    /// The user's `fontSizeShare` is the CEILING, not a fixed size — a caption too
    /// long for its box still shrinks rather than overflowing, exactly like the AI
    /// path. Setting a size and getting overflowing text would be a worse editor
    /// than one that quietly keeps the caption inside its box; the user can widen
    /// the box or shorten the text if they want it bigger.
    ///
    /// `measure` and `lineHeight` are injected so this stays pure (tests pass a
    /// deterministic stub, the renderer passes real font metrics). `measure`
    /// receives the box's `fontName` so per-box faces are measured with the right
    /// metrics.
    public static func layout(
        box: CaptionBox,
        imageWidth: Double,
        imageHeight: Double,
        measure: (_ text: String, _ fontSize: Double, _ fontName: String?) -> Double
    ) -> BoxLayout {
        let safe = clamped(box)
        let maxWidth = max(1, imageWidth * safe.widthShare)
        let ceiling = max(1, imageHeight * safe.fontSizeShare)
        // Floor at a quarter of the requested size: a caption may shrink to stay in
        // its box, but never to the point of being unreadable — beyond that it
        // clips, which `fit` already degrades to honestly.
        let floor = max(1, ceiling * 0.25)

        let fit = fit(
            caption: safe.text,
            maxWidth: maxWidth,
            // Vertically the box is free to grow — it's the WIDTH the user controls.
            // Capping at the image height stops an absurd caption from becoming a
            // block taller than the canvas.
            maxHeight: imageHeight,
            maxFontSize: ceiling,
            minFontSize: floor,
            step: max(1, ceiling * 0.05),
            measure: { text, size in measure(text, size, safe.fontName) },
            lineHeight: { $0 * lineHeightRatio })

        let blockHeight = Double(fit.lines.count) * fit.fontSize * lineHeightRatio

        return BoxLayout(
            id: safe.id,
            lines: fit.lines,
            fontSize: fit.fontSize,
            fontName: safe.fontName,
            centerX: safe.centerX * imageWidth,
            centerY: safe.centerY * imageHeight,
            blockHeight: blockHeight,
            maxWidth: maxWidth)
    }

    /// Resolve every box, dropping the ones with nothing to draw.
    ///
    /// Empty boxes are dropped at RENDER time only — the editor keeps them so the
    /// user has a handle to type into. This is why the export and the preview can
    /// disagree by exactly the empty boxes, which is the correct behaviour.
    public static func layout(
        boxes: [CaptionBox],
        imageWidth: Double,
        imageHeight: Double,
        measure: (_ text: String, _ fontSize: Double, _ fontName: String?) -> Double
    ) -> [BoxLayout] {
        boxes
            .map { layout(box: $0, imageWidth: imageWidth, imageHeight: imageHeight, measure: measure) }
            .filter { !$0.lines.isEmpty }
    }

    /// Where "Add text box" drops a new caption.
    ///
    /// Stacked down the middle so successive adds don't land on top of each other
    /// (which would look like the button did nothing). Wraps back to the top after
    /// filling the column rather than marching off the bottom edge.
    public static func newBoxCenter(existingCount: Int) -> (x: Double, y: Double) {
        let slots = [0.5, 0.3, 0.7, 0.2, 0.8, 0.4, 0.6]
        return (0.5, slots[existingCount % slots.count])
    }

    // MARK: - Export naming

    /// A PNG filename derived from the captions, so saved memes are findable later
    /// rather than a wall of `meme.png`, `meme-1.png`.
    ///
    /// Slugified conservatively: non-alphanumerics collapse to single hyphens, so a
    /// caption in any script degrades to something a filesystem is happy with, and
    /// an all-punctuation caption still yields a usable `meme.png`.
    public static func suggestedFileName(topText: String, bottomText: String) -> String {
        let joined = [topText, bottomText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")

        let slug = joined
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { partial, char in
                // Collapse runs of separators instead of emitting `a---b`.
                if char == "-", partial.last == "-" { return }
                partial.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(48)

        return (slug.isEmpty ? "meme" : String(slug)) + ".png"
    }

    /// The same naming rule, driven by the box model so an edited meme exports under
    /// the name the user actually sees rather than the AI's original captions.
    public static func suggestedFileName(boxes: [CaptionBox]) -> String {
        let joined = boxes
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        return suggestedFileName(topText: joined, bottomText: "")
    }
}
