// Draws the DMG window background at 1x and 2x: swift scripts/make-dmg-background.swift <out-dir>
// Layout must match scripts/dmg-settings.py (640x400 window, icons centred at (170, 215) and (470, 215)).
import AppKit

let out = CommandLine.arguments[1]
let size = NSSize(width: 640, height: 400)
let blue = NSColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1)
let purple = NSColor(red: 0.45, green: 0.25, blue: 0.95, alpha: 1)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(origin: .zero, size: size)

    // Soft base with two brand-coloured glows.
    NSGradient(colors: [NSColor(red: 0.97, green: 0.97, blue: 1.0, alpha: 1), NSColor(red: 0.92, green: 0.93, blue: 0.99, alpha: 1)])!
        .draw(in: bounds, angle: -90)
    for (center, color, radius) in [(NSPoint(x: 90, y: 360), blue, 300.0), (NSPoint(x: 600, y: 40), purple, 320.0)] {
        NSGradient(colors: [color.withAlphaComponent(0.16), color.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }

    // Faint activity bars along the bottom, echoing the app icon.
    let bars: [CGFloat] = [18, 34, 26, 48, 30, 58, 40, 22, 52, 36, 28, 44, 20, 38, 30, 54, 24, 42, 32, 16]
    let barWidth: CGFloat = 14, gap: CGFloat = 18
    let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
    for (i, h) in bars.enumerated() {
        let x = (size.width - total) / 2 + CGFloat(i) * (barWidth + gap)
        let t = CGFloat(i) / CGFloat(bars.count - 1)
        (blue.blended(withFraction: t, of: purple) ?? blue).withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: -6, width: barWidth, height: h + 6), xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }

    // Title and instruction.
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    NSAttributedString(string: "Autotime", attributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .bold),
        .foregroundColor: NSColor(red: 0.13, green: 0.14, blue: 0.22, alpha: 1),
        .paragraphStyle: center,
    ]).draw(in: NSRect(x: 0, y: 330, width: size.width, height: 36))
    NSAttributedString(string: "Drag Autotime into Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(red: 0.36, green: 0.38, blue: 0.48, alpha: 1),
        .paragraphStyle: center,
    ]).draw(in: NSRect(x: 0, y: 308, width: size.width, height: 20))

    // Arrow from the app to Applications; the head is aimed along the curve's end tangent so the two meet cleanly.
    let start = NSPoint(x: 262, y: 196), end = NSPoint(x: 370, y: 196)
    let control1 = NSPoint(x: 296, y: 222), control2 = NSPoint(x: 336, y: 222)
    let path = CGMutablePath()
    path.move(to: start)
    path.addCurve(to: end, control1: control1, control2: control2)
    let back = atan2(control2.y - end.y, control2.x - end.x)
    for spread in [-0.6, 0.6] {
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 14 * cos(back + spread), y: end.y + 14 * sin(back + spread)))
    }
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.addPath(path.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10))
    context.clip()
    NSGradient(colors: [blue, purple])!.draw(in: NSRect(x: 250, y: 176, width: 130, height: 56), angle: 0)
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
try! render(scale: 1).write(to: URL(fileURLWithPath: "\(out)/background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: "\(out)/background@2x.png"))
