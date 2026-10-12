import AppKit

/// Amp's desktop app is a web view onto ampcode.com. The open thread comes from the web view's URL; its title from the
/// sidebar link for it, or from the thread list SvelteKit embeds in pages WebKit has cached; its project from that list,
/// or from Amp's runner files, which record each thread's working directory.
final class AmpExtractor {
    static let bundleID = "com.ampcode.amp.macos"

    private var titles: [String: String] = [:]
    private var projects: [String: String] = [:]
    private var liveTitles: [String: (title: String?, checked: Date)] = [:]
    private var scanned: [URL: Date] = [:]
    private var lastScan = Date.distantPast

    func info(pid: pid_t, area: AXElement) -> ExtractedInfo? {
        guard let url = area.url(kAXURLAttribute), url.host?.hasSuffix("ampcode.com") == true else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let id = parts.last, id.hasPrefix("T-"), parts.count >= 2, ["threads", "puck-window"].contains(parts[parts.count - 2]) else {
            return ExtractedInfo(title: "", path: "")
        }
        refresh(force: titles[id] == nil || projects[id] == nil)
        let title = liveTitle(id, area: area) ?? titles[id] ?? ""
        guard let project = projects[id] ?? Self.runnerProject(id) else { return ExtractedInfo(title: "", path: title) }
        return ExtractedInfo(title: "", path: project + Extractor.separator + (title.isEmpty ? "Untitled Thread" : title))
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

    // MARK: WebKit cache

    private static let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/\(bundleID)/WebKit/NetworkCache")

    private func refresh(force: Bool) {
        guard Date().timeIntervalSince(lastScan) > (force ? 15 : 60) else { return }
        lastScan = Date()
        guard let e = FileManager.default.enumerator(at: Self.cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var pages: [(URL, Date)] = []
        for case let file as URL in e where file.lastPathComponent.hasSuffix("-blob") {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, (values.fileSize ?? 0) > 100_000, scanned[file] != modified else { continue }
            pages.append((file, modified))
        }
        // Oldest first, so the newest page's view of a thread wins.
        for (file, modified) in pages.sorted(by: { $0.1 < $1.1 }) {
            scanned[file] = modified
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

    private func parse(_ html: String) {
        let ns = html as NSString
        let starts = Self.threadStart.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for (i, m) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].range.location : min(ns.length, m.range.upperBound + 8000)
            let body = NSRange(location: m.range.upperBound, length: min(end - m.range.upperBound, 8000))
            let id = ns.substring(with: m.range(at: 1))
            func first(_ re: NSRegularExpression) -> String? {
                re.firstMatch(in: html, range: body).map { Self.unescape(ns.substring(with: $0.range(at: 1))) }
            }
            if let title = first(Self.titleField), !title.isEmpty { titles[id] = title }
            if let project = first(Self.projectName) ?? first(Self.treeName), !project.isEmpty { projects[id] = project }
        }
        var icons: [String: URL] = [:]
        for m in Self.projectRecord.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard m.range(at: 1).location != NSNotFound else { continue }
            let name = Self.unescape(ns.substring(with: m.range(at: 2)))
            if let url = URL(string: Self.unescape(ns.substring(with: m.range(at: 1)))), url.scheme == "https" { icons[name] = url }
        }
        AmpProjects.update(icons)
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

    // MARK: Runner files

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

/// Project icons Amp users can set, shared between the extractor (which finds them) and the activity list (which shows them).
enum AmpProjects {
    private static let lock = NSLock()
    private static var icons: [String: URL] = [:]

    static func update(_ found: [String: URL]) {
        lock.lock()
        icons.merge(found) { _, new in new }
        lock.unlock()
    }

    static func iconURL(_ project: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return icons[project]
    }
}
