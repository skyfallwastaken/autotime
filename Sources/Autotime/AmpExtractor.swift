import AppKit
import SwiftUI

/// Amp's desktop app is a web view onto ampcode.com. The open thread comes from the web view's URL; its title from the
/// sidebar link for it, or from the thread list SvelteKit embeds in pages WebKit has cached; its project from that list,
/// or from Amp's runner files, which record each thread's working directory.
final class AmpExtractor {
    static let bundleID = "com.ampcode.amp.macos"
    static let puck = "Puck"

    private var liveTitles: [String: (title: String?, checked: Date)] = [:]

    func info(pid: pid_t, area: AXElement) -> ExtractedInfo? {
        guard let url = area.url(kAXURLAttribute), url.host?.hasSuffix("ampcode.com") == true else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let id = parts.last, id.hasPrefix("T-"), parts.count >= 2, ["threads", "puck-window"].contains(parts[parts.count - 2]) else {
            // The floating Puck window, when it isn't showing a thread.
            return ExtractedInfo(title: "", path: parts.first == "puck-window" ? Self.puck : "")
        }
        let catalog = AmpCatalog.shared
        catalog.refresh(force: catalog.thread(id) == nil)
        let known = catalog.thread(id)
        let title = liveTitle(id, area: area) ?? known?.title ?? ""
        guard let project = known?.project ?? Self.runnerProject(id) else { return ExtractedInfo(title: "", path: title) }
        let label = title.isEmpty ? "Untitled Thread" : title
        catalog.remember(id, project: project, title: label)
        return ExtractedInfo(title: "", path: project + Extractor.separator + label)
    }

    /// The sidebar lists recent threads as links to /threads/<id>; the first text inside is the title.
    private func liveTitle(_ id: String, area: AXElement) -> String? {
        if let cached = liveTitles[id], Date().timeIntervalSince(cached.checked) < 15 { return cached.title }
        let link = area.findFirst(maxNodes: 1500, maxDepth: 40) {
            $0.role == "AXLink" && $0.url(kAXURLAttribute)?.lastPathComponent == id
        }
        let title = link?.findFirst(maxNodes: 40, maxDepth: 6) {
            $0.role == kAXStaticTextRole && !($0.string(kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }?.string(kAXValueAttribute)
        liveTitles[id] = (title, Date())
        return title
    }

    /// ~/.local/share/amp/runner/*.json maps the threads each local runner serves to its working directory.
    static func runnerProject(_ id: String) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/amp/runner")
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["servedThreadIds"] as? [String])?.contains(id) == true,
                  let dir = json["workingDirectory"] as? String, dir != NSHomeDirectory() else { continue }
            return URL(fileURLWithPath: dir).lastPathComponent
        }
        return nil
    }
}

/// The identicon Amp draws for a thread: a few stroked polylines on a 24×24 grid in the thread's colour.
/// Orbs, cubes and squircles mark cloud (Orb), local runner and macOS Orb executors.
struct AmpThreadIcon {
    struct Stroke {
        var points: [CGPoint]
        var opacity: Double
        var width: CGFloat
    }

    var strokes: [Stroke]
    var light: Color
    var dark: Color
}

/// What Amp's cached pages say about each thread and project, shared by the extractor and the activity list.
final class AmpCatalog {
    static let shared = AmpCatalog()

    struct Thread {
        var title: String?
        var project: String?
        var icon: AmpThreadIcon?
    }

    private let lock = NSLock()
    private var threads: [String: Thread] = [:]
    private var labels: [String: String] = [:]
    private var projectIcons: [String: URL] = [:]
    private var scanned: [URL: Date] = [:]
    private var lastScan = Date.distantPast

    func thread(_ id: String) -> Thread? {
        lock.lock(); defer { lock.unlock() }
        return threads[id]
    }

    /// The thread recorded as `project ▸ title`, for drawing its icon in the activity list.
    func icon(project: String, title: String) -> AmpThreadIcon? {
        refresh(force: false)
        lock.lock(); defer { lock.unlock() }
        return labels[project + "\u{1}" + title].flatMap { threads[$0]?.icon }
    }

    func projectIcon(_ project: String) -> URL? {
        refresh(force: false)
        lock.lock(); defer { lock.unlock() }
        return projectIcons[project]
    }

    func remember(_ id: String, project: String, title: String) {
        lock.lock(); defer { lock.unlock() }
        labels[project + "\u{1}" + title] = id
    }

