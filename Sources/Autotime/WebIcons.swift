import AppKit
import SQLite3
import SwiftUI

struct XProfile: Codable {
    var name: String?
    var image: Data?
}

struct Favicon {
    /// Single-colour glyphs on a transparent background (GitHub, X, Vercel…) vanish against a matching
    /// background, so they are inverted when they would clash with the current appearance.
    enum Tone { case colorful, darkGlyph, lightGlyph }

    var image: NSImage
    var tone: Tone
}

/// Favicons for visited sites and avatars for X users, loaded once and cached on disk.
/// Favicons come from the browsers' own favicon databases when possible, so most never touch the network.
/// Nothing is sent to third parties: icons come from the browser or the site itself, X profiles from x.com.
@MainActor
final class WebIcons {
    static let shared = WebIcons()

    private var favicons: [String: Task<Favicon?, Never>] = [:]
    private var profiles: [String: Task<XProfile?, Never>] = [:]
    private var githubAvatars: [String: Task<NSImage?, Never>] = [:]
    private var remoteImages: [String: Task<NSImage?, Never>] = [:]

    func favicon(host: String) async -> Favicon? {
        let host = host.lowercased()
        if let t = favicons[host] { return await t.value }
        let t = Task.detached(priority: .utility) { () -> Favicon? in
            guard let data = await Self.loadFavicon(host), let image = NSImage(data: data) else { return nil }
            return Favicon(image: image, tone: Self.tone(of: image))
        }
        favicons[host] = t
        return await t.value
    }

    func profile(handle: String) async -> XProfile? {
        let handle = handle.lowercased()
        if let t = profiles[handle] { return await t.value }
        let t = Task.detached(priority: .utility) { await Self.loadProfile(handle) }
        profiles[handle] = t
        return await t.value
    }

    func image(at url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let t = remoteImages[key] { return await t.value }
        let t = Task.detached(priority: .utility) { () -> NSImage? in
            let hash = key.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
            let name = "image-\(Self.safeName(url.host ?? ""))-\(String(hash, radix: 36))"
            var data = Self.cached(name, maxAge: 7 * 86400)
            if data == nil {
                data = await Self.get(url, limit: 1024 * 1024)
                if let data { Self.store(data, as: name) }
            }
            return data.flatMap { NSImage(data: $0) }
        }
        remoteImages[key] = t
        return await t.value
    }

    func githubAvatar(owner: String) async -> NSImage? {
        let owner = owner.lowercased()
        if let t = githubAvatars[owner] { return await t.value }
        let t = Task.detached(priority: .utility) { () -> NSImage? in
            let name = "github-\(Self.safeName(owner))"
            var data = Self.cached(name, maxAge: 7 * 86400)
            if data == nil, let url = URL(string: "https://github.com/\(owner).png?size=64") {
                data = await Self.get(url, limit: 1024 * 1024)
                if let data { Self.store(data, as: name) }
            }
            return data.flatMap { NSImage(data: $0) }
        }
        githubAvatars[owner] = t
        return await t.value
    }

    // MARK: Disk cache

    private nonisolated static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mahadk.autotime").appendingPathComponent("WebIcons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private nonisolated static func cached(_ name: String, maxAge: TimeInterval) -> Data? {
        let url = cacheDir.appendingPathComponent(name)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(modified) < maxAge else { return nil }
        return try? Data(contentsOf: url)
    }

    private nonisolated static func store(_ data: Data, as name: String) {
        try? data.write(to: cacheDir.appendingPathComponent(name), options: .atomic)
    }

