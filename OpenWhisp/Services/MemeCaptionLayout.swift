import Foundation

/// The pure text rules behind classic meme captioning (spike).
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

    /// The two boxes the AI path seeds: classic top and bottom captions.
    ///
    /// Positioned at 0.12 / 0.88 of the height — far enough in that a two-line
    /// caption still sits inside the image, which is where v1's top/bottom blocks
    /// landed. An empty caption still gets a box so the editor has something to type
    /// into rather than making the user hunt for "Add text box".
    public static func seedBoxes(topText: String, bottomText: String) -> [CaptionBox] {
        [
            CaptionBox(text: topText, centerX: 0.5, centerY: 0.12),
            CaptionBox(text: bottomText, centerX: 0.5, centerY: 0.88),
        ]
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
