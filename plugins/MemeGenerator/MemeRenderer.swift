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
/// All the *decisions* (uppercasing, line breaking, shrink-to-fit) live in the pure,
/// tested `MemeCaptionLayout`; this type owns only the drawing and the font metrics
/// it feeds back into that layout.
@MainActor
enum MemeRenderer {

    /// Compose a meme: template image + top/bottom captions.
    ///
    /// Returns a new image at the template's pixel dimensions, so exports are
    /// full-resolution regardless of how the preview is scaled.
    static func render(
        template: NSImage,
        topText: String,
        bottomText: String
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

        let inset = width * MemeCaptionLayout.horizontalInsetShare
        let maxTextWidth = width - inset * 2
        let maxBlockHeight = height * MemeCaptionLayout.captionHeightShare

        draw(
            caption: topText, position: .top,
            imageWidth: width, imageHeight: height,
            maxTextWidth: maxTextWidth, maxBlockHeight: maxBlockHeight)
        draw(
            caption: bottomText, position: .bottom,
            imageWidth: width, imageHeight: height,
            maxTextWidth: maxTextWidth, maxBlockHeight: maxBlockHeight)

        return output
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

    private static func draw(
        caption: String,
        position: MemeCaptionLayout.Position,
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        maxTextWidth: CGFloat,
        maxBlockHeight: CGFloat
    ) {
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Shrink-to-fit using REAL font metrics: the pure layout does the deciding,
        // we supply the measurements.
        let fit = MemeCaptionLayout.fit(
            caption: caption,
            maxWidth: Double(maxTextWidth),
            maxHeight: Double(maxBlockHeight),
            maxFontSize: MemeCaptionLayout.idealFontSize(imageHeight: Double(imageHeight)),
            minFontSize: MemeCaptionLayout.minimumFontSize(imageHeight: Double(imageHeight)),
            measure: { text, size in
                Double(text.size(withAttributes: [.font: captionFont(size: size)]).width)
            },
            lineHeight: { size in size * 1.15 })

        guard !fit.lines.isEmpty else { return }

        let font = captionFont(size: fit.fontSize)
        let lineHeight = CGFloat(fit.fontSize) * 1.15
        let blockHeight = lineHeight * CGFloat(fit.lines.count)
        let margin = imageHeight * 0.02

        // AppKit's image coordinate space is bottom-left origin.
        let blockTopY: CGFloat
        switch position {
        case .top:    blockTopY = imageHeight - margin
        case .bottom: blockTopY = blockHeight + margin
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .center

        // The classic look is a black OUTLINE around white glyphs. A negative
        // `.strokeWidth` tells AppKit to stroke AND fill (a positive value strokes
        // only, which would render hollow letters).
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -CGFloat(fit.fontSize) * 0.14,
            .paragraphStyle: style,
        ]

        for (index, line) in fit.lines.enumerated() {
            let y = blockTopY - lineHeight * CGFloat(index + 1)
            let rect = NSRect(
                x: 0, y: y + (lineHeight - font.ascender + font.descender) / 2,
                width: imageWidth, height: lineHeight)
            line.draw(in: rect, withAttributes: attributes)
        }
    }

    /// The heaviest condensed face available. Impact — the canonical meme font — does
    /// not ship with macOS, so this walks a preference list and ends at a bold system
    /// font, which is always present.
    static func captionFont(size: Double) -> NSFont {
        let candidates = ["Impact", "Haettenschweiler", "Arial Black", "HelveticaNeue-CondensedBlack"]
        for name in candidates {
            if let font = NSFont(name: name, size: CGFloat(size)) { return font }
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
