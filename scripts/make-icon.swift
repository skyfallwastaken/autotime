import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// Flat colours only: an indigo squircle, a white clock face and an amber wedge for the tracked time.
let background = NSColor(srgbRed: 0.31, green: 0.33, blue: 0.93, alpha: 1)
let face = NSColor.white
let wedge = NSColor(srgbRed: 1.0, green: 0.71, blue: 0.20, alpha: 1)
let hands = NSColor(srgbRed: 0.13, green: 0.14, blue: 0.30, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    background.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225).fill()

    let c = NSPoint(x: rect.midX, y: rect.midY)
    let r = rect.width * 0.3
    face.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()

    // 12 o'clock to 4 o'clock, drawn clockwise.
    let inner = r * 0.82
    let arc = NSBezierPath()
    arc.move(to: c)
    arc.appendArc(withCenter: c, radius: inner, startAngle: 90, endAngle: -30, clockwise: true)
    arc.close()
    wedge.setFill()
    arc.fill()

    hands.setStroke()
    func hand(_ degrees: CGFloat, _ length: CGFloat) {
        let a = degrees * .pi / 180
        let p = NSBezierPath()
        p.lineWidth = rect.width * 0.045
        p.lineCapStyle = .round
        p.move(to: c)
        p.line(to: NSPoint(x: c.x + cos(a) * length, y: c.y + sin(a) * length))
        p.stroke()
    }
    hand(90, r * 0.62)
    hand(-30, r * 0.45)
    hands.setFill()
    let dot = rect.width * 0.04
    NSBezierPath(ovalIn: NSRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
