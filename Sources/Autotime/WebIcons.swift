import AppKit
import SQLite3
import SwiftUI

struct XProfile: Codable {
    var name: String?
    var image: Data?
}

/// Favicons for visited sites and avatars for X users, loaded once and cached on disk.
/// Favicons come from the browsers' own favicon databases when possible, so most never touch the network.
@MainActor
final class WebIcons {
    static let shared = WebIcons()

    private var favicons: [String: Task<NSImage?, Never>] = [:]
    private var profiles: [String: Task<XProfile?, Never>] = [:]

    func favicon(host: String) async -> NSImage? {
        let host = host.lowercased()
        if let t = favicons[host] { return await t.value }
        let t = Task.detached(priority: .utility) { Self.loadFavicon(host).flatMap { NSImage(data: $0) } }
        favicons[host] = t
        return await t.value
    }

    func profile(handle: String, statusID: String?) async -> XProfile? {
        let handle = handle.lowercased()
        if let t = profiles[handle] { return await t.value }
        let t = Task.detached(priority: .utility) { await Self.loadProfile(handle, statusID: statusID) }
        profiles[handle] = t
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

    private nonisolated static func loadFavicon(_ host: String) -> Data? {
        let name = "favicon-\(safeName(host))"
        if let data = cached(name, maxAge: 30 * 86400) { return data }
        guard let data = browserFavicon(host) ?? fetchFavicon(host) else { return nil }
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

    private nonisolated static func fetchFavicon(_ host: String) -> Data? {
        guard let home = URL(string: "https://\(host)/") else { return nil }
        var candidates: [URL] = []
        if let html = get(home).flatMap({ String(data: $0.prefix(200_000), encoding: .utf8) ?? String(data: $0.prefix(200_000), encoding: .isoLatin1) }) {
            candidates = iconLinks(in: html, base: home)
        }
        candidates.append(home.appendingPathComponent("favicon.ico"))
        for url in candidates {
            if let data = get(url), NSImage(data: data) != nil { return data }
        }
        return nil
    }

    /// `<link rel="icon" href="…">` targets in a page, largest declared size first.
    private nonisolated static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return [] }
        func attr(_ name: String, _ s: String) -> String? {
            let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            for i in 1...3 { if let r = Range(m.range(at: i), in: s) { return String(s[r]) } }
            return nil
        }
        var links: [(URL, Int)] = []
        for m in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html) else { continue }
            let s = String(html[r])
            guard let rel = attr("rel", s)?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attr("href", s)?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL, !href.hasSuffix(".svg") else { continue }
            let size = attr("sizes", s).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 16
            links.append((url, size))
        }
        // Prefer icons close to 64px: big enough for Retina, small enough to download quickly.
        return links.sorted { abs($0.1 - 64) < abs($1.1 - 64) }.map(\.0)
    }

    // MARK: X profiles

    private nonisolated static func loadProfile(_ handle: String, statusID: String?) async -> XProfile? {
        let name = "x-\(safeName(handle)).json"
        if let data = cached(name, maxAge: 7 * 86400), let p = try? JSONDecoder().decode(XProfile.self, from: data) { return p }
        var profile = statusID.flatMap { tweetAuthor(handle, statusID: $0) }
        if profile == nil, let url = URL(string: "https://unavatar.io/x/\(handle)?fallback=false"), let data = get(url), NSImage(data: data) != nil {
            profile = XProfile(name: nil, image: data)
        }
        guard let profile else { return nil }
        if let data = try? JSONEncoder().encode(profile) { store(data, as: name) }
        return profile
    }

    /// The public embed endpoint behind platform.twitter.com widgets returns a tweet with its author, no login needed.
    private nonisolated static func tweetAuthor(_ handle: String, statusID: String) -> XProfile? {
        guard let id = Double(statusID),
              let url = URL(string: "https://cdn.syndication.twimg.com/tweet-result?id=\(statusID)&lang=en&token=\(syndicationToken(id))"),
              let data = get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["user"] as? [String: Any],
              (user["screen_name"] as? String)?.lowercased() == handle else { return nil }
        var image: Data?
        if let s = user["profile_image_url_https"] as? String,
           let avatar = URL(string: s.replacingOccurrences(of: "_normal.", with: "_bigger.")) {
            image = get(avatar)
        }
        return XProfile(name: user["name"] as? String, image: image)
    }

    /// The endpoint expects a token derived from the tweet ID: (id / 1e15 · π) in base 36, without zeros or the point.
    private nonisolated static func syndicationToken(_ id: Double) -> String {
        var value = id / 1e15 * Double.pi
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var integer = floor(value)
        value -= integer
        var whole = ""
        repeat {
            whole = String(digits[Int(integer.truncatingRemainder(dividingBy: 36))]) + whole
            integer = floor(integer / 36)
        } while integer > 0
        var fraction = ""
        for _ in 0..<11 where value > 0 {
            value *= 36
            let d = Int(value)
            fraction.append(digits[d])
            value -= Double(d)
        }
        return (whole + fraction).replacingOccurrences(of: "0", with: "")
    }

    // MARK: Networking

    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
        return URLSession(configuration: config)
    }()

    private nonisolated static func get(_ url: URL) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        session.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { result = data }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }
}

struct FaviconView: View {
    var host: String
    var fallback: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: fallback).foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .task(id: host) { image = await WebIcons.shared.favicon(host: host) }
    }
}

struct XAvatarView: View {
    var handle: String
    var statusID: String?

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
            image = await WebIcons.shared.profile(handle: handle, statusID: statusID)?.image.flatMap { NSImage(data: $0) }
        }
    }
}

struct XDisplayName: View {
    var handle: String
    var statusID: String?

    @State private var name: String?

    var body: some View {
        Group {
            if let name, !name.isEmpty { Text(name).foregroundStyle(.secondary).lineLimit(1) }
        }
        .task(id: handle) { name = await WebIcons.shared.profile(handle: handle, statusID: statusID)?.name }
    }
}