    // MARK: WebKit cache

    private static let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/\(AmpExtractor.bundleID)/WebKit/NetworkCache")

    /// Re-reads cached pages that changed since the last look, at most once a minute (every 15s when `force`).
    func refresh(force: Bool) {
        lock.lock()
        guard Date().timeIntervalSince(lastScan) > (force ? 15 : 60) else { lock.unlock(); return }
        lastScan = Date()
        let seen = scanned
        lock.unlock()

        guard let e = FileManager.default.enumerator(at: Self.cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var pages: [(URL, Date)] = []
        for case let file as URL in e where file.lastPathComponent.hasSuffix("-blob") {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, (values.fileSize ?? 0) > 100_000, seen[file] != modified else { continue }
            pages.append((file, modified))
        }
        // Oldest first, so the newest page's view of a thread wins.
        for (file, modified) in pages.sorted(by: { $0.1 < $1.1 }) {
            lock.lock(); scanned[file] = modified; lock.unlock()
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = String(data: handle.readData(ofLength: 15), encoding: .utf8)?.lowercased()
            try? handle.close()
            guard head == "<!doctype html>", let html = try? String(contentsOf: file, encoding: .utf8) else { continue }
            parse(html)
        }
    }

    private static let threadStart = try! NSRegularExpression(pattern: #"\{id:"(T-[0-9a-f-]{36})",v:\d+,created:\d+,"#)
    private static let projectName = try! NSRegularExpression(pattern: #"^project:\{id:"[^"]*",name:"((?:[^"\\]|\\.)*)"\}"#)
    private static let titleField = try! NSRegularExpression(pattern: #",title:"((?:[^"\\]|\\.)*)""#)
    private static let treeName = try! NSRegularExpression(pattern: #"displayName:"((?:[^"\\]|\\.)*)""#)
    private static let projectRecord = try! NSRegularExpression(
        pattern: #"\{id:"[0-9a-f-]{36}",owner:\{[^}]*\},iconURL:(?:null|"((?:[^"\\]|\\.)*)"),lastActivityAt:[^,]+,name:"((?:[^"\\]|\\.)*)""#)
    private static let identicon = try! NSRegularExpression(pattern: #"<svg[^>]*data-orb-identicon="[^"]*"[^>]*data-thread-id="(T-[0-9a-f-]{36})"[^>]*>(.*?)</svg>"#, options: .dotMatchesLineSeparators)

    private func parse(_ html: String) {
        let ns = html as NSString
        var found: [String: Thread] = [:]
        let starts = Self.threadStart.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for (i, m) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].range.location : min(ns.length, m.range.upperBound + 8000)
            let body = NSRange(location: m.range.upperBound, length: min(end - m.range.upperBound, 8000))
            func first(_ re: NSRegularExpression) -> String? {
                re.firstMatch(in: html, range: body).map { Self.unescape(ns.substring(with: $0.range(at: 1))) }
            }
            let id = ns.substring(with: m.range(at: 1))
            var t = found[id] ?? Thread()
            if let title = first(Self.titleField), !title.isEmpty { t.title = title }
            if let project = first(Self.projectName) ?? first(Self.treeName), !project.isEmpty { t.project = project }
            found[id] = t
        }
        for m in Self.identicon.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            if let icon = Self.parseIcon(ns.substring(with: m.range(at: 2))) { found[id, default: Thread()].icon = icon }
        }
        var icons: [String: URL] = [:]
        for m in Self.projectRecord.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard m.range(at: 1).location != NSNotFound else { continue }
            let name = Self.unescape(ns.substring(with: m.range(at: 2)))
            if let url = URL(string: Self.unescape(ns.substring(with: m.range(at: 1)))), url.scheme == "https" { icons[name] = url }
        }

        lock.lock(); defer { lock.unlock() }
        for (id, t) in found {
            var merged = threads[id] ?? Thread()
            merged.title = t.title ?? merged.title
            merged.project = t.project ?? merged.project
            merged.icon = t.icon ?? merged.icon
            threads[id] = merged
            if let title = merged.title, let project = merged.project { labels[project + "\u{1}" + title] = id }
        }
        projectIcons.merge(icons) { _, new in new }
    }

    // MARK: Identicons

    private static let pathElement = try! NSRegularExpression(pattern: #"<path\b[^>]*\bd="([^"]*)"[^>]*>"#)
    private static let number = try! NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?(?:e-?\d+)?"#)

    static func parseIcon(_ svg: String) -> AmpThreadIcon? {
        let ns = svg as NSString
        var strokes: [AmpThreadIcon.Stroke] = []
        var colors: (Color, Color)?
        for m in pathElement.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            let d = ns.substring(with: m.range(at: 1))
            var points: [CGPoint] = []
            for segment in d.components(separatedBy: CharacterSet(charactersIn: "ML")) {
                let v = numbers(segment)
                if v.count >= 2 { points.append(CGPoint(x: v[0], y: v[1])) }
            }
            guard points.count >= 2 else { continue }
            let opacity = attribute("stroke-opacity", tag).flatMap(Double.init) ?? 1
            let width = attribute("style", tag).flatMap { numbers($0).first }.map { CGFloat($0) } ?? 1.2
            strokes.append(.init(points: points, opacity: opacity, width: width))
            if colors == nil, let stroke = attribute("stroke", tag) { colors = strokeColors(stroke) }
        }
        guard !strokes.isEmpty, let colors else { return nil }
        return AmpThreadIcon(strokes: strokes, light: colors.0, dark: colors.1)
    }

    private static func attribute(_ name: String, _ tag: String) -> String? {
        guard let r = tag.range(of: " \(name)=\"") else { return nil }
        let rest = tag[r.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    private static func numbers(_ s: String) -> [Double] {
        let ns = s as NSString
        return number.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { Double(ns.substring(with: $0.range)) }
    }

    /// Evaluates Amp's stroke colour,
    /// `light-dark(oklch(from light-dark(BASE_L, BASE_D) L% min(c * k, max) h), oklch(from light-dark(BASE_L, BASE_D) L% min(c * k, max) h))`,
    /// once for each appearance: each side derives from the base colour light-dark() picks in that appearance.
    static func strokeColors(_ css: String) -> (Color, Color)? {
        let v = numbers(css)
        guard v.count == 18 else { return nil }
        func derive(base: Int, rule: Int) -> Color {
            oklch(l: v[rule] / 100, c: min(v[base + 1] * v[rule + 1], v[rule + 2]), h: v[base + 2])
        }
        return (derive(base: 0, rule: 6), derive(base: 12, rule: 15))
    }

    static func oklch(l: Double, c: Double, h: Double) -> Color {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        return Color(.sRGBLinear,
                     red: clamp(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_),
                     green: clamp(-1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_),
                     blue: clamp(-0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_))
    }

    /// Decodes a JavaScript string literal's escapes (\", \\, \n, \uXXXX, \xXX).
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var chars = s.makeIterator()
        while let c = chars.next() {
            guard c == "\\", let e = chars.next() else { out.append(c); continue }
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "u", "x":
                let hex = String((0..<(e == "u" ? 4 : 2)).compactMap { _ in chars.next() })
                if let v = UInt32(hex, radix: 16), let scalar = UnicodeScalar(v) { out.unicodeScalars.append(scalar) }
            default: out.append(e)
            }
        }
        return out
    }
}

struct AmpThreadIconView: View {
    var project: String
    var title: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var icon: AmpThreadIcon?

    var body: some View {
        Canvas { context, size in
            guard let icon else { return }
            let scale = size.width / 24
            let color = colorScheme == .dark ? icon.dark : icon.light
            for stroke in icon.strokes {
                var path = Path()
                path.addLines(stroke.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })
                context.stroke(path, with: .color(color.opacity(stroke.opacity)),
                               style: StrokeStyle(lineWidth: max(1, stroke.width * scale), lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 16, height: 16)
        .task(id: project + "\u{1}" + title) {
            let (p, t) = (project, title)
            icon = await Task.detached(priority: .utility) { AmpCatalog.shared.icon(project: p, title: t) }.value
        }
    }
}

/// Amp's Puck glyph (a circle with two eyes), as drawn in its sidebar.
struct AmpPuckIcon: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 24
            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s))
            }
            var face = circle(12, 12, 11)
            face.addPath(circle(7.5, 10.5, 3.5))
            face.addPath(circle(16.5, 10.5, 3.5))
            context.fill(face, with: .foreground, style: FillStyle(eoFill: true))
            context.fill(circle(7.5, 10.5, 1.25), with: .foreground)
            context.fill(circle(16.5, 10.5, 1.25), with: .foreground)
        }
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
    }
}
