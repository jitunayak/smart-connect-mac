// Generates macapp/AppIcon.iconset and AppIcon.icns using AppKit/SF Symbols.
// Run from the repository root: swift macapp/make-icon.swift
import AppKit
import Foundation

let outDir = URL(fileURLWithPath: "macapp/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let size = CGFloat(px)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.225
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.045, dy: size * 0.045),
                            xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.92, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.68, blue: 0.72, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -55)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.44, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right",
                            accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let scale = min(size * 0.62 / symbol.size.width, size * 0.62 / symbol.size.height)
        let drawSize = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let origin = NSPoint(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2)
        tinted.draw(in: NSRect(origin: origin, size: drawSize), from: .zero,
                    operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()

    // A subtle top highlight so the icon reads well in both light and dark menu bars.
    let shine = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.045, dy: size * 0.55),
                             xRadius: radius, yRadius: radius)
    NSColor.white.withAlphaComponent(0.10).setFill()
    shine.fill()

    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, px) in variants {
    guard let data = render(px) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent(name))
}
print("wrote \(outDir.path)")
