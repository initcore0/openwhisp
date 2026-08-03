import AppKit
import Foundation

/// Draws classic meme captions onto a template image (spike).
///
/// Rendering is entirely LOCAL — there is no captioning API and no API key. We
/// download the blank template from imgflip's CDN and do the text ourselves with
/// AppKit, which is also why the plugin never sends the user's words anywhere: only
/// the template image comes over the wire.
///
/// The classic look: heavy condensed sans, WHITE fill with a BLACK outline, centered,
/// wrapped, top and bottom blocks. Impact is not present on macOS, so we fall back
/// through the closest system faces (see `captionFont`).
///
/// All the *decisions* (uppercasing, line breaking, shrink-to-fit, and — since v2 —
/// where every box sits) live in the pure, tested `MemeCaptionLayout`; this type owns
/// only the drawing and the font metrics it feeds back into that layout.
///
/// ## v2 — the box model
///
/// Rendering is driven by `[MemeCaptionLayout.CaptionBox]` rather than a fixed
/// top/bottom pair. The AI path seeds two boxes, the manual editor mutates them, and
/// BOTH the on-screen preview and the exported PNG go through `render(template:
/// boxes:)` — that's what makes the editor WYSIWYG. Because box geometry is
/// normalized, the same boxes render correctly onto a differently-sized template when
/// the user picks another candidate.
@MainActor
enum MemeRenderer {

    /// Compose a meme from a template and an array of caption boxes.
    ///
    /// Returns a new image at the template's pixel dimensions, so exports are
    /// full-resolution regardless of how the preview is scaled.
    static func render(
        template: NSImage,
        boxes: [MemeCaptionLayout.CaptionBox]
    ) -> NSImage {
        // Work in PIXELS, not points: NSImage.size is point-based and would render
        // captions at the wrong scale on a template whose rep is 2x.
        let pixelSize = pixelDimensions(of: template)
        let width = pixelSize.width
        let height = pixelSize.height

        let output = NSImage(size: NSSize(width: width, height: height))
        output.lockFocus()
        defer { output.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        template.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero, operation: .copy, fraction: 1.0)

        // The pure layer resolves normalized geometry into pixels and does the
        // wrapping/shrinking; we hand it real font metrics and then draw what comes
        // back. Empty boxes are dropped there, not here.
        let layouts = MemeCaptionLayout.layout(
            boxes: boxes,
            imageWidth: Double(width),
            imageHeight: Double(height),
            measure: { text, size, fontName in
                Double(text.size(withAttributes: [.font: captionFont(size: size, name: fontName)]).width)
            })

        for layout in layouts {
            draw(layout, imageHeight: height)
        }

        return output
    }

    /// v1's two-caption entry point. **Removed in v8 — do not reintroduce.**
    ///
    /// It had no callers left (the render path takes `boxes:`), and leaving a
    /// top/bottom-shaped overload in reach is precisely how a 4-slot template gets
    /// rendered as a classic two-liner: any future call site that reached for it would
    /// collapse N captions to 2 at the boundary, silently and without failing a test.
    /// The `boxes:` overload above is the only entry point; a caller that genuinely has
    /// two captions passes a 2-element array through `MemeCaptionSeeding`.
    @available(*, unavailable, message: """
        Removed in v8: renders exactly two captions and silently drops the rest. \
        Use render(template:boxes:) with boxes from MemeCaptionSeeding.resolve.
        """)
    static func render(template: NSImage, topText: String, bottomText: String) -> NSImage {
        fatalError("unavailable")
    }

