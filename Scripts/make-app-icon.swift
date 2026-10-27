#!/usr/bin/env swift
//
// Draws the 1024x1024 app icon into the asset catalogue.
//
// The icon is generated rather than committed, so the repository keeps no binary assets and the
// artwork stays reproducible. Run it from the repository root before building:
//
//     swift Scripts/make-app-icon.swift
//
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let size: CGFloat = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("Could not create the icon canvas.\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// The blue the app's buttons, chips and accent use, deepening towards the bottom.
let bounds = NSRect(x: 0, y: 0, width: size, height: size)
let top = NSColor(srgbRed: 0.20, green: 0.52, blue: 1.00, alpha: 1)
let bottom = NSColor(srgbRed: 0.00, green: 0.26, blue: 0.72, alpha: 1)
NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)

// A soft white glow behind the box for a little depth.
let glow = NSBezierPath(ovalIn: NSRect(x: size * 0.12, y: size * 0.16, width: size * 0.76, height: size * 0.68))
NSColor(white: 1, alpha: 0.16).setFill()
glow.fill()

// The shipping box from SF Symbols, in white so it reads on the blue.
let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.4, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "ModShelf")?
    .withSymbolConfiguration(configuration) {
    let side = size * 0.46
    let rect = NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
    symbol.draw(in: rect)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode the icon.\n".utf8))
    exit(1)
}
try png.write(to: output)
print("Wrote \(output.path)")
