#!/usr/bin/env swift
// Renders the OpenWhisp app icon (AppIcon.iconset -> .icns) entirely with
// Core Graphics — no external rasterizer needed. "Quiet Glass" look: a near-black
// rounded-square tile with a minimal monochrome waveform glyph matching the
// SF Symbols `waveform`-style bars used in the menu bar.
//
// Usage: swift scripts/make-icon.swift <output-iconset-dir>
//   then: iconutil -c icns <output-iconset-dir> -o <path>/AppIcon.icns

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Waveform geometry (shared definition so the tray glyph can match)

/// Relative bar heights (0..1), symmetric, tallest in the middle — the same
/// silhouette as the menu-bar `waveform` symbol.
let barHeights: [CGFloat] = [0.34, 0.56, 0.82, 1.0, 0.82, 0.56, 0.34]

/// Draw the waveform centered in `rect`, bars in `color`.
func drawWaveform(in ctx: CGContext, rect: CGRect, color: CGColor) {
    let count = barHeights.count
    // Bar width vs gap ratio tuned to read cleanly even at 16px.
    let gapRatio: CGFloat = 0.62
    let unit = rect.width / (CGFloat(count) + CGFloat(count - 1) * gapRatio)
    let barW = unit
    let gap = unit * gapRatio
    let midY = rect.midY

    ctx.setFillColor(color)
    var x = rect.minX
    for h in barHeights {
        let barH = max(barW, rect.height * h)
        let bar = CGRect(x: x, y: midY - barH / 2, width: barW, height: barH)
        let radius = barW / 2
        let path = CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        x += barW + gap
    }
}

// MARK: - Icon tile

func renderIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // macOS icon grid: the rounded tile sits in ~80% of the canvas with margin.
    let margin = s * 0.10
    let tile = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let corner = tile.width * 0.225   // Apple "squircle"-ish corner radius

    // --- Tile background: near-black graphite vertical gradient ("Quiet Glass") ---
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let grad = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0),  // top: lifted graphite
            CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0)   // bottom: near-black
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(grad, start: CGPoint(x: tile.midX, y: tile.maxY),
                           end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    // Subtle top sheen for a glassy feel.
    let sheen = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.06),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: tile.midX, y: tile.maxY),
                           end: CGPoint(x: tile.midX, y: tile.midY), options: [])
    ctx.restoreGState()

    // --- Hairline edge stroke ---
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokePath()
    ctx.restoreGState()

    // --- Waveform glyph: bright off-white, centered, ~46% of tile width ---
    let wfW = tile.width * 0.46
    let wfH = tile.height * 0.40
    let wfRect = CGRect(x: tile.midX - wfW / 2, y: tile.midY - wfH / 2, width: wfW, height: wfH)
    // Soft glow so it pops on the dark tile (skip at tiny sizes to stay crisp).
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 0.02,
                      color: CGColor(red: 0.86, green: 0.92, blue: 1.0, alpha: 0.5))
        drawWaveform(in: ctx, rect: wfRect, color: CGColor(red: 0.96, green: 0.97, blue: 1.0, alpha: 1.0))
        ctx.restoreGState()
    } else {
        drawWaveform(in: ctx, rect: wfRect, color: CGColor(red: 0.96, green: 0.97, blue: 1.0, alpha: 1.0))
    }

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Menu-bar template glyph
//
// A black-on-transparent waveform using the SAME bar definition as the app icon,
// so the tray icon and the app icon are visually identical. Marked as an NSImage
// template at runtime, so macOS tints it for light/dark menu bars.

func renderTrayGlyph(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    // Waveform fills most of the height with a little vertical padding.
    let padX = s * 0.06
    let padY = s * 0.22
    let rect = CGRect(x: padX, y: padY, width: s - padX * 2, height: s - padY * 2)
    drawWaveform(in: ctx, rect: rect, color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    return ctx.makeImage()
}

// MARK: - Emit the full .iconset

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// (filename, pixel size) — the standard macOS iconset matrix.
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, px) in entries {
    guard let img = renderIcon(size: px) else {
        FileHandle.standardError.write("failed to render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    writePNG(img, to: outDir.appendingPathComponent(name))
    print("rendered \(name) (\(px)px)")
}

// Menu-bar template glyph (18pt @1x/@2x/@3x) written next to the iconset, so the
// build can copy it into the app Resources. Marked template at runtime.
let trayDir = outDir.deletingLastPathComponent()
for (name, px) in [("MenuBarIcon.png", 18), ("MenuBarIcon@2x.png", 36), ("MenuBarIcon@3x.png", 54)] {
    if let g = renderTrayGlyph(size: px) {
        writePNG(g, to: trayDir.appendingPathComponent(name))
        print("rendered \(name) (\(px)px)")
    }
}
print("done -> \(outDir.path)")