    /// Draw one resolved box.
    ///
    /// The pure layer works in a TOP-LEFT origin (what every UI framework, and the
    /// editor's drag gestures, use). AppKit's image space is BOTTOM-LEFT, so the
    /// single conversion `imageHeight - y` happens here and nowhere else — keeping
    /// the flip in one place is what stops the editor and the export from disagreeing
    /// about which way is up.
    private static func draw(_ layout: MemeCaptionLayout.BoxLayout, imageHeight: CGFloat) {
        guard !layout.lines.isEmpty else { return }

        let font = captionFont(size: layout.fontSize, name: layout.fontName)
        let lineHeight = CGFloat(layout.fontSize * MemeCaptionLayout.lineHeightRatio)

        let style = NSMutableParagraphStyle()
        style.alignment = .center

        let attributes = captionAttributes(font: font, paragraphStyle: style)

        // Flip the block's top edge into AppKit's bottom-left space.
        let blockTopFlipped = imageHeight - CGFloat(layout.blockTopY)
        let boxLeft = CGFloat(layout.centerX - layout.maxWidth / 2)

        for (index, line) in layout.lines.enumerated() {
            let y = blockTopFlipped - lineHeight * CGFloat(index + 1)
            let rect = NSRect(
                x: boxLeft,
                y: y + (lineHeight - font.ascender + font.descender) / 2,
                width: CGFloat(layout.maxWidth), height: lineHeight)
            line.draw(in: rect, withAttributes: attributes)
        }
    }

    /// The classic look is a black OUTLINE around white glyphs. A negative
    /// `.strokeWidth` tells AppKit to stroke AND fill (a positive value strokes only,
    /// which would render hollow letters). CRUCIALLY the value is a PERCENTAGE of the
    /// font size, not points — scaling it by the font size double-scaled it to ~12%,
    /// thick enough that neighboring glyphs' black outlines swallowed each other's
    /// white interiors (the unreadable-blob bug). ~4% is the classic meme outline
    /// weight at any size.
    ///
    /// Shared by the renderer and any preview that wants to match it, so the two can
    /// never drift apart.
    static func captionAttributes(
        font: NSFont, paragraphStyle: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -4.0,
            .paragraphStyle: paragraphStyle,
        ]
    }

    /// The image's size in PIXELS, preferring the largest bitmap rep so a retina
    /// template exports at full resolution.
    private static func pixelDimensions(of image: NSImage) -> (width: CGFloat, height: CGFloat) {
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let best = reps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           best.pixelsWide > 0, best.pixelsHigh > 0 {
            return (CGFloat(best.pixelsWide), CGFloat(best.pixelsHigh))
        }
        // No bitmap rep (e.g. a vector or a placeholder): fall back to the point size,
        // guarding against a degenerate zero that would make an undrawable image.
        return (max(image.size.width, 1), max(image.size.height, 1))
    }

    // MARK: - Fonts

    /// The faces offered in the editor's font picker, best-meme-first.
    ///
    /// Impact — the canonical meme font — does not ship with macOS, so the list walks
    /// down through the closest heavy/condensed system faces. Only the ones actually
    /// installed are offered (`availableCaptionFonts`), because a picker listing a
    /// font that silently falls back to something else is worse than a short list.
    static let captionFontCandidates = [
        "Impact", "Haettenschweiler", "Arial Black", "HelveticaNeue-CondensedBlack",
    ]

    /// The label used for "no explicit face" — the renderer's own default.
    static let defaultFontLabel = "Default (meme)"

    /// The subset of `captionFontCandidates` present on this Mac, plus the always-
    /// available bold system font. Computed once; font availability doesn't change
    /// mid-session in any way that matters here.
    static let availableCaptionFonts: [String] = {
        captionFontCandidates.filter { NSFont(name: $0, size: 12) != nil }
    }()

    /// Sentinel meaning "the bold system font", which has no stable PostScript name
    /// to put in `NSFont(name:)`. Stored in the box like any other face name so the
    /// box model stays a plain `String?` and remains Codable.
    static let systemFontToken = "__system__"

    /// Resolve a face name to a font, falling back the same way at every call site.
    ///
    /// `name == nil` (or a name that isn't installed) walks the candidate list and
    /// ends at a bold system font, which is always present — so a meme still renders
    /// in a meme-ish face on a Mac with none of the candidates installed.
    static func captionFont(size: Double, name: String? = nil) -> NSFont {
        if name == systemFontToken {
            return NSFont.systemFont(ofSize: CGFloat(size), weight: .black)
        }
        if let name, let font = NSFont(name: name, size: CGFloat(size)) { return font }
        for candidate in captionFontCandidates {
            if let font = NSFont(name: candidate, size: CGFloat(size)) { return font }
        }
        return NSFont.systemFont(ofSize: CGFloat(size), weight: .black)
    }

    // MARK: - Export

    /// PNG data for an image, for both the save panel and the share sheet.
    static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