    private nonisolated static func safeName(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    // MARK: Favicons

    private nonisolated static func loadFavicon(_ host: String) async -> Data? {
        let name = "favicon-\(safeName(host))"
        if let data = cached(name, maxAge: 30 * 86400) { return data }
        var data = browserFavicon(host)
        if data == nil { data = await fetchFavicon(host) }
        guard let data else { return nil }
        store(data, as: name)
        return data
    }

    /// Chromium-based browsers (Chrome, Arc, Brave, Edge, Helium, Vivaldi…) keep a `Favicons` SQLite database per profile.
    private nonisolated static let faviconDatabases: [URL] = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let e = FileManager.default.enumerator(at: support, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in e {
            if e.level >= 4 { e.skipDescendants() }
            guard url.lastPathComponent == "Favicons" else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            found.append((url, date))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }()

    private nonisolated static func browserFavicon(_ host: String) -> Data? {
        for file in faviconDatabases {
            // immutable=1 reads without taking locks, so a running browser is never blocked.
            var db: OpaquePointer?
            guard sqlite3_open_v2(file.absoluteString + "?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                sqlite3_close(db)
                continue
            }
            defer { sqlite3_close(db) }
            let sql = """
                SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
                WHERE (m.page_url >= ?1 AND m.page_url < ?2) OR (m.page_url >= ?3 AND m.page_url < ?4)
                ORDER BY b.width >= 32 DESC, abs(b.width - 32), b.last_updated DESC LIMIT 1
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            // "/" sorts just before "0", so [scheme://host/, scheme://host0) covers every page on the host.
            for (i, bound) in ["https://\(host)/", "https://\(host)0", "http://\(host)/", "http://\(host)0"].enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), bound, -1, transient)
            }
            if sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
                if NSImage(data: data) != nil { return data }
            }
        }
        return nil
    }

    private nonisolated static func fetchFavicon(_ host: String) async -> Data? {
        guard isPublicHost(host), let home = URL(string: "https://\(host)/") else { return nil }
        var candidates: [URL] = []
        if let data = await get(home, limit: 512 * 1024),
           let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            candidates = iconLinks(in: html, base: home)
        }
        candidates.append(home.appendingPathComponent("favicon.ico"))
        for url in candidates.prefix(4) {
            if let data = await get(url, limit: 1024 * 1024), NSImage(data: data) != nil { return data }
        }
        return nil
    }

    /// `<link rel="icon" href="…">` targets in a page, best size first. Dark-scheme variants are skipped; inversion handles those.
    private nonisolated static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return [] }
        var links: [(URL, Int)] = []
        for m in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html) else { continue }
            let s = String(html[r])
            guard let rel = attribute("rel", in: s)?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  !(attribute("media", in: s)?.contains("dark") ?? false),
                  let href = attribute("href", in: s)?.replacingOccurrences(of: "&amp;", with: "&"), !href.hasSuffix(".svg"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let size = attribute("sizes", in: s).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 16
            links.append((url, size))
        }
        // Prefer icons close to 64px: big enough for Retina, small enough to download quickly.
        return links.sorted { abs($0.1 - 64) < abs($1.1 - 64) }.map(\.0)
    }

    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for i in 1...3 { if let r = Range(m.range(at: i), in: tag) { return String(tag[r]) } }
        return nil
    }

    private nonisolated static func tone(of image: NSImage) -> Favicon.Tone {
        let size = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return .colorful }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        var transparent = 0, opaque = 0, saturated = 0
        var brightness = 0.0
        for x in 0..<size {
            for y in 0..<size {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.alphaComponent < 0.1 { transparent += 1; continue }
                guard c.alphaComponent > 0.5 else { continue }
                opaque += 1
                brightness += c.brightnessComponent
                if c.saturationComponent > 0.2 && c.brightnessComponent > 0.2 { saturated += 1 }
            }
        }
        // A glyph needs a transparent background to show through, and almost no colour of its own.
        guard opaque > 0, transparent > size * size / 5, Double(saturated) / Double(opaque) < 0.05 else { return .colorful }
        let mean = brightness / Double(opaque)
        if mean < 0.3 { return .darkGlyph }
        if mean > 0.85 { return .lightGlyph }
        return .colorful
    }

    // MARK: X profiles

    private nonisolated static func loadProfile(_ handle: String) async -> XProfile? {
        let name = "xprofile-\(safeName(handle)).json"
        if let data = cached(name, maxAge: 7 * 86400), let p = try? JSONDecoder().decode(XProfile.self, from: data) { return p }
        guard let profile = await profilePage(handle) else { return nil }
        if let data = try? JSONEncoder().encode(profile) { store(data, as: name) }
        return profile
    }

    /// x.com serves Open Graph tags (avatar, "Name (@handle) on X") on profile pages for link previews, no login needed.
    private nonisolated static func profilePage(_ handle: String) async -> XProfile? {
        guard let page = URL(string: "https://x.com/\(handle)"),
              let data = await get(page, limit: 1024 * 1024),
              let html = String(data: data, encoding: .utf8) else { return nil }
        func meta(_ property: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: "<meta\\b[^>]*property=\"\(property)\"[^>]*>", options: .caseInsensitive),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range, in: html) else { return nil }
            return attribute("content", in: String(html[r]))
        }
        var name: String?
        if let title = meta("og:title"), let r = title.range(of: " (@", options: .backwards) {
            name = decodeEntities(String(title[..<r.lowerBound]))
        }
        var image: Data?
        if let s = meta("og:image"), let url = URL(string: s.replacingOccurrences(of: "_200x200.", with: "_bigger.")),
           ["pbs.twimg.com", "abs.twimg.com"].contains(url.host ?? "") {
            image = await get(url, limit: 1024 * 1024)
        }
        guard name != nil || image != nil else { return nil }
        return XProfile(name: name, image: image)
    }

    private nonisolated static func decodeEntities(_ s: String) -> String {
        guard s.contains("&"), let re = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt);") else { return s }
        var result = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: result), let body = Range(m.range(at: 1), in: result) else { continue }
            let entity = String(result[body])
            let scalar: UnicodeScalar? = switch entity {
            case "amp": "&"
            case "quot": "\""
            case "apos": "'"
            case "lt": "<"
            case "gt": ">"
            default: entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init)
                                            : UInt32(entity.dropFirst()).flatMap(UnicodeScalar.init)
            }
            if let scalar { result.replaceSubrange(whole, with: String(Character(scalar))) }
        }
        return result
    }

    // MARK: Networking

    /// Hosts come from browsing history, so never reach into the local network: no localhost, `.local`/intranet names or private IPs.
    nonisolated static func isPublicHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard h.contains("."), !h.hasPrefix("localhost") else { return false }
        for suffix in [".local", ".localhost", ".internal", ".lan", ".home", ".corp", ".intranet", ".home.arpa", ".test", ".invalid"] where h.hasSuffix(suffix) {
            return false
        }
        if h.contains(":") { return false } // IPv6 literals: skip them rather than classify every reserved range
        let octets = h.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 && h.split(separator: ".").count == 4 { return isPublicIPv4(octets[0], octets[1]) }
        return true
    }

    private nonisolated static func isPublicIPv4(_ a: Int, _ b: Int) -> Bool {
        switch (a, b) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (100, 64...127), (172, 16...31), (224..., _): false
        default: true
        }
    }

    /// Every address the host resolves to must be public, so a public-looking name pointing at 192.168.x.x is refused too.
    nonisolated static func resolvesPublicly(_ host: String) -> Bool {
        guard isPublicHost(host) else { return false }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(first) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let info = node?.pointee {
            if info.ai_family == AF_INET {
                let addr = info.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let b = withUnsafeBytes(of: addr) { Array($0) }
                if !isPublicIPv4(Int(b[0]), Int(b[1])) { return false }
            } else if info.ai_family == AF_INET6 {
                let addr = info.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let b = withUnsafeBytes(of: addr) { Array($0) }
                let loopbackOrUnspecified = b[0..<15].allSatisfy { $0 == 0 } && b[15] <= 1
                let uniqueLocal = b[0] & 0xfe == 0xfc
                let linkLocal = b[0] == 0xfe && b[1] & 0xc0 == 0x80
                let mapped = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff
                if loopbackOrUnspecified || uniqueLocal || linkLocal || (mapped && !isPublicIPv4(Int(b[12]), Int(b[13]))) { return false }
            }
            node = info.ai_next
        }
        return true
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let ok = request.url.map { ["http", "https"].contains($0.scheme ?? "") && WebIcons.resolvesPublicly($0.host ?? "") } ?? false
            completionHandler(ok ? request : nil)
        }
    }

    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    /// GETs a public http(s) URL, giving up on anything larger than `limit` bytes.
    private nonisolated static func get(_ url: URL, limit: Int) async -> Data? {
        guard ["http", "https"].contains(url.scheme ?? ""), resolvesPublicly(url.host ?? "") else { return nil }
        guard let (bytes, response) = try? await session.bytes(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength <= Int64(limit) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { bytes.task.cancel(); return nil }
            }
        } catch {
            return nil
        }
        return data
    }
}

struct FaviconView: View {
    var host: String
    var fallback: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var favicon: Favicon?

    var body: some View {
        Group {
            if let favicon {
                let invert = (favicon.tone == .darkGlyph && colorScheme == .dark) || (favicon.tone == .lightGlyph && colorScheme == .light)
                Image(nsImage: favicon.image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .colorInvertIf(invert)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: fallback).foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .task(id: host) { favicon = await WebIcons.shared.favicon(host: host) }
    }
}

private extension View {
    @ViewBuilder func colorInvertIf(_ invert: Bool) -> some View {
        if invert { colorInvert() } else { self }
    }
}

struct XAvatarView: View {
    var handle: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .task(id: handle) {
            image = await WebIcons.shared.profile(handle: handle)?.image.flatMap { NSImage(data: $0) }
        }
    }
}

struct GitHubOwnerAvatar: View {
    var repo: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: repo) {
            image = await WebIcons.shared.githubAvatar(owner: String(repo.split(separator: "/").first ?? ""))
        }
    }
}

/// A project's own icon when its owner set one in Amp, otherwise Amp's app icon.
struct AmpProjectIcon: View {
    var project: String

    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? AppCatalog.shared.icon(for: AmpExtractor.bundleID))
            .resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: image == nil ? 0 : 4, style: .continuous))
            .task(id: project) {
                if let url = AmpProjects.iconURL(project) { image = await WebIcons.shared.image(at: url) }
            }
    }
}

struct XDisplayName: View {
    var handle: String

    @State private var name: String?

    var body: some View {
        Group {
            if let name, !name.isEmpty { Text(name).foregroundStyle(.secondary).lineLimit(1) }
        }
        .task(id: handle) { name = await WebIcons.shared.profile(handle: handle)?.name }
    }
}
