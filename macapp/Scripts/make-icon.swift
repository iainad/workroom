#!/usr/bin/env swift
//
// make-icon.swift — generates the Workroom app icon.
//
// Draws a white "worktree" branch graph (a trunk node forking into two parallel
// branches of commit nodes) on an indigo→violet rounded-square tile, and exports
// every PNG the macOS AppIcon set needs. Pure CoreGraphics/AppKit, no assets.
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

let bgTop = rgb(0x7C, 0x66, 0xFF)     // indigo, top-left
let bgBottom = rgb(0x3C, 0x1E, 0x91)  // deep violet, bottom-right
let glyph = rgb(0xFF, 0xFF, 0xFF)     // white branch graph

// MARK: - Geometry (fractions of the rounded tile, top-left origin, y down)

struct P { let x: CGFloat; let y: CGFloat }

let T  = P(x: 0.500, y: 0.150)   // trunk / HEAD
let L1 = P(x: 0.305, y: 0.400)   // left branch
let L2 = P(x: 0.305, y: 0.625)
let R1 = P(x: 0.695, y: 0.400)   // right branch (one node deeper)
let R2 = P(x: 0.695, y: 0.625)
let R3 = P(x: 0.695, y: 0.850)

let nodes = [T, L1, L2, R1, R2, R3]

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

    // Flip to a top-left origin so the fractions above read naturally.
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
    ctx.restoreGState()

    // --- Branch graph glyph ---------------------------------------------------------
    func pt(_ p: P) -> CGPoint {
        CGPoint(x: tile.minX + p.x * tile.width, y: tile.minY + p.y * tile.height)
    }
    let edgeW = tile.width * 0.052
    let nodeR = tile.width * 0.063
    let forkMidY: CGFloat = 0.285

    ctx.saveGState()
    ctx.setStrokeColor(glyph)
    ctx.setFillColor(glyph)
    ctx.setLineWidth(edgeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Soft glyph shadow for a touch of depth (skipped at tiny sizes where it muddies).
    if pixels >= 128 {
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.006), blur: S * 0.012,
                      color: rgb(0x18, 0x0A, 0x40, 0.35))
    }

    // Fork edges: smooth S-curves leaving T vertically and arriving vertically.
    func fork(to child: P) {
        let p0 = pt(T), p3 = pt(child)
        let c1 = CGPoint(x: p0.x, y: tile.minY + forkMidY * tile.height)
        let c2 = CGPoint(x: p3.x, y: tile.minY + forkMidY * tile.height)
        ctx.move(to: p0)
        ctx.addCurve(to: p3, control1: c1, control2: c2)
        ctx.strokePath()
    }
    fork(to: L1)
    fork(to: R1)

    // Straight branch segments.
    func line(_ a: P, _ b: P) {
        ctx.move(to: pt(a)); ctx.addLine(to: pt(b)); ctx.strokePath()
    }
    line(L1, L2)
    line(R1, R2)
    line(R2, R3)

    // Nodes on top of the edges.
    for n in nodes {
        let c = pt(n)
        ctx.addEllipse(in: CGRect(x: c.x - nodeR, y: c.y - nodeR, width: nodeR * 2, height: nodeR * 2))
    }
    ctx.fillPath()
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
