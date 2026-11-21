#!/usr/bin/env swift
// Draws the RMount icon (a drive labeled "RM") and writes it as a PNG.
// Usage: scripts/make-icon.swift <size> <out.png> [menubar|menubar-uploading]
// By default it draws the app icon (white drive on an indigo tile). With "menubar" it draws the
// black-on-transparent template glyph. "menubar-uploading" replaces the letters with an up arrow.
// scripts/make-icon.sh builds the .icns, docs/icon.png and the menu bar images from it.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4, let size = Int(args[1]), size > 0 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <size> <out.png> [menubar|menubar-uploading]\n".utf8))
    exit(2)
}
let uploading = args.count == 4 && args[3] == "menubar-uploading"
let menubar = args.count == 4 && (args[3] == "menubar" || uploading)

let indigo = NSColor(srgbRed: 0x5B / 255, green: 0x4B / 255, blue: 0xDB / 255, alpha: 1)
let white = NSColor.white
let black = NSColor.black

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
), let gc = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gc
let ctx = gc.cgContext
let canvas = CGFloat(size)

// Design space is 180x180 with y pointing down.
if menubar {
    // The drive glyph spans x 34...146, y 40...141; fit it into the square with a small margin.
    let scale = canvas * 0.92 / 112
    ctx.translateBy(x: (canvas - 112 * scale) / 2 - 34 * scale, y: canvas - (canvas - 101 * scale) / 2 + 40 * scale)
    ctx.scaleBy(x: scale, y: -scale)
} else {
    // macOS app icons keep the tile at 80% of the canvas, centred, to match the system's icon grid.
    let tile = canvas * 0.8
    ctx.translateBy(x: (canvas - tile) / 2, y: canvas - (canvas - tile) / 2)
    ctx.scaleBy(x: tile / 180, y: -tile / 180)
}

func fill(_ color: NSColor, _ path: CGPath) {
    ctx.setFillColor(color.cgColor)
    ctx.addPath(path)
    ctx.fillPath()
}

func stroke(_ color: NSColor, width: CGFloat, _ path: CGPath) {
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()
}

let drive = CGPath(roundedRect: CGRect(x: 34, y: 40, width: 112, height: 60), cornerWidth: 18, cornerHeight: 18, transform: nil)
let dot = CGPath(ellipseIn: CGRect(x: 81, y: 123, width: 18, height: 18), transform: nil)

// "R": stem, bowl, leg.
let letterR = CGMutablePath()
letterR.move(to: CGPoint(x: 56, y: 56)); letterR.addLine(to: CGPoint(x: 56, y: 84))
letterR.move(to: CGPoint(x: 56, y: 56)); letterR.addLine(to: CGPoint(x: 68, y: 56))
let k: CGFloat = 0.5523 * 7
letterR.addCurve(to: CGPoint(x: 75, y: 63), control1: CGPoint(x: 68 + k, y: 56), control2: CGPoint(x: 75, y: 63 - k))
letterR.addCurve(to: CGPoint(x: 68, y: 70), control1: CGPoint(x: 75, y: 63 + k), control2: CGPoint(x: 68 + k, y: 70))
letterR.addLine(to: CGPoint(x: 56, y: 70))
letterR.move(to: CGPoint(x: 65, y: 70)); letterR.addLine(to: CGPoint(x: 74, y: 84))

// "M".
let letterM = CGMutablePath()
letterM.move(to: CGPoint(x: 88, y: 84)); letterM.addLine(to: CGPoint(x: 88, y: 56))
letterM.addLine(to: CGPoint(x: 99, y: 70)); letterM.addLine(to: CGPoint(x: 110, y: 56)); letterM.addLine(to: CGPoint(x: 110, y: 84))

// Network stem and base under the drive.
let stem = CGMutablePath()
stem.move(to: CGPoint(x: 90, y: 100)); stem.addLine(to: CGPoint(x: 90, y: 132))
stem.move(to: CGPoint(x: 52, y: 132)); stem.addLine(to: CGPoint(x: 128, y: 132))

if menubar {
    // Template image: the drive is solid black and the letters are cut out of it.
    fill(black, drive)
    ctx.setBlendMode(.clear)
    if uploading {
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 90, y: 85)); arrow.addLine(to: CGPoint(x: 90, y: 55))
        arrow.move(to: CGPoint(x: 76, y: 69)); arrow.addLine(to: CGPoint(x: 90, y: 55))
        arrow.addLine(to: CGPoint(x: 104, y: 69))
        stroke(black, width: 9, arrow)
    } else {
        stroke(black, width: 9, letterR)
        stroke(black, width: 9, letterM)
    }
    ctx.setBlendMode(.normal)
    stroke(black, width: 9, stem)
    fill(black, dot)
} else {
    fill(indigo, CGPath(roundedRect: CGRect(x: 0, y: 0, width: 180, height: 180), cornerWidth: 40, cornerHeight: 40, transform: nil))
    fill(white, drive)
    stroke(indigo, width: 6, letterR)
    stroke(indigo, width: 6, letterM)
    stroke(white, width: 8, stem)
    fill(white, dot)
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
