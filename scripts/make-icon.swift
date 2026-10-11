import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1), NSColor(red: 0.45, green: 0.25, blue: 0.95, alpha: 1)])!.draw(in: shape, angle: -60)
    let bars: [(CGFloat, CGFloat, NSColor)] = [(0.30, 0.55, .systemGreen), (0.45, 0.35, .systemOrange), (0.60, 0.65, .systemTeal), (0.75, 0.25, .systemPink)]
    for (x, h, c) in bars {
        let w = rect.width * 0.1
        let r = NSRect(x: rect.minX + rect.width * x - w / 2, y: rect.minY + rect.height * 0.18, width: w, height: rect.height * h)
        c.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
    }
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.3, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let clock = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let cs = clock.size
        clock.draw(in: NSRect(x: rect.maxX - cs.width - rect.width * 0.08, y: rect.maxY - cs.height - rect.height * 0.08, width: cs.width, height: cs.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
