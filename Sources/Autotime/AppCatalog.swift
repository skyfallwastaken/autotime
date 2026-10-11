import AppKit
import SwiftUI

final class AppCatalog {
    static let shared = AppCatalog()

    private var icons: [String: NSImage] = [:]
    private var colors: [String: Color] = [:]
    private var categories: [String: String] = [:]
    private var fileIcons: [String: NSImage] = [:]

    private static let categoryNames: [String: String] = [
        "public.app-category.business": "Business",
        "public.app-category.developer-tools": "Developer Tools",
        "public.app-category.education": "Education",
        "public.app-category.entertainment": "Entertainment",
        "public.app-category.finance": "Finance",
        "public.app-category.games": "Games",
        "public.app-category.graphics-design": "Graphics & Design",
        "public.app-category.healthcare-fitness": "Health & Fitness",
        "public.app-category.lifestyle": "Lifestyle",
        "public.app-category.medical": "Medical",
        "public.app-category.music": "Music",
        "public.app-category.news": "News",
        "public.app-category.photography": "Photography",
        "public.app-category.productivity": "Productivity",
        "public.app-category.reference": "Reference",
        "public.app-category.social-networking": "Social Networking",
        "public.app-category.sports": "Sports",
        "public.app-category.travel": "Travel",
        "public.app-category.utilities": "Utilities",
        "public.app-category.video": "Video",
        "public.app-category.weather": "Weather",
    ]

    private static let knownCategories: [String: String] = [
        "com.tinyspeck.slackmacgap": "Communication",
        "app.jer.taut": "Communication",
        "com.hnc.Discord": "Communication",
        "com.apple.mail": "Communication",
        "com.apple.MobileSMS": "Communication",
        "net.whatsapp.WhatsApp": "Communication",
        "us.zoom.xos": "Communication",
        "com.microsoft.teams2": "Communication",
        "com.apple.Safari": "Web Browsing",
        "com.google.Chrome": "Web Browsing",
        "net.imput.helium": "Web Browsing",
        "company.thebrowser.Browser": "Web Browsing",
        "org.mozilla.firefox": "Web Browsing",
        "com.brave.Browser": "Web Browsing",
        "com.mitchellh.ghostty": "Developer Tools",
        "com.apple.Terminal": "Developer Tools",
        "com.googlecode.iterm2": "Developer Tools",
        "com.apple.dt.Xcode": "Developer Tools",
        "com.microsoft.VSCode": "Developer Tools",
        "com.todesktop.230313mzl4w4u92": "Developer Tools",
        "com.apple.finder": "Utilities",
    ]

    func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func icon(for bundleID: String) -> NSImage {
        if let i = icons[bundleID] { return i }
        let image: NSImage
        if let url = appURL(bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        image.size = NSSize(width: 32, height: 32)
        icons[bundleID] = image
        return image
    }

    func fileIcon(for path: String) -> NSImage {
        if let i = fileIcons[path] { return i }
        let image: NSImage
        if FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = NSWorkspace.shared.icon(for: path.hasSuffix("/") ? .folder : .data)
        }
        image.size = NSSize(width: 32, height: 32)
        fileIcons[path] = image
        return image
    }

    func category(for bundleID: String) -> String {
        if let c = categories[bundleID] { return c }
        var name = Self.knownCategories[bundleID]
        if name == nil, let url = appURL(bundleID), let bundle = Bundle(url: url),
           let type = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String {
            name = Self.categoryNames[type]
        }
        if name == nil, bundleID.contains(".app.") {
            name = "Web Apps"
        }
        let result = name ?? "Other"
        categories[bundleID] = result
        return result
    }

    func color(for bundleID: String) -> Color {
        if let c = colors[bundleID] { return c }
        let c = Color(nsColor: dominantColor(icon(for: bundleID)) ?? hashedColor(bundleID))
        colors[bundleID] = c
        return c
    }

    func color(forCategory name: String) -> Color {
        Color(nsColor: hashedColor(name))
    }

    private func hashedColor(_ s: String) -> NSColor {
        var hash: UInt64 = 5381
        for b in s.utf8 { hash = (hash &* 33) &+ UInt64(b) }
        return NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.55, brightness: 0.85, alpha: 1)
    }

    private func dominantColor(_ image: NSImage) -> NSColor? {
        let size = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        var buckets: [Int: (count: Double, r: Double, g: Double, b: Double)] = [:]
        for x in 0..<size {
            for y in 0..<size {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                let rgb = c.usingColorSpace(.deviceRGB) ?? c
                let sat = rgb.saturationComponent
                let bri = rgb.brightnessComponent
                guard sat > 0.25, bri > 0.25 else { continue }
                let bucket = Int(rgb.hueComponent * 12) % 12
                let weight = sat * bri
                let e = buckets[bucket] ?? (0, 0, 0, 0)
                buckets[bucket] = (e.count + weight, e.r + rgb.redComponent * weight, e.g + rgb.greenComponent * weight, e.b + rgb.blueComponent * weight)
            }
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }), best.count > 3 else { return nil }
        let color = NSColor(red: best.r / best.count, green: best.g / best.count, blue: best.b / best.count, alpha: 1)
        return NSColor(hue: color.hueComponent, saturation: min(1, max(0.45, color.saturationComponent)), brightness: max(0.7, color.brightnessComponent), alpha: 1)
    }
}
