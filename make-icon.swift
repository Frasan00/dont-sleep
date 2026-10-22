import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let body = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let bg = NSGradient(colors: [NSColor(red: 0.20, green: 0.15, blue: 0.42, alpha: 1), NSColor(red: 0.06, green: 0.07, blue: 0.22, alpha: 1)])!
    NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225).addClip()
    bg.draw(in: body, angle: 90)

    // Same SF Symbol the menu bar shows while sleep is disabled
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .regular)
    let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let white = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let w = body.width * 0.58
    let h = w * symbol.size.height / symbol.size.width
    white.draw(in: NSRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
