#!/usr/bin/env swift
// Generates macOS 26 Liquid Glass-style app icon for ChatBot
// No external dependencies — pure Core Graphics.
import AppKit
import CoreGraphics

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "\(FileManager.default.currentDirectoryPath)/ChatBot/Assets.xcassets/AppIcon.appiconset"

// MARK: - Colors

let topR: CGFloat    = 0.29;  let topG: CGFloat    = 0.56;  let topB: CGFloat    = 1.00
let bottomR: CGFloat = 0.54;  let bottomG: CGFloat = 0.36;  let bottomB: CGFloat = 0.97

// MARK: - Render

func renderIcon(px: Int) -> NSBitmapImageRep {
    let s = CGFloat(px)

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // ── 1. Squircle clip ─────────────────────────────────────────────────
    let squircleRadius = s * 0.2237   // matches macOS icon grid
    let squirclePath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                              cornerWidth: squircleRadius, cornerHeight: squircleRadius, transform: nil)
    ctx.addPath(squirclePath)
    ctx.clip()

    // ── 2. Background gradient (blue → indigo-purple) ────────────────────
    let cs = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: topR,    green: topG,    blue: topB,    alpha: 1),
            CGColor(red: bottomR, green: bottomG, blue: bottomB, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bg,
        start: CGPoint(x: s * 0.5, y: s),    // top
        end:   CGPoint(x: s * 0.5, y: 0),    // bottom
        options: [])

    // ── 3. Chat bubble shadows (drawn before bubbles) ─────────────────────
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -(s * 0.025)),
                  blur: s * 0.05,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))

    // Main bubble (upper-left region)
    let b1 = CGRect(x: s * 0.120, y: s * 0.395, width: s * 0.580, height: s * 0.350)
    let b1r = s * 0.078
    let b1Path = CGPath(roundedRect: b1, cornerWidth: b1r, cornerHeight: b1r, transform: nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(b1Path)
    ctx.fillPath()

    // Reply bubble (lower-right region)
    let b2 = CGRect(x: s * 0.320, y: s * 0.230, width: s * 0.430, height: s * 0.270)
    let b2r = s * 0.065
    let b2Path = CGPath(roundedRect: b2, cornerWidth: b2r, cornerHeight: b2r, transform: nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.78))
    ctx.addPath(b2Path)
    ctx.fillPath()
    ctx.restoreGState()

    // ── 4. Bubble tails ───────────────────────────────────────────────────
    // Main bubble tail (bottom-left)
    ctx.saveGState()
    let tailMain = CGMutablePath()
    let t1x = b1.minX + b1r
    let t1y = b1.minY
    tailMain.move(to: CGPoint(x: t1x, y: t1y))
    tailMain.addLine(to: CGPoint(x: t1x - s * 0.055, y: t1y - s * 0.062))
    tailMain.addLine(to: CGPoint(x: t1x + s * 0.075, y: t1y))
    tailMain.closeSubpath()
    ctx.setShadow(offset: CGSize(width: 0, height: -(s * 0.018)),
                  blur: s * 0.03,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(tailMain)
    ctx.fillPath()

    // Reply bubble tail (bottom-right)
    let tailReply = CGMutablePath()
    let t2x = b2.maxX - b2r
    let t2y = b2.minY
    tailReply.move(to: CGPoint(x: t2x, y: t2y))
    tailReply.addLine(to: CGPoint(x: t2x + s * 0.052, y: t2y - s * 0.055))
    tailReply.addLine(to: CGPoint(x: t2x - s * 0.068, y: t2y))
    tailReply.closeSubpath()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.78))
    ctx.addPath(tailReply)
    ctx.fillPath()
    ctx.restoreGState()

    // ── 5. Glass specular overlay (top 40% white-to-clear gradient) ───────
    let glassGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),   // mid (y=0.58s in AppKit)
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.26),  // top  (y=s)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(glassGrad,
        start: CGPoint(x: s * 0.5, y: s * 0.58),
        end:   CGPoint(x: s * 0.5, y: s),
        options: [])

    // ── 6. Specular pill (bright cap at very top) ─────────────────────────
    let pillW: CGFloat = s * 0.46
    let pillH: CGFloat = s * 0.055
    let pillX: CGFloat = (s - pillW) / 2
    let pillY: CGFloat = s * 0.892   // near top in AppKit coords
    let pillRadius     = pillH / 2
    let pillPath = CGPath(roundedRect: CGRect(x: pillX, y: pillY, width: pillW, height: pillH),
                          cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.50))
    ctx.addPath(pillPath)
    ctx.fillPath()

    // ── 7. Subtle inner rim ───────────────────────────────────────────────
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.setLineWidth(s * 0.004)
    ctx.addPath(squirclePath)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Output

let sizes = [16, 32, 64, 128, 256, 512, 1024]

try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for px in sizes {
    let rep  = renderIcon(px: px)
    let data = rep.representation(using: .png, properties: [:])!
    let path = "\(outputDir)/icon_\(px).png"
    try! data.write(to: URL(fileURLWithPath: path))
    print("✓ \(px)×\(px)  →  \(path)")
}
print("\nDone — \(sizes.count) PNGs written to:\n\(outputDir)")
