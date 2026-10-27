#!/usr/bin/env swift
//
// Prepares the app icon in the asset catalogue.
//
// A committed icon is kept and only made valid: iOS wants exactly 1024x1024 with no alpha channel, so
// the artwork is scaled to fit and placed on an opaque square. If there is no icon yet, a placeholder
// is drawn instead. Run it from the repository root before building:
//
//     swift Scripts/make-app-icon.swift
//
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let canvas: CGFloat = 1024
try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

/// Writes a 1024x1024 PNG without an alpha channel, which is what an app icon has to be.
func writeOpaquePNG(_ draw: (CGContext) -> Void) {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        FileHandle.standardError.write(Data("Could not create the icon canvas.\n".utf8))
        exit(1)
    }
    draw(ctx)
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("Could not encode the icon.\n".utf8))
        exit(1)
    }
    do { try png.write(to: output) } catch { exit(1) }
}

// An icon already exists: scale it onto an opaque square instead of replacing the artwork.
if let data = try? Data(contentsOf: output),
   let source = CGImageSourceCreateWithData(data as CFData, nil),
   let art = CGImageSourceCreateImageAtIndex(source, 0, nil) {
    if art.width == Int(canvas), art.height == Int(canvas), art.alphaInfo == .none || art.alphaInfo == .noneSkipLast {
        print("AppIcon.png is already 1024x1024 and opaque; leaving it alone.")
        exit(0)
    }
    writeOpaquePNG { ctx in
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        let ratio = min(canvas / CGFloat(art.width), canvas / CGFloat(art.height))
        let width = CGFloat(art.width) * ratio
        let height = CGFloat(art.height) * ratio
        ctx.draw(art, in: CGRect(x: (canvas - width) / 2, y: (canvas - height) / 2, width: width, height: height))
    }
    print("Fitted AppIcon.png onto a 1024x1024 opaque square.")
    exit(0)
}

// No icon yet: draw a placeholder so builds still get an icon.
let size = canvas
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let bounds = NSRect(x: 0, y: 0, width: size, height: size)
let top = NSColor(srgbRed: 0.20, green: 0.52, blue: 1.00, alpha: 1)
let bottom = NSColor(srgbRed: 0.00, green: 0.26, blue: 0.72, alpha: 1)
NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)

let glow = NSBezierPath(ovalIn: NSRect(x: size * 0.12, y: size * 0.16, width: size * 0.76, height: size * 0.68))
NSColor(white: 1, alpha: 0.16).setFill()
glow.fill()

let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.4, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "ModShelf")?
    .withSymbolConfiguration(configuration) {
    let side = size * 0.46
    symbol.draw(in: NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side))
}

image.unlockFocus()

writeOpaquePNG { ctx in
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    }
}
print("Wrote a placeholder \(output.path)")
