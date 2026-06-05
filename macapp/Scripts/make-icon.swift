#!/usr/bin/env swift
//
// make-icon.swift — generates the Workroom app icon.
//
// Draws three cascading rounded "room" cards (a workroom = an isolated copy) on a
// teal→blue rounded-square tile, with a terminal prompt — a blue chevron and a pink
// block cursor — on the front card. Exports every PNG the macOS AppIcon set needs.
// Pure CoreGraphics/AppKit, no assets.
//
// Usage:
//   swift Scripts/make-icon.swift [output-dir]
// Defaults to WorkroomApp/Assets.xcassets/AppIcon.appiconset relative to macapp/.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let bgTop = rgb(0x18, 0xE0, 0xC8)     // teal, top-left
let bgBottom = rgb(0x2E, 0x7D, 0xFF)  // blue, bottom-right
let cardBack = rgb(0xFF, 0xD2, 0x3F)  // yellow (deepest card)
let cardMid = rgb(0xFF, 0x6F, 0xB5)   // pink (middle card)
let cardFront = rgb(0xFF, 0xFF, 0xFF) // white (front card)
let chevron = rgb(0x2E, 0x7D, 0xFF)   // blue prompt chevron
let cursor = rgb(0xFF, 0x6F, 0xB5)    // pink block cursor

// MARK: - Geometry (fractions of the rounded tile)

let cardW: CGFloat = 0.66    // card edge as a fraction of the tile width
let offset: CGFloat = 0.055  // each card's diagonal step from the tile centre

// MARK: - Render

func render(_ pixels: Int, to url: URL) {
    let S = CGFloat(pixels)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext") }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip to a top-left origin so the fractions above read naturally (y grows downward).
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)

    // --- Tile + soft contact shadow -------------------------------------------------
    let margin = S * 0.0975
    let tile = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let radius = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    // In the flipped CTM, a negative height pushes the shadow visually downward.
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
                  color: rgb(0x10, 0x06, 0x33, 0.40))
    ctx.addPath(tilePath)
    ctx.setFillColor(bgBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // --- Background gradient (clipped to the tile) ----------------------------------
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [bgTop, bgBottom] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: tile.minX, y: tile.minY),
                           end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])

    // Subtle top sheen for a glassy feel.
    let sheen = CGGradient(colorsSpace: cs,
                           colors: [rgb(0xFF, 0xFF, 0xFF, 0.16), rgb(0xFF, 0xFF, 0xFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: tile.minX, y: tile.minY),
                           end: CGPoint(x: tile.minX, y: tile.minY + tile.height * 0.55), options: [])

    // --- Cascading "room" cards -----------------------------------------------------
    func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + fx * tile.width, y: tile.minY + fy * tile.height)
    }
    let w = tile.width * cardW
    let cardRadius = w * 0.235
    let cardShadow = rgb(0x07, 0x2A, 0x55, 0.45)

    func card(center: CGPoint, fill: CGColor) {
        let r = CGRect(x: center.x - w / 2, y: center.y - w / 2, width: w, height: w)
        let path = CGPath(roundedRect: r, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.05), blur: w * 0.11, color: cardShadow)
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }
    card(center: pt(0.5 + offset, 0.5 - offset), fill: cardBack)
    card(center: pt(0.5, 0.5), fill: cardMid)
    let front = pt(0.5 - offset, 0.5 + offset)
    card(center: front, fill: cardFront)

    // --- Terminal prompt on the front card ------------------------------------------
    func fp(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: front.x + dx * w, y: front.y + dy * w)
    }
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // Blue chevron ">".
    ctx.setStrokeColor(chevron)
    ctx.setLineWidth(0.085 * w)
    ctx.move(to: fp(-0.26, -0.17))
    ctx.addLine(to: fp(-0.05, 0.0))
    ctx.addLine(to: fp(-0.26, 0.17))
    ctx.strokePath()
    // Pink block cursor.
    let cc = fp(0.16, 0.02)
    let cw = 0.17 * w
    let ch = 0.30 * w
    let cursorRect = CGRect(x: cc.x - cw / 2, y: cc.y - ch / 2, width: cw, height: ch)
    ctx.addPath(CGPath(roundedRect: cursorRect, cornerWidth: 0.035 * w, cornerHeight: 0.035 * w, transform: nil))
    ctx.setFillColor(cursor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState()

    // --- Write PNG ------------------------------------------------------------------
    guard let image = ctx.makeImage() else { fatalError("makeImage") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! png.write(to: url)
    print("  \(url.lastPathComponent)  (\(pixels)px)")
}

// MARK: - Drive

let defaultDir = "WorkroomApp/Assets.xcassets/AppIcon.appiconset"
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultDir
let dir = URL(fileURLWithPath: outDir, isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

// filename -> pixel size, covering the full macOS AppIcon set.
let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),     ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),     ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),  ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),  ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),  ("icon_512x512@2x.png", 1024),
]

print("Rendering AppIcon set → \(dir.path)")
for (name, px) in outputs {
    render(px, to: dir.appendingPathComponent(name))
}
print("Done.")
