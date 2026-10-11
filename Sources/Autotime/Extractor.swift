import AppKit

struct ExtractedInfo: Equatable {
    var title: String
    var path: String
}

final class Extractor {
    static let separator = " ▸ "

    private var enabledPIDs = Set<pid_t>()
    private var webAreaCache: [pid_t: (window: AXElement, webArea: AXElement?, checked: Date)] = [:]
    private lazy var browsers: Set<String> = {
        var ids: Set<String> = [
            "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
            "com.google.Chrome.dev", "com.google.Chrome.canary", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
            "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera", "net.imput.helium", "app.zen-browser.zen", "org.chromium.Chromium",
            "com.kagi.kagimacOS", "company.thebrowser.dia", "ai.perplexity.comet", "com.openai.atlas",
        ]
        if let probe = URL(string: "https://example.com") {
            for url in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
                if let id = Bundle(url: url)?.bundleIdentifier { ids.insert(id) }
            }
        }
        return ids
    }()

    func isBrowser(_ bundleID: String) -> Bool {
        browsers.contains(bundleID) || browsers.contains(where: { bundleID.hasPrefix($0 + ".app.") })
    }

    func extract(app: NSRunningApplication) -> ExtractedInfo {
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? bundleID
        let axApp = AXElement.application(app.processIdentifier)

        guard let window = axApp.element(kAXFocusedWindowAttribute) ?? axApp.element(kAXMainWindowAttribute) else {
            return ExtractedInfo(title: "", path: "")
        }

        let rawTitle = window.title ?? ""
        let document = window.document ?? ""
        let browser = isBrowser(bundleID)

        var webTitle = ""
        var webURL: URL?
        let docURL = URL(string: document)
        let docIsWeb = docURL.map { Self.isWeb($0) } ?? false
        let slackApp = bundleID == "com.tinyspeck.slackmacgap"
        let slackNeedsDOM = slackApp && !Self.looksLikeSlack(rawTitle)
        let needsWebArea = (browser && document.isEmpty && !Self.isPrivate(rawTitle)) || slackNeedsDOM
        if slackNeedsDOM, !enabledPIDs.contains(app.processIdentifier) {
            axApp.set("AXManualAccessibility", kCFBooleanTrue)
            enabledPIDs.insert(app.processIdentifier)
        }
        if needsWebArea, let area = webArea(pid: app.processIdentifier, window: window) {
            webTitle = area.title ?? ""
            webURL = area.url(kAXURLAttribute)
        }

        if bundleID == "com.tinyspeck.slackmacgap" || Self.looksLikeSlack(rawTitle) || Self.looksLikeSlack(webTitle) || webURL?.host == "app.slack.com" {
            let source = Self.looksLikeSlack(rawTitle) ? rawTitle : (Self.looksLikeSlack(webTitle) ? webTitle : rawTitle)
            if let path = Self.slackPath(source) { return ExtractedInfo(title: "", path: path) }
        }

        if bundleID == "com.hnc.Discord" || bundleID.hasPrefix("com.hnc.Discord") {
            if let path = Self.discordPath(rawTitle.isEmpty ? webTitle : rawTitle) { return ExtractedInfo(title: "", path: path) }
        }

        if bundleID.hasPrefix("com.microsoft.teams") {
            if let path = Self.teamsPath(rawTitle) { return ExtractedInfo(title: "", path: path) }
        }

        if bundleID == "com.apple.mail" {
            return Self.mailInfo(rawTitle)
        }

        let title = Self.cleanTitle(rawTitle.isEmpty ? webTitle : rawTitle, appName: appName)

        if browser {
            if Self.isPrivate(rawTitle) { return ExtractedInfo(title: "Private Window", path: "") }
            let url = docIsWeb ? docURL : webURL.flatMap { Self.isWeb($0) ? $0 : nil }
            return ExtractedInfo(title: title, path: url?.absoluteString ?? "")
        }

        if let docURL, docURL.isFileURL || docIsWeb {
            var t = title
            if docURL.isFileURL { t = Self.removingFileName(t, url: docURL) }
            return ExtractedInfo(title: t, path: docURL.absoluteString)
        }
        if document.hasPrefix("/") {
            return ExtractedInfo(title: title, path: URL(fileURLWithPath: document).absoluteString)
        }

        return ExtractedInfo(title: title, path: "")
    }

    private func webArea(pid: pid_t, window: AXElement) -> AXElement? {
        if let cached = webAreaCache[pid], cached.window == window {
            if let area = cached.webArea, area.role == "AXWebArea" { return area }
            if cached.webArea == nil, Date().timeIntervalSince(cached.checked) < 20 { return nil }
        }
        let found = window.findFirst { $0.role == "AXWebArea" }
        webAreaCache[pid] = (window, found, Date())
        return found
    }

    static func removingFileName(_ title: String, url: URL) -> String {
        let names = [url.lastPathComponent, url.deletingPathExtension().lastPathComponent].map { $0.lowercased() }
        let parts = title.split(separator: #/\s[—–-]\s/#).map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^[●•]\s*"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        let kept = parts.filter { part in
            let p = part.lowercased().replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
            return !names.contains(p)
        }
        return kept.count == parts.count ? title : kept.joined(separator: " — ")
    }

    static func isWeb(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    static func isPrivate(_ title: String) -> Bool {
        let markers = ["(Private Browsing)", "— Private Browsing", "- Private Browsing", "(Incognito)", "Incognito", "(Private)", "– Private", "InPrivate"]
        return markers.contains { title.contains($0) }
    }

    static func looksLikeSlack(_ title: String) -> Bool {
        title.hasSuffix(" - Slack") || title.hasSuffix(" – Slack")
    }

    static func stripUnreadMarker(_ s: String) -> String {
        var s = s
        if let r = s.range(of: #"^(!|\*|\^) "#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"^\(\d+\+?\) "#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"^•\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    static func slackPath(_ title: String) -> String? {
        var parts = stripUnreadMarker(title).components(separatedBy: " - ")
        if parts.last?.trimmingCharacters(in: .whitespaces).hasSuffix("Slack") == true { parts.removeLast() }
        parts.removeAll { $0.range(of: #"^\d+\+? new (items?|messages?)$"#, options: .regularExpression) != nil }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1 { return parts[0] }
        let workspace = parts.removeLast()
        return workspace + separator + parts.joined(separator: " - ")
    }

    static func discordPath(_ title: String) -> String? {
        var s = stripUnreadMarker(title)
        for suffix in [" - Discord", " – Discord"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        if s.hasPrefix("Discord | ") { s.removeFirst("Discord | ".count) }
        let parts = s.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty, parts != ["Discord"] else { return nil }
        if parts.count == 1 {
            return parts[0].hasPrefix("@") ? "Direct Messages" + separator + parts[0] : parts[0]
        }
        return parts.reversed().joined(separator: separator)
    }

    static func teamsPath(_ title: String) -> String? {
        var parts = stripUnreadMarker(title).components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        parts.removeAll { $0.hasPrefix("Microsoft Teams") || $0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: separator)
    }

    static func mailInfo(_ title: String) -> ExtractedInfo {
        let parts = title.components(separatedBy: " – ")
        if parts.count >= 2, title.contains(" · ") || ["Inbox", "Sent", "Drafts", "Archive", "Junk", "Trash", "Flagged", "VIPs"].contains(where: { parts[0].hasPrefix($0) }) {
            let cleaned = parts.map { part -> String in
                if let r = part.range(of: " · ") { return String(part[..<r.lowerBound]) }
                return part
            }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return ExtractedInfo(title: "", path: cleaned.joined(separator: separator))
        }
        return ExtractedInfo(title: title.trimmingCharacters(in: .whitespaces), path: "")
    }

    private static let noise = try! NSRegularExpression(
        pattern: #"\s[-–—]\s(Audio playing|Audio muted|Playing audio|Camera recording|Microphone recording|Camera and microphone recording|Recording|Network activity|Bluetooth device connected|USB device connected|Sharing this tab|Pinned|Part of group .+?|High memory usage - [\d.,]+\s?[KMGT]B)(?=\s[-–—]\s|$)"#,
        options: [.caseInsensitive]
    )

    static func cleanTitle(_ raw: String, appName: String) -> String {
        var s = raw.replacingOccurrences(of: "\u{200E}", with: "").replacingOccurrences(of: "\u{200F}", with: "")
        if let r = s.range(of: #"^[\x{2800}-\x{28FF}◐◑◒◓◴◵◶◷✳✶✻✽✢⏺●○·•∙*]+\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        s = stripUnreadMarker(s)
        var previous = ""
        while previous != s {
            previous = s
            let ns = s as NSString
            s = noise.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        if !appName.isEmpty {
            let name = NSRegularExpression.escapedPattern(for: appName)
            let pattern = #"\s[-–—|]\s"# + name + #"(\s[-–—]\s[^-–—]{1,40})?$"#
            if let r = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        }
        if let r = s.range(of: #"\s\((Not Responding|Terminated)\)$"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.caseInsensitiveCompare(appName) == .orderedSame { return "" }
        return s
    }
}
