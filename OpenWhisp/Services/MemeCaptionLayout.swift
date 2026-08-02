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

    // MARK: - Geometry

    /// Where a caption block sits on the image.
    public enum Position: String, Equatable, Sendable {
        case top
        case bottom
    }

    /// The share of the image height one caption block may occupy before it must
    /// shrink. Classic memes keep captions in the top/bottom third.
    public static let captionHeightShare: Double = 0.32

    /// The horizontal inset applied to both sides, as a share of image width — the
    /// caption never runs to the bezel.
    public static let horizontalInsetShare: Double = 0.05

    /// Ideal font size for an image height, before shrink-to-fit. Scaled to the
    /// image so a 1200px template and a 400px one look the same when displayed.
    public static func idealFontSize(imageHeight: Double) -> Double {
        max(12, imageHeight * 0.11)
    }

    /// Smallest acceptable font size for an image height.
    public static func minimumFontSize(imageHeight: Double) -> Double {
        max(8, imageHeight * 0.04)
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
}
